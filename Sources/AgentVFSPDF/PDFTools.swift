//
//  PDFTools.swift
//  AgentVFSPDF
//
//  Created by Yevhenii Kalashnikov on 14.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import Foundation

/// Limits for the PDF commands.
public struct PDFOptions: Sendable {
    /// Largest PDF opened: downloaded from a source without local files, or read from the
    /// local disk when the driver has it there.
    public var maxDownloadBytes: Int
    /// Disk space kept for downloaded PDFs, so the next command on them needs no new download.
    public var downloadCacheBytes: Int
    /// Memory kept for page text already extracted or recognized.
    public var textCacheBytes: Int
    /// Wall-clock limit for one command. The command's own `OutputLimits.timeLimit` applies too.
    public var timeout: Duration
    /// Pages recognized from their image by one `pdftotext --ocr`, which takes about a second each.
    public var maxRecognizedPages: Int
    /// Largest decoded size of the content streams one page draws. Text is not extracted from a
    /// larger page, because extraction costs many times this size in time and memory. A compressed
    /// stream over a sixteenth of it counts as too large without being decoded.
    public var maxPageContentBytes: Int

    #if os(iOS)
    /// The default `maxDownloadBytes`: lower on iOS, where memory is tighter.
    public static let defaultMaxDownloadBytes = 200_000_000
    #else
    /// The default `maxDownloadBytes`.
    public static let defaultMaxDownloadBytes = 1_000_000_000
    #endif

    /// Limits with defaults that suit an agent on a phone or a laptop.
    public init(
        maxDownloadBytes: Int = Self.defaultMaxDownloadBytes,
        downloadCacheBytes: Int = 1_000_000_000,
        textCacheBytes: Int = 64_000_000,
        timeout: Duration = .seconds(30),
        maxRecognizedPages: Int = 10,
        maxPageContentBytes: Int = 4_000_000
    ) {
        self.maxDownloadBytes = maxDownloadBytes
        self.downloadCacheBytes = downloadCacheBytes
        self.textCacheBytes = textCacheBytes
        self.timeout = timeout
        self.maxRecognizedPages = maxRecognizedPages
        self.maxPageContentBytes = maxPageContentBytes
    }
}

/// `pdfinfo`, `pdfgrep` and `pdftotext` for PDF files in the workspace.
///
/// They are built for reading big documents with few tokens: `pdfinfo` shows the outline and how
/// much text there is, `pdfgrep` finds the pages that matter, and `pdftotext` prints a page range.
/// The three share downloads and extracted text, so they belong to one `PDFTools.commands()` call.
public enum PDFTools {
    /// The three commands, sharing one cache.
    public static func commands(options: PDFOptions = PDFOptions()) -> [any WorkspaceCommand] {
        let library = PDFLibrary(options: options)
        return [PDFInfoCommand(library: library), PDFGrepCommand(library: library), PDFToTextCommand(library: library)]
    }

    /// The commands with default limits. Each access makes a new cache, so keep the array for a session.
    public static var all: [any WorkspaceCommand] { commands() }
}

enum PDFCommandError: Error, Equatable {
    case notPDF(String)
    case encrypted(String)
    case empty(String)
    case recognitionFailed(String)
    case unreadablePage(path: String, page: Int)

    var message: String {
        switch self {
        case let .notPDF(path): "\(path): not a PDF file"
        case let .encrypted(path): "\(path): the PDF is protected with a password"
        case let .empty(path): "\(path): the PDF has no pages"
        case let .recognitionFailed(reason): "text recognition failed: \(reason)"
        case let .unreadablePage(path, page): "\(path): page \(page) cannot be read"
        }
    }
}

extension CommandContext {
    /// Opens a PDF for a command, reporting a failure the way every command does.
    func openPDF(
        _ raw: String,
        library: PDFLibrary,
        command: String,
        output: inout CommandOutput
    ) async -> OpenedDocument? {
        do {
            let path = try resolvePath(raw).description
            return try await library.open(path, fileSystem: fileSystem)
        } catch let error as VFSError {
            output.fail(command, describe(error), code: 2)
        } catch let error as PDFCommandError {
            output.fail(command, error.message, code: 2)
        } catch {
            output.fail(command, "\(raw): \(error.localizedDescription)", code: 2)
        }
        return nil
    }
}
