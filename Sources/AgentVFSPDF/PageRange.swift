//
//  PageRange.swift
//  AgentVFSPDF
//
//  Created by Yevhenii Kalashnikov on 14.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS

/// A run of 1-based page numbers that exists in the document.
struct PageRange: Equatable {
    let first: Int
    let last: Int

    /// 0-based page indexes.
    var indices: ClosedRange<Int> { (first - 1)...(last - 1) }

    /// Every page of a document, which has at least one.
    static func whole(pageCount: Int) -> Self {
        Self(first: 1, last: pageCount)
    }

    /// From `-f FIRST` and `-l LAST`, as poppler reads them: a missing bound is the document's,
    /// and a last page past the end is the end.
    static func bounds(first: String?, last: String?, pageCount: Int, command: String) throws -> Self {
        let start = try first.map { try number($0, option: "-f", command: command) } ?? 1
        let end = try last.map { try number($0, option: "-l", command: command) } ?? pageCount
        return try checked(first: start, last: min(end, pageCount), pageCount: pageCount, command: command)
    }

    /// From `--page-range=A-B` or `--page-range=A`, as pdfgrep reads it, before any document is open.
    static func parse(_ text: String, command: String) throws -> Self {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2 else {
            throw CommandError.usage("\(command): --page-range takes FIRST-LAST, such as 3-7")
        }
        let start = try number(parts[0], option: "--page-range", command: command)
        let end = try parts.count == 2 ? number(parts[1], option: "--page-range", command: command) : start
        guard start <= end else {
            throw CommandError.usage("\(command): the first page \(start) comes after the last page \(end)")
        }
        return Self(first: start, last: end)
    }

    /// The pages of this range that a document of `pageCount` pages has, or `nil` when it has none of them.
    func clamped(to pageCount: Int) -> Self? {
        first <= pageCount ? Self(first: first, last: min(last, pageCount)) : nil
    }

    private static func number(_ text: String, option: String, command: String) throws -> Int {
        guard let value = Int(text), value >= 1 else {
            throw CommandError.usage("\(command): \(option) takes a page number from 1, not '\(text)'")
        }
        return value
    }

    private static func checked(first: Int, last: Int, pageCount: Int, command: String) throws -> Self {
        guard first <= pageCount else {
            throw CommandError.usage("\(command): page \(first) is past the last page (\(pageCount))")
        }
        guard first <= last else {
            throw CommandError.usage("\(command): the first page \(first) comes after the last page \(last)")
        }
        return Self(first: first, last: last)
    }
}
