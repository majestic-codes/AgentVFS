//
//  VFSPath.swift
//  AgentVFS
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

/// A normalized absolute path inside the virtual `/workspace` tree.
///
/// The first component is the mount name. The rest is the path inside that mount. Normalization is purely
/// lexical and never touches a real file system, so `..`, symlinks and `~` can never reach anything outside
/// the workspace.
public struct VFSPath: Hashable, Sendable, CustomStringConvertible {
    /// How the workspace root is spelled.
    public static let rootName = "/workspace"
    /// The workspace root, `/workspace`.
    public static let root = Self(components: [])

    /// The path's components below `/workspace`: the mount name, then the path inside the mount.
    public let components: [String]

    /// A path from components that are already normalized.
    init(components: [String]) {
        self.components = components
    }

    /// Resolves `raw` (absolute or relative to `directory`) and normalizes `.`, `..` and repeated slashes.
    public init(normalizing raw: String, relativeTo directory: Self) throws {
        if raw.contains("\0") {
            throw VFSError.invalidPath("path contains a NUL character")
        }
        var resolved: [String]
        var pieces = raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if raw.hasPrefix("/") {
            guard pieces.first == "workspace" else {
                throw VFSError.outsideWorkspace(raw)
            }
            pieces.removeFirst()
            resolved = []
        } else {
            resolved = directory.components
        }
        for piece in pieces {
            switch piece {
            case ".":
                continue
            case "..":
                guard !resolved.isEmpty else {
                    throw VFSError.outsideWorkspace(raw)
                }
                resolved.removeLast()
            default:
                resolved.append(piece)
            }
        }
        self.components = resolved
    }

    /// Whether the path is `/workspace` itself.
    public var isRoot: Bool { components.isEmpty }

    /// The last component, or `workspace` for the root.
    public var name: String { components.last ?? "workspace" }

    /// The mount the path lies in, or `nil` for the root.
    public var mountName: String? { components.first }

    /// Path inside the mount, without a leading slash. Empty for the mount root.
    public var mountPath: String { components.dropFirst().joined(separator: "/") }

    /// The path one level up, or `nil` for the root.
    public var parent: Self? {
        guard !components.isEmpty else { return nil }
        return Self(components: Array(components.dropLast()))
    }

    /// The path with one more component.
    public func appending(_ component: String) -> Self {
        Self(components: components + [component])
    }

    /// The absolute path, such as `/workspace/ios/App.swift`.
    public var description: String {
        components.isEmpty ? Self.rootName : Self.rootName + "/" + components.joined(separator: "/")
    }
}
