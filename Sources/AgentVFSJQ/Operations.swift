//
//  Operations.swift
//  AgentVFSJQ
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

/// An error a filter raised at run time, such as indexing a number, `error(...)` or invalid JSON
/// passed to `fromjson` or `JQ.parse`. `try` and `?` catch it, and `value` is what `catch` receives.
public struct JQError: Error, LocalizedError, Sendable {
    /// The error value: a message string, or any value given to `error`.
    public let value: JSONValue

    init(_ message: String) {
        value = .string(message)
    }

    /// An error carrying `value`, as `error(value)` raises.
    public init(value: JSONValue) {
        self.value = value
    }

    /// The message, or the value as compact JSON when it is not a string.
    public var message: String {
        if case let .string(text) = value { return text }
        return value.serialized(.compact, limit: Operations.maxStringBytes)
    }

    /// The message prefixed with `jq: `.
    public var errorDescription: String? { "jq: " + message }
}

/// Values and paths, shared by the evaluator and the builtins.
enum Operations {

    static func describe(_ value: JSONValue) -> String {
        "\(value.typeName) (\(value.errorDescription))"
    }

    private static func keyDescription(_ key: JSONValue) -> String {
        if case let .string(text) = key { return "string \(JSONValue.string(text).json)" }
        return key.typeName
    }

    static func indexError(_ value: JSONValue, _ key: JSONValue) -> JQError {
        JQError("Cannot index \(value.typeName) with \(keyDescription(key))")
    }

    /// Clamps a double to an `Int` without trapping.
    static func integer(_ value: Double) -> Int {
        if value.isNaN { return 0 }
        if value >= 9.2e18 { return Int.max }
        if value <= -9.2e18 { return Int.min }
        return Int(value)
    }

    /// Largest array and string (in bytes) a program may build, so one filter cannot exhaust memory.
    /// Lower on iOS, where the memory an app may use is smaller.
    #if os(iOS)
    static let maxArrayCount = 4_000_000
    static let maxStringBytes = 32_000_000
    #else
    static let maxArrayCount = 10_000_000
    static let maxStringBytes = 100_000_000
    #endif

    /// How deeply values, paths and programs may nest. Deeper values would overflow the stack of
    /// the thread that releases them.
    static let maxDepth = 10_000

    static func checkSize(arrayCount: Int) throws {
        if arrayCount > maxArrayCount { throw JQError("Array too large (more than \(maxArrayCount) elements)") }
    }

    static func checkSize(stringBytes: Int) throws {
        if stringBytes > maxStringBytes { throw JQError("String too large (more than \(maxStringBytes) bytes)") }
    }

    // MARK: Indexing

    /// `value[key]`. `budget` stops a search for an array of values that runs past the time limit.
    static func index(_ value: JSONValue, _ key: JSONValue, _ budget: Budget) throws -> JSONValue {
        switch (value, key) {
        case (.null, .string), (.null, .number), (.null, .object), (.null, .null):
            return .null
        case let (.object(object), .string(name)):
            return object[name] ?? .null
        case let (.array(elements), .number(number, _)):
            guard number.isFinite else { return .null }
            var position = integer(number.rounded(.down))
            if position < 0 { position += elements.count }
            return position >= 0 && position < elements.count ? elements[position] : .null
        case let (.array(elements), .array(needle)):
            let positions = try indices(of: needle, in: elements, budget)
            return .array(positions.map { .int($0) })
        case let (.array, .object(bounds)), let (.string, .object(bounds)):
            return try slice(value, bounds["start"] ?? .null, bounds["end"] ?? .null)
        default:
            throw indexError(value, key)
        }
    }

    static func indices(of needle: [JSONValue], in elements: [JSONValue], _ budget: Budget) throws -> [Int] {
        try occurrences(of: needle, in: elements, progress: budget.check) { first, second in
            try JSONValue.compare(first, second, budget) == 0
        }
    }

    /// Resolves slice bounds like jq: negative counts from the end, the start rounds down and the
    /// end rounds up.
    static func sliceBounds(_ startBound: JSONValue, _ endBound: JSONValue, count: Int) throws -> Range<Int> {

        func number(_ value: JSONValue, default fallback: Double) throws -> Double {
            switch value {
            case .null: fallback
            case let .number(number, _): number
            default: throw JQError("Array/string slice indices must be integers")
            }
        }
        let length = Double(count)
        var start = try number(startBound, default: 0)
        var end = try number(endBound, default: length)
        if start < 0 { start += length }
        if end < 0 { end += length }
        start = min(max(start, 0), length)
        end = min(max(end, start), length)
        let lower = integer(start.rounded(.down))
        let upper = max(lower, min(count, integer(end.rounded(.up))))
        return lower..<upper
    }

    static func slice(_ value: JSONValue, _ start: JSONValue, _ end: JSONValue) throws -> JSONValue {
        switch value {
        case .null:
            return .null
        case let .array(elements):
            let range = try sliceBounds(start, end, count: elements.count)
            return .array(Array(elements[range]))
        case let .string(text):
            let scalars = Array(text.unicodeScalars)
            let range = try sliceBounds(start, end, count: scalars.count)
            return .string(String(String.UnicodeScalarView(scalars[range])))
        default:
            throw JQError("Cannot index \(value.typeName) with object")
        }
    }
}

/// `tostream` events of a value, one at a time: `[path, leaf]` for each leaf, then `[path]`
/// closing each array or object at its last key. Paths share one buffer while walking, so a
/// deep value costs memory for the events it has produced, not for every path at once.
struct StreamEvents {
    /// How the elements of an array or object are named in paths.
    private enum Keys {
        case positions
        case names([String])
    }

    private struct Level {
        let keys: Keys
        let values: [JSONValue]
        var next = 0

        /// The path component of the next value.
        var nextKey: JSONValue {
            switch keys {
            case .positions: .int(next)
            case let .names(names): .string(names[next])
            }
        }
    }

    private var levels: [Level] = []
    private var path: [JSONValue] = []
    private var pending: JSONValue?

    init(_ value: JSONValue) {
        pending = value
    }

    mutating func next() -> JSONValue? {
        while true {
            if let value = pending {
                pending = nil
                switch value {
                case let .array(elements) where !elements.isEmpty:
                    levels.append(Level(keys: .positions, values: elements))
                case let .object(object) where !object.isEmpty:
                    levels.append(Level(keys: .names(object.keys), values: object.values))
                default:
                    return .array([.array(path), value])
                }
            }
            guard var level = levels.popLast() else { return nil }
            guard level.next < level.values.count else {
                let closing = JSONValue.array([.array(path)])
                path.removeLast()
                return closing
            }
            if level.next > 0 { path.removeLast() }
            path.append(level.nextKey)
            pending = level.values[level.next]
            level.next += 1
            levels.append(level)
        }
    }
}
