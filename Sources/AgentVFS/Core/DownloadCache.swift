//
//  DownloadCache.swift
//  AgentVFS
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation
import Synchronization

/// Workspace files for tools that parse a file format themselves (`sqlite3`, the PDF commands).
/// A file a driver keeps on disk is opened in place, and a file a driver keeps in memory is handed
/// through as it is. Any other file is read once into memory, kept by file version, one version per
/// path, and bounded by total size. Nothing is written to disk.
public final class DownloadCache: Sendable {
    /// Where a tool reads a file from.
    public enum Source: Sendable {
        /// A file on disk, opened and checked by its driver and kept open while the source is alive.
        case file(LocalFile)
        /// The file's bytes. They never change while a tool uses them.
        case data(Data)
    }

    /// A file to read and the version it was read at.
    public struct Lease: Sendable {
        /// The file itself.
        public let source: Source
        /// Names the file within its workspace. Unlike `version`, it stays the same when the
        /// file's content changes.
        public let location: String
        /// The file's version, unique to its workspace and path, or `nil` when the source cannot
        /// tell. Results computed from the file may be cached under it.
        public let version: String?
    }

    private struct Entry {
        let version: String
        let data: Data
    }

    /// Keyed by the file's location, so a new version replaces the old one.
    private let cache: Mutex<LRUCache<String, Entry>>

    /// - Parameter capacity: Memory in bytes kept for files read from drivers. A file larger than
    ///   this is read for one use and not kept.
    public init(capacity: Int) {
        cache = Mutex(LRUCache(capacity: capacity))
    }

    /// The file at `path`: in place when its driver has it on the local disk, as the driver's own
    /// bytes when it holds files in memory, otherwise cached or newly read into memory. Throws
    /// `VFSError.fileTooLarge` for a file over `maxBytes`.
    public func lease(path: String, fileSystem: WorkspaceFileSystem, maxBytes: Int) async throws -> Lease {
        let resolved = try await fileSystem.resolveFile(path)
        let version = resolved.version
        if let localFile = try await fileSystem.openLocalFile(path: path) {
            return Lease(source: .file(localFile), location: resolved.location, version: version)
        }
        // Without a version there is no way to tell whether the file changed, so it is read
        // for this use only. Versions are unique to their workspace and path.
        if let version, let cached = cache.withLock({ $0.value(for: resolved.location) }), cached.version == version {
            return Lease(source: .data(cached.data), location: resolved.location, version: version)
        }
        let file = try await fileSystem.readBinary(path: path, maxBytes: maxBytes)
        guard let version, file.version == version else {
            return Lease(source: .data(file.data), location: resolved.location, version: nil)
        }
        if resolved.mount.driver.holdsFilesInMemory == false {
            let entry = Entry(version: version, data: file.data)
            cache.withLock { $0.insert(entry, cost: file.data.count, for: resolved.location) }
        }
        return Lease(source: .data(file.data), location: resolved.location, version: version)
    }
}
