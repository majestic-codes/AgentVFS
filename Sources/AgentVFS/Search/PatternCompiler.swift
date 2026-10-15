//
//  PatternCompiler.swift
//  AgentVFS
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

// NSRegularExpression exception: its matching callback enforces the time limit.

/// A line matcher compiled from a grep-style pattern.
///
/// Matching stops at `deadline` or when the task is cancelled, so a pattern that backtracks
/// without end, such as `(a+)+$`, cannot hang a command. A match cut short reports no match.
/// Callers check `isPastDeadline` to say the search is incomplete.
public struct CompiledPattern: Sendable {
    private let regex: NSRegularExpression
    /// The same expression with `^` and `$` matching at line breaks, for searching many lines at
    /// once. Every match it finds is confirmed on its own line with `matches`.
    private let lineRegex: NSRegularExpression
    /// A plain substring every matching line must contain, used to skip files quickly.
    let literalHint: String?
    let hintIsCaseInsensitive: Bool
    /// When matching gives up.
    public let deadline: ContinuousClock.Instant

    /// Steps of the regular expression engine between two looks at the clock.
    private static let stepsPerClockCheck = 64

    init(
        regex: NSRegularExpression,
        lineRegex: NSRegularExpression,
        literalHint: String?,
        hintIsCaseInsensitive: Bool,
        deadline: ContinuousClock.Instant
    ) {
        self.regex = regex
        self.lineRegex = lineRegex
        self.literalHint = literalHint
        self.hintIsCaseInsensitive = hintIsCaseInsensitive
        self.deadline = deadline
    }

    /// The same pattern giving up at `deadline`, usually the deadline of the search using it.
    public func limited(until deadline: ContinuousClock.Instant) -> Self {
        Self(
            regex: regex,
            lineRegex: lineRegex,
            literalHint: literalHint,
            hintIsCaseInsensitive: hintIsCaseInsensitive,
            deadline: deadline
        )
    }

    /// `true` once matching gives up, so a search that used the pattern may have missed lines.
    public var isPastDeadline: Bool { ContinuousClock.now >= deadline || Task.isCancelled }

