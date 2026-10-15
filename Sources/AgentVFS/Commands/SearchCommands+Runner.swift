//
//  SearchCommands+Runner.swift
//  AgentVFS
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

/// What a search has found so far, across every operand.
private struct SearchTally {
    var matchCount = 0
    var filesScanned = 0
    var reasons: [TruncationReason] = []
    var tooLarge = 0
    var tooLargeSamples: [String] = []
    var unreadable = 0
    var seenFiles = Set<String>()
    var counts: [(path: String, count: Int)] = []
    var contextGroups = 0

    mutating func add(_ page: SearchPage) {
        matchCount += page.matches.count
        filesScanned += page.filesScanned
        tooLarge += page.skippedTooLargeCount
        for skipped in page.skippedSample where tooLargeSamples.count < 3 {
            if case .tooLarge = skipped.reason, !tooLargeSamples.contains(skipped.path) {
                tooLargeSamples.append(skipped.path)
            }
        }
        unreadable += page.skippedUnreadableCount
        for reason in page.truncation where !reasons.contains(reason) {
            reasons.append(reason)
        }
    }

    mutating func count(_ matches: [SearchMatch]) {
        for match in matches {
            if let last = counts.last, last.path == match.path {
                counts[counts.count - 1].count += 1
            } else {
                counts.append((match.path, 1))
            }
        }
    }

    /// The per-file counts of `-c`, or the bare count for one file searched without recursion.
    /// Without file names (`-h`) each count is printed on its own.
    func printCounts(into output: inout CommandOutput, request: SearchRequest) {
        let single = !request.recursive && request.operands.count == 1
        if single, output.exitCode == 0 {
            output.line("\(counts.first?.count ?? 0)")
            return
        }
        for entry in counts {
            output.line(request.showFilename ? "\(entry.path):\(entry.count)" : "\(entry.count)")
        }
        if !counts.isEmpty, request.command == "grep" {
            output.error("[files without matches are not listed]", code: 0)
        }
    }

    /// Notes on what the search did not cover, so missing results are not taken as proof of absence.
    func printNotes(into output: inout CommandOutput, request: SearchRequest) {
        if matchCount == 0, output.exitCode == 0 {
            output.error("[no matches; searched \(filesScanned) files]", code: 0)
        }
        if !reasons.isEmpty {
            let messages = reasons.map(\.message).joined(separator: "; ")
            output.error("[search incomplete: \(messages). Missing results are not proof of absence.]", code: 0)
        }
        if tooLarge > 0 {
            let noun = tooLarge == 1 ? "file" : "files"
            let samples = tooLargeSamples.joined(separator: ", ")
            let limit = request.options.maxFileBytes
            output.error("[\(tooLarge) \(noun) skipped: larger than \(limit) bytes (for example \(samples))]", code: 0)
        }
        if unreadable > 0 {
            output.error("[\(unreadable) \(unreadable == 1 ? "file" : "files") could not be read]", code: 0)
        }
    }
}

extension CommandContext {
    func runSearch(_ request: SearchRequest) async throws -> CommandOutput {
        var output = CommandOutput()
        var tally = SearchTally()
        for operand in request.operands {
            do {
                guard let page = try await search(operand, request: request, output: &output) else { continue }
                tally.add(page)
                try await printMatches(page.matches, request: request, tally: &tally, into: &output)
            } catch let VFSError.invalidPattern(reason) {
                output.fail(request.command, "invalid pattern: \(reason)", code: 2)
                return output
            } catch let error as VFSError {
                request.fail(describe(error), into: &output)
            }
        }
        if request.mode == .count {
            tally.printCounts(into: &output, request: request)
        }
        tally.printNotes(into: &output, request: request)
        if output.exitCode == 0, tally.matchCount == 0 {
            output.exitCode = 1
        }
        return output
    }

    /// Searches one operand. `nil` when the operand is a directory and the search is not recursive.
    private func search(
        _ operand: String,
        request: SearchRequest,
        output: inout CommandOutput
    ) async throws -> SearchPage? {
        let root = try resolvePath(operand)
        if !request.recursive {
            let entry = try await fileSystem.stat(path: root.description)
            if entry.kind == .directory {
                request.fail("\(root.description): Is a directory", into: &output)
                return nil
            }
        }
        var options = request.options
        if request.rebaseGlobs {
            let base = root.mountPath
            options.includeGlobs = options.includeGlobs.map { Self.rebase($0, onto: base) }
            options.excludeGlobs = options.excludeGlobs.map { Self.rebase($0, onto: base) }
        }
        return try await fileSystem.search(pattern: request.pattern, path: root.description, options: options)
    }

