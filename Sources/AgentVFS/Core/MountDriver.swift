//
//  MountDriver.swift
//  AgentVFS
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

/// One child of a directory, as a driver reports it.
public struct DriverEntry: Sendable, Hashable {
    /// The entry's name in its directory.
    public var name: String
    /// What the entry is.
    public var kind: EntryKind
    /// The size in bytes, when the source knows it.
    public var size: Int?
    /// Opaque identity of this version of the entry: a git SHA, an ETag, a revision number.
    /// Equal ids promise equal content, so the workspace caches content by it. With `nil` the
    /// content is cached by path for the life of the workspace.
    public var id: String?

    /// An entry. The workspace does not list a name with a control, bidirectional or zero-width
    /// character, nor `.`, `..` or one with `/`.
    public init(name: String, kind: EntryKind, size: Int? = nil, id: String? = nil) {
        self.name = name
        self.kind = kind
        self.size = size
        self.id = id
    }
}

/// An entry the workspace asks a driver about.
public struct EntryRef: Sendable, Hashable {
    /// Path inside the mount, without a leading slash. `""` is the mount root.
    public let path: String
    /// The `DriverEntry.id` reported for the entry. `nil` for the mount root.
    public let id: String?
    /// The `DriverEntry.size` reported for the entry.
    public let size: Int?

    /// An entry to ask about.
    public init(path: String, id: String? = nil, size: Int? = nil) {
        self.path = path
        self.id = id
        self.size = size
    }

    /// The mount root.
    public static let root = Self(path: "")

    /// The last path component.
    public var name: String { path.split(separator: "/").last.map(String.init) ?? "" }
}

/// A source of files mounted as one directory under `/workspace`.
///
/// A driver only answers three questions: what is in a directory, what is in a file, and how to
/// describe the source. Paths, caching, `find`, `grep`, output limits and the shell commands are
/// handled by `WorkspaceFileSystem` for every driver alike. Everything is read-only.
///
/// The optional requirements have default implementations. Implement them when the source can
/// do better, for example list a whole tree in one request or search on the server.
public protocol MountDriver: Sendable {
    /// How the mount is described in listings and in the agent's prompt.
    var info: MountInfo { get }

    /// The children of a directory. Throw `VFSError.notFound` when it does not exist.
    func list(_ directory: EntryRef) async throws -> [DriverEntry]

    /// The content of one file.
    func read(_ file: EntryRef) async throws -> FileContent

    // MARK: Optional

    /// Every directory of the mount at once, when that is cheap for the source. Return
    /// `.unsupported` to make the workspace list directories one at a time.
    func listAll() async throws -> DriverListing

    /// Several files at once, keyed by `EntryRef.path`. Files missing from the result count as
    /// unreadable. The default reads them concurrently with `read(_:)`.
    func read(_ files: [EntryRef]) async throws -> [String: FileContent]

    /// The exact bytes of a file: one that `read` returned as `.transcodedText` or `.truncated`, or
    /// a binary file a tool such as `sqlite3` parses itself. The default works for text only.
    func readExactBytes(_ file: EntryRef) async throws -> Data

    /// Paths inside the mount that may contain `term`, from the source's own search index.
    /// `.unsupported` means the source cannot search, so the workspace reads every file.
    func searchCandidates(for term: String) async throws -> SearchCandidates

    /// A link to a file, and optionally a line, for citations.
    func link(to path: String, line: Int?) -> URL?

    /// `true` when listing a directory costs no network request, so walks need no budget.
    var listingIsCheap: Bool { get }

    /// Writes a file's exact bytes to `destination`, for tools that need a large file on disk,
    /// such as `sqlite3` with a database from an API. The default holds the whole file in memory
    /// once (through `readExactBytes`). A driver for large files streams it instead, for example
    /// with `URLSession.download(for:)`.
    func download(_ file: EntryRef, to destination: URL) async throws

    /// The file on the local disk behind an entry, opened, for tools that are better off opening it
    /// in place than reading it whole, such as `sqlite3` with a database of several gigabytes. The
    /// driver vouches that the descriptor is the entry itself, inside the mount and not a link.
    /// `nil`, the default, means the file has no local path and is read through `readExactBytes`.
    func openLocalFile(for file: EntryRef) throws -> LocalFile?

