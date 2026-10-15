//
//  ShellTokenizer.swift
//  AgentVFS
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

/// Errors raised while interpreting a command line.
public enum CommandError: Error, Equatable, Sendable {
    /// Valid shell syntax that this emulator deliberately does not provide.
    case unsupported(String)
    /// Wrong or missing arguments.
    case usage(String)
}

/// One word of a command line, with its quotes removed.
public struct ShellToken: Equatable, Sendable {
    /// The word's text.
    public let text: String
    /// `true` only when the word starts with a quote, so `'-n'` is an operand but
    /// `--include='*.kt'` is still an option.
    public let isQuoted: Bool

    /// A word.
    public init(text: String, isQuoted: Bool = false) {
        self.text = text
        self.isQuoted = isQuoted
    }
}

/// Splits a command line into words without ever expanding anything.
///
/// Quoting and backslash escapes are honoured, and `|` separates the commands of a pipeline.
/// Every other construct that would make a real shell do something beyond passing words to
/// programs (redirects, expansion, globbing, brace expansion, `~` at the start of a word,
/// sequencing, a line break anywhere, even quoted or escaped) is rejected with an explanation
/// instead of being silently misread. `!` is literal, as in a shell that is not interactive.
public enum ShellTokenizer {
    /// The words of each command in a pipeline such as `grep -c x a.txt | head`, in order. Empty
    /// for an empty line. Throws `CommandError.unsupported` for shell syntax beyond plain words and
    /// pipes, and `CommandError.usage` for unterminated quotes or a trailing backslash.
    public static func pipeline(_ line: String) throws -> [[ShellToken]] {
        if line.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) {
            throw CommandError.unsupported("multi-line input is not supported; send one command per call")
        }
        var scanner = TokenScanner(characters: Array(line.unicodeScalars))
        try scanner.scan()
        return scanner.commands
    }
}

/// Walks the characters of one command line once, collecting words into `tokens`. It looks at
/// Unicode scalars, so a mark combined with `;` or a `\r\n` pair cannot hide shell syntax.
private struct TokenScanner {
    let characters: [Unicode.Scalar]
    /// The finished commands of the pipeline.
    var commands: [[ShellToken]] = []
    var tokens: [ShellToken] = []
    var current = ""
    var hasToken = false
    var quoted = false
    var index = 0

    init(characters: [Unicode.Scalar]) {
        self.characters = characters
    }

    mutating func scan() throws {
        while index < characters.count {
            let character = characters[index]
            switch character {
            case " ", "\t":
                flush()
                index += 1
            case "'":
                try readSingleQuoted()
            case "\"":
                try readDoubleQuoted()
            case "|":
                try endCommand()
            case "\\":
                guard index + 1 < characters.count else {
                    throw CommandError.usage("trailing backslash")
                }
                hasToken = true
                current.unicodeScalars.append(characters[index + 1])
                index += 2
            case "#" where !hasToken:
                throw CommandError.unsupported("comments (#) are not supported; quote a # that is part of an argument")
            case "~" where !hasToken:
                let message = "home directory expansion (~) is not supported; paths start at /workspace"
                throw CommandError.unsupported(message)
            default:
                if let rejection = Self.rejection(of: character) {
                    throw rejection
                }
                hasToken = true
                current.unicodeScalars.append(character)
                index += 1
            }
        }
        flush()
        if tokens.isEmpty {
            guard commands.isEmpty else { throw CommandError.usage("syntax error: a pipe needs a command after |") }
        } else {
            commands.append(tokens)
        }
    }

    /// Closes the command before a `|`.
    private mutating func endCommand() throws {
        flush()
        if index + 1 < characters.count, characters[index + 1] == "|" {
            throw CommandError.unsupported("command chaining (||) is not supported; run one command at a time")
        }
        guard !tokens.isEmpty else {
            throw CommandError.usage("syntax error: a pipe needs a command before |")
        }
        commands.append(tokens)
        tokens = []
        index += 1
    }

    private mutating func flush() {
        if hasToken {
            tokens.append(ShellToken(text: current, isQuoted: quoted))
        }
        current = ""
        hasToken = false
        quoted = false
    }

    private mutating func openQuote() {
        if !hasToken { quoted = true }
        hasToken = true
        index += 1
    }

    private mutating func readSingleQuoted() throws {
        openQuote()
        while index < characters.count {
            let inner = characters[index]
            index += 1
            if inner == "'" { return }
            current.unicodeScalars.append(inner)
        }
        throw CommandError.usage("unterminated single quote")
    }

    private mutating func readDoubleQuoted() throws {
        openQuote()
        while index < characters.count {
            let inner = characters[index]
            if inner == "\"" {
                index += 1
                return
            }
            if inner == "\\", index + 1 < characters.count {
                let escaped = characters[index + 1]
                if "\"\\$`".unicodeScalars.contains(escaped) {
                    current.unicodeScalars.append(escaped)
                } else {
                    current.unicodeScalars.append(inner)
                    current.unicodeScalars.append(escaped)
                }
                index += 2
                continue
            }
            if inner == "$" || inner == "`" {
                let message = "shell expansion ($ and backticks) is not supported; "
                    + "write the value literally or escape the $"
                throw CommandError.unsupported(message)
            }
            current.unicodeScalars.append(inner)
            index += 1
        }
        throw CommandError.usage("unterminated double quote")
    }

    /// The error for a character that would make a real shell do more than pass words to one program.
    private static func rejection(of character: Unicode.Scalar) -> CommandError? {
        switch character {
        case "&":
            .unsupported("command chaining (&, &&) is not supported; run one command at a time")
        case ";":
            .unsupported("command sequencing (;) is not supported; run one command at a time")
        case "<", ">":
            .unsupported("redirections are not supported; the file system is read-only")
        case "$", "`":
            .unsupported("shell expansion ($ and backticks) is not supported; write the value literally")
        case "(", ")":
            .unsupported("subshells and grouping are not supported")
        case "*", "?", "[":
            .unsupported(
                "glob expansion is not supported; quote the pattern (for example -name '*.swift') or use find"
            )
        case "{", "}":
            .unsupported("brace expansion is not supported; quote the braces (for example -name '*.{swift,kt}')")
        default:
            nil
        }
    }
}
