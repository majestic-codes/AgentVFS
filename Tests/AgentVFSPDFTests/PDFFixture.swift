//
//  PDFFixture.swift
//  AgentVFSPDFTests
//
//  Created by Yevhenii Kalashnikov on 14.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
@testable import AgentVFSPDF
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing

/// Builds PDF files for the tests with Core Graphics, the way real producers write them.
enum PDFFixture {
    /// A page of the fixture: text in a text layer, or text drawn as a picture like a scan.
    enum Page {
        case text(String)
        case scanned(String)
    }

    private static let mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)

    /// The bytes of a PDF with `pages` and an outline of `(title, 1-based page)` entries.
    static func make(
        _ pages: [Page],
        title: String? = nil,
        password: String? = nil,
        outline: [(title: String, page: Int)] = []
    ) throws -> Data {
        let data = try #require(CFDataCreateMutable(nil, 0))
        let consumer = try #require(CGDataConsumer(data: data))
        var box = mediaBox
        var info: [CFString: String] = [:]
        if let title { info[kCGPDFContextTitle] = title }
        if let password {
            info[kCGPDFContextUserPassword] = password
            info[kCGPDFContextOwnerPassword] = password
        }
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary))
        for page in pages {
            context.beginPDFPage(nil)
            switch page {
            case let .text(text):
                draw(text, in: context, size: 12)
            case let .scanned(text):
                let image = try picture(of: text)
                context.draw(image, in: mediaBox)
            }
            context.endPDFPage()
        }
        context.closePDF()
        let bytes = data as Data
        guard !outline.isEmpty else { return bytes }
        return try addOutline(outline, to: bytes)
    }

    private static func draw(_ text: String, in context: CGContext, size: CGFloat) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: mediaBox.insetBy(dx: 50, dy: 50), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
    }

    /// `text` rendered into a bitmap, so the page has no text layer.
    private static func picture(of text: String) throws -> CGImage {
        let scale: CGFloat = 2
        let context = try #require(CGContext(
            data: nil,
            width: Int(mediaBox.width * scale),
            height: Int(mediaBox.height * scale),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.scaleBy(x: scale, y: scale)
        draw(text, in: context, size: 28)
        return try #require(context.makeImage())
    }

    private static func addOutline(_ entries: [(title: String, page: Int)], to bytes: Data) throws -> Data {
        let document = try #require(PDFDocument(data: bytes))
        let root = PDFOutline()
        for (index, entry) in entries.enumerated() {
            let outlineEntry = PDFOutline()
            outlineEntry.label = entry.title
            let page = try #require(document.page(at: entry.page - 1))
            outlineEntry.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: mediaBox.height))
            root.insertChild(outlineEntry, at: index)
        }
        document.outlineRoot = root
        return try #require(document.dataRepresentation())
    }
}

/// A shell over one in-memory mount `docs` with the PDF commands.
func pdfShell(
    _ files: [String: Data],
    limits: OutputLimits = OutputLimits(),
    options: PDFOptions = PDFOptions()
) throws -> CommandInterpreter {
    // Recognition is slow on a busy machine, so tests allow far more time than an agent gets.
    var limits = limits
    limits.timeLimit = .seconds(120)
    var options = options
    options.timeout = .seconds(120)
    let driver = try InMemoryDriver(files: files)
    let mount = WorkspaceMount(name: "docs", driver: driver)
    let fileSystem = try WorkspaceFileSystem(mounts: [mount])
    return CommandInterpreter(fileSystem: fileSystem, limits: limits, commands: PDFTools.commands(options: options))
}
