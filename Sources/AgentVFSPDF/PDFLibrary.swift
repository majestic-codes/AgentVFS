//
//  PDFLibrary.swift
//  AgentVFSPDF
//
//  Created by Yevhenii Kalashnikov on 14.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import Foundation
import PDFKit
import Synchronization

/// What the PDF commands share: downloaded files and the text already taken from them, so a
/// `pdfgrep` after `pdfinfo` does not parse the document again.
final class PDFLibrary: Sendable {
    let options: PDFOptions
    private let downloads: DownloadCache
    private let texts: Mutex<TextCache>

    init(options: PDFOptions) {
        self.options = options
        downloads = DownloadCache(capacity: options.downloadCacheBytes, label: "PDF")
        texts = Mutex(TextCache(capacity: options.textCacheBytes))
    }

    /// Opens the PDF at the virtual `path`. Call `close()` on the result when done.
    func open(_ path: String, fileSystem: WorkspaceFileSystem) async throws -> OpenedDocument {
        let lease = try await downloads.lease(path: path, fileSystem: fileSystem, maxBytes: options.maxDownloadBytes)
        do {
            let data = try contents(of: lease, path: path)
            let document = try Self.document(from: data, path: path)
            return OpenedDocument(
                path: path,
                data: data,
                document: document,
                cacheKey: lease.version,
                fileSize: data.count,
                lease: lease,
                library: self
            )
        } catch {
            lease.finish()
            throw error
        }
    }

    /// A downloaded copy never changes, so it is mapped. A file in place may shrink while it is
    /// open, which would crash a process reading it through a mapping, so it is read whole.
    private func contents(of lease: DownloadCache.Lease, path: String) throws -> Data {
        if lease.isCopy {
            return try Data(contentsOf: lease.url, options: .alwaysMapped)
        }
        let handle = try FileHandle(forReadingFrom: lease.url)
        let read = Result { () throws -> Data in
            let size = try handle.seekToEnd()
            guard size <= UInt64(options.maxDownloadBytes) else {
                throw VFSError.fileTooLarge(path: path, size: Int(clamping: size), limit: options.maxDownloadBytes)
            }
            try handle.seek(toOffset: 0)
            return try handle.readToEnd() ?? Data()
        }
        try handle.close()
        return try read.get()
    }

    private static func document(from data: Data, path: String) throws -> PDFDocument {
        guard data.starts(with: Data("%PDF-".utf8)), let document = PDFDocument(data: data) else {
            throw PDFCommandError.notPDF(path)
        }
        guard !document.isLocked else { throw PDFCommandError.encrypted(path) }
        guard document.pageCount > 0 else { throw PDFCommandError.empty(path) }
        return document
    }

    /// When a command started now must stop: at `PDFOptions.timeout` or at the command's own time
    /// limit, whichever comes first.
    func deadline(for context: CommandContext) -> ContinuousClock.Instant {
        min(ContinuousClock.now + options.timeout, context.deadline)
    }

    func cachedPage(_ index: Int, key: String) -> PageText? {
        texts.withLock { $0.page(index, key: key) }
    }

    func store(_ page: PageText, index: Int, key: String) {
        texts.withLock { $0.store(page, index: index, key: key) }
    }
}

/// Text of recently read documents, keyed by file version and page index, bounded by size.
struct TextCache {
    let capacity: Int
    private var pages: [String: [Int: PageText]] = [:]
    /// Keys from least to most recently used.
    private var order: [String] = []
    private(set) var bytes = 0

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func page(_ index: Int, key: String) -> PageText? {
        guard let page = pages[key]?[index] else { return nil }
        touch(key)
        return page
    }

    /// Stores a page, then evicts the least recently used documents, and when one document alone
    /// is over the capacity, its other pages and finally this page too.
    mutating func store(_ page: PageText, index: Int, key: String) {
        let previous = pages[key]?[index]?.byteCount ?? 0
        pages[key, default: [:]][index] = page
        bytes += page.byteCount - previous
        touch(key)
        while bytes > capacity, order.count > 1 {
            let oldest = order.removeFirst()
            let removed = pages.removeValue(forKey: oldest)?.values.reduce(0) { $0 + $1.byteCount } ?? 0
            bytes -= removed
        }
        if bytes > capacity {
            shrink(key, keeping: index)
        }
    }

