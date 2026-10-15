//
//  SearchTypes.swift
//  AgentVFS
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

/// How a search pattern is read.
public enum PatternSyntax: Sendable, Hashable {
    /// Literal text.
    case fixed
    /// POSIX basic regular expression, the default of `grep`.
    case basic
    /// POSIX extended regular expression (`grep -E`, `rg`).
    case extended
}

/// Where a search finds the files it reads.
public enum SearchStrategy: Sendable, Hashable {
    /// Read file contents through the drivers and match in memory. Complete within the limits.
    case virtual
    /// Let each source's own search index pick candidate files, then verify them in memory.
    /// Sources without an index are read in full. A pattern that is not a plain term an index can
    /// take (letters, digits and `_`, plus `.` for a fixed string) falls back to `virtual`, and
    /// `SearchPage.strategy` reports `virtual`.
    case remote
    /// `virtual`, switching to `remote` only when there are more files than `maxFiles`.
    case auto
}

/// What a content search matches and how far it may go.
public struct SearchOptions: Sendable, Hashable {
    /// How the pattern is read.
    public var syntax: PatternSyntax
    /// Match letters regardless of case.
    public var caseInsensitive: Bool
    /// Match only where the pattern is not part of a longer word.
    public var wholeWord: Bool
    /// Glob patterns a file name or path must match. Empty means every file.
    public var includeGlobs: [String]
    /// Glob patterns that remove files. A name or path match excludes the file.
    public var excludeGlobs: [String]
    /// Matches returned in all. The search stops once it has this many.
    public var maxMatches: Int
    /// Matches taken from one file, or `nil` for no limit per file.
    public var maxMatchesPerFile: Int?
    /// Files scanned. Files after the first `maxFiles` in walk order are left out.
    public var maxFiles: Int
    /// Largest file read through its driver. Larger files of a local source are scanned in place.
    public var maxFileBytes: Int
    /// Total file bytes a single search may download and scan.
    public var maxTotalBytes: Int
    /// How long the search may take, the walk and the matching together.
    public var timeout: Duration
    /// Where the search finds the files it reads.
    public var strategy: SearchStrategy

    /// Options with defaults that suit an agent's search through a repository.
    public init(
        syntax: PatternSyntax = .basic,
        caseInsensitive: Bool = false,
        wholeWord: Bool = false,
        includeGlobs: [String] = [],
        excludeGlobs: [String] = [],
        maxMatches: Int = 500,
        maxMatchesPerFile: Int? = nil,
        maxFiles: Int = 3000,
        maxFileBytes: Int = 512_000,
        maxTotalBytes: Int = 100_000_000,
        timeout: Duration = .seconds(15),
        strategy: SearchStrategy = .virtual
    ) {
        self.syntax = syntax
        self.caseInsensitive = caseInsensitive
        self.wholeWord = wholeWord
        self.includeGlobs = includeGlobs
        self.excludeGlobs = excludeGlobs
        self.maxMatches = maxMatches
        self.maxMatchesPerFile = maxMatchesPerFile
        self.maxFiles = maxFiles
        self.maxFileBytes = maxFileBytes
        self.maxTotalBytes = maxTotalBytes
        self.timeout = timeout
        self.strategy = strategy
    }

    /// Throws `VFSError.invalidConfiguration` unless the match and file limits are between 1 and
    /// `Int.max / 2`, the byte limits are not negative and the timeout is positive.
    public func validate() throws {
        var counts = [("maxMatches", maxMatches), ("maxFiles", maxFiles)]
        if let maxMatchesPerFile {
            counts.append(("maxMatchesPerFile", maxMatchesPerFile))
        }
        for (name, value) in counts where !(1...Self.maxCount).contains(value) {
            let message = "SearchOptions.\(name) must be between 1 and \(Self.maxCount), not \(value)"
            throw VFSError.invalidConfiguration(message)
        }
        for (name, value) in [("maxFileBytes", maxFileBytes), ("maxTotalBytes", maxTotalBytes)] where value < 0 {
            throw VFSError.invalidConfiguration("SearchOptions.\(name) must not be negative, not \(value)")
        }
        guard timeout > .zero else {
            throw VFSError.invalidConfiguration("SearchOptions.timeout must be positive, not \(timeout)")
        }
    }

