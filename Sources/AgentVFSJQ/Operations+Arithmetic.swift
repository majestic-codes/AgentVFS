//
//  Operations+Arithmetic.swift
//  AgentVFSJQ
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import Foundation

extension Operations {
    // MARK: Arithmetic

    /// `budget` stops an operation that would run past the program's time limit.
    static func apply(
        _ binaryOperator: BinaryOperator,
        _ lhs: JSONValue,
        _ rhs: JSONValue,
        _ budget: Budget
    ) throws -> JSONValue {
        switch binaryOperator {
        case .add: try add(lhs, rhs)
        case .subtract: try subtract(lhs, rhs, budget)
        case .multiply: try multiply(lhs, rhs, budget)
        case .divide: try divide(lhs, rhs, budget)
        case .modulo: try modulo(lhs, rhs)
        case .equal: .bool(try JSONValue.compare(lhs, rhs, budget) == 0)
        case .notEqual: .bool(try JSONValue.compare(lhs, rhs, budget) != 0)
        case .less: .bool(try JSONValue.compare(lhs, rhs, budget) < 0)
        case .lessOrEqual: .bool(try JSONValue.compare(lhs, rhs, budget) <= 0)
        case .greater: .bool(try JSONValue.compare(lhs, rhs, budget) > 0)
        case .greaterOrEqual: .bool(try JSONValue.compare(lhs, rhs, budget) >= 0)
        }
    }

    private static func failure(_ lhs: JSONValue, _ rhs: JSONValue, _ verb: String) -> JQError {
        JQError("\(describe(lhs)) and \(describe(rhs)) cannot be \(verb)")
    }

    static func add(_ lhs: JSONValue, _ rhs: JSONValue) throws -> JSONValue {
        switch (lhs, rhs) {
        case (.null, _): return rhs
        case (_, .null): return lhs
        case let (.number(left, _), .number(right, _)): return .number(left + right)
        case let (.string(left), .string(right)):
            try checkSize(stringBytes: left.utf8.count + right.utf8.count)
            return .string(left + right)
        case let (.array(left), .array(right)):
            try checkSize(arrayCount: left.count + right.count)
            return .array(left + right)
        case let (.object(left), .object(right)):
            var merged = left
            for (key, value) in right.entries { merged[key] = value }
            return .object(merged)
        default: throw failure(lhs, rhs, "added")
        }
    }

    static func subtract(_ lhs: JSONValue, _ rhs: JSONValue, _ budget: Budget) throws -> JSONValue {
        switch (lhs, rhs) {
        case let (.number(left, _), .number(right, _)):
            return .number(left - right)
        case let (.array(left), .array(right)):
            let kept = try left.filter { element in
                try budget.check()
                return try !right.contains { try JSONValue.compare($0, element, budget) == 0 }
            }
            return .array(kept)
        default:
            throw failure(lhs, rhs, "subtracted")
        }
    }

    static func multiply(_ lhs: JSONValue, _ rhs: JSONValue, _ budget: Budget) throws -> JSONValue {
        switch (lhs, rhs) {
        case let (.number(left, _), .number(right, _)):
            return .number(left * right)
        case let (.string(text), .number(count, _)), let (.number(count, _), .string(text)):
            guard count >= 0 else { return .null }
            // Repeating nothing gives nothing, however many times, so no loop runs.
            guard !text.isEmpty else { return .string("") }
            let times = integer(count.rounded(.down))
            let total = text.utf8.count.multipliedReportingOverflow(by: times)
            guard !total.overflow, total.partialValue <= maxStringBytes else {
                throw JQError("Repeat string result too long")
            }
            return .string(String(repeating: text, count: times))
        case let (.object(left), .object(right)):
            let merged = try deepMerge(left, right, budget)
            return .object(merged)
        default:
            throw failure(lhs, rhs, "multiplied")
        }
    }

    private static func deepMerge(_ base: JSONObject, _ overlay: JSONObject, _ budget: Budget) throws -> JSONObject {
        var result = base
        for (key, value) in overlay.entries {
            try budget.checkPeriodically()
            if case let .object(left)? = result[key], case let .object(right) = value {
                let merged = try deepMerge(left, right, budget)
                result[key] = .object(merged)
            } else {
                result[key] = value
            }
        }
        return result
    }

    static func divide(_ lhs: JSONValue, _ rhs: JSONValue, _ budget: Budget) throws -> JSONValue {
        switch (lhs, rhs) {
        case let (.number(left, _), .number(right, _)):
            guard right != 0 else {
                throw JQError("\(describe(lhs)) and \(describe(rhs)) cannot be divided because the divisor is zero")
            }
            return .number(left / right)
        case let (.string(text), .string(separator)):
            let parts = try split(text, by: separator, budget).map(JSONValue.string)
            return .array(parts)
        default:
            throw failure(lhs, rhs, "divided")
        }
    }

