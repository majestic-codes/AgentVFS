//
//  CandidateFilter.swift
//  AgentVFS
//
//  Created by Yevhenii Kalashnikov on 14.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

/// Decides, during the walk, which files a search reads.
struct CandidateFilter {
    enum Verdict {
        case excluded
        case skipped(SkipReason)
        case accepted(Candidate)
    }

    let includes: GlobSet
    let excludes: GlobSet
    let maxFileBytes: Int
    let maxLocalTextBytes: Int

    init(options: SearchOptions, maxLocalTextBytes: Int) throws {
        includes = try GlobSet(options.includeGlobs)
        excludes = try GlobSet(options.excludeGlobs)
        maxFileBytes = options.maxFileBytes
        self.maxLocalTextBytes = maxLocalTextBytes
    }

    func verdict(on node: WalkNode, in mount: WorkspaceMount) -> Verdict {
        let name = node.path.name
        let mountPath = node.path.mountPath
        if !includes.isEmpty, !includes.matches(name: name, mountPath: mountPath) { return .excluded }
        if excludes.matches(name: name, mountPath: mountPath) { return .excluded }
        if Self.hasBinaryExtension(name) { return .skipped(.binary) }
        let size = node.size ?? 0
        // The size limit keeps remote searches from downloading big files. Local files cost
        // nothing to read and are scanned in place.
        let large = size > maxFileBytes
        if large, !mount.driver.listingIsCheap || size > maxLocalTextBytes {
            return .skipped(.tooLarge(size: size))
        }
        let ref = EntryRef(path: mountPath, id: node.id, size: node.size)
        return .accepted(Candidate(mount: mount, path: node.path, ref: ref, size: size, large: large))
    }

    private static func hasBinaryExtension(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: ".") else { return false }
        return binaryExtensions.contains(name[name.index(after: dot)...].lowercased())
    }
}
