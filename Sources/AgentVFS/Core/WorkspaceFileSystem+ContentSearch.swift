//
//  WorkspaceFileSystem+ContentSearch.swift
//  AgentVFS
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

struct Candidate {
    let mount: WorkspaceMount
    let path: VFSPath
    let ref: EntryRef
    let size: Int
    /// Over `SearchOptions.maxFileBytes` but in a local source: scanned line by line from the
    /// file itself instead of being loaded and cached.
    var large = false
}

let binaryExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "ico", "icns", "bmp", "tif", "tiff", "psd", "ai",
    "pdf", "zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "jar", "aar", "war", "apk", "ipa", "dmg",
    "class", "o", "a", "dylib", "so", "dll", "exe", "bin", "dex", "pyc", "car", "nib", "mlmodel", "mlmodelc",
    "ttf", "otf", "woff", "woff2", "eot", "mp3", "mp4", "m4a", "m4v", "mov", "wav", "aac", "avi", "mkv", "ogg",
    "sqlite", "db", "ds_store"
]

private struct SkipLog {
    static let sampleLimit = 20
    private(set) var count = 0
    private(set) var tooLargeCount = 0
    private(set) var unreadableCount = 0
    private(set) var sample: [SkippedFile] = []

    mutating func add(_ path: VFSPath, _ reason: SkipReason) {
        count += 1
        switch reason {
        case .binary: break
        case .tooLarge: tooLargeCount += 1
        case .unreadable: unreadableCount += 1
        }
        if sample.count < Self.sampleLimit {
            sample.append(SkippedFile(path: path.description, reason: reason))
        }
    }
}

/// The state of one search while it runs: what it found, skipped and why it may be incomplete.
private struct SearchRun {
    let options: SearchOptions
    let deadline: ContinuousClock.Instant
    var reasons: [TruncationReason] = []
    var skipLog = SkipLog()
    var matches: [SearchMatch] = []
    var filesScanned = 0
    var bytesScanned = 0

    /// How many matches one more file may add: one more than the total limit allows, so going over
    /// it is noticed. `SearchOptions.validate` keeps `maxMatches + 1` within `Int`.
    var perFileLimit: Int {
        min(options.maxMatchesPerFile ?? Int.max, options.maxMatches + 1 - matches.count)
    }

    /// Keeps the files that fit the file limit and the byte budget. Large local files are scanned in
    /// place and do not count against the budget.
    mutating func budget(_ candidates: [Candidate]) -> [Candidate] {
        var kept = candidates
        if kept.count > options.maxFiles {
            kept = Array(kept.prefix(options.maxFiles))
            reasons.append(.maxFiles(options.maxFiles))
        }
        var eligible: [Candidate] = []
        var plannedBytes = 0
        for candidate in kept {
            if candidate.large {
                eligible.append(candidate)
                continue
            }
            if candidate.size > options.maxTotalBytes - plannedBytes {
                reasons.append(.byteBudget(options.maxTotalBytes))
                break
            }
            plannedBytes += candidate.size
            eligible.append(candidate)
        }
        return eligible
    }

    /// Adds the hits of one file.
    mutating func record(_ hits: [(line: Int, text: String)], in candidate: Candidate) {
        for hit in hits {
            let match = SearchMatch(
                mount: candidate.mount.name,
                path: candidate.path.description,
                mountPath: candidate.ref.path,
                line: hit.line,
                text: hit.text,
                version: candidate.mount.info.version,
                url: candidate.mount.driver.link(to: candidate.ref.path, line: hit.line)
            )
            matches.append(match)
        }
    }

    /// Cuts the matches down to the limit when they went over it. Returns `true` when they did and the
    /// search stops.
    mutating func reachedMatchLimit() -> Bool {
        guard matches.count > options.maxMatches else { return false }
        matches.removeLast(matches.count - options.maxMatches)
        reasons.append(.maxMatches(options.maxMatches))
        return true
    }

    func page(strategy: SearchStrategy) -> SearchPage {
        var uniqueReasons: [TruncationReason] = []
        for reason in reasons where !uniqueReasons.contains(reason) {
            uniqueReasons.append(reason)
        }
        return SearchPage(
            matches: matches,
            isComplete: uniqueReasons.isEmpty,
            truncation: uniqueReasons,
            filesScanned: filesScanned,
            skippedCount: skipLog.count,
            skippedTooLargeCount: skipLog.tooLargeCount,
            skippedUnreadableCount: skipLog.unreadableCount,
            skippedSample: skipLog.sample,
            bytesScanned: bytesScanned,
            strategy: strategy
        )
    }
}

