//
//  APIQueryRunner+Summaries.swift
//  AgentVFSAPI
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import AgentVFSJQ
import Foundation

extension APIQueryRunner {
    func report(_ fetched: Fetched, path: String, bytes: Int) -> String {
        var lines: [String] = []
        let pages = fetched.pages == 1 ? "1 page" : "\(fetched.pages) pages"
        lines.append("saved \(fetched.records.count) records (\(Self.size(bytes)), \(pages)) to \(path)")
        if let total = fetched.total {
            lines.append("matching records reported by the API: \(total)")
        }
        if fetched.moreAvailable, fetched.failure == nil {
            lines.append("more records are available; narrow the filters or raise --max")
        }
        if let failure = fetched.failure {
            lines.append("stopped early, results are partial: \(failure)")
        }
        lines += Self.shape(of: fetched.records)
        return lines.joined(separator: "\n") + "\n"
    }

    func describe(file name: String) async throws -> String {
        let text = try await results.text(of: name)
        guard case let .array(records) = try JQ.parse(text) else {
            throw VFSError.unreadable(path: results.path(of: name), reason: "the saved result is not a JSON array")
        }
        var lines = ["\(records.count) records (\(Self.size(text.utf8.count)))"]
        lines += Self.shape(of: records)
        return lines.joined(separator: "\n") + "\n"
    }

    /// The fields the records have and one example, which is usually all the agent needs to
    /// write its jq filter.
    static func shape(of records: [JSONValue]) -> [String] {
        guard let first = records.first else { return ["no records matched"] }
        var fields: [(path: String, types: [String])] = []
        var fieldPositions: [String: Int] = [:]
        func visit(_ value: JSONValue, path: String, depth: Int) {
            let type: String
            switch value {
            case let .object(object) where depth < 2 && !path.isEmpty:
                for (key, child) in object.entries { visit(child, path: path + "." + key, depth: depth + 1) }
                return
            case let .array(values):
                let element = values.first.map(\.typeName) ?? "empty"
                type = "array of \(element)"
            default:
                type = value.typeName
            }
            if let position = fieldPositions[path] {
                if !fields[position].types.contains(type) { fields[position].types.append(type) }
            } else {
                fieldPositions[path] = fields.count
                fields.append((path, [type]))
            }
        }
        for record in records.prefix(200) {
            if case let .object(object) = record {
                for (key, child) in object.entries { visit(child, path: key, depth: 0) }
            }
        }
        var lines: [String] = []
        if fields.isEmpty {
            lines.append("records are \(first.typeName)s")
        } else {
            let shown = fields.prefix(60).map { "\($0.path): \($0.types.joined(separator: "|"))" }
            let more = fields.count > 60 ? ", … (\(fields.count - 60) more)" : ""
            lines.append("fields: " + shown.joined(separator: ", ") + more)
        }
        var sample = first.serialized()
        if sample.count > 500 { sample = String(sample.prefix(500)) + "…" }
        lines.append("first record: " + sample)
        return lines
    }

    static func size(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) bytes" }
        if bytes < 1_048_576 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}
