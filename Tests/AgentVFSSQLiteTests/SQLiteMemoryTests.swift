//
//  SQLiteMemoryTests.swift
//  AgentVFSSQLiteTests
//
//  Created by Yevhenii Kalashnikov on 30.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
@testable import AgentVFSSQLite
import Foundation
import Testing

@Suite("sqlite3 from memory")
struct SQLiteMemoryTests {
    @Test("a database from a driver is queried from memory and the limit applies")
    func inMemory() async throws {
        let shop = try database(shopSQL)
        let driver = try InMemoryDriver(files: ["remote.db": shop])
        let fileSystem = try workspace("api", driver: driver)
        let shell = CommandInterpreter(fileSystem: fileSystem, commands: [SQLiteCommand()])
        #expect(await shell.run("sqlite3 api/remote.db 'SELECT count(*) FROM users'").output == "3")
        let small = CommandInterpreter(fileSystem: fileSystem, commands: [SQLiteCommand(maxDownloadBytes: 100)])
        #expect(await small.run("sqlite3 api/remote.db 'SELECT 1'").output.contains("too large"))
    }

    @Test("a database from a driver is never written to disk")
    func inMemoryLeavesNoFiles() async throws {
        let shop = try database(shopSQL)
        let driver = try InMemoryDriver(files: ["remote.db": shop])
        let fileSystem = try workspace("api", driver: driver)
        let shell = CommandInterpreter(fileSystem: fileSystem, commands: [SQLiteCommand()])
        let before = try agentTemporaryItems()
        let sorted = await shell.run("sqlite3 api/remote.db 'SELECT name FROM users ORDER BY name DESC'")
        #expect(sorted.output == "Chloé, Jr.\nBob\nAnn")
        #expect(try agentTemporaryItems().subtracting(before).isEmpty)
    }

    @Test("a database from a driver is read-only and cannot be changed")
    func inMemoryReadOnly() async throws {
        let shop = try database(shopSQL)
        let driver = try InMemoryDriver(files: ["remote.db": shop])
        let fileSystem = try workspace("api", driver: driver)
        let shell = CommandInterpreter(fileSystem: fileSystem, commands: [SQLiteCommand()])
        let result = await shell.run("sqlite3 api/remote.db \"INSERT INTO users(id, name) VALUES (9, 'Eve')\"")
        #expect(result.exitCode == 1)
        #expect(result.output.contains("not authorized"))
    }

    @Test("a file from a driver that is not a database is refused")
    func inMemoryNotDatabase() async throws {
        let driver = try InMemoryDriver(files: ["remote.db": Data("plain text, not a database".utf8)])
        let fileSystem = try workspace("api", driver: driver)
        let shell = CommandInterpreter(fileSystem: fileSystem, commands: [SQLiteCommand()])
        let result = await shell.run("sqlite3 api/remote.db 'SELECT 1'")
        #expect(result.exitCode == 1)
        #expect(result.output.contains("file is not a database"))
    }

    @Test("a new version of a database replaces the cached one")
    func inMemoryNewVersion() async throws {
        let first = try database("CREATE TABLE a(x); INSERT INTO a VALUES (1);")
        let driver = try InMemoryDriver(files: ["remote.db": first])
        let fileSystem = try workspace("api", driver: driver)
        let shell = CommandInterpreter(fileSystem: fileSystem, commands: [SQLiteCommand()])
        #expect(await shell.run("sqlite3 api/remote.db 'SELECT x FROM a'").output == "1")
        try driver.put("remote.db", data: database("CREATE TABLE a(x); INSERT INTO a VALUES (2);"))
        #expect(await shell.run("sqlite3 api/remote.db 'SELECT x FROM a'").output == "2")
    }

    @Test(
        "a database from a driver cannot attach, vacuum, load extensions, change temp_store or write",
        arguments: [
            "ATTACH ':memory:' AS other",
            "ATTACH '/etc/hosts' AS other",
            "VACUUM INTO '/tmp/agentvfs-memory-vacuum.db'",
            "SELECT load_extension('x')",
            "PRAGMA temp_store = MEMORY",
            "PRAGMA temp_store_directory = '/tmp'",
            "CREATE TABLE extra(x)",
            "DELETE FROM users",
            "UPDATE users SET name = 'x'",
            "DROP TABLE users"
        ]
    )
    func inMemoryRefusesStatement(sql: String) async throws {
        let shop = try database(shopSQL)
        let driver = try InMemoryDriver(files: ["remote.db": shop])
        let fileSystem = try workspace("api", driver: driver)
        let shell = CommandInterpreter(fileSystem: fileSystem, commands: [SQLiteCommand()])
        let result = await shell.run("sqlite3 api/remote.db \"\(sql)\"")
        #expect(result.exitCode == 1)
        #expect(await shell.run("sqlite3 api/remote.db 'SELECT count(*) FROM users'").output == "3")
        #expect(FileManager.default.fileExists(atPath: "/tmp/agentvfs-memory-vacuum.db") == false)
    }

    @Test("a database in write-ahead-log format is read as of its checkpoint from memory")
    func inMemoryWriteAheadLog() async throws {
        let image = try database("CREATE TABLE a(x); INSERT INTO a VALUES (1), (2);", wal: true)
        #expect(RollbackImages.isWriteAheadLog(image))
        let driver = try InMemoryDriver(files: ["remote.db": image])
        let fileSystem = try workspace("api", driver: driver)
        let shell = CommandInterpreter(fileSystem: fileSystem, commands: [SQLiteCommand()])
        #expect(await shell.run("sqlite3 api/remote.db 'SELECT count(*) FROM a'").output == "2")
    }

    @Test("the rollback-journal copy of an image is made once per file version")
    func rollbackImageIsKept() async throws {
        let image = try database("CREATE TABLE a(x);", wal: true)
        let driver = try InMemoryDriver(files: ["remote.db": image])
        let fileSystem = try workspace("api", driver: driver)
        let cache = DownloadCache(capacity: 1_000_000)
        let images = RollbackImages(capacity: 1_000_000)
        let lease = try await cache.lease(path: "/workspace/api/remote.db", fileSystem: fileSystem, maxBytes: 1_000_000)
        guard case let .data(first) = images.readable(lease), case let .data(second) = images.readable(lease) else {
            Issue.record("a database in memory is not read as data")
            return
        }
        #expect(RollbackImages.isWriteAheadLog(first) == false)
        #expect(first.withUnsafeBytes(\.baseAddress) == second.withUnsafeBytes(\.baseAddress))
        try driver.put("remote.db", data: image)
        let newer = try await cache.lease(path: "/workspace/api/remote.db", fileSystem: fileSystem, maxBytes: 1_000_000)
        guard case let .data(third) = images.readable(newer) else {
            Issue.record("a database in memory is not read as data")
            return
        }
        #expect(first.withUnsafeBytes(\.baseAddress) != third.withUnsafeBytes(\.baseAddress))
    }

    @Test("a database in a driver leaves no library file in the temporary directory")
    func inMemoryLeavesNoLibraryFile() async throws {
        let shop = try database(shopSQL)
        let driver = try InMemoryDriver(files: ["remote.db": shop])
        let fileSystem = try workspace("api", driver: driver)
        let shell = CommandInterpreter(fileSystem: fileSystem, commands: [SQLiteCommand()])
        let before = try agentTemporaryItems()
        _ = await shell.run("sqlite3 api/remote.db 'SELECT * FROM users ORDER BY name'")
        _ = await shell.run("sqlite3 api/remote.db 'SELECT * FROM orders ORDER BY note DESC'")
        #expect(try agentTemporaryItems().subtracting(before).isEmpty)
    }
}
