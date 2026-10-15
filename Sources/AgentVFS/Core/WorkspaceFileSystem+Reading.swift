//
//  WorkspaceFileSystem+Reading.swift
//  AgentVFS
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

/// A regular file a virtual path resolved to.
struct ResolvedFile {
    let mount: WorkspaceMount
    let entry: DriverEntry
    let path: VFSPath
    /// The workspace's `versionScope`.
    let versionScope: String

    /// What the driver needs to read the file.
    var ref: EntryRef { EntryRef(path: path.mountPath, id: entry.id, size: entry.size) }

    /// Changes whenever the content does, when the source can tell.
    var version: String? { entry.id.map { [versionScope, mount.name, path.mountPath, $0].joined(separator: "\u{0}") } }
}

/// A file's bytes as `readFile` returns them.
struct LoadedFile {
    let data: Data
    let path: VFSPath
    let mount: WorkspaceMount
}

extension WorkspaceFileSystem {
    /// The exact bytes of the file.
    public func read(path: String) async throws -> Data {
        try await readFile(path: path, exactBytes: true).data
    }

    /// Reads a UTF-8 text file together with the information needed to cite it.
    public func readText(path: String) async throws -> TextFile {
        let file = try await readFile(path: path, exactBytes: false)
        return TextFile(
            path: file.path.description,
            mountPath: file.path.mountPath,
            text: String(repairingUTF8: file.data).removingByteOrderMark,
            mount: file.mount.name,
            version: file.mount.info.version,
            url: file.mount.driver.link(to: file.path.mountPath, line: nil)
        )
    }

    /// The exact bytes of any file, binary ones included, for tools that parse a file format
    /// themselves (such as `sqlite3`). `maxBytes` replaces `VFSLimits.maxReadBytes`, since such
    /// files are often larger than anything worth showing as text.
    ///
    /// `BinaryFile.version` changes whenever the content does, when the source can tell.
    public func readBinary(path: String, maxBytes: Int) async throws -> BinaryFile {
        let file = try await resolveFile(path)
        let resolvedPath = file.path
        if let size = file.entry.size, size > maxBytes {
            throw VFSError.fileTooLarge(path: resolvedPath.description, size: size, limit: maxBytes)
        }
        let ref = file.ref
        let data = try await virtualizingErrors(resolvedPath) { try await file.mount.driver.readExactBytes(ref) }
        guard data.count <= maxBytes else {
            throw VFSError.fileTooLarge(path: resolvedPath.description, size: data.count, limit: maxBytes)
        }
        counters.filesRead += 1
        return BinaryFile(path: resolvedPath.description, data: data, version: file.version)
    }

    /// A text file for line-oriented commands. Files up to `VFSLimits.maxReadBytes` are read as
    /// usual. Larger ones are read when they come from a local source and are no larger than
    /// `maxBytes` (by default `VFSLimits.maxLocalTextBytes`), memory-mapped when the driver has
    /// them on disk. Pass `maxBytes` to allow large files from any source, such as `jq` does.
    public func largeText(path: String, maxBytes: Int? = nil) async throws -> LargeText {
        let virtualPath = try VFSPath(normalizing: path, relativeTo: .root)
        guard case let .entry(mount, child, resolvedPath) = try await resolve(virtualPath) else {
            throw VFSError.isADirectory(virtualPath.description)
        }
        if (child.size ?? 0) <= limits.maxReadBytes || child.kind != .file {
            let text = try await readText(path: resolvedPath.description)
            return LargeText(path: text.path, data: Data(text.text.utf8), encoding: .utf8)
        }
        let file = ResolvedFile(mount: mount, entry: child, path: resolvedPath, versionScope: versionScope)
        let size = child.size ?? 0
        let defaultLimit = mount.driver.listingIsCheap ? limits.maxLocalTextBytes : limits.maxReadBytes
        let allowed = maxBytes ?? defaultLimit
        guard size <= allowed else {
            throw VFSError.fileTooLarge(path: resolvedPath.description, size: size, limit: allowed)
        }
        let data = try await mappedOrReadBytes(of: file)
        guard let encoding = LargeText.encoding(of: data) else {
            if TextEncodingGuess.wide(data) != nil {
                let reason = "UTF-16 or UTF-32 text larger than \(limits.maxReadBytes) bytes "
                    + "cannot be read line by line"
                throw VFSError.unreadable(path: resolvedPath.description, reason: reason)
            }
            throw VFSError.binaryFile(path: resolvedPath.description, size: data.count)
        }
        counters.filesRead += 1
        return LargeText(path: resolvedPath.description, data: data, encoding: encoding)
    }

    /// The file memory-mapped from the local disk when the driver has it there, read whole otherwise.
    private func mappedOrReadBytes(of file: ResolvedFile) async throws -> Data {
        let ref = file.ref
        let driver = file.mount.driver
        return try await virtualizingErrors(file.path) {
            if let localFile = try driver.openLocalFile(for: ref) {
                do {
                    return try Data(contentsOf: localFile.url, options: .alwaysMapped)
                } catch {
                    throw VFSError.unreadable(path: ref.path, reason: error.localizedDescription)
                }
            }
            return try await driver.readExactBytes(ref)
        }
    }

    /// The file on the local disk behind a virtual path, opened, when its driver has one (see
    /// `MountDriver.openLocalFile`). `nil` means it has to be read with `readBinary` or `download`.
    public func openLocalFile(path: String) async throws -> LocalFile? {
        let file = try await resolveFile(path)
        let ref = file.ref
        return try await virtualizingErrors(file.path) { try file.mount.driver.openLocalFile(for: ref) }
    }

