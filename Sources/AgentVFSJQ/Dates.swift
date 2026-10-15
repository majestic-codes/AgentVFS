//
//  Dates.swift
//  AgentVFSJQ
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// `gmtime`, `mktime`, `strftime`, `strptime` and friends. Broken-down times are
/// `[year, month (0-11), day, hours, minutes, seconds, weekday, day of year]`.
enum Dates {

    static func brokenDown(_ seconds: Double, local: Bool) throws -> JSONValue {
        guard seconds.isFinite else { throw JQError("\(local ? "localtime" : "gmtime")() requires a finite number") }
        var time = time_t(Operations.integer(seconds.rounded(.down)))
        var parts = tm()
        let converted = local ? localtime_r(&time, &parts) : gmtime_r(&time, &parts)
        guard converted != nil else {
            throw JQError("error converting number of seconds since epoch to datetime")
        }
        return array(parts, fraction: seconds - seconds.rounded(.down))
    }

    private static func array(_ parts: tm, fraction: Double = 0) -> JSONValue {
        .array([
            .int(Int(parts.tm_year) + 1900),
            .int(Int(parts.tm_mon)),
            .int(Int(parts.tm_mday)),
            .int(Int(parts.tm_hour)),
            .int(Int(parts.tm_min)),
            .number(Double(parts.tm_sec) + fraction),
            .int(Int(parts.tm_wday)),
            .int(Int(parts.tm_yday))
        ])
    }

    private static func parts(_ value: JSONValue, function: String) throws -> tm {
        guard case let .array(elements) = value else {
            throw JQError("\(function) requires parsed datetime inputs")
        }
        let invalid = JQError("\(function) requires parsed datetime inputs")
        var numbers: [Double] = []
        for element in elements {
            guard case let .number(number, _) = element else { throw invalid }
            numbers.append(number.rounded(.down))
        }
        guard numbers.count >= 6 else {
            throw function == "mktime" ? JQError("mktime requires array of 6 numbers") : invalid
        }
        // The year is stored as years since 1900, like every field of `tm`, in 32 bits.
        numbers[0] -= 1900
        var fields: [Int32] = []
        for number in numbers.prefix(8) {
            guard let field = Int32(exactly: number) else { throw invalid }
            fields.append(field)
        }
        var parts = tm()
        parts.tm_year = fields[0]
        parts.tm_mon = fields[1]
        parts.tm_mday = fields[2]
        parts.tm_hour = fields[3]
        parts.tm_min = fields[4]
        parts.tm_sec = fields[5]
        if fields.count > 6 { parts.tm_wday = fields[6] }
        if fields.count > 7 { parts.tm_yday = fields[7] }
        return parts
    }

    static func mktime(_ value: JSONValue) throws -> JSONValue {
        guard case .array = value else { throw JQError("mktime requires array of 6 numbers") }
        var broken = try parts(value, function: "mktime")
        return .int(Int(timegm(&broken)))
    }

    static func strftime(_ value: JSONValue, _ format: JSONValue, local: Bool) throws -> JSONValue {
        let name = local ? "strflocaltime/1" : "strftime/1"
        var input = value
        if case let .number(seconds, _) = value {
            input = try brokenDown(seconds, local: local)
        }
        guard case let .string(pattern) = format else { throw JQError("\(name) requires a string format") }
        var broken = try parts(input, function: name)
        if !local {
            // Fill in the weekday and day of year from the date itself.
            var copy = broken
            var time = timegm(&copy)
            var normalized = tm()
            gmtime_r(&time, &normalized)
            broken.tm_wday = normalized.tm_wday
            broken.tm_yday = normalized.tm_yday
        }
        var buffer = [Int8](repeating: 0, count: 1024)
        let count = Foundation.strftime(&buffer, buffer.count, pattern, &broken)
        guard count > 0 || pattern.isEmpty else { throw JQError("\(name): unknown system failure") }
        return .string(String(repairingUTF8: buffer[0..<count].map { UInt8(bitPattern: $0) }))
    }

    static func strptime(_ value: JSONValue, _ format: JSONValue) throws -> JSONValue {
        guard case let .string(text) = value, case let .string(pattern) = format else {
            throw JQError("strptime/1 requires string inputs and arguments")
        }
        var broken = tm()
        let matched: Bool = text.withCString { input in
            guard let end = Foundation.strptime(input, pattern, &broken) else { return false }
            return end.pointee == 0
        }
        guard matched else { throw JQError("date \"\(text)\" does not match format \"\(pattern)\"") }
        var copy = broken
        var time = timegm(&copy)
        var normalized = tm()
        gmtime_r(&time, &normalized)
        broken.tm_wday = normalized.tm_wday
        broken.tm_yday = normalized.tm_yday
        return array(broken)
    }
}
