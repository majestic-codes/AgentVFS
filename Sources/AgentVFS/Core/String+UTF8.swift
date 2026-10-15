//
//  String+UTF8.swift
//  AgentVFS
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

extension String {
    /// The text without a leading U+FEFF, which only marks the encoding and is not content.
    var removingByteOrderMark: String {
        hasPrefix("\u{FEFF}") ? String(dropFirst()) : self
    }

    /// Decodes UTF-8 bytes, replacing each invalid sequence with U+FFFD. File contents and output
    /// cut at a byte limit need this lossy decoding: a failable decode would drop the whole text.
    package init(repairingUTF8 bytes: some Collection<UInt8>) {
        self.init(unsafeUninitializedCapacity: bytes.count) { buffer in
            buffer.initialize(fromContentsOf: bytes)
        }
    }

    /// The text's lines as UTF-8 slices, without their `\n`. A final `\n` ends the last line
    /// rather than starting an empty one.
    var lineSlices: [Substring.UTF8View] {
        var pieces = utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if utf8.last == UInt8(ascii: "\n") {
            pieces.removeLast()
        }
        return pieces
    }
}
