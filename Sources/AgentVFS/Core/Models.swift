//
//  Models.swift
//  AgentVFS
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

/// What an entry of a directory is.
public enum EntryKind: String, Sendable, Hashable, CaseIterable {
    /// A regular file.
    case file
    /// A directory.
    case directory
    /// A symbolic link, listed but never followed.
    case symbolicLink
    /// A nested repository whose contents are not part of the mount (a git submodule).
    case submodule
}

/// An entry returned by `list` and `find`.
public struct FileEntry: Hashable, Sendable {
    /// The last path component.
    public let name: String
    /// Absolute virtual path, e.g. `/workspace/ios/Sources/App.swift`.
    public let path: String
    /// What the entry is.
    public let kind: EntryKind
    /// The size in bytes, when the source reports it.
    public let size: Int?

    /// An entry.
    public init(name: String, path: String, kind: EntryKind, size: Int?) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
    }
}

/// The content of one file as a driver delivers it.
public enum FileContent: Sendable, Equatable {
    /// UTF-8 text whose bytes are exactly the file's bytes.
    case text(Data)
    /// The file is not UTF-8 (for example UTF-16) and the source returned it transcoded to UTF-8.
    /// Good for reading and searching. `MountDriver.readExactBytes` returns the original bytes.
    case transcodedText(Data, originalByteSize: Int)
    /// The file is binary, so its bytes are not delivered.
    case binary(byteSize: Int)
    /// Only a prefix was returned. `MountDriver.readExactBytes` returns the whole file.
    case truncated(byteSize: Int)

    /// Approximate memory cost for cache accounting.
    public var cost: Int {
        switch self {
        case let .text(data), let .transcodedText(data, _): data.count + 64
        case .binary, .truncated: 64
        }
    }

    /// Classifies raw bytes. UTF-8 without NUL bytes is text. UTF-16 and UTF-32 (with a byte order
    /// mark, or UTF-16 recognised by its zero bytes) and single-byte legacy text (Windows-1251 for
    /// Cyrillic, Windows-1252 otherwise) are transcoded to UTF-8. Anything else is binary.
    public static func classify(_ data: Data) -> Self {
        let head = data.prefix(8192)
        if !head.contains(0) {
            if String(validating: data, as: UTF8.self) != nil {
                return .text(data)
            }
            if let legacy = TextEncodingGuess.singleByte(data) {
                return transcoded(data, legacy)
            }
            return .binary(byteSize: data.count)
        }
        if let wide = TextEncodingGuess.wide(data) {
            return transcoded(data, wide)
        }
        return .binary(byteSize: data.count)
    }

    private static func transcoded(_ data: Data, _ encoding: String.Encoding) -> Self {
        guard let text = String(data: data, encoding: encoding) else { return .binary(byteSize: data.count) }
        // Decoders keep a byte order mark as U+FEFF. It marks the encoding and is not content.
        let content = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        return .transcodedText(Data(content.utf8), originalByteSize: data.count)
    }
}

/// Recognises text that is not UTF-8.
enum TextEncodingGuess {
    /// UTF-32 or UTF-16 by byte order mark, or UTF-16 without one when every other byte of
    /// mostly-ASCII text is zero.
    static func wide(_ data: Data) -> String.Encoding? {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return .utf32LittleEndian }
        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return .utf32BigEndian }
        if bytes.starts(with: [0xFF, 0xFE]) { return .utf16LittleEndian }
        if bytes.starts(with: [0xFE, 0xFF]) { return .utf16BigEndian }
        let sample = [UInt8](data.prefix(4096))
        guard sample.count >= 4, sample.count.isMultiple(of: 2), data.count.isMultiple(of: 2) else { return nil }
        let pairs = sample.count / 2
        var zeroOdd = 0
        var zeroEven = 0
        for index in stride(from: 0, to: sample.count, by: 2) {
            if sample[index] == 0 { zeroEven += 1 }
            if sample[index + 1] == 0 { zeroOdd += 1 }
        }
        // ASCII in UTF-16LE is "x\0x\0…"; real binary has zeros scattered on both sides.
        if zeroOdd * 10 >= pairs * 7, zeroEven * 20 <= pairs { return .utf16LittleEndian }
        if zeroEven * 10 >= pairs * 7, zeroOdd * 20 <= pairs { return .utf16BigEndian }
        return nil
    }

    /// Windows-1251 when most non-ASCII bytes are Cyrillic letters, Windows-1252 otherwise, as
    /// long as the text has no control characters that text files do not contain.
    static func singleByte(_ data: Data) -> String.Encoding? {
        var high = 0
        var cyrillicLetters = 0
        for byte in data.prefix(65_536) {
            switch byte {
            case 0x09, 0x0A, 0x0C, 0x0D: continue
            case 0x00..<0x20, 0x7F: return nil
            case 0x80...0xFF:
                high += 1
                if byte >= 0xC0 || byte == 0xA8 || byte == 0xB8 { cyrillicLetters += 1 }
            default: continue
            }
        }
        guard high > 0 else { return nil }
        // Cyrillic text is mostly letters from the C0–FF block. Western text uses accents sparingly
        // between ASCII letters, so the share alone cannot tell them apart. Count runs instead.
        return cyrillicLetters * 10 >= high * 9 && Self.hasLetterRuns(data) ? .windowsCP1251 : .windowsCP1252
    }

    /// Whether several high bytes stand next to each other, as letters of a non-Latin word do.
    private static func hasLetterRuns(_ data: Data) -> Bool {
        var run = 0
        for byte in data.prefix(65_536) {
            run = byte >= 0xC0 ? run + 1 : 0
            if run >= 3 { return true }
        }
        return false
    }
}

