//
//  SearchBoundTests.swift
//  AgentVFSTests
//
//  Created by Yevhenii Kalashnikov on 15.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation
import Synchronization
import Testing
@testable import AgentVFS

/// In-memory files with a search index that takes every term literally, and cheap listings.
private struct IndexedDriver: MountDriver {
    let files: [String: String]
    var info: MountInfo { MountInfo(kind: "indexed", source: "indexed files") }
    var listingIsCheap: Bool { true }

    func list(_ directory: EntryRef) async throws -> [DriverEntry] {
        files.map { DriverEntry(name: $0.key, kind: .file, size: $0.value.utf8.count, id: $0.key) }
    }

    func read(_ file: EntryRef) async throws -> FileContent {
        guard let text = files[file.path] else { throw VFSError.notFound(file.path) }
        return .text(Data(text.utf8))
    }

    func searchCandidates(for term: String) async throws -> SearchCandidates {
        .paths(Set(files.filter { $0.value.contains(term) }.map(\.key)))
    }
}

/// A large file of a local source whose exact bytes can be read `allowedReads` times, after which
/// reading throws `CancellationError`, as a driver that sees its task cancelled does.
private struct CancellingDriver: MountDriver {
    final class Reads: Sendable {
        let count = Mutex(0)
    }

    let text: String
    let allowedReads: Int
    let reads = Reads()
    var info: MountInfo { MountInfo(kind: "cancelling", source: "cancelling") }
    var listingIsCheap: Bool { true }

    func list(_ directory: EntryRef) async throws -> [DriverEntry] {
        [DriverEntry(name: "big.log", kind: .file, size: text.utf8.count, id: "v1")]
    }

    func read(_ file: EntryRef) async throws -> FileContent { .text(Data(text.utf8)) }

    func readExactBytes(_ file: EntryRef) async throws -> Data {
        let number = reads.count.withLock { count in
            count += 1
            return count
        }
        guard number <= allowedReads else { throw CancellationError() }
        return Data(text.utf8)
    }
}

private let bigLog = String(repeating: "filler line\n", count: 100) + "ERROR here\n"

@Suite("search configuration")
struct SearchConfigurationTests {
    private func workspace() throws -> WorkspaceFileSystem {
        let driver = try InMemoryDriver(texts: ["a.txt": "needle\n"])
        return try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "data", driver: driver)])
    }

    @Test("search options out of range are refused instead of trapping", arguments: [
        SearchOptions(maxMatches: Int.max),
        SearchOptions(maxMatches: 0),
        SearchOptions(maxMatchesPerFile: -1),
        SearchOptions(maxFiles: -1),
        SearchOptions(maxTotalBytes: -1),
        SearchOptions(timeout: .zero)
    ])
    func invalidOptions(options: SearchOptions) async throws {
        let fileSystem = try workspace()
        await #expect(throws: VFSError.self) {
            _ = try await fileSystem.search(pattern: "needle", path: "/workspace", options: options)
        }
    }

    @Test("workspace limits out of range are refused", arguments: [
        VFSLimits(maxReadBytes: -1), VFSLimits(contentCacheBytes: -1), VFSLimits(maxWalkEntries: 0)
    ])
    func invalidLimits(limits: VFSLimits) throws {
        let mount = WorkspaceMount(name: "data", driver: InMemoryDriver())
        #expect(throws: VFSError.self) { try WorkspaceFileSystem(mounts: [mount], limits: limits) }
    }

    @Test("output limits out of range are refused", arguments: [
        OutputLimits(maxBytes: 0), OutputLimits(maxLines: Int.max), OutputLimits(timeLimit: .zero)
    ])
    func invalidOutputLimits(limits: OutputLimits) {
        #expect(throws: VFSError.self) { try limits.validate() }
    }

    @Test("the default search time limit is 15 seconds")
    func defaultTimeout() {
        #expect(SearchOptions().timeout == .seconds(15))
    }

    @Test("a catastrophic expression stops at the search time limit")
    func searchTimeout() async throws {
        let driver = try InMemoryDriver(texts: ["a.txt": String(repeating: "a", count: 40) + "!\n"])
        let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "data", driver: driver)])
        let options = SearchOptions(syntax: .extended, timeout: .milliseconds(300))
        let started = ContinuousClock.now
        let page = try await fileSystem.search(pattern: "(a+)+$", path: "/workspace", options: options)
        #expect(ContinuousClock.now - started < .seconds(15))
        #expect(page.truncation.contains(.timeout))
    }

    @Test("matching runs off the workspace actor, so other calls are not held up")
    func matchingOffActor() async throws {
        let driver = try InMemoryDriver(texts: ["a.txt": String(repeating: "a", count: 40) + "!\n"])
        let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "data", driver: driver)])
        let options = SearchOptions(syntax: .extended, timeout: .seconds(8))
        let search = Task { try await fileSystem.search(pattern: "(a+)+$", path: "/workspace", options: options) }
        try await Task.sleep(for: .milliseconds(300))
        let started = ContinuousClock.now
        _ = try await fileSystem.stat(path: "/workspace/data/a.txt")
        #expect(ContinuousClock.now - started < .seconds(4))
        _ = try await search.value
    }
}

