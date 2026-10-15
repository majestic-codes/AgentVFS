//
//  TemporaryDirectory.swift
//  AgentVFSTests
//
//  Created by Yevhenii Kalashnikov on 15.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

/// A new directory under the temporary directory, holding `files` keyed by relative path. The caller removes it.
func makeTemporaryDirectory(_ files: [String: String] = [:]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentVFSTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (path, text) in files {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    return root
}
