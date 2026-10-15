//
//  Interpreter+Paths.swift
//  AgentVFSJQ
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

// MARK: Indexing and iteration

extension Interpreter {

    func index(_ target: Item, _ key: JSONValue, _ tracking: Bool) throws -> Item {
        let value = try Operations.index(target.value, key, budget)
        // A key or a position picks one element, nested a level less. Slices nest as deep.
        let depth: Int? = switch key {
        case .string, .number: target.depth.map { max($0 - 1, 0) }
        case .null, .bool, .array, .object: target.depth
        }
        guard tracking else { return Item(value, depth: depth) }
        guard let path = target.path else {
            let element = key.errorDescription
            let target = target.value.errorDescription
            throw JQError("Invalid path expression near attempt to access element \(element) of \(target)")
        }
        return Item(value, path: path.appending(key.computed), depth: depth)
    }

    /// Passes each element of an array or value of an object to `sink`. When `optional`, a value
    /// that cannot be iterated yields nothing instead of an error.
    func iterate(_ target: Item, _ tracking: Bool, optional: Bool = false, _ sink: Sink) throws -> Bool {
        let base: JSONPath?
        do {
            base = try iterationPath(target, tracking)
        } catch is JQError where optional {
            return true
        }
        let depth = target.depth.map { max($0 - 1, 0) }
        switch target.value {
        case let .array(elements):
            for (position, element) in elements.enumerated() {
                guard try sink(Item(element, path: base?.appending(.int(position)), depth: depth)) else { return false }
            }
            return true
        case let .object(object):
            for (key, element) in object.entries {
                guard try sink(Item(element, path: base?.appending(.string(key)), depth: depth)) else { return false }
            }
            return true
        case .null, .bool, .number, .string:
            return true
        }
    }

    /// The path of an iterated value while paths are tracked, after checking it can be iterated.
    func iterationPath(_ target: Item, _ tracking: Bool) throws -> JSONPath? {
        var path: JSONPath?
        if tracking {
            guard let tracked = target.path else {
                let description = target.value.errorDescription
                throw JQError("Invalid path expression near attempt to iterate through \(description)")
            }
            path = tracked
        }
        guard target.value.isContainer else {
            throw JQError("Cannot iterate over \(Operations.describe(target.value))")
        }
        return path
    }

    /// `..` and `recurse`: every value in `root`, parents before children, depth first. Each level
    /// of nesting is one entry on an explicit stack, and children are read from their container
    /// one at a time, so deep or wide values need neither call stack nor a copy.
    func recurseAll(_ root: Item, _ tracking: Bool, _ sink: Sink) throws -> Bool {
        try tick()
        guard try sink(root) else { return false }
        var levels: [RecursionLevel] = []
        if root.value.isContainer {
            let path = try iterationPath(root, tracking)
            levels.append(RecursionLevel(root, path: path))
        }
        while let top = levels.indices.last {
            guard let child = levels[top].nextChild() else {
                levels.removeLast()
                continue
            }
            try tick()
            guard try sink(child) else { return false }
            guard child.value.isContainer else { continue }
            let path = try iterationPath(child, tracking)
            levels.append(RecursionLevel(child, path: path))
        }
        return true
    }

    /// One step of `unfold`: passes outputs to `emit` and the items to run the next step on to
    /// `descend`, in the order the filter produces them.
    typealias UnfoldStep = (_ item: Item, _ emit: Sink, _ descend: Sink) throws -> Bool

    /// Runs `step` on `start` and on every item it descends into, depth first and lazily, as jq's
    /// recursive definitions of `recurse`, `repeat`, `while` and `until` do. An item is visited
    /// when `step` produces the next one or finishes, and the last item is visited in a loop
    /// rather than by recursion, so a long chain of single items needs no call stack. An error
    /// raised while the next item is computed is thrown after the held item is visited.
    func unfold(_ start: Item, _ sink: Sink, step: @escaping UnfoldStep) throws -> Bool {
        var current = start
        while true {
            try tick()
            var pending: Item?
            func visitPending() throws -> Bool {
                guard let held = pending else { return true }
                pending = nil
                return try unfold(held, sink, step: step)
            }
            let completed: Bool
            do {
                completed = try step(
                    current,
                    { output in
                        guard try visitPending() else { return false }
                        return try sink(output)
                    },
                    { next in
                        guard try visitPending() else { return false }
                        pending = next
                        return true
                    }
                )
            } catch {
                // The held item comes before the error, as jq visits it before it goes on.
                guard pending != nil else { throw error }
                guard try visitPending() else { return false }
                throw error
            }
            guard completed else { return false }
            guard let next = pending else { return true }
            current = next
        }
    }

