//
//  JQTests.swift
//  AgentVFSJQTests
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import Testing
@testable import AgentVFSJQ

@Suite("jq engine")
struct JQEngineTests {

    private func run(
        _ filter: String,
        _ input: String? = nil,
        configure: (inout JQ.Options) -> Void = { _ in }
    ) async -> JQ.Result {
        var options = JQ.Options()
        if input == nil { options.nullInput = true }
        configure(&options)
        let inputs = input.map { [JQ.Input(name: "in.json", text: $0)] } ?? []
        return await JQ.run(filter: filter, inputs: inputs, options: options)
    }

    @Test("pretty-prints like jq by default")
    func prettyPrint() async {
        let result = await run(".", #"{"a":[1,{"b":null}],"c":{},"d":[]}"#)
        #expect(result.output == """
        {
          "a": [
            1,
            {
              "b": null
            }
          ],
          "c": {},
          "d": []
        }

        """)
        #expect(result.exitCode == 0)
    }

    @Test("output options: tab, indent, sort keys, raw, join, ascii")
    func outputOptions() async {
        #expect(await run(".", #"{"a":[1]}"#) { $0.tab = true }.output == "{\n\t\"a\": [\n\t\t1\n\t]\n}\n")
        #expect(await run(".", #"{"a":[1]}"#) { $0.indent = 1 }.output == "{\n \"a\": [\n  1\n ]\n}\n")
        let sorted = await run(".", #"{"b":1,"a":{"d":1,"c":2}}"#) { options in
            options.sortKeys = true
            options.compactOutput = true
        }
        #expect(sorted.output == #"{"a":{"c":2,"d":1},"b":1}"# + "\n")
        #expect(await run(".[]", #"["a\nb",1,null]"#) { $0.rawOutput = true }.output == "a\nb\n1\nnull\n")
        #expect(await run(".[]", #"["a","b",1]"#) { $0.joinOutput = true }.output == "ab1")
        let ascii = await run(".", #"["é😀"]"#) { options in
            options.asciiOutput = true
            options.compactOutput = true
        }
        #expect(ascii.output == #"["\u00e9\ud83d\ude00"]"# + "\n")
    }

    @Test("numbers keep their literal form until arithmetic touches them")
    func numberLiterals() async {
        let literals = "[1.0, 1.50, 1e3, 100000000000000000000, 0.00001, -0]"
        let result = await run(".[]", literals) { $0.compactOutput = true }
        #expect(result.output == "1.0\n1.50\n1E+3\n100000000000000000000\n0.00001\n-0\n")
        let operands = "[1.0, 1.50, 1e3, 1e17, 0.00001, 1e-7, 123456789012]"
        let computed = await run("map(. * 1)", operands) { $0.compactOutput = true }
        #expect(computed.output == "[1,1.5,1000,1e+17,1e-05,1e-07,123456789012]\n")
        #expect(await run("[0.1 + 0.2, 1 / 3, infinite, -infinite, nan]") { $0.compactOutput = true }.output
            == "[0.30000000000000004,0.3333333333333333,1.7976931348623157e+308,-1.7976931348623157e+308,null]\n")
    }

    @Test("inputs: streams of values, slurp, raw input, null input with input/inputs")
    func inputs() async {
        #expect(await run(".a", "{\"a\":1}\n{\"a\":2} {\"a\":3}").output == "1\n2\n3\n")
        let slurped = await run(".", "1 2 3") { options in
            options.slurp = true
            options.compactOutput = true
        }
        #expect(slurped.output == "[1,2,3]\n")
        #expect(await run(".", "one\ntwo\n") { $0.rawInput = true }.output == "\"one\"\n\"two\"\n")
        let rawSlurped = await run(".", "one\ntwo\n") { options in
            options.rawInput = true
            options.slurp = true
        }
        #expect(rawSlurped.output == "\"one\\ntwo\\n\"\n")
        var nullOptions = JQ.Options()
        nullOptions.nullInput = true
        nullOptions.compactOutput = true
        let streams = [JQ.Input(name: "a", text: "1 2"), JQ.Input(name: "b", text: "3")]
        let null = await JQ.run(filter: "[inputs]", inputs: streams, options: nullOptions)
        #expect(null.output == "[1,2,3]\n")
        #expect(await run("[., input]", "1 2 3 4") { $0.compactOutput = true }.output == "[1,2]\n[3,4]\n")
        let streamed = await run(".", #"{"a":[1,2]}"#) { options in
            options.stream = true
            options.compactOutput = true
        }
        #expect(streamed.output == "[[\"a\",0],1]\n[[\"a\",1],2]\n[[\"a\",1]]\n[[\"a\"]]\n")
    }

    @Test("named and positional arguments")
    func arguments() async {
        let result = await run("[$x, $y, $ARGS.named, $ARGS.positional]") {
            $0.compactOutput = true
            $0.namedArguments = [("x", .string("1")), ("y", .int(2))]
            $0.positionalArguments = [.string("p")]
        }
        #expect(result.output == #"["1",2,{"x":"1","y":2},["p"]]"# + "\n")
    }

    @Test("exit status: errors, -e, halt and halt_error")
    func exitStatus() async {
        #expect(await run(".a", #"{"a":false}"#) { $0.exitStatus = true }.exitCode == 1)
        #expect(await run(".a", #"{"a":1}"#) { $0.exitStatus = true }.exitCode == 0)
        #expect(await run("empty", "1") { $0.exitStatus = true }.exitCode == 4)
        let failure = await run(".a", "[1]")
        #expect(failure.output == "jq: error (at in.json:0): Cannot index array with string \"a\"\n")
        #expect(failure.exitCode == 5)
        let custom = await run("error({\"code\": 1})")
        #expect(custom.output == "jq: error (at <unknown>) (not a string): {\"code\":1}\n")
        #expect(await run("1, halt, 2").output == "1\n")
        let halted = await run("\"bye\\n\" | halt_error(3)")
        #expect(halted.output == "bye\n")
        #expect(halted.exitCode == 3)
    }

    @Test("an error in one input does not stop the next")
    func errorsPerInput() async {
        let result = await run(".a", "{\"a\":1}\n[]\n{\"a\":3}")
        #expect(result.output == "1\njq: error (at in.json:2): Cannot index array with string \"a\"\n3\n")
    }

    @Test("compile errors are reported with exit status 3")
    func compileErrors() async {
        let undefined = await run("foo(1)")
        #expect(undefined.exitCode == 3)
        #expect(undefined.output.contains("foo/1 is not defined"))
        #expect(await run(".a | $nope").output.contains("$nope is not defined"))
        #expect(await run("[1, 2").output.contains("syntax error"))
        #expect(await run("break $x").output.contains("$*label-x is not defined"))
    }

    @Test("invalid JSON input is a parse error")
    func parseErrors() async {
        let result = await run(".", "{\"a\":1} {\"a\":")
        let parseError = "jq: parse error: Unfinished JSON term at EOF at line 1, column 13\n"
        #expect(result.output == "{\n  \"a\": 1\n}\n" + parseError)
        #expect(result.exitCode == 5)
    }

    @Test("runaway programs are stopped instead of hanging or crashing")
    func budgets() async {
        // A step budget small enough to run out long before the time limit, however loaded the machine.
        let infinite = await run("last(range(infinite))") { $0.maxSteps = 100_000 }
        #expect(infinite.exitCode == 5)
        #expect(infinite.output.contains("evaluation budget of 100000 steps"))
        let endless = await run("[range(infinite)]")
        #expect(endless.exitCode == 5)
        let limits = ["Array too large", "memory limit", "time limit"]
        #expect(limits.contains { endless.output.contains($0) })
        #expect(await run("[limit(5; repeat(1))]") { $0.compactOutput = true }.output == "[1,1,1,1,1]\n")
        #expect(await run("first(range(1e12))").output == "0\n")
        let deep = await run("def f: 1 + f; f")
        #expect(deep.exitCode == 5)
        #expect(deep.output.contains("nests too deeply"))
        #expect(await run("reduce range(40) as $i (\"x\"; . + .)").output.contains("String too large"))
        let deepFilter = "reduce range(300) as $i (1; [.]) | tojson | contains(\"<skipped: too deep>\")"
        #expect(await run(deepFilter).output == "true\n")
        let flood = await run("repeat(\"x\")") { $0.maxOutputBytes = 1000 }
        #expect(flood.truncated)
        #expect(flood.output.utf8.count < 1100)
    }

    @Test("evaluate returns values")
    func evaluate() throws {
        let input = try JQ.parse(#"{"a":1}"#)
        #expect(try JQ.evaluate(".a + 1", input: input) == [.int(2)])
        #expect(try JQ.evaluate("1, 2") == [.int(1), .int(2)])
    }
}

@Suite("jq command")
struct JQCommandTests {

    private func shell(_ files: [String: String]) throws -> CommandInterpreter {
        let driver = try InMemoryDriver(texts: files)
        let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "kb", driver: driver)])
        return CommandInterpreter(fileSystem: fileSystem, commands: [JQCommand()])
    }

    private let data = #"{"users":[{"name":"ann","age":31,"tags":["a"]},{"name":"bob","age":25,"tags":[]}]}"#

    @Test("reads workspace files and prints results")
    func basics() async throws {
        let shell = try shell(["data.json": data, "lines.jsonl": "{\"n\":1}\n{\"n\":2}\n"])
        #expect(await shell.run("jq -r '.users[].name' /workspace/kb/data.json").output == "ann\nbob")
        #expect(await shell.run("jq -c '.users | map(select(.age > 30) | .name)' kb/data.json").output == #"["ann"]"#)
        #expect(await shell.run("jq '.users[0].age' kb/data.json").output == "31")
        #expect(await shell.run("jq -c '.n' kb/lines.jsonl").output == "1\n2")
        #expect(await shell.run("jq -s -c 'map(.n) | add' kb/lines.jsonl").output == "3")
        #expect(await shell.run("jq -c '.users[1]' kb/data.json").output == #"{"name":"bob","age":25,"tags":[]}"#)
        _ = await shell.run("cd kb")
        #expect(await shell.run("jq -rc '.users[] | [.name, .age] | @tsv' data.json").output == "ann\t31\nbob\t25")
    }

    @Test("reads JSON from a pipe and feeds other filters")
    func pipeline() async throws {
        let shell = try shell(["data.json": data, "lines.jsonl": "{\"n\":1}\n{\"n\":2}\n"])
        #expect(await shell.run("cat kb/data.json | jq -r '.users[].name'").output == "ann\nbob")
        #expect(await shell.run("grep 2 kb/lines.jsonl | jq '.n'").output == "2")
        #expect(await shell.run("jq -r '.users[] | .name' kb/data.json | sort -r | head -1").output == "bob")
        #expect(await shell.run("jq -c '.users[]' kb/data.json | wc -l").output == "2")
    }

    @Test("options: --arg, --argjson, -n, -e, --slurpfile, --rawfile, -f")
    func options() async throws {
        let shell = try shell(["data.json": data, "filter.jq": ".users | length", "names.txt": "x\ny\n"])
        let byName = await shell.run("jq --arg who bob -c '.users[] | select(.name == $who) | .age' kb/data.json")
        #expect(byName.output == "25")
        let byAge = await shell.run("jq --argjson min 30 -c '[.users[] | select(.age >= $min) | .name]' kb/data.json")
        #expect(byAge.output == #"["ann"]"#)
        #expect(await shell.run("jq -n '1 + 2'").output == "3")
        #expect(await shell.run("jq -e '.missing' kb/data.json").exitCode == 1)
        #expect(await shell.run("jq -n -c --slurpfile d kb/data.json '$d[0].users | length'").output == "2")
        #expect(await shell.run("jq -n --rawfile t kb/names.txt '$t | split(\"\\n\") | length'").output == "3")
        #expect(await shell.run("jq -f kb/filter.jq kb/data.json").output == "2")
        #expect(await shell.run("jq -n -c '$ARGS.positional' --args a b").output == #"["a","b"]"#)
    }

    @Test("errors: missing files, no input, bad filters, runtime errors")
    func errors() async throws {
        let shell = try shell(["data.json": data, "bad.json": "{oops"])
        let missing = await shell.run("jq . kb/missing.json")
        #expect(missing.exitCode == 2)
        #expect(missing.output.hasPrefix("jq: error: Could not open kb/missing.json"))
        let noInput = await shell.run("jq .")
        #expect(noInput.exitCode == 2)
        #expect(noInput.output.contains("no input"))
        let compile = await shell.run("jq '.users | mapp(.name)' kb/data.json")
        #expect(compile.exitCode == 3)
        #expect(compile.output.contains("mapp/1 is not defined"))
        let runtime = await shell.run("jq '.users[0].name + 1' kb/data.json")
        #expect(runtime.exitCode == 5)
        #expect(runtime.output == #"jq: error (at kb/data.json:0): string ("ann") and number (1) cannot be added"#)
        let parse = await shell.run("jq . kb/bad.json")
        #expect(parse.exitCode == 5)
        #expect(parse.output.hasPrefix("jq: parse error:"))
        #expect(await shell.run("jq --bogus . kb/data.json").exitCode == 2)
    }

    @Test("is listed in help and long output is truncated by the interpreter")
    func integration() async throws {
        let driver = try InMemoryDriver(texts: ["a.json": "[]"])
        let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "kb", driver: driver)])
        let limits = OutputLimits(maxBytes: 200, maxLines: 10)
        let shell = CommandInterpreter(fileSystem: fileSystem, limits: limits, commands: [JQCommand()])
        let help = await CommandInterpreter(fileSystem: fileSystem, commands: [JQCommand()]).run("help")
        #expect(help.output.contains("jq [-rcjsnReS]"))
        #expect(await shell.commandNames.contains("jq"))
        let long = await shell.run("jq -n 'range(1000)'")
        #expect(long.truncated)
    }
}

@Suite("jq on large files")
struct JQLargeFileTests {
    @Test("files over the whole-read limit are parsed up to jq's own limit")
    func large() async throws {
        let json = "[" + (0..<2000).map { #"{"id":\#($0),"ok":\#($0.isMultiple(of: 2))}"# }.joined(separator: ",") + "]"
        let driver = try InMemoryDriver(texts: ["big.json": json])
        let fileSystem = try WorkspaceFileSystem(
            mounts: [WorkspaceMount(name: "d", driver: driver)],
            limits: VFSLimits(maxReadBytes: 1_000)
        )
        let shell = CommandInterpreter(fileSystem: fileSystem, commands: [JQCommand()])
        #expect(await shell.run("jq '[.[] | select(.ok)] | length' d/big.json").output == "1000")
        #expect(await shell.run("cat d/big.json").exitCode == 1)

        let small = CommandInterpreter(fileSystem: fileSystem, commands: [JQCommand(maxFileBytes: 1_000)])
        #expect(await small.run("jq length d/big.json").output.contains("too large"))
    }
}
