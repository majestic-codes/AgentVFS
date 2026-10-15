//
//  Interpreter+Evaluation.swift
//  AgentVFSJQ
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

/// One function per kind of expression, so that one level of `eval` needs little stack.
extension Interpreter {
    /// `eval` with the input, scope and tracking taken from `frame`.
    @inline(__always)
    func eval(_ expr: Expr, in frame: Frame, _ sink: Sink) throws -> Bool {
        try eval(expr, frame.input, frame.env, frame.tracking, sink)
    }

    @inline(never)
    func evalIndex(_ base: Expr, _ key: Expr, _ optional: Bool, _ frame: Frame, _ sink: Sink) throws -> Bool {
        try eval(key, in: frame.plain) { key in
            try self.eval(base, in: frame) { target in
                let element: Item
                do {
                    element = try self.index(target, key.value, frame.tracking)
                } catch is JQError where optional {
                    return true
                }
                return try sink(element)
            }
        }
    }

    @inline(never)
    func evalSlice(
        _ base: Expr,
        _ bounds: (start: Expr?, end: Expr?),
        _ optional: Bool,
        _ frame: Frame,
        _ sink: Sink
    ) throws -> Bool {
        let plain = frame.plain
        return try evalBound(bounds.start, plain) { start in
            try self.evalBound(bounds.end, plain) { end in
                try self.eval(base, in: frame) { target in
                    let part: Item
                    do {
                        part = try self.slice(target, start, end, frame.tracking)
                    } catch is JQError where optional {
                        return true
                    }
                    return try sink(part)
                }
            }
        }
    }

    private func slice(_ target: Item, _ start: JSONValue, _ end: JSONValue, _ tracking: Bool) throws -> Item {
        let component = JSONValue.object(JSONObject([("start", start), ("end", end)]))
        var path: JSONPath?
        if tracking {
            guard let tracked = target.path else {
                let element = component.json
                let target = target.value.errorDescription
                throw JQError("Invalid path expression near attempt to access element \(element) of \(target)")
            }
            path = tracked.appending(component)
        }
        let value = try Operations.slice(target.value, start, end)
        return Item(value, path: path, depth: target.depth)
    }

    @inline(never)
    func evalIterate(_ base: Expr, _ optional: Bool, _ frame: Frame, _ sink: Sink) throws -> Bool {
        try eval(base, in: frame) { target in
            try self.iterate(target, frame.tracking, optional: optional, sink)
        }
    }

    @inline(never)
    func evalTry(_ body: Expr, _ handler: Expr?, _ frame: Frame, _ sink: Sink) throws -> Bool {
        let id = newID()
        do {
            return try eval(body, in: frame) { item in
                do {
                    return try sink(item)
                } catch {
                    throw Passthrough(id: id, error: error)
                }
            }
        } catch let passthrough as Passthrough where passthrough.id == id {
            throw passthrough.error
        } catch let error as JQError {
            guard let handler else { return true }
            return try eval(handler, Item(error.value), frame.env, false, sink)
        }
    }

    @inline(never)
    func evalPipe(_ first: Expr, _ second: Expr, _ frame: Frame, _ sink: Sink) throws -> Bool {
        try eval(first, in: frame) { item in
            try self.eval(second, item, frame.env, frame.tracking, sink)
        }
    }

    @inline(never)
    func evalComma(_ first: Expr, _ second: Expr, _ frame: Frame, _ sink: Sink) throws -> Bool {
        guard try eval(first, in: frame, sink) else { return false }
        return try eval(second, in: frame, sink)
    }

    @inline(never)
    func evalNegate(_ operand: Expr, _ frame: Frame, _ sink: Sink) throws -> Bool {
        try eval(operand, in: frame.plain) { item in
            guard case let .number(number, _) = item.value else {
                throw JQError("\(Operations.describe(item.value)) cannot be negated")
            }
            return try sink(Item(.number(-number)))
        }
    }

    @inline(never)
    func evalBinary(
        _ binaryOperator: BinaryOperator,
        _ lhs: Expr,
        _ rhs: Expr,
        _ frame: Frame,
        _ sink: Sink
    ) throws -> Bool {
        let plain = frame.plain
        return try eval(rhs, in: plain) { right in
            try self.eval(lhs, in: plain) { left in
                let result = try Operations.apply(binaryOperator, left.value, right.value, self.budget)
                try self.charge(result)
                // Arithmetic never nests deeper than its deepest operand.
                let depth = left.depth.flatMap { leftDepth in right.depth.map { max(leftDepth, $0) } }
                return try sink(Item(result, depth: depth))
            }
        }
    }

    @inline(never)
    func evalLogic(and: Bool, _ lhs: Expr, _ rhs: Expr, _ frame: Frame, _ sink: Sink) throws -> Bool {
        let plain = frame.plain
        return try eval(lhs, in: plain) { left in
            // `and` stops at a falsy left side, `or` at a truthy one.
            if left.value.isTruthy != and { return try sink(Item(.bool(!and))) }
            return try self.eval(rhs, in: plain) { right in try sink(Item(.bool(right.value.isTruthy))) }
        }
    }

    @inline(never)
    func evalAlternative(_ lhs: Expr, _ rhs: Expr, _ frame: Frame, _ sink: Sink) throws -> Bool {
        var produced = false
        let completed = try eval(lhs, in: frame) { item in
            guard item.value.isTruthy else { return true }
            produced = true
            return try sink(item)
        }
        guard completed else { return false }
        return produced ? true : try eval(rhs, in: frame, sink)
    }

