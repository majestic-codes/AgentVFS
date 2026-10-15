//
//  FileCommands.swift
//  AgentVFS
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

extension CommandContext {
    // MARK: cd

    func changeDirectory(_ arguments: [ShellToken]) async throws -> CommandOutput {
        var output = CommandOutput()
        let operands = arguments.map(\.text)
        guard operands.count <= 1 else {
            output.fail("cd", "too many arguments", code: 1)
            return output
        }
        do {
            let target = if let operand = operands.first {
                try resolvePath(operand)
            } else {
                VFSPath.root
            }
            let entry = try await fileSystem.stat(path: target.description)
            guard entry.kind == .directory else {
                throw VFSError.notADirectory(target.description)
            }
            output.newWorkingDirectory = target
        } catch let error as VFSError {
            output.fail("cd", describe(error), code: 1)
        }
        return output
    }

    // MARK: ls

    func list(_ arguments: [ShellToken]) async throws -> CommandOutput {
        var specification = OptionSpec(flags: ["l", "a", "A", "1"])
        specification.hints["-R"] = "use find to walk a tree"
        let parsed = try OptionParser.parse(arguments, spec: specification, command: "ls")
        let long = parsed.has("l")
        let operands = parsed.positionals.isEmpty ? [workingDirectory.description] : parsed.positionals
        var output = CommandOutput()
        for (index, operand) in operands.enumerated() {
            do {
                let path = try resolvePath(operand)
                let entry = try await fileSystem.stat(path: path.description)
                if entry.kind == .directory {
                    if operands.count > 1 {
                        if index > 0 { output.line("") }
                        output.line("\(path.description):")
                    }
                    for child in try await fileSystem.list(path: path.description) {
                        output.line(Self.format(child, long: long))
                    }
                } else {
                    output.line(long ? Self.format(entry, long: true, name: path.description) : path.description)
                }
            } catch let error as VFSError {
                output.fail("ls", describe(error), code: 2)
            }
        }
        return output
    }

    private static func format(_ entry: FileEntry, long: Bool, name: String? = nil) -> String {
        let label = name ?? entry.name
        if long {
            switch entry.kind {
            case .directory: return "d - \(label)"
            case .symbolicLink: return "l - \(label)"
            case .submodule: return "s - \(label)"
            case .file: return "- \(entry.size ?? 0) \(label)"
            }
        }
        switch entry.kind {
        case .directory: return label + "/"
        case .symbolicLink: return label + "@"
        case .submodule: return label + " (submodule)"
        case .file: return label
        }
    }

    // MARK: cat

    func concatenate(_ arguments: [ShellToken]) async throws -> CommandOutput {
        let parsed = try OptionParser.parse(arguments, spec: OptionSpec(flags: ["n"]), command: "cat")
        if parsed.positionals.isEmpty, let standardInput {
            return Self.catenated(standardInput, numbered: parsed.has("n"))
        }
        guard !parsed.positionals.isEmpty else {
            throw CommandError.usage("cat: missing file operand (pass a file path)")
        }
        var output = CommandOutput()
        var lineNumber = 0
        for operand in parsed.positionals where !output.isFull {
            do {
                let path = try resolvePath(operand)
                let file = try await fileSystem.readText(path: path.description)
                if parsed.has("n") {
                    for line in Self.lines(of: file.text) where !output.isFull {
                        lineNumber += 1
                        output.line(String(format: "%6d\t", lineNumber) + line)
                    }
                } else {
                    output.content(file.text)
                }
            } catch let VFSError.fileTooLarge(path, size, limit) {
                let message = "\(path): \(size) bytes is more than cat prints (\(limit)); "
                    + "read parts with head, tail, sed -n 'START,ENDp' or grep"
                output.fail("cat", message, code: 1)
            } catch let error as VFSError {
                output.fail("cat", describe(error), code: 1)
            }
        }
        return output
    }

    private static func catenated(_ text: String, numbered: Bool) -> CommandOutput {
        var output = CommandOutput()
        guard numbered else {
            output.content(text)
            return output
        }
        for (index, line) in lines(of: text).enumerated() where !output.isFull {
            output.line(String(format: "%6d\t", index + 1) + line)
        }
        return output
    }