    static func modulo(_ lhs: JSONValue, _ rhs: JSONValue) throws -> JSONValue {
        guard case let .number(dividend, _) = lhs, case let .number(divisorValue, _) = rhs else {
            throw failure(lhs, rhs, "divided")
        }
        guard !dividend.isNaN, !divisorValue.isNaN else { return .number(.nan) }
        let divisor = integer(divisorValue)
        guard divisor != 0 else {
            let operands = "\(describe(lhs)) and \(describe(rhs))"
            throw JQError("\(operands) cannot be divided (remainder) because the divisor is zero")
        }
        let result = integer(dividend).remainderReportingOverflow(dividingBy: divisor)
        return .int(result.overflow ? 0 : result.partialValue)
    }

    /// Splits on a literal separator. An empty separator splits into characters.
    static func split(_ text: String, by separator: String, _ budget: Budget) throws -> [String] {
        guard !text.isEmpty else { return [] }
        if separator.isEmpty {
            try checkSize(arrayCount: text.unicodeScalars.count)
            return text.unicodeScalars.map { String($0) }
        }
        let bytes = Array(text.utf8), needle = Array(separator.utf8)
        var parts: [String] = []
        var start = 0
        let offsets = try occurrences(of: needle, in: bytes, progress: budget.check, matches: ==)
        for offset in offsets where offset >= start {
            parts.append(String(repairingUTF8: bytes[start..<offset]))
            try checkSize(arrayCount: parts.count)
            start = offset + needle.count
        }
        parts.append(String(repairingUTF8: bytes[start...]))
        return parts
    }

    // MARK: Containment

    /// `contains`: the top-level kinds must match, with `true` and `false` as different kinds, as
    /// in jq. Nested values of different kinds just do not contain each other. `budget` stops a
    /// containment check that would run past the program's time limit.
    static func contains(_ lhs: JSONValue, _ rhs: JSONValue, _ budget: Budget) throws -> Bool {
        guard lhs.typeName == rhs.typeName, lhs.isTruthy == rhs.isTruthy else {
            throw JQError("\(describe(lhs)) and \(describe(rhs)) cannot have their containment checked")
        }
        return try containsValue(lhs, rhs, budget)
    }

    private static func containsValue(_ lhs: JSONValue, _ rhs: JSONValue, _ budget: Budget) throws -> Bool {
        try budget.checkPeriodically()
        switch (lhs, rhs) {
        case let (.object(container), .object(contained)):
            for (key, value) in contained.entries {
                guard let mine = container[key], try containsValue(mine, value, budget) else { return false }
            }
            return true
        case let (.array(container), .array(contained)):
            for needle in contained {
                try budget.check()
                var found = false
                for element in container where try containsValue(element, needle, budget) {
                    found = true
                    break
                }
                if !found { return false }
            }
            return true
        case let (.string(container), .string(contained)):
            let needle = Array(contained.utf8)
            guard !needle.isEmpty else { return true }
            let haystack = Array(container.utf8)
            let found = try occurrences(of: needle, in: haystack, limit: 1, progress: budget.check, matches: ==)
            return !found.isEmpty
        default:
            return try JSONValue.compare(lhs, rhs, budget) == 0
        }
    }

    /// Byte offsets where `needle` occurs in `haystack`, overlapping occurrences included.
    static func utf8Offsets(of needle: String, in haystack: String, _ budget: Budget) throws -> [Int] {
        try occurrences(of: Array(needle.utf8), in: Array(haystack.utf8), progress: budget.check, matches: ==)
    }

    /// Where `needle` starts in `haystack`, overlapping occurrences included, at most `limit` of
    /// them. Knuth–Morris–Pratt, so the time grows with the lengths added, not multiplied.
    /// `progress` is called every million elements of `haystack` and may throw to stop.
    static func occurrences<Element>(
        of needle: [Element],
        in haystack: [Element],
        limit: Int = .max,
        progress: () throws -> Void,
        matches: (Element, Element) throws -> Bool
    ) rethrows -> [Int] {
        guard !needle.isEmpty, needle.count <= haystack.count else { return [] }
        // fallback[i]: the length of the longest proper prefix of needle[...i] that is also its suffix.
        var fallback = [Int](repeating: 0, count: needle.count)
        var matched = 0
        for index in needle.indices.dropFirst() {
            while matched > 0, try !matches(needle[index], needle[matched]) { matched = fallback[matched - 1] }
            if try matches(needle[index], needle[matched]) { matched += 1 }
            fallback[index] = matched
        }
        var starts: [Int] = []
        matched = 0
        for (index, element) in haystack.enumerated() {
            if index & 0xF_FFFF == 0 { try progress() }
            while matched > 0, try !matches(element, needle[matched]) { matched = fallback[matched - 1] }
            if try matches(element, needle[matched]) { matched += 1 }
            guard matched == needle.count else { continue }
            starts.append(index - needle.count + 1)
            if starts.count >= limit { return starts }
            matched = fallback[matched - 1]
        }
        return starts
    }
}
