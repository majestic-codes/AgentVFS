//
//  Formats.swift
//  AgentVFSJQ
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import Foundation

/// `@text`, `@json`, `@csv` and the other string formats.
enum Formats {
    /// `budget` stops turning a large value into text past the program's limits.
    static func apply(_ name: String, _ value: JSONValue, _ budget: Budget) throws -> String {
        switch name {
        case "json": return try value.boundedJSON(budget)
        case "csv": return try csv(value)
        case "tsv": return try tsv(value)
        case "sh": return try shell(value)
        case "text", "html", "uri", "base64", "base64d", "base32", "base32d":
            let text = try value.boundedText(budget)
            return try applyToText(name, text)
        default: throw JQError("\(name) is not a valid format")
        }
    }

    /// The formats that work on the value as text, as `tostring` gives it.
    private static func applyToText(_ name: String, _ text: String) throws -> String {
        switch name {
        case "text": text
        case "html": escapeHTML(text)
        case "uri": escapeURI(text)
        case "base64": Data(text.utf8).base64EncodedString()
        case "base64d": try decodeBase64(text)
        case "base32": encodeBase32(Array(text.utf8))
        case "base32d": try decodeBase32(text)
        default: throw JQError("\(name) is not a valid format")
        }
    }

    private static func escapeHTML(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "&": out += "&amp;"
            case "'": out += "&apos;"
            case "\"": out += "&quot;"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Percent-encodes every byte except ASCII letters, digits and `-_.~`.
    private static func escapeURI(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            let character = Character(Unicode.Scalar(byte))
            if byte < 0x80, character.isLetter || character.isNumber || "-_.~".contains(character) {
                out.append(character)
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    private static func csv(_ value: JSONValue) throws -> String {
        guard case let .array(elements) = value else {
            throw JQError("\(Operations.describe(value)) cannot be csv-formatted, only array")
        }
        let fields = try elements.map { element -> String in
            switch element {
            case .number: element.json
            case let .string(text): "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            case let .bool(flag): flag ? "true" : "false"
            case .null: ""
            default: throw JQError("\(Operations.describe(element)) is not valid in a csv row")
            }
        }
        return fields.joined(separator: ",")
    }

    private static func tsv(_ value: JSONValue) throws -> String {
        guard case let .array(elements) = value else {
            throw JQError("\(Operations.describe(value)) cannot be tsv-formatted, only array")
        }
        let fields = try elements.map { element -> String in
            switch element {
            case .number: element.json
            case let .string(text): escapeTSV(text)
            case let .bool(flag): flag ? "true" : "false"
            case .null: ""
            default: throw JQError("\(Operations.describe(element)) is not valid in a tsv row")
            }
        }
        return fields.joined(separator: "\t")
    }

    private static func escapeTSV(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    /// Single-quotes a string, or each element of an array, separated by spaces.
    private static func shell(_ value: JSONValue) throws -> String {

        func quote(_ element: JSONValue) throws -> String {
            switch element {
            case let .string(text): "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
            case .array, .object: throw JQError("\(Operations.describe(element)) can not be escaped for shell")
            default: element.json
            }
        }
        if case let .array(elements) = value {
            return try elements.map(quote).joined(separator: " ")
        }
        return try quote(value)
    }

    private static func decodeBase64(_ text: String) throws -> String {
        var values: [UInt8] = []
        // Like jq, decoding stops at the first `=`, wherever it is.
        for byte in text.utf8.prefix(while: { $0 != UInt8(ascii: "=") }) {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): values.append(byte - UInt8(ascii: "A"))
            case UInt8(ascii: "a")...UInt8(ascii: "z"): values.append(byte - UInt8(ascii: "a") + 26)
            case UInt8(ascii: "0")...UInt8(ascii: "9"): values.append(byte - UInt8(ascii: "0") + 52)
            case UInt8(ascii: "+"): values.append(62)
            case UInt8(ascii: "/"): values.append(63)
            default: throw JQError("\(Operations.describe(.string(text))) is not valid base64 data")
            }
        }
        if values.count % 4 == 1 {
            throw JQError("\(Operations.describe(.string(text))) trailing base64 byte found")
        }
        var bytes: [UInt8] = []
        var index = 0
        while index < values.count {
            let chunk = values[index..<min(index + 4, values.count)]
            let padded = Array(chunk) + Array(repeating: 0, count: 4 - chunk.count)
            let high = UInt32(padded[0]) << 18 | UInt32(padded[1]) << 12
            let combined = high | UInt32(padded[2]) << 6 | UInt32(padded[3])
            let produced = [UInt8(combined >> 16 & 0xFF), UInt8(combined >> 8 & 0xFF), UInt8(combined & 0xFF)]
            bytes.append(contentsOf: produced.prefix(chunk.count - 1))
            index += 4
        }
        return String(repairingUTF8: bytes)
    }

    private static let base32Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)

    private static func encodeBase32(_ bytes: [UInt8]) -> String {
        var out: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let chunk = Array(bytes[index..<min(index + 5, bytes.count)])
            let padded = chunk + Array(repeating: 0, count: 5 - chunk.count)
            var bits: UInt64 = 0
            for byte in padded { bits = bits << 8 | UInt64(byte) }
            let characters = [2, 4, 5, 7, 8][chunk.count - 1]
            for position in 0..<8 {
                if position < characters {
                    out.append(base32Alphabet[Int(bits >> UInt64(35 - position * 5) & 0x1F)])
                } else {
                    out.append(UInt8(ascii: "="))
                }
            }
            index += 5
        }
        return String(repairingUTF8: out)
    }

    private static func decodeBase32(_ text: String) throws -> String {
        var bits: UInt64 = 0
        var count = 0
        var bytes: [UInt8] = []
        for byte in text.utf8 {
            if byte == UInt8(ascii: "=") { continue }
            guard let value = base32Alphabet.firstIndex(of: byte) else {
                throw JQError("\(Operations.describe(.string(text))) is not valid base32 data")
            }
            bits = bits << 5 | UInt64(value)
            count += 5
            if count >= 8 {
                count -= 8
                bytes.append(UInt8(bits >> UInt64(count) & 0xFF))
            }
        }
        return String(repairingUTF8: bytes)
    }
}
