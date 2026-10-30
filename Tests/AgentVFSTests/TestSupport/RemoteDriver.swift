//
//  RemoteDriver.swift
//  AgentVFSTests
//
//  Created by Yevhenii Kalashnikov on 30.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation
@testable import AgentVFS

/// Files that cost a read each time, like a driver over a network: it has no local path and does
/// not hold its files in memory.
struct RemoteDriver: MountDriver {
    let files: InMemoryDriver

    var info: MountInfo { files.info }
    var revision: Int? { files.revision }
    var listingIsCheap: Bool { true }

    init(texts: [String: String]) throws {
        files = try InMemoryDriver(texts: texts)
    }

    func put(_ path: String, text: String) throws {
        try files.put(path, text: text)
    }

    func list(_ directory: EntryRef) async throws -> [DriverEntry] {
        try await files.list(directory)
    }

    func read(_ file: EntryRef) async throws -> FileContent {
        try await files.read(file)
    }

    func readExactBytes(_ file: EntryRef) async throws -> Data {
        try await files.readExactBytes(file)
    }
}