/// What a mount shows to people and to the agent.
public struct MountInfo: Sendable, Hashable {
    /// Short name of the kind of source, e.g. `GitHub`, `local`, `Jira`.
    public var kind: String
    /// What is mounted, e.g. `acme/ios-app` or `/Users/me/Projects/app`.
    public var source: String
    /// The version the mount is pinned to (a commit SHA, a snapshot id). `nil` for live sources.
    public var version: String?
    /// One line describing the mount, e.g. `acme/ios-app, main, commit 1a2b3c…`.
    public var summary: String
    /// How to cite a line, with `<path>` and `<line>` placeholders. `nil` when the source has no links.
    public var linkTemplate: String?

    /// A description of a mount. `summary` defaults to `source`.
    public init(
        kind: String,
        source: String,
        version: String? = nil,
        summary: String? = nil,
        linkTemplate: String? = nil
    ) {
        self.kind = kind
        self.source = source
        self.version = version
        self.summary = summary ?? source
        self.linkTemplate = linkTemplate
    }
}

/// The exact bytes of a file, as `WorkspaceFileSystem.readBinary` returns them.
public struct BinaryFile: Sendable, Equatable {
    /// Absolute virtual path.
    public let path: String
    /// The file's bytes.
    public let data: Data
    /// Identifies this content of this file, when the source versions its files. Two reads with
    /// the same version return the same bytes, so the value can key a cache.
    public let version: String?

    /// A file's bytes.
    public init(path: String, data: Data, version: String?) {
        self.path = path
        self.data = data
        self.version = version
    }
}

/// A text file together with where it was read from.
public struct TextFile: Sendable, Equatable {
    /// Absolute virtual path.
    public let path: String
    /// Path inside the mount, without a leading slash.
    public let mountPath: String
    /// The decoded text, without a byte order mark.
    public let text: String
    /// The mount the file belongs to.
    public let mount: String
    /// The mount's pinned version, if it has one.
    public let version: String?
    /// A citation link to the file, when the source has links.
    public let url: URL?

    /// A text file.
    public init(path: String, mountPath: String, text: String, mount: String, version: String?, url: URL?) {
        self.path = path
        self.mountPath = mountPath
        self.text = text
        self.mount = mount
        self.version = version
        self.url = url
    }
}

/// Resource limits applied to every operation.
public struct VFSLimits: Sendable, Hashable {
    /// Largest file `read` returns.
    public var maxReadBytes: Int
    /// Memory budget for cached file contents.
    public var contentCacheBytes: Int
    /// Number of search results kept in the cache.
    public var searchCacheEntries: Int
    /// Directory listings one walk may fetch from a driver whose listings are not cheap.
    public var maxListingsPerWalk: Int
    /// Largest file of a local source (a driver with cheap listings, such as a local directory or
    /// in-memory files) that line-oriented commands (`head`, `tail`, `sed -n`, `grep`, `rg`) read.
    /// Local files are memory-mapped and read line by line, so size costs time rather than memory.
    /// The default of 1 GB is about what a command reads within its time limit.
    public var maxLocalTextBytes: Int
    /// Entries one walk (`find`, a recursive search) visits before it stops.
    public var maxWalkEntries: Int
    /// Directory entries kept in the listing cache for mounts listed one directory at a time.
    /// Past it the cached directories of those mounts are dropped and listed again on use.
    public var maxCachedListingEntries: Int

