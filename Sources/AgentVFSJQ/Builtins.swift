//
//  Builtins.swift
//  AgentVFSJQ
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import Foundation

/// A builtin implemented in Swift: interpreter, input, unevaluated arguments, caller scope,
/// whether paths are tracked, and the sink.
typealias Native = @Sendable (Interpreter, Item, [Expr], Env, Bool, Sink) throws -> Bool

enum Builtins {
    static let natives: [String: Native] = {
        var table: [String: Native] = [:]
        registerCore(&table)
        registerPaths(&table)
        registerValues(&table)
        registerEntries(&table)
        registerConversions(&table)
        registerStrings(&table)
        registerStringTransforms(&table)
        registerCollections(&table)
        registerSorting(&table)
        registerRanges(&table)
        registerGenerators(&table)
        registerRecursion(&table)
        registerMath(&table)
        registerSystem(&table)
        return table
    }()

    /// Every builtin name as `name/arity`, without internal helpers.
    static let names: [String] = {
        let all = Set(natives.keys).union(Prelude.definitions.map(\.key))
        return all.filter { !$0.hasPrefix("_") }.sorted()
    }()

    // MARK: Helpers

    static func simple(_ body: @escaping @Sendable (JSONValue) throws -> JSONValue) -> Native {
        { _, input, _, _, _, sink in
            let output = try body(input.value)
            return try sink(Item(output))
        }
    }

    /// Evaluates the arguments to values (every combination) and applies `body`.
    static func withValues(_ body: @escaping @Sendable (JSONValue, [JSONValue]) throws -> JSONValue) -> Native {
        { interpreter, input, arguments, env, _, sink in
            try interpreter.withArguments(arguments, input, env) { values in
                let output = try body(input.value, values)
                return try sink(Item(output))
            }
        }
    }

    static func string(_ value: JSONValue, _ message: String) throws -> String {
        guard case let .string(text) = value else { throw JQError(message) }
        return text
    }

    static func number(_ value: JSONValue) throws -> Double {
        guard case let .number(number, _) = value else {
            throw JQError("\(Operations.describe(value)) number required")
        }
        return number
    }

    static func array(_ value: JSONValue, _ verb: String) throws -> [JSONValue] {
        guard case let .array(elements) = value else {
            throw JQError("\(Operations.describe(value)) cannot be \(verb), as it is not an array")
        }
        return elements
    }

    /// `[f]` for every element, the keys `sort_by` and friends compare.
    static func keys(
        _ elements: [JSONValue],
        _ interpreter: Interpreter,
        _ expr: Expr,
        _ env: Env
    ) throws -> [JSONValue] {
        try interpreter.budget.reserve(elements.count * Budget.valueBytes)
        var keys: [JSONValue] = []
        keys.reserveCapacity(elements.count)
        for element in elements {
            var outputs: [JSONValue] = []
            _ = try interpreter.eval(expr, Item(element), env, false) { output in
                outputs.append(output.value)
                return true
            }
            try interpreter.budget.note(allocating: Budget.storageBytes + outputs.count * Budget.valueBytes)
            keys.append(.array(outputs))
        }
        return keys
    }

    /// The positions of `keys` in ascending order. Equal keys keep their original order. `budget`
    /// refuses a sort that does not fit in memory and stops one that runs past the time limit.
    static func sortedPositions(_ keys: [JSONValue], _ budget: Budget) throws -> [Int] {
        // The positions, and the buffer the stable sort merges through.
        try budget.reserve(keys.count * MemoryLayout<Int>.stride * 2)
        var positions = Array(keys.indices)
        try positions.sort { first, second in
            let order = try JSONValue.compare(keys[first], keys[second], budget)
            return order != 0 ? order < 0 : first < second
        }
        return positions
    }

    /// The elements ordered by their keys. Equal keys keep their original order.
    static func sorted(_ elements: [JSONValue], by keys: [JSONValue], _ budget: Budget) throws -> [JSONValue] {
        let positions = try sortedPositions(keys, budget)
        try budget.reserve(elements.count * Budget.valueBytes)
        return positions.map { elements[$0] }
    }

    /// The elements in runs of equal keys, the runs ordered by key.
    static func groups(_ elements: [JSONValue], _ keys: [JSONValue], _ budget: Budget) throws -> [[JSONValue]] {
        let positions = try sortedPositions(keys, budget)
        try budget.reserve(elements.count * Budget.valueBytes)
        var result: [[JSONValue]] = []
        var lastKey: JSONValue?
        for position in positions {
            let key = keys[position]
            let sameKey = try lastKey.map { try JSONValue.compare($0, key, budget) == 0 } ?? false
            if sameKey {
                result[result.count - 1].append(elements[position])
            } else {
                try budget.note(allocating: Budget.storageBytes + Budget.valueBytes)
                result.append([elements[position]])
            }
            lastKey = key
        }
        return result
    }

    static func extreme(
        _ elements: [JSONValue],
        _ keys: [JSONValue],
        maximum: Bool,
        _ budget: Budget
    ) throws -> JSONValue {
        guard !elements.isEmpty else { return .null }
        var best = 0
        for position in 1..<elements.count {
            let order = try JSONValue.compare(keys[position], keys[best], budget)
            if maximum ? order >= 0 : order < 0 { best = position }
        }
        return elements[best]
    }

    /// Code point offsets for ascending UTF-8 byte offsets into `text`, in one pass.
    static func scalarOffsets(_ byteOffsets: [Int], in text: String) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(byteOffsets.count)
        var bytes = text.utf8.makeIterator()
        var byteIndex = 0
        var scalars = 0
        for offset in byteOffsets {
            while byteIndex < offset, let byte = bytes.next() {
                // Continuation bytes (10xxxxxx) do not start a code point.
                if byte & 0xC0 != 0x80 { scalars += 1 }
                byteIndex += 1
            }
            result.append(scalars)
        }
        return result
    }
}