extension WorkspaceFileSystem {
    // MARK: Search

    /// Searches the contents of the text files below `path`, line by line. Results are cached until a
    /// mount changes, except for searches cut short by a timeout or a rate limit. Throws
    /// `VFSError.invalidPattern` for a pattern or glob that does not compile and
    /// `VFSError.invalidConfiguration` for options that `SearchOptions.validate` refuses.
    ///
    /// With `SearchStrategy.remote`, a pattern that a source's index cannot take as a plain term
    /// is searched as with `.virtual`, and the page's `strategy` says so.
    public func search(pattern: String, path: String, options: SearchOptions) async throws -> SearchPage {
        try options.validate()
        let compiled = try PatternCompiler.compile(
            pattern,
            syntax: options.syntax,
            caseInsensitive: options.caseInsensitive,
            wholeWord: options.wholeWord,
            timeLimit: options.timeout
        )
        let filter = try CandidateFilter(options: options, maxLocalTextBytes: limits.maxLocalTextBytes)
        let virtualPath = try VFSPath(normalizing: path, relativeTo: .root)
        let key = SearchCacheKey(path: virtualPath.description, pattern: pattern, options: options)
        syncRevisions()
        if let cached = searchCache.value(for: key) {
            counters.searchCacheHits += 1
            return cached
        }
        counters.searchCacheMisses += 1

        var run = SearchRun(options: options, deadline: compiled.deadline)
        var candidates = try await collectCandidates(below: virtualPath, filter: filter, run: &run)
        var strategy = SearchStrategy.virtual
        let wantsRemote = options.strategy == .remote
            || (options.strategy == .auto && candidates.count > options.maxFiles)
        if wantsRemote, PatternCompiler.isSimpleTerm(pattern, syntax: options.syntax) {
            do {
                let narrowed = try await narrowWithSourceSearch(candidates, term: pattern)
                if narrowed.usedIndex {
                    candidates = narrowed.candidates
                    strategy = .remote
                    run.reasons.append(.remoteIndexIncomplete)
                }
            } catch VFSError.rateLimited where options.strategy == .auto {
                run.reasons.append(.rateLimited)
            }
        }
        try await scan(run.budget(candidates), pattern: compiled, run: &run)

        let page = run.page(strategy: strategy)
        let isTransient = page.truncation.contains(.timeout) || page.truncation.contains(.rateLimited)
        if !isTransient {
            searchCache.insert(page, cost: 1, for: key)
        }
        return page
    }

    /// The text files below `path` that pass the globs and size limits, in walk order.
    private func collectCandidates(
        below path: VFSPath,
        filter: CandidateFilter,
        run: inout SearchRun
    ) async throws -> [Candidate] {
        var candidates: [Candidate] = []
        var skipLog = run.skipLog
        let walked = try await walk(from: path, deadline: run.deadline) { node in
            guard node.kind == .file, let mount = node.mount else { return true }
            switch filter.verdict(on: node, in: mount) {
            case .excluded:
                break
            case let .skipped(reason):
                skipLog.add(node.path, reason)
            case let .accepted(candidate):
                candidates.append(candidate)
            }
            return true
        }
        run.skipLog = skipLog
        run.reasons.append(contentsOf: walked.reasons)
        return candidates
    }

    /// Scans the candidates in windows, loading each window's small files from every mount in one
    /// request per mount.
    private func scan(_ eligible: [Candidate], pattern: CompiledPattern, run: inout SearchRun) async throws {
        let windowSize = 200
        var index = 0
        while index < eligible.count {
            try Task.checkCancellation()
            if ContinuousClock.now >= run.deadline {
                run.reasons.append(.timeout)
                return
            }
            let window = Array(eligible[index..<min(index + windowSize, eligible.count)])
            index += window.count
            let contents: [String: [String: FileContent]]
            do {
                contents = try await loadContents(of: window)
            } catch VFSError.rateLimited {
                run.reasons.append(.rateLimited)
                return
            }
            for candidate in window {
                let content = contents[candidate.mount.name]?[candidate.ref.path]
                let stop = if candidate.large {
                    try await scanLarge(candidate, pattern: pattern, run: &run)
                } else {
                    await scanLoaded(candidate, content: content, pattern: pattern, run: &run)
                }
                if stop { return }
            }
        }
    }

