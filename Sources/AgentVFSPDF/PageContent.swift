//
//  PageContent.swift
//  AgentVFSPDF
//
//  Created by Yevhenii Kalashnikov on 15.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import CoreGraphics

/// Measures the content streams a page draws, and the forms they draw, before PDFKit extracts
/// text from them: text extraction costs many times the decoded size in time and memory.
struct PageContent {
    /// The most bytes the page's content may decode to.
    let limit: Int
    private var decodedBytes = 0
    private var visited: Set<CGPDFStreamRef> = []

    /// Compressed streams over `limit / compressedShare` bytes are not decoded to be measured,
    /// because Flate can expand data about a thousand times. With the default limit, measuring
    /// one stream decodes at most about 128 MB.
    static let compressedShare = 32
    /// Forms drawn inside forms deeper than this are not followed.
    private static let maxFormDepth = 8
    /// Filters that only shrink data, so a stream filtered by them alone is no larger decoded.
    private static let shrinkingFilters: Set<String> = ["ASCIIHexDecode", "ASCII85Decode", "AHx", "A85"]

    private init(limit: Int) {
        self.limit = limit
    }

    /// Whether the content of `page` decodes to no more than `limit` bytes.
    static func fits(_ page: CGPDFPage, limit: Int) -> Bool {
        var content = Self(limit: limit)
        return content.add(page: page)
    }

    /// Counts the page's content streams and forms. Returns `false` once they pass the limit.
    private mutating func add(page: CGPDFPage) -> Bool {
        guard let dictionary = page.dictionary else { return true }
        var contents: CGPDFObjectRef?
        if CGPDFDictionaryGetObject(dictionary, "Contents", &contents), let contents {
            guard add(contents: contents) else { return false }
        }
        guard let resources = Self.resources(of: dictionary) else { return true }
        return add(formsIn: resources, depth: 0)
    }

    /// A page's resources, which it may inherit from the page tree above it.
    private static func resources(of page: CGPDFDictionaryRef) -> CGPDFDictionaryRef? {
        var node: CGPDFDictionaryRef? = page
        var depth = 0
        while let current = node, depth < 32 {
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(current, "Resources", &resources) { return resources }
            var parent: CGPDFDictionaryRef?
            node = CGPDFDictionaryGetDictionary(current, "Parent", &parent) ? parent : nil
            depth += 1
        }
        return nil
    }

    /// `Contents` is one stream or an array of streams.
    private mutating func add(contents: CGPDFObjectRef) -> Bool {
        var stream: CGPDFStreamRef?
        if CGPDFObjectGetValue(contents, .stream, &stream), let stream {
            return add(stream: stream)
        }
        var array: CGPDFArrayRef?
        guard CGPDFObjectGetValue(contents, .array, &array), let array else { return true }
        for index in 0..<CGPDFArrayGetCount(array) {
            var element: CGPDFStreamRef?
            guard CGPDFArrayGetStream(array, index, &element), let element else { continue }
            guard add(stream: element) else { return false }
        }
        return true
    }

    private mutating func add(formsIn resources: CGPDFDictionaryRef, depth: Int) -> Bool {
        guard depth < Self.maxFormDepth else { return true }
        var objects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { return true }
        var forms: [CGPDFStreamRef] = []
        let collect: CGPDFDictionaryApplierBlock = { _, object, _ in
            var stream: CGPDFStreamRef?
            if CGPDFObjectGetValue(object, .stream, &stream), let stream, Self.isForm(stream) {
                forms.append(stream)
            }
            return true
        }
        CGPDFDictionaryApplyBlock(objects, collect, nil)
        for form in forms where !visited.contains(form) {
            guard add(stream: form) else { return false }
            var formResources: CGPDFDictionaryRef?
            guard let dictionary = CGPDFStreamGetDictionary(form),
                  CGPDFDictionaryGetDictionary(dictionary, "Resources", &formResources),
                  let formResources
            else { continue }
            guard add(formsIn: formResources, depth: depth + 1) else { return false }
        }
        return true
    }

    private static func isForm(_ stream: CGPDFStreamRef) -> Bool {
        var subtype: UnsafePointer<CChar>?
        guard let dictionary = CGPDFStreamGetDictionary(stream),
              CGPDFDictionaryGetName(dictionary, "Subtype", &subtype),
              let subtype
        else { return false }
        return String(cString: subtype) == "Form"
    }

    /// Adds one stream's decoded size, decoding it only when that is cheap enough.
    private mutating func add(stream: CGPDFStreamRef) -> Bool {
        guard visited.insert(stream).inserted else { return true }
        guard let dictionary = CGPDFStreamGetDictionary(stream) else { return false }
        var length: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dictionary, "Length", &length), length >= 0 else { return false }
        let filters = Self.filters(of: dictionary)
        let expanding = filters.filter { !Self.shrinkingFilters.contains($0) }
        if expanding.isEmpty {
            return add(decoded: length)
        }
        guard expanding.count == 1, length <= limit / Self.compressedShare else { return false }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) else { return false }
        return add(decoded: CFDataGetLength(data))
    }

    /// Counts decoded bytes. False once they are over the limit, checked before adding so a
    /// forged `Length` cannot overflow the count.
    private mutating func add(decoded length: Int) -> Bool {
        guard length <= limit - decodedBytes else { return false }
        decodedBytes += length
        return true
    }

    /// The names in a stream's `Filter`, which is one name or an array of names.
    private static func filters(of dictionary: CGPDFDictionaryRef) -> [String] {
        var name: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(dictionary, "Filter", &name), let name {
            return [String(cString: name)]
        }
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Filter", &array), let array else { return [] }
        return (0..<CGPDFArrayGetCount(array)).map { index in
            var element: UnsafePointer<CChar>?
            guard CGPDFArrayGetName(array, index, &element), let element else { return "unknown" }
            return String(cString: element)
        }
    }
}
