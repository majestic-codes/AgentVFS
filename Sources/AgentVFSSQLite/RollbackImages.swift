//
//  RollbackImages.swift
//  AgentVFSSQLite
//
//  Created by Yevhenii Kalashnikov on 30.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import Foundation
import Synchronization

/// Database images in memory in a form SQLite can open.
///
/// A database in memory has no `-wal` file to read, and SQLite opens a database file written in
/// write-ahead-log format only with one. Such an image is read as of its last checkpoint, as a
/// rollback-journal database, which takes a copy with the two format version bytes changed. The
/// copy is made once per file version and kept, one version per file, within `capacity` bytes.
final class RollbackImages: Sendable {
    private struct Entry {
        let version: String
        let image: Data
    }

    private let cache: Mutex<LRUCache<String, Entry>>

    init(capacity: Int) {
        cache = Mutex(LRUCache(capacity: capacity))
    }

    /// The database in `lease`, readable by SQLite: files on disk and images already in
    /// rollback-journal format as they are.
    func readable(_ lease: DownloadCache.Lease) -> DownloadCache.Source {
        let location = lease.location
        let version = lease.version
        guard case let .data(data) = lease.source, Self.isWriteAheadLog(data) else { return lease.source }
        guard let version else { return .data(Self.rollbackJournalImage(of: data)) }
        if let cached = cache.withLock({ $0.value(for: location) }), cached.version == version {
            return .data(cached.image)
        }
        let image = Self.rollbackJournalImage(of: data)
        cache.withLock { $0.insert(Entry(version: version, image: image), cost: image.count, for: location) }
        return .data(image)
    }

    static func isWriteAheadLog(_ data: Data) -> Bool {
        data.count > 19 && (data[data.startIndex + 18] == 2 || data[data.startIndex + 19] == 2)
    }

    static func rollbackJournalImage(of data: Data) -> Data {
        var image = data
        image[image.startIndex + 18] = 1
        image[image.startIndex + 19] = 1
        return image
    }
}
