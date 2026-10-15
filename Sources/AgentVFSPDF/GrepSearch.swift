//
//  GrepSearch.swift
//  AgentVFSPDF
//
//  Created by Yevhenii Kalashnikov on 14.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import Foundation

/// Searches PDFs page by page for `pdfgrep` and builds its output within the limits.
struct GrepSearch {
    let invocation: PDFGrepCommand.Invocation
    let showFilename: Bool
    let deadline: ContinuousClock.Instant
    private(set) var text = ""
    /// Remarks about the search, for standard error, so they stay out of a pipe.
    private(set) var notes: [String] = []
    private(set) var found = false
    private var shownMatches = 0
    private var bytesLeft: Int

    /// Matching lines printed in all. The rest are counted with their pages.
    static let maxShownMatches = 40
    /// Longer lines are cut to this many characters around the match.
    static let maxLineCharacters = 240

    /// What one file's search found.
    private struct FileResult {
        let path: String
        var matchCount = 0
        var hiddenCount = 0
        var hiddenPages: [Int] = []
        var pagesWithoutText: [Int] = []
        var pagesTooLarge: [Int] = []
        var stoppedAt: Int?
    }

    init(
        invocation: PDFGrepCommand.Invocation,
        showFilename: Bool,
        limits: OutputLimits,
        deadline: ContinuousClock.Instant
    ) {
        self.invocation = invocation
        self.showFilename = showFilename
        self.deadline = deadline
        bytesLeft = limits.maxBytes - 1000
    }

    /// Searches one file page by page. Throws `CancellationError` when the task is cancelled.
    mutating func scan(_ file: OpenedDocument) async throws {
        let whole = PageRange.whole(pageCount: file.pageCount)
        guard let range = invocation.pageRange.map({ $0.clamped(to: file.pageCount) }) ?? whole else {
            notes.append("[\(file.path): not searched, it has only \(file.pageCount) pages]")
            return
        }
        var result = FileResult(path: file.path)
        for index in range.indices {
            if let maxCount = invocation.maxCountPerFile, result.matchCount >= maxCount { break }
            try Task.checkCancellation()
            let page = ContinuousClock.now < deadline ? try await file.text(ofPage: index, until: deadline) : nil
            guard let page else {
                result.stoppedAt = index + 1
                break
            }
            switch page.source {
            case .missing:
                result.pagesWithoutText.append(index + 1)
            case .tooLarge:
                result.pagesTooLarge.append(index + 1)
            case .textLayer, .recognized:
                scan(page, number: index + 1, into: &result)
            }
            if invocation.pattern.isPastDeadline {
                result.stoppedAt = index + 1
                break
            }
        }
        report(result, range: range, pageCount: file.pageCount)
    }

    private mutating func scan(_ page: PageText, number: Int, into result: inout FileResult) {
        let lines = page.lines
        var matches: [Int] = []
        for (index, line) in lines.enumerated() where invocation.pattern.matches(line) {
            if let maxCount = invocation.maxCountPerFile, result.matchCount >= maxCount { break }
            result.matchCount += 1
            matches.append(index)
        }
        guard !matches.isEmpty else { return }
        found = true
        guard invocation.mode == .lines else { return }
        let shownCount = min(matches.count, max(0, Self.maxShownMatches - shownMatches))
        let printed = printLines(Array(matches.prefix(shownCount)), of: lines, page: number, path: result.path)
        if printed < matches.count {
            result.hiddenCount += matches.count - printed
            result.hiddenPages.append(number)
        }
        shownMatches += printed
    }

    /// Prints matching lines with their context, `--` between separate groups as grep does, until
    /// the output budget is spent. Returns how many of the matches it printed.
    private mutating func printLines(_ matches: [Int], of lines: [String], page: Int, path: String) -> Int {
        guard !matches.isEmpty else { return 0 }
        let matchSet = Set(matches)
        var groups: [ClosedRange<Int>] = []
        for index in matches {
            let group = max(0, index - invocation.before)...min(lines.count - 1, index + invocation.after)
            if let last = groups.last, last.upperBound + 1 >= group.lowerBound {
                groups[groups.count - 1] = last.lowerBound...max(last.upperBound, group.upperBound)
            } else {
                groups.append(group)
            }
        }
        let name = showFilename ? path : nil
        var printed = 0
        for group in groups {
            guard bytesLeft > 0 else { break }
            if invocation.before + invocation.after > 0, !text.isEmpty { emit("--") }
            for index in group {
                let isMatch = matchSet.contains(index)
                if isMatch, bytesLeft <= 0 { return printed }
                let line = lines[index]
                let clipped = Self.clip(line, around: isMatch ? invocation.pattern.firstMatchRange(in: line) : nil)
                let prefix = [name, "\(page)"].compactMap(\.self).joined(separator: isMatch ? ":" : "-")
                emit("\(prefix)\(isMatch ? ":" : "-") \(clipped)")
                if isMatch { printed += 1 }
            }
        }
        return printed
    }

    private mutating func report(_ result: FileResult, range: PageRange, pageCount: Int) {
        switch invocation.mode {
        case .count:
            emit(showFilename ? "\(result.path):\(result.matchCount)" : "\(result.matchCount)")
        case .filesWithMatches:
            if result.matchCount > 0 { emit(result.path) }
        case .lines:
            if result.hiddenCount > 0 {
                let pages = PageTextFormatter.compact(result.hiddenPages)
                notes.append("[\(result.path): \(result.hiddenCount) more matches not shown, on pages \(pages); "
                    + "narrow the pattern or add --page-range]")
            }
        }
        if !result.pagesWithoutText.isEmpty {
            let pages = PageTextFormatter.compact(result.pagesWithoutText)
            let path = ShellQuoting.quoted(result.path)
            notes.append("[\(result.path): not searched, no text layer on pages \(pages); "
                + "read them with: pdftotext --ocr -f N -l N \(path)]")
        }
        if !result.pagesTooLarge.isEmpty {
            let pages = PageTextFormatter.compact(result.pagesTooLarge)
            let reason = "the content of pages \(pages) is too large to extract text from"
            notes.append("[\(result.path): not searched, \(reason)]")
        }
        if let stoppedAt = result.stoppedAt {
            notes.append("[\(result.path): stopped at the time limit at page \(stoppedAt) of \(pageCount); "
                + "continue with --page-range=\(stoppedAt)-\(range.last)]")
        }
    }

    private mutating func emit(_ line: String) {
        text += line + "\n"
        bytesLeft -= line.utf8.count + 1
    }

    /// `line` cut to `maxLineCharacters`, keeping the match and a little before it in view.
    static func clip(_ line: String, around match: Range<String.Index>?) -> String {
        guard line.count > maxLineCharacters else { return line }
        let matchStart = match.map { line.distance(from: line.startIndex, to: $0.lowerBound) } ?? 0
        let start = max(0, min(matchStart - 80, line.count - maxLineCharacters))
        let windowStart = line.index(line.startIndex, offsetBy: start)
        let windowEnd = line.index(windowStart, offsetBy: maxLineCharacters)
        let head = start > 0 ? "…" : ""
        let tail = windowEnd < line.endIndex ? "…" : ""
        return head + line[windowStart..<windowEnd] + tail
    }
}
