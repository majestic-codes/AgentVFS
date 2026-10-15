//
//  SQLiteCommand.swift
//  AgentVFSSQLite
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import Foundation

/// `sqlite3 [OPTIONS] FILE [SQL]`: read-only queries over SQLite databases in the workspace.
///
/// A local database is opened in place and read as of its last checkpoint, any other one is
/// downloaded once. Queries may only read this one database, within a time limit and caps on
/// temporary space and row size.
public struct SQLiteCommand: WorkspaceCommand {
    public let name = "sqlite3"
    public let usage = Self.synopsis + "   query a SQLite database (read-only)"

    static let synopsis = "sqlite3 [-header] [-csv|-json|-line|-column] FILE [SQL|.tables|.schema [TABLE]]"

    /// Largest database downloaded from a source without local files. A database the driver
    /// has on the local disk is opened in place, whatever its size. Lower on iOS, because a
    /// driver without a streaming `download` holds the file in memory once while it is fetched.
    public let maxDownloadBytes: Int

    #if os(iOS)
    /// The default `maxDownloadBytes`: lower on iOS, where memory is tighter.
    public static let defaultMaxDownloadBytes = 200_000_000
    /// The default `maxTemporaryBytes`: lower on iOS, where disk space is tighter.
    public static let defaultMaxTemporaryBytes = 64_000_000
    #else
    /// The default `maxDownloadBytes`.
    public static let defaultMaxDownloadBytes = 1_000_000_000
    /// The default `maxTemporaryBytes`.
    public static let defaultMaxTemporaryBytes = 256_000_000
    #endif
    /// Wall-clock limit for one command's queries. The command's own `OutputLimits.timeLimit` applies too.
    public let timeout: Duration
    /// Disk space kept for downloaded databases, so the next query on them needs no new download.
    public let downloadCacheBytes: Int
    /// Bytes one query may write to temporary files, for sorting and grouping. A query that needs
    /// more stops with an error.
    public let maxTemporaryBytes: Int

    private let downloads: DownloadCache

    /// A command with its own download cache. Limits must be positive.
    public init(
        maxDownloadBytes: Int = Self.defaultMaxDownloadBytes,
        timeout: Duration = .seconds(30),
        downloadCacheBytes: Int = 2_000_000_000,
        maxTemporaryBytes: Int = Self.defaultMaxTemporaryBytes
    ) {
        precondition(maxDownloadBytes > 0, "SQLiteCommand.maxDownloadBytes must be positive")
        precondition(timeout > .zero, "SQLiteCommand.timeout must be positive")
        precondition(maxTemporaryBytes > 0, "SQLiteCommand.maxTemporaryBytes must be positive")
        self.maxDownloadBytes = maxDownloadBytes
        self.timeout = timeout
        self.downloadCacheBytes = downloadCacheBytes
        self.maxTemporaryBytes = maxTemporaryBytes
        self.downloads = DownloadCache(capacity: downloadCacheBytes, label: "SQLite")
    }

    public func run(_ arguments: [ShellToken], in context: CommandContext) async throws -> CommandOutput {
        let invocation = try Invocation.parse(arguments)
        let path = try context.resolvePath(invocation.file).description
        var output = CommandOutput()
        let database: DownloadCache.Lease
        do {
            database = try await downloads.lease(path: path, fileSystem: context.fileSystem, maxBytes: maxDownloadBytes)
        } catch let error as VFSError {
            output.fail("sqlite3", context.describe(error), code: 1)
            return output
        }
        defer { database.finish() }
        let isDatabase: Bool
        do {
            isDatabase = try Self.hasHeader(database.url)
        } catch {
            // The error names the file's real location on disk, which the agent does not see.
            output.fail("sqlite3", "\(path): the file cannot be read", code: 1)
            return output
        }
        guard isDatabase else {
            output.fail("sqlite3", "\(path): file is not a database", code: 1)
            return output
        }
        let renderer = Renderer(
            mode: invocation.mode,
            header: invocation.showsHeader,
            separator: invocation.separator,
            nullValue: invocation.nullValue,
            budget: max(1, context.limits.maxBytes - Self.noteReserve),
            lineBudget: context.limits.maxLines - 1
        )
        let watchdog = Connection.Watchdog(deadline: min(ContinuousClock.now + timeout, context.deadline))
        let query = Query(
            file: database.url,
            isCopy: database.isCopy,
            sql: invocation.sql,
            maxTemporaryBytes: maxTemporaryBytes
        )
        let result = await query.run(into: renderer, watchdog: watchdog)
        try Task.checkCancellation()
        output.content(result.renderer.text)
        if let failure = result.failure {
            output.fail("sqlite3", failure.message, code: 1)
        }
        return output
    }

    /// Output bytes kept for the note that the output limit was reached.
    private static let noteReserve = 100

    static let header = Data("SQLite format 3\u{0}".utf8)

    /// Whether the file starts like a SQLite database.
    static func hasHeader(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        let start = Result { try handle.read(upToCount: header.count) }
        try handle.close()
        return try start.get() == header
    }
}

/// One command's queries, run on a thread of their own so a long query holds none of the threads
/// Swift concurrency shares.
private struct Query: Sendable {
    let file: URL
    let isCopy: Bool
    let sql: String
    let maxTemporaryBytes: Int

    private static let queue = DispatchQueue(
        label: "AgentVFSSQLite.queries",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// What was printed, and the error that stopped the queries, if any.
    struct Result: Sendable {
        let renderer: Renderer
        let failure: SQLiteError?
    }

    /// Runs the queries. Cancelling the task interrupts the running statement.
    func run(into renderer: Renderer, watchdog: Connection.Watchdog) async -> Result {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Self.queue.async {
                    continuation.resume(returning: execute(into: renderer, watchdog: watchdog))
                }
            }
        } onCancel: {
            watchdog.cancel()
        }
    }

    private func execute(into renderer: Renderer, watchdog: Connection.Watchdog) -> Result {
        var renderer = renderer
        do {
            let connection = try Connection(
                file: file,
                isCopy: isCopy,
                watchdog: watchdog,
                maxTemporaryBytes: maxTemporaryBytes
            )
            try connection.execute(sql, into: &renderer)
            return Result(renderer: renderer, failure: nil)
        } catch let error as SQLiteError {
            return Result(renderer: renderer, failure: error)
        } catch {
            return Result(renderer: renderer, failure: SQLiteError(message: error.localizedDescription))
        }
    }
}
