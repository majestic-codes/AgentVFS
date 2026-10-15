//
//  InputQueue.swift
//  AgentVFSJQ
//
//  Created by Yevhenii Kalashnikov on 14.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

/// Inputs read from the files in order, in the mode the options ask for.
final class InputQueue: InputSource {
    private let inputs: [JQ.Input]
    private let options: JQ.Options
    private let budget: Budget
    private var fileIndex = -1
    private var parser: JSONStreamParser?
    private var lines: [String] = []
    private var lineIndex = 0
    /// With `--stream`: the events of the value being streamed.
    private var events: StreamEvents?
    private var slurped = false
    private(set) var currentName: String?
    private(set) var currentLine = 0

    init(inputs: [JQ.Input], options: JQ.Options, budget: Budget) {
        self.inputs = inputs
        self.options = options
        self.budget = budget
    }

    /// Where the last input came from, for error messages.
    var location: String {
        guard let currentName else { return "<unknown>" }
        return "\(currentName):\(currentLine)"
    }

    func next() throws -> JSONValue? {
        if options.slurp {
            guard !slurped else { return nil }
            slurped = true
            if options.rawInput {
                currentName = inputs.last?.name
                return .string(inputs.map(\.text).joined())
            }
            let values = try remainingValues()
            return .array(values)
        }
        return try nextValue()
    }

    /// Every value not read yet, as `--slurp` and `--slurpfile` take them.
    func remainingValues() throws -> [JSONValue] {
        var values: [JSONValue] = []
        while let value = try nextValue() {
            values.append(value)
            try Operations.checkSize(arrayCount: values.count)
        }
        return values
    }

    private func nextValue() throws -> JSONValue? {
        if let event = events?.next() { return event }
        events = nil
        while true {
            if options.rawInput {
                if lineIndex < lines.count {
                    lineIndex += 1
                    currentLine = lineIndex
                    return .string(lines[lineIndex - 1])
                }
            } else if let value = try nextParsedValue() {
                guard options.stream else { return value }
                var streamed = StreamEvents(value)
                let first = streamed.next()
                events = streamed
                return first
            }
            fileIndex += 1
            guard fileIndex < inputs.count else { return nil }
            let input = inputs[fileIndex]
            currentName = input.name
            currentLine = 0
            if options.rawInput {
                var split = input.text.components(separatedBy: "\n")
                if split.last?.isEmpty == true { split.removeLast() }
                lines = split
                lineIndex = 0
            } else {
                parser = JSONStreamParser(input.text, budget: budget)
            }
        }
    }

    /// The next value of the current file, or `nil` when there is no file yet or it is used up.
    private func nextParsedValue() throws -> JSONValue? {
        guard var current = parser else { return nil }
        defer { parser = current }
        guard let value = try current.next() else { return nil }
        currentLine = current.currentLine
        return value
    }
}
