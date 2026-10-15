//
//  SQLiteTests.swift
//  AgentVFSSQLiteTests
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import AgentVFSSQLite
import Foundation
import SQLite3
import Testing

@Suite("sqlite3")
struct SQLiteCommandTests {
    private func shell(_ files: [String: Data]) throws -> CommandInterpreter {
        let driver = try InMemoryDriver(files: files)
        let fileSystem = try workspace("data", driver: driver)
        return CommandInterpreter(fileSystem: fileSystem, commands: [SQLiteCommand()])
    }

    @Test("lists tables, shows the schema and runs queries in every mode")
    func queries() async throws {
        let shop = try database(shopSQL)
        let shell = try shell(["shop.db": shop])
        #expect(await shell.run("sqlite3 data/shop.db").output == "big_orders\norders\nusers")
        #expect(await shell.run("sqlite3 data/shop.db .tables 'us%'").output == "users")
        let schema = await shell.run("sqlite3 data/shop.db '.schema users'").output
        #expect(schema.contains("CREATE TABLE users (id INTEGER PRIMARY KEY"))
        #expect(schema.contains("CREATE INDEX users_email ON users(email);"))
        #expect(await shell.run("sqlite3 data/shop.db .indexes").output == "users_email")

        #expect(await shell.run("sqlite3 data/shop.db 'SELECT id, name, score FROM users ORDER BY id'").output
            == "1|Ann|4.5\n2|Bob|3.0\n3|Chloé, Jr.|")
        let nullValue = "sqlite3 -header -nullvalue NULL data/shop.db 'SELECT name, email FROM users WHERE id > 1'"
        #expect(await shell.run(nullValue).output == "name|email\nBob|NULL\nChloé, Jr.|c@example.com")
        let join = "SELECT name, note FROM users JOIN orders ON orders.user_id = users.id ORDER BY orders.id"
        #expect(await shell.run("sqlite3 -csv -header data/shop.db '\(join)'").output
            == "name,note\nAnn,first\nAnn,\"small \"\"one\"\"\"\nBob,")
        #expect(await shell.run("sqlite3 -json data/shop.db 'SELECT id, total, note FROM big_orders'").output
            == "[{\"id\":1,\"total\":250.0,\"note\":\"first\"},\n{\"id\":3,\"total\":120.5,\"note\":null}]")
        #expect(await shell.run("sqlite3 -line data/shop.db 'SELECT id, name FROM users WHERE id = 1'").output
            == "  id = 1\nname = Ann")
        #expect(await shell.run("sqlite3 -column data/shop.db 'SELECT id, name FROM users WHERE id < 3'").output
            == "id  name\n--  ----\n1   Ann\n2   Bob")
        let twoStatements = "SELECT count(*) FROM users; SELECT max(total) FROM orders;"
        #expect(await shell.run("sqlite3 data/shop.db '\(twoStatements)'").output == "3\n250.0")
    }

    @Test("the database cannot be changed and nothing outside it can be reached")
    func readOnly() async throws {
        let shop = try database(shopSQL)
        let shell = try shell(["shop.db": shop])
        let write = await shell.run("sqlite3 data/shop.db \"DELETE FROM users\"")
        #expect(write.exitCode == 1)
        #expect(write.output.contains("not authorized"))
        #expect(await shell.run("sqlite3 data/shop.db 'SELECT count(*) FROM users'").output == "3")

        let attach = await shell.run("sqlite3 data/shop.db \"ATTACH '/etc/hosts' AS other\"")
        #expect(attach.exitCode == 1)
        #expect(await shell.run("sqlite3 data/shop.db \"SELECT load_extension('x')\"").exitCode == 1)
    }

    @Test("a runaway query stops at the time limit")
    func timeout() async throws {
        let empty = try database("CREATE TABLE t(x);")
        let driver = try InMemoryDriver(files: ["a.db": empty])
        let fileSystem = try workspace("data", driver: driver)
        let shell = CommandInterpreter(fileSystem: fileSystem, commands: [SQLiteCommand(timeout: .milliseconds(200))])
        let result = await shell.run("sqlite3 data/a.db '\(endlessCounter) SELECT count(*) FROM c'")
        #expect(result.exitCode == 1)
        #expect(result.output.contains("time limit"))
    }

    @Test("long results stop at the output limit")
    func outputLimit() async throws {
        let empty = try database("CREATE TABLE t(x);")
        let shell = try shell(["a.db": empty])
        let result = await shell.run("sqlite3 data/a.db '\(endlessCounter) SELECT n FROM c'")
        #expect(result.output.contains("output limit reached"))
    }

    @Test("write-ahead-log databases open")
    func wal() async throws {
        let setup = "CREATE TABLE t(x); INSERT INTO t VALUES (42); PRAGMA wal_checkpoint(TRUNCATE);"
        let walDatabase = try database(setup, wal: true)
        let shell = try shell(["w.db": walDatabase])
        #expect(await shell.run("sqlite3 data/w.db 'SELECT x FROM t'").output == "42")
    }

    @Test("errors name the file")
    func errors() async throws {
        let shop = try database(shopSQL)
        let shell = try shell(["notes.txt": Data("hello\n".utf8), "shop.db": shop])
        let notDatabase = await shell.run("sqlite3 data/notes.txt").output
        #expect(notDatabase == "sqlite3: /workspace/data/notes.txt: file is not a database")
        #expect(await shell.run("sqlite3 data/missing.db").exitCode == 1)
        let unknownColumn = await shell.run("sqlite3 data/shop.db 'SELECT nope FROM users'").output
        #expect(unknownColumn.contains("no such column: nope"))
        #expect(await shell.run("sqlite3").exitCode != 0)
        #expect(await shell.run("help").output.contains("sqlite3 [-header]"))
    }

    @Test("a local database file is read through the local driver")
    func localFile() async throws {
        let directory = try TemporaryDirectory()
        defer { extendLifetime(directory) }
        let root = directory.url
        try database(shopSQL).write(to: root.appendingPathComponent("shop.sqlite"))
        let fileSystem = try localWorkspace(root)
        let shell = CommandInterpreter(fileSystem: fileSystem, commands: [SQLiteCommand()])
        #expect(await shell.run("cd app").exitCode == 0)
        #expect(await shell.run("sqlite3 shop.sqlite 'SELECT name FROM users WHERE id = 2'").output == "Bob")
        #expect(await shell.run("sqlite3 shop.sqlite 'SELECT count(*) FROM orders'").output == "3")
    }

    @Test("a local database is opened in place: no download limit, no copy")
    func inPlace() async throws {
        let directory = try TemporaryDirectory()
        defer { extendLifetime(directory) }
        let root = directory.url
        // About 20 MB, far over the download limit below.
        var handle: OpaquePointer?
        try #require(sqlite3_open(root.appendingPathComponent("big.db").path, &handle) == SQLITE_OK)
        let fill = """
            CREATE TABLE t(id INTEGER PRIMARY KEY, payload BLOB);
            WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c WHERE n < 20000)
            INSERT INTO t SELECT n, randomblob(1000) FROM c;
            """
        try #require(sqlite3_exec(handle, fill, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)

        let command = SQLiteCommand(maxDownloadBytes: 1_000)
        let local = try localWorkspace(root)
        let shell = CommandInterpreter(fileSystem: local, commands: [command])
        #expect(await shell.run("sqlite3 app/big.db 'SELECT count(*), max(id) FROM t'").output == "20000|20000")
        #expect(await local.metrics().filesRead == 0, "nothing was read through the workspace")

        let copy = try Data(contentsOf: root.appendingPathComponent("big.db"))
        let driver = try InMemoryDriver(files: ["big.db": copy])
        let memory = try workspace("app", driver: driver)
        let memoryShell = CommandInterpreter(fileSystem: memory, commands: [command])
        let refused = await memoryShell.run("sqlite3 app/big.db 'SELECT 1'")
        #expect(refused.output.contains("too large"))
    }

    @Test("a local database is read through the file the driver checked, as of its last checkpoint")
    func liveWAL() async throws {
        let directory = try TemporaryDirectory()
        defer { extendLifetime(directory) }
        let root = directory.url
        var writer: OpaquePointer?
        try #require(sqlite3_open(root.appendingPathComponent("live.db").path, &writer) == SQLITE_OK)
        defer { sqlite3_close(writer) }
        let setup = """
            PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;
            CREATE TABLE t(x); INSERT INTO t VALUES (1);
            PRAGMA wal_checkpoint(TRUNCATE);
            INSERT INTO t VALUES (2);
            """
        try #require(sqlite3_exec(writer, setup, nil, nil, nil) == SQLITE_OK)

        let fileSystem = try localWorkspace(root)
        let shell = CommandInterpreter(fileSystem: fileSystem, commands: [SQLiteCommand()])
        #expect(await shell.run("sqlite3 app/live.db 'SELECT count(*) FROM t'").output == "1")
        let write = await shell.run("sqlite3 app/live.db 'DELETE FROM t'")
        #expect(write.output.contains("not authorized"))
    }

    @Test("VACUUM INTO cannot write a file, and a link to a database is not opened")
    func noEscape() async throws {
        let directory = try TemporaryDirectory()
        defer { extendLifetime(directory) }
        let root = directory.url
        try database(shopSQL).write(to: root.appendingPathComponent("shop.db"))
        let outsideDirectory = try TemporaryDirectory()
        defer { extendLifetime(outsideDirectory) }
        let outside = outsideDirectory.url
        try database(shopSQL).write(to: outside.appendingPathComponent("secret.db"))
        let link = root.appendingPathComponent("link.db").path
        let secret = outside.appendingPathComponent("secret.db").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: secret)
        let fileSystem = try localWorkspace(root)
        let shell = CommandInterpreter(fileSystem: fileSystem, commands: [SQLiteCommand()])

        let target = outside.appendingPathComponent("copy.db").path
        let vacuum = await shell.run("sqlite3 app/shop.db \"VACUUM INTO '\(target)'\"")
        #expect(vacuum.exitCode == 1)
        #expect(FileManager.default.fileExists(atPath: target) == false)
        #expect(await shell.run("sqlite3 app/link.db 'SELECT 1'").output.contains("symbolic link"))
    }

    @Test("downloaded copies are reused and evicted by size")
    func downloadCache() async throws {
        let one = try database("CREATE TABLE a(x); INSERT INTO a VALUES (1);")
        let two = try database("CREATE TABLE b(x); INSERT INTO b VALUES (2);")
        let command = SQLiteCommand(downloadCacheBytes: one.count + 10)
        let driver = try InMemoryDriver(files: ["one.db": one, "two.db": two])
        let fileSystem = try workspace("d", driver: driver)
        let shell = CommandInterpreter(fileSystem: fileSystem, commands: [command])
        #expect(await shell.run("sqlite3 d/one.db 'SELECT x FROM a'").output == "1")
        #expect(await fileSystem.metrics().filesRead == 1)
        #expect(await shell.run("sqlite3 d/one.db 'SELECT x FROM a'").output == "1")
        #expect(await fileSystem.metrics().filesRead == 1, "the cached copy is reused")
        #expect(await shell.run("sqlite3 d/two.db 'SELECT x FROM b'").output == "2")
        #expect(await fileSystem.metrics().filesRead == 2)
        #expect(await shell.run("sqlite3 d/one.db 'SELECT x FROM a'").output == "1")
        #expect(await fileSystem.metrics().filesRead == 3, "only one database fits, so the first was evicted")
    }

    @Test("only reading is allowed", arguments: [
        "PRAGMA temp_store = MEMORY",
        "PRAGMA cache_size = 1000000",
        "PRAGMA mmap_size = 1000000000",
        "PRAGMA user_version = 5",
        "PRAGMA writable_schema = ON",
        "CREATE TEMP TABLE scratch(x)",
        "CREATE TEMP VIEW scratch AS SELECT 1",
        "CREATE TEMP TABLE scratch AS SELECT * FROM users",
        "INSERT INTO temp.sqlite_temp_master VALUES ('table', 'x', 'x', 0, '')",
        "BEGIN",
        "SAVEPOINT one",
        "ANALYZE",
        "SELECT fts3_tokenizer('simple')"
    ])
    func refused(sql: String) async throws {
        let shop = try database(shopSQL)
        let shell = try shell(["shop.db": shop])
        let result = await shell.run("sqlite3 data/shop.db \"\(sql)\"")
        #expect(result.exitCode == 1)
        #expect(result.output.contains("not authorized"))
    }

    @Test("read-only pragmas still answer", arguments: [
        ("PRAGMA table_info(orders)", "0|id|INTEGER|0||1"),
        ("SELECT name FROM pragma_table_info('users') WHERE pk = 1", "id"),
        ("PRAGMA index_list(users)", "0|users_email|0|c|0"),
        ("PRAGMA user_version", "0"),
        ("PRAGMA foreign_key_list(orders)", "0|0|users|user_id|id|NO ACTION|NO ACTION|NONE"),
        ("PRAGMA quick_check", "ok")
    ])
    func readOnlyPragmas(sql: String, firstLine: String) async throws {
        let shop = try database(shopSQL)
        let shell = try shell(["shop.db": shop])
        let result = await shell.run("sqlite3 data/shop.db \"\(sql)\"")
        #expect(result.exitCode == 0)
        #expect(result.output.split(separator: "\n").first.map(String.init) == firstLine)
    }

    @Test("a result row of many large values is refused instead of filling memory")
    func wideRows() async throws {
        let empty = try database("CREATE TABLE t(x);")
        let shell = try shell(["a.db": empty])
        // Doubles a string to 8 MB.
        let doubling = "WITH RECURSIVE c(s, n) AS (SELECT 'ab', 0 UNION ALL SELECT s || s, n + 1 FROM c WHERE n < 22)"
        let narrow = await shell.run("sqlite3 data/a.db \"\(doubling) SELECT length(s) FROM c WHERE n = 22\"")
        #expect(narrow.output == "8388608")
        let columns = Array(repeating: "s", count: 40).joined(separator: ", ")
        let wide = await shell.run("sqlite3 data/a.db \"\(doubling) SELECT \(columns) FROM c WHERE n = 22\"")
        #expect(wide.exitCode == 1)
        #expect(wide.output.contains("select fewer columns"))
    }

    @Test("a driver that streams downloads is used instead of reading the file into memory")
    func streamingDriver() async throws {
        struct StreamingDriver: MountDriver {
            let database: Data
            var info: MountInfo { MountInfo(kind: "api", source: "test") }
            func list(_ directory: EntryRef) async throws -> [DriverEntry] {
                [DriverEntry(name: "remote.db", kind: .file, size: database.count, id: "v1")]
            }
            func read(_ file: EntryRef) async throws -> FileContent { .binary(byteSize: database.count) }
            func readExactBytes(_ file: EntryRef) async throws -> Data {
                throw VFSError.unreadable(path: file.path, reason: "must not be read into memory")
            }
            func download(_ file: EntryRef, to destination: URL) async throws {
                try database.write(to: destination)
            }
        }
        let shop = try database(shopSQL)
        let fileSystem = try workspace("api", driver: StreamingDriver(database: shop))
        let shell = CommandInterpreter(fileSystem: fileSystem, commands: [SQLiteCommand()])
        #expect(await shell.run("sqlite3 api/remote.db 'SELECT count(*) FROM users'").output == "3")
        let small = CommandInterpreter(fileSystem: fileSystem, commands: [SQLiteCommand(maxDownloadBytes: 100)])
        #expect(await small.run("sqlite3 api/remote.db 'SELECT 1'").output.contains("too large"))
    }
}
