//
//  DownloadCacheTests.swift
//  AgentVFSTests
//
//  Created by Yevhenii Kalashnikov on 30.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation
import Testing
@testable import AgentVFS

@Suite("download cache")
struct DownloadCacheTests {
    private static let path = "/workspace/docs/a.txt"

    private func fileSystem(_ driver: InMemoryDriver) throws -> WorkspaceFileSystem {
        try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "docs", driver: driver)])
    }

    @Test("a file from a driver is read once into memory and reused")
    func reuse() async throws {
        let driver = try InMemoryDriver(texts: ["a.txt": "0123456789"])
        let fileSystem = try fileSystem(driver)
        let cache = DownloadCache(capacity: 1_000)
        let first = try await cache.lease(path: Self.path, fileSystem: fileSystem, maxBytes: 100)
        let second = try await cache.lease(path: Self.path, fileSystem: fileSystem, maxBytes: 100)
        guard case .data = first.source else {
            Issue.record("a file without a local path is not held in memory")
            return
        }
        #expect(try second.text() == "0123456789")
        #expect(first.version == second.version)
        #expect(await fileSystem.metrics().filesRead == 1)
    }

    @Test("the oldest file is evicted when the capacity is passed")
    func evictionByCapacity() async throws {
        let driver = try InMemoryDriver(texts: ["a.txt": "0123456789", "b.txt": "abcdefghij"])
        let fileSystem = try fileSystem(driver)
        let cache = DownloadCache(capacity: 15)
        _ = try await cache.lease(path: Self.path, fileSystem: fileSystem, maxBytes: 100)
        _ = try await cache.lease(path: "/workspace/docs/b.txt", fileSystem: fileSystem, maxBytes: 100)
        #expect(await fileSystem.metrics().filesRead == 2)
        _ = try await cache.lease(path: "/workspace/docs/b.txt", fileSystem: fileSystem, maxBytes: 100)
        #expect(await fileSystem.metrics().filesRead == 2, "the newer file is still cached")
        let evicted = try await cache.lease(path: Self.path, fileSystem: fileSystem, maxBytes: 100)
        #expect(await fileSystem.metrics().filesRead == 3, "the older file was evicted and is read again")
        #expect(try evicted.text() == "0123456789")
    }

    @Test("an evicted file stays readable by the lease that holds it")
    func leaseOutlivesEviction() async throws {
        let driver = try InMemoryDriver(texts: ["a.txt": "0123456789", "b.txt": "abcdefghij"])
        let fileSystem = try fileSystem(driver)
        let cache = DownloadCache(capacity: 15)
        let first = try await cache.lease(path: Self.path, fileSystem: fileSystem, maxBytes: 100)
        _ = try await cache.lease(path: "/workspace/docs/b.txt", fileSystem: fileSystem, maxBytes: 100)
        #expect(try first.text() == "0123456789")
    }

    @Test("a file larger than the capacity is read for one use and not kept")
    func largerThanCapacity() async throws {
        let driver = try InMemoryDriver(texts: ["a.txt": "0123456789"])
        let fileSystem = try fileSystem(driver)
        let cache = DownloadCache(capacity: 5)
        let lease = try await cache.lease(path: Self.path, fileSystem: fileSystem, maxBytes: 100)
        #expect(try lease.text() == "0123456789")
        _ = try await cache.lease(path: Self.path, fileSystem: fileSystem, maxBytes: 100)
        #expect(await fileSystem.metrics().filesRead == 2)
    }

    @Test("a changed file version replaces the cached data")
    func versionChange() async throws {
        let driver = try InMemoryDriver(texts: ["a.txt": "before"])
        let fileSystem = try fileSystem(driver)
        let cache = DownloadCache(capacity: 1_000)
        let before = try await cache.lease(path: Self.path, fileSystem: fileSystem, maxBytes: 100)
        try driver.put("a.txt", text: "after")
        let after = try await cache.lease(path: Self.path, fileSystem: fileSystem, maxBytes: 100)
        #expect(try before.text() == "before")
        #expect(try after.text() == "after")
        #expect(before.version != after.version)
    }

    @Test("a file over the limit is refused")
    func tooLarge() async throws {
        let driver = try InMemoryDriver(texts: ["a.txt": "0123456789"])
        let fileSystem = try fileSystem(driver)
        let cache = DownloadCache(capacity: 1_000)
        await #expect(throws: VFSError.fileTooLarge(path: Self.path, size: 10, limit: 5)) {
            try await cache.lease(path: Self.path, fileSystem: fileSystem, maxBytes: 5)
        }
    }

    @Test("a file on the local disk is opened in place")
    func localFile() async throws {
        let root = try makeTemporaryDirectory(["a.txt": "0123456789"])
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
        let driver = try LocalDirectoryDriver(root: root)
        let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "docs", driver: driver)])
        let cache = DownloadCache(capacity: 1_000)
        let lease = try await cache.lease(path: Self.path, fileSystem: fileSystem, maxBytes: 100)
        guard case .file = lease.source else {
            Issue.record("a local file is not opened in place")
            return
        }
        #expect(try lease.text() == "0123456789")
    }
}
