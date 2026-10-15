//
//  Lexer.swift
//  AgentVFSJQ
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

/// A filter that does not compile: a syntax error, an undefined function, variable or label, or a
/// filter past the length and nesting limits.
public struct JQCompileError: Error, Equatable, Sendable {
    /// What is wrong, as jq words it.
    public let message: String
}

enum StringPart: Sendable {
    case literal(String)
    case interpolation([Token])
}

enum TokenKind: Sendable {
    case identifier(String)
    case keyword(String)
    /// `.name`
    case field(String)
    /// `$name`
    case variable(String)
    /// `literal` is the canonical text jq keeps, or `nil` when it keeps only the double.
    case number(Double, literal: String?)
    case string([StringPart])
    /// `@name`
    case format(String)
    case symbol(String)
    case end
}

struct Token: Sendable {
    let kind: TokenKind
    let line: Int

    var symbol: String? {
        if case let .symbol(value) = kind { return value }
        return nil
    }

    var display: String {
        switch kind {
        case let .identifier(name), let .keyword(name): name
        case let .field(name): "." + name
        case let .variable(name): "$" + name
        case let .number(value, literal): literal ?? JSONValue.formatNumber(value, literal: nil)
        case .string: "string"
        case let .format(name): "@" + name
        case let .symbol(value): value
        case .end: "end of file"
        }
    }
}

/// Turns jq program text into tokens.
struct Lexer {
    static let keywords: Set<String> = [
        "def", "if", "then", "elif", "else", "end", "as", "reduce", "foreach", "try", "catch",
        "label", "import", "include", "and", "or", "__loc__"
    ]

    /// The symbols by their first character, longer ones first so `//=` is not read as `//` and `=`.
    private static let symbols: [Unicode.Scalar: [(text: String, scalars: [Unicode.Scalar])]] = {
        let all = [
            "?//", "|=", "+=", "-=", "*=", "/=", "%=", "//=", "==", "!=", "<=", ">=", "//", "..",
            ".", "[", "]", "{", "}", "(", ")", "|", ",", "+", "-", "*", "/", "%", "=", "<", ">", ":", ";", "?"
        ]
        let entries = all.map { symbol in (text: symbol, scalars: Array(symbol.unicodeScalars)) }
        let grouped = Dictionary(grouping: entries) { $0.scalars[0] }
        return grouped.mapValues { group in group.sorted { $0.scalars.count > $1.scalars.count } }
    }()

    private let scalars: [Unicode.Scalar]
    private var index = 0
    private var line = 1
    /// Strings open at this point. Each `\(…)` inside a string lexes recursively.
    private var openStrings = 0

    static func tokenize(_ source: String) throws -> [Token] {
        var lexer = Self(scalars: Array(source.unicodeScalars))
        var tokens = try lexer.lex(insideInterpolation: false)
        tokens.append(Token(kind: .end, line: lexer.line))
        return tokens
    }

    private init(scalars: [Unicode.Scalar]) {
        self.scalars = scalars
    }

    private static func isIdentifierStart(_ scalar: Unicode.Scalar) -> Bool {
        (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z") || scalar == "_"
    }

    private static func isIdentifierPart(_ scalar: Unicode.Scalar) -> Bool {
        isIdentifierStart(scalar) || isDigit(scalar)
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool { scalar >= "0" && scalar <= "9" }

    /// The scalar `offset` places ahead, or `nil` past the end.
    private func scalar(ahead offset: Int) -> Unicode.Scalar? {
        index + offset < scalars.count ? scalars[index + offset] : nil
    }

    /// Lexes until the end of input or, inside `\( … )`, until the matching `)`.
    private mutating func lex(insideInterpolation: Bool) throws -> [Token] {
        var tokens: [Token] = []
        var depth = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if skipTrivia(scalar) { continue }
            if insideInterpolation {
                if scalar == "(" { depth += 1 }
                if scalar == ")" {
                    if depth == 0 {
                        index += 1
                        return tokens
                    }
                    depth -= 1
                }
            }
            let token = try lexToken(scalar)
            tokens.append(token)
        }
        if insideInterpolation {
            throw JQCompileError(message: "syntax error, unterminated string interpolation")
        }
        return tokens
    }

    /// Skips a newline, other whitespace or a comment, and returns whether there was one.
    private mutating func skipTrivia(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "\n":
            line += 1
            index += 1
        case " ", "\t", "\r":
            index += 1
        case "#":
            while index < scalars.count, scalars[index] != "\n" { index += 1 }
        default:
            return false
        }
        return true
    }

    private mutating func lexToken(_ scalar: Unicode.Scalar) throws -> Token {
        let next = self.scalar(ahead: 1)
        if scalar == "\"" {
            index += 1
            let parts = try lexString()
            return Token(kind: .string(parts), line: line)
        }
        if Self.isDigit(scalar) || (scalar == "." && next.map(Self.isDigit) == true) {
            return try lexNumber()
        }
        if scalar == ".", let next, Self.isIdentifierStart(next) {
            index += 1
            return Token(kind: .field(identifier()), line: line)
        }
        if scalar == "$" {
            index += 1
            guard let next, Self.isIdentifierStart(next) else {
                throw JQCompileError(message: "syntax error, unexpected '$' at line \(line)")
            }
            return Token(kind: .variable(identifier()), line: line)
        }
        if scalar == "@" {
            index += 1
            return Token(kind: .format(identifier()), line: line)
        }
        if Self.isIdentifierStart(scalar) {
            let name = identifier()
            return Token(kind: Self.keywords.contains(name) ? .keyword(name) : .identifier(name), line: line)
        }
        return try lexSymbol(scalar)
    }

