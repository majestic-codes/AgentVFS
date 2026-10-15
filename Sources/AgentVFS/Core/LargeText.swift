//
//  LargeText.swift
//  AgentVFS
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

/// A text file read for line-oriented work (`head`, `tail`, `sed -n`, `grep`), however large.
///
/// A local file is memory-mapped, so the system pages in only what is touched and nothing is
/// copied. Lines are decoded one at a time. Files no larger than `VFSLimits.maxReadBytes` come
/// through the ordinary read path and its cache.
///
/// A line longer than `maxLineBytes` is cut to that length before it is decoded: commands see, and
/// searches match, only its start, and a printed line ends in `…`. Line loops stop with
/// `CancellationError` when the task is cancelled and with `VFSError.timeLimitReached` at their deadline.
public struct LargeText: Sendable {
    /// Bytes of one line that are decoded. The rest of a longer line is left out.
    public static let maxLineBytes = 1 << 20

    /// Lines walked between two looks at the clock and at cancellation.
    static let linesPerCheck = 1024

    /// Absolute virtual path.
    public let path: String
    /// The file's bytes, in `encoding`.
    public let data: Data
    /// How each line's bytes are decoded: UTF-8, or a single-byte legacy encoding.
    let encoding: String.Encoding

    init(path: String, data: Data, encoding: String.Encoding) {
        self.path = path
        self.data = data
        self.encoding = encoding
    }

    /// The whole file as one string, for tools that parse it entirely, such as `jq`. This holds
    /// the text in memory, so callers bound the size with `largeText(path:maxBytes:)`.
    public var text: String {
        var body = data
        if encoding == .utf8, body.starts(with: [0xEF, 0xBB, 0xBF]) { body = body.dropFirst(3) }
        if encoding == .utf8 { return String(repairingUTF8: body) }
        return String(data: body, encoding: encoding) ?? String(repairingUTF8: body)
    }

    /// Lines `first` through `last` (1-based, `nil` for the end), at most `limit` of them. Throws
    /// `VFSError.timeLimitReached` past `deadline` and `CancellationError` when the task is cancelled.
    public func lines(
        from first: Int,
        through last: Int?,
        limit: Int,
        deadline: ContinuousClock.Instant? = nil
    ) throws -> [String] {
        var selected: [String] = []
        guard limit > 0 else { return selected }
        try forEachLine(until: deadline) { number, line in
            if number < first { return true }
            if let last, number > last { return false }
            selected.append(decode(line))
            return selected.count < limit
        }
        return selected
    }

    /// The last `count` lines. Throws like `lines(from:through:limit:deadline:)`.
    public func lastLines(_ count: Int, deadline: ContinuousClock.Instant? = nil) throws -> [String] {
        guard count > 0 else { return [] }
        return try data.withUnsafeBytes { raw -> [String] in
            let bytes = raw.bindMemory(to: UInt8.self)
            let first = contentStart(of: bytes)
            guard bytes.count > first else { return [] }
            // The final newline ends the last line rather than starting an empty one.
            var cursor = bytes.count
            if bytes[cursor - 1] == UInt8(ascii: "\n") { cursor -= 1 }
            var lines: [String] = []
            while lines.count < count {
                if lines.count.isMultiple(of: Self.linesPerCheck) { try Self.checkTime(deadline) }
                var start = cursor
                while start > first, bytes[start - 1] != UInt8(ascii: "\n") { start -= 1 }
                lines.append(decode(UnsafeBufferPointer(rebasing: bytes[start..<cursor])))
                if start == first { break }
                cursor = start - 1
            }
            return lines.reversed()
        }
    }

    /// Throws `CancellationError` when the task is cancelled and `VFSError.timeLimitReached` once
    /// `deadline` has passed.
    static func checkTime(_ deadline: ContinuousClock.Instant?) throws {
        try Task.checkCancellation()
        if let deadline, ContinuousClock.now >= deadline {
            throw VFSError.timeLimitReached
        }
    }

    /// Matching lines, at most `limit`, stopping at `deadline`.
    func scan(
        _ pattern: CompiledPattern,
        limit: Int,
        deadline: ContinuousClock.Instant
    ) -> (hits: [(line: Int, text: String)], timedOut: Bool) {
        guard limit > 0 else { return ([], false) }
        let limited = pattern.limited(until: min(deadline, pattern.deadline))
        let scanned = scanFast(limited, limit: limit, deadline: limited.deadline)
        // A match the expression gave up on counts as a timeout, since a line may have been missed.
        let gaveUp = scanned.hits.count < limit && limited.isPastDeadline
        return (scanned.hits, scanned.timedOut || gaveUp)
    }

