//
//  TextFilterCommands.swift
//  AgentVFS
//
//  Created by Yevhenii Kalashnikov on 14.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

/// One text a filter reads: a file, or the piped input.
struct FilterInput {
    let name: String
    let text: LargeText
    /// The size of the file itself, which differs from `text` when the file was not UTF-8.
    let byteCount: Int
}

extension CommandContext {
    /// The texts a filter reads: the named files, or the piped input when no file is named.
    /// Files that cannot be read are reported on standard error and left out.
    func filterInputs(
        _ operands: [String],
        command: String,
        maxBytes: Int? = nil,
        output: inout CommandOutput
    ) async throws -> [FilterInput] {
        if operands.isEmpty {
            guard let input = pipedText else {
                throw CommandError.usage("\(command): missing file operand (pass a file path or pipe text in)")
            }
            return [FilterInput(name: Self.standardInputName, text: input, byteCount: input.data.count)]
        }
        var inputs: [FilterInput] = []
        for operand in operands {
            do {
                let path = try resolvePath(operand).description
                let text = if let maxBytes {
                    try await fileSystem.largeText(path: path, maxBytes: maxBytes)
                } else {
                    try await fileSystem.largeText(path: path)
                }
                // A source that does not list sizes gives the text as it is stored.
                let size = try await fileSystem.stat(path: path).size ?? text.data.count
                inputs.append(FilterInput(name: operand, text: text, byteCount: size))
            } catch let error as VFSError {
                output.fail(command, describe(error), code: 1)
            }
        }
        return inputs
    }

    // MARK: wc

    func wordCount(_ arguments: [ShellToken]) async throws -> CommandOutput {
        let parsed = try OptionParser.parse(arguments, spec: OptionSpec(flags: ["l", "w", "c", "m"]), command: "wc")
        var output = CommandOutput()
        let inputs = try await filterInputs(parsed.positionals, command: "wc", output: &output)
        let selected = TextCount.allCases.filter { parsed.has($0.rawValue) }
        let columns = selected.isEmpty ? [.lines, .words, .bytes] : selected
        var rows: [(name: String, counts: [Int])] = []
        for input in inputs {
            let counts = try columns.map { try $0.count(in: input, deadline: deadline) }
            rows.append((input.name, counts))
        }
        if rows.count > 1 {
            let totals = columns.indices.map { column in rows.reduce(0) { $0 + $1.counts[column] } }
            rows.append(("total", totals))
        }
        let width = rows.flatMap(\.counts).map { String($0).count }.max() ?? 1
        for row in rows {
            let numbers = row.counts.map { String(repeating: " ", count: width - String($0).count) + String($0) }
            let name = row.name == Self.standardInputName ? "" : " " + row.name
            output.line(numbers.joined(separator: " ") + name)
        }
        return output
    }

    // MARK: uniq

    func unique(_ arguments: [ShellToken]) async throws -> CommandOutput {
        let parsed = try OptionParser.parse(arguments, spec: OptionSpec(flags: ["c", "d", "u", "i"]), command: "uniq")
        guard parsed.positionals.count <= 1 else {
            throw CommandError.usage("uniq: give one file, or pipe text in (writing to a file is not available)")
        }
        var output = CommandOutput()
        guard let input = try await filterInputs(parsed.positionals, command: "uniq", output: &output).first else {
            return output
        }
        let ignoreCase = parsed.has("i")
        var current: UniqueRun?
        func emit(_ run: UniqueRun) {
            if parsed.has("d"), run.count < 2 { return }
            if parsed.has("u"), run.count > 1 { return }
            output.line(parsed.has("c") ? String(format: "%7d ", run.count) + run.line : run.line)
        }
        try input.text.forEachLine(until: deadline) { _, bytes in
            let line = input.text.decode(bytes)
            let key = ignoreCase ? line.lowercased() : line
            if let run = current, run.key == key {
                current?.count += 1
            } else {
                if let run = current { emit(run) }
                current = UniqueRun(line: line, key: key, count: 1)
            }
            return !output.isFull
        }
        if let run = current { emit(run) }
        return output
    }

    // MARK: cut

    func cut(_ arguments: [ShellToken]) async throws -> CommandOutput {
        let specification = OptionSpec(flags: ["s"], valueFlags: ["d", "f", "c"])
        let parsed = try OptionParser.parse(arguments, spec: specification, command: "cut")
        let selection = try CutSelection(parsed)
        var output = CommandOutput()
        for input in try await filterInputs(parsed.positionals, command: "cut", output: &output) {
            try input.text.forEachLine(until: deadline) { _, bytes in
                if let line = selection.apply(to: input.text.decode(bytes)) { output.line(line) }
                return !output.isFull
            }
        }
        return output
    }
}

/// Equal adjacent lines for `uniq`: the first of them, what they are compared by, and how many.
private struct UniqueRun {
    let line: String
    let key: String
    var count: Int
}

