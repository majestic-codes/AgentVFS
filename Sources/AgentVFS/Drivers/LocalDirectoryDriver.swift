//
//  LocalDirectoryDriver.swift
//  AgentVFS
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Darwin
import Foundation

/// Mounts a directory on the local disk, read-only.
///
/// Symbolic links are listed but never followed, and files with more than one hard link are not
/// read, so nothing outside `root` is reachable.
/// Listings are cached by the workspace for its lifetime, until `WorkspaceFileSystem.refresh`. A file
/// whose size on disk no longer matches its listing is refused, so a file that grew cannot pass the
/// read limits checked against the listing.
public struct LocalDirectoryDriver: MountDriver {
    /// The mounted directory, by its real path: links resolved and in the letter case the disk stores.
    public let root: URL
    /// Names skipped at every level, such as `.git` or `node_modules`.
    public let excludedNames: Set<String>

    /// Version control and build output, which only add noise for an agent.
    public static let defaultExcludedNames: Set<String> = [
        ".git", ".build", ".swiftpm", "node_modules", "DerivedData", ".DS_Store"
    ]

    /// Mounts the directory at `root`. Throws `VFSError.invalidConfiguration` when it is not a
    /// directory that can be opened.
    public init(root: URL, excludedNames: Set<String> = Self.defaultExcludedNames) throws {
        // The path as the file system itself spells it, with links resolved and the stored letter
        // case, so it can be compared with the real paths of opened files.
        let descriptor = Darwin.open(root.standardizedFileURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard descriptor >= 0 else {
            throw VFSError.invalidConfiguration("\(root.path) is not a directory")
        }
        defer { close(descriptor) }
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0, let realPath = Self.path(from: buffer) else {
            throw VFSError.invalidConfiguration("\(root.path) cannot be opened")
        }
        self.root = URL(fileURLWithPath: realPath, isDirectory: true)
        self.excludedNames = excludedNames
    }

    /// Mounts the directory at `path`, where a leading `~` is the home directory.
    public init(path: String, excludedNames: Set<String> = Self.defaultExcludedNames) throws {
        let expanded = Self.expandingHome(in: path)
        try self.init(root: URL(fileURLWithPath: expanded, isDirectory: true), excludedNames: excludedNames)
    }

    /// The path in a NUL-terminated buffer filled by `F_GETPATH`, or `nil` when it is not UTF-8.
    private static func path(from buffer: [CChar]) -> String? {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(validating: bytes, as: UTF8.self)
    }

    /// Replaces a leading `~` or `~/` with the home directory.
    private static func expandingHome(in path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return URL.homeDirectory.path + path.dropFirst()
    }

    public var info: MountInfo {
        MountInfo(kind: "local", source: root.path, summary: "local directory \(root.lastPathComponent)")
    }

    public var listingIsCheap: Bool { true }

    public func list(_ directory: EntryRef) async throws -> [DriverEntry] {
        let descriptor = try open(directory.path, directory: true)
        guard let stream = fdopendir(descriptor) else {
            close(descriptor)
            throw VFSError.notFound(directory.path)
        }
        defer { closedir(stream) }
        var children: [DriverEntry] = []
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(cString: Array(raw.bindMemory(to: CChar.self)))
            }
            guard name != ".", name != "..", !excludedNames.contains(name) else { continue }
            // Each entry is examined relative to the directory already opened, and never followed.
            var status = stat()
            guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            switch status.st_mode & S_IFMT {
            case S_IFLNK:
                children.append(DriverEntry(name: name, kind: .symbolicLink))
            case S_IFDIR:
                children.append(DriverEntry(name: name, kind: .directory))
            case S_IFREG:
                let id = Self.id(of: status)
                children.append(DriverEntry(name: name, kind: .file, size: Int(status.st_size), id: id))
            default:
                // Sockets, pipes and devices are not files an agent can read.
                continue
            }
        }
        return children
    }

    /// Identifies a file's content: the same file with the same size and modification time.
    private static func id(of status: stat) -> String {
        let modified = "\(status.st_mtimespec.tv_sec).\(status.st_mtimespec.tv_nsec)"
        return "\(status.st_dev):\(status.st_ino):\(status.st_size):\(modified)"
    }

    public func read(_ file: EntryRef) async throws -> FileContent {
        let data = try contents(of: file)
        return FileContent.classify(data)
    }

    public func readExactBytes(_ file: EntryRef) async throws -> Data {
        try contents(of: file)
    }

    /// Opened and checked the same way as a read.
    public func openLocalFile(for file: EntryRef) throws -> LocalFile? {
        let descriptor = try open(file)
        return LocalFile(descriptor: descriptor)
    }

    private func contents(of file: EntryRef) throws -> Data {
        let descriptor = try open(file)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            return try handle.readToEnd() ?? Data()
        } catch {
            throw VFSError.unreadable(path: file.path, reason: error.localizedDescription)
        }
    }

    /// Opens a file and checks that its size still matches the listing.
    private func open(_ file: EntryRef) throws -> Int32 {
        let descriptor = try open(file.path, directory: false)
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            close(descriptor)
            throw VFSError.notFound(file.path)
        }
        if let size = file.size, Int(status.st_size) != size {
            close(descriptor)
            let reason = "the file changed after the workspace listed it (\(size) bytes then, \(status.st_size) now)"
            throw VFSError.unreadable(path: file.path, reason: reason)
        }
        return descriptor
    }

    /// Opens a file or directory of the mount without following symbolic links, and checks that
    /// what was opened really lies inside `root`.
    ///
    /// Listing and reading are separate steps, so a file could be swapped for a link between
    /// them. `O_NOFOLLOW` refuses a link in the last component. The real path of the opened
    /// descriptor catches a directory higher up that became a link. A file with a second hard link
    /// may be the same file as one outside `root`, so it is refused.
    private func open(_ path: String, directory: Bool) throws -> Int32 {
        let url = try fileURL(path)
        let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (directory ? O_DIRECTORY : 0)
        let descriptor = Darwin.open(url.path, flags)
        guard descriptor >= 0 else {
            throw errno == ELOOP ? VFSError.symbolicLink(path: path) : VFSError.notFound(path)
        }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var status = stat()
        let real = fcntl(descriptor, F_GETPATH, &buffer) == 0 ? Self.path(from: buffer) : nil
        let expected: mode_t = directory ? S_IFDIR : S_IFREG
        guard let real, real == root.path || real.hasPrefix(rootPrefix),
              fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == expected
        else {
            close(descriptor)
            throw VFSError.notFound(path)
        }
        guard directory || status.st_nlink == 1 else {
            close(descriptor)
            let reason = "the file has \(status.st_nlink) hard links, so it may be a file from outside the mount"
            throw VFSError.unreadable(path: path, reason: reason)
        }
        return descriptor
    }

    /// The root path with a trailing slash, which every path inside it starts with.
    private var rootPrefix: String { root.path.hasSuffix("/") ? root.path : root.path + "/" }

    /// The file's URL, or `nil` for a path with `.` or `..` components.
    public func link(to path: String, line: Int?) -> URL? {
        Self.isPlain(path) ? url(of: path) : nil
    }

    /// The file URL for a mount path. Throws `VFSError.outsideWorkspace` for a path with `.` or `..` components.
    private func fileURL(_ path: String) throws -> URL {
        guard Self.isPlain(path) else { throw VFSError.outsideWorkspace(path) }
        return url(of: path)
    }

    private static func isPlain(_ path: String) -> Bool {
        !path.split(separator: "/").contains { $0 == ".." || $0 == "." }
    }

    private func url(of path: String) -> URL {
        path.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
    }
}