    /// The contents of the window's small files, keyed by mount name and then by mount path.
    private func loadContents(of window: [Candidate]) async throws -> [String: [String: FileContent]] {
        var order: [String] = []
        var byMount: [String: [Candidate]] = [:]
        for candidate in window where !candidate.large {
            if byMount[candidate.mount.name] == nil { order.append(candidate.mount.name) }
            byMount[candidate.mount.name, default: []].append(candidate)
        }
        var contents: [String: [String: FileContent]] = [:]
        for name in order {
            guard let files = byMount[name], let first = files.first else { continue }
            contents[name] = try await loadContents(mount: first.mount, refs: files.map(\.ref))
        }
        return contents
    }

    /// Scans a large local file line by line. Returns `true` when the search stops.
    private func scanLarge(
        _ candidate: Candidate,
        pattern: CompiledPattern,
        run: inout SearchRun
    ) async throws -> Bool {
        let perFileLimit = run.perFileLimit
        let text: LargeText
        do {
            text = try await largeText(path: candidate.path.description)
        } catch VFSError.binaryFile {
            run.skipLog.add(candidate.path, .binary)
            return false
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            run.skipLog.add(candidate.path, .unreadable)
            return false
        }
        run.filesScanned += 1
        run.bytesScanned += text.data.count
        counters.filesSearched += 1
        let scanned = await Self.scan(text, pattern: pattern, limit: perFileLimit, deadline: run.deadline)
        run.record(scanned.hits, in: candidate)
        if scanned.timedOut {
            run.reasons.append(.timeout)
            return true
        }
        return run.reachedMatchLimit()
    }

    /// Scans a file loaded with its window. Returns `true` when the search stops.
    private func scanLoaded(
        _ candidate: Candidate,
        content: FileContent?,
        pattern: CompiledPattern,
        run: inout SearchRun
    ) async -> Bool {
        guard let content else {
            run.skipLog.add(candidate.path, .unreadable)
            return false
        }
        switch content {
        case .binary:
            run.skipLog.add(candidate.path, .binary)
            return false
        case let .truncated(size):
            run.skipLog.add(candidate.path, .tooLarge(size: size))
            return false
        case let .text(data), let .transcodedText(data, _):
            run.filesScanned += 1
            run.bytesScanned += data.count
            counters.filesSearched += 1
            let text = String(repairingUTF8: data).removingByteOrderMark
            let hits = await Self.scan(text: text, pattern: pattern, limit: run.perFileLimit)
            run.record(hits, in: candidate)
            if pattern.isPastDeadline {
                run.reasons.append(.timeout)
                return true
            }
            return run.reachedMatchLimit()
        }
    }

    /// Keeps only the candidates the sources' own search indexes report. Mounts whose driver
    /// cannot search keep all their candidates.
    private func narrowWithSourceSearch(
        _ candidates: [Candidate],
        term: String
    ) async throws -> (candidates: [Candidate], usedIndex: Bool) {
        var askedMounts = Set<String>()
        var hitsByMount: [String: Set<String>] = [:]
        for candidate in candidates where askedMounts.insert(candidate.mount.name).inserted {
            if case let .paths(hits) = try await candidate.mount.driver.searchCandidates(for: term) {
                hitsByMount[candidate.mount.name] = hits
            }
        }
        let kept = candidates.filter { candidate in
            guard let hits = hitsByMount[candidate.mount.name] else { return true }
            return hits.contains(candidate.ref.path)
        }
        return (kept, !hitsByMount.isEmpty)
    }

    /// Matching lines of a large file. Static and asynchronous, so the matching runs off the actor
    /// and a slow expression does not hold up other operations.
    private static func scan(
        _ text: LargeText,
        pattern: CompiledPattern,
        limit: Int,
        deadline: ContinuousClock.Instant
    ) async -> (hits: [(line: Int, text: String)], timedOut: Bool) {
        text.scan(pattern, limit: limit, deadline: deadline)
    }

    /// Finds matching lines in `text`, collecting at most `limit` of them. Static and asynchronous,
    /// so the matching runs off the actor.
    static func scan(text: String, pattern: CompiledPattern, limit: Int) async -> [(line: Int, text: String)] {
        // NSRegularExpression exception: its matching callback enforces the time limit.
        // The prefilter runs it over the whole text, which takes an NSString.
        // swiftlint:disable:next legacy_objc_type
        guard limit > 0, pattern.mayMatch(NSString(string: text)) else { return [] }
        var hits: [(line: Int, text: String)] = []
        for (index, slice) in text.lineSlices.enumerated() {
            let bytes = slice.last == UInt8(ascii: "\r") ? slice.dropLast() : slice
            let line = String(Substring(bytes))
            guard pattern.matches(line) else { continue }
            hits.append((index + 1, LargeText.clipped(line)))
            if hits.count >= limit { break }
        }
        return hits
    }
}