    /// `true` when the pattern matches somewhere in `line`.
    public func matches(_ line: String) -> Bool {
        firstMatch(of: regex, in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// The first match in `line`, or `nil`.
    public func firstMatchRange(in line: String) -> Range<String.Index>? {
        guard let match = firstMatch(of: regex, in: line, range: NSRange(line.startIndex..., in: line)) else {
            return nil
        }
        return Range(match, in: line)
    }

    /// The first match of `expression` in `range`, or `nil` when there is none or matching gave up.
    private func firstMatch(of expression: NSRegularExpression, in text: String, range: NSRange) -> NSRange? {
        var found: NSRange?
        var steps = 0
        expression.enumerateMatches(in: text, options: .reportProgress, range: range) { match, _, stop in
            if let match {
                found = match.range
                stop.pointee = true
                return
            }
            steps += 1
            if steps.isMultiple(of: Self.stepsPerClockCheck), isPastDeadline {
                stop.pointee = true
            }
        }
        return found
    }

    // NSRegularExpression works in NSString offsets, and blocks of megabytes stay NSString to avoid copies.
    // swiftlint:disable legacy_objc_type

    /// The first match at or after `location` in a block of lines.
    func firstMatch(in text: NSString, from location: Int) -> NSRange? {
        let range = NSRange(location: location, length: text.length - location)
        return firstMatch(of: lineRegex, in: text as String, range: range)
    }

    /// Cheap whole-text test that can only produce false positives.
    func mayMatch(_ text: NSString) -> Bool {
        guard let literalHint else { return true }
        let options: NSString.CompareOptions = hintIsCaseInsensitive ? [.caseInsensitive] : []
        return text.range(of: literalHint, options: options).location != NSNotFound
    }

    // swiftlint:enable legacy_objc_type
}

/// Compiles grep-style patterns: basic (`grep`), extended (`grep -E`) or fixed strings (`grep -F`).
public enum PatternCompiler {
    static let maxPatternLength = 4000

    /// Compiles `pattern`, matching for at most `timeLimit` from now. Throws
    /// `VFSError.invalidPattern` for an empty, overlong or malformed one.
    public static func compile(
        _ pattern: String,
        syntax: PatternSyntax,
        caseInsensitive: Bool,
        wholeWord: Bool,
        timeLimit: Duration = .seconds(30)
    ) throws -> CompiledPattern {
        guard !pattern.isEmpty else {
            throw VFSError.invalidPattern("the pattern is empty")
        }
        guard pattern.count <= maxPatternLength else {
            throw VFSError.invalidPattern("the pattern is longer than \(maxPatternLength) characters")
        }
        let translated: String
        switch syntax {
        case .fixed: translated = NSRegularExpression.escapedPattern(for: pattern)
        case .basic: translated = try translateBasic(pattern)
        case .extended: translated = try translateExtended(pattern)
        }
        let source = wholeWord ? "(?<![\\p{L}\\p{N}_])(?:\(translated))(?![\\p{L}\\p{N}_])" : translated
        let regex: NSRegularExpression
        let lineRegex: NSRegularExpression
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        do {
            regex = try NSRegularExpression(pattern: source, options: options)
            lineRegex = try NSRegularExpression(pattern: source, options: options.union(.anchorsMatchLines))
        } catch {
            let kind = syntax == .fixed ? "string" : "regular expression"
            throw VFSError.invalidPattern("'\(pattern)' is not a valid \(kind)")
        }
        return CompiledPattern(
            regex: regex,
            lineRegex: lineRegex,
            literalHint: literalHint(for: pattern, syntax: syntax),
            hintIsCaseInsensitive: caseInsensitive,
            deadline: ContinuousClock.now + timeLimit
        )
    }

    /// The pattern itself when it contains no regular-expression operators.
    static func literalHint(for pattern: String, syntax: PatternSyntax) -> String? {
        if syntax == .fixed { return pattern }
        let operators = CharacterSet(charactersIn: "\\.[]*^$+?(){}|")
        return pattern.unicodeScalars.contains(where: operators.contains) ? nil : pattern
    }

    /// Whether a source search index (such as GitHub Code Search) can take the pattern as a plain
    /// term: letters, digits and `_`, plus `.` in a fixed string, where it is not an operator.
    static func isSimpleTerm(_ pattern: String, syntax: PatternSyntax) -> Bool {
        guard !pattern.isEmpty, pattern.count <= 128 else { return false }
        return pattern.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || (scalar == "." && syntax == .fixed)
        }
    }

    // MARK: POSIX basic (GNU grep default)

    private static func translateBasic(_ pattern: String) throws -> String {
        let characters = Array(pattern)
        var output = ""
        var index = 0
        var atStart = true
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "\\":
                guard index + 1 < characters.count else {
                    throw VFSError.invalidPattern("the pattern ends with a backslash")
                }
                let next = characters[index + 1]
                index += 2
                output += translateBasicEscape(next)
                // A group or an alternative starts a new expression, where `*` is literal and `^` anchors.
                atStart = next == "(" || next == "|"
            case "(", ")", "|", "+", "?", "{", "}":
                output += "\\" + String(character)
                index += 1
                atStart = false
            case "*":
                output += atStart ? "\\*" : "*"
                index += 1
                atStart = false
            case "^":
                output += atStart ? "^" : "\\^"
                index += 1
            case "$":
                let rest = characters[(index + 1)...]
                let isAnchor = rest.isEmpty || rest.starts(with: ["\\", ")"]) || rest.starts(with: ["\\", "|"])
                output += isAnchor ? "$" : "\\$"
                index += 1
                atStart = false
            case "[":
                output += try translateBracket(characters, index: &index)
                atStart = false
            default:
                output.append(character)
                index += 1
                atStart = false
            }
        }
        return output
    }

    /// The expression for `\` followed by `next` in a basic pattern, where `\(`, `\|`, `\{` and the
    /// like are the operators and the bare characters are literal.
    private static func translateBasicEscape(_ next: Character) -> String {
        switch next {
        case "(", "|", ")", "{", "}", "+", "?":
            String(next)
        case "<":
            "\\b(?=\\w)"
        case ">":
            "\\b(?<=\\w)"
        case "w", "W", "s", "S", "b", "B", "1", "2", "3", "4", "5", "6", "7", "8", "9":
            "\\" + String(next)
        default:
            NSRegularExpression.escapedPattern(for: String(next))
        }
    }

    // MARK: POSIX extended / ripgrep

    private static func translateExtended(_ pattern: String) throws -> String {
        let characters = Array(pattern)
        var output = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "\\":
                guard index + 1 < characters.count else {
                    throw VFSError.invalidPattern("the pattern ends with a backslash")
                }
                let next = characters[index + 1]
                index += 2
                switch next {
                case "<": output += "\\b(?=\\w)"
                case ">": output += "\\b(?<=\\w)"
                default: output += "\\" + String(next)
                }
            case "[":
                output += try translateBracket(characters, index: &index)
            case "{":
                if isInterval(characters, at: index) {
                    output.append(character)
                } else {
                    output += "\\{"
                }
                index += 1
            case "}":
                output += isClosingInterval(output) ? "}" : "\\}"
                index += 1
            default:
                output.append(character)
                index += 1
            }
        }
        return output
    }

    private static func isInterval(_ characters: [Character], at index: Int) -> Bool {
        var cursor = index + 1
        var digits = 0
        while cursor < characters.count, characters[cursor].isNumber {
            digits += 1
            cursor += 1
        }
        guard digits > 0 else { return false }
        if cursor < characters.count, characters[cursor] == "," {
            cursor += 1
            while cursor < characters.count, characters[cursor].isNumber { cursor += 1 }
        }
        return cursor < characters.count && characters[cursor] == "}"
    }

    private static func isClosingInterval(_ translated: String) -> Bool {
        guard let open = translated.lastIndex(of: "{") else { return false }
        let inside = translated[translated.index(after: open)...]
        return !inside.isEmpty && inside.allSatisfy { $0.isNumber || $0 == "," }
    }

    // MARK: Bracket expressions

    /// Translates `[...]`, leaving POSIX classes such as `[:alpha:]` intact and making every other
    /// character literal.
    private static func translateBracket(_ characters: [Character], index: inout Int) throws -> String {
        var cursor = index + 1
        var output = "["
        if cursor < characters.count, characters[cursor] == "^" {
            output += "^"
            cursor += 1
        }
        var first = true
        while cursor < characters.count {
            let character = characters[cursor]
            if character == "]", !first {
                index = cursor + 1
                return output + "]"
            }
            first = false
            if character == "[", cursor + 1 < characters.count, characters[cursor + 1] == ":" {
                var end = cursor + 2
                while end + 1 < characters.count, !(characters[end] == ":" && characters[end + 1] == "]") {
                    end += 1
                }
                if end + 1 < characters.count {
                    output += String(characters[cursor...(end + 1)])
                    cursor = end + 2
                    continue
                }
            }
            switch character {
            case "\\", "[", "]", "&", "~", "^", "{", "}":
                output += "\\" + String(character)
            default:
                output.append(character)
            }
            cursor += 1
        }
        throw VFSError.invalidPattern("the pattern has an unterminated '['")
    }
}