    private func printMatches(
        _ matches: [SearchMatch],
        request: SearchRequest,
        tally: inout SearchTally,
        into output: inout CommandOutput
    ) async throws {
        switch request.mode {
        case .lines where request.before > 0 || request.after > 0:
            try await printWithContext(matches, request: request, into: &output, groups: &tally.contextGroups)
        case .lines:
            for match in matches {
                output.line(prefix(path: match.path, line: match.line, isMatch: true, request: request) + match.text)
            }
        case .filesWithMatches:
            for match in matches where tally.seenFiles.insert(match.path).inserted {
                output.line(match.path)
            }
        case .count:
            tally.count(matches)
        }
    }

    /// Matches with the lines around them. The files were just searched, so reading them again
    /// comes from the cache. A file that cannot be read now has its matches printed as they were found.
    private func printWithContext(
        _ matches: [SearchMatch],
        request: SearchRequest,
        into output: inout CommandOutput,
        groups: inout Int
    ) async throws {
        for file in Self.matchedLinesByFile(matches) {
            let text: LargeText
            do {
                text = try await fileSystem.largeText(path: file.path)
            } catch is VFSError {
                for match in matches where match.path == file.path {
                    let linePrefix = prefix(path: match.path, line: match.line, isMatch: true, request: request)
                    output.line(linePrefix + match.text)
                }
                continue
            }
            try printContext(around: file, of: text, request: request, into: &output, groups: &groups)
        }
    }

    /// The matching lines of one text with the lines around them, the way grep prints them: `path:N:`
    /// on matching lines, `path-N-` on context lines and `--` between groups that do not touch.
    /// `groups` counts the groups printed so far, across texts.
    func printContext(
        around matched: (path: String, lines: [Int]),
        of text: LargeText,
        request: SearchRequest,
        into output: inout CommandOutput,
        groups: inout Int
    ) throws {
        let path = matched.path
        let matching = Set(matched.lines)
        let ranges = Self.contextRanges(around: matched.lines, request: request)
        let collected = try Self.collectLines(of: text, in: ranges, deadline: deadline)
        for range in ranges {
            let present = range.compactMap { number in collected[number].map { (number: number, text: $0) } }
            guard !present.isEmpty else { continue }
            if groups > 0 { output.line("--") }
            groups += 1
            for line in present {
                let isMatch = matching.contains(line.number)
                let linePrefix = prefix(path: path, line: line.number, isMatch: isMatch, request: request)
                output.line(linePrefix + line.text)
            }
        }
    }

    /// The matching line numbers of each file, in the order the files were found.
    private static func matchedLinesByFile(_ matches: [SearchMatch]) -> [(path: String, lines: [Int])] {
        var byFile: [(path: String, lines: [Int])] = []
        for match in matches {
            if let last = byFile.last, last.path == match.path {
                byFile[byFile.count - 1].lines.append(match.line)
            } else {
                byFile.append((match.path, [match.line]))
            }
        }
        return byFile
    }

    /// The line ranges to print around matching lines, with overlapping or touching ranges merged.
    static func contextRanges(around lines: [Int], request: SearchRequest) -> [ClosedRange<Int>] {
        var ranges: [ClosedRange<Int>] = []
        for line in lines.sorted() where line >= 1 {
            let range = max(1, line - request.before)...(line + request.after)
            if let last = ranges.last, range.lowerBound <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                ranges.append(range)
            }
        }
        return ranges
    }

    /// The text of the lines inside `ranges`, keyed by line number, read in one pass over the file.
    static func collectLines(
        of text: LargeText,
        in ranges: [ClosedRange<Int>],
        deadline: ContinuousClock.Instant
    ) throws -> [Int: String] {
        guard let lastNeeded = ranges.last?.upperBound else { return [:] }
        var collected: [Int: String] = [:]
        var current = 0
        try text.forEachLine(until: deadline) { number, bytes in
            if number > lastNeeded { return false }
            while current < ranges.count, number > ranges[current].upperBound { current += 1 }
            if current < ranges.count, ranges[current].contains(number) {
                collected[number] = text.decode(bytes)
            }
            return true
        }
        return collected
    }

    /// What a printed line starts with: the path and the line number when the request shows them,
    /// each followed by `:` on a matching line and `-` on a context line.
    func prefix(path: String, line: Int, isMatch: Bool, request: SearchRequest) -> String {
        let separator = isMatch ? ":" : "-"
        var label = ""
        if request.showFilename { label += path + separator }
        if request.showLineNumbers { label += "\(line)" + separator }
        return label
    }
}

extension SearchRequest {
    /// Reports a file that cannot be searched, unless `suppressErrors` leaves the message out. The
    /// exit status says so either way.
    func fail(_ message: String, into output: inout CommandOutput) {
        if suppressErrors {
            output.exitCode = max(output.exitCode, 2)
        } else {
            output.fail(command, message, code: 2)
        }
    }
}
