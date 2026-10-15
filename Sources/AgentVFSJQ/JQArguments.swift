//
//  JQArguments.swift
//  AgentVFSJQ
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import Foundation

/// The `jq` command line, parsed.
struct JQArguments {
    /// How operands after `--args` or `--jsonargs` are read.
    private enum PositionalMode {
        case strings
        case json
    }

    var options = JQ.Options()
    var filter: String?
    /// `-f FILE`: the filter is read from this file.
    var filterFile: String?
    var operands: [String] = []
    /// `--slurpfile NAME FILE`, in order.
    var slurpFiles: [(name: String, path: String)] = []
    /// `--rawfile NAME FILE`, in order.
    var rawFiles: [(name: String, path: String)] = []
    /// `-h`: print the usage and nothing else.
    var showHelp = false

    private let tokens: [ShellToken]
    private let usage: String
    private var index = 0
    private var positionalMode: PositionalMode?
    private var onlyOperands = false

    /// Parses `tokens`, stopping at `-h`. Throws `CommandError.usage` for an unknown option or a
    /// missing or invalid option value.
    init(_ tokens: [ShellToken], usage: String) throws {
        self.tokens = tokens
        self.usage = usage
        while index < tokens.count, !showHelp {
            let token = tokens[index]
            let text = token.text
            if onlyOperands || token.isQuoted || !text.hasPrefix("-") || text == "-" {
                try addOperand(text)
            } else {
                try parseOption(text)
            }
            index += 1
        }
    }

    private mutating func addOperand(_ text: String) throws {
        if filter == nil && filterFile == nil {
            filter = text
            return
        }
        switch positionalMode {
        case .json:
            let argument = try Self.parseJSON(text, option: "--jsonargs")
            options.positionalArguments.append(argument)
        case .strings: options.positionalArguments.append(.string(text))
        case nil: operands.append(text)
        }
    }

    /// The parameter after the current option.
    private mutating func value(_ option: String) throws -> String {
        index += 1
        guard index < tokens.count else { throw CommandError.usage("jq: \(option) takes a parameter") }
        return tokens[index].text
    }

    private mutating func parseOption(_ text: String) throws {
        if let flag = Self.longFlag(text) {
            options[keyPath: flag] = true
            return
        }
        switch text {
        case "--": onlyOperands = true
        case "--color-output", "--monochrome-output", "--unbuffered": break
        case "--indent":
            let raw = try value(text)
            options.indent = try indent(raw)
        case "--arg":
            let name = try value(text)
            let argument = try value(text)
            options.namedArguments.append((name, .string(argument)))
        case "--argjson":
            let name = try value(text)
            let raw = try value(text)
            let parsed = try Self.parseJSON(raw, option: "--argjson")
            options.namedArguments.append((name, parsed))
        case "--slurpfile":
            let name = try value(text)
            let path = try value(text)
            slurpFiles.append((name, path))
        case "--rawfile":
            let name = try value(text)
            let path = try value(text)
            rawFiles.append((name, path))
        case "--args": positionalMode = .strings
        case "--jsonargs": positionalMode = .json
        case "-f", "--from-file": filterFile = try value(text)
        case "-h", "--help": showHelp = true
        default:
            guard !text.hasPrefix("--"), text.count > 1 else {
                throw CommandError.usage("jq: Unknown option: \(text)\n\(usage)")
            }
            for flag in text.dropFirst() { try setShortFlag(flag) }
        }
    }

    private func indent(_ text: String) throws -> Int {
        guard let indent = Int(text), indent >= 0 else { throw CommandError.usage("jq: --indent takes a number") }
        guard indent <= 7 else { throw CommandError.usage("jq: Cannot indent more than 7 characters") }
        return indent
    }

    private mutating func setShortFlag(_ flag: Character) throws {
        switch flag {
        case "r": options.rawOutput = true
        case "j": options.joinOutput = true
        case "a": options.asciiOutput = true
        case "c": options.compactOutput = true
        case "n": options.nullInput = true
        case "s": options.slurp = true
        case "R": options.rawInput = true
        case "e": options.exitStatus = true
        case "S": options.sortKeys = true
        case "C", "M": break
        default: throw CommandError.usage("jq: Unknown option: -\(flag)\n\(usage)")
        }
    }

    /// The option a long flag such as `--slurp` turns on, or `nil` when `text` is not one.
    private static func longFlag(_ text: String) -> WritableKeyPath<JQ.Options, Bool>? {
        switch text {
        case "--raw-output": \.rawOutput
        case "--join-output": \.joinOutput
        case "--ascii-output": \.asciiOutput
        case "--compact-output": \.compactOutput
        case "--null-input": \.nullInput
        case "--slurp": \.slurp
        case "--raw-input": \.rawInput
        case "--exit-status": \.exitStatus
        case "--sort-keys": \.sortKeys
        case "--stream": \.stream
        case "--tab": \.tab
        default: nil
        }
    }

    private static func parseJSON(_ text: String, option: String) throws -> JSONValue {
        do {
            return try JQ.parse(text)
        } catch {
            throw CommandError.usage("jq: Invalid JSON text passed to \(option)")
        }
    }
}
