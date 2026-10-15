//
//  JQRegex.swift
//  AgentVFSJQ
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

/// `match`, `test` and the functions built on them, using ICU regular expressions in place of
/// jq's Oniguruma. Offsets and lengths count code points, as in jq.
///
/// `NSRegularExpression`, with `NSString`, `NSRange` and `NSTextCheckingResult`, is the sanctioned
/// exception to the rule against NS types: its matching callback is the only way to stop a
/// backtracking pattern at the time limit, which Swift's `Regex` cannot do.
enum JQRegex {
    /// What a jq modifier string such as `"gi"` asks for.
    private struct Modifiers {
        /// Only `\n` ends a line, as in Oniguruma.
        var options: NSRegularExpression.Options = [.useUnixLineSeparators]
        var global = false
        var skipEmpty = false

        init(_ flags: JSONValue) throws {
            var text = ""
            switch flags {
            case .null: break
            case let .string(value): text = value
            default: throw JQError("\(flags.errorDescription) is not a string")
            }
            for flag in text {
                switch flag {
                case "g": global = true
                case "i": options.insert(.caseInsensitive)
                case "x": options.insert(.allowCommentsAndWhitespace)
                case "n": skipEmpty = true
                case "p": options.insert(.dotMatchesLineSeparators)
                // Single-line mode: `^` and `$` match only at the ends of the text, which ICU
                // already does without the multiline option.
                case "s": break
                case "l": throw JQError("the l (longest match) regex modifier is not supported")
                default: throw JQError("\(text) is not a valid modifier string")
                }
            }
        }
    }

    /// A string being matched. NSRegularExpression reports UTF-16 ranges, which `NSString` measures
    /// and slices by, and jq counts code points.
    private struct Subject {
        // swiftlint:disable:next legacy_objc_type
        let text: NSString
        private let string: String

        init(_ string: String) {
            self.string = string
            // swiftlint:disable:next legacy_objc_type
            text = string as NSString
        }

        /// The code point offset of a UTF-16 offset, counted from `anchor`, an offset whose code
        /// point offset is known. Counting from a near anchor keeps many matches linear.
        func scalarOffset(_ utf16Offset: Int, from anchor: Anchor) -> Anchor {
            let start = String.Index(utf16Offset: anchor.utf16, in: string)
            let end = String.Index(utf16Offset: utf16Offset, in: string)
            let between = string.unicodeScalars.distance(from: start, to: end)
            return Anchor(utf16: utf16Offset, scalars: anchor.scalars + between)
        }

        /// `offset`, `length` and `string` of a matched range, counted in code points from `anchor`.
        func describe(_ range: NSRange, from anchor: Anchor) -> [(String, JSONValue)] {
            let start = scalarOffset(range.location, from: anchor)
            let end = scalarOffset(range.location + range.length, from: start)
            let matched = JSONValue.string(text.substring(with: range))
            return [("offset", .int(start.scalars)), ("length", .int(end.scalars - start.scalars)), ("string", matched)]
        }
    }

    /// A UTF-16 offset into a subject and the code point offset it stands for.
    private struct Anchor {
        let utf16: Int
        let scalars: Int
    }

    static func match(
        _ interpreter: Interpreter,
        _ input: JSONValue,
        _ pattern: JSONValue,
        _ flags: JSONValue,
        test: Bool
    ) throws -> JSONValue {
        guard case let .string(text) = input else {
            throw JQError("\(Operations.describe(input)) cannot be matched, as it is not a string")
        }
        guard case let .string(source) = pattern else {
            throw JQError("\(Operations.describe(pattern)) cannot be matched, as it is not a string")
        }
        let modifiers = try Modifiers(flags)
        let regex = try compile(interpreter, source, modifiers.options)
        let subject = Subject(text)
        let wanted = test || !modifiers.global ? 1 : Operations.maxArrayCount + 1
        var results: [NSTextCheckingResult] = []
        var failure: JQAbort?
        let whole = NSRange(location: 0, length: subject.text.length)
        // Progress reports come during a long match too, so a pattern that backtracks without end
        // still stops at the time limit.
        autoreleasepool {
            regex.enumerateMatches(in: text, options: [.reportProgress], range: whole) { result, _, stop in
                if let result, !(modifiers.skipEmpty && result.range.length == 0) { results.append(result) }
                failure = interpreter.budget.failure(allocating: result == nil ? 0 : 256)
                if failure != nil || results.count >= wanted { stop.pointee = true }
            }
        }
        if let failure { throw failure }
        if test { return .bool(!results.isEmpty) }
        try Operations.checkSize(arrayCount: results.count)
        let names = groupNames(source)
        var anchor = Anchor(utf16: 0, scalars: 0)
        var matches: [JSONValue] = []
        for result in results {
            try interpreter.budget.note(allocating: 1024)
            anchor = subject.scalarOffset(result.range.location, from: anchor)
            matches.append(matchObject(result, subject, from: anchor, names: names))
        }
        return .array(matches)
    }

