//
//  DataTools.swift
//  AgentVFSTools
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import AgentVFSJQ
import AgentVFSPDF
import AgentVFSSQLite

/// The ready-made commands for data files, in one place.
///
///     CommandInterpreter(fileSystem: fileSystem, commands: DataTools.all)
public enum DataTools {
    /// `sqlite3` for SQLite databases, `jq` for JSON, and `pdfinfo`, `pdfgrep` and `pdftotext` for
    /// PDFs, with default limits. Each access makes new commands with caches of their own, so keep
    /// the array for a session rather than reading `all` again.
    public static var all: [any WorkspaceCommand] { commands() }

    /// The same commands with your own limits, `json` being the `jq` command, such as
    /// `DataTools.commands(sqlite: SQLiteCommand(timeout: .seconds(10)), pdf: PDFOptions(maxRecognizedPages: 3))`.
    public static func commands(
        sqlite: SQLiteCommand = SQLiteCommand(),
        json: JQCommand = JQCommand(),
        pdf: PDFOptions = PDFOptions()
    ) -> [any WorkspaceCommand] {
        [sqlite, json] + PDFTools.commands(options: pdf)
    }
}
