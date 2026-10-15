//
//  JSONValue+Serialization.swift
//  AgentVFSJQ
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

// MARK: Serialization

/// How `JSONValue.serialized` lays out text.
public struct JSONFormat: Sendable, Hashable {
    /// Spaces per level, from 0 to `maxIndent`. 0 is compact unless `useTabs` is set.
    public var indent: Int {
        didSet { Self.checkIndent(indent) }
    }
    /// Indents with one tab per level in place of spaces.
    public var useTabs: Bool
    /// Writes object keys in sorted order rather than insertion order.
    public var sortKeys: Bool
    /// Escapes everything outside ASCII as `\uXXXX`.
    public var asciiOnly: Bool

    /// The largest `indent`, as in jq.
    public static let maxIndent = 7

    /// A layout with `indent` spaces per level, which must be from 0 to `maxIndent`.
    public init(indent: Int = 2, useTabs: Bool = false, sortKeys: Bool = false, asciiOnly: Bool = false) {
        Self.checkIndent(indent)
        self.indent = indent
        self.useTabs = useTabs
        self.sortKeys = sortKeys
        self.asciiOnly = asciiOnly
    }

    private static func checkIndent(_ indent: Int) {
        let message = "JSONFormat.indent must be from 0 to \(maxIndent), not \(indent)"
        precondition((0...maxIndent).contains(indent), message)
    }

    /// No whitespace between tokens.
    public static let compact = Self(indent: 0)

    var isPretty: Bool { useTabs || indent > 0 }

    /// Starts a new line indented to `level`, when the layout is pretty.
    func newline(into out: inout String, level: Int) {
        guard isPretty else { return }
        out += "\n"
        if useTabs {
            out += String(repeating: "\t", count: level)
        } else {
            out += String(repeating: " ", count: level * indent)
        }
    }
}

extension JSONValue {
    /// The value as JSON text laid out by `format`, compact by default.
    public func serialized(_ format: JSONFormat = .compact) -> String {
        serialized(format, limit: .max)
    }

    /// The text `serialized(format)` gives, stopped soon after it passes `limit` bytes. Text
    /// longer than `limit` means the value did not fit.
    func serialized(_ format: JSONFormat, limit: Int) -> String {
        var writer = JSONWriter(format: format, limit: limit, budget: nil)
        writer.write(self, level: 0)
        return writer.out
    }

    /// The text `serialized(format, limit:)` gives, and throws once `budget` runs out first.
    func serialized(_ format: JSONFormat, limit: Int, budget: Budget) throws -> String {
        var writer = JSONWriter(format: format, limit: limit, budget: budget)
        writer.write(self, level: 0)
        if let failure = writer.failure { throw failure }
        return writer.out
    }

    /// Compact JSON, as `tojson` produces.
    var json: String { serialized(.compact) }

    /// Compact JSON, refusing values whose text would pass the longest string jq builds, and
    /// stopping when `budget` runs out.
    func boundedJSON(_ budget: Budget) throws -> String {
        var writer = JSONWriter(format: .compact, limit: Operations.maxStringBytes, budget: budget)
        writer.write(self, level: 0)
        if let failure = writer.failure { throw failure }
        try Operations.checkSize(stringBytes: writer.out.utf8.count)
        return writer.out
    }

    /// `tostring`: strings unchanged, everything else as compact JSON, with the limits of
    /// `boundedJSON`.
    func boundedText(_ budget: Budget) throws -> String {
        if case let .string(value) = self { return value }
        return try boundedJSON(budget)
    }

    /// A value for error messages, cut to 11 characters like jq does.
    var errorDescription: String {
        let dumped = serialized(.compact, limit: 64)
        guard dumped.count > 11 else { return dumped }
        return String(dumped.prefix(11)) + "..."
    }

    /// Like jq, values nested deeper than this are not printed.
    static let maxPrintDepth = 256

