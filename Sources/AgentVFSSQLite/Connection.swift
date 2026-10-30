//
//  Connection.swift
//  AgentVFSSQLite
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import Foundation
import SQLite3

/// A read-only connection to one database file, closed when it goes.
final class Connection {
    private var handle: OpaquePointer?
    private let watchdog: Watchdog
    private let temporarySpace: TemporarySpace
    /// The largest value the running statement may hold, from `maxValueBytes` and `maxRowBytes`.
    private var valueLimit = maxValueBytes

    /// Runs `body` on a read-only connection to the database in `source`, then closes it. A
    /// database in memory is read where it is, so it stays pinned while the connection is open. A
    /// database in memory must not be in write-ahead-log format (see `RollbackImages`).
    static func withConnection<Result>(
        source: DownloadCache.Source,
        watchdog: Watchdog,
        maxTemporaryBytes: Int,
        _ body: (Connection) throws -> Result
    ) throws -> Result {
        switch source {
        case let .file(localFile):
            let connection = try Connection(
                file: localFile.url,
                watchdog: watchdog,
                maxTemporaryBytes: maxTemporaryBytes
            )
            return try withExtendedLifetime(connection) { try body(connection) }
        case let .data(data):
            return try data.withUnsafeBytes { bytes in
                let connection = try Connection(
                    memory: bytes,
                    watchdog: watchdog,
                    maxTemporaryBytes: maxTemporaryBytes
                )
                return try withExtendedLifetime(connection) { try body(connection) }
            }
        }
    }

    private init(watchdog: Watchdog, maxTemporaryBytes: Int) throws {
        self.watchdog = watchdog
        temporarySpace = try TemporarySpace(limit: maxTemporaryBytes)
    }

    /// Opens a database file in place, read-only. It is first opened normally and falls back to
    /// immutable when that needs files that cannot be opened read-only. Its `-wal` file is never
    /// found next to the descriptor it is opened through, so it is read as of its last checkpoint.
    private convenience init(file: URL, watchdog: Watchdog, maxTemporaryBytes: Int) throws {
        try self.init(watchdog: watchdog, maxTemporaryBytes: maxTemporaryBytes)
        do {
            try open(file, immutable: false)
        } catch let first as SQLiteError where !watchdog.expired {
            sqlite3_close_v2(handle)
            handle = nil
            do {
                try open(file, immutable: true)
            } catch {
                // The first error describes the file better than the fallback's.
                throw first
            }
        }
    }

    /// Opens a database held in `bytes`, read-only, without a copy. `bytes` must stay valid and
    /// unchanged until the connection is closed.
    private convenience init(memory bytes: UnsafeRawBufferPointer, watchdog: Watchdog, maxTemporaryBytes: Int) throws {
        try self.init(watchdog: watchdog, maxTemporaryBytes: maxTemporaryBytes)
        guard let start = bytes.baseAddress else { throw SQLiteError(message: "cannot open the database") }
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_MEMORY
        guard sqlite3_open_v2(":memory:", &handle, flags, temporarySpace.name) == SQLITE_OK, let handle else {
            throw SQLiteError(message: lastError)
        }
        let size = Int64(bytes.count)
        let mutableStart = UnsafeMutablePointer(mutating: start.assumingMemoryBound(to: UInt8.self))
        let status = sqlite3_deserialize(handle, "main", mutableStart, size, size, UInt32(SQLITE_DESERIALIZE_READONLY))
        guard status == SQLITE_OK else { throw SQLiteError(message: lastError) }
        try restrict()
    }

