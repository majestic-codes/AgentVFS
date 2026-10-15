//
//  SortCommand.swift
//  AgentVFS
//
//  Created by Yevhenii Kalashnikov on 14.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

extension CommandContext {
    /// Most bytes `sort` reads, across all its inputs: it holds every line in memory.
    static let maxSortBytes = 64_000_000
    /// Most lines `sort` reads, across all its inputs.
    static let maxSortLines = 1_000_000

    func sortLines(_ arguments: [ShellToken]) async throws -> CommandOutput {
        let specification = OptionSpec(flags: ["r", "n", "u", "f"], valueFlags: ["k", "t"])
        let parsed = try OptionParser.parse(arguments, spec: specification, command: "sort")
        let order = try SortOrder(parsed)
        var output = CommandOutput()
        var lines: [String] = []
        var totalBytes = 0
        let operands = parsed.positionals
        let inputs = try await filterInputs(operands, command: "sort", maxBytes: Self.maxSortBytes, output: &output)
        for input in inputs {
            totalBytes += input.text.data.count
            guard totalBytes <= Self.maxSortBytes else {
                let message = "the inputs hold more than \(Self.maxSortBytes) bytes together; narrow them first"
                output.fail("sort", message, code: 2)
                return output
            }
            var overflow = false
            try input.text.forEachLine(until: deadline) { _, bytes in
                guard lines.count < Self.maxSortLines else {
                    overflow = true
                    return false
                }
                lines.append(input.text.decode(bytes))
                return true
            }
            guard !overflow else {
                output.fail("sort", "the inputs hold more than \(Self.maxSortLines) lines; narrow them first", code: 2)
                return output
            }
        }
        for line in try order.sorted(lines, deadline: deadline) where !output.isFull {
            output.line(line)
        }
        return output
    }
}

/// How `sort` orders lines: by a key (`-k`, `-t`), as numbers (`-n`), ignoring case (`-f`),
/// reversed (`-r`), and once per key (`-u`).
private struct SortOrder {
    let fields: ClosedRange<Int>?
    let separator: Character?
    let numeric: Bool
    let foldCase: Bool
    let reversed: Bool
    let unique: Bool

    /// A line's key, computed once before sorting.
    private enum Key: Comparable {
        case text(String)
        case number(Double)
    }

    /// A line with its key and its place in the input.
    private struct KeyedLine {
        let key: Key
        let line: String
        let index: Int
    }

    init(_ parsed: ParsedArguments) throws {
        numeric = parsed.has("n")
        foldCase = parsed.has("f")
        reversed = parsed.has("r")
        unique = parsed.has("u")
        if let separator = try parsed.singleValue("t", command: "sort") {
            guard separator.count == 1 else {
                throw CommandError.usage("sort: the separator must be a single character")
            }
            self.separator = separator.first
        } else {
            separator = nil
        }
        let keys = parsed.all("k")
        guard keys.count <= 1 else {
            throw CommandError.usage("sort: give one -k; sorting by several keys is not available")
        }
        fields = try keys.first.map(Self.fields)
    }

    /// The lines in order. Throws `VFSError.timeLimitReached` past `deadline` and
    /// `CancellationError` when the task is cancelled.
    func sorted(_ lines: [String], deadline: ContinuousClock.Instant) throws -> [String] {
        var keyed: [KeyedLine] = []
        keyed.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            if index.isMultiple(of: LargeText.linesPerCheck) { try LargeText.checkTime(deadline) }
            keyed.append(KeyedLine(key: key(of: line), line: line, index: index))
        }
        try LargeText.checkTime(deadline)
        let ordered = keyed.sorted { first, second in
            if first.key != second.key {
                return reversed ? first.key > second.key : first.key < second.key
            }
            // With -u lines keep their input order, so the first of equal keys stays, as in GNU sort.
            // Otherwise equal keys fall back to the whole line.
            if unique || first.line == second.line { return first.index < second.index }
            return reversed ? first.line > second.line : first.line < second.line
        }
        guard unique else { return ordered.map(\.line) }
        var kept: [KeyedLine] = []
        for entry in ordered where kept.last?.key != entry.key {
            kept.append(entry)
        }
        return kept.map(\.line)
    }

    private func key(of line: String) -> Key {
        let text = fieldText(of: line)
        if numeric { return .number(Self.leadingNumber(text)) }
        return .text(foldCase ? text.lowercased() : text)
    }

    private func fieldText(of line: String) -> String {
        guard let fields else { return line }
        let parts: [Substring] = if let separator {
            line.split(separator: separator, omittingEmptySubsequences: false)
        } else {
            line.split(whereSeparator: \.isWhitespace)
        }
        guard fields.lowerBound <= parts.count else { return "" }
        let selected = parts[(fields.lowerBound - 1)..<min(fields.upperBound, parts.count)]
        return selected.joined(separator: separator.map(String.init) ?? " ")
    }

    /// The number a line starts with, as `sort -n` reads it. 0 when it starts with none.
    private static func leadingNumber(_ text: String) -> Double {
        let trimmed = text.drop(while: \.isWhitespace)
        var end = trimmed.startIndex
        var seenDigit = false
        var seenPoint = false
        for (offset, character) in trimmed.enumerated() {
            if character.isASCII, character.isNumber {
                seenDigit = true
            } else if character == ".", !seenPoint {
                seenPoint = true
            } else if character != "-" || offset > 0 {
                break
            }
            end = trimmed.index(after: end)
        }
        guard seenDigit, let value = Double(trimmed[..<end]) else { return 0 }
        return value
    }

    /// `-k N` (field N to the end of the line) or `-k N,M`.
    private static func fields(_ text: String) throws -> ClosedRange<Int> {
        let usage = "sort: -k takes a field number, or FIRST,LAST, counted from 1; "
            + "for numbers or reverse order use -n and -r on their own, such as sort -t, -k2,2 -n"
        let bounds = text.split(separator: ",", omittingEmptySubsequences: false)
        guard bounds.count <= 2, let first = Int(bounds[0]), first >= 1 else { throw CommandError.usage(usage) }
        guard bounds.count == 2 else { return first...Int.max }
        guard let last = Int(bounds[1]), last >= first else { throw CommandError.usage(usage) }
        return first...last
    }
}
