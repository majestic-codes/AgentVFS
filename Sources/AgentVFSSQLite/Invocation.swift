//
//  Invocation.swift
//  AgentVFSSQLite
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS

/// What one command line asks for.
struct Invocation {
    enum Mode: String {
        case list, csv, json, line, column, tabs
    }

    /// Whether `-header` or `-noheader` was given, or neither.
    enum HeaderChoice {
        case modeDefault, shown, hidden
    }

    var mode = Mode.list
    var header = HeaderChoice.modeDefault
    var separator: String?
    var nullValue = ""
    var file = ""
    var sql = ".tables"

    /// Reads options before and after the database, as sqlite3 does, but none after the SQL.
    static func parse(_ arguments: [ShellToken]) throws -> Self {
        var invocation = Self()
        var operands: [String] = []
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            index += 1
            guard !token.isQuoted, operands.count < 2, token.text.hasPrefix("-"), token.text.count > 1 else {
                operands.append(token.text)
                continue
            }
            let option = token.text.hasPrefix("--") ? String(token.text.dropFirst()) : token.text
            func value() throws -> String {
                guard index < arguments.count else { throw CommandError.usage("sqlite3: \(token.text) needs a value") }
                index += 1
                return arguments[index - 1].text
            }
            switch option {
            case "-header", "-headers": invocation.header = .shown
            case "-noheader": invocation.header = .hidden
            case "-separator": invocation.separator = try value()
            case "-nullvalue": invocation.nullValue = try value()
            case "-readonly", "-safe", "-batch", "-bail": break
            case "-cmd": throw CommandError.usage("sqlite3: -cmd is not supported; pass the SQL as one argument")
            default:
                guard let mode = Mode(rawValue: String(option.dropFirst())) else {
                    throw CommandError.usage("sqlite3: unknown option \(token.text)")
                }
                invocation.mode = mode
            }
        }
        guard let file = operands.first else {
            throw CommandError.usage("usage: " + SQLiteCommand.synopsis)
        }
        invocation.file = file
        if operands.count > 1 {
            invocation.sql = operands.dropFirst().joined(separator: " ")
        }
        return invocation
    }

    /// Like the sqlite3 shell, column mode shows headers unless told otherwise.
    var showsHeader: Bool {
        switch header {
        case .modeDefault: mode == .column
        case .shown: true
        case .hidden: false
        }
    }
}
