//
//  AST.swift
//  AgentVFSJQ
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

indirect enum Expr: Sendable {
    case identity
    /// `..`
    case recurseAll
    case literal(JSONValue)
    /// `base[key]`, where the key is evaluated against the input of the whole term. An `optional`
    /// index (`base[key]?`) yields nothing where indexing fails.
    case index(Self, Self, optional: Bool = false)
    /// `base[start:end]`. A missing bound is `nil`.
    case slice(Self, start: Self?, end: Self?, optional: Bool = false)
    /// `base[]`, which yields nothing for a value it cannot iterate when `optional`.
    case iterate(Self, optional: Bool = false)
    /// `term?` and `try body catch handler`.
    case tryCatch(Self, Self?)
    case pipe(Self, Self)
    case comma(Self, Self)
    case negate(Self)
    case binary(BinaryOperator, Self, Self)
    case logicalAnd(Self, Self)
    case logicalOr(Self, Self)
    case alternative(Self, Self)
    case assign(AssignOperator, Self, Self)
    case ifThen(Self, Self, Self?)
    case reduce(Fold)
    /// `foreach`, with the optional extract expression.
    case foreach(Fold, extract: Self?)
    case functionDefinition(FunctionDefinition, Self)
    case call(String, [Self], line: Int)
    case variable(String)
    case bind(Self, [Pattern], Self)
    case label(String, Self)
    case breakLabel(String)
    case array(Self?)
    case object([ObjectEntry])
    /// A string with interpolations, optionally under a format such as `@base64`.
    case string([InterpolatedPart], format: String?)
    /// `@base64` on its own.
    case format(String)
}

enum InterpolatedPart: Sendable {
    case literal(String)
    case expression(Expr)
}

/// `reduce SOURCE as PATTERNS (INITIAL; UPDATE)` and the shared part of `foreach`.
struct Fold: Sendable {
    let source: Expr
    let patterns: [Pattern]
    let initial: Expr
    let update: Expr
}

struct ObjectEntry: Sendable {
    let key: Expr
    let value: Expr
}

enum BinaryOperator: String, Sendable {
    case add = "+", subtract = "-", multiply = "*", divide = "/", modulo = "%"
    case equal = "==", notEqual = "!=", less = "<", lessOrEqual = "<=", greater = ">", greaterOrEqual = ">="
}

enum AssignOperator: Sendable {
    /// `=`
    case set
    /// `|=`
    case update
    /// `//=`
    case alternative
    /// `+=`, `-=`, `*=`, `/=` and `%=`.
    case arithmetic(BinaryOperator)

    /// The operator `symbol` spells, or `nil` when it is not an assignment.
    init?(symbol: String) {
        switch symbol {
        case "=": self = .set
        case "|=": self = .update
        case "//=": self = .alternative
        case "+=": self = .arithmetic(.add)
        case "-=": self = .arithmetic(.subtract)
        case "*=": self = .arithmetic(.multiply)
        case "/=": self = .arithmetic(.divide)
        case "%=": self = .arithmetic(.modulo)
        default: return nil
        }
    }
}

indirect enum Pattern: Sendable {
    case variable(String)
    case array([Self])
    case object([ObjectPatternEntry])

    var variables: [String] {
        switch self {
        case let .variable(name): [name]
        case let .array(elementPatterns): elementPatterns.flatMap(\.variables)
        case let .object(entries): entries.flatMap(\.variables)
        }
    }
}

/// One `key: pattern` entry of an object pattern. `$name` entries bind `variable`, and may also
/// destructure the value further with `pattern`.
struct ObjectPatternEntry: Sendable {
    let key: Expr
    let variable: String?
    let pattern: Pattern?

    var variables: [String] {
        var names: [String] = []
        if let variable { names.append(variable) }
        if let pattern { names += pattern.variables }
        return names
    }
}

struct FunctionDefinition: Sendable {
    let name: String
    /// Parameter names. `$name` parameters keep their `$`.
    let parameters: [String]
    let body: Expr
    /// `name/arity`, how calls find the definition.
    let key: String

    init(name: String, parameters: [String], body: Expr) {
        self.name = name
        self.parameters = parameters
        self.body = body
        key = "\(name)/\(parameters.count)"
    }
}
