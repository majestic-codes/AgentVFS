//
//  PDFBoundTests.swift
//  AgentVFSPDFTests
//
//  Created by Yevhenii Kalashnikov on 15.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
@testable import AgentVFSPDF
import Foundation
import PDFKit
import Testing

/// A page filled with text, so its content streams are large.
private let densePage = PDFFixture.Page.text(String(repeating: "dense words fill the page ", count: 400))

@Suite("PDF time and memory bounds")
struct PDFBoundTests {
    @Test("a page whose content is over the limit is refused, and the other pages are still read")
    func pageContentLimit() async throws {
        let document = try PDFFixture.make([.text("small first page"), densePage])
        let shell = try pdfShell(["dense.pdf": document], options: PDFOptions(maxPageContentBytes: 30_000))
        let output = await shell.run("pdftotext docs/dense.pdf").output
        #expect(output.hasPrefix("--- page 1 of 2 ---\nsmall first page\n"))
        #expect(output.contains("--- page 2 of 2: its content is over the limit of 30000 bytes for text extraction"))
        #expect(output.contains("dense words") == false)
        let search = await shell.run("pdfgrep dense docs/dense.pdf")
        #expect(search.exitCode == 1)
        let note = "[/workspace/docs/dense.pdf: not searched, the content of pages 2 is too large to extract text from]"
        #expect(search.output == note)
        #expect(await shell.run("pdfinfo docs/dense.pdf").output.contains("Pages too large to extract text from: 2"))

        let roomy = try pdfShell(["dense.pdf": document])
        #expect(await roomy.run("pdftotext -f 2 docs/dense.pdf").output.contains("dense words"))
    }

