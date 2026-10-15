//
//  PDFCommandTests.swift
//  AgentVFSPDFTests
//
//  Created by Yevhenii Kalashnikov on 14.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
@testable import AgentVFSPDF
import Foundation
import Testing

/// Pages with a text layer only: an introduction, results, and conclusions in Ukrainian.
private let textPages: [PDFFixture.Page] = [
    .text("Annual report\n\nIntroduction to the year."),
    .text("Results\n\nRevenue grew   to 4.2 million.\n\n\n\nCosts stayed flat."),
    .text("Висновки\n\nРахунок 4711 сплачено.")
]

/// A report: an introduction, a results chapter in Ukrainian, an appendix with a scanned page.
func report() throws -> Data {
    try PDFFixture.make(
        textPages + [.scanned("INVOICE 4711")],
        title: "Annual report 2025",
        outline: [("Introduction", 1), ("Results", 2), ("Conclusions", 3), ("Appendix", 4)]
    )
}

@Suite("pdfinfo")
struct PDFInfoTests {
    @Test("shows pages, metadata, text size, scanned pages and the outline")
    func summary() async throws {
        let document = try report()
        let shell = try pdfShell(["report.pdf": document])
        let result = await shell.run("pdfinfo docs/report.pdf")
        #expect(result.exitCode == 0)
        let output = result.output
        #expect(output.contains("File: /workspace/docs/report.pdf"))
        #expect(output.contains("Pages: 4"))
        #expect(output.contains("Title: Annual report 2025"))
        #expect(output.contains("Text: 125 characters, ~32 tokens"))
        #expect(output.contains("Pages without a text layer (scanned?): 4; read them with pdftotext --ocr -f N -l N"))
        let outline = "Outline:\n  Introduction — p. 1\n  Results — p. 2\n  Conclusions — p. 3\n  Appendix — p. 4"
        #expect(output.contains(outline))
    }

    @Test("reports files that are not PDFs and PDFs with a password")
    func refusals() async throws {
        let locked = try PDFFixture.make([.text("secret")], password: "pass")
        let shell = try pdfShell(["notes.pdf": Data("just text".utf8), "locked.pdf": locked])
        let notPDF = await shell.run("pdfinfo docs/notes.pdf")
        #expect(notPDF.exitCode == 2)
        #expect(notPDF.output == "pdfinfo: /workspace/docs/notes.pdf: not a PDF file")
        let encrypted = await shell.run("pdfinfo docs/locked.pdf")
        #expect(encrypted.output == "pdfinfo: /workspace/docs/locked.pdf: the PDF is protected with a password")
        #expect(await shell.run("pdfinfo docs/missing.pdf").exitCode == 2)
    }
}

@Suite("pdftotext")
struct PDFToTextTests {
    @Test("prints a page range with page markers and collapsed whitespace")
    func range() async throws {
        let document = try report()
        let shell = try pdfShell(["report.pdf": document])
        let output = await shell.run("pdftotext -f 2 -l 3 docs/report.pdf -").output
        let expected = """
            --- page 2 of 4 ---
            Results
            Revenue grew to 4.2 million.
            Costs stayed flat.

            --- page 3 of 4 ---
            Висновки
            Рахунок 4711 сплачено.
            """
        #expect(output == expected)
    }

    @Test("points a scanned page to --ocr instead of printing nothing")
    func scannedPage() async throws {
        let document = try report()
        let shell = try pdfShell(["report.pdf": document])
        let output = await shell.run("pdftotext -f 4 docs/report.pdf").output
        let hint = "--- page 4 of 4: no text layer (a scanned image?); "
            + "read it with pdftotext --ocr -f 4 -l 4 /workspace/docs/report.pdf ---"
        #expect(output == hint)
    }

    @Test("reads a scanned page with --ocr, and pdfgrep then finds its text")
    func recognition() async throws {
        let document = try report()
        let shell = try pdfShell(["report.pdf": document])
        let output = await shell.run("pdftotext --ocr -f 4 -l 4 docs/report.pdf").output
        #expect(output.contains("--- page 4 of 4, recognized from the image, may contain errors ---"))
        #expect(output.contains("INVOICE 4711"))
        let search = await shell.run("pdfgrep INVOICE docs/report.pdf").output
        #expect(search == "4: INVOICE 4711")
    }

