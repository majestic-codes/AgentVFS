//
//  WorkspaceFileSystem.swift
//  AgentVFS
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation
import Synchronization

/// Directory listings of one mount.
struct MountListing: Sendable {
    /// Keyed by mount-relative directory path. `""` is the root.
    var directories: [String: [DriverEntry]]
    /// `true` when `directories` already holds every directory of the mount.
    var isComplete: Bool
    /// Entries of the directories cached one at a time, for `VFSLimits.maxCachedListingEntries`.
    var entryCount = 0
}

/// Where a virtual path points.
enum Resolution {
    case workspaceRoot
    case mountRoot(WorkspaceMount)
    case entry(WorkspaceMount, DriverEntry, VFSPath)
}

/// Children in listing order: by name, ignoring case.
///
/// Names with control characters such as a newline are left out: printed in a listing they would
/// pass for other entries or lines of output. So are names a path cannot hold.
func sortedChildren(_ children: [DriverEntry]) -> [DriverEntry] {
    children.filter(\.hasPrintableName).sorted { first, second in
        let firstKey = first.name.lowercased()
        let secondKey = second.name.lowercased()
        return firstKey == secondKey ? first.name < second.name : firstKey < secondKey
    }
}

/// A read-only file system that shows every mount as a directory under `/workspace`.
///
/// Each mount is served by a `MountDriver`. The workspace resolves paths, caches listings and
/// file contents, and implements `find` and content search the same way for every driver.
/// Mounts can be added and removed while it is in use.
public actor WorkspaceFileSystem {
    nonisolated private let mountTable: Mutex<[WorkspaceMount]>
    /// Starts every file version, so caches shared by several workspaces never mix their files.
    nonisolated let versionScope = UUID().uuidString
    let limits: VFSLimits
    private let statisticsSources: [any RequestStatsSource]

    private var listings: [String: MountListing] = [:]
    private var listingLoads: [String: Task<MountListing, any Error>] = [:]
    /// Bumped whenever a mount's caches are dropped, so what a load started before brings back is not stored.
    private(set) var mountGenerations: [String: Int] = [:]
    /// Directory entries cached for mounts listed one directory at a time.
    private var cachedListingEntries = 0
    /// The driver revision each mount's caches were filled at.
    private var seenRevisions: [String: Int] = [:]
    var contentCache: LRUCache<String, FileContent>
    var searchCache: LRUCache<SearchCacheKey, SearchPage>
    var counters = VFSMetrics()

    /// Throws `VFSError.invalidConfiguration` for no mounts, an invalid or repeated mount name, or
    /// limits that `VFSLimits.validate` refuses.
    ///
    /// - Parameter statistics: services whose traffic `metrics()` reports, usually the API clients
    ///   the drivers share.
    public init(
        mounts: [WorkspaceMount],
        limits: VFSLimits = VFSLimits(),
        statistics: [any RequestStatsSource] = []
    ) throws {
        try limits.validate()
        guard !mounts.isEmpty else {
            throw VFSError.invalidConfiguration("at least one mount is required")
        }
        var seen = Set<String>()
        for mount in mounts {
            try WorkspaceMount.validate(name: mount.name)
            guard seen.insert(mount.name).inserted else {
                throw VFSError.invalidConfiguration("mount name '\(mount.name)' is used more than once")
            }
        }
        self.mountTable = Mutex(mounts)
        self.limits = limits
        self.statisticsSources = statistics
        self.contentCache = LRUCache(capacity: limits.contentCacheBytes)
        self.searchCache = LRUCache(capacity: limits.searchCacheEntries)
    }

    /// The mounts in the order they were added.
    nonisolated public var mounts: [WorkspaceMount] {
        mountTable.withLock { $0 }
    }

    /// The mount with this name, or `nil`.
    nonisolated public func mount(named name: String) -> WorkspaceMount? {
        mountTable.withLock { table in table.first { $0.name == name } }
    }

    // MARK: Changing mounts

    /// Adds a mount. It appears under `/workspace/<name>` for the next operation.
    public func addMount(_ mount: WorkspaceMount) throws {
        try WorkspaceMount.validate(name: mount.name)
        try mountTable.withLock { table in
            guard !table.contains(where: { $0.name == mount.name }) else {
                throw VFSError.invalidConfiguration("mount name '\(mount.name)' is used more than once")
            }
            table.append(mount)
        }
        dropCaches(mountNamed: mount.name)
    }

    /// Removes a mount and everything cached for it. The last mount cannot be removed.
    public func removeMount(named name: String) throws {
        try mountTable.withLock { table in
            guard let index = table.firstIndex(where: { $0.name == name }) else {
                throw VFSError.unknownMount(name)
            }
            guard table.count > 1 else {
                throw VFSError.invalidConfiguration("at least one mount is required")
            }
            table.remove(at: index)
        }
        dropCaches(mountNamed: name)
    }

    /// Forgets cached listings and contents, of one mount or of all, so the next operation asks
    /// the drivers again. Use it after files changed in a source the workspace cannot watch, such
    /// as a local directory. Throws `VFSError.unknownMount` for a name no mount has.
    public func refresh(mountNamed name: String? = nil) throws {
        if let name, mount(named: name) == nil {
            throw VFSError.unknownMount(name)
        }
        for mount in mounts where name == nil || mount.name == name {
            dropCaches(mountNamed: mount.name)
        }
    }

    private func dropCaches(mountNamed name: String) {
        if let listing = listings[name], !listing.isComplete {
            cachedListingEntries -= listing.entryCount
        }
        listings[name] = nil
        listingLoads[name] = nil
        mountGenerations[name, default: 0] += 1
        seenRevisions[name] = nil
        let prefix = name + "\u{0}"
        contentCache.removeAll { $0.hasPrefix(prefix) }
        // Search results may span several mounts, so none of them can be trusted any more.
        searchCache.removeAll()
    }

    /// Drops the caches of mounts whose drivers report a new revision.
    func syncRevisions() {
        for mount in mounts {
            guard let revision = mount.driver.revision else { continue }
            if let seen = seenRevisions[mount.name], seen == revision { continue }
            if seenRevisions[mount.name] != nil || listings[mount.name] != nil {
                dropCaches(mountNamed: mount.name)
            }
            seenRevisions[mount.name] = revision
        }
    }

    /// A citation link for a virtual path, if its mount has links. Throws for a path outside the workspace.
    nonisolated public func link(to path: String, line: Int? = nil) throws -> URL? {
        let virtualPath = try VFSPath(normalizing: path, relativeTo: .root)
        guard let name = virtualPath.mountName, let mount = mount(named: name) else { return nil }
        return mount.driver.link(to: virtualPath.mountPath, line: line)
    }

    /// What the workspace did so far, with the traffic of its statistics sources.
    public func metrics() async -> VFSMetrics {
        var snapshot = counters
        snapshot.contentCacheBytes = contentCache.totalCost
        for source in statisticsSources {
            snapshot.requests.add(await source.requestStats())
        }
        return snapshot
    }

    // MARK: Listing

    /// The entries of a directory, sorted by name ignoring case. Names a listing cannot show safely,
    /// such as ones with control characters, are left out.
    public func list(path: String) async throws -> [FileEntry] {
        let virtualPath = try VFSPath(normalizing: path, relativeTo: .root)
        switch try await resolve(virtualPath) {
        case .workspaceRoot:
            return mounts
                .sorted { $0.name.lowercased() < $1.name.lowercased() }
                .map { mount in
                    let path = virtualPath.appending(mount.name).description
                    return FileEntry(name: mount.name, path: path, kind: .directory, size: nil)
                }
        case let .mountRoot(mount):
            let children = try await directoryChildren(mount: mount, directory: .root)
            return children.map { fileEntry($0, in: virtualPath) }
        case let .entry(mount, child, resolvedPath):
            switch child.kind {
            case .directory:
                let directory = EntryRef(path: resolvedPath.mountPath, id: child.id)
                let children = try await directoryChildren(mount: mount, directory: directory)
                return children.map { fileEntry($0, in: resolvedPath) }
            case .submodule:
                throw VFSError.submodule(path: resolvedPath.description)
            case .file, .symbolicLink:
                throw VFSError.notADirectory(resolvedPath.description)
            }
        }
    }

    /// The entry a path names.
    public func stat(path: String) async throws -> FileEntry {
        let virtualPath = try VFSPath(normalizing: path, relativeTo: .root)
        switch try await resolve(virtualPath) {
        case .workspaceRoot, .mountRoot:
            return FileEntry(name: virtualPath.name, path: virtualPath.description, kind: .directory, size: nil)
        case let .entry(_, child, resolvedPath):
            return FileEntry(name: child.name, path: resolvedPath.description, kind: child.kind, size: child.size)
        }
    }

    // MARK: Path resolution

    func resolve(_ path: VFSPath) async throws -> Resolution {
        guard let mountName = path.mountName else { return .workspaceRoot }
        syncRevisions()
        guard let mount = mount(named: mountName) else {
            throw VFSError.unknownMount(mountName)
        }
        let parts = Array(path.components.dropFirst())
        if parts.isEmpty { return .mountRoot(mount) }
        var directory = EntryRef.root
        for (index, part) in parts.enumerated() {
            let children = try await directoryChildren(mount: mount, directory: directory)
            guard let child = children.first(where: { $0.name == part }) else {
                throw VFSError.notFound(path.description)
            }
            if index == parts.count - 1 {
                return .entry(mount, child, path)
            }
            guard child.kind == .directory else {
                let parent = VFSPath(components: Array(path.components.prefix(index + 2)))
                throw VFSError.notADirectory(parent.description)
            }
            directory = EntryRef(path: directory.path.isEmpty ? part : directory.path + "/" + part, id: child.id)
        }
        throw VFSError.notFound(path.description)
    }

    private func fileEntry(_ child: DriverEntry, in parent: VFSPath) -> FileEntry {
        FileEntry(name: child.name, path: parent.appending(child.name).description, kind: child.kind, size: child.size)
    }

    // MARK: Listings

    /// Children of one directory. Asks the driver for the whole tree on first use and, when it
    /// cannot give one, lists single directories on demand.
    func directoryChildren(mount: WorkspaceMount, directory: EntryRef) async throws -> [DriverEntry] {
        try await ensureListing(mount)
        if let cached = listings[mount.name]?.directories[directory.path] {
            counters.listingCacheHits += 1
            return cached
        }
        let directoryComponents = directory.path.split(separator: "/").map(String.init)
        let virtualPath = VFSPath(components: [mount.name] + directoryComponents)
        guard listings[mount.name]?.isComplete == false else {
            throw VFSError.notFound(virtualPath.description)
        }
        counters.listingFetches += 1
        let generation = mountGenerations[mount.name, default: 0]
        let listed = try await virtualizingErrors(virtualPath) { try await mount.driver.list(directory) }
        let children = sortedChildren(listed)
        // The mount may have been removed, replaced or refreshed while the driver listed.
        guard mountGenerations[mount.name, default: 0] == generation else { return children }
        storeListed(children, of: directory.path, mountNamed: mount.name)
        return children
    }

    /// Caches one directory of a mount listed one directory at a time. Past
    /// `VFSLimits.maxCachedListingEntries` the cached directories of all such mounts are dropped first.
    private func storeListed(_ children: [DriverEntry], of path: String, mountNamed name: String) {
        guard listings[name] != nil else { return }
        if cachedListingEntries + children.count > limits.maxCachedListingEntries {
            for (mountName, listing) in listings where !listing.isComplete {
                listings[mountName]?.directories = [:]
                listings[mountName]?.entryCount = 0
            }
            cachedListingEntries = 0
        }
        let replaced = listings[name]?.directories[path]?.count ?? 0
        listings[name]?.directories[path] = children
        listings[name]?.entryCount += children.count - replaced
        cachedListingEntries += children.count - replaced
    }

    /// Whether every directory of the mount is already known without further requests.
    func isListingComplete(_ mount: WorkspaceMount) async throws -> Bool {
        try await ensureListing(mount)
        return listings[mount.name]?.isComplete ?? false
    }

    func hasLoadedDirectory(mount: WorkspaceMount, path: String) -> Bool {
        listings[mount.name]?.directories[path] != nil
    }

    private func ensureListing(_ mount: WorkspaceMount) async throws {
        let name = mount.name
        syncRevisions()
        if listings[name] != nil { return }
        let generation = mountGenerations[name, default: 0]
        let task: Task<MountListing, any Error>
        if let running = listingLoads[name] {
            task = running
        } else {
            let driver = mount.driver
            task = Task {
                guard case let .complete(all) = try await driver.listAll() else {
                    return MountListing(directories: [:], isComplete: false)
                }
                return MountListing(directories: all.mapValues(sortedChildren), isComplete: true)
            }
            listingLoads[name] = task
            counters.listingFetches += 1
        }
        do {
            let loaded = try await task.value
            // A listing dropped while it loaded may already be out of date.
            guard mountGenerations[name, default: 0] == generation else {
                try await ensureListing(mount)
                return
            }
            if listings[name] == nil {
                listings[name] = loaded
            }
            listingLoads[name] = nil
        } catch {
            if mountGenerations[name, default: 0] == generation {
                listingLoads[name] = nil
            }
            throw error
        }
    }
}

