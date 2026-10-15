//
//  VFSError.swift
//  AgentVFS
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

/// Errors surfaced by the virtual file system. Messages are written for an AI agent:
/// they say what happened and, where possible, what to do instead.
public enum VFSError: Error, Equatable, Sendable {
    /// The path leads outside `/workspace`.
    case outsideWorkspace(String)
    /// The path is malformed, for example it holds a NUL character.
    case invalidPath(String)
    /// Nothing exists at the path.
    case notFound(String)
    /// A directory was expected but the path names something else.
    case notADirectory(String)
    /// A file was expected but the path names a directory.
    case isADirectory(String)
    /// No mount has this name.
    case unknownMount(String)
    /// The file is binary, so it is not shown as text.
    case binaryFile(path: String, size: Int)
    /// The file is larger than the limit of the operation.
    case fileTooLarge(path: String, size: Int, limit: Int)
    /// The path names a symbolic link, which is never followed.
    case symbolicLink(path: String)
    /// The path names a git submodule, whose contents are not mounted.
    case submodule(path: String)
    /// The source could not deliver the file.
    case unreadable(path: String, reason: String)
    /// A search pattern or glob does not compile.
    case invalidPattern(String)
    /// The workspace, a driver or a limit was set up wrongly.
    case invalidConfiguration(String)
    /// The source refused the credentials.
    case unauthorized(String)
    /// The source's rate limit is exhausted until `resetAt`, when known.
    case rateLimited(resetAt: Date?)
    /// The source could not be reached.
    case network(String)
    /// The source answered with an error status.
    case api(status: Int, message: String)
    /// The operation was cancelled.
    case cancelled
    /// The operation ran past its time limit before it read its input to the end.
    case timeLimitReached
}

extension VFSError: LocalizedError {
    /// The message for the agent.
    public var errorDescription: String? {
        switch self {
        case let .outsideWorkspace(path):
            "\(path): path is outside /workspace. Only paths under /workspace are accessible."
        case let .invalidPath(reason):
            "invalid path: \(reason)"
        case let .notFound(path):
            "\(path): No such file or directory"
        case let .notADirectory(path):
            "\(path): Not a directory"
        case let .isADirectory(path):
            "\(path): Is a directory"
        case let .unknownMount(name):
            "\(name): no such mount"
        case let .binaryFile(path, size):
            "\(path): binary file (\(size) bytes) skipped"
        case let .fileTooLarge(path, size, limit):
            "\(path): file is too large (\(size) bytes, limit \(limit)) and was skipped"
        case let .symbolicLink(path):
            "\(path): is a symbolic link; links are not followed"
        case let .submodule(path):
            "\(path): is a git submodule; its contents are not mounted"
        case let .unreadable(path, reason):
            "\(path): cannot be read (\(reason))"
        case let .invalidPattern(reason):
            "invalid pattern: \(reason)"
        case let .invalidConfiguration(reason):
            "invalid configuration: \(reason)"
        case let .unauthorized(reason):
            "authorization failed: \(reason)"
        case let .rateLimited(resetAt):
            if let resetAt {
                "rate limit exceeded; resets at \(resetAt.formatted(.iso8601))"
            } else {
                "rate limit exceeded"
            }
        case let .network(reason):
            "network error: \(reason)"
        case let .api(status, message):
            "API error \(status): \(message)"
        case .cancelled:
            "operation cancelled"
        case .timeLimitReached:
            "time limit reached before the input was read to the end; narrow it first, for example with grep or head"
        }
    }
}
