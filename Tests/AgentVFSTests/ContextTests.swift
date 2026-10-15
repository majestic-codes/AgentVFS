//
//  ContextTests.swift
//  AgentVFSTests
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation
import Testing
@testable import AgentVFS

@Suite("grep and rg context lines")
struct ContextTests {
    private func shell() throws -> CommandInterpreter {
        let logs = try InMemoryDriver(texts: [
            "app.log": "l1\nl2 ERROR a\nl3\nl4\nl5\nl6\nl7 ERROR b\nl8 ERROR c\nl9\nl10\n",
            "b.log": "x\nERROR z\n",
            "empty.log": ""
        ])
        let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "logs", driver: logs)])
        return CommandInterpreter(fileSystem: fileSystem)
    }

    @Test("output matches grep: ':' on matches, '-' on context, '--' between groups")
    func grepFormat() async throws {
        let shell = try shell()
        let after = await shell.run("grep -A2 ERROR logs/app.log").output
        #expect(after == "l2 ERROR a\nl3\nl4\n--\nl7 ERROR b\nl8 ERROR c\nl9\nl10")
        let before = await shell.run("grep -n -B1 ERROR logs/app.log").output
        #expect(before == "1-l1\n2:l2 ERROR a\n--\n6-l6\n7:l7 ERROR b\n8:l8 ERROR c")
        #expect(await shell.run("grep -rn -C1 ERROR logs").output == """
        /workspace/logs/app.log-1-l1
        /workspace/logs/app.log:2:l2 ERROR a
        /workspace/logs/app.log-3-l3
        --
        /workspace/logs/app.log-6-l6
        /workspace/logs/app.log:7:l7 ERROR b
        /workspace/logs/app.log:8:l8 ERROR c
        /workspace/logs/app.log-9-l9
        --
        /workspace/logs/b.log-1-x
        /workspace/logs/b.log:2:ERROR z
        """)
    }

    @Test("-A and -B override -C, long forms work, and rg takes them too")
    func options() async throws {
        let shell = try shell()
        let overridden = await shell.run("grep -C 3 -A 0 -n 'ERROR c' logs/app.log").output
        #expect(overridden == "5-l5\n6-l6\n7-l7 ERROR b\n8:l8 ERROR c")
        #expect(await shell.run("grep --context=1 'ERROR z' logs/b.log").output == "x\nERROR z")
        let ripgrep = await shell.run("rg -A1 'ERROR a' logs").output
        #expect(ripgrep == "/workspace/logs/app.log:2:l2 ERROR a\n/workspace/logs/app.log-3-l3")
        #expect(await shell.run("grep -C x ERROR logs/app.log").exitCode == 2)
        #expect(await shell.run("grep -C 1 nothing logs/app.log").exitCode == 1)
    }

    @Test("context does not read the file from the source again")
    func cached() async throws {
        let logs = try InMemoryDriver(texts: ["a.log": "a\nERROR\nb\n"])
        let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "logs", driver: logs)])
        let shell = CommandInterpreter(fileSystem: fileSystem)
        _ = await shell.run("grep -C1 ERROR logs/a.log")
        let metrics = await fileSystem.metrics()
        #expect(metrics.contentCacheMisses == 1)
    }
}
