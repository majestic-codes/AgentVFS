//
//  Renderer.swift
//  AgentVFSSQLite
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import Foundation

struct SQLiteError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Turns result rows into text in the requested mode, stopping once the output budget is spent.
struct Renderer {
    let mode: Invocation.Mode
    let header: Bool
    let separator: String
    let nullValue: String
    let budget: Int
    let lineBudget: Int
    private(set) var text = ""
    private var lineCount = 0
    private(set) var exhausted = false

    private var columns: [String] = []
    private var rows: [[String]] = []
    private var rowCount = 0
    /// Bytes of column-mode rows not yet written.
    private var pending = 0

    init(
        mode: Invocation.Mode,
        header: Bool,
        separator: String?,
        nullValue: String,
        budget: Int,
        lineBudget: Int = .max
    ) {
        self.lineBudget = lineBudget
        self.mode = mode
        self.header = header
        self.separator = separator ?? (mode == .csv ? "," : mode == .tabs ? "\t" : "|")
        self.nullValue = nullValue
        self.budget = budget
    }

    /// Output bytes still to spend, `Int.max` for a renderer without a budget.
    var bytesLeft: Int {
        budget == .max ? .max : max(0, budget - text.utf8.count - pending)
    }

    mutating func begin(columns: [String]) {
        self.columns = columns
        rows = []
        rowCount = 0
        pending = 0
    }

    /// Returns `false` when no more rows are wanted.
    mutating func add(_ row: [Value]) -> Bool {
        defer { rowCount += 1 }
        switch mode {
        case .list, .tabs:
            if rowCount == 0 && header { write(columns.joined(separator: separator) + "\n") }
            write(row.map { $0.plain(null: nullValue) }.joined(separator: separator) + "\n")
        case .csv:
            if rowCount == 0 && header { write(columns.map(Self.csv).joined(separator: separator) + "\n") }
            write(row.map { $0.isNull ? nullValue : Self.csv($0.plain(null: "")) }.joined(separator: separator) + "\n")
        case .json:
            let fields = zip(columns, row).map { "\(Self.json(string: $0)):\($1.json)" }
            write((rowCount == 0 ? "[" : ",\n") + "{" + fields.joined(separator: ",") + "}")
        case .line:
            let width = columns.map(\.count).max() ?? 0
            if rowCount > 0 { write("\n") }
            for (column, value) in zip(columns, row) {
                let padding = String(repeating: " ", count: width - column.count)
                write(padding + column + " = " + value.plain(null: nullValue) + "\n")
            }
        case .column:
            // Widths depend on every row, so rows are kept until the statement ends.
            let cells = row.map { $0.plain(null: nullValue) }
            rows.append(cells)
            pending += cells.reduce(0) { $0 + $1.utf8.count + 2 }
            if text.utf8.count + pending > budget || lineCount + rows.count > lineBudget { exhausted = true }
        }
        return !exhausted
    }

    mutating func end() {
        switch mode {
        case .json where rowCount > 0:
            write("]\n")
        case .column where !rows.isEmpty:
            var widths = columns.map(\.count)
            for row in rows {
                for (index, value) in row.enumerated() where index < widths.count {
                    widths[index] = max(widths[index], value.count)
                }
            }
            func line(_ values: [String]) -> String {
                let padded = zip(values, widths).map { $0 + String(repeating: " ", count: max(0, $1 - $0.count)) }
                let joined = padded.joined(separator: "  ")
                let end = joined.lastIndex { !$0.isWhitespace }
                return end.map { String(joined[...$0]) + "\n" } ?? "\n"
            }
            let stopped = exhausted
            exhausted = false
            if header {
                write(line(columns))
                write(line(widths.map { String(repeating: "-", count: $0) }))
            }
            for row in rows where !exhausted {
                write(line(row))
            }
            exhausted = exhausted || stopped
        default:
            break
        }
        if exhausted {
            text += "... (output limit reached; narrow the query with WHERE or LIMIT)\n"
        }
    }

    /// Plain lines, for dot commands.
    mutating func lines(_ values: [String]) {
        for value in values where !exhausted {
            write(value + "\n")
        }
        if exhausted {
            text += "... (output limit reached)\n"
        }
    }

    /// Appends `piece`, or as much of it as the budget has room for.
    private mutating func write(_ piece: String) {
        guard !exhausted else { return }
        let room = budget - text.utf8.count
        let kept = piece.utf8.count > room ? String(repairingUTF8: piece.utf8.prefix(room)) : piece
        text += kept
        lineCount += kept.utf8.count { $0 == UInt8(ascii: "\n") }
        if kept.utf8.count < piece.utf8.count || text.utf8.count >= budget || lineCount >= lineBudget {
            exhausted = true
        }
    }

    static func csv(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func json(string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case _ where scalar.value < 0x20: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
