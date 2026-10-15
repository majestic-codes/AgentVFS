//
//  TerminalText.swift
//  AgentVFS
//
//  Created by Yevhenii Kalashnikov on 15.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

/// Text made safe to write to a terminal.
public enum TerminalText {
    /// `text` with every C0 and C1 control character except tab and line feed written as `\u{XX}`,
    /// so file content cannot move the cursor, recolor the screen or retitle the window.
    public static func escaped(_ text: String) -> String {
        var escaped = ""
        escaped.unicodeScalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            if isControl(scalar) {
                escaped += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
            } else {
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A: false
        case 0x00..<0x20, 0x7F...0x9F: true
        default: false
        }
    }
}
