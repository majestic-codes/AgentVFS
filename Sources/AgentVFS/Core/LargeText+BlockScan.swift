//
//  LargeText+BlockScan.swift
//  AgentVFS
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

// NSRegularExpression exception: its matching callback enforces the time limit.
// NSString lets it run over a block of megabytes without copying it into a Swift String.
// swiftlint:disable legacy_objc_type
extension LargeText {
    static let blockSize = 4 << 20

    /// Runs the expression over blocks of a few megabytes instead of line by line, which is many times
    /// faster, and confirms each hit on its own line, so a match that only exists across a line break
    /// is not reported.
    func scanInBlocks(
        _ pattern: CompiledPattern,
        limit: Int,
        deadline: ContinuousClock.Instant
    ) -> (hits: [(line: Int, text: String)], timedOut: Bool) {
        var hits: [(line: Int, text: String)] = []
        var timedOut = false
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard let base = bytes.baseAddress else { return }
            var position = contentStart(of: bytes)
            var lineNumber = 1
            while position < bytes.count {
                if ContinuousClock.now >= deadline {
                    timedOut = true
                    return
                }
                let end = blockEnd(in: bytes, from: position)
                let block = UnsafeBufferPointer(rebasing: bytes[position..<end])
                let text = NSString(bytes: base + position, length: block.count, encoding: encoding.rawValue)
                    ?? (String(repairingUTF8: block) as NSString)
                var blockScan = BlockScan(text: text, firstLine: lineNumber)
                timedOut = blockScan.collect(pattern, into: &hits, limit: limit, deadline: deadline)
                if timedOut || hits.count >= limit { return }
                lineNumber += Self.countNewlines(in: block)
                position = end
            }
        }
        return (hits, timedOut)
    }

    /// The end of the block that starts at `start`: just past the first `\n` after `blockSize` bytes,
    /// or the end of the bytes. A line that goes on for more than `maxLineBytes` past `blockSize` is
    /// cut at a character boundary, so a block never holds more than `blockSize + maxLineBytes` bytes.
    func blockEnd(in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        let end = start + Self.blockSize
        guard end < bytes.count else { return bytes.count }
        let reach = min(end + Self.maxLineBytes, bytes.count)
        let newline = Self.lineEnd(in: bytes, from: end, to: reach)
        if newline < reach { return newline + 1 }
        guard reach < bytes.count else { return bytes.count }
        var cut = reach
        if encoding == .utf8 {
            while cut > end, UTF8.isContinuation(bytes[cut]) { cut -= 1 }
        }
        return cut
    }
}

/// The matches of one block, found with the regular expression over the whole block.
private struct BlockScan {
    let text: NSString
    var searchFrom = 0
    var countedTo = 0
    var lineNumber: Int

    init(text: NSString, firstLine: Int) {
        self.text = text
        self.lineNumber = firstLine
    }

    /// Appends the block's matching lines to `hits` until there are `limit`. Returns `true` when
    /// `deadline` passed first.
    mutating func collect(
        _ pattern: CompiledPattern,
        into hits: inout [(line: Int, text: String)],
        limit: Int,
        deadline: ContinuousClock.Instant
    ) -> Bool {
        while searchFrom < text.length, let match = pattern.firstMatch(in: text, from: searchFrom) {
            let lineStart = lineStart(before: match.location)
            let lineEnd = lineEnd(from: match.location)
            lineNumber += countNewlines(from: countedTo, to: lineStart)
            countedTo = lineStart
            var line = text.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
            if line.hasSuffix("\r") { line.removeLast() }
            if pattern.matches(line) {
                hits.append((lineNumber, LargeText.clipped(line)))
                if hits.count >= limit { return false }
            }
            searchFrom = lineEnd + 1
            if ContinuousClock.now >= deadline { return true }
        }
        return false
    }

    /// Where the line holding `location` starts. Never before `searchFrom`, which is a line start.
    private func lineStart(before location: Int) -> Int {
        let range = NSRange(location: searchFrom, length: location - searchFrom)
        let found = text.range(of: "\n", options: [.literal, .backwards], range: range)
        return found.location == NSNotFound ? searchFrom : found.location + 1
    }

    /// Where the line holding `location` ends: the offset of its `\n`, or the end of the text.
    private func lineEnd(from location: Int) -> Int {
        let range = NSRange(location: location, length: text.length - location)
        let found = text.range(of: "\n", options: .literal, range: range)
        return found.location == NSNotFound ? text.length : found.location
    }

    private func countNewlines(from start: Int, to end: Int) -> Int {
        var between = text.substring(with: NSRange(location: start, length: end - start))
        return between.withUTF8(LargeText.countNewlines)
    }
}
// swiftlint:enable legacy_objc_type
