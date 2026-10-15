//
//  APIResults.swift
//  AgentVFSAPI
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import AgentVFSJQ
import Foundation

/// Where API commands keep their results: one in-memory mount, `/workspace/results` by default,
/// shared by every command given the same store.
public final class APIResults: Sendable {
    /// The mount's name under `/workspace`.
    public let mountName: String
    let driver: InMemoryDriver
    private let state = ResultsState()

    /// A store mounted as `/workspace/<mountName>` on first use.
    public init(mountName: String = "results") {
        self.mountName = mountName
        let summary = "results of API queries, one JSON file per query"
        driver = InMemoryDriver(info: MountInfo(kind: "results", source: "API query results", summary: summary))
    }

    /// The mount, for a workspace that should show the store before the first query.
    public var mount: WorkspaceMount { WorkspaceMount(name: mountName, driver: driver) }

    /// Mounts the store if the workspace does not have it yet. Throws when another source already
    /// uses the mount name.
    public func ensureMounted(in fileSystem: WorkspaceFileSystem) async throws {
        if let existing = fileSystem.mount(named: mountName) {
            guard existing.driver as? InMemoryDriver === driver else {
                throw VFSError.invalidConfiguration("/workspace/\(mountName) is already used by another source")
            }
            return
        }
        try await fileSystem.addMount(mount)
    }

    /// The file saved earlier under `key`, or `nil` when there is none or it was removed.
    public func cached(_ key: String) async -> SavedResult? {
        guard let saved = await state.file(for: key), driver.paths.contains(saved.name) else { return nil }
        return saved
    }

    /// Saves records as a JSON array with one record per line, so `grep` and `head` see whole
    /// records, in a new file named `<command>-N.json`. `key` identifies the request for `cached`.
    @discardableResult
    public func save(_ records: [JSONValue], command: String, key: String) async throws -> SavedResult {
        try await save(records, command: command, reuseKey: key)
    }

    /// Saves records like `save(_:command:key:)`, remembered for `cached` only when `reuseKey` is given.
    func save(_ records: [JSONValue], command: String, reuseKey: String?) async throws -> SavedResult {
        let text = records.isEmpty ? "[]\n" : "[\n" + records.map { $0.serialized() }.joined(separator: ",\n") + "\n]\n"
        return try await save(text: text, command: command, reuseKey: reuseKey, fileExtension: "json")
    }

    /// Saves a response as it came, such as a JSON object or plain text, in a new file named
    /// `<command>-N.<fileExtension>`. `key` identifies the request for `cached`.
    @discardableResult
    public func save(
        text: String,
        command: String,
        key: String,
        fileExtension: String = "json"
    ) async throws -> SavedResult {
        try await save(text: text, command: command, reuseKey: key, fileExtension: fileExtension)
    }

    private func save(
        text: String,
        command: String,
        reuseKey: String?,
        fileExtension: String
    ) async throws -> SavedResult {
        let name = "\(command)-\(await state.nextNumber(for: command)).\(fileExtension)"
        let data = Data(text.utf8)
        try driver.put(name, data: data)
        let saved = SavedResult(name: name, path: path(of: name), bytes: data.count)
        if let reuseKey {
            await state.remember(saved, for: reuseKey)
        }
        return saved
    }

    /// The text of a saved file, read from memory without a size limit.
    func text(of name: String) async throws -> String {
        let data = try await driver.readExactBytes(EntryRef(path: name))
        return String(repairingUTF8: data)
    }

    /// The virtual path of a saved file.
    public func path(of name: String) -> String { "/workspace/\(mountName)/\(name)" }
}

/// A file `APIResults` saved.
public struct SavedResult: Sendable, Equatable {
    /// The file name inside the results mount, such as `orders-1.json`.
    public let name: String
    /// The virtual path the agent reads, such as `/workspace/results/orders-1.json`.
    public let path: String
    /// The size of the file in bytes.
    public let bytes: Int
}

private actor ResultsState {
    private var counters: [String: Int] = [:]
    private var files: [String: SavedResult] = [:]

    func nextNumber(for command: String) -> Int {
        let number = counters[command, default: 0] + 1
        counters[command] = number
        return number
    }

    func file(for key: String) -> SavedResult? { files[key] }

    func remember(_ saved: SavedResult, for key: String) { files[key] = saved }
}
