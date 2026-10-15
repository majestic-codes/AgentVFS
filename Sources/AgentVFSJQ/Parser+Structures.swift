//
//  Parser+Structures.swift
//  AgentVFSJQ
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

// MARK: Objects and strings

extension Parser {

    mutating func parseObject() throws -> Expr {
        try expectSymbol("{")
        var entries: [ObjectEntry] = []
        if isSymbol("}") {
            advance()
            return .object(entries)
        }
        while true {
            let entry = try parseObjectEntry()
            entries.append(entry)
            if isSymbol(",") {
                advance()
                continue
            }
            try expectSymbol("}")
            return .object(entries)
        }
    }

    private mutating func parseObjectEntry() throws -> ObjectEntry {
        let token = peek
        let key: Expr
        let shorthand: Expr
        switch token.kind {
        case let .variable(name):
            advance()
            let variable: Expr = name == "__loc__" ? Self.location(line: token.line) : .variable(name)
            guard isSymbol(":") else { return ObjectEntry(key: .literal(.string(name)), value: variable) }
            key = variable
            shorthand = variable
        case let .identifier(name), let .keyword(name):
            advance()
            key = .literal(.string(name))
            shorthand = .index(.identity, key)
        case let .string(parts):
            advance()
            key = try stringExpr(parts, format: nil)
            shorthand = .index(.identity, key)
        case let .format(name):
            advance()
            guard case let .string(parts) = peek.kind else { throw unexpected(expecting: "string") }
            advance()
            key = try stringExpr(parts, format: name)
            shorthand = .index(.identity, key)
        case .symbol("("):
            advance()
            key = try parsePipe()
            try expectSymbol(")")
            guard isSymbol(":") else { throw unexpected(expecting: "':'") }
            shorthand = key
        default:
            throw unexpected(expecting: "object key")
        }
        guard isSymbol(":") else { return ObjectEntry(key: key, value: shorthand) }
        advance()
        let value = try parseObjectValue()
        return ObjectEntry(key: key, value: value)
    }

    /// An object value: postfix terms, each optionally negated, joined by `|`.
    private mutating func parseObjectValue() throws -> Expr {
        var value = try parseObjectValueTerm()
        while isSymbol("|") {
            advance()
            let next = try parseObjectValueTerm()
            value = .pipe(value, next)
        }
        return value
    }

    private mutating func parseObjectValueTerm() throws -> Expr {
        try deepen()
        defer { depth -= 1 }
        if isSymbol("-") {
            advance()
            let operand = try parseObjectValueTerm()
            return .negate(operand)
        }
        if case .keyword = peek.kind { throw unexpected(expecting: nil) }
        return try parsePostfix(allowBinding: false)
    }

    mutating func stringExpr(_ parts: [StringPart], format: String?) throws -> Expr {
        var result: [InterpolatedPart] = []
        for part in parts {
            switch part {
            case let .literal(text):
                result.append(.literal(text))
            case let .interpolation(tokens):
                var inner = Self(tokens: tokens)
                inner.depth = depth
                let expr = try inner.parsePipe()
                try inner.expectEnd()
                result.append(.expression(expr))
            }
        }
        if format == nil, result.count == 1, case let .literal(text) = result[0] {
            return .literal(.string(text))
        }
        return .string(result, format: format)
    }

    mutating func parsePatterns() throws -> [Pattern] {
        let pattern = try parsePattern()
        var patterns = [pattern]
        while isSymbol("?//") {
            advance()
            let alternative = try parsePattern()
            patterns.append(alternative)
        }
        return patterns
    }
}

// MARK: Patterns and definitions

extension Parser {

    private mutating func parsePattern() throws -> Pattern {
        try deepen()
        defer { depth -= 1 }
        switch peek.kind {
        case let .variable(name):
            advance()
            return .variable(name)
        case .symbol("["):
            advance()
            let first = try parsePattern()
            var elementPatterns = [first]
            while isSymbol(",") {
                advance()
                let element = try parsePattern()
                elementPatterns.append(element)
            }
            try expectSymbol("]")
            return .array(elementPatterns)
        case .symbol("{"):
            advance()
            var entries: [ObjectPatternEntry] = []
            repeat {
                if !entries.isEmpty { advance() }
                let entry = try parseObjectPatternEntry()
                entries.append(entry)
            } while isSymbol(",")
            try expectSymbol("}")
            return .object(entries)
        default:
            throw unexpected(expecting: "'$', '[' or '{'")
        }
    }

    private mutating func parseObjectPatternEntry() throws -> ObjectPatternEntry {
        switch peek.kind {
        case let .variable(name):
            advance()
            var nested: Pattern?
            if isSymbol(":") {
                advance()
                nested = try parsePattern()
            }
            return ObjectPatternEntry(key: .literal(.string(name)), variable: name, pattern: nested)
        case let .identifier(name), let .keyword(name):
            advance()
            try expectSymbol(":")
            let pattern = try parsePattern()
            return ObjectPatternEntry(key: .literal(.string(name)), variable: nil, pattern: pattern)
        case let .string(parts):
            advance()
            let key = try stringExpr(parts, format: nil)
            try expectSymbol(":")
            let pattern = try parsePattern()
            return ObjectPatternEntry(key: key, variable: nil, pattern: pattern)
        case .symbol("("):
            advance()
            let key = try parsePipe()
            try expectSymbol(")")
            try expectSymbol(":")
            let pattern = try parsePattern()
            return ObjectPatternEntry(key: key, variable: nil, pattern: pattern)
        default:
            throw unexpected(expecting: "object pattern")
        }
    }

    mutating func parseFunctionDefinition() throws -> FunctionDefinition {
        try expectKeyword("def")
        let name: String
        switch peek.kind {
        case let .identifier(identifier), let .keyword(identifier):
            name = identifier
        default:
            throw unexpected(expecting: "function name")
        }
        advance()
        var parameters: [String] = []
        if isSymbol("(") {
            advance()
            repeat {
                if !parameters.isEmpty { advance() }
                switch peek.kind {
                case let .identifier(parameter), let .keyword(parameter):
                    parameters.append(parameter)
                case let .variable(parameter):
                    parameters.append("$" + parameter)
                default:
                    throw unexpected(expecting: "parameter name")
                }
                advance()
            } while isSymbol(";")
            try expectSymbol(")")
        }
        try expectSymbol(":")
        let body = try parsePipe()
        try expectSymbol(";")
        return FunctionDefinition(name: name, parameters: parameters, body: body)
    }
}
