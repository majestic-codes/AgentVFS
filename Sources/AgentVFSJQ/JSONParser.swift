//
//  JSONParser.swift
//  AgentVFSJQ
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import Foundation

struct JSONParseError: Error, Equatable {
    let message: String
}

/// Reads a stream of JSON values, such as a file with one document per line.
struct JSONStreamParser {
    let bytes: [UInt8]
    var index = 0
    var line = 1
    var lineStart = 0
    /// How deeply arrays and objects may nest. Each level takes a stack frame of the thread that
    /// parses, so callers on small stacks pass less.
    private let maxDepth: Int
    /// The most elements an array, or keys an object, may have.
    private let maxCount: Int
    /// Where the memory the parsed values take is noted, so a large input stops at the memory limit.
    private let budget: Budget?

    init(
        _ text: String,
        maxDepth: Int = Operations.maxDepth,
        maxCount: Int = Operations.maxArrayCount,
        budget: Budget? = nil
    ) {
        bytes = Array(text.utf8)
        self.maxDepth = maxDepth
        self.maxCount = maxCount
        self.budget = budget
    }

    /// The lines read when the last value was complete, which `input_line_number` and jq's
    /// messages show. jq reads its input a line at a time, so this counts the line the value ends
    /// on when a newline ends that line.
    private(set) var currentLine = 0
    /// Where the first newline at or after the last value's end is, or the input's length when
    /// there is none.
    private var nextNewline = -1

    /// The next value, or `nil` at the end of the input.
    mutating func next() throws -> JSONValue? {
        skipWhitespace()
        guard index < bytes.count else { return nil }
        let value = try parseValue(depth: 0)
        if nextNewline < index {
            nextNewline = bytes[index...].firstIndex(of: UInt8(ascii: "\n")) ?? bytes.count
        }
        currentLine = line - 1 + (nextNewline < bytes.count ? 1 : 0)
        return value
    }

    /// Parses text that must hold exactly one value, as `fromjson` and `tonumber` require.
    static func parseSingle(
        _ text: String,
        maxDepth: Int = Operations.maxDepth,
        budget: Budget? = nil
    ) throws -> JSONValue {
        var parser = Self(text, maxDepth: maxDepth, budget: budget)
        do {
            guard let value = try parser.next() else {
                throw JSONParseError(message: "Expected JSON value")
            }
            parser.skipWhitespace()
            if parser.index < parser.bytes.count {
                if parser.isValueStart(parser.bytes[parser.index]) {
                    _ = try parser.parseValue(depth: 0)
                    throw JSONParseError(message: "Unexpected extra JSON values")
                }
                parser.skipWord()
                throw parser.failure("Invalid numeric literal")
            }
            return value
        } catch let error as JSONParseError {
            throw JSONParseError(message: "\(error.message) (while parsing '\(text)')")
        }
    }

