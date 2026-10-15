//
//  Parser+Terms.swift
//  AgentVFSJQ
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

extension Parser {

    mutating func parsePostfix(allowBinding: Bool) throws -> Expr {
        let outer = depth
        defer { depth = outer }
        var lastIsStep = startsWithStep
        var term = try parsePrimary()
        while true {
            try deepen()
            let isStep = lastIsStep
            lastIsStep = false
            switch peek.kind {
            case let .field(name):
                advance()
                term = .index(term, .literal(.string(name)))
                lastIsStep = true
            case .symbol("."):
                guard let indexed = try parseDotSuffix(term) else { return term }
                term = indexed
                lastIsStep = true
            case .symbol("["):
                term = try parseBracketSuffix(term)
                lastIsStep = true
            case .symbol("?"):
                advance()
                term = Self.optional(term, stepOnly: isStep)
            case .symbol("?//"):
                // `.a?//b` is `.a? // b` outside a destructuring.
                tokens[position] = Token(kind: .symbol("//"), line: peek.line)
                return Self.optional(term, stepOnly: isStep)
            case .keyword("as") where allowBinding:
                advance()
                let patterns = try parsePatterns()
                try expectSymbol("|")
                let body = try parsePipe()
                return .bind(term, patterns, body)
            default:
                return term
            }
        }
    }

    /// Whether the next term starts with an index step: `.name` or `."name"`.
    private var startsWithStep: Bool {
        if case .field = peek.kind { return true }
        guard peek.symbol == "." else { return false }
        if case .string = peek(at: 1).kind { return true }
        return false
    }

    /// `term?`: when the term ends in an index, slice or iteration step, only that step is
    /// optional, so errors are dropped for each input it fails on. Any other term is wrapped in `try`.
    private static func optional(_ term: Expr, stepOnly: Bool) -> Expr {
        guard stepOnly else { return .tryCatch(term, nil) }
        return switch term {
        case let .index(base, key, _): .index(base, key, optional: true)
        case let .slice(base, start, end, _): .slice(base, start: start, end: end, optional: true)
        case let .iterate(base, _): .iterate(base, optional: true)
        default: .tryCatch(term, nil)
        }
    }

    /// `term."key"` and `term.[…]`; `nil` when the `.` starts something else.
    private mutating func parseDotSuffix(_ term: Expr) throws -> Expr? {
        if case let .string(parts) = peek(at: 1).kind {
            advance()
            advance()
            let key = try stringExpr(parts, format: nil)
            return .index(term, key)
        }
        guard peek(at: 1).symbol == "[" else { return nil }
        advance()
        return try parseBracketSuffix(term)
    }

    private mutating func parseBracketSuffix(_ term: Expr) throws -> Expr {
        try expectSymbol("[")
        if isSymbol("]") {
            advance()
            return .iterate(term)
        }
        if isSymbol(":") {
            advance()
            let end = try parsePipe()
            try expectSymbol("]")
            return .slice(term, start: nil, end: end)
        }
        let index = try parsePipe()
        if isSymbol(":") {
            advance()
            if isSymbol("]") {
                advance()
                return .slice(term, start: index, end: nil)
            }
            let end = try parsePipe()
            try expectSymbol("]")
            return .slice(term, start: index, end: end)
        }
        try expectSymbol("]")
        return .index(term, index)
    }

    private mutating func parsePrimary() throws -> Expr {
        try deepen()
        defer { depth -= 1 }
        let token = peek
        switch token.kind {
        case let .number(value, literal):
            advance()
            return .literal(.number(value, literal: literal))
        case let .string(parts):
            advance()
            return try stringExpr(parts, format: nil)
        case let .format(name):
            advance()
            guard case let .string(parts) = peek.kind else { return .format(name) }
            advance()
            return try stringExpr(parts, format: name)
        case let .field(name):
            advance()
            return .index(.identity, .literal(.string(name)))
        case let .variable(name):
            advance()
            return name == "__loc__" ? Self.location(line: token.line) : .variable(name)
        case .symbol:
            return try parseSymbolTerm()
        case .keyword:
            return try parseKeywordTerm()
        case let .identifier(name):
            return try parseIdentifierTerm(name, line: token.line)
        case .end:
            throw unexpected(expecting: nil)
        }
    }

    /// `$__loc__`: where in the program it appears.
    static func location(line: Int) -> Expr {
        .literal(.object(JSONObject([("file", .string("<top-level>")), ("line", .int(line))])))
    }

