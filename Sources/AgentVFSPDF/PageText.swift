//
//  PageText.swift
//  AgentVFSPDF
//
//  Created by Yevhenii Kalashnikov on 14.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

/// The text of one PDF page, with where it came from.
struct PageText: Sendable {
    enum Source: Sendable {
        /// The page's own text layer.
        case textLayer
        /// Recognized from the page image, so it may contain errors.
        case recognized
        /// The page has no text layer and was not recognized yet.
        case missing
        /// The page's content is over `PDFOptions.maxPageContentBytes`, so its text was not extracted.
        case tooLarge
    }

    let text: String
    let source: Source

    /// Bytes the text takes in the cache.
    var byteCount: Int { text.utf8.count }

    /// The text split into lines, without empty ones.
    var lines: [String] {
        text.split(separator: "\n").map(String.init)
    }
}

enum PageTextFormatter {
    /// Collapses runs of spaces inside lines and runs of empty lines, which PDF text extraction
    /// produces from layout and costs tokens without carrying meaning.
    static func normalize(_ raw: String) -> String {
        var lines: [String] = []
        var previousWasBlank = true
        for line in raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: \.isWhitespace)
            if words.isEmpty {
                if !previousWasBlank { lines.append("") }
                previousWasBlank = true
                continue
            }
            lines.append(words.joined(separator: " "))
            previousWasBlank = false
        }
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Page numbers as short ranges, such as `1–3, 7, 9–10`, listing at most `limit` ranges.
    static func compact(_ pages: [Int], limit: Int = 12) -> String {
        var ranges: [ClosedRange<Int>] = []
        for page in pages.sorted() {
            if let last = ranges.last, last.upperBound + 1 == page {
                ranges[ranges.count - 1] = last.lowerBound...page
            } else if ranges.last?.contains(page) != true {
                ranges.append(page...page)
            }
        }
        let shown = ranges.prefix(limit).map { range in
            range.count == 1 ? "\(range.lowerBound)" : "\(range.lowerBound)–\(range.upperBound)"
        }
        let rest = ranges.count > limit ? ", …" : ""
        return shown.joined(separator: ", ") + rest
    }

    /// A rough token count for `characters` of text, to help decide how much to read.
    static func estimatedTokens(characters: Int) -> Int {
        (characters + 3) / 4
    }
}
