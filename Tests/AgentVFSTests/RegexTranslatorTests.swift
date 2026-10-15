//
//  RegexTranslatorTests.swift
//  AgentVFSTests
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation
import Testing
@testable import AgentVFS

@Suite("PatternCompiler")
struct PatternCompilerTests {
    private func matches(
        _ pattern: String,
        _ syntax: PatternSyntax,
        in text: String,
        caseInsensitive: Bool = false,
        wholeWord: Bool = false
    ) throws -> Bool {
        let compiled = try PatternCompiler.compile(
            pattern,
            syntax: syntax,
            caseInsensitive: caseInsensitive,
            wholeWord: wholeWord
        )
        return compiled.matches(text)
    }

    private func compile(_ pattern: String, syntax: PatternSyntax) throws -> CompiledPattern {
        try PatternCompiler.compile(pattern, syntax: syntax, caseInsensitive: false, wholeWord: false)
    }

    @Test("fixed strings are literal")
    func fixed() throws {
        #expect(try matches("a.b(c)", .fixed, in: "xa.b(c)y"))
        #expect(try matches("a.b", .fixed, in: "axb") == false)
        #expect(try matches("[x]*", .fixed, in: "see [x]* here"))
    }

    @Test("basic syntax treats bare ( ) | + ? { } as literals")
    func basicLiterals() throws {
        #expect(try matches("func(", .basic, in: "func(a)"))
        #expect(try matches("a|b", .basic, in: "a|b"))
        #expect(try matches("a|b", .basic, in: "a") == false)
        #expect(try matches("a+", .basic, in: "a+"))
        #expect(try matches("a+", .basic, in: "aaa") == false)
        #expect(try matches("x{2}", .basic, in: "x{2}"))
    }

    @Test("basic syntax honours backslash operators")
    func basicOperators() throws {
        #expect(try matches("foo\\|bar", .basic, in: "bar"))
        #expect(try matches("foo\\|bar", .basic, in: "foo"))
        #expect(try matches("foo\\|bar", .basic, in: "baz") == false)
        #expect(try matches("\\(ab\\)\\{2\\}", .basic, in: "abab"))
        #expect(try matches("a\\+", .basic, in: "aaa"))
        #expect(try matches("colou\\?r", .basic, in: "color"))
    }

    @Test("basic star, anchors, classes and word boundaries")
    func basicCommon() throws {
        #expect(try matches("^class .*Manager", .basic, in: "class SyncManager {"))
        #expect(try matches("^class", .basic, in: "  class") == false)
        #expect(try matches("end$", .basic, in: "the end"))
        #expect(try matches("[[:digit:]]\\{3\\}", .basic, in: "ab123"))
        #expect(try matches("\\<sync\\>", .basic, in: "do sync now"))
        #expect(try matches("\\<sync\\>", .basic, in: "async") == false)
        #expect(try matches("*star", .basic, in: "*star"))
        #expect(try matches("a.c", .basic, in: "abc"))
    }

    @Test("extended syntax is regex")
    func extended() throws {
        #expect(try matches("foo|bar", .extended, in: "bar"))
        #expect(try matches("(ab)+c", .extended, in: "ababc"))
        #expect(try matches("x{2,3}", .extended, in: "xx"))
        #expect(try matches("\\bSync\\w+", .extended, in: "use SyncQueue"))
        #expect(try matches("\\<sync\\>", .extended, in: "do sync now"))
    }

    @Test("case and whole word")
    func options() throws {
        #expect(try matches("SYNC", .fixed, in: "sync", caseInsensitive: true))
        #expect(try matches("SYNC", .fixed, in: "sync") == false)
        #expect(try matches("sync", .fixed, in: "sync()", wholeWord: true))
        #expect(try matches("sync", .fixed, in: "async", wholeWord: true) == false)
        #expect(try matches("sync|run", .extended, in: "run", wholeWord: true))
        #expect(try matches("sync|run", .extended, in: "rerun", wholeWord: true) == false)
    }

    @Test("invalid patterns are reported")
    func invalid() {
        #expect(throws: VFSError.self) { try compile("(", syntax: .extended) }
        #expect(throws: VFSError.self) { try compile("", syntax: .fixed) }
        let tooLong = String(repeating: "a", count: 5000)
        #expect(throws: VFSError.self) { try compile(tooLong, syntax: .fixed) }
    }

    @Test("range of the first match")
    func matchRange() throws {
        let compiled = try compile("Sync[A-Za-z]+", syntax: .extended)
        #expect(compiled.firstMatchColumn(in: "use SyncQueue now") == 5)
        #expect(compiled.firstMatchColumn(in: "nothing") == nil)
    }
}

extension CompiledPattern {
    /// 1-based column of the first match, or `nil`.
    func firstMatchColumn(in line: String) -> Int? {
        guard let range = firstMatchRange(in: line) else { return nil }
        return line.distance(from: line.startIndex, to: range.lowerBound) + 1
    }
}
