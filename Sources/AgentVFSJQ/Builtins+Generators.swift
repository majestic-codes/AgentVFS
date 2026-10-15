//
//  Builtins+Generators.swift
//  AgentVFSJQ
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

// MARK: Ranges

extension Builtins {

    static func registerRanges(_ table: inout [String: Native]) {
        table["range/1"] = { interpreter, input, arguments, env, _, sink in
            try interpreter.eval(arguments[0], Item(input.value), env, false) { upto in
                try range(interpreter, .int(0), upto.value, .int(1), sink)
            }
        }
        table["range/2"] = { interpreter, input, arguments, env, _, sink in
            try interpreter.eval(arguments[0], Item(input.value), env, false) { from in
                try interpreter.eval(arguments[1], Item(input.value), env, false) { upto in
                    try range(interpreter, from.value, upto.value, .int(1), sink)
                }
            }
        }
        table["range/3"] = { interpreter, input, arguments, env, _, sink in
            try interpreter.eval(arguments[0], Item(input.value), env, false) { from in
                try interpreter.eval(arguments[1], Item(input.value), env, false) { upto in
                    try interpreter.eval(arguments[2], Item(input.value), env, false) { step in
                        try range(interpreter, from.value, upto.value, step.value, sink)
                    }
                }
            }
        }
    }

    private static func range(
        _ interpreter: Interpreter,
        _ from: JSONValue,
        _ upto: JSONValue,
        _ step: JSONValue,
        _ sink: Sink
    ) throws -> Bool {
        guard case let .number(start, _) = from, case let .number(end, _) = upto,
              case let .number(increment, _) = step else {
            throw JQError("Range bounds must be numeric")
        }
        var current = start
        while increment > 0 ? current < end : increment < 0 && current > end {
            try interpreter.tick()
            guard try sink(Item(.number(current))) else { return false }
            current += increment
        }
        return true
    }
}

// MARK: Generators

extension Builtins {

    static func registerGenerators(_ table: inout [String: Native]) {
        table["limit/2"] = { interpreter, input, arguments, env, tracking, sink in
            try interpreter.eval(arguments[0], Item(input.value), env, false) { bound in
                let count = try number(bound.value)
                let frame = Frame(input: input, env: env, tracking: tracking)
                return try limit(interpreter, arguments[1], count, frame, sink)
            }
        }
        table["first/1"] = { interpreter, input, arguments, env, tracking, sink in
            var first: Item?
            _ = try interpreter.eval(arguments[0], input, env, tracking) { item in
                first = item
                return false
            }
            guard let first else { return true }
            return try sink(first)
        }
        table["last/1"] = { interpreter, input, arguments, env, tracking, sink in
            var last: Item?
            _ = try interpreter.eval(arguments[0], input, env, tracking) { item in
                last = item
                return true
            }
            guard let last else { return true }
            return try sink(last)
        }
        table["isempty/1"] = { interpreter, input, arguments, env, _, sink in
            var empty = true
            _ = try interpreter.eval(arguments[0], Item(input.value), env, false) { _ in
                empty = false
                return false
            }
            return try sink(Item(.bool(empty)))
        }
    }

    /// `limit(n; f)`: the first `count` outputs of `generator`, all of them for a negative count.
    private static func limit(
        _ interpreter: Interpreter,
        _ generator: Expr,
        _ count: Double,
        _ frame: Frame,
        _ sink: Sink
    ) throws -> Bool {
        if count <= 0 { return count == 0 ? true : try interpreter.eval(generator, in: frame, sink) }
        var produced = 0.0
        var stopped = false
        _ = try interpreter.eval(generator, in: frame) { item in
            produced += 1
            guard try sink(item) else {
                stopped = true
                return false
            }
            return produced < count
        }
        return !stopped
    }
}

// MARK: Recursion

extension Builtins {

    static func registerRecursion(_ table: inout [String: Native]) {
        table["recurse/0"] = { interpreter, input, _, _, tracking, sink in
            try interpreter.recurseAll(input, tracking, sink)
        }
        // jq: `def recurse(f): def r: ., (f | r); r;`
        table["recurse/1"] = { interpreter, input, arguments, env, tracking, sink in
            try interpreter.unfold(input, sink) { item, emit, descend in
                guard try emit(item) else { return false }
                return try interpreter.eval(arguments[0], item, env, tracking, descend)
            }
        }
        // jq: `def recurse(f; cond): def r: ., (f | select(cond) | r); r;`
        table["recurse/2"] = { interpreter, input, arguments, env, tracking, sink in
            try interpreter.unfold(input, sink) { item, emit, descend in
                guard try emit(item) else { return false }
                return try interpreter.eval(arguments[0], item, env, tracking) { child in
                    try interpreter.eval(arguments[1], child.detached, env, false) { condition in
                        condition.value.isTruthy ? try descend(child) : true
                    }
                }
            }
        }
        // jq: `def repeat(f): def _repeat: f | (., _repeat); _repeat;`
        table["repeat/1"] = { interpreter, input, arguments, env, tracking, sink in
            try interpreter.unfold(input, sink) { item, emit, descend in
                try interpreter.eval(arguments[0], item, env, tracking) { child in
                    guard try emit(child) else { return false }
                    return try descend(child)
                }
            }
        }
        // jq: `def while(cond; update): def _while: if cond then ., (update | _while) else empty end; _while;`
        table["while/2"] = { interpreter, input, arguments, env, tracking, sink in
            try interpreter.unfold(input, sink) { item, emit, descend in
                try interpreter.eval(arguments[0], item.detached, env, false) { condition in
                    guard condition.value.isTruthy else { return true }
                    guard try emit(item) else { return false }
                    return try interpreter.eval(arguments[1], item, env, tracking, descend)
                }
            }
        }
        // jq: `def until(cond; update): def _until: if cond then . else (update | _until) end; _until;`
        table["until/2"] = { interpreter, input, arguments, env, tracking, sink in
            try interpreter.unfold(input, sink) { item, emit, descend in
                try interpreter.eval(arguments[0], item.detached, env, false) { condition in
                    guard condition.value.isTruthy else {
                        return try interpreter.eval(arguments[1], item, env, tracking, descend)
                    }
                    return try emit(item)
                }
            }
        }
    }
}