@Suite("search strategies")
struct SearchStrategyTests {
    @Test("a dot is a plain term only in a fixed string")
    func simpleTerms() {
        #expect(PatternCompiler.isSimpleTerm("a.b", syntax: .fixed))
        #expect(PatternCompiler.isSimpleTerm("a.b", syntax: .extended) == false)
        #expect(PatternCompiler.isSimpleTerm("a.b", syntax: .basic) == false)
    }

    @Test("a regular expression with a dot is not narrowed by the index as a literal")
    func dotIsNotLiteral() async throws {
        let driver = IndexedDriver(files: ["one.txt": "axb\n", "two.txt": "nothing\n"])
        let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "data", driver: driver)])
        let options = SearchOptions(syntax: .extended, strategy: .remote)
        let page = try await fileSystem.search(pattern: "a.b", path: "/workspace", options: options)
        #expect(page.matches.map(\.path) == ["/workspace/data/one.txt"])
        #expect(page.strategy == .virtual, "a pattern the index cannot take falls back to virtual")
    }
}

@Suite("search cancellation")
struct SearchCancellationTests {
    @Test("cancellation while a large file loads ends the search instead of skipping the file")
    func largeFile() async throws {
        let driver = CancellingDriver(text: bigLog, allowedReads: 0)
        let mount = WorkspaceMount(name: "data", driver: driver)
        let fileSystem = try WorkspaceFileSystem(mounts: [mount], limits: VFSLimits(maxReadBytes: 10))
        let options = SearchOptions(maxFileBytes: 10)
        await #expect(throws: CancellationError.self) {
            _ = try await fileSystem.search(pattern: "ERROR", path: "/workspace", options: options)
        }
    }

    @Test("cancellation while context is read ends the command")
    func contextLines() async throws {
        let driver = CancellingDriver(text: bigLog, allowedReads: 1)
        let mount = WorkspaceMount(name: "data", driver: driver)
        let fileSystem = try WorkspaceFileSystem(mounts: [mount], limits: VFSLimits(maxReadBytes: 10))
        let shell = CommandInterpreter(fileSystem: fileSystem, limits: OutputLimits(maxSearchFileBytes: 10))
        let result = await shell.run("grep -C 1 ERROR data/big.log")
        #expect(result == CommandResult(output: "[cancelled]", exitCode: 130))
    }
}

@Suite("find bounds")
struct FindBoundTests {
    private func workspace(limits: VFSLimits = VFSLimits()) throws -> WorkspaceFileSystem {
        let files = Dictionary(uniqueKeysWithValues: (1...10).map { ("f\($0).txt", "x") })
        let driver = try InMemoryDriver(texts: files)
        return try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "data", driver: driver)], limits: limits)
    }

    @Test("find stops at its time limit")
    func timeout() async throws {
        let found = try await workspace().find(path: "/workspace", query: FindQuery(timeout: .nanoseconds(1)))
        #expect(found.truncation == [.timeout])
        #expect(found.isComplete == false)
    }

    @Test("find stops after visiting the most entries a walk may visit")
    func visitLimit() async throws {
        let fileSystem = try workspace(limits: VFSLimits(maxWalkEntries: 3))
        let found = try await fileSystem.find(path: "/workspace", query: FindQuery())
        #expect(found.truncation == [.visitLimit(3)])
        #expect(found.entries.count == 3)
    }

    @Test("a query out of range is refused", arguments: [FindQuery(limit: -1), FindQuery(maxDepth: -1)])
    func invalidQuery(query: FindQuery) async throws {
        let fileSystem = try workspace()
        await #expect(throws: VFSError.self) { _ = try await fileSystem.find(path: "/workspace", query: query) }
    }

    @Test("the listing cache drops directories past its entry limit")
    func listingCacheBound() async throws {
        let root = try makeTemporaryDirectory(["a/1": "", "a/2": "", "b/1": "", "b/2": ""])
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
        let driver = try LocalDirectoryDriver(root: root)
        let mount = WorkspaceMount(name: "d", driver: driver)
        let fileSystem = try WorkspaceFileSystem(mounts: [mount], limits: VFSLimits(maxCachedListingEntries: 3))
        _ = try await fileSystem.list(path: "/workspace/d")
        _ = try await fileSystem.list(path: "/workspace/d/a")
        let before = await fileSystem.metrics().listingFetches
        _ = try await fileSystem.list(path: "/workspace/d")
        #expect(await fileSystem.metrics().listingFetches == before + 1, "the root was dropped from the cache")
    }
}