    private mutating func parseSymbolTerm() throws -> Expr {
        switch peek.kind {
        case .symbol("."):
            advance()
            guard case let .string(parts) = peek.kind else { return .identity }
            advance()
            let key = try stringExpr(parts, format: nil)
            return .index(.identity, key)
        case .symbol(".."):
            advance()
            return .recurseAll
        case .symbol("("):
            advance()
            let inner = try parsePipe()
            try expectSymbol(")")
            return inner
        case .symbol("["):
            advance()
            if isSymbol("]") {
                advance()
                return .array(nil)
            }
            let inner = try parsePipe()
            try expectSymbol("]")
            return .array(inner)
        case .symbol("{"):
            return try parseObject()
        case .symbol("-"):
            advance()
            let operand = try parsePostfix(allowBinding: false)
            return .negate(operand)
        default:
            throw unexpected(expecting: nil)
        }
    }

    private mutating func parseKeywordTerm() throws -> Expr {
        switch peek.kind {
        case .keyword("def"):
            let definition = try parseFunctionDefinition()
            let rest = try parsePipe()
            return .functionDefinition(definition, rest)
        case .keyword("if"):
            return try parseIf()
        case .keyword("try"):
            advance()
            let body = try parsePostTerm()
            guard isKeyword("catch") else { return .tryCatch(body, nil) }
            advance()
            let handler = try parsePostTerm()
            return .tryCatch(body, handler)
        case .keyword("reduce"):
            let fold = try parseFold()
            return .reduce(fold)
        case .keyword("foreach"):
            let fold = try parseFold(closing: false)
            var extract: Expr?
            if isSymbol(";") {
                advance()
                extract = try parsePipe()
            }
            try expectSymbol(")")
            return .foreach(fold, extract: extract)
        case .keyword("label"):
            advance()
            guard case let .variable(name) = peek.kind else { throw unexpected(expecting: "'$'") }
            advance()
            try expectSymbol("|")
            let body = try parsePipe()
            return .label(name, body)
        default:
            throw unexpected(expecting: nil)
        }
    }

    /// `reduce`/`foreach SOURCE as PATTERNS (INITIAL; UPDATE`, and the `)` unless `closing` is
    /// false.
    private mutating func parseFold(closing: Bool = true) throws -> Fold {
        advance()
        let source = try parsePostfix(allowBinding: false)
        try expectKeyword("as")
        let patterns = try parsePatterns()
        try expectSymbol("(")
        let initial = try parsePipe()
        try expectSymbol(";")
        let update = try parsePipe()
        if closing { try expectSymbol(")") }
        return Fold(source: source, patterns: patterns, initial: initial, update: update)
    }

    private mutating func parseIdentifierTerm(_ name: String, line: Int) throws -> Expr {
        advance()
        switch name {
        case "break":
            guard case let .variable(label) = peek.kind else { throw unexpected(expecting: "'$'") }
            advance()
            return .breakLabel(label)
        case "null": return .literal(.null)
        case "true": return .literal(.bool(true))
        case "false": return .literal(.bool(false))
        default: break
        }
        var arguments: [Expr] = []
        if isSymbol("(") {
            advance()
            let argument = try parsePipe()
            arguments.append(argument)
            while isSymbol(";") {
                advance()
                let argument = try parsePipe()
                arguments.append(argument)
            }
            try expectSymbol(")")
        }
        return .call(name, arguments, line: line)
    }

    /// The operand of `try` and `catch`: a postfix term.
    private mutating func parsePostTerm() throws -> Expr {
        if isSymbol("-") {
            advance()
            let operand = try parsePostfix(allowBinding: false)
            return .negate(operand)
        }
        return try parsePostfix(allowBinding: false)
    }

    /// `if … then … (elif … then …)* (else …)? end`. Each `elif` is read as a nested `if` that
    /// shares the outer `end`.
    private mutating func parseIf() throws -> Expr {
        try deepen()
        defer { depth -= 1 }
        try expectKeyword("if")
        let condition = try parsePipe()
        try expectKeyword("then")
        let then = try parsePipe()
        if isKeyword("elif") {
            tokens[position] = Token(kind: .keyword("if"), line: peek.line)
            let rest = try parseIf()
            return .ifThen(condition, then, rest)
        }
        var otherwise: Expr?
        if isKeyword("else") {
            advance()
            otherwise = try parsePipe()
        }
        try expectKeyword("end")
        return .ifThen(condition, then, otherwise)
    }
}
