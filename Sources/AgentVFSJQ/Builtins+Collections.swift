//
//  Builtins+Collections.swift
//  AgentVFSJQ
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

extension Builtins {

    static func registerCollections(_ table: inout [String: Native]) {
        table["add/0"] = { interpreter, input, _, _, _, sink in
            var elements: [JSONValue] = []
            _ = try interpreter.iterate(Item(input.value), false) { item in
                if case .null = item.value { return true }
                elements.append(item.value)
                return true
            }
            let total = try sum(elements)
            return try sink(Item(total))
        }
        table["join/1"] = { interpreter, input, arguments, env, _, sink in
            try interpreter.withArguments(arguments, input, env) { values in
                let text = try join(interpreter, input.value, separator: values[0])
                return try sink(Item(.string(text)))
            }
        }
        table["reverse/0"] = simple { value in
            switch value {
            case let .array(elements): .array(elements.reversed())
            case let .string(text): .string(String(String.UnicodeScalarView(text.unicodeScalars.reversed())))
            case .null: .array([])
            case let .object(object) where object.isEmpty: .array([])
            default: throw JQError("Cannot index \(value.typeName) with number")
            }
        }
        table["flatten/0"] = { interpreter, input, _, _, _, sink in
            let flattened = try flatten(input.value, -1, interpreter.budget)
            return try sink(Item(.array(flattened)))
        }
        table["flatten/1"] = { interpreter, input, arguments, env, _, sink in
            try interpreter.withArguments(arguments, input, env) { values in
                let depth = try number(values[0])
                guard depth >= 0 else { throw JQError("flatten depth must not be negative") }
                let flattened = try flatten(input.value, depth, interpreter.budget)
                return try sink(Item(.array(flattened)))
            }
        }
    }

    /// `add`: strings and arrays are concatenated in one pass.
    private static func sum(_ elements: [JSONValue]) throws -> JSONValue {
        let strings = elements.compactMap(\.stringValue)
        if !elements.isEmpty, strings.count == elements.count {
            try Operations.checkSize(stringBytes: strings.reduce(0) { $0 + $1.utf8.count })
            return .string(strings.joined())
        }
        if !elements.isEmpty, elements.allSatisfy({ if case .array = $0 { true } else { false } }) {
            var result: [JSONValue] = []
            for case let .array(part) in elements {
                try Operations.checkSize(arrayCount: result.count + part.count)
                result.append(contentsOf: part)
            }
            return .array(result)
        }
        var total = JSONValue.null
        for element in elements { total = try Operations.add(total, element) }
        return total
    }

    private static func join(_ interpreter: Interpreter, _ input: JSONValue, separator: JSONValue) throws -> String {
        var result = ""
        var first = true
        _ = try interpreter.iterate(Item(input), false) { item in
            if !first {
                guard case let .string(text) = separator else {
                    let joined = Operations.describe(.string(result))
                    throw JQError("\(joined) and \(Operations.describe(separator)) cannot be added")
                }
                result += text
            }
            first = false
            switch item.value {
            case .null: break
            case let .string(text): result += text
            case .number, .bool: result += item.value.json
            default:
                let joined = Operations.describe(.string(result))
                throw JQError("\(joined) and \(Operations.describe(item.value)) cannot be added")
            }
            try Operations.checkSize(stringBytes: result.utf8.count)
            return true
        }
        return result
    }

    /// `flatten(depth)`, with a negative depth for no limit. Elements are appended to one result
    /// as they are visited, so the size limit and `budget` stop a value whose shared parts make it
    /// far larger than its storage.
    private static func flatten(_ value: JSONValue, _ depth: Double, _ budget: Budget) throws -> [JSONValue] {
        let elements: [JSONValue]
        switch value {
        case let .array(array): elements = array
        case let .object(object): elements = object.values
        default: throw JQError("Cannot iterate over \(Operations.describe(value))")
        }
        var result: [JSONValue] = []
        try appendFlattened(elements, depth, to: &result, budget)
        return result
    }

    private static func appendFlattened(
        _ elements: [JSONValue],
        _ depth: Double,
        to result: inout [JSONValue],
        _ budget: Budget
    ) throws {
        for element in elements {
            try budget.checkPeriodically()
            if case let .array(nested) = element, depth != 0 {
                try appendFlattened(nested, depth - 1, to: &result, budget)
            } else {
                result.append(element)
                try Operations.checkSize(arrayCount: result.count)
            }
        }
    }

    static func registerSorting(_ table: inout [String: Native]) {
        table["sort/0"] = { interpreter, input, _, _, _, sink in
            let elements = try array(input.value, "sorted")
            let ordered = try sorted(elements, by: elements, interpreter.budget)
            return try sink(Item(.array(ordered), depth: input.depth))
        }
        table["sort_by/1"] = { interpreter, input, arguments, env, _, sink in
            let elements = try array(input.value, "sorted")
            let elementKeys = try keys(elements, interpreter, arguments[0], env)
            let ordered = try sorted(elements, by: elementKeys, interpreter.budget)
            return try sink(Item(.array(ordered), depth: input.depth))
        }
        table["group_by/1"] = { interpreter, input, arguments, env, _, sink in
            let elements = try array(input.value, "grouped")
            // Each group is one more array around the elements.
            let inputDepth = try interpreter.depth(of: input)
            let depth = try interpreter.allowedDepth(inputDepth + 1)
            let elementKeys = try keys(elements, interpreter, arguments[0], env)
            let grouped = try groups(elements, elementKeys, interpreter.budget)
            return try sink(Item(.array(grouped.map(JSONValue.array)), depth: depth))
        }
        table["unique_by/1"] = { interpreter, input, arguments, env, _, sink in
            let elements = try array(input.value, "grouped")
            let elementKeys = try keys(elements, interpreter, arguments[0], env)
            let grouped = try groups(elements, elementKeys, interpreter.budget)
            return try sink(Item(.array(grouped.map { $0[0] }), depth: input.depth))
        }
        table["unique/0"] = { interpreter, input, _, _, _, sink in
            let elements = try array(input.value, "sorted")
            let grouped = try groups(elements, elements, interpreter.budget)
            return try sink(Item(.array(grouped.map { $0[0] }), depth: input.depth))
        }
        for (name, maximum) in [("min", false), ("max", true)] {
            table["\(name)/0"] = { interpreter, input, _, _, _, sink in
                let elements = try array(input.value, "iterated over")
                let chosen = try extreme(elements, elements, maximum: maximum, interpreter.budget)
                return try sink(Item(chosen))
            }
            table["\(name)_by/1"] = { interpreter, input, arguments, env, _, sink in
                let elements = try array(input.value, "iterated over")
                let elementKeys = try keys(elements, interpreter, arguments[0], env)
                let chosen = try extreme(elements, elementKeys, maximum: maximum, interpreter.budget)
                return try sink(Item(chosen))
            }
        }
    }
}