    @Test("stops at a page boundary at the output limit and says how to continue")
    func outputLimit() async throws {
        let pages = (1...30).map { PDFFixture.Page.text("Page \($0)\n" + String(repeating: "word ", count: 120)) }
        let document = try PDFFixture.make(pages)
        let shell = try pdfShell(["long.pdf": document], limits: OutputLimits(maxBytes: 3000))
        let output = await shell.run("pdftotext -f 3 -l 30 docs/long.pdf").output
        #expect(output.hasPrefix("--- page 3 of 30 ---\nPage 3\n"))
        #expect(output.contains("--- page 7 of 30 ---") == false)
        #expect(output.hasSuffix("[pages 3–6 of 30 shown, stopped at the output limit; "
            + "continue with: pdftotext -f 7 -l 30 /workspace/docs/long.pdf]"))
    }

    @Test("without a range, shows the first pages of a long document and where to look next")
    func noRange() async throws {
        let pages = (1...30).map { PDFFixture.Page.text("Page \($0)\n" + String(repeating: "word ", count: 120)) }
        let document = try PDFFixture.make(pages)
        let shell = try pdfShell(["long.pdf": document], limits: OutputLimits(maxBytes: 3000))
        let output = await shell.run("pdftotext docs/long.pdf").output
        #expect(output.contains("--- page 2 of 30 ---"))
        #expect(output.contains("--- page 3 of 30 ---") == false)
        #expect(output.contains("[pages 1–2 of 30 shown; the whole document does not fit."))
        #expect(output.contains("pdfgrep PATTERN /workspace/docs/long.pdf"))

        let shortDocument = try PDFFixture.make([.text("one"), .text("two")])
        let short = try pdfShell(["short.pdf": shortDocument])
        let whole = "--- page 1 of 2 ---\none\n\n--- page 2 of 2 ---\ntwo"
        #expect(await short.run("pdftotext docs/short.pdf").output == whole)
    }

    @Test(
        "refuses what it cannot do",
        arguments: [
            ("pdftotext docs/report.pdf out.txt", "writing files is not available"),
            ("pdftotext -layout docs/report.pdf", "layout mode is not available"),
            ("pdftotext -f 9 docs/report.pdf", "page 9 is past the last page (4)"),
            ("pdftotext -f 3 -l 2 docs/report.pdf", "the first page 3 comes after the last page 2"),
            ("pdftotext -f 0 docs/report.pdf", "-f takes a page number from 1")
        ]
    )
    func refusals(command: String, message: String) async throws {
        let document = try report()
        let shell = try pdfShell(["report.pdf": document])
        let result = await shell.run(command)
        #expect(result.exitCode == 2)
        #expect(result.output.contains(message))
    }

    @Test("accepts poppler options that change nothing here")
    func ignoredOptions() async throws {
        let document = try report()
        let shell = try pdfShell(["report.pdf": document])
        let result = await shell.run("pdftotext -q -nopgbrk -enc UTF-8 -f 1 -l 1 docs/report.pdf -")
        #expect(result.output == "--- page 1 of 4 ---\nAnnual report\nIntroduction to the year.")
    }
}

@Suite("PDF files on the local disk")
struct LocalPDFTests {
    @Test("opens a PDF in a local directory in place")
    func localDirectory() async throws {
        let directoryName = "AgentVFSPDFTests-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(directoryName)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { removeDirectory(root) }
        try PDFFixture.make(textPages).write(to: root.appendingPathComponent("report.pdf"))
        let mount = WorkspaceMount(name: "local", driver: try LocalDirectoryDriver(root: root))
        let fileSystem = try WorkspaceFileSystem(mounts: [mount])
        let shell = CommandInterpreter(fileSystem: fileSystem, commands: PDFTools.all)
        #expect(await shell.run("pdfgrep -i висновки local/report.pdf").output == "3: Висновки")
        #expect(await shell.run("pdfinfo local/report.pdf").output.contains("Pages: 3"))
    }

    private func removeDirectory(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Issue.record("could not remove \(url.path): \(error)")
        }
    }
}

