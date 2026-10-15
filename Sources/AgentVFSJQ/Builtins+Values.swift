//
//  Builtins+Values.swift
//  AgentVFSJQ
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

// MARK: Core

extension Builtins {

    static func registerCore(_ table: inout [String: Native]) {
        table["empty/0"] = { _, _, _, _, _, _ in true }
        table["not/0"] = simple { .bool(!$0.isTruthy) }
        table["error/0"] = { _, input, _, _, _, _ in throw JQError(value: input.value) }
        table["error/1"] = { interpreter, input, arguments, env, _, _ in
            _ = try interpreter.eval(arguments[0], Item(input.value), env, false) { message in
                throw JQError(value: message.value)
            }
            return true
        }
        table["tostream/0"] = { interpreter, input, _, _, _, sink in
            var events = StreamEvents(input.value)
            while let event = events.next() {
                try interpreter.budget.checkPeriodically()
                guard try sink(Item(event)) else { return false }
            }
            return true
        }
        table["format/1"] = { interpreter, input, arguments, env, _, sink in
            try interpreter.withArguments(arguments, input, env) { values in
                let message = "\(Operations.describe(values[0])) is not a valid format"
                let format = try string(values[0], message)
                let text = try Formats.apply(format, input.value, interpreter.budget)
                return try sink(Item(.string(text)))
            }
        }
        table["_match_impl/3"] = { interpreter, input, arguments, env, _, sink in
            try interpreter.withArguments(arguments, input, env) { values in
                guard case let .bool(test) = values[2] else {
                    throw JQError("_match_impl/3: \(Operations.describe(values[2])) is not a boolean")
                }
                let result = try JQRegex.match(interpreter, input.value, values[0], values[1], test: test)
                return try sink(Item(result))
            }
        }
    }

    static func registerPaths(_ table: inout [String: Native]) {
        table["path/1"] = { interpreter, input, arguments, env, _, sink in
            try interpreter.eval(arguments[0], Item(input.value, path: .root), env, true) { item in
                guard let path = item.path else {
                    throw JQError("Invalid path expression with result \(item.value.errorDescription)")
                }
                return try sink(Item(.array(path.components)))
            }
        }
        table["getpath/1"] = { interpreter, input, arguments, env, tracking, sink in
            try interpreter.eval(arguments[0], Item(input.value), env, false) { path in
                guard case let .array(components) = path.value else {
                    throw JQError("Path must be specified as an array")
                }
                let value = try Operations.getpath(input.value, components, interpreter.budget)
                guard tracking else { return try sink(Item(value)) }
                guard let base = input.path else {
                    throw JQError("Invalid path expression with result \(input.value.errorDescription)")
                }
                return try sink(Item(value, path: base.appending(contentsOf: components)))
            }
        }
        table["setpath/2"] = { interpreter, input, arguments, env, _, sink in
            try interpreter.eval(arguments[1], input.detached, env, false) { newValue in
                try interpreter.eval(arguments[0], input.detached, env, false) { path in
                    guard case let .array(components) = path.value else {
                        throw JQError("Path must be specified as an array")
                    }
                    try Operations.checkLength(components)
                    let newValueDepth = try interpreter.depth(of: newValue)
                    let inputDepth = try interpreter.depth(of: input)
                    let nested = Operations.descents(components) + newValueDepth
                    let depth = try interpreter.allowedDepth(max(inputDepth, nested))
                    let result = try Operations.setpath(input.value, components[...], newValue.value)
                    return try sink(Item(result, depth: depth))
                }
            }
        }
        table["delpaths/1"] = { interpreter, input, arguments, env, _, sink in
            try interpreter.withArguments(arguments, input, env) { values in
                guard case let .array(paths) = values[0] else { throw JQError("Paths must be specified as an array") }
                let result = try Operations.delpaths(input.value, paths, interpreter.budget)
                return try sink(Item(result))
            }
        }
    }
}

// MARK: Values

extension Builtins {

    static func registerValues(_ table: inout [String: Native]) {
        table["length/0"] = simple { value in
            switch value {
            case .null: .int(0)
            case .bool: throw JQError("\(Operations.describe(value)) has no length")
            case let .number(number, _): .number(abs(number))
            case let .string(text): .int(text.unicodeScalars.count)
            case let .array(elements): .int(elements.count)
            case let .object(object): .int(object.count)
            }
        }
        table["utf8bytelength/0"] = simple { value in
            guard case let .string(text) = value else {
                throw JQError("\(Operations.describe(value)) only strings have UTF-8 byte length")
            }
            return .int(text.utf8.count)
        }
        table["type/0"] = simple { .string($0.typeName) }
        table["keys/0"] = simple { value in
            switch value {
            case let .object(object): .array(object.sortedKeys.map(JSONValue.string))
            case let .array(elements): .array(elements.indices.map { .int($0) })
            default: throw JQError("\(Operations.describe(value)) has no keys")
            }
        }
        table["keys_unsorted/0"] = simple { value in
            switch value {
            case let .object(object): .array(object.keys.map(JSONValue.string))
            case let .array(elements): .array(elements.indices.map { .int($0) })
            default: throw JQError("\(Operations.describe(value)) has no keys")
            }
        }
        table["has/1"] = withValues { value, arguments in
            switch (value, arguments[0]) {
            case let (.object(object), .string(key)):
                .bool(object[key] != nil)
            case let (.array(elements), .number(number, _)):
                .bool(number >= 0 && number < Double(elements.count))
            default:
                throw JQError("Cannot check whether \(value.typeName) has a \(arguments[0].typeName) key")
            }
        }
        table["contains/1"] = { interpreter, input, arguments, env, _, sink in
            try interpreter.withArguments(arguments, input, env) { values in
                let contained = try Operations.contains(input.value, values[0], interpreter.budget)
                return try sink(Item(.bool(contained)))
            }
        }
    }

