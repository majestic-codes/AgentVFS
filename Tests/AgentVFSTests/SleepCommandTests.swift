//
//  SleepCommandTests.swift
//  AgentVFSTests
//
//  Created by Yevhenii Kalashnikov on 18.11.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation
import Testing
@testable import AgentVFS

/// A shell over an empty in-memory mount whose `sleep` may last `maxSleep`.
private func sleepShell(maxSleep: Duration = .seconds(60)) throws -> CommandInterpreter {
    let driver = try InMemoryDriver(texts: [:])
    let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "data", driver: driver)])
    return CommandInterpreter(fileSystem: fileSystem, limits: OutputLimits(maxSleep: maxSleep))
}

@Suite("sleep")
struct SleepCommandTests {
    @Test("waits the given seconds and prints nothing", arguments: ["sleep 0.05", "sleep 00.050"])
    func waits(line: String) async throws {
        let shell = try sleepShell()
        let start = ContinuousClock.now
        let result = await shell.run(line)
        #expect(ContinuousClock.now - start >= .milliseconds(50))
        #expect(result == CommandResult(output: "", exitCode: 0))
    }

    @Test("zero seconds is no wait")
    func zero() async throws {
        let result = try await sleepShell().run("sleep 0")
        #expect(result == CommandResult(output: "", exitCode: 0))
    }

    @Test("a wait as long as the limit is allowed")
    func atTheLimit() async throws {
        let result = try await sleepShell(maxSleep: .milliseconds(20)).run("sleep 0.02")
        #expect(result.exitCode == 0)
    }

    @Test("a wait past the limit is refused at once, with the limit in the message", arguments: [
        "sleep 3", "sleep 2.001", "sleep 86400", "sleep 99999999999999999999999999999999999999999999"
    ])
    func pastTheLimit(line: String) async throws {
        let shell = try sleepShell(maxSleep: .seconds(2))
        let start = ContinuousClock.now
        let result = await shell.run(line)
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(result.exitCode == 2)
        #expect(result.output == "sleep: a wait lasts at most 2 seconds; wait that long, then check again")
    }

    @Test("a limit with a fraction is shown with it")
    func fractionalLimit() async throws {
        let result = try await sleepShell(maxSleep: .milliseconds(1500)).run("sleep 2")
        #expect(result.output.contains("at most 1.5 seconds"))
    }

    @Test("anything but one plain number of seconds is a usage error", arguments: [
        "sleep", "sleep 1 2", "sleep 1m", "sleep 30s", "sleep -1", "sleep abc", "sleep 1e3", "sleep .5", "sleep 5.",
        "sleep 1.2.3", "sleep inf", "sleep nan", "sleep 0x10", "sleep ''", "sleep ٣"
    ])
    func usage(line: String) async throws {
        let start = ContinuousClock.now
        let result = try await sleepShell().run(line)
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(result.exitCode == 2)
        #expect(result.output == "sleep: give the wait as one number of seconds, such as sleep 30")
    }

    @Test("cancelling the task ends the wait")
    func cancellation() async throws {
        let shell = try sleepShell()
        let start = ContinuousClock.now
        let waiting = Task { await shell.run("sleep 30") }
        try await Task.sleep(for: .milliseconds(20))
        waiting.cancel()
        let result = await waiting.value
        #expect(ContinuousClock.now - start < .seconds(10))
        #expect(result.exitCode == 130)
    }

    @Test("does not read a pipe")
    func pipe() async throws {
        let result = try await sleepShell().run("pwd | sleep 0")
        #expect(result.exitCode == 2)
        #expect(result.output.contains("sleep does not read from a pipe"))
    }

    @Test("is a standard command with a help line")
    func listed() async throws {
        let shell = try sleepShell()
        #expect(await shell.commandNames.contains("sleep"))
        #expect(await shell.helpText.contains("sleep SECONDS"))
    }

    @Test("the longest sleep must be positive", arguments: [Duration.zero, .seconds(-1)])
    func limitValidation(maxSleep: Duration) {
        let message = "OutputLimits.maxSleep must be positive, not \(maxSleep)"
        #expect(throws: VFSError.invalidConfiguration(message)) {
            try OutputLimits(maxSleep: maxSleep).validate()
        }
    }
}
