//
//  JSONParser+Scalars.swift
//  AgentVFSJQ
//
//  Created by Yevhenii Kalashnikov on 15.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

/// A bad escape in a JSON string, reported once the string ends.
private struct InvalidEscape: Error {
    let message: String
}

// MARK: Scalars

extension JSONStreamParser {

    mutating func parseKeyword() throws -> JSONValue {
        let start = index
        skipWord()
        let word = bytes[start..<index]
        if word.elementsEqual("true".utf8) { return .bool(true) }
        if word.elementsEqual("false".utf8) { return .bool(false) }
        if word.elementsEqual("null".utf8) { return .null }
        if word.elementsEqual("nan".utf8) || word.elementsEqual("NaN".utf8) { return .number(.nan) }
        throw failure("Invalid numeric literal")
    }

    mutating func parseNumber() throws -> JSONValue {
        let start = index
        if bytes[index] == UInt8(ascii: "-") { index += 1 }
        if index < bytes.count, bytes[index] == UInt8(ascii: "N") || bytes[index] == UInt8(ascii: "n") {
            let value = try parseKeyword()
            if case .number = value { return value }
            throw failure("Invalid numeric literal")
        }
        guard skipDigits() > 0 else { throw failure("Invalid numeric literal") }
        try skipFractionAndExponent()
        if index < bytes.count, isLetter(bytes[index]) {
            skipWord()
            throw failure("Invalid numeric literal")
        }
        let text = String(repairingUTF8: bytes[start..<index])
        guard let value = Double(text) else { throw failure("Invalid numeric literal") }
        return .number(value, literal: JSONValue.canonicalLiteral(Substring(text)))
    }

    /// Skips the `.DIGITS` and `eDIGITS` parts of a number, when it has them.
    private mutating func skipFractionAndExponent() throws {
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            guard skipDigits() > 0 else { throw failure("Invalid numeric literal") }
        }
        guard index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") else {
            return
        }
        index += 1
        if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
            index += 1
        }
        guard skipDigits() > 0 else { throw failure("Invalid numeric literal") }
    }

    /// Skips ASCII digits and returns how many there were.
    private mutating func skipDigits() -> Int {
        let start = index
        while index < bytes.count, bytes[index] >= UInt8(ascii: "0"), bytes[index] <= UInt8(ascii: "9") { index += 1 }
        return index - start
    }

    private func isLetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
    }

    mutating func parseString() throws -> String {
        index += 1
        var buffer: [UInt8] = []
        // Like jq, a bad escape is reported where the string ends.
        var invalidEscape: InvalidEscape?
        while true {
            guard index < bytes.count else { throw failure("Unfinished string") }
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "\""):
                if let invalidEscape { throw failure(invalidEscape.message, consumed: 1) }
                guard buffer.count <= Operations.maxStringBytes else {
                    throw failure("String too large (more than \(Operations.maxStringBytes) bytes)", consumed: 1)
                }
                index += 1
                return String(repairingUTF8: buffer)
            case UInt8(ascii: "\\"):
                index += 1
                guard index < bytes.count else { throw failure("Unfinished string") }
                let escape = bytes[index]
                index += 1
                do {
                    try appendEscape(escape, to: &buffer)
                } catch let error as InvalidEscape {
                    invalidEscape = invalidEscape ?? error
                }
            case UInt8(ascii: "\n"):
                buffer.append(byte)
                index += 1
                line += 1
                lineStart = index
            default:
                buffer.append(byte)
                index += 1
            }
        }
    }

    /// Appends the UTF-8 bytes for the escape that follows a backslash.
    private mutating func appendEscape(_ escape: UInt8, to buffer: inout [UInt8]) throws {
        switch escape {
        case UInt8(ascii: "\""): buffer.append(UInt8(ascii: "\""))
        case UInt8(ascii: "\\"): buffer.append(UInt8(ascii: "\\"))
        case UInt8(ascii: "/"): buffer.append(UInt8(ascii: "/"))
        case UInt8(ascii: "b"): buffer.append(0x08)
        case UInt8(ascii: "f"): buffer.append(0x0C)
        case UInt8(ascii: "n"): buffer.append(0x0A)
        case UInt8(ascii: "r"): buffer.append(0x0D)
        case UInt8(ascii: "t"): buffer.append(0x09)
        case UInt8(ascii: "u"): try appendUnicodeEscape(to: &buffer)
        default: throw InvalidEscape(message: "Invalid escape")
        }
    }

    /// `\uXXXX`, joining a surrogate pair. A high surrogate must be followed by a low one, and a
    /// lone low surrogate becomes U+FFFD, as in jq.
    private mutating func appendUnicodeEscape(to buffer: inout [UInt8]) throws {
        let unit = try hex4()
        let scalar: Unicode.Scalar
        if (0xD800...0xDBFF).contains(unit) {
            let pairError = InvalidEscape(message: "Invalid \\uXXXX\\uXXXX surrogate pair escape")
            let followedByEscape = index + 1 < bytes.count && bytes[index] == UInt8(ascii: "\\")
            guard followedByEscape, bytes[index + 1] == UInt8(ascii: "u") else { throw pairError }
            index += 2
            let low = try hex4()
            guard (0xDC00...0xDFFF).contains(low) else { throw pairError }
            scalar = try Self.scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00))
        } else if (0xDC00...0xDFFF).contains(unit) {
            scalar = "\u{FFFD}"
        } else {
            scalar = try Self.scalar(unit)
        }
        buffer.append(contentsOf: Array(String(scalar).utf8))
    }

    /// The scalar of a code point that is not a surrogate.
    private static func scalar(_ codePoint: UInt32) throws -> Unicode.Scalar {
        guard let scalar = Unicode.Scalar(codePoint) else {
            throw InvalidEscape(message: "Invalid code point \(codePoint)")
        }
        return scalar
    }

    private mutating func hex4() throws -> UInt32 {
        let digits = bytes[index..<min(index + 4, bytes.count)].map(UInt32.init)
        guard let value = HexDigits.value(of: digits) else {
            throw InvalidEscape(message: "Invalid characters in \\uXXXX escape")
        }
        index += 4
        return value
    }
}

/// Exactly four hexadecimal digits, as `\uXXXX` escapes take them.
enum HexDigits {

    /// The value of four ASCII hex digits, or `nil` when there are not four or one is not a digit.
    static func value(of codes: [UInt32]) -> UInt32? {
        guard codes.count == 4 else { return nil }
        var value: UInt32 = 0
        for code in codes {
            let digit: UInt32
            switch code {
            case 0x30...0x39: digit = code - 0x30
            case 0x41...0x46: digit = code - 0x41 + 10
            case 0x61...0x66: digit = code - 0x61 + 10
            default: return nil
            }
            value = value << 4 | digit
        }
        return value
    }
}