    /// Writes a file's exact bytes to `destination` through its driver's `download`, refusing files
    /// larger than `maxBytes`. Returns the version, like `readBinary`.
    @discardableResult
    public func download(path: String, to destination: URL, maxBytes: Int) async throws -> String? {
        let file = try await resolveFile(path)
        let resolvedPath = file.path
        if let size = file.entry.size, size > maxBytes {
            throw VFSError.fileTooLarge(path: resolvedPath.description, size: size, limit: maxBytes)
        }
        let ref = file.ref
        try await virtualizingErrors(resolvedPath) { try await file.mount.driver.download(ref, to: destination) }
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        guard let written = attributes[.size] as? Int else {
            throw VFSError.unreadable(path: resolvedPath.description, reason: "the downloaded file has no size")
        }
        guard written <= maxBytes else {
            try FileManager.default.removeItem(at: destination)
            throw VFSError.fileTooLarge(path: resolvedPath.description, size: written, limit: maxBytes)
        }
        counters.filesRead += 1
        return file.version
    }

    /// The version `readBinary` would report for a file, without reading it.
    public func version(path: String) async throws -> String? {
        let virtualPath = try VFSPath(normalizing: path, relativeTo: .root)
        guard case let .entry(mount, child, resolvedPath) = try await resolve(virtualPath) else {
            throw VFSError.isADirectory(virtualPath.description)
        }
        return ResolvedFile(mount: mount, entry: child, path: resolvedPath, versionScope: versionScope).version
    }

    /// Resolves a path that must name a regular file. Throws for a directory, a symbolic link or a submodule.
    private func resolveFile(_ path: String) async throws -> ResolvedFile {
        let virtualPath = try VFSPath(normalizing: path, relativeTo: .root)
        guard case let .entry(mount, child, resolvedPath) = try await resolve(virtualPath) else {
            throw VFSError.isADirectory(virtualPath.description)
        }
        switch child.kind {
        case .directory: throw VFSError.isADirectory(resolvedPath.description)
        case .symbolicLink: throw VFSError.symbolicLink(path: resolvedPath.description)
        case .submodule: throw VFSError.submodule(path: resolvedPath.description)
        case .file: return ResolvedFile(mount: mount, entry: child, path: resolvedPath, versionScope: versionScope)
        }
    }

    private func readFile(path: String, exactBytes: Bool) async throws -> LoadedFile {
        let file = try await resolveFile(path)
        let resolvedPath = file.path
        let maxReadBytes = limits.maxReadBytes
        if let size = file.entry.size, size > maxReadBytes {
            throw VFSError.fileTooLarge(path: resolvedPath.description, size: size, limit: maxReadBytes)
        }
        let ref = file.ref
        let contents = try await loadContents(mount: file.mount, refs: [ref])
        guard let content = contents[ref.path] else {
            // A batch read leaves out files it could not read, so one more read reports why.
            _ = try await virtualizingErrors(resolvedPath) { try await file.mount.driver.read(ref) }
            throw VFSError.notFound(resolvedPath.description)
        }
        counters.filesRead += 1
        switch content {
        case let .text(data):
            return LoadedFile(data: data, path: resolvedPath, mount: file.mount)
        case let .transcodedText(decoded, originalSize):
            guard exactBytes else {
                return LoadedFile(data: decoded, path: resolvedPath, mount: file.mount)
            }
            guard originalSize <= maxReadBytes else {
                throw VFSError.fileTooLarge(path: resolvedPath.description, size: originalSize, limit: maxReadBytes)
            }
            let data = try await virtualizingErrors(resolvedPath) { try await file.mount.driver.readExactBytes(ref) }
            return LoadedFile(data: data, path: resolvedPath, mount: file.mount)
        case let .binary(size):
            throw VFSError.binaryFile(path: resolvedPath.description, size: size)
        case let .truncated(size):
            guard size <= maxReadBytes else {
                throw VFSError.fileTooLarge(path: resolvedPath.description, size: size, limit: maxReadBytes)
            }
            let generation = mountGenerations[file.mount.name, default: 0]
            let data = try await virtualizingErrors(resolvedPath) { try await file.mount.driver.readExactBytes(ref) }
            if mountGenerations[file.mount.name, default: 0] == generation {
                let full = FileContent.text(data)
                contentCache.insert(full, cost: full.cost, for: cacheKey(mount: file.mount, ref: ref))
            }
            return LoadedFile(data: data, path: resolvedPath, mount: file.mount)
        }
    }

    // MARK: Contents

    func cacheKey(mount: WorkspaceMount, ref: EntryRef) -> String {
        mount.name + "\u{0}" + (ref.id.map { "id:" + $0 } ?? "path:" + ref.path)
    }

    /// Returns contents keyed by path, using the cache and asking the driver for the rest in one call.
    func loadContents(mount: WorkspaceMount, refs: [EntryRef]) async throws -> [String: FileContent] {
        var contents: [String: FileContent] = [:]
        var missing: [EntryRef] = []
        var requested = Set<String>()
        for ref in refs where requested.insert(ref.path).inserted {
            if let cached = contentCache.value(for: cacheKey(mount: mount, ref: ref)) {
                counters.contentCacheHits += 1
                contents[ref.path] = cached
            } else {
                counters.contentCacheMisses += 1
                missing.append(ref)
            }
        }
        guard !missing.isEmpty else { return contents }
        let generation = mountGenerations[mount.name, default: 0]
        let fetched = try await mount.driver.read(missing)
        // The mount may have been removed, replaced or refreshed while the driver read.
        let isCurrent = mountGenerations[mount.name, default: 0] == generation
        for ref in missing {
            guard let content = fetched[ref.path] else { continue }
            if isCurrent {
                contentCache.insert(content, cost: content.cost, for: cacheKey(mount: mount, ref: ref))
            }
            contents[ref.path] = content
        }
        return contents
    }
}
