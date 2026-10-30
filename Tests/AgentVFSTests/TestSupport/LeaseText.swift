//
//  LeaseText.swift
//  AgentVFSTests
//
//  Created by Yevhenii Kalashnikov on 30.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation
import Testing
@testable import AgentVFS

extension DownloadCache.Lease {
    /// The file's content as UTF-8 text, wherever the lease keeps the file.
    func text() throws -> String {
        let data: Data
        switch source {
        case let .data(bytes):
            data = bytes
        case let .file(localFile):
            data = try Data(contentsOf: localFile.url)
        }
        return try #require(String(bytes: data, encoding: .utf8))
    }
}
