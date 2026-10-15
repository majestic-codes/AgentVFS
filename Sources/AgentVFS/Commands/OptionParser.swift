//
//  OptionParser.swift
//  AgentVFS
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

/// Declares which options a command understands.
public struct OptionSpec: Sendable {
    /// Short options without a value, e.g. `r` for `-r`.
    public var flags: Set<String> = []
    /// Short options that take a value, e.g. `m` for `-m 5`.
    public var valueFlags: Set<String> = []
    /// Long options without a value, mapped to their canonical key.
    public var longFlags: [String: String] = [:]
    /// Long options with a value (`--name=value` or `--name value`), mapped to their canonical key.
    public var longValueFlags: [String: String] = [:]
    /// When true, `-5` is read as `-n 5` (for `head` and `tail`).
    public var numericShorthand = false
    /// Extra advice shown when a known-but-unsupported option is used, keyed by option text.
    public var hints: [String: String] = [:]

    /// A specification with these short options and nothing else.
    public init(flags: Set<String> = [], valueFlags: Set<String> = []) {
        self.flags = flags
        self.valueFlags = valueFlags
    }
}

/// The options and operands of one command line, by canonical key.
public struct ParsedArguments: Sendable {
    /// The flags given.
    public var flags: Set<String> = []
    /// Every value given for each option, in order.
    public var values: [String: [String]] = [:]
    /// The operands, in order.
    public var positionals: [String] = []

    /// Whether the flag was given.
    public func has(_ key: String) -> Bool { flags.contains(key) }
    /// The last value given for the option, or `nil`.
    public func value(_ key: String) -> String? { values[key]?.last }
    /// Every value given for the option, in order.
    public func all(_ key: String) -> [String] { values[key] ?? [] }

    /// The value of an option that may be given only once, or `nil` without it. Throws
    /// `CommandError.usage` when it was given more than once.
    public func singleValue(_ key: String, command: String) throws -> String? {
        let given = all(key)
        guard given.count <= 1 else {
            let option = key.count == 1 ? "-" + key : "--" + key
            throw CommandError.usage("\(command): option \(option) may be given only once")
        }
        return given.first
    }
}

/// Parses getopt-style options for a command.
public enum OptionParser {
    /// Splits tokens into flags, option values and positionals. Quoted tokens and everything after
    /// `--` are positionals. Throws `CommandError.usage` for an unknown option or a missing value.
    public static func parse(_ tokens: [ShellToken], spec: OptionSpec, command: String) throws -> ParsedArguments {
        var scanner = OptionScanner(tokens: tokens, specification: spec, command: command)
        try scanner.scan()
        return scanner.parsed
    }
}

/// Walks the tokens of one command line once, filling `parsed`.
private struct OptionScanner {
    let tokens: [ShellToken]
    let specification: OptionSpec
    let command: String
    var parsed = ParsedArguments()
    var index = 0

    mutating func scan() throws {
        var onlyOperands = false
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            let text = token.text
            if onlyOperands || token.isQuoted || !text.hasPrefix("-") || text == "-" {
                parsed.positionals.append(text)
            } else if text == "--" {
                onlyOperands = true
            } else if text.hasPrefix("--") {
                try scanLongOption(String(text.dropFirst(2)))
            } else {
                try scanShortCluster(Array(text.dropFirst()))
            }
        }
    }

    private mutating func scanLongOption(_ body: String) throws {
        let name: String
        var inlineValue: String?
        if let equals = body.firstIndex(of: "=") {
            name = String(body[..<equals])
            inlineValue = String(body[body.index(after: equals)...])
        } else {
            name = body
        }
        if let key = specification.longFlags[name] {
            guard inlineValue == nil else {
                throw CommandError.usage("\(command): option --\(name) does not take a value")
            }
            parsed.flags.insert(key)
        } else if let key = specification.longValueFlags[name] {
            let value = try inlineValue ?? nextValue(for: "--\(name)")
            parsed.values[key, default: []].append(value)
        } else {
            throw unsupported("--\(name)")
        }
    }

    private mutating func scanShortCluster(_ cluster: [Character]) throws {
        if specification.numericShorthand, cluster.allSatisfy(\.isNumber) {
            parsed.values["n", default: []].append(String(cluster))
            return
        }
        var position = 0
        while position < cluster.count {
            let letter = String(cluster[position])
            position += 1
            if specification.flags.contains(letter) {
                parsed.flags.insert(letter)
            } else if specification.valueFlags.contains(letter) {
                let attached = position < cluster.count ? String(cluster[position...]) : nil
                let value = try attached ?? nextValue(for: "-\(letter)")
                parsed.values[letter, default: []].append(value)
                return
            } else {
                throw unsupported("-\(letter)")
            }
        }
    }

    /// The token after an option that takes a value.
    private mutating func nextValue(for option: String) throws -> String {
        guard index < tokens.count else {
            throw CommandError.usage("\(command): option \(option) requires a value")
        }
        defer { index += 1 }
        return tokens[index].text
    }

    private func unsupported(_ option: String) -> CommandError {
        let hint = specification.hints[option].map { " (\($0))" } ?? ""
        return .usage("\(command): unsupported option \(option)\(hint)")
    }
}