    /// A name, including `::` module separators.
    private mutating func identifier() -> String {
        var name = ""
        while let scalar = scalar(ahead: 0) {
            if Self.isIdentifierPart(scalar) {
                name.unicodeScalars.append(scalar)
                index += 1
            } else if scalar == ":", self.scalar(ahead: 1) == ":", let start = self.scalar(ahead: 2),
                      Self.isIdentifierStart(start) {
                name += "::"
                index += 2
            } else {
                break
            }
        }
        return name
    }

    private mutating func lexNumber() throws -> Token {
        var text = ""
        appendDigits(to: &text)
        if scalar(ahead: 0) == ".", scalar(ahead: 1) != "." {
            text += "."
            index += 1
            appendDigits(to: &text)
        }
        if let marker = scalar(ahead: 0), marker == "e" || marker == "E" {
            var lookahead = index + 1
            if lookahead < scalars.count, scalars[lookahead] == "+" || scalars[lookahead] == "-" { lookahead += 1 }
            if lookahead < scalars.count, Self.isDigit(scalars[lookahead]) {
                text += String(scalars[index..<lookahead].map(Character.init))
                index = lookahead
                appendDigits(to: &text)
            }
        }
        let normalized = text.hasPrefix(".") ? "0" + text : (text.hasSuffix(".") ? text + "0" : text)
        guard let value = Double(normalized) else {
            throw JQCompileError(message: "syntax error, invalid numeric literal \(text) at line \(line)")
        }
        let literal = JSONValue.canonicalLiteral(Substring(normalized))
        return Token(kind: .number(value, literal: literal), line: line)
    }

    private mutating func appendDigits(to text: inout String) {
        while let scalar = scalar(ahead: 0), Self.isDigit(scalar) {
            text.unicodeScalars.append(scalar)
            index += 1
        }
    }

    private mutating func lexSymbol(_ scalar: Unicode.Scalar) throws -> Token {
        for symbol in Self.symbols[scalar, default: []] {
            let end = index + symbol.scalars.count
            if end <= scalars.count, scalars[index..<end].elementsEqual(symbol.scalars) {
                index = end
                return Token(kind: .symbol(symbol.text), line: line)
            }
        }
        let character = Character(scalar)
        throw JQCompileError(message: "syntax error, unexpected INVALID_CHARACTER '\(character)' at line \(line)")
    }

    // MARK: Strings

    private mutating func lexString() throws -> [StringPart] {
        openStrings += 1
        defer { openStrings -= 1 }
        guard openStrings <= Operations.maxDepth else {
            throw JQCompileError(message: "filter nests too deeply (more than \(Operations.maxDepth) levels)")
        }
        let unterminated = JQCompileError(message: "syntax error, unterminated string literal")
        var parts: [StringPart] = []
        var current = ""
        while true {
            guard index < scalars.count else { throw unterminated }
            let scalar = scalars[index]
            index += 1
            if scalar == "\"" { break }
            if scalar == "\n" { line += 1 }
            guard scalar == "\\" else {
                current.unicodeScalars.append(scalar)
                continue
            }
            guard index < scalars.count else { throw unterminated }
            let escape = scalars[index]
            index += 1
            guard escape == "(" else {
                let unescaped = try unescape(escape)
                current.unicodeScalars.append(unescaped)
                continue
            }
            if !current.isEmpty {
                parts.append(.literal(current))
                current = ""
            }
            let inner = try lex(insideInterpolation: true)
            parts.append(.interpolation(inner + [Token(kind: .end, line: line)]))
        }
        if !current.isEmpty || parts.isEmpty {
            parts.append(.literal(current))
        }
        return parts
    }

    /// The scalar a backslash escape other than `\(` stands for.
    private mutating func unescape(_ escape: Unicode.Scalar) throws -> Unicode.Scalar {
        switch escape {
        case "\"", "\\", "/": escape
        case "b": "\u{08}"
        case "f": "\u{0C}"
        case "n": "\n"
        case "r": "\r"
        case "t": "\t"
        case "u": try unicodeEscape()
        default: throw JQCompileError(message: "syntax error, invalid escape \\\(Character(escape)) in string literal")
        }
    }

    /// `\uXXXX`, where a high surrogate must be followed by a low one. A lone low surrogate
    /// becomes U+FFFD, as in jq.
    private mutating func unicodeEscape() throws -> Unicode.Scalar {
        let surrogateError = JQCompileError(message: "Invalid \\uXXXX\\uXXXX surrogate pair escape")
        let unit = try hex()
        let codePoint: UInt32
        if (0xD800...0xDBFF).contains(unit) {
            guard scalar(ahead: 0) == "\\", scalar(ahead: 1) == "u" else { throw surrogateError }
            index += 2
            let low = try hex()
            guard (0xDC00...0xDFFF).contains(low) else { throw surrogateError }
            codePoint = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
        } else if (0xDC00...0xDFFF).contains(unit) {
            return "\u{FFFD}"
        } else {
            codePoint = unit
        }
        guard let scalar = Unicode.Scalar(codePoint) else { throw surrogateError }
        return scalar
    }

    private mutating func hex() throws -> UInt32 {
        let end = min(index + 4, scalars.count)
        guard let value = HexDigits.value(of: scalars[index..<end].map(\.value)) else {
            throw JQCompileError(message: "syntax error, invalid \\u escape in string literal")
        }
        index += 4
        return value
    }
}