@Suite("pdfgrep")
struct PDFGrepTests {
    @Test("prints matching lines with page numbers, in any script and case")
    func matches() async throws {
        let document = try PDFFixture.make(textPages)
        let shell = try pdfShell(["report.pdf": document])
        #expect(await shell.run("pdfgrep 4711 docs/report.pdf").output == "3: Рахунок 4711 сплачено.")
        #expect(await shell.run("pdfgrep -i рахунок docs/report.pdf").output == "3: Рахунок 4711 сплачено.")
        #expect(await shell.run("pdfgrep -i 'revenue|costs' docs/report.pdf").output
            == "2: Revenue grew to 4.2 million.\n2: Costs stayed flat.")
        #expect(await shell.run("pdfgrep -c -i results docs/report.pdf").output == "1")
        #expect(await shell.run("pdfgrep nothing-here docs/report.pdf").exitCode == 1)
    }

    @Test("says which pages could not be searched because they have no text layer")
    func scannedPages() async throws {
        let document = try report()
        let shell = try pdfShell(["report.pdf": document])
        let output = await shell.run("pdfgrep 4711 docs/report.pdf").output
        #expect(output == """
            3: Рахунок 4711 сплачено.
            [/workspace/docs/report.pdf: not searched, no text layer on pages 4; \
            read them with: pdftotext --ocr -f N -l N /workspace/docs/report.pdf]
            """)
    }

    @Test("shows context lines and limits the search to a page range")
    func contextAndRange() async throws {
        let document = try PDFFixture.make(textPages)
        let shell = try pdfShell(["report.pdf": document])
        #expect(await shell.run("pdfgrep -B 1 Revenue docs/report.pdf").output
            == "2- Results\n2: Revenue grew to 4.2 million.")
        #expect(await shell.run("pdfgrep --page-range=1-2 4711 docs/report.pdf").exitCode == 1)
        #expect(await shell.run("pdfgrep --page-range=3 4711 docs/report.pdf").output == "3: Рахунок 4711 сплачено.")
    }

    @Test("searches every PDF in a directory with -r and names the files")
    func recursive() async throws {
        let other = try PDFFixture.make([.text("Rechnung 4711")])
        let notes = Data("4711".utf8)
        let document = try report()
        let shell = try pdfShell(["report.pdf": document, "archive/old.pdf": other, "archive/notes.txt": notes])
        let output = await shell.run("pdfgrep -r 4711 docs").output
        #expect(output.contains("/workspace/docs/archive/old.pdf:1: Rechnung 4711"))
        #expect(output.contains("/workspace/docs/report.pdf:3: Рахунок 4711 сплачено."))
        #expect(output.contains("notes.txt") == false)
        #expect(await shell.run("pdfgrep -l -r 4711 docs").output.contains("/workspace/docs/archive/old.pdf"))
        #expect(await shell.run("pdfgrep 4711 docs").output.contains("is a directory; search the PDFs in it with -r"))
    }

    @Test("counts matches past the first few dozen instead of printing them")
    func manyMatches() async throws {
        let pageText = (1...8).map { "line \($0) total" }.joined(separator: "\n")
        let pages = Array(repeating: PDFFixture.Page.text(pageText), count: 10)
        let document = try PDFFixture.make(pages)
        let shell = try pdfShell(["ledger.pdf": document])
        let output = await shell.run("pdfgrep total docs/ledger.pdf").output
        #expect(output.split(separator: "\n").count == 41)
        #expect(output.hasSuffix("[/workspace/docs/ledger.pdf: 40 more matches not shown, on pages 6–10; "
            + "narrow the pattern or add --page-range]"))
    }

    @Test("cuts long lines around the match")
    func longLine() {
        let line = String(repeating: "a", count: 500) + "NEEDLE" + String(repeating: "b", count: 500)
        let range = line.range(of: "NEEDLE")
        let clipped = GrepSearch.clip(line, around: range)
        #expect(clipped.count <= 242)
        #expect(clipped.contains("NEEDLE"))
        #expect(clipped.hasPrefix("…"))
        #expect(clipped.hasSuffix("…"))
    }
}
