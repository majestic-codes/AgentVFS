//
//  WorkspaceFileSystem+Search.swift
//  AgentVFS
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

/// One node visited while walking the virtual tree.
struct WalkNode {
    let path: VFSPath
    let kind: EntryKind
    let size: Int?
    let id: String?
    let mount: WorkspaceMount?
    let depth: Int
}

struct WalkOutcome {
    var reasons: [TruncationReason] = []
}

extension WorkspaceFileSystem {
    // MARK: Walking

    /// Visits `path` and everything below it in sorted pre-order, at most `VFSLimits.maxWalkEntries`
    /// nodes, until `deadline`. The visitor returns `false` to stop.
    func walk(
        from path: VFSPath,
        maxDepth: Int? = nil,
        deadline: ContinuousClock.Instant,
        visit: (WalkNode) -> Bool
    ) async throws -> WalkOutcome {
        var outcome = WalkOutcome()
        let start = try await walkStart(at: path)
        var stack = [start]
        var directoryBudget = limits.maxListingsPerWalk
        var visited = 0
        var reportedIncomplete = Set<String>()
        while let node = stack.popLast() {
            try Task.checkCancellation()
            if let reason = walkStop(deadline: deadline, visited: visited) {
                outcome.reasons.append(reason)
                break
            }
            visited += 1
            if !visit(node) { break }
            guard node.kind == .directory else { continue }
            if let maxDepth, node.depth >= maxDepth { continue }
            guard let mount = node.mount else {
                stack.append(contentsOf: mountRootNodes(below: node))
                continue
            }
            let mountPath = node.path.mountPath
            if try await needsListingRequest(mount: mount, path: mountPath) {
                guard directoryBudget > 0 else {
                    if reportedIncomplete.insert(mount.name).inserted {
                        outcome.reasons.append(.treeIncomplete(mount: mount.name))
                    }
                    continue
                }
                directoryBudget -= 1
            }
            let directory = EntryRef(path: mountPath, id: node.id)
            let children = try await directoryChildren(mount: mount, directory: directory)
            for child in children.reversed() {
                let childNode = WalkNode(
                    path: node.path.appending(child.name),
                    kind: child.kind,
                    size: child.size,
                    id: child.id,
                    mount: mount,
                    depth: node.depth + 1
                )
                stack.append(childNode)
            }
        }
        return outcome
    }

    /// Why a walk that visited `visited` nodes stops now, or `nil` when it goes on.
    private func walkStop(deadline: ContinuousClock.Instant, visited: Int) -> TruncationReason? {
        if ContinuousClock.now >= deadline { return .timeout }
        if visited >= limits.maxWalkEntries { return .visitLimit(limits.maxWalkEntries) }
        return nil
    }

    private func walkStart(at path: VFSPath) async throws -> WalkNode {
        switch try await resolve(path) {
        case .workspaceRoot:
            WalkNode(path: path, kind: .directory, size: nil, id: nil, mount: nil, depth: 0)
        case let .mountRoot(mount):
            WalkNode(path: path, kind: .directory, size: nil, id: nil, mount: mount, depth: 0)
        case let .entry(mount, child, resolved):
            WalkNode(path: resolved, kind: child.kind, size: child.size, id: child.id, mount: mount, depth: 0)
        }
    }

    /// The mount roots under `/workspace`, in reverse order, ready to be pushed on the walk stack.
    private func mountRootNodes(below node: WalkNode) -> [WalkNode] {
        mounts
            .sorted { $0.name.lowercased() > $1.name.lowercased() }
            .map { mount in
                WalkNode(
                    path: node.path.appending(mount.name),
                    kind: .directory,
                    size: nil,
                    id: nil,
                    mount: mount,
                    depth: node.depth + 1
                )
            }
    }

    /// Whether listing the directory costs a request, so it counts against the walk's budget.
    private func needsListingRequest(mount: WorkspaceMount, path: String) async throws -> Bool {
        if mount.driver.listingIsCheap { return false }
        if try await isListingComplete(mount) { return false }
        return !hasLoadedDirectory(mount: mount, path: path)
    }

    // MARK: Find

    /// The entries below `path` whose names match the glob `pattern`, up to the default limit of `FindQuery`.
    public func find(path: String, pattern: String) async throws -> [FileEntry] {
        try await find(path: path, query: FindQuery(namePattern: pattern)).entries
    }

    /// The entries below `path` that match `query`, in sorted pre-order. The result says when the walk
    /// stopped early: at the entry limit, at `FindQuery.timeout`, after `VFSLimits.maxWalkEntries`
    /// visited entries, or at the listing budget of a remote mount. Throws
    /// `VFSError.invalidConfiguration` for a query that `FindQuery.validate` refuses.
    public func find(path: String, query: FindQuery) async throws -> FindResult {
        try query.validate()
        let virtualPath = try VFSPath(normalizing: path, relativeTo: .root)
        let glob: Glob? = if let namePattern = query.namePattern {
            try Glob(namePattern, caseInsensitive: query.caseInsensitive)
        } else {
            nil
        }
        var entries: [FileEntry] = []
        var overflow = false
        let deadline = ContinuousClock.now + query.timeout
        let outcome = try await walk(from: virtualPath, maxDepth: query.maxDepth, deadline: deadline) { node in
            guard node.depth >= query.minDepth else { return true }
            if !query.kinds.contains(node.kind) { return true }
            if let glob, !glob.matches(node.path.name) { return true }
            if entries.count >= query.limit {
                overflow = true
                return false
            }
            let entry = FileEntry(name: node.path.name, path: node.path.description, kind: node.kind, size: node.size)
            entries.append(entry)
            return true
        }
        var reasons = outcome.reasons
        if overflow {
            reasons.append(.entryLimit(query.limit))
        }
        return FindResult(entries: entries, isComplete: reasons.isEmpty, truncation: reasons)
    }
}
