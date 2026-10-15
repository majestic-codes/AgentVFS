//
//  Builtins+System.swift
//  AgentVFSJQ
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

// MARK: Math

extension Builtins {
    /// The C math functions of one number, by jq name.
    private static let unaryMath: [(String, @Sendable (Double) -> Double)] = [
        ("floor", { $0.rounded(.down) }), ("ceil", { $0.rounded(.up) }), ("round", { $0.rounded() }),
        ("trunc", { $0.rounded(.towardZero) }), ("rint", { $0.rounded(.toNearestOrEven) }),
        ("nearbyint", { $0.rounded(.toNearestOrEven) }), ("fabs", { Swift.abs($0) }),
        ("sqrt", { $0.squareRoot() }), ("cbrt", { Foundation.cbrt($0) }),
        ("exp", { Foundation.exp($0) }), ("exp2", { Foundation.exp2($0) }),
        ("exp10", { Foundation.pow(10, $0) }), ("pow10", { Foundation.pow(10, $0) }),
        ("expm1", { Foundation.expm1($0) }),
        ("log", { Foundation.log($0) }), ("log2", { Foundation.log2($0) }), ("log10", { Foundation.log10($0) }),
        ("log1p", { Foundation.log1p($0) }), ("logb", { Foundation.logb($0) }),
        ("sin", { Foundation.sin($0) }), ("cos", { Foundation.cos($0) }), ("tan", { Foundation.tan($0) }),
        ("asin", { Foundation.asin($0) }), ("acos", { Foundation.acos($0) }), ("atan", { Foundation.atan($0) }),
        ("sinh", { Foundation.sinh($0) }), ("cosh", { Foundation.cosh($0) }), ("tanh", { Foundation.tanh($0) }),
        ("asinh", { Foundation.asinh($0) }), ("acosh", { Foundation.acosh($0) }),
        ("atanh", { Foundation.atanh($0) }),
        ("gamma", { Foundation.tgamma($0) }), ("lgamma", { Foundation.lgamma($0) }),
        ("tgamma", { Foundation.tgamma($0) }),
        ("significand", { value in
            guard value.isFinite, value != 0 else { return value }
            return Foundation.frexp(value).0 * 2
        })
    ]

    /// The C math functions of two numbers, by jq name.
    private static let binaryMath: [(String, @Sendable (Double, Double) -> Double)] = [
        ("pow", { Foundation.pow($0, $1) }), ("atan2", { Foundation.atan2($0, $1) }),
        ("fmin", { Swift.min($0, $1) }), ("fmax", { Swift.max($0, $1) }), ("fmod", { Foundation.fmod($0, $1) }),
        ("hypot", { Foundation.hypot($0, $1) }), ("copysign", { Foundation.copysign($0, $1) }),
        ("fdim", { $0 > $1 ? $0 - $1 : 0 }), ("drem", { Foundation.remainder($0, $1) }),
        ("remainder", { Foundation.remainder($0, $1) }),
        ("ldexp", { Foundation.scalbn($0, Operations.integer($1)) }), ("scalb", { $0 * Foundation.pow(2, $1) }),
        ("scalbln", { Foundation.scalbn($0, Operations.integer($1)) }),
        ("nextafter", { Foundation.nextafter($0, $1) }), ("nexttoward", { Foundation.nextafter($0, $1) })
    ]

    static func registerMath(_ table: inout [String: Native]) {
        for (name, function) in unaryMath {
            table["\(name)/0"] = simple { value in
                let operand = try number(value)
                return .number(function(operand))
            }
        }
        table["frexp/0"] = simple { value in
            let operand = try number(value)
            let (mantissa, exponent) = Foundation.frexp(operand)
            return .array([.number(mantissa), .int(exponent)])
        }
        table["modf/0"] = simple { value in
            let operand = try number(value)
            let whole = operand.rounded(.towardZero)
            return .array([.number(operand.isInfinite ? 0 : operand - whole), .number(whole)])
        }
        table["lgamma_r/0"] = simple { value in
            let operand = try number(value)
            return .array([.number(Foundation.lgamma(operand)), .number(Foundation.tgamma(operand) < 0 ? -1 : 1)])
        }
        for (name, function) in binaryMath {
            table["\(name)/2"] = withValues { _, arguments in
                let first = try number(arguments[0])
                let second = try number(arguments[1])
                return .number(function(first, second))
            }
        }
        table["fma/3"] = withValues { _, arguments in
            let first = try number(arguments[0])
            let second = try number(arguments[1])
            let addend = try number(arguments[2])
            return .number(Foundation.fma(first, second, addend))
        }
    }
}

// MARK: Input, output and time

extension Builtins {

    static func registerSystem(_ table: inout [String: Native]) {
        table["input/0"] = { interpreter, _, _, _, _, sink in
            guard let value = try interpreter.inputs?.next() else { throw JQError("No more inputs") }
            return try sink(Item(value))
        }
        table["inputs/0"] = { interpreter, _, _, _, _, sink in
            while let value = try interpreter.inputs?.next() {
                guard try sink(Item(value)) else { return false }
            }
            return true
        }
        table["input_filename/0"] = { interpreter, _, _, _, _, sink in
            try sink(Item(interpreter.inputs?.currentName.map(JSONValue.string) ?? .null))
        }
        table["debug/0"] = { interpreter, input, _, _, _, sink in
            let json = try input.value.boundedJSON(interpreter.budget)
            try interpreter.message("[\"DEBUG:\",\(json)]\n")
            return try sink(input)
        }
        table["stderr/0"] = { interpreter, input, _, _, _, sink in
            let json = try input.value.boundedJSON(interpreter.budget)
            try interpreter.message(json)
            return try sink(input)
        }
        table["halt/0"] = { _, _, _, _, _, _ in throw JQHalt(exitCode: 0, message: nil) }
        table["halt_error/1"] = { interpreter, input, arguments, env, _, _ in
            _ = try interpreter.eval(arguments[0], Item(input.value), env, false) { code in
                guard case let .number(number, _) = code.value else { throw JQError("halt_error/1: number required") }
                throw JQHalt(exitCode: Operations.integer(number), message: input.value)
            }
            return true
        }
        registerTime(&table)
    }

    private static func registerTime(_ table: inout [String: Native]) {
        table["now/0"] = simple { _ in .number(Date().timeIntervalSince1970) }
        table["mktime/0"] = simple { try Dates.mktime($0) }
        table["gmtime/0"] = simple { value in
            guard case let .number(seconds, _) = value else { throw JQError("gmtime() requires a number") }
            return try Dates.brokenDown(seconds, local: false)
        }
        table["localtime/0"] = simple { value in
            guard case let .number(seconds, _) = value else { throw JQError("localtime() requires a number") }
            return try Dates.brokenDown(seconds, local: true)
        }
        table["strftime/1"] = withValues { value, arguments in
            try Dates.strftime(value, arguments[0], local: false)
        }
        table["strflocaltime/1"] = withValues { value, arguments in
            try Dates.strftime(value, arguments[0], local: true)
        }
        table["strptime/1"] = withValues { value, arguments in try Dates.strptime(value, arguments[0]) }
    }
}