    @Test("a content stream with a forged length is refused instead of overflowing the count")
    func forgedStreamLength() async throws {
        let content = "BT /F1 12 Tf 72 712 Td (Hello) Tj ET"
        let document = HandWrittenPDF.make(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents [4 0 R 5 0 R] "
                + "/Resources << /Font << /F1 6 0 R >> >> >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Length \(Int.max) >>\nstream\n\(content)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        ])
        let shell = try pdfShell(["forged.pdf": document])
        let output = await shell.run("pdftotext docs/forged.pdf").output
        #expect(output.contains("its content is over the limit"))
    }

    @Test("pages past a fresh copy of the document still give their own text")
    func freshDocumentCopies() async throws {
        let pageCount = OpenedDocument.pagesPerDocument * 2 + 5
        let pages = (1...pageCount).map { PDFFixture.Page.text("marker-\($0)-end") }
        let document = try PDFFixture.make(pages)
        let shell = try pdfShell(["long.pdf": document])
        let output = await shell.run("pdfgrep -c marker docs/long.pdf").output
        #expect(output == "\(pageCount)")
        let last = await shell.run("pdfgrep marker-\(pageCount)-end docs/long.pdf").output
        #expect(last == "\(pageCount): marker-\(pageCount)-end")
    }

    @Test("work that passes the deadline is abandoned instead of waited for")
    func abandonedWork() async throws {
        let started = ContinuousClock.now
        let result = try await PageWorker.run(until: .now + .milliseconds(100)) {
            Thread.sleep(forTimeInterval: 10)
            return 1
        }
        #expect(result == nil)
        #expect(ContinuousClock.now - started < .seconds(8))
        let finished = try await PageWorker.run(until: .now + .seconds(5)) { 7 }
        #expect(finished == 7)
    }

    @Test("cancelling the task stops waiting for the work at once")
    func cancelledWork() async throws {
        let started = ContinuousClock.now
        let task = Task {
            try await PageWorker.run(until: .now + .seconds(30)) {
                Thread.sleep(forTimeInterval: 10)
                return 1
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(9))
    }

    @Test("the text cache stays within its capacity even for a single document")
    func textCacheCapacity() {
        var cache = TextCache(capacity: 100)
        let page = PageText(text: String(repeating: "a", count: 40), source: .textLayer)
        for index in 0..<10 {
            cache.store(page, index: index, key: "one")
        }
        #expect(cache.bytes <= 100)
        #expect(cache.page(9, key: "one") != nil)
        cache.store(PageText(text: String(repeating: "b", count: 150), source: .textLayer), index: 0, key: "two")
        #expect(cache.bytes == 0)
        #expect(cache.page(0, key: "two") == nil)
    }

    @Test("an outline entry pointing at a page of another document has no page number")
    func foreignOutlinePage() throws {
        let documentData = try PDFFixture.make([.text("one")])
        let otherData = try PDFFixture.make([.text("two")])
        let document = try #require(PDFDocument(data: documentData))
        let other = try #require(PDFDocument(data: otherData))
        let root = PDFOutline()
        let entry = PDFOutline()
        entry.label = "Elsewhere"
        let foreignPage = try #require(other.page(at: 0))
        entry.destination = PDFDestination(page: foreignPage, at: .zero)
        root.insertChild(entry, at: 0)
        document.outlineRoot = root
        #expect(PDFInfoCommand.outline(of: document) == ["Outline:", "  Elsewhere"])
    }

    @Test("pdfgrep stops printing matches once the output budget is spent")
    func grepOutputBudget() async throws {
        let line = "needle " + String(repeating: "x", count: 60)
        let page = PDFFixture.Page.text(Array(repeating: line, count: 40).joined(separator: "\n"))
        let document = try PDFFixture.make([page])
        let shell = try pdfShell(["wide.pdf": document], limits: OutputLimits(maxBytes: 3000))
        let result = await shell.run("pdfgrep needle docs/wide.pdf")
        #expect(result.truncated == false)
        #expect(result.output.contains("more matches not shown, on pages 1"))
        #expect(result.output.utf8.count <= 3000)
    }

    @Test("a PDF on the local disk is read within the size limit")
    func localSizeLimit() async throws {
        let directoryName = "AgentVFSPDFTests-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(directoryName)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { removeDirectory(root) }
        try PDFFixture.make([.text("local")]).write(to: root.appendingPathComponent("local.pdf"))
        let mount = WorkspaceMount(name: "local", driver: try LocalDirectoryDriver(root: root))
        let fileSystem = try WorkspaceFileSystem(mounts: [mount])
        let small = PDFTools.commands(options: PDFOptions(maxDownloadBytes: 100))
        let refused = await CommandInterpreter(fileSystem: fileSystem, commands: small).run("pdfinfo local/local.pdf")
        #expect(refused.exitCode == 2)
        #expect(refused.output.contains("too large"))
        let shell = CommandInterpreter(fileSystem: fileSystem, commands: PDFTools.all)
        #expect(await shell.run("pdftotext local/local.pdf").output == "--- page 1 of 1 ---\nlocal")
    }

    private func removeDirectory(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Issue.record("could not remove \(url.path): \(error)")
        }
    }
}

@Suite("PDF command suggestions")
struct PDFSuggestionTests {
    @Test("paths are quoted for the shell", arguments: [
        ("/workspace/docs/report.pdf", "/workspace/docs/report.pdf"),
        ("/workspace/docs/my report.pdf", "'/workspace/docs/my report.pdf'"),
        ("/workspace/docs/it's.pdf", #"'/workspace/docs/it'\''s.pdf'"#),
        ("", "''")
    ])
    func quoting(path: String, quoted: String) {
        #expect(ShellQuoting.quoted(path) == quoted)
    }

    @Test("a suggested command for a path with spaces runs as shown")
    func suggestionRuns() async throws {
        let document = try report()
        let shell = try pdfShell(["my report.pdf": document])
        let hint = await shell.run("pdftotext -f 4 'docs/my report.pdf'").output
        let suggestion = "pdftotext --ocr -f 4 -l 4 '/workspace/docs/my report.pdf'"
        #expect(hint.contains(suggestion))
        let recognized = await shell.run(suggestion).output
        #expect(recognized.contains("INVOICE 4711"))
    }

    @Test("a recognized page longer than the output limit is cut, not printed empty")
    func recognizedPageCut() async throws {
        let document = try report()
        let shell = try pdfShell(["report.pdf": document], limits: OutputLimits(maxBytes: 480))
        let output = await shell.run("pdftotext --ocr -f 4 -l 4 docs/report.pdf").output
        #expect(output.hasPrefix("--- page 4 of 4, recognized from the image, may contain errors ---\nINVOICE 4711\n"))
        #expect(output.contains("page 4 is longer than the output limit and was cut"))
    }

    @Test("-ocr with one dash recognizes scanned pages like --ocr")
    func singleDashRecognition() async throws {
        let document = try report()
        let shell = try pdfShell(["report.pdf": document])
        #expect(await shell.run("pdftotext -ocr -f 4 -l 4 docs/report.pdf").output.contains("INVOICE 4711"))
    }
}

/// A PDF written object by object, for structures that drawing APIs never produce.
private enum HandWrittenPDF {
    static func make(objects: [String]) -> Data {
        var text = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(text.utf8.count)
            text += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let crossReference = text.utf8.count
        text += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            let padded = String(repeating: "0", count: 10 - String(offset).count) + String(offset)
            text += "\(padded) 00000 n \n"
        }
        text += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(crossReference)\n%%EOF\n"
        return Data(text.utf8)
    }
}
