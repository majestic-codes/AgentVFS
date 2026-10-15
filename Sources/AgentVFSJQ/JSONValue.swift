//
//  JSONValue.swift
//  AgentVFSJQ
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

/// A JSON value as jq sees it: objects keep their key order and numbers read from text keep the
/// way they were written until arithmetic touches them, so `1.10` prints as `1.10`.
public enum JSONValue: Sendable {
    /// `null`.
    case null
    /// `true` or `false`.
    case bool(Bool)
    /// A number. `literal` is the canonical text of a number that came from JSON or the program,
    /// or `nil` for a computed one.
    case number(Double, literal: String? = nil)
    /// A string.
    case string(String)
    /// An array.
    case array([Self])
    /// An object, which keeps its keys in insertion order.
    case object(JSONObject)

    /// A computed number holding `value`.
    public static func int(_ value: Int) -> Self { .number(Double(value)) }

    /// The name jq's `type` gives the value: `null`, `boolean`, `number`, `string`, `array` or
    /// `object`.
    public var typeName: String {
        switch self {
        case .null: "null"
        case .bool: "boolean"
        case .number: "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }

    /// `false` and `null` are falsy. Everything else is truthy.
    public var isTruthy: Bool {
        switch self {
        case .null, .bool(false): false
        default: true
        }
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    /// Whether the value is an array or an object.
    var isContainer: Bool {
        switch self {
        case .array, .object: true
        case .null, .bool, .number, .string: false
        }
    }

    /// The elements of an array or the values of an object, and none for a scalar.
    var elements: [Self] {
        switch self {
        case let .array(elements): elements
        case let .object(object): object.values
        case .null, .bool, .number, .string: []
        }
    }

    /// Drops the literal text, as arithmetic does.
    var computed: Self {
        if case let .number(value, literal) = self, literal != nil { return .number(value) }
        return self
    }
}

/// An object that remembers the order its keys were added in.
public struct JSONObject: Sendable {
    /// The keys in insertion order.
    public private(set) var keys: [String] = []
    /// The values, in the order of `keys`.
    public private(set) var values: [JSONValue] = []
    /// Where each key sits in `keys` and `values`.
    private var positions: [String: Int] = [:]

    /// An empty object.
    public init() {}

    /// An object with the pairs in order. A repeated key keeps its first position and last value.
    public init(_ pairs: [(String, JSONValue)]) {
        for (key, value) in pairs { self[key] = value }
    }

    /// The number of keys.
    public var count: Int { keys.count }
    /// Whether the object has no keys.
    public var isEmpty: Bool { keys.isEmpty }

    /// The value at `key`, or `nil` when it is absent. Setting a new key appends it, and setting `nil`
    /// removes the key.
    public subscript(key: String) -> JSONValue? {
        get { positions[key].map { values[$0] } }
        set {
            if let newValue {
                insert(newValue, at: key)
            } else {
                remove(key)
            }
        }
    }

    private mutating func insert(_ value: JSONValue, at key: String) {
        if let position = positions[key] {
            values[position] = value
            return
        }
        positions[key] = keys.count
        keys.append(key)
        values.append(value)
    }

    private mutating func remove(_ key: String) {
        guard let position = positions.removeValue(forKey: key) else { return }
        keys.remove(at: position)
        values.remove(at: position)
        for (index, later) in keys[position...].enumerated() { positions[later] = position + index }
    }

    /// The key-value pairs in insertion order.
    public var entries: [(key: String, value: JSONValue)] { zip(keys, values).map { ($0, $1) } }
    var sortedKeys: [String] { keys.sorted(by: JSONValue.precedes) }
    /// The key-value pairs ordered by key.
    var sortedEntries: [(key: String, value: JSONValue)] {
        entries.sorted { JSONValue.precedes($0.key, $1.key) }
    }
}

// MARK: Ordering

extension JSONValue: Equatable {

    /// Whether the values are equal in jq's order. Compares nested values in full, so callers
    /// holding untrusted values compare with a budget instead.
    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        compare(lhs, rhs) {} == 0
    }

    /// `compare`, checking `budget` as it goes, so values whose shared parts make them far larger
    /// than their storage stop at the time limit.
    static func compare(_ lhs: JSONValue, _ rhs: JSONValue, _ budget: Budget) throws -> Int {
        try compare(lhs, rhs, progress: budget.checkPeriodically)
    }

    /// jq's total order: null < false < true < numbers < strings < arrays < objects.
    /// `nan` sorts as if it were null, so it is below every number and never equal to anything.
    /// `progress` runs once per pair of values visited, and may throw to stop.
    static func compare(_ lhs: JSONValue, _ rhs: JSONValue, progress: () throws -> Void) rethrows -> Int {
        try progress()
        let leftRank = lhs.rank, rightRank = rhs.rank
        if leftRank != rightRank { return leftRank < rightRank ? -1 : 1 }
        switch (lhs, rhs) {
        case let (.number(left, _), .number(right, _)):
            if left.isNaN { return -1 }
            if right.isNaN { return 1 }
            return left < right ? -1 : (left == right ? 0 : 1)
        case let (.string(left), .string(right)):
            return compareStrings(left, right)
        case let (.array(left), .array(right)):
            return try compareArrays(left, right, progress: progress)
        case let (.object(left), .object(right)):
            return try compareObjects(left, right, progress: progress)
        default:
            return 0
        }
    }

    private static func compareArrays(
        _ left: [JSONValue],
        _ right: [JSONValue],
        progress: () throws -> Void
    ) rethrows -> Int {
        for (leftElement, rightElement) in zip(left, right) {
            let order = try compare(leftElement, rightElement, progress: progress)
            if order != 0 { return order }
        }
        return left.count < right.count ? -1 : (left.count == right.count ? 0 : 1)
    }

    /// Objects compare by their sorted keys first, then by the values under those keys.
    private static func compareObjects(
        _ left: JSONObject,
        _ right: JSONObject,
        progress: () throws -> Void
    ) rethrows -> Int {
        let leftEntries = left.sortedEntries, rightEntries = right.sortedEntries
        let leftKeys = leftEntries.map { Self.string($0.key) }, rightKeys = rightEntries.map { Self.string($0.key) }
        let keyOrder = try compare(.array(leftKeys), .array(rightKeys), progress: progress)
        if keyOrder != 0 { return keyOrder }
        for (leftEntry, rightEntry) in zip(leftEntries, rightEntries) {
            let order = try compare(leftEntry.value, rightEntry.value, progress: progress)
            if order != 0 { return order }
        }
        return 0
    }

    /// Strings compare by code point, which is the order of their UTF-8 bytes.
    static func compareStrings(_ lhs: String, _ rhs: String) -> Int {
        var left = lhs.utf8.makeIterator(), right = rhs.utf8.makeIterator()
        while true {
            switch (left.next(), right.next()) {
            case (nil, nil): return 0
            case (nil, _): return -1
            case (_, nil): return 1
            case let (leftByte?, rightByte?):
                if leftByte != rightByte { return leftByte < rightByte ? -1 : 1 }
            }
        }
    }

    static func precedes(_ lhs: String, _ rhs: String) -> Bool { compareStrings(lhs, rhs) < 0 }

    private var rank: Int {
        switch self {
        case .null: 0
        case .bool(false): 1
        case .bool(true): 2
        case .number: 3
        case .string: 4
        case .array: 5
        case .object: 6
        }
    }
}
