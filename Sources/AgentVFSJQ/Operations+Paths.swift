//
//  Operations+Paths.swift
//  AgentVFSJQ
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

extension Operations {
    // MARK: Paths

    /// How many levels a path goes down: one per key or position. A slice stays on its level,
    /// since what is set in its place is spliced back into the array.
    /// Refuses paths longer than `maxDepth`: setting and deleting recurse once per component.
    static func checkLength(_ path: [JSONValue]) throws {
        guard path.count <= maxDepth else { throw JQError("Path too long (more than \(maxDepth) components)") }
    }

    static func descents(_ path: [JSONValue]) -> Int {
        path.reduce(0) { count, component in
            switch component {
            case .string, .number: count + 1
            case .null, .bool, .array, .object: count
            }
        }
    }

    static func getpath(_ value: JSONValue, _ path: [JSONValue], _ budget: Budget) throws -> JSONValue {
        var current = value
        for key in path {
            if case .null = current { return .null }
            current = try index(current, key, budget)
        }
        return current
    }

    static func setpath(_ value: JSONValue, _ path: ArraySlice<JSONValue>, _ newValue: JSONValue) throws -> JSONValue {
        guard let key = path.first else { return newValue }
        let rest = path.dropFirst()
        switch (value, key) {
        case let (.object(existing), .string(name)):
            var object = existing
            object[name] = try setpath(object[name] ?? .null, rest, newValue)
            return .object(object)
        case let (.null, .string(name)):
            var object = JSONObject()
            object[name] = try setpath(.null, rest, newValue)
            return .object(object)
        case let (.array, .number(number, _)), let (.null, .number(number, _)):
            var elements: [JSONValue] = []
            if case let .array(existing) = value { elements = existing }
            guard number.isFinite else { throw JQError("Array index must be finite") }
            var position = integer(number.rounded(.down))
            if position < 0 {
                position += elements.count
                guard position >= 0 else { throw JQError("Out of bounds negative array index") }
            }
            guard position < maxArrayCount else { throw JQError("Array index too large") }
            if position >= elements.count {
                elements.append(contentsOf: repeatElement(JSONValue.null, count: position - elements.count + 1))
            }
            elements[position] = try setpath(elements[position], rest, newValue)
            return .array(elements)
        case let (.array, .object(bounds)), let (.null, .object(bounds)):
            var elements: [JSONValue] = []
            if case let .array(existing) = value { elements = existing }
            let range = try sliceBounds(bounds["start"] ?? .null, bounds["end"] ?? .null, count: elements.count)
            let replaced = try setpath(.array(Array(elements[range])), rest, newValue)
            guard case let .array(replacement) = replaced else {
                throw JQError("A slice of an array can only be assigned another array")
            }
            elements.replaceSubrange(range, with: replacement)
            return .array(elements)
        case (.string, .object):
            throw JQError("Cannot update string slices")
        default:
            throw indexError(value, key)
        }
    }

    static func delpaths(_ value: JSONValue, _ paths: [JSONValue], _ budget: Budget) throws -> JSONValue {
        var arrays: [[JSONValue]] = []
        for path in paths {
            guard case let .array(components) = path else { throw JQError("Path must be specified as an array") }
            try checkLength(components)
            arrays.append(components)
        }
        try arrays.sort { try JSONValue.compare(.array($0), .array($1), budget) < 0 }
        // The same path twice deletes once. Later paths go first so indices stay valid.
        var unique: [[JSONValue]] = []
        for path in arrays {
            if let last = unique.last, try JSONValue.compare(.array(last), .array(path), budget) == 0 { continue }
            unique.append(path)
        }
        var result = value
        for path in unique.reversed() {
            result = try delpath(result, path[...], budget)
        }
        return result
    }

    private static func delpath(
        _ value: JSONValue,
        _ path: ArraySlice<JSONValue>,
        _ budget: Budget
    ) throws -> JSONValue {
        guard let key = path.first else { return .null }
        if case .null = value { return .null }
        if path.count == 1 {
            switch (value, key) {
            case let (.object(existing), .string(name)):
                var object = existing
                object[name] = nil
                return .object(object)
            case let (.array(existing), .number(number, _)):
                var elements = existing
                var position = integer(number.rounded(.down))
                if position < 0 { position += elements.count }
                if (0..<elements.count).contains(position) { elements.remove(at: position) }
                return .array(elements)
            case let (.array(existing), .object(bounds)):
                var elements = existing
                let range = try sliceBounds(bounds["start"] ?? .null, bounds["end"] ?? .null, count: elements.count)
                elements.removeSubrange(range)
                return .array(elements)
            case (.object, _), (.array, _):
                throw indexError(value, key)
            default:
                throw JQError("Cannot delete fields from \(value.typeName)")
            }
        }
        let child: JSONValue
        do {
            child = try index(value, key, budget)
        } catch {
            if case .object = value { throw error }
            if case .array = value { throw error }
            throw JQError("Cannot delete fields from \(value.typeName)")
        }
        if case .null = child { return value }
        let remaining = try delpath(child, path.dropFirst(), budget)
        return try setpath(value, [key][...], remaining)
    }
}