    // MARK: head and tail

    func headOrTail(_ arguments: [ShellToken], command: String) async throws -> CommandOutput {
        var specification = OptionSpec(valueFlags: ["n"])
        specification.numericShorthand = true
        let parsed = try OptionParser.parse(arguments, spec: specification, command: command)
        let selection = try LineSelection(command: command, count: parsed.value("n"))
        if parsed.positionals.isEmpty, let input = pipedText {
            var output = CommandOutput()
            for line in try selection.lines(of: input, cap: limits.maxLines + 1, deadline: deadline) {
                output.line(line)
            }
            return output
        }
        guard !parsed.positionals.isEmpty else {
            throw CommandError.usage("\(command): missing file operand (pass a file path or pipe text in)")
        }
        var output = CommandOutput()
        for (index, operand) in parsed.positionals.enumerated() where !output.isFull {
            do {
                // Read line by line, so files far larger than a whole read allows still work.
                let path = try resolvePath(operand)
                let file = try await fileSystem.largeText(path: path.description)
                if parsed.positionals.count > 1 {
                    if index > 0 { output.line("") }
                    output.line("==> \(file.path) <==")
                }
                for line in try selection.lines(of: file, cap: limits.maxLines + 1, deadline: deadline) {
                    output.line(line)
                }
            } catch let error as VFSError {
                output.fail(command, describe(error), code: 1)
            }
        }
        return output
    }

    // MARK: sed

    func streamEdit(_ arguments: [ShellToken]) async throws -> CommandOutput {
        let usage = "sed: only \"sed -n 'START,ENDp' FILE\" (print a line range) is supported"
        let specification = OptionSpec(flags: ["n"], valueFlags: ["e"])
        let parsed = try OptionParser.parse(arguments, spec: specification, command: "sed")
        var operands = parsed.positionals
        let script: String
        if let option = try parsed.singleValue("e", command: "sed") {
            script = option
        } else if !operands.isEmpty {
            script = operands.removeFirst()
        } else {
            throw CommandError.usage(usage)
        }
        guard parsed.has("n"), let range = Self.parseLineRange(script) else {
            throw CommandError.usage(usage)
        }
        if operands.isEmpty, let input = pipedText {
            var output = CommandOutput()
            let limit = limits.maxLines + 1
            let lines = try input.lines(from: range.start, through: range.end, limit: limit, deadline: deadline)
            for line in lines {
                output.line(line)
            }
            return output
        }
        guard operands.count == 1, let operand = operands.first else {
            throw CommandError.usage("sed: give exactly one file, or pipe text in")
        }
        var output = CommandOutput()
        do {
            let path = try resolvePath(operand)
            let file = try await fileSystem.largeText(path: path.description)
            let limit = limits.maxLines + 1
            let lines = try file.lines(from: range.start, through: range.end, limit: limit, deadline: deadline)
            for line in lines {
                output.line(line)
            }
        } catch let error as VFSError {
            output.fail("sed", describe(error), code: 1)
        }
        return output
    }

    /// Parses `N`, `N,M` or `N,$` followed by `p`. `end == nil` means the last line.
    static func parseLineRange(_ script: String) -> (start: Int, end: Int?)? {
        guard script.hasSuffix("p") else { return nil }
        let body = script.dropLast()
        let parts = body.split(separator: ",", omittingEmptySubsequences: false)
        guard let first = parts.first, let start = Int(first), start >= 1 else { return nil }
        switch parts.count {
        case 1:
            return (start, start)
        case 2:
            if parts[1] == "$" { return (start, nil) }
            guard let end = Int(parts[1]), end >= start else { return nil }
            return (start, end)
        default:
            return nil
        }
    }

    // MARK: find

    func find(_ arguments: [ShellToken]) async throws -> CommandOutput {
        let (paths, query) = try parseFindArguments(arguments)
        var output = CommandOutput()
        for operand in paths.isEmpty ? ["."] : paths {
            do {
                let path = try resolvePath(operand)
                let findResult = try await fileSystem.find(path: path.description, query: query)
                for entry in findResult.entries {
                    output.line(entry.path)
                }
                if !findResult.isComplete {
                    let reasons = findResult.truncation.map(\.message).joined(separator: "; ")
                    output.error("[find incomplete: \(reasons). Results may be missing.]", code: 0)
                }
            } catch let error as VFSError {
                output.fail("find", describe(error), code: 1)
            }
        }
        return output
    }