    private static func matchObject(
        _ result: NSTextCheckingResult,
        _ subject: Subject,
        from anchor: Anchor,
        names: [String?]
    ) -> JSONValue {
        var captures: [JSONValue] = []
        for group in 1..<max(1, result.numberOfRanges) {
            let range = result.range(at: group)
            let name: JSONValue = group - 1 < names.count ? (names[group - 1].map(JSONValue.string) ?? .null) : .null
            if range.location == NSNotFound {
                let missing: [(String, JSONValue)] = [
                    ("offset", .int(-1)), ("string", .null), ("length", .int(0)), ("name", name)
                ]
                captures.append(.object(JSONObject(missing)))
            } else {
                captures.append(.object(JSONObject(subject.describe(range, from: anchor) + [("name", name)])))
            }
        }
        let fields = subject.describe(result.range, from: anchor) + [("captures", .array(captures))]
        return .object(JSONObject(fields))
    }

    private static func compile(
        _ interpreter: Interpreter,
        _ source: String,
        _ options: NSRegularExpression.Options
    ) throws -> NSRegularExpression {
        let key = "\(options.rawValue)/\(source)"
        if let cached = interpreter.regexCache[key] { return cached }
        do {
            let regex = try NSRegularExpression(pattern: source.isEmpty ? "(?:)" : source, options: options)
            interpreter.regexCache[key] = regex
            return regex
        } catch {
            throw JQError("\(source) (at offset 0) is not a valid regex")
        }
    }

    /// Names of the capture groups in order, `nil` for unnamed ones.
    static func groupNames(_ pattern: String) -> [String?] {
        let scalars = Array(pattern.unicodeScalars)
        var names: [String?] = []
        var index = 0
        var inClass = false
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\\" {
                index += 2
                continue
            }
            if inClass {
                if scalar == "]" { inClass = false }
                index += 1
                continue
            }
            if scalar == "[" {
                inClass = true
                if index + 1 < scalars.count, scalars[index + 1] == "]" { index += 1 }
            } else if scalar == "(" {
                if index + 1 < scalars.count, scalars[index + 1] == "?" {
                    if let name = groupName(scalars, at: index + 2) { names.append(name) }
                } else {
                    names.append(nil)
                }
            }
            index += 1
        }
        return names
    }

    /// The name of a `(?<name>`, `(?P<name>` or `(?'name'` group whose marker starts at `start`, or
    /// `nil` for other `(?` groups, which do not capture.
    private static func groupName(_ scalars: [Unicode.Scalar], at start: Int) -> String? {
        let marker = start < scalars.count ? scalars[start] : " "
        let after = start + 1 < scalars.count ? scalars[start + 1] : " "
        if marker == "<", after != "=", after != "!" { return readName(scalars, from: start + 1, until: ">") }
        if marker == "P", after == "<" { return readName(scalars, from: start + 2, until: ">") }
        if marker == "'" { return readName(scalars, from: start + 1, until: "'") }
        return nil
    }

    private static func readName(
        _ scalars: [Unicode.Scalar],
        from start: Int,
        until terminator: Unicode.Scalar
    ) -> String {
        var name = ""
        var position = start
        while position < scalars.count, scalars[position] != terminator {
            name.unicodeScalars.append(scalars[position])
            position += 1
        }
        return name
    }
}