    /// A number that changes whenever the driver's files change, for drivers whose content can
    /// change while the workspace is open (such as a mutable `InMemoryDriver`). The workspace
    /// checks it before each operation and drops what it cached for the mount when it differs.
    /// `nil`, the default, means the content never changes on its own.
    var revision: Int? { get }
}

extension MountDriver {
    /// Returns `.unsupported`, so the workspace lists directories one at a time.
    public func listAll() async throws -> DriverListing { .unsupported }

    /// Reads the files with `read(_:)`, at most eight at a time. Files that are not found are left out.
    public func read(_ files: [EntryRef]) async throws -> [String: FileContent] {
        try await withThrowingTaskGroup(of: (String, FileContent?).self) { group in
            var iterator = files.makeIterator()
            var inFlight = 0
            while inFlight < 8, let file = iterator.next() {
                group.addTask { (file.path, try await Self.readIfPresent(self, file)) }
                inFlight += 1
            }
            var contents: [String: FileContent] = [:]
            while let (path, content) = try await group.next() {
                contents[path] = content
                if let file = iterator.next() {
                    group.addTask { (file.path, try await Self.readIfPresent(self, file)) }
                }
            }
            return contents
        }
    }

    private static func readIfPresent(_ driver: Self, _ file: EntryRef) async throws -> FileContent? {
        do {
            return try await driver.read(file)
        } catch VFSError.notFound, VFSError.unreadable, VFSError.symbolicLink {
            return nil
        }
    }

    /// Returns the bytes of a text file from `read(_:)`. Throws `VFSError.binaryFile` for a binary file and
    /// `VFSError.unreadable` for a truncated one.
    public func readExactBytes(_ file: EntryRef) async throws -> Data {
        switch try await read(file) {
        case let .text(data), let .transcodedText(data, _):
            return data
        case let .binary(size):
            throw VFSError.binaryFile(path: file.path, size: size)
        case .truncated:
            throw VFSError.unreadable(path: file.path, reason: "the source returned only part of the file")
        }
    }

    /// Returns `.unsupported`: the source has no search index.
    public func searchCandidates(for term: String) async throws -> SearchCandidates { .unsupported }

    /// Returns `nil`: the source has no links.
    public func link(to path: String, line: Int?) -> URL? { nil }

    /// `false`: walks over the mount are budgeted.
    public var listingIsCheap: Bool { false }

    /// `nil`: the content never changes on its own.
    public var revision: Int? { nil }

    /// `nil`: the file has no local path.
    public func openLocalFile(for file: EntryRef) throws -> LocalFile? { nil }

    /// Reads the whole file with `readExactBytes` and writes it to `destination`. Throws
    /// `VFSError.unreadable` when the write fails.
    public func download(_ file: EntryRef, to destination: URL) async throws {
        let data = try await readExactBytes(file)
        do {
            try data.write(to: destination)
        } catch {
            let reason = "could not write \(destination.lastPathComponent): \(error.localizedDescription)"
            throw VFSError.unreadable(path: file.path, reason: reason)
        }
    }
}

/// A driver mounted under a name.
public struct WorkspaceMount: Sendable {
    /// The directory name under `/workspace`.
    public let name: String
    /// The driver that serves the mount.
    public let driver: any MountDriver

    /// A mount. The workspace checks the name with `validate(name:)` when the mount is added.
    public init(name: String, driver: any MountDriver) {
        self.name = name
        self.driver = driver
    }

    /// The driver's description of the mount.
    public var info: MountInfo { driver.info }

    /// Checks that `name` can be a directory name under `/workspace`.
    public static func validate(name: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !name.isEmpty,
              name != ".", name != "..",
              name.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else {
            let message = "mount name '\(name)' may only contain letters, digits, '.', '_' and '-'"
            throw VFSError.invalidConfiguration(message)
        }
    }
}

/// A whole mount's directories, listed in one go.
public enum DriverListing: Sendable {
    /// The source lists directories one at a time.
    case unsupported
    /// Every directory of the mount keyed by path, where `""` is the root.
    case complete([String: [DriverEntry]])
}

/// The answer of a source's own search index.
public enum SearchCandidates: Sendable {
    /// The source cannot search, so every file has to be read.
    case unsupported
    /// The paths inside the mount that may contain the term.
    case paths(Set<String>)
}
