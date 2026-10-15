//
//  SQLiteFixtures.swift
//  AgentVFSSQLiteTests
//
//  Created by Yevhenii Kalashnikov on 15.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import Foundation
import SQLite3
import Testing

/// A new directory under the temporary directory, deleted with this value.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        let name = "AgentVFSSQLiteTests-\(UUID().uuidString)"
        url = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        // `try?` exception: best-effort cleanup in `deinit`.
        try? FileManager.default.removeItem(at: url)
    }
}

/// Builds a database file with the real SQLite library and returns its bytes.
func database(_ sql: String, wal: Bool = false) throws -> Data {
    let directory = try TemporaryDirectory()
    defer { extendLifetime(directory) }
    let url = directory.url.appendingPathComponent("test.db")
    var handle: OpaquePointer?
    try #require(sqlite3_open(url.path, &handle) == SQLITE_OK)
    let script = (wal ? "PRAGMA journal_mode=WAL;" : "") + sql
    var error: UnsafeMutablePointer<CChar>?
    let status = sqlite3_exec(handle, script, nil, nil, &error)
    if status != SQLITE_OK {
        let message = try #require(error)
        Issue.record("setup failed: \(String(cString: message))")
    }
    sqlite3_close(handle)
    return try Data(contentsOf: url)
}

let shopSQL = """
CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT, score REAL);
CREATE INDEX users_email ON users(email);
CREATE TABLE orders (id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES users(id), total REAL, note TEXT);
CREATE VIEW big_orders AS SELECT * FROM orders WHERE total > 100;
INSERT INTO users VALUES (1, 'Ann', 'ann@example.com', 4.5), (2, 'Bob', NULL, 3.0),
    (3, 'Chloé, Jr.', 'c@example.com', NULL);
INSERT INTO orders VALUES (1, 1, 250, 'first'), (2, 1, 20, 'small "one"'), (3, 2, 120.5, NULL);
"""

/// A workspace with one mount.
func workspace(_ name: String, driver: any MountDriver) throws -> WorkspaceFileSystem {
    try WorkspaceFileSystem(mounts: [WorkspaceMount(name: name, driver: driver)])
}

/// A workspace that mounts a local directory as `app`.
func localWorkspace(_ root: URL) throws -> WorkspaceFileSystem {
    let driver = try LocalDirectoryDriver(root: root)
    return try workspace("app", driver: driver)
}

/// Counts up from 1 without end, for queries that never finish on their own.
let endlessCounter = "WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c)"
