//
//  WorkspaceStateTests.swift
//  AgentVFSTests
//
//  Created by Yevhenii Kalashnikov on 15.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation
import Testing
@testable import AgentVFS

/// One file, `a.txt`, with a fixed id, and a directory `dir`. Reads of the file and listings of
/// `dir` wait at their gates when given.
private struct GatedDriver: MountDriver {
    let content: String
    let child: String
    var readGate: Gate?
    var listGate: Gate?
    var info: MountInfo { MountInfo(kind: "gated", source: content) }

    func list(_ directory: EntryRef) async throws -> [DriverEntry] {
        if directory.path.isEmpty {
            return [
                DriverEntry(name: "a.txt", kind: .file, size: content.utf8.count, id: "v1"),
                DriverEntry(name: "dir", kind: .directory)
            ]
        }
        await listGate?.pass()
        return [DriverEntry(name: child, kind: .file, size: 1, id: child)]
    }

    func read(_ file: EntryRef) async throws -> FileContent {
        await readGate?.pass()
        return .text(Data(content.utf8))
    }
}

@Suite("mounts replaced while an operation waits")
struct MountReplacementTests {
    private func workspace(_ driver: GatedDriver) throws -> WorkspaceFileSystem {
        let other = WorkspaceMount(name: "other", driver: InMemoryDriver())
        return try WorkspaceFileSystem(mounts: [other, WorkspaceMount(name: "m", driver: driver)])
    }

    private func replace(in fileSystem: WorkspaceFileSystem, with driver: GatedDriver) async throws {
        try await fileSystem.removeMount(named: "m")
        try await fileSystem.addMount(WorkspaceMount(name: "m", driver: driver))
    }

    @Test("content read from a removed mount is not cached for its replacement")
    func staleContent() async throws {
        let gate = Gate()
        let fileSystem = try workspace(GatedDriver(content: "old", child: "old.txt", readGate: gate))
        let reading = Task { try await fileSystem.readText(path: "/workspace/m/a.txt").text }
        await gate.waitUntilEntered()
        try await replace(in: fileSystem, with: GatedDriver(content: "new", child: "new.txt"))
        gate.open()
        #expect(try await reading.value == "old")
        #expect(try await fileSystem.readText(path: "/workspace/m/a.txt").text == "new")
    }

    @Test("a listing from a removed mount is not cached for its replacement")
    func staleListing() async throws {
        let gate = Gate()
        let fileSystem = try workspace(GatedDriver(content: "old", child: "old.txt", listGate: gate))
        let listing = Task { try await fileSystem.list(path: "/workspace/m/dir").map(\.name) }
        await gate.waitUntilEntered()
        try await replace(in: fileSystem, with: GatedDriver(content: "new", child: "new.txt"))
        _ = try await fileSystem.list(path: "/workspace/m")
        gate.open()
        #expect(try await listing.value == ["old.txt"])
        #expect(try await fileSystem.list(path: "/workspace/m/dir").map(\.name) == ["new.txt"])
    }

    @Test("in-memory drivers mounted one after another under a name never share a download")
    func inMemoryIds() async throws {
        let first = try InMemoryDriver(texts: ["a.txt": "first"])
        let fileSystem = try WorkspaceFileSystem(mounts: [
            WorkspaceMount(name: "keep", driver: InMemoryDriver()),
            WorkspaceMount(name: "docs", driver: first)
        ])
        let cache = DownloadCache(capacity: 1_000, label: "Test")
        let firstLease = try await cache.lease(path: "/workspace/docs/a.txt", fileSystem: fileSystem, maxBytes: 100)
        firstLease.finish()
        try await fileSystem.removeMount(named: "docs")
        let second = try InMemoryDriver(texts: ["a.txt": "second"])
        try await fileSystem.addMount(WorkspaceMount(name: "docs", driver: second))
        let secondLease = try await cache.lease(path: "/workspace/docs/a.txt", fileSystem: fileSystem, maxBytes: 100)
        defer { secondLease.finish() }
        #expect(try String(contentsOf: secondLease.url, encoding: .utf8) == "second")
    }
}

@Suite("workspace and driver checks")
struct WorkspaceCheckTests {
    @Test("refreshing a mount that does not exist is an error")
    func refreshUnknown() async throws {
        let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "a", driver: InMemoryDriver())])
        await #expect(throws: VFSError.unknownMount("nope")) { try await fileSystem.refresh(mountNamed: "nope") }
        try await fileSystem.refresh()
    }

    @Test("in-memory files whose names the workspace would hide are refused", arguments: [
        "bad\u{1B}name.txt", "dir/new\nline.txt", "right\u{202E}left.txt", "zero\u{200B}.txt", "a/./b"
    ])
    func hiddenNames(path: String) {
        let expected = VFSError.invalidPath("'\(path)' is not a file path the workspace can show")
        #expect(throws: expected) { try InMemoryDriver().put(path, text: "x") }
        #expect(throws: expected) { try InMemoryDriver(texts: [path: "x"]) }
    }

    @Test("finishing a lease twice does not release a copy another lease still uses")
    func leaseFinishedTwice() async throws {
        let driver = try InMemoryDriver(texts: ["a.txt": "0123456789", "b.txt": "abcdefghij"])
        let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "docs", driver: driver)])
        let cache = DownloadCache(capacity: 15, label: "Test")
        let first = try await cache.lease(path: "/workspace/docs/a.txt", fileSystem: fileSystem, maxBytes: 100)
        let second = try await cache.lease(path: "/workspace/docs/a.txt", fileSystem: fileSystem, maxBytes: 100)
        first.finish()
        first.finish()
        let other = try await cache.lease(path: "/workspace/docs/b.txt", fileSystem: fileSystem, maxBytes: 100)
        #expect(FileManager.default.fileExists(atPath: second.url.path), "the second lease still uses the copy")
        second.finish()
        other.finish()
        #expect(FileManager.default.fileExists(atPath: second.url.path) == false)
    }
}
