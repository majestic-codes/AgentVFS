//
//  LocalFile.swift
//  AgentVFS
//
//  Created by Yevhenii Kalashnikov on 14.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Darwin
import Foundation

/// A file on the local disk that a driver opened and checked, kept open while a tool uses it.
///
/// Tools open `url`, which names this open descriptor (`/dev/fd/N`) rather than a path in the
/// mount, so a file swapped for a link after the check is never what they read.
public final class LocalFile: Sendable {
    /// The open, read-only descriptor. It is closed when the `LocalFile` goes.
    public let descriptor: Int32

    /// Takes ownership of `descriptor`.
    public init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    /// A path that opens this descriptor's file.
    public var url: URL {
        URL(fileURLWithPath: "/dev/fd/\(descriptor)", isDirectory: false)
    }
}