    private mutating func shrink(_ key: String, keeping index: Int) {
        guard var document = pages[key] else { return }
        for (pageIndex, page) in document where pageIndex != index && bytes > capacity {
            document[pageIndex] = nil
            bytes -= page.byteCount
        }
        if bytes > capacity, let kept = document.removeValue(forKey: index) {
            bytes -= kept.byteCount
        }
        if document.isEmpty {
            pages[key] = nil
            order.removeAll { $0 == key }
        } else {
            pages[key] = document
        }
    }

    private mutating func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

/// One open PDF. Reads page text through the library's cache, each page on a `PageWorker` thread.
///
/// It is used by one thread at a time: a command awaits each page before it asks for the next,
/// and stops using the document once a page is abandoned at the time limit.
final class OpenedDocument: @unchecked Sendable {
    /// PDFKit keeps every page it has read until its document is released, so pages are read from a
    /// fresh copy of the document after this many.
    static let pagesPerDocument = 10

    /// The virtual path, as the agent wrote it after resolving.
    let path: String
    /// The document for metadata and the outline.
    let document: PDFDocument
    let fileSize: Int
    private let data: Data
    private var pageDocument: PDFDocument
    private var pagesFromPageDocument = 0
    private let cacheKey: String?
    private let lease: DownloadCache.Lease
    private let library: PDFLibrary

    init(
        path: String,
        data: Data,
        document: PDFDocument,
        cacheKey: String?,
        fileSize: Int,
        lease: DownloadCache.Lease,
        library: PDFLibrary
    ) {
        self.path = path
        self.data = data
        self.document = document
        pageCount = document.pageCount
        pageDocument = document
        self.cacheKey = cacheKey
        self.fileSize = fileSize
        self.lease = lease
        self.library = library
    }

    /// Read once, because a page worker abandoned at the time limit may still be using `document`.
    let pageCount: Int

    func close() { lease.finish() }

    /// The text of the page at the 0-based `index`: recognized text when an earlier `--ocr` read
    /// it, otherwise its text layer. `nil` when reading it passed `deadline`.
    func text(ofPage index: Int, until deadline: ContinuousClock.Instant) async throws -> PageText? {
        if let cacheKey, let cached = library.cachedPage(index, key: cacheKey) { return cached }
        return try await PageWorker.run(until: deadline) { try self.extractText(ofPage: index) }
    }

    /// Recognizes the text of a page without a text layer from its image. `nil` when that passed `deadline`.
    func recognizeText(ofPage index: Int, until deadline: ContinuousClock.Instant) async throws -> PageText? {
        try await PageWorker.run(until: deadline) { try self.recognize(ofPage: index) }
    }

    private func extractText(ofPage index: Int) throws -> PageText {
        let page = try page(at: index)
        guard let pageReference = page.pageRef else {
            throw PDFCommandError.unreadablePage(path: path, page: index + 1)
        }
        let result: PageText
        if PageContent.fits(pageReference, limit: library.options.maxPageContentBytes) {
            let text = PageTextFormatter.normalize(page.string ?? "")
            result = PageText(text: text, source: text.isEmpty ? .missing : .textLayer)
        } else {
            result = PageText(text: "", source: .tooLarge)
        }
        if let cacheKey { library.store(result, index: index, key: cacheKey) }
        return result
    }

    private func recognize(ofPage index: Int) throws -> PageText {
        let page = try page(at: index)
        let raw = try PageRecognizer.recognize(page)
        let result = PageText(text: PageTextFormatter.normalize(raw), source: .recognized)
        if let cacheKey { library.store(result, index: index, key: cacheKey) }
        return result
    }

    private func page(at index: Int) throws -> PDFPage {
        if pagesFromPageDocument == Self.pagesPerDocument {
            guard let fresh = PDFDocument(data: data) else { throw PDFCommandError.notPDF(path) }
            pageDocument = fresh
            pagesFromPageDocument = 0
        }
        pagesFromPageDocument += 1
        guard let page = pageDocument.page(at: index) else {
            throw PDFCommandError.unreadablePage(path: path, page: index + 1)
        }
        return page
    }
}
