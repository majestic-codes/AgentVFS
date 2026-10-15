//
//  Parser.swift
//  AgentVFSJQ
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

/// Recursive-descent parser for the jq language, following the precedence of jq's grammar:
/// `|` < `,` < `//` < assignment < `or` < `and` < comparison < `+ -` < `* / %` < postfix terms.
struct Parser {
    var tokens: [Token]
    var position = 0
    /// Nesting levels open at this point, see `deepen()`.
    var depth = 0

    init(tokens: [Token]) {
        self.tokens = tokens
    }

    static func parse(_ source: String) throws -> Expr {
        let tokens = try Lexer.tokenize(source)
        var parser = Self(tokens: tokens)
        if case .end = parser.peek.kind { return .identity }
        let expr = try parser.parsePipe()
        try parser.expectEnd()
        return expr
    }

    /// Parses a file of definitions, such as the builtin library.
    static func parseDefinitions(_ source: String) throws -> [FunctionDefinition] {
        let tokens = try Lexer.tokenize(source)
        var parser = Self(tokens: tokens)
        var definitions: [FunctionDefinition] = []
        while case .keyword("def") = parser.peek.kind {
            let definition = try parser.parseFunctionDefinition()
            definitions.append(definition)
        }
        try parser.expectEnd()
        return definitions
    }

    // MARK: Tokens

    var peek: Token { tokens[position] }

    func peek(at offset: Int) -> Token {
        tokens[min(position + offset, tokens.count - 1)]
    }

    @discardableResult
    mutating func advance() -> Token {
        let token = tokens[position]
        if position < tokens.count - 1 { position += 1 }
        return token
    }

    func isSymbol(_ symbol: String) -> Bool { peek.symbol == symbol }

    func isKeyword(_ keyword: String) -> Bool {
        if case .keyword(keyword) = peek.kind { return true }
        return false
    }

    mutating func expectSymbol(_ symbol: String) throws {
        guard isSymbol(symbol) else { throw unexpected(expecting: "'\(symbol)'") }
        advance()
    }

    mutating func expectKeyword(_ keyword: String) throws {
        guard isKeyword(keyword) else { throw unexpected(expecting: keyword) }
        advance()
    }

    func expectEnd() throws {
        guard case .end = peek.kind else { throw unexpected(expecting: nil) }
    }

    func unexpected(expecting: String?) -> JQCompileError {
        let found: String
        if case .end = peek.kind { found = "end of file" } else { found = "'\(peek.display)'" }
        let expectation = expecting.map { ", expecting \($0)" } ?? ""
        return JQCompileError(message: "syntax error, unexpected \(found)\(expectation) at line \(peek.line)")
    }

    /// Counts one more level: a nested term, or one more operand of a chain such as `a, b, c`.
    /// Checking, running and releasing the program recurse once per level, so the count is capped.
    mutating func deepen() throws {
        depth += 1
        guard depth <= Operations.maxDepth else {
            throw JQCompileError(message: "filter nests too deeply (more than \(Operations.maxDepth) levels)")
        }
    }

    // MARK: Expressions

    mutating func parsePipe() throws -> Expr {
        try deepen()
        defer { depth -= 1 }
        if isKeyword("def") {
            let definition = try parseFunctionDefinition()
            let rest = try parsePipe()
            return .functionDefinition(definition, rest)
        }
        let left = try parseComma()
        if isSymbol("|") {
            advance()
            let right = try parsePipe()
            return .pipe(left, right)
        }
        return left
    }

    private mutating func parseComma() throws -> Expr {
        let outer = depth
        defer { depth = outer }
        var left = try parseAlternative()
        while isSymbol(",") {
            advance()
            try deepen()
            let right = try parseAlternative()
            left = .comma(left, right)
        }
        return left
    }

    /// `//` is right-associative.
    mutating func parseAlternative() throws -> Expr {
        try deepen()
        defer { depth -= 1 }
        let left = try parseAssignment()
        if isSymbol("//") {
            advance()
            let right = try parseAlternative()
            return .alternative(left, right)
        }
        return left
    }

    private mutating func parseAssignment() throws -> Expr {
        let left = try parseOr()
        if let symbol = peek.symbol, let assignOperator = AssignOperator(symbol: symbol) {
            advance()
            let right = try parseAlternative()
            return .assign(assignOperator, left, right)
        }
        return left
    }

    private mutating func parseOr() throws -> Expr {
        let outer = depth
        defer { depth = outer }
        var left = try parseAnd()
        while isKeyword("or") {
            advance()
            try deepen()
            let right = try parseAnd()
            left = .logicalOr(left, right)
        }
        return left
    }

    private mutating func parseAnd() throws -> Expr {
        let outer = depth
        defer { depth = outer }
        var left = try parseComparison()
        while isKeyword("and") {
            advance()
            try deepen()
            let right = try parseComparison()
            left = .logicalAnd(left, right)
        }
        return left
    }

    /// Comparisons do not chain: `a < b < c` is a syntax error.
    private mutating func parseComparison() throws -> Expr {
        let left = try parseAdditive()
        guard let comparison = comparisonOperator else { return left }
        advance()
        let right = try parseAdditive()
        if comparisonOperator != nil { throw unexpected(expecting: nil) }
        return .binary(comparison, left, right)
    }

    /// The comparison the next token spells, if any.
    private var comparisonOperator: BinaryOperator? {
        guard let symbol = peek.symbol, let binaryOperator = BinaryOperator(rawValue: symbol) else { return nil }
        let comparisons: [BinaryOperator] = [.equal, .notEqual, .less, .lessOrEqual, .greater, .greaterOrEqual]
        return comparisons.contains(binaryOperator) ? binaryOperator : nil
    }

    private mutating func parseAdditive() throws -> Expr {
        let outer = depth
        defer { depth = outer }
        var left = try parseMultiplicative()
        while let symbol = peek.symbol, symbol == "+" || symbol == "-" {
            advance()
            try deepen()
            let right = try parseMultiplicative()
            left = .binary(symbol == "+" ? .add : .subtract, left, right)
        }
        return left
    }

    private mutating func parseMultiplicative() throws -> Expr {
        let outer = depth
        defer { depth = outer }
        var left = try parseUnary()
        while let symbol = peek.symbol, symbol == "*" || symbol == "/" || symbol == "%" {
            advance()
            try deepen()
            let binaryOperator: BinaryOperator = symbol == "*" ? .multiply : (symbol == "/" ? .divide : .modulo)
            let right = try parseUnary()
            left = .binary(binaryOperator, left, right)
        }
        return left
    }

    private mutating func parseUnary() throws -> Expr {
        try deepen()
        defer { depth -= 1 }
        if isSymbol("-") {
            advance()
            let operand = try parseUnary()
            return .negate(operand)
        }
        return try parsePostfix(allowBinding: true)
    }
}