    func paths(of expr: Expr, in value: JSONValue, _ env: Env) throws -> [[JSONValue]] {
        var result: [[JSONValue]] = []
        _ = try eval(expr, Item(value, path: .root), env, true) { item in
            guard let path = item.path else {
                throw JQError("Invalid path expression with result \(item.value.errorDescription)")
            }
            try self.budget.note(allocating: path.count * MemoryLayout<JSONValue>.stride)
            result.append(path.components)
            return true
        }
        return result
    }
}

/// A container `..` is walking through, and the position of its next child.
private struct RecursionLevel {
    /// How the children are named in paths.
    private enum Keys {
        case positions
        case names([String])
    }

    private let elements: [JSONValue]
    private let keys: Keys
    private let path: JSONPath?
    private let depth: Int?
    private var next = 0

    init(_ container: Item, path: JSONPath?) {
        switch container.value {
        case let .array(elements):
            self.elements = elements
            keys = .positions
        case let .object(object):
            elements = object.values
            keys = .names(object.keys)
        case .null, .bool, .number, .string:
            elements = []
            keys = .positions
        }
        self.path = path
        depth = container.depth.map { max($0 - 1, 0) }
    }

    /// The next child, with its path and depth, or `nil` after the last.
    mutating func nextChild() -> Item? {
        guard next < elements.count else { return nil }
        defer { next += 1 }
        let key: JSONValue = switch keys {
        case .positions: .int(next)
        case let .names(names): .string(names[next])
        }
        return Item(elements[next], path: path?.appending(key), depth: depth)
    }
}

// MARK: Assignment

extension Interpreter {

    func assign(
        _ assignOperator: AssignOperator,
        _ lhs: Expr,
        _ rhs: Expr,
        _ frame: Frame,
        _ sink: Sink
    ) throws -> Bool {
        let input = frame.input.detached
        let value = input.value
        let targets = try paths(of: lhs, in: value, frame.env)
        try targets.forEach(Operations.checkLength)
        let deepestPath = targets.reduce(0) { max($0, Operations.descents($1)) }
        let stateDepth = try depth(of: input)
        func replace(_ newValue: Replacement) throws -> Bool {
            try eval(rhs, input, frame.env, false) { operand in
                // A replacement is the operand, the old value, or the two combined, which nests no
                // deeper than they do.
                let operandDepth = try self.depth(of: operand)
                let nested = deepestPath + (operandDepth)
                let depth = try self.allowedDepth(max(stateDepth, nested))
                var state = value
                for path in targets {
                    let replacement = try newValue(state, path, operand.value)
                    state = try Operations.setpath(state, path[...], replacement)
                }
                return try sink(Item(state, depth: depth))
            }
        }
        switch assignOperator {
        case .update:
            let updated = try update(input, at: targets, with: rhs, frame.env)
            return try sink(updated)
        case .set:
            return try replace { _, _, operand in operand }
        case .alternative:
            return try replace { state, path, operand in
                let old = try Operations.getpath(state, path, self.budget)
                return old.isTruthy ? old : operand
            }
        case let .arithmetic(binaryOperator):
            return try replace { state, path, operand in
                let old = try Operations.getpath(state, path, self.budget)
                return try Operations.apply(binaryOperator, old, operand, self.budget)
            }
        }
    }

    /// The new value at `path` in `state`, given the right-hand side's output.
    typealias Replacement = (_ state: JSONValue, _ path: [JSONValue], _ operand: JSONValue) throws -> JSONValue

    /// `|=`: each path gets the first output of `rhs` on its old value, or is deleted when there
    /// is none.
    private func update(_ input: Item, at targets: [[JSONValue]], with rhs: Expr, _ env: Env) throws -> Item {
        var state = input.value
        var depth = try self.depth(of: input)
        var deletions: [JSONValue] = []
        for path in targets {
            let old = try Operations.getpath(state, path, self.budget)
            let descents = Operations.descents(path)
            var replacement: Item?
            _ = try eval(rhs, Item(old, depth: max(depth - descents, 0)), env, false) { item in
                replacement = item
                return false
            }
            if let replacement {
                let replacementDepth = try self.depth(of: replacement)
                depth = try allowedDepth(max(depth, descents + replacementDepth))
                state = try Operations.setpath(state, path[...], replacement.value)
            } else {
                deletions.append(.array(path))
            }
        }
        if !deletions.isEmpty { state = try Operations.delpaths(state, deletions, budget) }
        return Item(state, depth: depth)
    }
}
