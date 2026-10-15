//
//  JQLimitsTests.swift
//  AgentVFSJQTests
//
//  Created by Yevhenii Kalashnikov on 14.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import Foundation
import Testing
@testable import AgentVFSJQ

/// Runs `filter` with `-n` and the options `configure` sets.
private func runNull(_ filter: String, configure: (inout JQ.Options) -> Void = { _ in }) async -> JQ.Result {
    var options = JQ.Options()
    options.nullInput = true
    options.compactOutput = true
    configure(&options)
    return await JQ.run(filter: filter, inputs: [], options: options)
}

@Suite("jq limits")
struct JQLimitsTests {
    @Test("values nested past the limit fail instead of overflowing the stack", arguments: [
        "reduce range(3000000) as $x (null; [.]) | 1",
        "reduce range(3000000) as $x (null; {a: .}) | 1",
        "reduce range(3000000) as $x (null; .a = .) | 1",
        "reduce range(3000000) as $x (null; .a |= [.]) | 1",
        "reduce range(3000000) as $x ([1]; group_by(.)) | 1",
        "reduce range(3000000) as $x ([1]; to_entries) | 1",
        "reduce range(3000000) as $x (null; setpath([\"a\"]; .)) | 1",
        "last(limit(3000000; repeat([.]))) | 1",
        "setpath([range(9999) | 0]; [[1]]) | 1",
        "getpath([range(9999) | \"a\"]) = [[1]]"
    ])
    func deepValues(filter: String) async {
        let result = await runNull(filter)
        #expect(result.exitCode == 5)
        #expect(result.output.contains("Value nests too deeply (more than 10000 levels)"))
    }

    @Test("bounds on depth follow values down, so steady nesting is not mistaken for growth", arguments: [
        ("reduce range(20000) as $x ([0]; [.[0]]) | length", "1"),
        ("reduce range(20000) as $x ({a: 1}; {a: .a}) | .a", "1"),
        ("reduce range(20000) as $x ([[1]]; group_by(.) | .[0]) | length", "1"),
        ("reduce range(20000) as $x ({a: {b: 1}}; .a = .a) | .a.b", "1"),
        ("reduce range(20000) as $x ([[1]]; to_entries | map(.value)) | length", "1"),
        ("reduce range(20000) as $x ({a: {b: 1}}; .a |= .) | .a.b", "1")
    ])
    func steadyDepth(filter: String, expected: String) async {
        #expect(await runNull(filter).output == expected + "\n")
    }

    @Test("deep and long filters fail to compile instead of overflowing the stack", arguments: [
        String(repeating: "[", count: 30000) + String(repeating: "]", count: 30000),
        String(repeating: "-", count: 30000) + "1",
        "1" + String(repeating: " + 1", count: 20000),
        "." + String(repeating: " | .", count: 20000),
        String(repeating: "\"\\(", count: 20000) + "1" + String(repeating: ")\"", count: 20000),
        String(repeating: "try ", count: 20000) + "1",
        ". as " + String(repeating: "[", count: 20000) + "$a" + String(repeating: "]", count: 20000) + " | 1"
    ])
    func deepFilters(filter: String) async {
        let result = await runNull(filter)
        #expect(result.exitCode == 3)
        #expect(result.output.contains("filter nests too deeply"))
        #expect(result.output.utf8.count < 1000)
    }

    @Test("filters longer than a megabyte are refused")
    func longFilter() async {
        let result = await runNull("1" + String(repeating: ",1", count: 600_000))
        #expect(result.exitCode == 3)
        #expect(result.output.contains("filter too long"))
    }

    @Test("long paths are refused before they recurse", arguments: [
        "delpaths([[range(20000) | 0]])",
        "setpath([range(20000) | {start: 0}]; [1])",
        "getpath([range(20000) | {start: 0}]) = [1]",
        "getpath([range(20000) | {start: 0}]) |= [1]"
    ])
    func longPaths(filter: String) async {
        let result = await runNull(filter)
        #expect(result.output.contains("Path too long (more than 10000 components)"))
    }

    @Test("paths and stream events of a deep value share their prefixes")
    func deepPaths() async {
        let deep = String(repeating: "[", count: 3000) + String(repeating: "]", count: 3000)
        let input = [JQ.Input(name: "deep.json", text: deep)]
        var options = JQ.Options()
        options.compactOutput = true
        let events = await JQ.run(filter: "first(tostream) | .[0] | length", inputs: input, options: options)
        #expect(events.output == "2999\n")
        let lastPath = await JQ.run(filter: "last(paths) | length", inputs: input, options: options)
        #expect(lastPath.output == "2999\n")
        #expect(await runNull("path(getpath([range(300000) | \"a\"])) | length").output == "300000\n")
    }

    @Test("--stream reads deep inputs one event at a time")
    func streamedInput() async {
        let deep = String(repeating: "[", count: 9000) + "1" + String(repeating: "]", count: 9000)
        var options = JQ.Options()
        options.stream = true
        options.compactOutput = true
        let input = JQ.Input(name: "deep.json", text: deep)
        let result = await JQ.run(filter: ".[0] | length", inputs: [input], options: options)
        #expect(result.output.hasPrefix("9000\n9000\n8999\n"))
    }

    @Test("a program that holds too much memory is stopped")
    func memoryLimit() async {
        let result = await runNull("[range(20) | \"a\" * 1e7] | length") { $0.maxMemoryGrowth = 50 << 20 }
        #expect(result.exitCode == 5)
        #expect(result.output.contains("memory limit of 50 MB"))
    }

