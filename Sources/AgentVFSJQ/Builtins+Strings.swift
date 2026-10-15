//
//  Builtins+Strings.swift
//  AgentVFSJQ
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import Foundation

extension Builtins {

    static func registerStrings(_ table: inout [String: Native]) {
        table["startswith/1"] = withValues { value, arguments in
            guard case let .string(text) = value, case let .string(prefix) = arguments[0] else {
                throw JQError("startswith() requires string inputs")
            }
            return .bool(text.utf8.starts(with: prefix.utf8))
        }
        table["endswith/1"] = withValues { value, arguments in
            guard case let .string(text) = value, case let .string(suffix) = arguments[0] else {
                throw JQError("endswith() requires string inputs")
            }
            return .bool(text.utf8.reversed().starts(with: suffix.utf8.reversed()))
        }
        table["ltrimstr/1"] = withValues { value, arguments in
            guard case let .string(text) = value, case let .string(prefix) = arguments[0],
                  text.utf8.starts(with: prefix.utf8) else {
                return value
            }
            return .string(String(repairingUTF8: text.utf8.dropFirst(prefix.utf8.count)))
        }
        table["rtrimstr/1"] = withValues { value, arguments in
            guard case let .string(text) = value, case let .string(suffix) = arguments[0],
                  text.utf8.reversed().starts(with: suffix.utf8.reversed()) else {
                return value
            }
            return .string(String(repairingUTF8: text.utf8.dropLast(suffix.utf8.count)))
        }
        for (name, edges) in [("trim", (true, true)), ("ltrim", (true, false)), ("rtrim", (false, true))] {
            table["\(name)/0"] = simple { value in
                guard case let .string(text) = value else { throw JQError("trim input must be a string") }
                return .string(trimmed(text, leading: edges.0, trailing: edges.1))
            }
        }
    }

    private static func trimmed(_ text: String, leading: Bool, trailing: Bool) -> String {
        var scalars = Substring(text).unicodeScalars[...]
        if leading {
            while let first = scalars.first, first.properties.isWhitespace { scalars.removeFirst() }
        }
        if trailing {
            while let last = scalars.last, last.properties.isWhitespace { scalars.removeLast() }
        }
        return String(String.UnicodeScalarView(scalars))
    }

    static func registerStringTransforms(_ table: inout [String: Native]) {
        table["explode/0"] = simple { value in
            guard case let .string(text) = value else { throw JQError("explode input must be a string") }
            try Operations.checkSize(arrayCount: text.unicodeScalars.count)
            return .array(text.unicodeScalars.map { .int(Int($0.value)) })
        }
        table["implode/0"] = simple(implode)
        table["split/1"] = { interpreter, input, arguments, env, _, sink in
            try interpreter.withArguments(arguments, input, env) { values in
                guard case let .string(text) = input.value, case let .string(separator) = values[0] else {
                    throw JQError("split input and separator must be strings")
                }
                let parts = try Operations.split(text, by: separator, interpreter.budget)
                return try sink(Item(.array(parts.map(JSONValue.string)), depth: 1))
            }
        }
        table["_strindices/1"] = { interpreter, input, arguments, env, _, sink in
            try interpreter.withArguments(arguments, input, env) { values in
                guard case let .string(text) = input.value, case let .string(needle) = values[0] else {
                    throw JQError("_strindices requires string inputs")
                }
                let offsets = try Operations.utf8Offsets(of: needle, in: text, interpreter.budget)
                return try sink(Item(.array(scalarOffsets(offsets, in: text).map { .int($0) }), depth: 1))
            }
        }
        for (name, upper) in [("ascii_downcase", false), ("ascii_upcase", true)] {
            table["\(name)/0"] = simple { value in
                guard case let .string(text) = value else { throw JQError("explode input must be a string") }
                return .string(asciiCased(text, upper: upper))
            }
        }
    }

    private static func implode(_ value: JSONValue) throws -> JSONValue {
        guard case let .array(elements) = value else { throw JQError("implode input must be an array") }
        var text = String.UnicodeScalarView()
        for element in elements {
            guard case let .number(code, _) = element else {
                let description = Operations.describe(element)
                throw JQError("\(description) can't be imploded, unicode codepoint needs to be numeric")
            }
            let codepoint = Operations.integer(code)
            let scalar = codepoint >= 0 && codepoint <= 0x10FFFF ? Unicode.Scalar(UInt32(codepoint)) : nil
            text.append(scalar ?? "\u{FFFD}")
        }
        return .string(String(text))
    }

    /// Changes the case of ASCII letters only.
    private static func asciiCased(_ text: String, upper: Bool) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if upper, scalar >= "a", scalar <= "z" {
                scalars.append(Unicode.Scalar(UInt8(scalar.value - 32)))
            } else if !upper, scalar >= "A", scalar <= "Z" {
                scalars.append(Unicode.Scalar(UInt8(scalar.value + 32)))
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}