    static func registerEntries(_ table: inout [String: Native]) {
        table["to_entries/0"] = { interpreter, input, _, _, _, sink in
            // Each entry is an object around the value, inside one more array.
            let inputDepth = try interpreter.depth(of: input)
            let depth = try interpreter.allowedDepth(inputDepth + 1)
            let entries = try entries(input.value, interpreter.budget)
            return try sink(Item(entries, depth: depth))
        }
        table["from_entries/0"] = { interpreter, input, _, _, _, sink in
            let object = try object(fromEntries: input.value, interpreter.budget)
            return try sink(Item(object))
        }
    }

    /// Bytes one `{key, value}` entry takes: its slot in the array, its object and its two keys.
    private static let entryBytes = Budget.valueBytes + 3 * Budget.storageBytes + 2 * (Budget.memberBytes + 5)

    /// `to_entries`: `{key, value}` objects for an object's entries or an array's elements.
    private static func entries(_ value: JSONValue, _ budget: Budget) throws -> JSONValue {
        let pairs: [(key: JSONValue, value: JSONValue)]
        switch value {
        case let .object(object):
            try budget.reserve(object.count * entryBytes)
            pairs = object.entries.map { (key: .string($0.key), value: $0.value) }
        case let .array(elements):
            try budget.reserve(elements.count * entryBytes)
            pairs = elements.enumerated().map { (key: .int($0.offset), value: $0.element) }
        case .null, .bool, .number, .string:
            throw JQError("\(Operations.describe(value)) has no keys")
        }
        return .array(pairs.map { pair in .object(JSONObject([("key", pair.key), ("value", pair.value)])) })
    }

    /// `from_entries`, as jq 1.7.1 defines it: `reduce .[] as $x ({}; . + {($x | .key // .Key //
    /// .name // .Name): ($x | if has("value") then .value else .Value end)})`, in one pass.
    private static func object(fromEntries value: JSONValue, _ budget: Budget) throws -> JSONValue {
        let entries: [JSONValue]
        switch value {
        case let .array(elements): entries = elements
        case let .object(object): entries = object.values
        case .null, .bool, .number, .string: throw JQError("Cannot iterate over \(Operations.describe(value))")
        }
        var result = JSONObject()
        for entry in entries {
            var key = JSONValue.null
            for name in ["key", "Key", "name", "Name"] {
                key = try Operations.index(entry, .string(name), budget)
                if key.isTruthy { break }
            }
            guard case let .string(name) = key else {
                throw JQError("Cannot use \(Operations.describe(key)) as object key")
            }
            guard case let .object(fields) = entry else {
                throw JQError("Cannot check whether \(entry.typeName) has a string key")
            }
            try budget.note(allocating: Budget.memberBytes + name.utf8.count)
            result[name] = fields["value"] ?? fields["Value"] ?? .null
        }
        return .object(result)
    }

    static func registerConversions(_ table: inout [String: Native]) {
        table["tostring/0"] = { interpreter, input, _, _, _, sink in
            let text = try input.value.boundedText(interpreter.budget)
            return try sink(Item(.string(text)))
        }
        table["tojson/0"] = { interpreter, input, _, _, _, sink in
            let json = try input.value.boundedJSON(interpreter.budget)
            return try sink(Item(.string(json)))
        }
        table["fromjson/0"] = { interpreter, input, _, _, _, sink in
            guard case let .string(text) = input.value else {
                throw JQError("\(Operations.describe(input.value)) only strings can be parsed")
            }
            let parsed = try parseJSON(text, interpreter.budget)
            return try sink(Item(parsed))
        }
        table["tonumber/0"] = { interpreter, input, _, _, _, sink in
            switch input.value {
            case .number:
                return try sink(input.detached)
            case let .string(text):
                let parsed = try parseJSON(text, interpreter.budget)
                guard case .number = parsed else { throw JQError("Cannot parse '\(text)' as number") }
                return try sink(Item(parsed))
            default:
                throw JQError("\(Operations.describe(input.value)) cannot be parsed as a number")
            }
        }
        table["infinite/0"] = simple { _ in .number(.infinity) }
        table["nan/0"] = simple { _ in .number(.nan) }
        let classifications: [(String, @Sendable (Double) -> Bool)] = [
            ("isinfinite", \.isInfinite), ("isnan", \.isNaN), ("isnormal", \.isNormal)
        ]
        for (name, holds) in classifications {
            table["\(name)/0"] = simple { value in
                let operand = try number(value)
                return .bool(holds(operand))
            }
        }
        table["have_literal_numbers/0"] = simple { _ in .bool(true) }
        table["have_decnum/0"] = simple { _ in .bool(false) }
        table["builtins/0"] = simple { _ in .array(names.map(JSONValue.string)) }
        table["input_line_number/0"] = { interpreter, _, _, _, _, sink in
            // Without an input source, as in `JQ.evaluate`, no line has been read.
            let line = interpreter.inputs.map(\.currentLine) ?? 0
            return try sink(Item(.int(line)))
        }
    }

    /// One JSON value, with parse errors as catchable jq errors.
    private static func parseJSON(_ text: String, _ budget: Budget) throws -> JSONValue {
        do {
            return try JSONStreamParser.parseSingle(text, budget: budget)
        } catch let error as JSONParseError {
            throw JQError(error.message)
        }
    }
}
