//
//  DownloadCache.swift
//  AgentVFS
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation
import Synchronization

/// Workspace files on the local disk, for tools that open a file themselves (`sqlite3`, the PDF
/// commands). A file a driver keeps on disk is opened in place. Any other file is downloaded once
/// into a temporary file, kept by file version and bounded by total size. A temporary file is
/// deleted once it is evicted and no lease uses it, and all of them when the cache goes.
public final class DownloadCache: Sendable {
    /// A file on disk to open. Call `finish` once the tool is done with it. Copies of a lease share
    /// it, so only the first `finish` of any copy releases the file.
    public struct Lease: Sendable {
        /// The file itself, to open read-only.
        public let url: URL
        /// `true` for a downloaded copy, which never changes while it is open.
        public let isCopy: Bool
        /// The file's version, unique to its workspace and path, or `nil` when the source cannot
        /// tell. Results computed from the file may be cached under it.
        public let version: String?
        /// Keeps an in-place file open, so `url` names the file the driver checked.
        let localFile: LocalFile?
        private let release: Release

        init(
            url: URL,
            isCopy: Bool,
            version: String?,
            localFile: LocalFile?,
            onFinish: @escaping @Sendable () -> Void
        ) {
            self.url = url
            self.isCopy = isCopy
            self.version = version
            self.localFile = localFile
            self.release = Release(onFinish)
        }

        /// Releases the file, deleting a copy that is no longer cached. Calls after the first do nothing.
        public func finish() { release.run() }
    }

    /// Runs an action once, however often it is asked to.
    private final class Release: Sendable {
        private let pending: Mutex<(@Sendable () -> Void)?>

        init(_ action: @escaping @Sendable () -> Void) {
            pending = Mutex(action)
        }

        func run() {
            let action = pending.withLock { pending -> (@Sendable () -> Void)? in
                defer { pending = nil }
                return pending
            }
            action?()
        }
    }

    private let state: Mutex<State>
    private let directoryName: String

    private struct Entry {
        let key: String
        let url: URL
        let bytes: Int
        var leases = 0
    }

    private struct State {
        var entries: [Entry] = []
        /// Evicted files still leased, deleted when their last lease finishes.
        var retired: [URL: Int] = [:]
        var totalBytes = 0
        let capacity: Int
    }

    /// - Parameters:
    ///   - capacity: Disk space in bytes kept for downloaded files.
    ///   - label: Names the temporary directory, such as `"SQLite"`.
    public init(capacity: Int, label: String) {
        state = Mutex(State(capacity: capacity))
        directoryName = "AgentVFS\(label)-\(UUID().uuidString)"
    }

    deinit {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(directoryName)
        // `try?` exception: best-effort cleanup in `deinit`.
        try? FileManager.default.removeItem(at: directory)
    }

    /// The directory for downloads, by its real path: tools may refuse links (SQLite opens with
    /// SQLITE_OPEN_NOFOLLOW) and the temporary directory sits behind one on Apple platforms.
    private func directory() throws -> URL {
        let temporary = FileManager.default.temporaryDirectory.path
        guard let pointer = realpath(temporary, nil) else {
            throw VFSError.unreadable(path: temporary, reason: "the temporary directory cannot be resolved")
        }
        defer { free(pointer) }
        return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// The file at `path` on the local disk: in place when its driver has it there, otherwise a
    /// cached or new download. Throws `VFSError.fileTooLarge` for a download over `maxBytes`.
    public func lease(path: String, fileSystem: WorkspaceFileSystem, maxBytes: Int) async throws -> Lease {
        let version = try await fileSystem.version(path: path)
        if let localFile = try await fileSystem.openLocalFile(path: path) {
            return Lease(url: localFile.url, isCopy: false, version: version, localFile: localFile) {}
        }
        // Without a version there is no way to tell whether the file changed, so it is downloaded
        // for this use only. Versions are unique to their workspace and path.
        if let version, let cached = leaseCached(version) {
            return cached
        }
        let directory = try directory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString)
        let downloaded: String?
        do {
            downloaded = try await fileSystem.download(path: path, to: url, maxBytes: maxBytes)
        } catch {
            Self.discard(url)
            throw error
        }
        guard let version, downloaded == version else {
            return Lease(url: url, isCopy: true, version: nil, localFile: nil) { Self.discard(url) }
        }
        guard let bytes = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int else {
            Self.discard(url)
            throw VFSError.unreadable(path: path, reason: "the downloaded copy has no size")
        }
        return store(Entry(key: version, url: url, bytes: bytes))
    }

    private func leaseCached(_ key: String) -> Lease? {
        let url = state.withLock { state -> URL? in
            guard let index = state.entries.firstIndex(where: { $0.key == key }) else { return nil }
            var entry = state.entries.remove(at: index)
            entry.leases += 1
            state.entries.append(entry)
            return entry.url
        }
        return url.map { cachedLease($0, version: key) }
    }

    /// Adds a new download, or leases the copy another call stored for the same key meanwhile.
    private func store(_ entry: Entry) -> Lease {
        let (url, deletable) = state.withLock { state -> (URL, [URL]) in
            if let index = state.entries.firstIndex(where: { $0.key == entry.key }) {
                state.entries[index].leases += 1
                return (state.entries[index].url, [entry.url])
            }
            var leased = entry
            leased.leases = 1
            state.entries.append(leased)
            state.totalBytes += entry.bytes
            var deletable: [URL] = []
            // The newest entry stays even when it alone is over the limit. It is in use.
            while state.totalBytes > state.capacity, state.entries.count > 1 {
                let oldest = state.entries.removeFirst()
                state.totalBytes -= oldest.bytes
                if oldest.leases > 0 {
                    state.retired[oldest.url] = oldest.leases
                } else {
                    deletable.append(oldest.url)
                }
            }
            return (entry.url, deletable)
        }
        deletable.forEach(Self.discard)
        return cachedLease(url, version: entry.key)
    }

    private func cachedLease(_ url: URL, version: String) -> Lease {
        Lease(url: url, isCopy: true, version: version, localFile: nil) { [self] in release(url) }
    }

    private func release(_ url: URL) {
        let isDeletable = state.withLock { state -> Bool in
            if let index = state.entries.firstIndex(where: { $0.url == url }) {
                state.entries[index].leases -= 1
                return false
            }
            guard let leases = state.retired[url] else { return false }
            if leases > 1 {
                state.retired[url] = leases - 1
                return false
            }
            state.retired[url] = nil
            return true
        }
        if isDeletable { Self.discard(url) }
    }

    /// Deletes a temporary file. A file that is already gone, or cannot be deleted, only costs
    /// disk space until the cache goes.
    private static func discard(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            return
        }
    }
}