    static func writeString(_ value: String, into out: inout String, asciiOnly: Bool) {
        out += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04x", scalar.value)
                } else if asciiOnly && scalar.value > 0x7E {
                    for unit in String(scalar).utf16 {
                        out += String(format: "\\u%04x", unit)
                    }
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    /// Prints a number like jq 1.7: literals keep their canonical text, computed numbers use the
    /// shortest representation that round-trips.
    static func formatNumber(_ value: Double, literal: String?) -> String {
        if let literal { return literal }
        if value.isNaN { return "null" }
        if value.isInfinite { return value > 0 ? "1.7976931348623157e+308" : "-1.7976931348623157e+308" }
        if value == 0 { return value.sign == .minus ? "-0" : "0" }
        let sign = value < 0 ? "-" : ""
        let (digits, point) = shortestDigits(abs(value))
        return sign + dtoaLayout(digits, point: point)
    }

    /// The shortest round-trip digits of a positive number, without leading or trailing zeros,
    /// and where the decimal point goes: the value is `0.DIGITS × 10^point`.
    private static func shortestDigits(_ magnitude: Double) -> (digits: [Character], point: Int) {
        let parts = magnitude.description.split(separator: "e", maxSplits: 1)
        var exponent = 0
        if parts.count > 1, let written = Int(parts[1]) { exponent = written }
        let pieces = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        let integer = String(pieces[0])
        let fraction = pieces.count > 1 ? String(pieces[1]) : ""
        var digits = Array(integer + fraction)
        var point = integer.count + exponent
        while digits.first == "0" {
            digits.removeFirst()
            point -= 1
        }
        while digits.last == "0" { digits.removeLast() }
        return (digits, point)
    }

    /// Lays out digits the way jq's dtoa does: exponent form for very small or large numbers.
    private static func dtoaLayout(_ digits: [Character], point: Int) -> String {
        let count = digits.count
        if point <= -4 || point > count + 15 {
            var text = String(digits[0])
            if count > 1 { text += "." + String(digits[1...]) }
            let power = point - 1
            text += "e" + (power < 0 ? "-" : "+") + (abs(power) < 10 ? "0" : "") + String(abs(power))
            return text
        }
        if point <= 0 {
            return "0." + String(repeating: "0", count: -point) + String(digits)
        }
        if point >= count {
            return String(digits) + String(repeating: "0", count: point - count)
        }
        return String(digits[..<point]) + "." + String(digits[point...])
    }

    /// The canonical text jq 1.7 keeps for a number literal (decNumber's scientific form), or `nil`
    /// when the exponent is beyond decNumber's range and jq keeps only the double.
    static func canonicalLiteral(_ text: Substring) -> String? {
        var characters = Array(text)
        var sign = ""
        if characters.first == "-" {
            sign = "-"
            characters.removeFirst()
        } else if characters.first == "+" {
            characters.removeFirst()
        }
        guard let parts = decimalParts(characters) else { return nil }
        var coefficient = parts.coefficient
        let exponent = parts.exponent
        while coefficient.count > 1, coefficient.first == "0" { coefficient.removeFirst() }
        if coefficient.isEmpty { coefficient = ["0"] }
        let adjusted = exponent + coefficient.count - 1
        guard adjusted <= maxLiteralExponent, exponent >= minLiteralExponent else { return nil }
        return sign + decimalLayout(coefficient, exponent: exponent)
    }

    /// The largest adjusted exponent decNumber keeps in jq: `1E+999999999`.
    private static let maxLiteralExponent = 999_999_999
    /// The smallest exponent decNumber keeps in jq, counting its subnormal numbers.
    private static let minLiteralExponent = -1_999_999_999

    /// Splits unsigned number text into its digits and the power of ten they are scaled by, or
    /// `nil` when the written exponent has more digits than any literal jq keeps.
    private static func decimalParts(_ characters: [Character]) -> (coefficient: [Character], exponent: Int)? {
        var coefficient: [Character] = []
        var exponent = 0
        var index = 0
        var seenPoint = false
        while index < characters.count, characters[index] != "e", characters[index] != "E" {
            if characters[index] == "." {
                seenPoint = true
            } else {
                coefficient.append(characters[index])
                if seenPoint { exponent -= 1 }
            }
            index += 1
        }
        guard index < characters.count else { return (coefficient, exponent) }
        var written = characters[(index + 1)...]
        var negative = false
        if let marker = written.first, marker == "+" || marker == "-" {
            negative = marker == "-"
            written = written.dropFirst()
        }
        let digits = written.drop { $0 == "0" }
        let parsed = digits.isEmpty ? 0 : Int(String(digits))
        guard digits.count <= maxExponentDigits, let magnitude = parsed else { return nil }
        exponent += negative ? -magnitude : magnitude
        return (coefficient, exponent)
    }

    /// Digits of a written exponent past which the literal is out of range whatever its coefficient.
    private static let maxExponentDigits = 12

    /// Lays out digits scaled by a power of ten the way decNumber's to-scientific-string does.
    private static func decimalLayout(_ coefficient: [Character], exponent: Int) -> String {
        let count = coefficient.count
        let adjusted = exponent + count - 1
        if exponent <= 0 && adjusted >= -6 {
            if exponent == 0 { return String(coefficient) }
            let pointIndex = count + exponent
            if pointIndex > 0 {
                return String(coefficient[..<pointIndex]) + "." + String(coefficient[pointIndex...])
            }
            return "0." + String(repeating: "0", count: -pointIndex) + String(coefficient)
        }
        var result = String(coefficient[0])
        if count > 1 { result += "." + String(coefficient[1...]) }
        result += "E" + (adjusted >= 0 ? "+" : "-") + String(abs(adjusted))
        return result
    }
}

/// Writes JSON text, stopping soon after `limit` bytes or once `budget` runs out.
private struct JSONWriter {
    let format: JSONFormat
    let limit: Int
    let budget: Budget?
    var out = ""
    /// Why the budget stopped the writing.
    var failure: JQAbort?
    private var written = 0

