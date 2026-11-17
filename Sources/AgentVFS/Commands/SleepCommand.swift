//
//  SleepCommand.swift
//  AgentVFS
//
//  Created by Yevhenii Kalashnikov on 18.11.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

extension CommandContext {
    func sleep(_ arguments: [ShellToken]) async throws -> CommandOutput {
        guard let operand = arguments.first, arguments.count == 1, let seconds = Self.seconds(operand.text) else {
            throw CommandError.usage("sleep: give the wait as one number of seconds, such as sleep 30")
        }
        let longest = limits.maxSleep / .seconds(1)
        guard seconds <= longest else {
            var output = CommandOutput()
            let plainNumber = FloatingPointFormatStyle<Double>(locale: Locale(identifier: "en_US_POSIX"))
                .grouping(.never)
                .precision(.fractionLength(0...3))
            let limit = longest.formatted(plainNumber)
            output.fail("sleep", "a wait lasts at most \(limit) seconds; wait that long, then check again", code: 2)
            return output
        }
        try await Task.sleep(for: .seconds(seconds))
        return CommandOutput()
    }

    /// The number `text` writes with digits and at most one fraction, such as `30` or `0.5`.
    private static func seconds(_ text: String) -> Double? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let digits: ClosedRange<Character> = "0"..."9"
        let isNumber = parts.count <= 2 && parts.allSatisfy { part in
            part.isEmpty == false && part.allSatisfy(digits.contains)
        }
        guard isNumber else {
            return nil
        }
        return Double(text)
    }
}