    @inline(never)
    func evalIf(_ condition: Expr, _ then: Expr, _ otherwise: Expr?, _ frame: Frame, _ sink: Sink) throws -> Bool {
        try eval(condition, in: frame.plain) { result in
            if result.value.isTruthy { return try self.eval(then, in: frame, sink) }
            if let otherwise { return try self.eval(otherwise, in: frame, sink) }
            return try sink(frame.input)
        }
    }

    @inline(never)
    func evalReduce(_ fold: Fold, _ frame: Frame, _ sink: Sink) throws -> Bool {
        try eval(fold.initial, in: frame) { start in
            var state: Item? = start
            _ = try self.eval(fold.source, in: frame.plain) { element in
                try self.destructureAlternatives(fold.patterns, element.value, frame.env) { scope in
                    var last: Item?
                    _ = try self.eval(fold.update, state ?? Item(.null), scope, frame.tracking) { output in
                        last = output
                        return true
                    }
                    state = last
                    return true
                }
            }
            return try sink(state ?? Item(.null))
        }
    }

    @inline(never)
    func evalForeach(_ fold: Fold, _ extract: Expr?, _ frame: Frame, _ sink: Sink) throws -> Bool {
        try eval(fold.initial, in: frame) { start in
            var state = start
            return try self.eval(fold.source, in: frame.plain) { element in
                try self.destructureAlternatives(fold.patterns, element.value, frame.env) { scope in
                    try self.eval(fold.update, state, scope, frame.tracking) { output in
                        state = output
                        guard let extract else { return try sink(output) }
                        return try self.eval(extract, output, scope, frame.tracking, sink)
                    }
                }
            }
        }
    }

    @inline(never)
    func evalDefinition(_ definition: FunctionDefinition, _ rest: Expr, _ frame: Frame, _ sink: Sink) throws -> Bool {
        try eval(rest, frame.input, Env(frame.env, .function(definition)), frame.tracking, sink)
    }

    @inline(never)
    func evalCall(_ name: String, _ arguments: [Expr], _ frame: Frame, _ sink: Sink) throws -> Bool {
        let key = "\(name)/\(arguments.count)"
        switch lookupFunction(key, in: frame.env) {
        case let .closure(body, closureEnv):
            return try eval(body, frame.input, closureEnv, frame.tracking, sink)
        case let .function(definition, scope):
            return try call(definition, scope, arguments, frame, sink)
        case nil:
            guard let native = Builtins.natives[key] else { throw JQError("\(key) is not defined") }
            return try native(self, frame.input, arguments, frame.env, frame.tracking) { item in
                try self.charge(item.value)
                return try sink(item)
            }
        }
    }

    @inline(never)
    func evalVariable(_ name: String, _ env: Env, _ sink: Sink) throws -> Bool {
        guard let value = lookupVariable(name, in: env) else { throw JQError("$\(name) is not defined") }
        return try sink(Item(value))
    }

    @inline(never)
    func evalLabel(_ name: String, _ body: Expr, _ frame: Frame, _ sink: Sink) throws -> Bool {
        let id = newID()
        do {
            return try eval(body, frame.input, Env(frame.env, .label(name, id)), frame.tracking, sink)
        } catch let signal as BreakSignal where signal.id == id {
            return true
        }
    }

    /// The signal `break $name` throws.
    func breakSignal(_ name: String, _ env: Env) throws -> BreakSignal {
        guard let id = lookupLabel(name, in: env) else { throw JQError("$*label-\(name) is not defined") }
        return BreakSignal(id: id)
    }

    @inline(never)
    func evalArray(_ body: Expr?, _ frame: Frame, _ sink: Sink) throws -> Bool {
        guard let body else { return try sink(Item(.array([]), depth: 1)) }
        var elements: [JSONValue] = []
        var deepest = 0
        _ = try eval(body, in: frame.plain) { item in
            elements.append(item.value)
            if elements.count > Operations.maxArrayCount { try Operations.checkSize(arrayCount: elements.count) }
            let itemDepth = try self.depth(of: item)
            deepest = max(deepest, itemDepth)
            return true
        }
        let depth = try allowedDepth(deepest + 1)
        let array = JSONValue.array(elements)
        try charge(array)
        return try sink(Item(array, depth: depth))
    }

    @inline(never)
    func evalString(_ parts: [InterpolatedPart], _ format: String?, _ frame: Frame, _ sink: Sink) throws -> Bool {
        let template = StringTemplate(parts: parts, format: format)
        let pieces = Array(repeating: "", count: parts.count)
        return try interpolate(template, parts.count - 1, pieces, frame.plain, sink)
    }

    @inline(never)
    func evalFormat(_ name: String, _ input: Item, _ sink: Sink) throws -> Bool {
        let text = try Formats.apply(name, input.value, budget)
        try Operations.checkSize(stringBytes: text.utf8.count)
        let value = JSONValue.string(text)
        try charge(value)
        return try sink(Item(value, depth: 0))
    }

    /// The values of a slice bound, or `null` when it is missing.
    func evalBound(_ expr: Expr?, _ frame: Frame, _ body: (JSONValue) throws -> Bool) throws -> Bool {
        guard let expr else { return try body(.null) }
        return try eval(expr, in: frame) { item in try body(item.value) }
    }
}