    /// Splits `find` arguments into the leading paths and the query built from the predicates after them.
    private func parseFindArguments(_ arguments: [ShellToken]) throws -> (paths: [String], query: FindQuery) {
        var paths: [String] = []
        var index = 0
        while index < arguments.count, arguments[index].isQuoted || !arguments[index].text.hasPrefix("-") {
            paths.append(arguments[index].text)
            index += 1
        }
        var query = FindQuery(limit: limits.maxFindEntries)
        let supported = "-name, -iname, -type, -maxdepth, -mindepth"

        func value(for predicate: String) throws -> String {
            guard index < arguments.count else {
                throw CommandError.usage("find: missing argument to \(predicate)")
            }
            defer { index += 1 }
            return arguments[index].text
        }

        func number(for predicate: String) throws -> Int {
            let raw = try value(for: predicate)
            guard let parsed = Int(raw), parsed >= 0 else {
                throw CommandError.usage("find: invalid argument '\(raw)' to \(predicate)")
            }
            return parsed
        }

        var seen = Set<String>()
        while index < arguments.count {
            let predicate = arguments[index].text
            index += 1
            try Self.checkGivenOnce(predicate, seen: &seen)
            switch predicate {
            case "-name":
                query.namePattern = try value(for: predicate)
                query.caseInsensitive = false
            case "-iname":
                query.namePattern = try value(for: predicate)
                query.caseInsensitive = true
            case "-type":
                let letter = try value(for: predicate)
                let kind = try Self.entryKind(forType: letter)
                query.kinds = [kind]
            case "-maxdepth":
                query.maxDepth = try number(for: predicate)
            case "-mindepth":
                query.minDepth = try number(for: predicate)
            case "-print":
                continue
            default:
                throw CommandError.usage("find: unsupported expression '\(predicate)'; supported: \(supported)")
            }
        }
        return (paths, query)
    }

    /// Throws `CommandError.usage` for a predicate given before. `-name` and `-iname` count as one.
    private static func checkGivenOnce(_ predicate: String, seen: inout Set<String>) throws {
        let group = predicate == "-iname" ? "-name" : predicate
        guard ["-name", "-type", "-maxdepth", "-mindepth"].contains(group) else { return }
        guard seen.insert(group).inserted else {
            let message = "find: give \(predicate) once; combining several is not available, run one find per value"
            throw CommandError.usage(message)
        }
    }

    /// The entry kind a `find -type` letter selects.
    private static func entryKind(forType letter: String) throws -> EntryKind {
        switch letter {
        case "f": .file
        case "d": .directory
        case "l": .symbolicLink
        default: throw CommandError.usage("find: unknown argument to -type: \(letter) (use f, d or l)")
        }
    }
}

/// Which lines `head` or `tail` print, from the `-n` option.
private struct LineSelection {
    let command: String
    /// How many lines to print, 10 unless `-n N` says otherwise.
    var count = 10
    /// The first line `tail -n +N` prints. `nil` prints the last `count` lines instead.
    var fromLine: Int?

    init(command: String, count raw: String?) throws {
        self.command = command
        guard let raw else { return }
        if command == "tail", raw.hasPrefix("+"), let start = Int(raw.dropFirst()), start >= 0 {
            fromLine = max(start, 1)
        } else if let value = Int(raw), value >= 0 {
            count = value
        } else {
            throw CommandError.usage("\(command): invalid number of lines: '\(raw)'")
        }
    }

    /// The selected lines, at most `cap`. One line more than the output can hold is enough to make the
    /// interpreter say the output was truncated.
    func lines(of file: LargeText, cap: Int, deadline: ContinuousClock.Instant) throws -> [String] {
        if command == "head" {
            return try file.lines(from: 1, through: count, limit: min(count, cap), deadline: deadline)
        }
        if let fromLine {
            return try file.lines(from: fromLine, through: nil, limit: cap, deadline: deadline)
        }
        return try file.lastLines(min(count, cap), deadline: deadline)
    }
}
