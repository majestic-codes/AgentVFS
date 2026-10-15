//
//  JQRegressionTests.swift
//  AgentVFSJQTests
//
//  Created by Yevhenii Kalashnikov on 15.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import Foundation
import Testing
@testable import AgentVFSJQ

/// Runs `filter` with `-n -c` and the options `configure` sets.
private func runNull(_ filter: String, configure: (inout JQ.Options) -> Void = { _ in }) async -> JQ.Result {
    var options = JQ.Options()
    options.nullInput = true
    options.compactOutput = true
    configure(&options)
    return await JQ.run(filter: filter, inputs: [], options: options)
}

@Suite("jq numbers out of range")
struct JQRangeTests {
    @Test("broken-down times outside 32 bits are refused instead of trapping", arguments: [
        "[-1e300,0,0,0,0,0] | mktime",
        "[-1e300,0,0,0,0,0] | todate",
        "[1e300,0,0,0,0,0] | strftime(\"%Y\")",
        "[-1e300,0,0,0,0,0] | strflocaltime(\"%Y\")",
        "[2024,0,1e300,0,0,0] | mktime"
    ])
    func brokenDownTimes(filter: String) async {
        let result = await runNull(filter)
        #expect(result.exitCode == 5)
        #expect(result.output.contains("requires parsed datetime inputs"))
    }

    @Test("seconds the system cannot convert are an error", arguments: ["1e300 | gmtime", "1e300 | todate"])
    func unconvertibleSeconds(filter: String) async {
        let result = await runNull(filter)
        #expect(result.exitCode == 5)
        #expect(result.output.contains("error converting number of seconds since epoch to datetime"))
    }
}

@Suite("jq options")
struct JQOptionsTests {
    @Test("options no run can use are reported with exit status 2", arguments: [
        ("indent 8", "Cannot indent more than 7 characters"),
        ("indent -1", "Cannot indent less than 0 characters"),
        ("maxSteps 0", "maxSteps must be at least 1"),
        ("maxOutputBytes -1", "maxOutputBytes must not be negative"),
        ("timeout 0", "timeout must be positive"),
        ("maxMemoryGrowth 0", "maxMemoryGrowth must be at least 1")
    ])
    func invalidOptions(setting: String, message: String) async {
        let result = await runNull(".") { options in
            switch setting {
            case "indent 8": options.indent = 8
            case "indent -1": options.indent = -1
            case "maxSteps 0": options.maxSteps = 0
            case "maxOutputBytes -1": options.maxOutputBytes = -1
            case "timeout 0": options.timeout = .zero
            default: options.maxMemoryGrowth = 0
            }
        }
        #expect(result.exitCode == 2)
        #expect(result.output.contains(message))
    }

    @Test("evaluate runs with the options it is given")
    func evaluateOptions() throws {
        var options = JQ.Options()
        options.namedArguments = [("x", .int(41))]
        #expect(try JQ.evaluate("$x + 1", options: options) == [.int(42)])
        options.indent = 9
        #expect(throws: VFSError.self) { try JQ.evaluate(".", options: options) }
    }

    @Test("the command's output limit does not overflow with the largest output limits")
    func largestOutputLimit() async throws {
        let driver = try InMemoryDriver(texts: ["a.json": "[1]"])
        let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "kb", driver: driver)])
        let context = CommandContext(
            fileSystem: fileSystem,
            limits: OutputLimits(maxBytes: .max),
            workingDirectory: .root,
            commands: []
        )
        let arguments = [ShellToken(text: "-c"), ShellToken(text: "."), ShellToken(text: "/workspace/kb/a.json")]
        let output = try await JQCommand().run(arguments, in: context)
        #expect(output.text == "[1]\n")
    }
}