    /// Largest value a count may have, so the count plus one still fits in an `Int`.
    static let maxCount = Int.max / 2
}

/// Why a search or listing did not cover everything it was asked to.
public enum TruncationReason: Sendable, Hashable {
    /// The search stopped at `SearchOptions.maxMatches`.
    case maxMatches(Int)
    /// Only the first `SearchOptions.maxFiles` files were scanned.
    case maxFiles(Int)
    /// The search stopped at `SearchOptions.maxTotalBytes`.
    case byteBudget(Int)
    /// The time limit ran out.
    case timeout
    /// The mount is too large to list in one go and the walk's listing budget ran out.
    case treeIncomplete(mount: String)
    /// A source's search index is partial or may be stale. Absence of a result proves nothing.
    case remoteIndexIncomplete
    /// A source's rate limit ran out.
    case rateLimited
    /// `find` stopped at its entry limit.
    case entryLimit(Int)
    /// The walk stopped after visiting `VFSLimits.maxWalkEntries` entries.
    case visitLimit(Int)

    /// The reason in a few words, for the agent.
    public var message: String {
        switch self {
        case let .maxMatches(limit):
            "stopped after \(limit) matches"
        case let .maxFiles(limit):
            "scanned only the first \(limit) files"
        case let .byteBudget(limit):
            "stopped after reading \(limit) bytes of file content"
        case .timeout:
            "time limit reached"
        case let .treeIncomplete(mount):
            "'\(mount)' is too large to list completely"
        case .remoteIndexIncomplete:
            "the source's search index is partial or may be stale"
        case .rateLimited:
            "rate limit reached"
        case let .entryLimit(limit):
            "stopped after \(limit) entries"
        case let .visitLimit(limit):
            "stopped after visiting \(limit) entries; search a smaller directory"
        }
    }
}

/// Why a search left a file out.
public enum SkipReason: Sendable, Hashable {
    /// The file is binary.
    case binary
    /// The file is larger than the search reads.
    case tooLarge(size: Int)
    /// The source could not deliver the file.
    case unreadable

    /// The reason in a few words, for the agent.
    public var message: String {
        switch self {
        case .binary: "binary file"
        case let .tooLarge(size): "larger than the size limit (\(size) bytes)"
        case .unreadable: "could not be read"
        }
    }
}

/// A file a search left out, and why.
public struct SkippedFile: Sendable, Hashable {
    /// Absolute virtual path.
    public let path: String
    /// Why the file was left out.
    public let reason: SkipReason

    /// A skipped file.
    public init(path: String, reason: SkipReason) {
        self.path = path
        self.reason = reason
    }
}

/// One matching line.
public struct SearchMatch: Sendable, Hashable {
    /// The mount the file belongs to.
    public let mount: String
    /// Absolute virtual path.
    public let path: String
    /// Path inside the mount.
    public let mountPath: String
    /// The 1-based line number.
    public let line: Int
    /// The line, cut to 1000 characters.
    public let text: String
    /// The mount's pinned version, if it has one.
    public let version: String?
    /// A citation link to the line, when the source has links.
    public let url: URL?

    /// A match.
    public init(mount: String, path: String, mountPath: String, line: Int, text: String, version: String?, url: URL?) {
        self.mount = mount
        self.path = path
        self.mountPath = mountPath
        self.line = line
        self.text = text
        self.version = version
        self.url = url
    }
}

