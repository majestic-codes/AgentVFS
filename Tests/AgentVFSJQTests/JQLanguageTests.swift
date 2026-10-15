//
//  JQLanguageTests.swift
//  AgentVFSJQTests
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Testing
@testable import AgentVFSJQ

/// One filter run with `jq -c` on one input. Expected outputs come from jq 1.7.1.
struct JQCase: Sendable, CustomTestStringConvertible {
    let filter: String
    let input: String
    let expected: String

    init(_ filter: String, _ input: String, _ expected: String) {
        self.filter = filter
        self.input = input
        self.expected = expected
    }

    var testDescription: String { filter }
}

func runCompact(_ filter: String, input: String) async -> String {
    var options = JQ.Options()
    options.compactOutput = true
    let result = await JQ.run(filter: filter, inputs: [JQ.Input(name: "input.json", text: input)], options: options)
    return String(result.output.dropLast(result.output.hasSuffix("\n") ? 1 : 0))
}

@Suite("jq language")
struct JQLanguageTests {
    @Test("paths and indexing", arguments: indexingCases)
    func indexing(_ test: JQCase) async {
        #expect(await runCompact(test.filter, input: test.input) == test.expected)
    }

    @Test("operators", arguments: operatorsCases)
    func operators(_ test: JQCase) async {
        #expect(await runCompact(test.filter, input: test.input) == test.expected)
    }

    @Test("construction", arguments: constructionCases)
    func construction(_ test: JQCase) async {
        #expect(await runCompact(test.filter, input: test.input) == test.expected)
    }

    @Test("conditionals and errors", arguments: errorsCases)
    func errors(_ test: JQCase) async {
        #expect(await runCompact(test.filter, input: test.input) == test.expected)
    }

    @Test("variables and functions", arguments: functionsCases)
    func functions(_ test: JQCase) async {
        #expect(await runCompact(test.filter, input: test.input) == test.expected)
    }

    @Test("paths and assignment", arguments: assignmentCases)
    func assignment(_ test: JQCase) async {
        #expect(await runCompact(test.filter, input: test.input) == test.expected)
    }

    @Test("builtins on values", arguments: builtinsCases)
    func builtins(_ test: JQCase) async {
        #expect(await runCompact(test.filter, input: test.input) == test.expected)
    }

    @Test("math", arguments: mathCases)
    func math(_ test: JQCase) async {
        #expect(await runCompact(test.filter, input: test.input) == test.expected)
    }

    @Test("dates", arguments: datesCases)
    func dates(_ test: JQCase) async {
        #expect(await runCompact(test.filter, input: test.input) == test.expected)
    }
}