    /// Limits that suit an agent working on a few repositories.
    public init(
        maxReadBytes: Int = 2_000_000,
        contentCacheBytes: Int = 64 * 1024 * 1024,
        searchCacheEntries: Int = 64,
        maxListingsPerWalk: Int = 200,
        maxLocalTextBytes: Int = 1_000_000_000,
        maxWalkEntries: Int = 500_000,
        maxCachedListingEntries: Int = 1_000_000
    ) {
        self.maxLocalTextBytes = maxLocalTextBytes
        self.maxReadBytes = maxReadBytes
        self.contentCacheBytes = contentCacheBytes
        self.searchCacheEntries = searchCacheEntries
        self.maxListingsPerWalk = maxListingsPerWalk
        self.maxWalkEntries = maxWalkEntries
        self.maxCachedListingEntries = maxCachedListingEntries
    }

    /// Throws `VFSError.invalidConfiguration` for a limit that is negative, or for a read or walk
    /// limit that is zero.
    public func validate() throws {
        let positive = [
            ("maxReadBytes", maxReadBytes), ("maxLocalTextBytes", maxLocalTextBytes), ("maxWalkEntries", maxWalkEntries)
        ]
        for (name, value) in positive where value <= 0 {
            throw VFSError.invalidConfiguration("VFSLimits.\(name) must be positive, not \(value)")
        }
        let counts = [
            ("contentCacheBytes", contentCacheBytes), ("searchCacheEntries", searchCacheEntries),
            ("maxListingsPerWalk", maxListingsPerWalk), ("maxCachedListingEntries", maxCachedListingEntries)
        ]
        for (name, value) in counts where value < 0 {
            throw VFSError.invalidConfiguration("VFSLimits.\(name) must not be negative, not \(value)")
        }
    }
}

/// Network traffic of a service behind one or more drivers.
public struct RequestStats: Sendable, Equatable {
    /// Requests by kind, e.g. `["REST": 12, "GraphQL": 3]`.
    public var requests: [String: Int]
    /// Requests sent again after a failure.
    public var retries: Int
    /// Requests refused by a rate limit.
    public var rateLimitErrors: Int
    /// Bytes of response bodies.
    public var bytesReceived: Int

    /// Traffic counts, zero by default.
    public init(requests: [String: Int] = [:], retries: Int = 0, rateLimitErrors: Int = 0, bytesReceived: Int = 0) {
        self.requests = requests
        self.retries = retries
        self.rateLimitErrors = rateLimitErrors
        self.bytesReceived = bytesReceived
    }

    /// Requests of every kind together.
    public var totalRequests: Int { requests.values.reduce(0, +) }

    /// Adds the counts of `other` to these.
    public mutating func add(_ other: Self) {
        requests.merge(other.requests, uniquingKeysWith: +)
        retries += other.retries
        rateLimitErrors += other.rateLimitErrors
        bytesReceived += other.bytesReceived
    }
}

/// Anything that can report its traffic, usually the API client shared by several drivers.
public protocol RequestStatsSource: Sendable {
    /// The traffic so far.
    func requestStats() async -> RequestStats
}

/// What a workspace did so far, as `WorkspaceFileSystem.metrics()` reports it.
public struct VFSMetrics: Sendable, Equatable {
    /// Directory listings served from the cache.
    public var listingCacheHits = 0
    /// Directory listings asked of drivers.
    public var listingFetches = 0
    /// File contents served from the cache.
    public var contentCacheHits = 0
    /// File contents asked of drivers.
    public var contentCacheMisses = 0
    /// Bytes held by the content cache.
    public var contentCacheBytes = 0
    /// Searches answered from the cache.
    public var searchCacheHits = 0
    /// Searches that ran.
    public var searchCacheMisses = 0
    /// Files read whole.
    public var filesRead = 0
    /// Files whose contents a search scanned.
    public var filesSearched = 0
    /// Traffic of the services behind the drivers.
    public var requests = RequestStats()

    /// Metrics that are all zero.
    public init() {}

    /// The share of content reads served from the cache, from 0 to 1.
    public var contentCacheHitRate: Double {
        let total = contentCacheHits + contentCacheMisses
        return total == 0 ? 0 : Double(contentCacheHits) / Double(total)
    }
}
