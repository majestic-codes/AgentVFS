//
//  Interpreter+Functions.swift
//  AgentVFSJQ
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

/// A string literal with interpolations, optionally under a format such as `@base64`.
struct StringTemplate {
    let parts: [InterpolatedPart]
    let format: String?
}

// MARK: Functions

extension Interpreter {
    /// Calls a jq-defined function. `frame` is the caller's: arguments are evaluated in its scope.
    func call(
        _ definition: FunctionDefinition,
        _ scope: Env,
        _ arguments: [Expr],
        _ frame: Frame,
        _ sink: Sink
    ) throws -> Bool {
        var calleeEnv = scope
        var valueParameters: [(position: Int, name: String)] = []
        for (position, parameter) in definition.parameters.enumerated() {
            if parameter.hasPrefix("$") {
                valueParameters.append((position, String(parameter.dropFirst())))
            } else {
                calleeEnv = Env(calleeEnv, .closure("\(parameter)/0", arguments[position], frame.env))
            }
        }
        return try bindValues(valueParameters[...], arguments, caller: frame, calleeEnv) { env in
            try self.eval(definition.body, frame.input, env, frame.tracking, sink)
        }
    }

    /// `$name` parameters: every combination of argument values, the first parameter outermost.
    private func bindValues(
        _ parameters: ArraySlice<(position: Int, name: String)>,
        _ arguments: [Expr],
        caller: Frame,
        _ env: Env,
        _ body: (Env) throws -> Bool
    ) throws -> Bool {
        guard let parameter = parameters.first else { return try body(env) }
        return try eval(arguments[parameter.position], caller.input.detached, caller.env, false) { value in
            let variable = Env(env, .variable(parameter.name, value.value))
            let bound = Env(variable, .closure("\(parameter.name)/0", .literal(value.value), env))
            return try self.bindValues(parameters.dropFirst(), arguments, caller: caller, bound, body)
        }
    }

    /// Calls `body` with every combination of the arguments' values, the last argument outermost,
    /// as jq does for its C builtins.
    func withArguments(
        _ arguments: [Expr],
        _ input: Item,
        _ env: Env,
        _ body: ([JSONValue]) throws -> Bool
    ) throws -> Bool {
        var values = [JSONValue](repeating: .null, count: arguments.count)
        func fill(_ position: Int) throws -> Bool {
            guard position >= 0 else { return try body(values) }
            return try eval(arguments[position], input.detached, env, false) { item in
                values[position] = item.value
                return try fill(position - 1)
            }
        }
        return try fill(arguments.count - 1)
    }
}

// MARK: Destructuring

extension Interpreter {

    static func uniqueVariables(_ patterns: [Pattern]) -> [String] {
        var seen = Set<String>()
        return patterns.flatMap(\.variables).filter { seen.insert($0).inserted }
    }

    @inline(never)
    func evalBind(_ source: Expr, _ patterns: [Pattern], _ body: Expr, _ frame: Frame, _ sink: Sink) throws -> Bool {
        try eval(source, in: frame.plain) { element in
            try self.destructureAlternatives(patterns, element.value, frame.env) { scope in
                try self.eval(body, frame.input, scope, frame.tracking, sink)
            }
        }
    }

    /// `?//`: tries each pattern in turn, going on to the next when destructuring, `body` or what
    /// it passes outputs to raises a jq error, as jq backtracks. Every pattern's variables exist,
    /// as null.
    func destructureAlternatives(
        _ patterns: [Pattern],
        _ value: JSONValue,
        _ env: Env,
        _ body: (Env) throws -> Bool
    ) throws -> Bool {
        if patterns.count == 1 { return try destructure(patterns[0], value, env, body) }
        let names = Self.uniqueVariables(patterns)
        for (position, pattern) in patterns.enumerated() {
            let base = names.reduce(env) { Env($0, .variable($1, .null)) }
            if position == patterns.count - 1 { return try destructure(pattern, value, base, body) }
            do {
                return try destructure(pattern, value, base, body)
            } catch is JQError {
                continue
            }
        }
        return true
    }

    func destructure(_ pattern: Pattern, _ value: JSONValue, _ env: Env, _ body: (Env) throws -> Bool) throws -> Bool {
        switch pattern {
        case let .variable(name):
            return try body(Env(env, .variable(name, value)))
        case let .array(elementPatterns):
            func next(_ position: Int, _ scope: Env) throws -> Bool {
                guard position < elementPatterns.count else { return try body(scope) }
                let element = try Operations.index(value, .int(position), budget)
                return try destructure(elementPatterns[position], element, scope) { inner in
                    try next(position + 1, inner)
                }
            }
            return try next(0, env)
        case let .object(entries):
            return try destructureObject(entries[...], value, env, body)
        }
    }

    private func destructureObject(
        _ entries: ArraySlice<ObjectPatternEntry>,
        _ value: JSONValue,
        _ scope: Env,
        _ body: (Env) throws -> Bool
    ) throws -> Bool {
        guard let entry = entries.first else { return try body(scope) }
        let rest = entries.dropFirst()
        return try eval(entry.key, Item(value), scope, false) { key in
            guard case .string = key.value else {
                throw JQError("Cannot index \(value.typeName) with \(key.value.typeName)")
            }
            let element = try Operations.index(value, key.value, self.budget)
            var inner = scope
            if let name = entry.variable { inner = Env(inner, .variable(name, element)) }
            if let nested = entry.pattern {
                return try self.destructure(nested, element, inner) { deeper in
                    try self.destructureObject(rest, value, deeper, body)
                }
            }
            return try self.destructureObject(rest, value, inner, body)
        }
    }
}

// MARK: Construction

extension Interpreter {
    /// Builds an object entry by entry. `frame` is the input with tracking off. `deepest` is how
    /// deeply the values so far nest.
    func buildObject(
        _ entries: [ObjectEntry],
        _ position: Int,
        _ object: JSONObject,
        deepest: Int = 0,
        _ frame: Frame,
        _ sink: Sink
    ) throws -> Bool {
        guard position < entries.count else {
            let depth = try allowedDepth(deepest + 1)
            let value = JSONValue.object(object)
            try charge(value)
            return try sink(Item(value, depth: depth))
        }
        let entry = entries[position]
        return try eval(entry.key, in: frame) { key in
            guard case let .string(name) = key.value else {
                throw JQError("Cannot use \(Operations.describe(key.value)) as object key")
            }
            return try self.eval(entry.value, in: frame) { value in
                let valueDepth = try self.depth(of: value)
                let nested = max(deepest, valueDepth)
                var next = object
                next[name] = value.value
                return try self.buildObject(entries, position + 1, next, deepest: nested, frame, sink)
            }
        }
    }

    /// Fills interpolations from the last one outward, which is the order jq produces.
    func interpolate(
        _ template: StringTemplate,
        _ position: Int,
        _ pieces: [String],
        _ frame: Frame,
        _ sink: Sink
    ) throws -> Bool {
        guard position >= 0 else {
            let text = pieces.joined()
            try Operations.checkSize(stringBytes: text.utf8.count)
            let value = JSONValue.string(text)
            try charge(value)
            return try sink(Item(value, depth: 0))
        }
        switch template.parts[position] {
        case let .literal(text):
            var next = pieces
            next[position] = text
            return try interpolate(template, position - 1, next, frame, sink)
        case let .expression(expr):
            return try eval(expr, in: frame) { item in
                var next = pieces
                next[position] = try Formats.apply(template.format ?? "text", item.value, self.budget)
                return try self.interpolate(template, position - 1, next, frame, sink)
            }
        }
    }
}