/// The result of one search.
public struct SearchPage: Sendable, Equatable {
    /// The matching lines, in walk order.
    public var matches: [SearchMatch]
    /// `false` when anything may have been missed. Absence of matches then proves nothing.
    public var isComplete: Bool
    /// Why the search is incomplete, each reason once.
    public var truncation: [TruncationReason]
    /// Files whose contents were scanned.
    public var filesScanned: Int
    /// Number of skipped files. `skippedSample` lists only the first few.
    public var skippedCount: Int
    /// Skipped files that were too large.
    public var skippedTooLargeCount: Int
    /// Skipped files that could not be read.
    public var skippedUnreadableCount: Int
    /// The first few skipped files.
    public var skippedSample: [SkippedFile]
    /// Bytes of file content scanned.
    public var bytesScanned: Int
    /// The strategy the search actually used.
    public var strategy: SearchStrategy

    /// A page of search results.
    public init(
        matches: [SearchMatch] = [],
        isComplete: Bool = true,
        truncation: [TruncationReason] = [],
        filesScanned: Int = 0,
        skippedCount: Int = 0,
        skippedTooLargeCount: Int = 0,
        skippedUnreadableCount: Int = 0,
        skippedSample: [SkippedFile] = [],
        bytesScanned: Int = 0,
        strategy: SearchStrategy = .virtual
    ) {
        self.matches = matches
        self.isComplete = isComplete
        self.truncation = truncation
        self.filesScanned = filesScanned
        self.skippedCount = skippedCount
        self.skippedTooLargeCount = skippedTooLargeCount
        self.skippedUnreadableCount = skippedUnreadableCount
        self.skippedSample = skippedSample
        self.bytesScanned = bytesScanned
        self.strategy = strategy
    }
}

/// What `find` looks for.
public struct FindQuery: Sendable, Hashable {
    /// Glob matched against the entry name. `nil` matches everything.
    public var namePattern: String?
    /// Match `namePattern` regardless of case.
    public var caseInsensitive: Bool
    /// Entry kinds to return. Every kind by default.
    public var kinds: Set<EntryKind>
    /// Deepest level visited below the starting path, or `nil` for no limit.
    public var maxDepth: Int?
    /// Shallowest level returned. The starting path itself is level 0.
    public var minDepth: Int
    /// Entries returned.
    public var limit: Int
    /// How long the walk may take.
    public var timeout: Duration

    /// A query with every filter off by default.
    public init(
        namePattern: String? = nil,
        caseInsensitive: Bool = false,
        kinds: Set<EntryKind> = Set(EntryKind.allCases),
        maxDepth: Int? = nil,
        minDepth: Int = 0,
        limit: Int = 1000,
        timeout: Duration = .seconds(15)
    ) {
        self.namePattern = namePattern
        self.caseInsensitive = caseInsensitive
        self.kinds = kinds
        self.maxDepth = maxDepth
        self.minDepth = minDepth
        self.limit = limit
        self.timeout = timeout
    }

    /// Throws `VFSError.invalidConfiguration` for a negative depth or limit, or a timeout that is not positive.
    public func validate() throws {
        var counts = [("minDepth", minDepth), ("limit", limit)]
        if let maxDepth {
            counts.append(("maxDepth", maxDepth))
        }
        for (name, value) in counts where value < 0 {
            throw VFSError.invalidConfiguration("FindQuery.\(name) must not be negative, not \(value)")
        }
        guard timeout > .zero else {
            throw VFSError.invalidConfiguration("FindQuery.timeout must be positive, not \(timeout)")
        }
    }
}

/// The entries `find` returned.
public struct FindResult: Sendable, Equatable {
    /// The matching entries, in sorted pre-order.
    public var entries: [FileEntry]
    /// `false` when the walk stopped early, so entries may be missing.
    public var isComplete: Bool
    /// Why the walk stopped early.
    public var truncation: [TruncationReason]

    /// A result of `find`.
    public init(entries: [FileEntry] = [], isComplete: Bool = true, truncation: [TruncationReason] = []) {
        self.entries = entries
        self.isComplete = isComplete
        self.truncation = truncation
    }
}