    private func scanFast(
        _ pattern: CompiledPattern,
        limit: Int,
        deadline: ContinuousClock.Instant
    ) -> (hits: [(line: Int, text: String)], timedOut: Bool) {
        if encoding == .utf8, let hint = pattern.literalHint, !hint.isEmpty {
            let asciiOnly = hint.utf8.allSatisfy { $0 < 0x80 }
            if !pattern.hintIsCaseInsensitive || asciiOnly {
                return scanForLiteral(hint, pattern: pattern, limit: limit, deadline: deadline)
            }
        }
        return scanInBlocks(pattern, limit: limit, deadline: deadline)
    }

    /// Jumps from one occurrence of the literal every match contains to the next instead of testing
    /// every line: a plain search through gigabytes takes about a second.
    private func scanForLiteral(
        _ hint: String,
        pattern: CompiledPattern,
        limit: Int,
        deadline: ContinuousClock.Instant
    ) -> (hits: [(line: Int, text: String)], timedOut: Bool) {
        var hits: [(line: Int, text: String)] = []
        var timedOut = false
        let insensitive = pattern.hintIsCaseInsensitive
        let needle = insensitive ? Array(hint.lowercased().utf8) : Array(hint.utf8)
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let first = contentStart(of: bytes)
            var position = first
            var lineNumber = 1
            var counted = first
            var checks = 0
            while position < bytes.count {
                checks += 1
                if checks.isMultiple(of: 256), ContinuousClock.now >= deadline {
                    timedOut = true
                    return
                }
                let found = Self.find(needle, caseInsensitive: insensitive, in: bytes, from: position)
                guard let offset = found else { return }
                let line = Self.lineBounds(around: offset, in: bytes, from: first)
                lineNumber += Self.countNewlines(in: UnsafeBufferPointer(rebasing: bytes[counted..<line.lowerBound]))
                counted = line.lowerBound
                let text = decodeLine(UnsafeBufferPointer(rebasing: bytes[line])).text
                if pattern.matches(text) {
                    hits.append((lineNumber, Self.clipped(text)))
                    if hits.count >= limit { return }
                }
                position = line.upperBound + 1
            }
        }
        return (hits, timedOut)
    }

    /// The first offset at or after `start` where `needle` occurs. A case-insensitive needle is lowercased ASCII.
    private static func find(
        _ needle: [UInt8],
        caseInsensitive: Bool,
        in bytes: UnsafeBufferPointer<UInt8>,
        from start: Int
    ) -> Int? {
        if caseInsensitive {
            return findASCIIInsensitive(needle, in: bytes, from: start)
        }
        guard let base = bytes.baseAddress,
              let found = memmem(base + start, bytes.count - start, needle, needle.count)
        else { return nil }
        return base.distance(to: found.assumingMemoryBound(to: UInt8.self))
    }

    /// The bytes of the line holding `offset`, without its `\n`. Lines start no earlier than `first`.
    private static func lineBounds(
        around offset: Int,
        in bytes: UnsafeBufferPointer<UInt8>,
        from first: Int
    ) -> Range<Int> {
        var start = offset
        while start > first, bytes[start - 1] != UInt8(ascii: "\n") { start -= 1 }
        return start..<lineEnd(in: bytes, from: offset)
    }

    /// The offset of the first `\n` at or after `start` and before `end` (by default the end of the
    /// bytes), or `end` when there is none.
    static func lineEnd(in bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int? = nil) -> Int {
        let limit = end ?? bytes.count
        guard let base = bytes.baseAddress,
              let newline = memchr(base + start, Int32(UInt8(ascii: "\n")), limit - start)
        else { return limit }
        return base.distance(to: newline.assumingMemoryBound(to: UInt8.self))
    }

    /// Where the content starts: after a UTF-8 byte order mark, which marks the encoding and is not content.
    func contentStart(of bytes: UnsafeBufferPointer<UInt8>) -> Int {
        let hasByteOrderMark = encoding == .utf8 && bytes.starts(with: [0xEF, 0xBB, 0xBF])
        return hasByteOrderMark ? 3 : 0
    }

    /// Calls `body` with each line's number and bytes (without `\n` or `\r\n`) until it returns
    /// `false`. Throws like `lines(from:through:limit:deadline:)`, and whatever `body` throws.
    func forEachLine(
        until deadline: ContinuousClock.Instant?,
        _ body: (Int, UnsafeBufferPointer<UInt8>) throws -> Bool
    ) throws {
        try data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = contentStart(of: bytes)
            var number = 1
            while start < bytes.count {
                if number.isMultiple(of: Self.linesPerCheck) { try Self.checkTime(deadline) }
                let end = Self.lineEnd(in: bytes, from: start)
                var lineEnd = end
                if lineEnd > start, bytes[lineEnd - 1] == UInt8(ascii: "\r") { lineEnd -= 1 }
                guard try body(number, UnsafeBufferPointer(rebasing: bytes[start..<lineEnd])) else { return }
                number += 1
                start = end + 1
            }
        }
    }

    /// A line's text for printing: cut to `maxLineBytes`, and then ending in `…`.
    func decode(_ bytes: UnsafeBufferPointer<UInt8>) -> String {
        let line = decodeLine(bytes)
        return line.isClipped ? line.text + "…" : line.text
    }

    /// A line's text, without a final `\r`, cut to `maxLineBytes` at a character boundary.
    func decodeLine(_ bytes: UnsafeBufferPointer<UInt8>) -> (text: String, isClipped: Bool) {
        var slice = bytes
        if slice.last == UInt8(ascii: "\r") { slice = UnsafeBufferPointer(rebasing: slice.dropLast()) }
        guard slice.count > Self.maxLineBytes else { return (decodeChunk(slice), false) }
        var end = Self.maxLineBytes
        if encoding == .utf8 {
            while end > 0, UTF8.isContinuation(slice[end]) { end -= 1 }
        }
        return (decodeChunk(UnsafeBufferPointer(rebasing: slice[..<end])), true)
    }

    /// Bytes decoded as they are, without looking for lines. Callers keep the chunk small.
    func decodeChunk(_ bytes: UnsafeBufferPointer<UInt8>) -> String {
        if encoding == .utf8 {
            return String(repairingUTF8: bytes)
        }
        return String(bytes: bytes, encoding: encoding) ?? String(repairingUTF8: bytes)
    }

    /// The first offset at or after `start` where the lowercased ASCII `needle` occurs, ignoring
    /// the case of ASCII letters.
    private static func findASCIIInsensitive(
        _ needle: [UInt8],
        in bytes: UnsafeBufferPointer<UInt8>,
        from start: Int
    ) -> Int? {
        guard let first = needle.first, bytes.count >= needle.count else { return nil }
        let isLetter = first >= UInt8(ascii: "a") && first <= UInt8(ascii: "z")
        let upper = isLetter ? first - 32 : first
        var index = start
        let last = bytes.count - needle.count
        while index <= last {
            let byte = bytes[index]
            if byte == first || byte == upper {
                var matched = true
                for offset in 1..<needle.count {
                    var candidate = bytes[index + offset]
                    if candidate >= UInt8(ascii: "A") && candidate <= UInt8(ascii: "Z") { candidate += 32 }
                    if candidate != needle[offset] {
                        matched = false
                        break
                    }
                }
                if matched { return index }
            }
            index += 1
        }
        return nil
    }

    /// The number of `\n` bytes in `bytes`.
    static func countNewlines(in bytes: UnsafeBufferPointer<UInt8>) -> Int {
        guard var cursor = bytes.baseAddress, !bytes.isEmpty else { return 0 }
        var count = 0
        var remaining = bytes.count
        while remaining > 0, let found = memchr(cursor, Int32(UInt8(ascii: "\n")), remaining) {
            let next = UnsafePointer(found.assumingMemoryBound(to: UInt8.self) + 1)
            count += 1
            remaining -= cursor.distance(to: next)
            cursor = next
        }
        return count
    }

    /// Characters of a matching line that a search reports. Longer lines are cut and end in `…`.
    static let maxReportedLineCharacters = 1000

    /// A matching line as a search reports it, cut to `maxReportedLineCharacters`.
    static func clipped(_ line: String) -> String {
        guard line.count > maxReportedLineCharacters else { return line }
        return String(line.prefix(maxReportedLineCharacters)) + "…"
    }

    /// How a large file's lines are decoded, judged from its start: `nil` means binary or an
    /// encoding that cannot be read line by line (UTF-16 and UTF-32).
    static func encoding(of data: Data) -> String.Encoding? {
        var sample = data.prefix(65_536)
        if sample.contains(0) { return nil }
        // The sample may end inside a multi-byte character.
        for _ in 0..<4 {
            if String(validating: sample, as: UTF8.self) != nil { return .utf8 }
            guard sample.count == 65_536 || sample.count < data.count else { break }
            sample = sample.dropLast()
        }
        return TextEncodingGuess.singleByte(data)
    }
}