/// What `wc` counts, by its option letter.
private enum TextCount: String, CaseIterable {
    case lines = "l"
    case words = "w"
    case characters = "m"
    case bytes = "c"

    /// The count for one input. Lines are newline characters, as `wc` counts them, so a last line
    /// without one is not counted.
    func count(in input: FilterInput, deadline: ContinuousClock.Instant) throws -> Int {
        let text = input.text
        return try text.data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            switch self {
            case .bytes:
                return input.byteCount
            case .lines:
                return LargeText.countNewlines(in: bytes)
            case .characters:
                guard text.encoding == .utf8 else { return bytes.count }
                return bytes.reduce(0) { $0 + (UTF8.isContinuation($1) ? 0 : 1) }
            case .words:
                return try Self.words(in: text, bytes: bytes, deadline: deadline)
            }
        }
    }

    /// Bytes decoded at a time when counting words.
    private static let wordChunkBytes = 1 << 20

    /// The words of a text, decoded a chunk at a time, so a long line is never decoded whole. A word
    /// that runs across two chunks counts once.
    private static func words(
        in text: LargeText,
        bytes: UnsafeBufferPointer<UInt8>,
        deadline: ContinuousClock.Instant
    ) throws -> Int {
        var words = 0
        var inWord = false
        var start = text.contentStart(of: bytes)
        while start < bytes.count {
            try LargeText.checkTime(deadline)
            var end = min(start + wordChunkBytes, bytes.count)
            if text.encoding == .utf8 {
                while end > start + 1, end < bytes.count, UTF8.isContinuation(bytes[end]) { end -= 1 }
            }
            let chunk = text.decodeChunk(UnsafeBufferPointer(rebasing: bytes[start..<end]))
            for character in chunk {
                let isSpace = character.isWhitespace
                if !isSpace, !inWord { words += 1 }
                inWord = !isSpace
            }
            start = end
        }
        return words
    }
}

/// What `cut` keeps of each line: fields split at a delimiter (`-f`), or characters (`-c`).
private struct CutSelection {
    /// The selected 1-based positions, sorted, without overlaps.
    let ranges: [ClosedRange<Int>]
    let byCharacter: Bool
    let delimiter: Character
    let onlyDelimited: Bool

    /// More ranges than this in one list are refused.
    static let maxRanges = 1000

    init(_ parsed: ParsedArguments) throws {
        let usage = "cut: use -f LIST with -d SEP for fields, or -c LIST for characters (LIST like 1,3-5,7-)"
        let fields = try parsed.singleValue("f", command: "cut")
        let characters = try parsed.singleValue("c", command: "cut")
        let delimiterValue = try parsed.singleValue("d", command: "cut")
        switch (fields, characters) {
        case let (.some(list), nil):
            ranges = try Self.ranges(list, usage: usage)
            byCharacter = false
        case let (nil, .some(list)):
            guard delimiterValue == nil, !parsed.has("s") else {
                throw CommandError.usage("cut: -d and -s go with -f, not with -c")
            }
            ranges = try Self.ranges(list, usage: usage)
            byCharacter = true
        default:
            throw CommandError.usage(usage)
        }
        let delimiter = delimiterValue ?? "\t"
        guard delimiter.count == 1, let character = delimiter.first else {
            throw CommandError.usage("cut: the delimiter must be a single character")
        }
        self.delimiter = character
        onlyDelimited = parsed.has("s")
    }

    /// The kept part of `line`, or `nil` when `-s` drops a line without the delimiter.
    func apply(to line: String) -> String? {
        if byCharacter {
            return String(selected(from: Array(line)))
        }
        let parts = line.split(separator: delimiter, omittingEmptySubsequences: false)
        guard parts.count > 1 else { return onlyDelimited ? nil : line }
        return selected(from: parts).joined(separator: String(delimiter))
    }

    /// The elements at the selected positions, in order.
    private func selected<Element>(from elements: [Element]) -> [Element] {
        var kept: [Element] = []
        for range in ranges {
            guard range.lowerBound <= elements.count else { break }
            kept += elements[(range.lowerBound - 1)..<min(range.upperBound, elements.count)]
        }
        return kept
    }

    private static func ranges(_ list: String, usage: String) throws -> [ClosedRange<Int>] {
        let parts = list.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count <= maxRanges else {
            throw CommandError.usage("cut: a list may have at most \(maxRanges) parts")
        }
        let parsed = try parts.map { part in
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
            guard !part.isEmpty, part != "-", bounds.count <= 2 else { throw CommandError.usage(usage) }
            let low = bounds[0].isEmpty ? 1 : Int(bounds[0])
            let high = bounds.count == 1 ? low : (bounds[1].isEmpty ? Int.max : Int(bounds[1]))
            guard let low, let high, low >= 1, low <= high else {
                throw CommandError.usage(usage)
            }
            return low...high
        }
        var merged: [ClosedRange<Int>] = []
        for range in parsed.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound - 1 <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
