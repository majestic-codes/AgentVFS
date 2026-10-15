//
//  PDFToTextCommand.swift
//  AgentVFSPDF
//
//  Created by Yevhenii Kalashnikov on 14.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import Foundation

/// `pdftotext [-f FIRST] [-l LAST] [--ocr] FILE [-]`: the text of a page range, one block per page.
///
/// Output stops at a page boundary when the next page would pass the output limit, and says
/// where to continue. Without a range, a document that does not fit shows only its first pages
/// and a pointer to `pdfinfo` and `pdfgrep`, instead of spending the whole limit on the start.
struct PDFToTextCommand: WorkspaceCommand {
    let name = "pdftotext"
    let usage = "pdftotext [-f FIRST] [-l LAST] [--ocr] FILE   text of a page range; --ocr reads scanned pages"
    let library: PDFLibrary

    /// Pages shown when no range was given and the whole document does not fit.
    static let pagesWithoutRange = 2

    struct Invocation {
        var file: String
        var first: String?
        var last: String?
        var recognize: Bool
        var hasRange: Bool { first != nil || last != nil }
    }

    func run(_ arguments: [ShellToken], in context: CommandContext) async throws -> CommandOutput {
        let invocation = try Self.parse(arguments)
        var output = CommandOutput()
        guard let file = await context.openPDF(invocation.file, library: library, command: name, output: &output) else {
            return output
        }
        defer { file.close() }
        let range = try PageRange.bounds(
            first: invocation.first,
            last: invocation.last,
            pageCount: file.pageCount,
            command: name
        )
        var printer = TextPrinter(
            file: file,
            invocation: invocation,
            limits: context.limits,
            options: library.options,
            deadline: library.deadline(for: context)
        )
        do {
            try await printer.print(range)
        } catch let error as PDFCommandError {
            output.content(printer.text)
            output.fail(name, error.message, code: 1)
            return output
        }
        output.content(printer.text)
        return output
    }

    /// poppler's single-dash long options, which the short-option parser would misread.
    private static let refusedOptions = [
        "-layout": "layout mode is not available; the text comes in reading order",
        "-raw": "raw mode is not available; the text comes in reading order",
        "-bbox": "word boxes are not available",
        "-htmlmeta": "HTML output is not available"
    ]
    private static let ignoredOptions: Set<String> = ["-nopgbrk", "-q"]

    static func parse(_ arguments: [ShellToken]) throws -> Invocation {
        var tokens: [ShellToken] = []
        var recognize = false
        var iterator = arguments.makeIterator()
        while let token = iterator.next() {
            if let hint = refusedOptions[token.text], !token.isQuoted {
                throw CommandError.usage("pdftotext: unsupported option \(token.text) (\(hint))")
            }
            if token.text == "-enc", !token.isQuoted {
                _ = iterator.next()
                continue
            }
            if token.text == "-ocr", !token.isQuoted {
                recognize = true
                continue
            }
            if ignoredOptions.contains(token.text), !token.isQuoted {
                continue
            }
            tokens.append(token)
        }
        var specification = OptionSpec(valueFlags: ["f", "l"])
        specification.longFlags = ["ocr": "ocr"]
        specification.longValueFlags = ["first-page": "f", "last-page": "l"]
        let parsed = try OptionParser.parse(tokens, spec: specification, command: "pdftotext")
        return try invocation(from: parsed, recognize: recognize || parsed.has("ocr"))
    }

    private static func invocation(from parsed: ParsedArguments, recognize: Bool) throws -> Invocation {
        let operands = parsed.positionals
        guard operands.count == 1 || operands.count == 2 else {
            throw CommandError.usage("usage: pdftotext [-f FIRST] [-l LAST] [--ocr] FILE [-]")
        }
        if operands.count == 2, operands[1] != "-" {
            let message = "pdftotext: writing files is not available; the text is printed, so leave out OUTPUT or use -"
            throw CommandError.usage(message)
        }
        return Invocation(file: operands[0], first: parsed.value("f"), last: parsed.value("l"), recognize: recognize)
    }
}
