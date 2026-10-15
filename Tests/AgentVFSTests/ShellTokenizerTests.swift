//
//  ShellTokenizerTests.swift
//  AgentVFSTests
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Testing
@testable import AgentVFS

@Suite("ShellTokenizer")
struct ShellTokenizerTests {
    private func words(_ line: String) throws -> [String] {
        try ShellTokenizer.tokenize(line).map(\.text)
    }

    @Test("splits on whitespace")
    func whitespace() throws {
        #expect(try words("grep  -rn   foo  /workspace") == ["grep", "-rn", "foo", "/workspace"])
        #expect(try words("   ls   ") == ["ls"])
        #expect(try words("").isEmpty)
        #expect(try words(" \t ").isEmpty)
    }

    @Test("single quotes are literal")
    func singleQuotes() throws {
        #expect(try words("grep 'foo bar' x") == ["grep", "foo bar", "x"])
        #expect(try words("grep '$HOME | ; > `x`' x") == ["grep", "$HOME | ; > `x`", "x"])
        #expect(try words("find . -name '*.swift'") == ["find", ".", "-name", "*.swift"])
    }

    @Test("double quotes allow escapes")
    func doubleQuotes() throws {
        #expect(try words(#"grep "foo bar" x"#) == ["grep", "foo bar", "x"])
        #expect(try words(#"grep "say \"hi\"" x"#) == ["grep", #"say "hi""#, "x"])
        #expect(try words(#"grep "a\\b" x"#) == ["grep", #"a\b"#, "x"])
        #expect(try words(#"grep "cost \$5" x"#) == ["grep", "cost $5", "x"])
        #expect(try words(#"grep "a|b" x"#) == ["grep", "a|b", "x"])
    }

    @Test("backslash escapes one character outside quotes")
    func backslash() throws {
        #expect(try words(#"grep foo\ bar x"#) == ["grep", "foo bar", "x"])
        #expect(try words(#"grep a\|b x"#) == ["grep", "a|b", "x"])
    }

    @Test("adjacent quoted and bare pieces join into one word")
    func joining() throws {
        #expect(try words(#"grep --include='*.swift' x"#) == ["grep", "--include=*.swift", "x"])
        #expect(try words(#"echo a"b c"d"#) == ["echo", "ab cd"])
    }

    @Test("only words that start with a quote count as quoted")
    func quotedMeansStartsWithQuote() throws {
        let tokens = try ShellTokenizer.tokenize(#"grep --include='*.kt' '-v' "-x" a'b'"#)
        #expect(tokens.map(\.isQuoted) == [false, false, true, true, false])
        #expect(tokens.map(\.text) == ["grep", "--include=*.kt", "-v", "-x", "ab"])
    }

    @Test("empty quotes make an empty word")
    func emptyWord() throws {
        let tokens = try ShellTokenizer.tokenize("grep '' x")
        #expect(tokens == [ShellToken(text: "grep"), ShellToken(text: "", isQuoted: true), ShellToken(text: "x")])
    }

    @Test("tokens remember whether they were quoted")
    func quotedFlag() throws {
        let tokens = try ShellTokenizer.tokenize("find . -name '*.swift' -type f")
        #expect(tokens.map(\.isQuoted) == [false, false, false, true, false, false])
    }

    @Test("shell operators are rejected with an explanation", arguments: [
        ("cat a || cat b", "chaining"),
        ("cat a && cat b", "chaining"),
        ("cat a & ", "chaining"),
        ("cat a; cat b", "sequencing"),
        ("cat a > out", "redirect"),
        ("cat a >> out", "redirect"),
        ("cat < a", "redirect"),
        ("cat $HOME", "expansion"),
        ("cat `pwd`", "expansion"),
        ("cat $(pwd)", "expansion"),
        (#"cat "$HOME""#, "expansion"),
        ("(cat a)", "subshell"),
        ("cat a\ncat b", "line")
    ])
    func rejectsOperators(line: String, keyword: String) throws {
        let error = try #require(throws: CommandError.self) { try ShellTokenizer.tokenize(line) }
        let message = try #require(Self.unsupportedMessage(error))
        #expect(message.lowercased().contains(keyword), "message was: \(message)")
    }

    @Test("shell syntax hidden in one character with a combining mark or CRLF is still rejected", arguments: [
        "cat a;\u{301} ls",
        "cat a\r\nls",
        "cat a >\u{301} b",
        "cat a # note"
    ])
    func rejectsHiddenOperators(line: String) {
        #expect(throws: CommandError.self) { try ShellTokenizer.pipeline(line) }
    }

    @Test("a # inside a word or quoted is literal")
    func literalHash() throws {
        #expect(try words("grep a#b '#x' \\#y") == ["grep", "a#b", "#x", "#y"])
    }

    @Test("splits a pipeline at unquoted bars")
    func pipeline() throws {
        let commands = try ShellTokenizer.pipeline("grep -c 'a|b' log.txt | sort -rn|head")
        #expect(commands.map { $0.map(\.text) } == [["grep", "-c", "a|b", "log.txt"], ["sort", "-rn"], ["head"]])
        #expect(try ShellTokenizer.pipeline("   ").isEmpty)
    }

    @Test("a pipe needs a command on both sides", arguments: ["| head", "cat a |", "cat a | | head"])
    func emptyPipelinePart(line: String) {
        #expect(throws: CommandError.self) { try ShellTokenizer.pipeline(line) }
    }

    @Test("tokenize takes one command only")
    func tokenizeRejectsPipeline() {
        #expect(throws: CommandError.unsupported("a pipeline is not allowed here; give one command")) {
            try ShellTokenizer.tokenize("cat a | head")
        }
    }

    @Test("unquoted glob characters are rejected, quoted ones are fine", arguments: ["ls *.swift", "ls a?c", "ls [ab]"])
    func rejectsGlobs(line: String) {
        #expect(throws: CommandError.self) { try ShellTokenizer.tokenize(line) }
    }

    @Test("unterminated quotes are errors", arguments: ["grep 'foo", #"grep "foo"#, #"grep foo\"#])
    func unterminated(line: String) {
        #expect(throws: CommandError.self) { try ShellTokenizer.tokenize(line) }
    }

    /// The message of an `.unsupported` error, or `nil` for another error.
    private static func unsupportedMessage(_ error: CommandError) -> String? {
        if case let .unsupported(message) = error { message } else { nil }
    }
}

extension ShellTokenizer {
    /// The words of `line`, which must be a single command.
    static func tokenize(_ line: String) throws -> [ShellToken] {
        let commands = try pipeline(line)
        guard commands.count <= 1 else {
            throw CommandError.unsupported("a pipeline is not allowed here; give one command")
        }
        return commands.first ?? []
    }
}