    private func isValueStart(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "{"), UInt8(ascii: "["), UInt8(ascii: "\""), UInt8(ascii: "-"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "t"), UInt8(ascii: "f"), UInt8(ascii: "n"), UInt8(ascii: "N"):
            true
        default:
            false
        }
    }

    /// An error at the current position, or `consumed` bytes past it when jq reads that far
    /// before it reports.
    func failure(_ message: String, consumed: Int = 0) -> JSONParseError {
        let column = index + consumed - lineStart
        if index >= bytes.count {
            return JSONParseError(message: "\(message) at EOF at line \(line), column \(column)")
        }
        return JSONParseError(message: "\(message) at line \(line), column \(column)")
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r"):
                index += 1
            case UInt8(ascii: "\n"):
                index += 1
                line += 1
                lineStart = index
            case 0xEF where index == 0 && isByteOrderMark:
                index += 3
            default:
                return
            }
        }
    }

    /// Whether the input starts with a UTF-8 byte order mark.
    private var isByteOrderMark: Bool {
        bytes.count > 2 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF
    }

    /// Each nested level takes a frame of this function and of `parseArray` or `parseObject`, so
    /// it does little but dispatch, and the rest happens in functions it calls.
    private mutating func parseValue(depth: Int) throws -> JSONValue {
        try startValue(depth: depth)
        let byte = bytes[index]
        if byte == Self.openBrace { return try noted(parseObject(depth: depth), storage: 3 * Budget.storageBytes) }
        if byte == Self.openBracket { return try noted(parseArray(depth: depth), storage: Budget.storageBytes) }
        return try parseScalar()
    }

    private static let openBrace = UInt8(ascii: "{")
    private static let openBracket = UInt8(ascii: "[")

    /// Skips whitespace up to the next value, checking it nests no deeper than `maxDepth`.
    @inline(never)
    private mutating func startValue(depth: Int) throws {
        guard depth <= maxDepth else { throw failure("Exceeds depth limit for parsing") }
        skipWhitespace()
        guard index < bytes.count else { throw failure("Unfinished JSON term") }
    }

    /// A string, number, `true`, `false`, `null` or `nan` at the current position.
    @inline(never)
    private mutating func parseScalar() throws -> JSONValue {
        switch bytes[index] {
        case UInt8(ascii: "\""):
            let text = try parseString()
            return try noted(.string(text), storage: Budget.storageBytes + text.utf8.count)
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            return try noted(parseNumber())
        case UInt8(ascii: "]"):
            throw failure("Unmatched ']'")
        case UInt8(ascii: "}"):
            throw failure("Unmatched '}'")
        default:
            return try noted(parseKeyword())
        }
    }

    /// `value`, after noting the memory it takes besides `storage` bytes of its own.
    @inline(never)
    private func noted(_ value: JSONValue, storage: Int = 0) throws -> JSONValue {
        try budget?.note(allocating: Budget.valueBytes + storage)
        return value
    }

    private mutating func parseObject(depth: Int) throws -> JSONValue {
        var object = JSONObject()
        guard try openContainer(closing: Self.closeBrace) else { return .object(object) }
        while true {
            let key = try parseKey()
            let member = try parseValue(depth: depth + 1)
            try insert(member, at: key, into: &object)
            if try endOfContainer(Self.closeBrace) { return .object(object) }
        }
    }

    private static let closeBrace = UInt8(ascii: "}")
    private static let closeBracket = UInt8(ascii: "]")

    /// Reads the opening bracket and returns whether members follow, or reads the closing one too
    /// and returns `false` for an empty container.
    @inline(never)
    private mutating func openContainer(closing: UInt8) throws -> Bool {
        index += 1
        skipWhitespace()
        guard index < bytes.count, bytes[index] == closing else { return true }
        index += 1
        return false
    }

    /// An object key and the `:` after it.
    @inline(never)
    private mutating func parseKey() throws -> String {
        skipWhitespace()
        guard index < bytes.count else { throw failure("Unfinished JSON term") }
        guard bytes[index] == UInt8(ascii: "\"") else { throw failure("Object keys must be strings") }
        let key = try parseString()
        skipWhitespace()
        guard index < bytes.count else { throw failure("Unfinished JSON term") }
        guard bytes[index] == UInt8(ascii: ":") else {
            throw failure("Objects must consist of key:value pairs")
        }
        index += 1
        return key
    }

    @inline(never)
    private func insert(_ member: JSONValue, at key: String, into object: inout JSONObject) throws {
        object[key] = member
        try checkCount(object.count, of: "Object", "keys")
        try budget?.note(allocating: Budget.memberBytes + key.utf8.count)
    }

    private mutating func parseArray(depth: Int) throws -> JSONValue {
        var elements: [JSONValue] = []
        guard try openContainer(closing: Self.closeBracket) else { return .array(elements) }
        while true {
            let element = try parseValue(depth: depth + 1)
            elements.append(element)
            try checkCount(elements.count, of: "Array", "elements")
            if try endOfContainer(Self.closeBracket) { return .array(elements) }
        }
    }

    /// Throws once a container holds more than `maxCount` members. Kept out of the recursive
    /// functions, whose frames every nested level takes.
    @inline(never)
    private func checkCount(_ count: Int, of container: String, _ members: String) throws {
        guard count > maxCount else { return }
        throw failure("\(container) too large (more than \(maxCount) \(members))")
    }

    /// Reads the `,` before the next member, returning `false`, or the closing bracket, returning
    /// `true`.
    private mutating func endOfContainer(_ closing: UInt8) throws -> Bool {
        skipWhitespace()
        guard index < bytes.count else { throw failure("Unfinished JSON term") }
        if bytes[index] == UInt8(ascii: ",") {
            index += 1
            return false
        }
        guard bytes[index] == closing else { throw failure("Expected separator between values") }
        index += 1
        return true
    }

    /// Skips a run of characters that cannot end a token, the way jq reads a bad literal whole.
    mutating func skipWord() {
        let start = index
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r"), UInt8(ascii: "\n"),
                 UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "{"), UInt8(ascii: "}"),
                 UInt8(ascii: ","), UInt8(ascii: ":"), UInt8(ascii: "\""):
                if index == start { index += 1 }
                return
            default:
                index += 1
            }
        }
    }
}