    init(format: JSONFormat, limit: Int, budget: Budget?) {
        self.format = format
        self.limit = limit
        self.budget = budget
    }

    /// Whether to stop before the next value. Asks the budget every 4096 values.
    private mutating func isDone() -> Bool {
        if failure != nil || out.utf8.count > limit { return true }
        written += 1
        if written & 4095 == 0 { failure = budget?.failure() }
        return failure != nil
    }

    mutating func write(_ value: JSONValue, level: Int) {
        guard level <= JSONValue.maxPrintDepth else {
            out += "<skipped: too deep>"
            return
        }
        switch value {
        case .null:
            out += "null"
        case let .bool(flag):
            out += flag ? "true" : "false"
        case let .number(number, literal):
            out += JSONValue.formatNumber(number, literal: literal)
        case let .string(text):
            writeString(text)
        case let .array(elements):
            writeArray(elements, level: level)
        case let .object(object):
            writeObject(object, level: level)
        }
    }

    private mutating func writeString(_ text: String) {
        let room = max(limit - out.utf8.count, 0)
        guard text.utf8.count > room else {
            JSONValue.writeString(text, into: &out, asciiOnly: format.asciiOnly)
            return
        }
        // Escaping never shortens text, so a prefix one byte past the room shows the overflow.
        let shown = String(String.UnicodeScalarView(text.unicodeScalars.prefix(room + 1)))
        JSONValue.writeString(shown, into: &out, asciiOnly: format.asciiOnly)
    }

    private mutating func writeArray(_ elements: [JSONValue], level: Int) {
        guard !elements.isEmpty else {
            out += "[]"
            return
        }
        out += "["
        for (index, element) in elements.enumerated() {
            if isDone() { return }
            if index > 0 { out += "," }
            format.newline(into: &out, level: level + 1)
            write(element, level: level + 1)
        }
        format.newline(into: &out, level: level)
        out += "]"
    }

    private mutating func writeObject(_ object: JSONObject, level: Int) {
        guard !object.isEmpty else {
            out += "{}"
            return
        }
        out += "{"
        let entries = format.sortKeys ? object.sortedEntries : object.entries
        for (index, entry) in entries.enumerated() {
            if isDone() { return }
            if index > 0 { out += "," }
            format.newline(into: &out, level: level + 1)
            writeString(entry.key)
            out += format.isPretty ? ": " : ":"
            write(entry.value, level: level + 1)
        }
        format.newline(into: &out, level: level)
        out += "}"
    }
}
