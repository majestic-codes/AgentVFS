//
//  InMemoryDriver.swift
//  AgentVFS
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation
import Synchronization

/// Mounts files held in memory, which can be added, replaced and removed at any time.
///
/// Useful for tests, for files a user hands to the agent during a conversation, and for APIs whose
/// data is small enough to fetch up front: turn the records into text files (Markdown, JSON) and
/// mount them, e.g. `issues/PROJ-42.md`. Changes show up in the workspace on its next operation.
public final class InMemoryDriver: MountDriver {
    /// How the mount is described.
    public let info: MountInfo
    private let links: (@Sendable (String, Int?) -> URL?)?
    private let state: Mutex<State>
    /// Starts every entry id, so two drivers never report the same id for different content.
    private let instanceID = UUID().uuidString

    private struct State {
        /// Contents and the revision each file was last written at, keyed by normalized path.
        var files: [String: (data: Data, revision: Int)] = [:]
        var revision = 0
        /// Rebuilt lazily after a change, when `directoriesAreStale` is set.
        var directories: [String: [DriverEntry]] = [:]
        var directoriesAreStale = true
    }

    /// An empty mount. Add files with `put`.
    ///
    /// - Parameter link: builds a citation link for a path and an optional line.
    public init(
        info: MountInfo = MountInfo(kind: "memory", source: "in-memory files"),
        link: (@Sendable (_ path: String, _ line: Int?) -> URL?)? = nil
    ) {
        self.info = info
        self.links = link
        self.state = Mutex(State())
    }

    /// A mount holding `files`, keyed by path inside the mount, e.g. `docs/intro.md`. Parent
    /// directories are created implicitly. Throws for a path `put` refuses.
    ///
    /// - Parameter link: builds a citation link for a path and an optional line.
    public convenience init(
        files: [String: Data],
        info: MountInfo = MountInfo(kind: "memory", source: "in-memory files"),
        link: (@Sendable (_ path: String, _ line: Int?) -> URL?)? = nil
    ) throws {
        self.init(info: info, link: link)
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            try put(path, data: data)
        }
    }

    /// Text files keyed by path. Throws for a path `put` refuses.
    public convenience init(
        texts: [String: String],
        info: MountInfo = MountInfo(kind: "memory", source: "in-memory files"),
        link: (@Sendable (_ path: String, _ line: Int?) -> URL?)? = nil
    ) throws {
        try self.init(files: texts.mapValues { Data($0.utf8) }, info: info, link: link)
    }

    // MARK: Changing files

    /// Adds or replaces a file. Parent directories are created implicitly. Throws
    /// `VFSError.invalidPath` for a path with an empty, `.` or `..` component, or a name the
    /// workspace would not list (see `WorkspaceFileSystem.list`), and `VFSError.isADirectory` or
    /// `VFSError.notADirectory` when a file and a directory would share a path.
    public func put(_ path: String, data: Data) throws {
        let normalized = try Self.normalize(path)
        try state.withLock { state in
            if state.files[normalized] == nil {
                try Self.checkNoConflict(normalized, in: state.files)
            }
            state.revision += 1
            state.files[normalized] = (data, state.revision)
            state.directoriesAreStale = true
        }
    }

    /// Adds or replaces a text file, like `put(_:data:)`.
    public func put(_ path: String, text: String) throws {
        try put(path, data: Data(text.utf8))
    }

    /// Removes a file, or a directory with everything in it. Returns `false` if nothing was there.
    @discardableResult
    public func remove(_ path: String) throws -> Bool {
        let normalized = try Self.normalize(path)
        return state.withLock { state in
            let prefix = normalized + "/"
            let doomed = state.files.keys.filter { $0 == normalized || $0.hasPrefix(prefix) }
            guard !doomed.isEmpty else { return false }
            for key in doomed { state.files[key] = nil }
            state.revision += 1
            state.directoriesAreStale = true
            return true
        }
    }

    /// Paths of every file, sorted.
    public var paths: [String] {
        state.withLock { $0.files.keys.sorted() }
    }

    private static func normalize(_ path: String) throws -> String {
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty, parts.allSatisfy(DriverEntry.isPrintable(name:)) else {
            throw VFSError.invalidPath("'\(path)' is not a file path the workspace can show")
        }
        return parts.joined(separator: "/")
    }

    /// A file cannot share its path with a directory, in either direction.
    private static func checkNoConflict(_ path: String, in files: [String: (data: Data, revision: Int)]) throws {
        let prefix = path + "/"
        if files.keys.contains(where: { $0.hasPrefix(prefix) }) {
            throw VFSError.isADirectory(path)
        }
        var parent = path
        while let slash = parent.lastIndex(of: "/") {
            parent = String(parent[..<slash])
            if files[parent] != nil { throw VFSError.notADirectory(parent) }
        }
    }

    private func buildDirectories(_ files: [String: (data: Data, revision: Int)]) -> [String: [DriverEntry]] {
        var directories: [String: [DriverEntry]] = ["": []]
        for (path, file) in files {
            let parts = path.split(separator: "/").map(String.init)
            var parent = ""
            for directory in parts.dropLast() {
                let child = parent.isEmpty ? directory : parent + "/" + directory
                if directories[child] == nil {
                    directories[parent, default: []].append(DriverEntry(name: directory, kind: .directory))
                    directories[child] = []
                }
                parent = child
            }
            let id = "\(instanceID):\(path)@\(file.revision)"
            let entry = DriverEntry(name: parts[parts.count - 1], kind: .file, size: file.data.count, id: id)
            directories[parent, default: []].append(entry)
        }
        return directories
    }

    // MARK: MountDriver

    public var listingIsCheap: Bool { true }

    public var revision: Int? { state.withLock { $0.revision } }

    private var directories: [String: [DriverEntry]] {
        state.withLock { state in
            if state.directoriesAreStale {
                state.directories = buildDirectories(state.files)
                state.directoriesAreStale = false
            }
            return state.directories
        }
    }

    public func listAll() async throws -> DriverListing { .complete(directories) }

    public func list(_ directory: EntryRef) async throws -> [DriverEntry] {
        guard let children = directories[directory.path] else { throw VFSError.notFound(directory.path) }
        return children
    }

    public func read(_ file: EntryRef) async throws -> FileContent {
        let data = try bytes(of: file)
        return FileContent.classify(data)
    }

    public func readExactBytes(_ file: EntryRef) async throws -> Data {
        try bytes(of: file)
    }

    private func bytes(of file: EntryRef) throws -> Data {
        guard let data = state.withLock({ $0.files[file.path]?.data }) else { throw VFSError.notFound(file.path) }
        return data
    }

    public func link(to path: String, line: Int?) -> URL? {
        links?(path, line)
    }
}
