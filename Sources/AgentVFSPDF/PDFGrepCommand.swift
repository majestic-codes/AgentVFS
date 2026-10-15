//
//  PDFGrepCommand.swift
//  AgentVFSPDF
//
//  Created by Yevhenii Kalashnikov on 14.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import Foundation

/// `pdfgrep [OPTIONS] PATTERN FILE|DIR...`: matching lines of PDFs with their page numbers.
///
/// Like pdfgrep, the pattern is an extended regular expression and `-r` searches the PDFs in a
/// directory. Every match shows its page, long lines are cut around the match, and after a few
/// dozen matches the rest are only counted with their pages, so a broad pattern stays cheap.
struct PDFGrepCommand: WorkspaceCommand {
    let name = "pdfgrep"
    let usage = "pdfgrep [-i] [-F] [-c] [-C N] [--page-range=A-B] [-r] PATTERN FILE|DIR...   "
        + "search PDFs, shows page numbers"
    let library: PDFLibrary

    enum Mode {
        case lines
        case count
        case filesWithMatches
    }

    /// Whether lines start with the file name: `-H`, `-h`, or by default when several files are searched.
    enum FilenameChoice {
        case automatic
        case shown
        case hidden
    }

    struct Invocation {
        var pattern: CompiledPattern
        var operands: [String]
        var mode: Mode
        var recursive: Bool
        var filename: FilenameChoice
        var pageRange: PageRange?
        var maxCountPerFile: Int?
        var before: Int
        var after: Int
    }

    func run(_ arguments: [ShellToken], in context: CommandContext) async throws -> CommandOutput {
        let invocation = try Self.parse(arguments)
        var output = CommandOutput()
        let files = await pdfFiles(invocation, context: context, output: &output)
        let showFilename = switch invocation.filename {
        case .automatic: files.count > 1 || invocation.recursive
        case .shown: true
        case .hidden: false
        }
        let deadline = library.deadline(for: context)
        var limitedInvocation = invocation
        limitedInvocation.pattern = invocation.pattern.limited(until: deadline)
        var search = GrepSearch(
            invocation: limitedInvocation,
            showFilename: showFilename,
            limits: context.limits,
            deadline: deadline
        )
        for path in files {
            guard let file = await context.openPDF(path, library: library, command: name, output: &output) else {
                continue
            }
            defer { file.close() }
            try await search.scan(file)
        }
        output.content(search.text)
        for note in search.notes {
            output.error(note, code: 0)
        }
        let failed = output.exitCode == 2
        output.exitCode = failed ? 2 : (search.found ? 0 : 1)
        return output
    }

    /// The PDF paths to search: the operands, with directories expanded under `-r`.
    private func pdfFiles(
        _ invocation: Invocation,
        context: CommandContext,
        output: inout CommandOutput
    ) async -> [String] {
        var files: [String] = []
        for operand in invocation.operands {
            do {
                let path = try context.resolvePath(operand).description
                let info = try await context.fileSystem.stat(path: path)
                guard info.kind == .directory else {
                    files.append(path)
                    continue
                }
                guard invocation.recursive else {
                    output.fail(name, "\(operand): is a directory; search the PDFs in it with -r", code: 2)
                    continue
                }
                let query = FindQuery(namePattern: "*.pdf", caseInsensitive: true, kinds: [.file], limit: 200)
                let found = try await context.fileSystem.find(path: path, query: query)
                files += found.entries.map(\.path)
                if !found.isComplete {
                    let count = found.entries.count
                    let note = "[\(operand): only the first \(count) PDFs were searched; name a smaller directory]"
                    output.error(note, code: 0)
                }
            } catch let error as VFSError {
                output.fail(name, context.describe(error), code: 2)
            } catch {
                output.fail(name, "\(operand): \(error.localizedDescription)", code: 2)
            }
        }
        return files
    }

    private static let optionSpecification: OptionSpec = {
        let flags: Set<String> = ["i", "F", "E", "G", "w", "n", "c", "l", "H", "h", "r", "R"]
        var specification = OptionSpec(flags: flags, valueFlags: ["e", "m", "A", "B", "C"])
        specification.longFlags = [
            "ignore-case": "i", "fixed-strings": "F", "word-regexp": "w", "page-number": "n", "count": "c",
            "files-with-matches": "l", "with-filename": "H", "no-filename": "h", "recursive": "r"
        ]
        specification.longValueFlags = [
            "regexp": "e", "max-count": "m", "page-range": "page-range",
            "after-context": "A", "before-context": "B", "context": "C"
        ]
        specification.hints = [
            "-v": "inverted matching is not available",
            "-P": "Perl expressions are not available; the default is extended"
        ]
        return specification
    }()

    static func parse(_ arguments: [ShellToken]) throws -> Invocation {
        let parsed = try OptionParser.parse(arguments, spec: optionSpecification, command: "pdfgrep")
        var operands = parsed.positionals
        let patternText: String
        let explicit = parsed.all("e")
        if explicit.count > 1 {
            let message = "pdfgrep: give one pattern; join alternatives with | in one -e, such as -e 'cat|dog'"
            throw CommandError.usage(message)
        } else if let only = explicit.first {
            patternText = only
        } else if operands.isEmpty {
            throw CommandError.usage("usage: pdfgrep [OPTIONS] PATTERN FILE|DIR...")
        } else {
            patternText = operands.removeFirst()
        }
        guard !operands.isEmpty else {
            throw CommandError.usage("pdfgrep: name the PDF files to search, or a directory with -r")
        }
        let syntax: PatternSyntax = parsed.has("F") ? .fixed : (parsed.has("G") ? .basic : .extended)
        let pattern = try PatternCompiler.compile(
            patternText,
            syntax: syntax,
            caseInsensitive: parsed.has("i"),
            wholeWord: parsed.has("w")
        )
        let context = try parsed.value("C").map { try contextLines($0, option: "-C") } ?? 0
        return Invocation(
            pattern: pattern,
            operands: operands,
            mode: parsed.has("l") ? .filesWithMatches : (parsed.has("c") ? .count : .lines),
            recursive: parsed.has("r") || parsed.has("R"),
            filename: parsed.has("H") ? .shown : (parsed.has("h") ? .hidden : .automatic),
            pageRange: try parsed.value("page-range").map { try PageRange.parse($0, command: "pdfgrep") },
            maxCountPerFile: try parsed.value("m").map { try number($0, option: "-m") },
            before: try parsed.value("B").map { try contextLines($0, option: "-B") } ?? context,
            after: try parsed.value("A").map { try contextLines($0, option: "-A") } ?? context
        )
    }

    /// Context larger than this is cut down. Reading a whole page is what `pdftotext` is for.
    private static let maxContextLines = 20

    private static func contextLines(_ text: String, option: String) throws -> Int {
        let lines = try number(text, option: option)
        return min(lines, maxContextLines)
    }

    private static func number(_ text: String, option: String) throws -> Int {
        guard let value = Int(text), value >= 0 else {
            throw CommandError.usage("pdfgrep: \(option) takes a number, not '\(text)'")
        }
        return value
    }
}