    private func open(_ file: URL, immutable: Bool) throws {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#%"))
        guard let path = file.path.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw SQLiteError(message: "cannot open the database")
        }
        let uri = "file:\(path)?mode=ro" + (immutable ? "&immutable=1" : "")
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOFOLLOW
        guard sqlite3_open_v2(uri, &handle, flags, temporarySpace.name) == SQLITE_OK, let handle else {
            throw SQLiteError(message: lastError)
        }
        try restrict()
    }

    /// Limits what the opened database may do and checks that it can be read.
    private func restrict() throws {
        guard let handle else { throw SQLiteError(message: "cannot open the database") }
        // Nothing but this one database may be reached, and no value may grow without bound.
        sqlite3_limit(handle, SQLITE_LIMIT_ATTACHED, 0)
        sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, Int32(Self.maxValueBytes))
        // Functions the schema names run only when harmless. Sorting spills past a small cache to
        // temporary files, which `TemporarySpace` caps. These run before the authorizer is installed.
        let settings = "PRAGMA trusted_schema = OFF; PRAGMA temp_store = FILE; PRAGMA cache_size = -8000;"
        guard sqlite3_exec(handle, settings, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError(message: lastError)
        }
        sqlite3_set_authorizer(handle, Self.authorizer, nil)
        sqlite3_progress_handler(handle, 1000, Self.progressHandler, Unmanaged.passUnretained(watchdog).toOpaque())
        // Opening is lazy. Reading the schema shows now whether the file can really be read.
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, "SELECT count(*) FROM sqlite_schema", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW
        else {
            throw SQLiteError(message: lastError)
        }
    }

    deinit {
        sqlite3_close_v2(handle)
        temporarySpace.close()
    }

    /// Largest string or blob a query may hold.
    static let maxValueBytes = 16_000_000
    /// Largest sum of the values in one result row: a row of many columns gets a smaller limit
    /// per value, because SQLite builds the whole row in memory before returning it.
    static let maxRowBytes = 32_000_000

    private var lastError: String {
        if watchdog.cancelled { return "query interrupted: the command was cancelled" }
        if watchdog.expired { return "query interrupted: it ran longer than the time limit" }
        if temporarySpace.exceeded {
            let limit = temporarySpace.limit
            return "the query needs more than \(limit) bytes of temporary space to sort or group; "
                + "add a WHERE or select fewer columns"
        }
        guard let handle else { return "cannot open the database" }
        let message = String(cString: sqlite3_errmsg(handle))
        return switch sqlite3_errcode(handle) {
        case SQLITE_AUTH:
            message + " (sqlite3 here only reads: SELECT, WITH and read-only PRAGMAs such as table_info)"
        case SQLITE_TOOBIG:
            message + " (a value over \(valueLimit) bytes; select fewer columns or a substr() of the value)"
        default:
            message
        }
    }

    /// Runs SQL, or one of the dot commands `.tables`, `.schema` and `.indexes`.
    func execute(_ input: String, into renderer: inout Renderer) throws {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(".") {
            try dotCommand(trimmed, into: &renderer)
        } else {
            try run(trimmed, into: &renderer)
        }
    }

    private func dotCommand(_ line: String, into renderer: inout Renderer) throws {
        let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count <= 2 else {
            let extra = words.dropFirst().joined(separator: " ")
            throw SQLiteError(message: "\(words[0]) takes at most one pattern, not '\(extra)'")
        }
        let argument = words.count > 1 ? Self.literal(words[1]) : nil
        switch words[0] {
        case ".tables", ".table":
            let filter = argument.map { " AND name LIKE \($0)" } ?? ""
            let sql = "SELECT name FROM sqlite_schema WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%'"
                + filter + " ORDER BY name"
            var names: [String] = []
            try query(sql) { names.append($0[0].plain(null: "")) }
            renderer.lines(names)
        case ".schema", ".fullschema":
            let filter = argument.map { " AND (name LIKE \($0) OR tbl_name LIKE \($0))" } ?? ""
            let sql = "SELECT sql FROM sqlite_schema WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'"
                + filter + " ORDER BY tbl_name, type DESC, name"
            var statements: [String] = []
            try query(sql) { statements.append($0[0].plain(null: "") + ";") }
            renderer.lines(statements)
        case ".indexes", ".indices":
            let filter = argument.map { " AND tbl_name LIKE \($0)" } ?? ""
            let sql = "SELECT name FROM sqlite_schema WHERE type = 'index'" + filter + " ORDER BY name"
            try run(sql, into: &renderer)
        case ".help":
            throw SQLiteError(message: "supported dot commands: .tables [PATTERN], .schema [TABLE], .indexes [TABLE]")
        default:
            let hint = "use .tables, .schema [TABLE], .indexes [TABLE] or SQL"
            throw SQLiteError(message: "unsupported dot command \(words[0]); \(hint)")
        }
    }

    /// A SQL string literal.
    private static func literal(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private func query(_ sql: String, row: @escaping ([Value]) -> Void) throws {
        var collector = Renderer(mode: .list, header: false, separator: nil, nullValue: "", budget: .max)
        try statements(sql, into: &collector, each: row)
    }

    private func run(_ sql: String, into renderer: inout Renderer) throws {
        try statements(sql, into: &renderer, each: nil)
    }

    /// Prepares and steps every statement in `sql` in turn.
    private func statements(_ sql: String, into renderer: inout Renderer, each: (([Value]) -> Void)?) throws {
        let utf8 = Array(sql.utf8CString)
        try utf8.withUnsafeBufferPointer { buffer in
            guard let start = buffer.baseAddress else { throw SQLiteError(message: "no SQL to run") }
            var cursor = start
            let end = start + buffer.count - 1
            while cursor < end {
                var statement: OpaquePointer?
                var tail: UnsafePointer<CChar>?
                guard sqlite3_prepare_v2(handle, cursor, Int32(end - cursor), &statement, &tail) == SQLITE_OK else {
                    throw SQLiteError(message: lastError)
                }
                defer { sqlite3_finalize(statement) }
                guard let tail, tail > cursor else { break }
                cursor = tail
                guard let statement else { continue }
                let columns = max(Int(sqlite3_column_count(statement)), 1)
                valueLimit = min(Self.maxValueBytes, Self.maxRowBytes / columns)
                sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, Int32(valueLimit))
                try step(statement, into: &renderer, each: each)
                if renderer.exhausted { break }
            }
        }
    }

    /// Steps one prepared statement to its end, or until the renderer wants no more rows.
    private func step(_ statement: OpaquePointer, into renderer: inout Renderer, each: (([Value]) -> Void)?) throws {
        let count = sqlite3_column_count(statement)
        renderer.begin(columns: (0..<count).map { String(cString: sqlite3_column_name(statement, $0)) })
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw SQLiteError(message: lastError) }
            // A cell is read only as far as the output can still show, plus one byte to tell it was cut.
            var bytesLeft = renderer.bytesLeft
            var row: [Value] = []
            for column in 0..<count {
                let value = try value(statement, column, maxBytes: bytesLeft == .max ? .max : bytesLeft + 1)
                bytesLeft = max(0, bytesLeft - value.byteCount)
                row.append(value)
            }
            if let each {
                each(row)
            } else if !renderer.add(row) {
                break
            }
        }
        renderer.end()
    }

    /// One cell, with text cut to its first `maxBytes` bytes and blobs to the start they are shown by.
    private func value(_ statement: OpaquePointer, _ column: Int32, maxBytes: Int) throws -> Value {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, column))
        case SQLITE_TEXT:
            let pointer = sqlite3_column_text(statement, column)
            let size = Int(sqlite3_column_bytes(statement, column))
            guard size > 0 else { return .text("") }
            guard let pointer else { throw SQLiteError(message: lastError) }
            let bytes = UnsafeBufferPointer(start: pointer, count: min(size, maxBytes))
            return .text(String(repairingUTF8: bytes))
        case SQLITE_BLOB:
            let pointer = sqlite3_column_blob(statement, column)
            let size = Int(sqlite3_column_bytes(statement, column))
            guard size > 0 else { return .blob(prefix: Data(), count: 0) }
            guard let pointer else { throw SQLiteError(message: lastError) }
            return .blob(prefix: Data(bytes: pointer, count: min(size, Value.shownBlobBytes)), count: size)
        default:
            return .null
        }
    }
}
