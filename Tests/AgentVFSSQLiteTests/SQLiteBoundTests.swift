//
//  SQLiteBoundTests.swift
//  AgentVFSSQLiteTests
//
//  Created by Yevhenii Kalashnikov on 15.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import AgentVFSSQLite
import Testing

@Suite("sqlite3 bounds and parsing")
struct SQLiteBoundTests {
    private func shell(_ command: SQLiteCommand = SQLiteCommand(), limits: OutputLimits = OutputLimits()) throws
        -> CommandInterpreter {
        let empty = try database("CREATE TABLE t(x);")
        let shop = try database(shopSQL)
        let driver = try InMemoryDriver(files: ["a.db": empty, "shop.db": shop])
        let fileSystem = try workspace("data", driver: driver)
        return CommandInterpreter(fileSystem: fileSystem, limits: limits, commands: [command])
    }

    @Test("a sort that needs more temporary space than allowed stops with an error")
    func temporarySpace() async throws {
        let rows = "WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c WHERE n < 100000)"
        let sort = "sqlite3 data/a.db \"\(rows) SELECT n, randomblob(200) FROM c ORDER BY random()\""
        let capped = try shell(SQLiteCommand(maxTemporaryBytes: 1_000_000))
        let refused = await capped.run(sort)
        #expect(refused.exitCode == 1)
        #expect(refused.output.contains("more than 1000000 bytes of temporary space"))
        #expect(try await shell().run(sort).exitCode == 0)
    }

    @Test("a value larger than the output is read only as far as the output shows")
    func largeValue() async throws {
        let doubling = "WITH RECURSIVE c(s, n) AS (SELECT 'ab', 0 UNION ALL SELECT s || s, n + 1 FROM c WHERE n < 22)"
        let result = try await shell().run("sqlite3 data/a.db \"\(doubling) SELECT s FROM c WHERE n = 22\"")
        #expect(result.truncated == false)
        #expect(result.output.hasSuffix("... (output limit reached; narrow the query with WHERE or LIMIT)"))
        #expect(result.output.utf8.count <= OutputLimits().maxBytes)
    }

    @Test("text with a NUL character is read whole")
    func embeddedNul() async throws {
        let output = try await shell().run("sqlite3 data/a.db \"SELECT 'a' || char(0) || 'b'\"").output
        #expect(output == "a\u{0}b")
    }

    @Test("options may follow the database but not the SQL")
    func optionsAfterDatabase() async throws {
        let shell = try shell()
        let after = await shell.run("sqlite3 data/shop.db -header 'SELECT id FROM users WHERE id = 1'")
        #expect(after.output == "id\n1")
        let afterSQL = await shell.run("sqlite3 data/shop.db 'SELECT id FROM users WHERE id = 1' -header")
        #expect(afterSQL.exitCode == 1)
    }

    @Test("a dot command with extra words is refused")
    func dotCommandWords() async throws {
        let result = try await shell().run("sqlite3 data/shop.db '.tables us% extra'")
        #expect(result.exitCode == 1)
        #expect(result.output.contains(".tables takes at most one pattern, not 'us% extra'"))
    }

    @Test("cancelling the command interrupts a running query")
    func cancellation() async throws {
        let shell = try shell(SQLiteCommand(timeout: .seconds(60)), limits: OutputLimits(timeLimit: .seconds(60)))
        let started = ContinuousClock.now
        let task = Task { await shell.run("sqlite3 data/a.db '\(endlessCounter) SELECT count(*) FROM c'") }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = await task.value
        #expect(result.exitCode == 130)
        #expect(ContinuousClock.now - started < .seconds(20))
    }
}
