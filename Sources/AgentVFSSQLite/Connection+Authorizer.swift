//
//  Connection+Authorizer.swift
//  AgentVFSSQLite
//
//  Created by Yevhenii Kalashnikov on 30.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import SQLite3

extension Connection {
    /// Allows reading and nothing else: `SELECT`, `WITH`, functions other than `deniedFunctions`,
    /// and the read-only pragmas. Writes, temporary tables, transactions, `ATTACH` and settings are refused.
    static let authorizer: @convention(c) (
        UnsafeMutableRawPointer?,
        Int32,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?
    ) -> Int32 = { _, action, first, second, _, _ in
        let firstText = first.map { String(cString: $0) }
        let secondText = second.map { String(cString: $0) }
        return isAllowed(action: action, first: firstText, second: secondText) ? SQLITE_OK : SQLITE_DENY
    }

    /// Whether the authorizer lets `action` through. `first` and `second` are its two arguments:
    /// for a pragma its name and value, for a function the function's name as `second`.
    private static func isAllowed(action: Int32, first: String?, second: String?) -> Bool {
        switch action {
        case SQLITE_SELECT, SQLITE_READ, SQLITE_RECURSIVE:
            true
        case SQLITE_FUNCTION:
            second.map { !deniedFunctions.contains($0.lowercased()) } ?? false
        case SQLITE_PRAGMA:
            first.map { isReadOnlyPragma(name: $0.lowercased(), argument: second) } ?? false
        default:
            false
        }
    }

    private static func isReadOnlyPragma(name: String, argument: String?) -> Bool {
        pragmasTakingName.contains(name) || (argument == nil && pragmasWithoutArgument.contains(name))
    }

    /// Functions that would reach outside the database.
    private static let deniedFunctions: Set<String> = ["load_extension", "fts3_tokenizer"]

    /// Pragmas that only report, given a table, an index or a count.
    private static let pragmasTakingName: Set<String> = [
        "table_info", "table_xinfo", "table_list", "index_list", "index_info", "index_xinfo",
        "foreign_key_list", "foreign_key_check", "integrity_check", "quick_check"
    ]

    /// Pragmas that report a setting when given no value, and would change it when given one.
    private static let pragmasWithoutArgument: Set<String> = [
        "database_list", "collation_list", "function_list", "module_list", "pragma_list", "compile_options",
        "encoding", "page_size", "page_count", "freelist_count", "user_version", "application_id",
        "schema_version", "data_version", "journal_mode", "auto_vacuum", "foreign_keys"
    ]

    /// Interrupts the query (returns 1) once the watchdog passed as `context` says it must stop.
    static let progressHandler: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { context in
        guard let context else { return 1 }
        let watchdog = Unmanaged<Watchdog>.fromOpaque(context).takeUnretainedValue()
        return watchdog.shouldStop() ? 1 : 0
    }
}
