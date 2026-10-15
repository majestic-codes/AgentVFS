//
//  JQCrossCheckTests.swift
//  AgentVFSJQTests
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

#if os(macOS)
import AgentVFS
import Foundation
import Testing
@testable import AgentVFSJQ

/// Compares this implementation with a real `jq` binary, filter by filter.
///
/// Off by default. `JQ_CROSSCHECK=/path/to/filters.txt swift test --filter JQCrossCheck` runs every
/// line of the file as `jq -nc FILTER` and reports the lines whose output differs.
@Suite("jq cross-check")
struct JQCrossCheckTests {
    static let isCrossCheckEnabled = ProcessInfo.processInfo.environment["JQ_CROSSCHECK"] != nil

    @Test("matches the jq binary", .enabled(if: isCrossCheckEnabled))
    func crossCheck() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["JQ_CROSSCHECK"])
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        let filters = contents.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        var mismatches: [String] = []
        for filter in filters {
            let expected = try reference(filter)
            var options = JQ.Options()
            options.nullInput = true
            options.compactOutput = true
            let actual = await JQ.run(filter: filter, inputs: [], options: options)
            if normalize(actual.output) != normalize(expected) {
                mismatches.append("\(filter)\n   jq:   \(normalize(expected))\n   ours: \(normalize(actual.output))")
            }
        }
        if !mismatches.isEmpty {
            let report = "\(mismatches.count) of \(filters.count) differ:\n" + mismatches.joined(separator: "\n")
            Issue.record(Comment(rawValue: report))
        }
    }

    /// `JQ_EVAL='FILTER' swift test --filter JQCrossCheck` prints this implementation's output.
    @Test("evaluates one filter", .enabled(if: ProcessInfo.processInfo.environment["JQ_EVAL"] != nil))
    func evaluate() async throws {
        var options = JQ.Options()
        options.nullInput = true
        options.compactOutput = true
        let filter = try #require(ProcessInfo.processInfo.environment["JQ_EVAL"])
        let result = await JQ.run(filter: filter, inputs: [], options: options)
        print("JQ_EVAL exit \(result.exitCode):\n\(result.output)")
    }

    /// Compile errors compare as one marker. Runtime errors compare by message.
    private func normalize(_ text: String) -> String {
        if text.contains("compile error") { return "COMPILE ERROR" }
        // jq writes errors to stderr, so their position relative to outputs is not reliable.
        let lines = text.split(separator: "\n").map(String.init).sorted { first, second in
            !first.hasPrefix("jq: error") && second.hasPrefix("jq: error")
        }
        return lines.joined(separator: " ")
    }

    private func reference(_ filter: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/jq")
        process.arguments = ["-nc", filter]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try #require(String(bytes: data, encoding: .utf8))
    }
}

