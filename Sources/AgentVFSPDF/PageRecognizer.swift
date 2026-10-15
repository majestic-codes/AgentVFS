//
//  PageRecognizer.swift
//  AgentVFSPDF
//
//  Created by Yevhenii Kalashnikov on 14.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import CoreGraphics
import Foundation
import PDFKit
import Vision

/// Reads the text of a scanned page from its image with the Vision framework.
enum PageRecognizer {
    /// The longer side of the rendered page in pixels: enough for small print, about 240 dpi on A4.
    private static let renderedSide: CGFloat = 2800

    static func recognize(_ page: PDFPage) throws -> String {
        // The rendered page is large, so it is released before the next page is rendered.
        try autoreleasepool { try recognizeInPool(page) }
    }

    private static func recognizeInPool(_ page: PDFPage) throws -> String {
        let image = try render(page)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw PDFCommandError.recognitionFailed(error.localizedDescription)
        }
        guard let observations = request.results else { return "" }
        return readingOrder(observations).joined(separator: "\n")
    }

    /// Lines top to bottom. Pieces at the same height, such as table cells, are joined left to right.
    private static func readingOrder(_ observations: [VNRecognizedTextObservation]) -> [String] {
        let pieces = observations.compactMap { observation -> (box: CGRect, text: String)? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return (observation.boundingBox, candidate.string)
        }
        var rows: [[(box: CGRect, text: String)]] = []
        // Vision measures from the bottom left, so higher text has a larger y.
        for piece in pieces.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let last = rows.last?.first, abs(last.box.midY - piece.box.midY) < last.box.height / 2 {
                rows[rows.count - 1].append(piece)
            } else {
                rows.append([piece])
            }
        }
        return rows.map { row in
            row.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ")
        }
    }

    private static func render(_ page: PDFPage) throws -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
        let turned = !page.rotation.isMultiple(of: 180)
        let size = turned ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        let scale = renderedSide / max(size.width, size.height, 1)
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw PDFCommandError.recognitionFailed("the page could not be rendered")
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else {
            throw PDFCommandError.recognitionFailed("the page could not be rendered")
        }
        return image
    }
}
