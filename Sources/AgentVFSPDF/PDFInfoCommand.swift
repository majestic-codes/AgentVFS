//
//  PDFInfoCommand.swift
//  AgentVFSPDF
//
//  Created by Yevhenii Kalashnikov on 14.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import Foundation
import PDFKit

/// `pdfinfo FILE`: a short map of a PDF — pages, metadata, how much text it holds, which pages are
/// scanned images, and the outline with page numbers — so the agent can pick what to read.
struct PDFInfoCommand: WorkspaceCommand {
    let name = "pdfinfo"
    let usage = "pdfinfo FILE   pages, outline and text size of a PDF; start here"
    let library: PDFLibrary

    /// Outline entries shown. The rest are counted.
    private static let maxOutlineEntries = 60
    private static let maxOutlineDepth = 3

    func run(_ arguments: [ShellToken], in context: CommandContext) async throws -> CommandOutput {
        let parsed = try OptionParser.parse(arguments, spec: OptionSpec(), command: name)
        guard parsed.positionals.count == 1 else {
            throw CommandError.usage("usage: pdfinfo FILE")
        }
        var output = CommandOutput()
        let operand = parsed.positionals[0]
        guard let file = await context.openPDF(operand, library: library, command: name, output: &output) else {
            return output
        }
        defer { file.close() }
        // The document is read before the text summary, which may abandon a page still in use at the time limit.
        let metadata = metadata(of: file.document)
        let outline = Self.outline(of: file.document)
        output.line("File: \(file.path)")
        output.line("Pages: \(file.pageCount)")
        for line in metadata { output.line(line) }
        output.line("File size: \(ByteCountFormatter.string(fromByteCount: Int64(file.fileSize), countStyle: .file))")
        for line in try await textSummary(of: file, deadline: library.deadline(for: context)) { output.line(line) }
        for line in outline { output.line(line) }
        return output
    }

    private func metadata(of document: PDFDocument) -> [String] {
        let attributes = document.documentAttributes ?? [:]
        let fields: [(label: String, key: PDFDocumentAttribute)] = [
            ("Title", .titleAttribute), ("Author", .authorAttribute), ("Subject", .subjectAttribute),
            ("Creator", .creatorAttribute), ("Producer", .producerAttribute)
        ]
        var lines = fields.compactMap { field -> String? in
            guard let value = attributes[field.key] as? String, !value.isEmpty else { return nil }
            return "\(field.label): \(value)"
        }
        let dates: [(label: String, key: PDFDocumentAttribute)] = [
            ("Created", .creationDateAttribute), ("Modified", .modificationDateAttribute)
        ]
        for date in dates {
            guard let value = attributes[date.key] as? Date else { continue }
            lines.append("\(date.label): \(value.formatted(.iso8601.year().month().day()))")
        }
        if document.isEncrypted { lines.append("Encrypted: yes, readable without a password") }
        return lines
    }

    /// How much text the document holds and which pages have none, measured within the time limit.
    private func textSummary(of file: OpenedDocument, deadline: ContinuousClock.Instant) async throws -> [String] {
        var characters = 0
        var withoutText: [Int] = []
        var tooLarge: [Int] = []
        var measured = 0
        for index in 0..<file.pageCount {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline, let page = try await file.text(ofPage: index, until: deadline) else {
                break
            }
            characters += page.text.count
            switch page.source {
            case .missing: withoutText.append(index + 1)
            case .tooLarge: tooLarge.append(index + 1)
            case .textLayer, .recognized: break
            }
            measured += 1
        }
        let tokens = PageTextFormatter.estimatedTokens(characters: characters)
        var lines: [String] = []
        if measured < file.pageCount {
            lines.append("Text: ~\(tokens) tokens in the first \(measured) pages (stopped at the time limit)")
        } else {
            lines.append("Text: \(characters) characters, ~\(tokens) tokens")
        }
        if !withoutText.isEmpty {
            let pages = PageTextFormatter.compact(withoutText)
            lines.append("Pages without a text layer (scanned?): \(pages); read them with pdftotext --ocr -f N -l N")
        }
        if !tooLarge.isEmpty {
            let pages = PageTextFormatter.compact(tooLarge)
            lines.append("Pages too large to extract text from: \(pages)")
        }
        return lines
    }

    static func outline(of document: PDFDocument) -> [String] {
        guard let root = document.outlineRoot, root.numberOfChildren > 0 else { return [] }
        var lines = ["Outline:"]
        var hidden = 0
        walk(root, depth: 0, document: document) { entry in
            if lines.count > Self.maxOutlineEntries {
                hidden += 1
            } else {
                lines.append(entry)
            }
        }
        if hidden > 0 { lines.append("  (\(hidden) more entries)") }
        return lines
    }

    private static func walk(_ outline: PDFOutline, depth: Int, document: PDFDocument, visit: (String) -> Void) {
        for index in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: index) else { continue }
            let indent = String(repeating: "  ", count: depth + 1)
            let title = child.label ?? "(untitled)"
            // A destination may name a page this document does not have.
            if let page = child.destination?.page, case let pageIndex = document.index(for: page),
               (0..<document.pageCount).contains(pageIndex) {
                visit("\(indent)\(title) — p. \(pageIndex + 1)")
            } else {
                visit("\(indent)\(title)")
            }
            if depth + 1 < Self.maxOutlineDepth {
                walk(child, depth: depth + 1, document: document, visit: visit)
            }
        }
    }
}
