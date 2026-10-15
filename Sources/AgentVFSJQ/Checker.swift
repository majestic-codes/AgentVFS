//
//  Checker.swift
//  AgentVFSJQ
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

/// Reports undefined functions, variables and labels before the program runs, as jq does.
enum Checker {
    struct Scope {
        var functions: Set<String>
        var variables: Set<String>
        var labels: Set<String> = []
    }

    static func check(_ expr: Expr, _ scope: Scope) throws {
        switch expr {
        case .identity, .recurseAll, .literal, .format:
            return
        case let .index(base, key, _):
            try checkAll([base, key], scope)
        case let .slice(base, start, end, _):
            try checkAll([base, start, end].compactMap(\.self), scope)
        case let .iterate(base, _), let .negate(base):
            try check(base, scope)
        case let .tryCatch(body, handler):
            try checkAll([body, handler].compactMap(\.self), scope)
        case let .pipe(first, second), let .comma(first, second), let .binary(_, first, second),
             let .logicalAnd(first, second), let .logicalOr(first, second), let .alternative(first, second),
             let .assign(_, first, second):
            try checkAll([first, second], scope)
        case let .ifThen(condition, then, otherwise):
            try checkAll([condition, then, otherwise].compactMap(\.self), scope)
        case let .reduce(fold):
            try checkFold(fold, extract: nil, scope)
        case let .foreach(fold, extract):
            try checkFold(fold, extract: extract, scope)
        case let .functionDefinition(definition, rest):
            try checkDefinition(definition, rest, scope)
        case let .call(name, arguments, line):
            try checkCall(name, arguments, line: line, scope)
        case let .variable(name):
            guard scope.variables.contains(name) else { throw JQCompileError(message: "$\(name) is not defined") }
        case let .bind(source, patterns, body):
            try check(source, scope)
            let inner = try bind(patterns, scope)
            try check(body, inner)
        case let .label(name, body):
            var inner = scope
            inner.labels.insert(name)
            try check(body, inner)
        case let .breakLabel(name):
            guard scope.labels.contains(name) else { throw JQCompileError(message: "$*label-\(name) is not defined") }
        case let .array(body):
            try checkAll([body].compactMap(\.self), scope)
        case let .object(entries):
            try checkAll(entries.flatMap { [$0.key, $0.value] }, scope)
        case let .string(parts, _):
            for case let .expression(part) in parts { try check(part, scope) }
        }
    }

    private static func checkAll(_ expressions: [Expr], _ scope: Scope) throws {
        for expression in expressions { try check(expression, scope) }
    }

    private static func checkFold(_ fold: Fold, extract: Expr?, _ scope: Scope) throws {
        try check(fold.source, scope)
        try check(fold.initial, scope)
        let inner = try bind(fold.patterns, scope)
        try check(fold.update, inner)
        if let extract { try check(extract, inner) }
    }

    /// The body sees the function itself and its parameters. The rest sees the function only.
    private static func checkDefinition(_ definition: FunctionDefinition, _ rest: Expr, _ scope: Scope) throws {
        var body = scope
        body.functions.insert(definition.key)
        for parameter in definition.parameters {
            if parameter.hasPrefix("$") {
                body.variables.insert(String(parameter.dropFirst()))
                body.functions.insert("\(parameter.dropFirst())/0")
            } else {
                body.functions.insert("\(parameter)/0")
            }
        }
        try check(definition.body, body)
        var after = scope
        after.functions.insert(definition.key)
        try check(rest, after)
    }

    private static func checkCall(_ name: String, _ arguments: [Expr], line: Int, _ scope: Scope) throws {
        let key = "\(name)/\(arguments.count)"
        guard scope.functions.contains(key) else {
            throw JQCompileError(message: "\(key) is not defined at <top-level>, line \(line)")
        }
        try checkAll(arguments, scope)
    }

    /// The scope inside `… as PATTERNS | body`. Keys of object patterns can use variables bound
    /// earlier in the same pattern.
    private static func bind(_ patterns: [Pattern], _ scope: Scope) throws -> Scope {
        var inner = scope
        for name in Interpreter.uniqueVariables(patterns) { inner.variables.insert(name) }
        func visit(_ pattern: Pattern) throws {
            switch pattern {
            case .variable:
                return
            case let .array(elementPatterns):
                for elementPattern in elementPatterns { try visit(elementPattern) }
            case let .object(entries):
                for entry in entries {
                    try check(entry.key, inner)
                    if let nested = entry.pattern { try visit(nested) }
                }
            }
        }
        for pattern in patterns { try visit(pattern) }
        return inner
    }
}