extension WorkspaceFileSystem {
    /// Runs `body`, turning the mount-relative paths in driver errors into the virtual path the agent sees.
    func virtualizingErrors<T>(_ path: VFSPath, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch VFSError.notFound {
            throw VFSError.notFound(path.description)
        } catch let VFSError.binaryFile(_, size) {
            throw VFSError.binaryFile(path: path.description, size: size)
        } catch VFSError.symbolicLink {
            throw VFSError.symbolicLink(path: path.description)
        } catch let VFSError.unreadable(_, reason) {
            throw VFSError.unreadable(path: path.description, reason: reason)
        }
    }
}

extension DriverEntry {
    /// `false` for a name that `isPrintable(name:)` refuses.
    var hasPrintableName: Bool { Self.isPrintable(name: name) }

    /// `false` for an empty name, `.`, `..`, a name with `/`, or one with a character that could make a
    /// printed listing lie: a control character, a bidirectional control, a line or paragraph
    /// separator, or a zero-width character.
    static func isPrintable(name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return false }
        return !name.unicodeScalars.contains(where: isHidingScalar)
    }

    private static func isHidingScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00..<0x20, 0x7F...0x9F: true
        case 0x200B...0x200F, 0x202A...0x202E, 0x2060, 0x2066...0x2069, 0xFEFF: true
        case 0x2028, 0x2029: true
        default: false
        }
    }
}

struct SearchCacheKey: Hashable, Sendable {
    let path: String
    let pattern: String
    let options: SearchOptions
}
