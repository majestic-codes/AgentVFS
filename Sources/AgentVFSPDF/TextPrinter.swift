//
//  TextPrinter.swift
//  AgentVFSPDF
//
//  Created by Yevhenii Kalashnikov on 14.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import Foundation

/// Builds `pdftotext` output page by page within the output limits.
struct TextPrinter {
    let file: OpenedDocument
    let invocation: PDFToTextCommand.Invocation
    let options: PDFOptions
    private(set) var text = ""
    private var bytesLeft: Int
    private var linesLeft: Int
    private var recognizedPages = 0
    private let deadline: ContinuousClock.Instant

    /// Room kept for the closing note.
    private static let noteReserve = 400

    private enum StopReason: String {
        case outputLimit = "the output limit"
        case timeLimit = "the time limit"
        case recognitionLimit = "the limit of pages recognized per command"
    }

    /// One page as it is printed.
    private struct Block {
        /// The 1-based page number.
        let page: Int
        /// The page marker line and the page's text.
        let rendered: String
    }

    /// What reading one page gave.
    private enum PageOutcome {
        case block(Block)
        case stopped(StopReason)
    }

    init(
        file: OpenedDocument,
        invocation: PDFToTextCommand.Invocation,
        limits: OutputLimits,
        options: PDFOptions,
        deadline: ContinuousClock.Instant
    ) {
        self.file = file
        self.invocation = invocation
        self.options = options
        self.deadline = deadline
        bytesLeft = limits.maxBytes - Self.noteReserve
        linesLeft = limits.maxLines - 3
    }

    /// Prints the pages of `range` that fit. Throws `CancellationError` when the task is cancelled.
    mutating func print(_ range: PageRange) async throws {
        var blocks: [Block] = []
        for index in range.indices {
            try Task.checkCancellation()
            switch try await outcome(forPage: index) {
            case let .stopped(reason):
                finish(blocks, range: range, stoppedAt: index + 1, reason: reason)
                return
            case let .block(block):
                guard fits(blocks + [block]) else {
                    finishOverflowing(blocks, overflowing: block, range: range)
                    return
                }
                blocks.append(block)
            }
        }
        append(blocks)
    }

    /// The block for one page, or why printing stops there.
    private mutating func outcome(forPage index: Int) async throws -> PageOutcome {
        guard ContinuousClock.now < deadline, var page = try await file.text(ofPage: index, until: deadline) else {
            return .stopped(.timeLimit)
        }
        if page.source == .missing, invocation.recognize {
            guard recognizedPages < options.maxRecognizedPages else { return .stopped(.recognitionLimit) }
            guard let recognized = try await file.recognizeText(ofPage: index, until: deadline) else {
                return .stopped(.timeLimit)
            }
            page = recognized
            recognizedPages += 1
        }
        return .block(Block(page: index + 1, rendered: render(page, number: index + 1)))
    }

    private func render(_ page: PageText, number: Int) -> String {
        let total = file.pageCount
        switch page.source {
        case .textLayer:
            return "--- page \(number) of \(total) ---\n\(page.text)\n"
        case .recognized:
            let body = page.text.isEmpty ? "(no text found on the page image)" : page.text
            return "--- page \(number) of \(total), recognized from the image, may contain errors ---\n\(body)\n"
        case .missing:
            let command = "pdftotext --ocr -f \(number) -l \(number) \(quotedPath)"
            return "--- page \(number) of \(total): no text layer (a scanned image?); read it with \(command) ---\n"
        case .tooLarge:
            let limit = options.maxPageContentBytes
            return "--- page \(number) of \(total): its content is over the limit of \(limit) bytes "
                + "for text extraction, so it was not read ---\n"
        }
    }

    private var quotedPath: String { ShellQuoting.quoted(file.path) }

    private func fits(_ blocks: [Block]) -> Bool {
        let bytes = blocks.reduce(0) { $0 + $1.rendered.utf8.count + 1 }
        let lines = blocks.reduce(0) { $0 + $1.rendered.split(separator: "\n", omittingEmptySubsequences: false).count }
        return bytes <= bytesLeft && lines <= linesLeft
    }

    private mutating func append(_ blocks: [Block]) {
        text += blocks.map(\.rendered).joined(separator: "\n")
    }

    /// Prints what fits when the page after `blocks` does not.
    private mutating func finishOverflowing(_ blocks: [Block], overflowing: Block, range: PageRange) {
        if !invocation.hasRange {
            finishWithoutRange(blocks, overflowing: overflowing)
        } else if blocks.isEmpty {
            appendCut(overflowing, last: range.last)
        } else {
            finish(blocks, range: range, stoppedAt: overflowing.page, reason: .outputLimit)
        }
    }

    /// Prints what fits and a note on how to go on from `stoppedAt`.
    private mutating func finish(_ blocks: [Block], range: PageRange, stoppedAt page: Int, reason: StopReason) {
        append(blocks)
        let recognize = invocation.recognize || reason == .recognitionLimit ? "--ocr " : ""
        let next = "pdftotext \(recognize)-f \(page) -l \(range.last) \(quotedPath)"
        let shown = blocks.first.map { "pages \($0.page)–\(page - 1) of \(file.pageCount) shown" } ?? "no pages shown"
        text += "\n[\(shown), stopped at \(reason.rawValue); continue with: \(next)]\n"
    }

    /// A document read without a range that does not fit: its first pages and where to look next.
    private mutating func finishWithoutRange(_ blocks: [Block], overflowing: Block) {
        let shown = Array(blocks.prefix(PDFToTextCommand.pagesWithoutRange))
        guard let lastShown = shown.last?.page else {
            appendCut(overflowing, last: file.pageCount)
            return
        }
        append(shown)
        text += """

            [pages 1–\(lastShown) of \(file.pageCount) shown; the whole document does not fit. \
            See the outline with: pdfinfo \(quotedPath). Find pages with: pdfgrep PATTERN \(quotedPath). \
            Read a range with: pdftotext -f N -l M \(quotedPath)]

            """
    }

    /// A single page longer than the output limit: its start, cut at a line.
    private mutating func appendCut(_ block: Block, last: Int) {
        var kept: [Substring] = []
        var bytes = 0
        for line in block.rendered.split(separator: "\n") {
            bytes += line.utf8.count + 1
            if bytes > bytesLeft || kept.count >= linesLeft { break }
            kept.append(line)
        }
        text += kept.joined(separator: "\n") + "\n"
        let page = block.page
        let recognize = invocation.recognize ? "--ocr " : ""
        let next = page < last ? "; the next pages: pdftotext \(recognize)-f \(page + 1) -l \(last) \(quotedPath)" : ""
        text += "\n[page \(page) is longer than the output limit and was cut; find the part you need with: "
            + "pdfgrep -C 3 PATTERN \(quotedPath)\(next)]\n"
    }
}