    @Test("a program that runs too long is stopped", arguments: [
        "last(range(infinite))",
        "[range(100000)] - [range(100000)] | length",
        "reduce range(1000000) as $x (\"a\" * 1e6; ascii_downcase) | length",
        "\"\(String(repeating: "a", count: 40))!\" | test(\"(a+)+$\")"
    ])
    func timeLimit(filter: String) async {
        let clock = ContinuousClock()
        let started = clock.now
        let result = await runNull(filter) { options in
            options.timeout = .milliseconds(300)
            options.maxSteps = .max
        }
        #expect(result.exitCode == 5)
        #expect(result.output.contains("time limit"))
        // Generous, so a loaded machine does not fail it: a program the limit missed runs for minutes.
        #expect(clock.now - started < .seconds(30))
    }

    @Test("cancelling the task stops the program")
    func cancellation() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let task = Task {
            await runNull("last(range(infinite))") { $0.maxSteps = .max }
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let result = await task.value
        #expect(result.output.contains("jq was stopped"))
        #expect(clock.now - started < .seconds(25))
    }

    @Test("debug and stderr stop at the output limit", arguments: ["debug", "stderr"])
    func messages(function: String) async {
        let filter = "(\"a\" * 1e5) as $s | range(1500) | ($s | \(function)) | empty"
        let result = await runNull(filter) { $0.maxOutputBytes = 1000 }
        #expect(result.truncated)
        #expect(result.output.utf8.count <= 1000)
    }

    @Test("output is serialized only as far as it fits")
    func boundedOutput() async {
        let result = await runNull("[range(1000000)] | [., ., .]") { options in
            options.compactOutput = false
            options.maxOutputBytes = 1000
        }
        #expect(result.truncated)
        #expect(result.output.utf8.count <= 1000)
        let text = JSONValue.array(Array(repeating: .string("abc"), count: 100_000)).serialized(.compact, limit: 10)
        #expect(text.utf8.count < 20)
    }

    @Test("arrays and strings past the size limits are refused", arguments: [
        "\"a\" * (\(Operations.maxArrayCount) + 1) | explode",
        "[range(\(Operations.maxArrayCount / 4 + 1))] | [., ., ., .] | flatten | length"
    ])
    func sizeLimits(filter: String) async {
        #expect(await runNull(filter).output.contains("too large"))
    }

    @Test("text search takes time in proportion to the text", arguments: [
        ("(\"a\" * 1000000) | contains(\"a\" * 500000 + \"b\")", "false"),
        ("(\"ab\" * 100000) | indices(\"b\") | length", "100000"),
        ("(\"a,\" * 100000) | split(\",\") | length", "100001"),
        ("[range(100000) | 0] | indices([0, 0, 1]) | length", "0")
    ])
    func linearSearch(filter: String, expected: String) async {
        let clock = ContinuousClock()
        let started = clock.now
        #expect(await runNull(filter).output == expected + "\n")
        // Quadratic search on these sizes takes hours, so a generous bound still tells them apart.
        #expect(clock.now - started < .seconds(60))
    }

    @Test("search and split keep jq's answers", arguments: [
        ("\"aaa\" | indices(\"aa\")", "[0,1]"),
        ("\"a,b,,c\" | split(\",\")", #"["a","b","","c"]"#),
        ("\"abcabc\" | split(\"bc\")", #"["a","a",""]"#),
        ("\"aaaa\" | split(\"aa\")", #"["","",""]"#),
        ("\"é😀é\" | indices(\"é\")", "[0,2]"),
        ("[1, 2, 1, 2, 1] | indices([1, 2, 1])", "[0,2]"),
        ("\"x😀ab😀ab\" | [match(\"ab\"; \"g\") | .offset]", "[2,5]"),
        ("\"foobar\" | contains(\"oba\")", "true")
    ])
    func searchAnswers(filter: String, expected: String) async {
        #expect(await runNull(filter).output == expected + "\n")
    }

    @Test("JQ.parse refuses deep JSON, since it runs on the caller's stack")
    func parseDepth() throws {
        let deep = String(repeating: "[", count: 300) + String(repeating: "]", count: 300)
        #expect(throws: JQError.self) { try JQ.parse(deep) }
        let allowed = String(repeating: "[", count: 200) + String(repeating: "]", count: 200)
        _ = try JQ.parse(allowed)
    }
}

@Suite("jq command limits")
struct JQCommandLimitsTests {
    @Test("the files of one run are held together to the file limit")
    func totalInput() async throws {
        let record = String(repeating: "1", count: 40)
        let driver = try InMemoryDriver(texts: ["a.json": record, "b.json": record, "c.json": record])
        let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "kb", driver: driver)])
        let shell = CommandInterpreter(fileSystem: fileSystem, commands: [JQCommand(maxFileBytes: 100)])
        let result = await shell.run("jq length kb/a.json kb/b.json kb/c.json")
        #expect(result.exitCode == 2)
        #expect(result.output.contains("the files add up to more than 100 bytes"))
        #expect(await shell.run("jq -c . kb/a.json kb/b.json").exitCode == 0)
    }

    @Test("unreadable files are reported on standard error, not passed down a pipe")
    func errorsStayOutOfThePipe() async throws {
        let driver = try InMemoryDriver(texts: ["a.json": "[1,2]"])
        let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "kb", driver: driver)])
        let shell = CommandInterpreter(fileSystem: fileSystem, commands: StandardCommands.all + [JQCommand()])
        let result = await shell.run("jq -c '.[]' kb/a.json kb/missing.json | wc -l")
        #expect(result.output.hasSuffix("2"))
        #expect(result.output.contains("Could not open kb/missing.json"))
    }
}
