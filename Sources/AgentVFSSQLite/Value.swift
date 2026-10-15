//
//  Value.swift
//  AgentVFSSQLite
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

/// One result cell.
enum Value {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    /// A blob by its first `shownBlobBytes` bytes and its whole size.
    case blob(prefix: Data, count: Int)

    /// Bytes of a blob shown in output.
    static let shownBlobBytes = 64

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    func plain(null: String) -> String {
        switch self {
        case .null: null
        case let .integer(value): String(value)
        case let .real(value): Self.format(value)
        case let .text(value): value
        case let .blob(prefix, count): Self.hex(prefix, count: count)
        }
    }

    /// Roughly the bytes the value takes in output.
    var byteCount: Int {
        switch self {
        case .null, .integer, .real: 8
        case let .text(value): value.utf8.count
        case let .blob(prefix, _): prefix.count * 2 + 32
        }
    }

    var json: String {
        switch self {
        case .null: "null"
        case let .integer(value): String(value)
        case let .real(value): value.isFinite ? Self.format(value) : "null"
        case let .text(value): Renderer.json(string: value)
        case let .blob(prefix, count): Renderer.json(string: Self.hex(prefix, count: count))
        }
    }

    static func format(_ value: Double) -> String {
        if value.isFinite, value == value.rounded(), abs(value) < 1e15 {
            return String(format: "%.1f", value)
        }
        return String(value)
    }

    /// Blobs are shown as SQL literals. Long ones are shown only by their start and size.
    static func hex(_ prefix: Data, count: Int) -> String {
        let shown = prefix.prefix(shownBlobBytes).map { String(format: "%02X", $0) }.joined()
        return count > shownBlobBytes ? "X'\(shown)…' (\(count) bytes)" : "X'\(shown)'"
    }
}