extension JQCrossCheckTests {
    /// Command lines run both as `jq … in.json` and through `JQCommand` on the same file.
    static let commandCases: [(arguments: String, input: String)] = [
        (".", #"{"b":[1,2,{"c":null}],"a":"x","e":{},"f":[]}"#),
        ("--tab .", #"{"a":[1,{"b":2}]}"#),
        ("--indent 4 .", #"{"a":[1,{"b":2}]}"#),
        ("--indent 0 .", #"{"a":[1,{"b":2}]}"#),
        ("-S .", #"{"b":1,"a":{"d":1,"c":2}}"#),
        ("-c '.[]'", #"[1,"a",{"b":null}]"#),
        ("-r '.[]'", #"["a\nb","c",1,null,{"d":"e"}]"#),
        ("-j '.[]'", #"["a","b",1]"#),
        ("-a .", #"["é","😀","\u0001"]"#),
        ("-r -a '.[]'", #"["é"]"#),
        ("-s .", "1 2\n3"),
        ("-s -c 'map(. * 2)'", "1 2 3"),
        ("-n '[inputs]'", "1 2 3"),
        ("-n 'input, input'", "1 2 3"),
        ("-c '[., input]'", "1 2 3 4"),
        ("-R .", "line one\nline two\n"),
        ("-R -s .", "line one\nline two\n"),
        ("-R -r 'ascii_upcase'", "a\nb\n"),
        ("-e '.a'", #"{"a":false}"#),
        ("-e '.a'", #"{"a":1}"#),
        ("-e 'empty'", "1"),
        ("--arg x 5 '{x: $x}'", "null"),
        ("--argjson x '{\"a\":1}' '$x.a'", "null"),
        ("--arg a 1 --argjson b 2 -c '$ARGS'", "null"),
        ("-c --stream .", #"{"a":[1,2]}"#),
        ("-c 'tostream'", #"{"a":[1,{"b":2}]}"#),
        (".a", "{\"a\":1}\n{\"a\":2}\n[]\n{\"a\":3}"),
        ("'.[0]'", #"{"a":1}"#),
        ("'.a.b.c'", #"{"a":{"b":"x"}}"#),
        ("-c 'error(\"custom\")'", "1"),
        ("-c 'error({\"a\":1})'", "1"),
        ("-c '.[] | numbers'", #"[1,"a",2.50,1.0,1e3,100000000000000000000,0.1]"#),
        ("-c '.[] | . + 0'", #"[1,2.50,1.0,1e3,100000000000000000000,0.1,1e-7]"#),
        ("'halt_error'", #""bye\n""#),
        ("-c 'halt_error(1)'", #"{"a":1}"#),
        ("'.[] | if . > 1 then halt else . end'", "[1,2,3]"),
        ("-r '@csv'", #"[1,"a,b","c\"d",null,true]"#),
        ("-r '@tsv'", #"[1,"a\tb",null]"#),
        ("-r '.[] | @sh \"echo \\(.)\"'", #"["a b","it's"]"#),
        ("-c 'paths'", #"{"a":[1,{"b":2}]}"#),
        ("'.' ", "[1,[2,[3,[]]],{}]"),
        (".", "\"\\u0000\\u001f\\u007f\\u2028\\\\\\\"\\t\""),
        (".", "1.000 1e2 -0 0.0 1E-7 123456789012345678901234567890"),
        ("-c '.'", #"{"a":1,"a":2}"#),
        (".a", "{\"a\":1} {\"a\":"),
        (".", "[1,2"),
        ("'.[] | tostring'", #"[1,"a",[1],{"a":1.50}]"#)
    ]

    @Test("command lines match the jq binary", .enabled(if: isCrossCheckEnabled))
    func commandLines() async throws {
        let temporary = FileManager.default.temporaryDirectory
        let directory = temporary.appendingPathComponent("jq-crosscheck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record(error, "could not remove \(directory.path)")
            }
        }
        var mismatches: [String] = []
        for (arguments, input) in Self.commandCases {
            let file = directory.appendingPathComponent("in.json")
            try Data(input.utf8).write(to: file)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "/usr/bin/jq \(arguments) in.json 2>&1; echo \"exit $?\""]
            process.currentDirectoryURL = directory
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let expected = try #require(String(bytes: data, encoding: .utf8))

            let driver = try InMemoryDriver(texts: ["in.json": input])
            let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "kb", driver: driver)])
            let shell = CommandInterpreter(fileSystem: fileSystem, commands: [JQCommand()])
            _ = await shell.run("cd /workspace/kb")
            let result = await shell.run("jq \(arguments) in.json")
            let actual = result.output + "\nexit \(result.exitCode)\n"
            func clean(_ text: String) -> String {
                let renamed = text.replacingOccurrences(of: "<stdin>", with: "in.json")
                return renamed.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if clean(actual) != clean(expected) {
                let comparison = "--- jq:\n\(clean(expected))\n--- ours:\n\(clean(actual))"
                mismatches.append("jq \(arguments)  <<< \(input)\n" + comparison)
            }
        }
        if !mismatches.isEmpty {
            let summary = "\(mismatches.count) of \(Self.commandCases.count) differ:\n"
            let report = summary + mismatches.joined(separator: "\n\n")
            Issue.record(Comment(rawValue: report))
        }
    }
}
#endif
