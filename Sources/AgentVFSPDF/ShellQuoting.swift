//
//  ShellQuoting.swift
//  AgentVFSPDF
//
//  Created by Yevhenii Kalashnikov on 15.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

/// Writes words into the command lines the PDF commands suggest, so they run as shown.
enum ShellQuoting {
    /// Characters the shell reads as something other than part of a word.
    private static let special = Set(" \t\n\r'\"\\|&;<>()$`*?[]{}#~!".unicodeScalars)

    /// `word` as it is when it has no special characters, otherwise in single quotes, with each
    /// `'` inside written as `'\''`.
    static func quoted(_ word: String) -> String {
        guard word.isEmpty || word.unicodeScalars.contains(where: special.contains) else { return word }
        return "'" + word.replacing("'", with: #"'\''"#) + "'"
    }
}