@Suite("jq literals and object construction")
struct JQLiteralTests {
    @Test("outputs match jq 1.7.1", arguments: [
        JQCase("1e1000", "null", "1E+1000"),
        JQCase("1e99999999999999999999", "null", "1.7976931348623157e+308"),
        JQCase("[1e1000000000, -1e1000]", "null", "[1.7976931348623157e+308,-1.7976931348623157e+308]"),
        JQCase("\"1e99999999999999999999\" | fromjson", "null", "1.7976931348623157e+308"),
        JQCase(".", "[1e99999999999999999999, 12345e999999995]", "[1.7976931348623157e+308,1.2345E+999999999]"),
        JQCase(#""\udc00""#, "null", #""\#u{FFFD}""#),
        JQCase(".", #""\udc00\ud83d\ude00""#, #""\#u{FFFD}😀""#),
        JQCase(
            #""\"\\ud800\"" | fromjson"#,
            "null",
            #"jq: error (at input.json:0): Invalid \uXXXX\uXXXX surrogate pair escape at line 1, column 8"#
                + #" (while parsing '"\ud800"')"#
        ),
        JQCase(".", #""\ud800x""#, #"jq: parse error: Invalid \uXXXX\uXXXX surrogate pair escape at line 1, column 9"#),
        JQCase(".", #""\u+041""#, #"jq: parse error: Invalid characters in \uXXXX escape at line 1, column 8"#),
        JQCase("\"z\" as $k | {$k: 1}", "null", #"{"z":1}"#),
        JQCase("\"z\" as $k | {$k}", "null", #"{"k":"z"}"#),
        JQCase("{a: -1 | 2, b: .x?, c: \"x\" | ascii_upcase}", "{}", #"{"a":2,"b":null,"c":"X"}"#),
        JQCase("{true: 1, if: 2}", "null", #"{"true":1,"if":2}"#)
    ])
    func outputs(_ test: JQCase) async {
        #expect(await runCompact(test.filter, input: test.input) == test.expected)
    }

    @Test("filters jq 1.7.1 does not compile", arguments: [
        #""\u+041""#,
        "{1: 2}",
        "{a: 1 + 2}",
        "{a: 1 // 2}",
        "{a: reduce empty as $x (0; .)}",
        "{a: if true then 1 else 2 end}",
        "{a: 1 as $x | 2}"
    ])
    func compileErrors(filter: String) async {
        #expect(await runCompact(filter, input: "null").contains("compile error"))
    }
}

@Suite("jq optional steps")
struct JQOptionalTests {
    @Test("? makes only the step before it optional, element by element", arguments: [
        JQCase("[.[].b?]", #"[1,{"b":2}]"#, "[2]"),
        JQCase("[.[][0]?]", "[1,[2]]", "[2]"),
        JQCase("[.[][]?]", #"[[1,2],"x",[3]]"#, "[1,2,3]"),
        JQCase("[.[][1:]?]", "[[1,2],3]", "[[2]]"),
        JQCase("[.[].b?.c?]", #"[1,{"b":2}]"#, "[]"),
        JQCase("[.[].a.b?]", #"[{"a":"x"},{"a":{"b":1}}]"#, "[1]"),
        JQCase("[path(.a[].b?)]", #"{"a":[1,{"b":2}]}"#, #"[["a",1,"b"]]"#),
        JQCase("[.c.d?]", "1", #"jq: error (at input.json:0): Cannot index number with string "c""#),
        JQCase("[.[.x]?]", "1", #"jq: error (at input.json:0): Cannot index number with string "x""#),
        JQCase("[(.[].b)?]", #"[1,{"b":2}]"#, "[]"),
        JQCase("[.[].b??]", #"[1,{"b":2}]"#, "[2]")
    ])
    func optionalSteps(_ test: JQCase) async {
        #expect(await runCompact(test.filter, input: test.input) == test.expected)
    }
}

@Suite("jq 1.7.1 divergences")
struct JQDivergenceTests {
    @Test("builtins match jq 1.7.1", arguments: [
        JQCase(
            "contains(false)",
            "true",
            "jq: error (at input.json:0): boolean (true) and boolean (false) cannot have their containment checked"
        ),
        JQCase("[contains(true), ([true] | contains([false]))]", "true", "[true,false]"),
        JQCase("del(.a[-5])", #"{"a":[1]}"#, #"{"a":[1]}"#),
        JQCase("delpaths([[-5]])", "[1]", "[1]"),
        JQCase("[.[] | @base64d]", #"["YWJj=ZGVm","YW=Jj","=YQ","YQ==="]"#, #"["abc","a","","a"]"#),
        JQCase("[test(\"a.b\"), test(\"a.b\"; \"s\"), test(\"^b\"; \"s\")]", "\"a\\rb\"", "[true,true,false]"),
        JQCase("[bsearch(2), bsearch(0), bsearch(4), bsearch(2.5)]", "[1,2,3]", "[1,-1,-4,-3]"),
        JQCase("[.[] | isfinite]", "[1,\"a\"]", "[true,false]"),
        JQCase("[infinite, nan] | map(isfinite)", "null", "[false,true]"),
        JQCase("JOIN({\"1\": \"x\"}; .[0] | tostring)", "[[1,2]]", #"[[[1,2],"x"]]"#),
        JQCase("[JOIN({\"1\": \"x\"}; .[]; .[0] | tostring; .[1])]", "[[1],[2]]", #"["x",null]"#),
        JQCase("[remainder(5; 3), remainder(-5; 3)]", "null", "[-1,1]")
    ])
    func builtins(_ test: JQCase) async {
        #expect(await runCompact(test.filter, input: test.input) == test.expected)
    }

    @Test("?// goes on to the next pattern when a later filter fails, as jq backtracks")
    func destructuringAlternatives() async {
        let filter = #"try ((.[] as [$a] ?// $a | $a) | if type == "number" then error("down") else . end) catch ."#
        #expect(await runCompact(filter, input: "[[1]]") == "[1]")
        let foreach = #"try (foreach ([1], [2]) as [$a] ?// $a (0; . + $a) | error("down")) catch ."#
        #expect(await runCompact(foreach, input: "null") == #""number (1) and array ([1]) cannot be added""#)
    }

    @Test("the l regex modifier is refused rather than ignored")
    func longestMatch() async {
        let output = await runCompact("test(\"a+\"; \"l\")", input: "\"aa\"")
        #expect(output.contains("the l (longest match) regex modifier is not supported"))
    }

    @Test("input_line_number and error locations count lines as jq reads them")
    func lineNumbers() async {
        #expect(await runCompact("[., input_line_number]", input: "1\n2\n\n3 4") == "[1,1]\n[2,2]\n[3,3]\n[4,3]")
        let failure = await runCompact(".a", input: "[]\n\n{\"a\":1}")
        #expect(failure == "jq: error (at input.json:1): Cannot index array with string \"a\"\n1")
    }
}

@Suite("jq recursion")
struct JQRecursionTests {
    @Test("recurse, repeat, while and until follow jq's recursive definitions lazily", arguments: [
        JQCase("[1 | until(. > 3, true; . + 1)]", "null", "[4,4,3,2,1]"),
        JQCase("[1 | while(. < 3, . < 2; . + 1)]", "null", "[1,2,1,2]"),
        JQCase("[limit(5; 0 | recurse(., . + 1))]", "null", "[0,0,0,0,0]"),
        JQCase("[limit(2; 0 | recurse(., error(\"x\")))]", "null", "[0,0]"),
        JQCase("[limit(5; recurse(range(infinite)))]", "null", "[null,0,0,0,0]"),
        JQCase("[limit(3; [1] | recurse(.[0] + 1 | [.]))]", "null", "[[1],[2],[3]]"),
        JQCase("first(1 | repeat(. + 1, error(\"x\")))", "null", "2"),
        JQCase("0 | until(. > 200000; . + 1)", "null", "200001"),
        JQCase("[limit(1000000; repeat(1))] | length", "null", "1000000")
    ])
    func recursion(_ test: JQCase) async {
        #expect(await runCompact(test.filter, input: test.input) == test.expected)
    }
}

@Suite("jq memory budget")
struct JQMemoryTests {
    @Test("a large input is parsed under the memory limit")
    func largeInput() async {
        let objects = Array(repeating: #"{"a":1,"b":"x"}"#, count: 400_000).joined(separator: ",")
        var options = JQ.Options()
        options.maxMemoryGrowth = 50 << 20
        let input = JQ.Input(name: "big.json", text: "[" + objects + "]")
        let result = await JQ.run(filter: "length", inputs: [input], options: options)
        #expect(result.exitCode == 5)
        #expect(result.output.contains("memory limit of 50 MB"))
    }

    @Test("the parser refuses arrays and objects past the size limit", arguments: [
        ("[1,2,3,4]", "Array too large (more than 3 elements)"),
        (#"{"a":1,"b":2,"c":3,"d":4}"#, "Object too large (more than 3 keys)")
    ])
    func containerCounts(text: String, message: String) throws {
        var parser = JSONStreamParser(text, maxCount: 3)
        #expect(throws: JSONParseError.self) { _ = try parser.next() }
        var again = JSONStreamParser(text, maxCount: 3)
        do {
            _ = try again.next()
        } catch let error as JSONParseError {
            #expect(error.message.hasPrefix(message))
        }
    }

    @Test("JQ.parse reads objects nested to its depth limit on the caller's stack")
    func deepObjects() throws {
        let depth = JQ.maxParseDepth - 1
        let text = String(repeating: #"{"a":"#, count: depth) + "1" + String(repeating: "}", count: depth)
        _ = try JQ.parse(text)
    }

    @Test("a value that cannot fit is refused before it is built")
    func reservation() throws {
        var options = JQ.Options()
        options.maxMemoryGrowth = 10 << 20
        let budget = Budget(options, cancellation: nil)
        try budget.reserve(1 << 20)
        #expect(throws: JQAbort.self) { try budget.reserve(100 << 20) }
    }

    @Test("builtins that build large values reserve their memory first", arguments: [
        "[range(3000000)] | to_entries | length",
        "[range(3000000)] | sort | length",
        "[range(3000000)] | group_by(.) | length"
    ])
    func largeBuiltins(filter: String) async {
        let result = await runNull(filter) { $0.maxMemoryGrowth = 32 << 20 }
        #expect(result.exitCode == 5)
        #expect(result.output.contains("memory limit"))
    }
}

@Suite("jq public errors")
struct JQPublicErrorTests {
    @Test("evaluate tells compile errors, runtime errors, limits and halts apart")
    func errorKinds() throws {
        #expect(throws: JQCompileError.self) { try JQ.evaluate("[1, 2") }
        #expect(throws: JQError.self) { try JQ.evaluate("error(\"x\")") }
        var options = JQ.Options()
        options.maxSteps = 10
        #expect(throws: JQAbort.self) { try JQ.evaluate("last(range(100))", options: options) }
        #expect(throws: JQHalt.self) { try JQ.evaluate("halt") }
    }

    @Test("Result can be made by callers")
    func result() {
        let result = JQ.Result(output: "1\n", exitCode: 0, truncated: false)
        #expect(result.output == "1\n")
    }
}

@Suite("jq values larger than their storage")
struct JQSharedValueTests {
    /// An array whose two halves are the same storage, nested 40 deep: 2^40 leaves in 40 arrays.
    static let shared = "(reduce range(40) as $i ([1]; [., .])) as $v | "

    @Test("walks over a shared value stop at the time limit", arguments: [
        "$v == $v",
        "[$v, $v] | sort | length",
        "[$v, $v] | unique | length",
        "[$v, $v] | group_by(.) | length",
        "[$v, $v] | min | length",
        "[$v] | index([$v])",
        "[$v] | contains([$v])",
        "[$v] - [$v]",
        "[$v] | delpaths([[$v], [$v]])",
        "(reduce range(40) as $i ({}; {a: ., b: .})) as $o | $o * $o | length",
        "$v | flatten | length",
        "$v | tojson | length",
        "[$v | tostream] | length"
    ])
    func sharedValues(filter: String) async {
        let clock = ContinuousClock()
        let started = clock.now
        let result = await runNull(Self.shared + filter) { options in
            options.timeout = .seconds(1)
            options.maxSteps = .max
        }
        #expect(result.exitCode == 5)
        let stopped = ["time limit", "too large", "memory limit"].contains { result.output.contains($0) }
        #expect(stopped, "\(result.output.prefix(300))")
        #expect(clock.now - started < .seconds(20))
    }

    @Test("cancelling stops a comparison of shared values")
    func cancelledComparison() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let task = Task {
            await runNull(Self.shared + "$v == $v") { $0.maxSteps = .max }
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = await task.value
        #expect(result.output.contains("jq was stopped"))
        #expect(clock.now - started < .seconds(20))
    }

    @Test("repeating the empty string any number of times gives the empty string")
    func emptyRepeat() async {
        #expect(await runNull("\"\" * 1e18") == JQ.Result(output: "\"\"\n", exitCode: 0, truncated: false))
    }
}
