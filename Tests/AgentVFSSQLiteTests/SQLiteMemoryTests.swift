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
}
