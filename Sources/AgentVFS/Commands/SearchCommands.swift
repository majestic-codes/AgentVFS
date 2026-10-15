//
//  SearchCommands.swift
//  AgentVFS
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

enum SearchOutputMode {
    case lines
    case filesWithMatches
    case count
}

struct SearchRequest {
    var command: String
    var pattern: String
    var options: SearchOptions
    var operands: [String]
    var showFilename: Bool
    var showLineNumbers: Bool
    var mode: SearchOutputMode
    var recursive: Bool
    /// Rebase globs that contain `/` onto the searched directory, as ripgrep does.
    var rebaseGlobs: Bool
    /// Leave out messages about files that cannot be searched (`grep -s`). The exit status still says so.
    var suppressErrors = false
    /// Lines of context printed before and after each match (`-B`, `-A`, `-C`).
    var before = 0
    var after = 0
}

/// Larger context is refused: reading a whole region is what `sed -n` is for.
private let maxContextLines = 50

private let ripgrepTypes: [String: [String]] = [
    "swift": ["*.swift"],
    "kotlin": ["*.kt", "*.kts"], "kt": ["*.kt", "*.kts"],
    "java": ["*.java"],
    "objc": ["*.m", "*.mm", "*.h"],
    "c": ["*.c", "*.h"],
    "cpp": ["*.cpp", "*.cc", "*.cxx", "*.hpp", "*.hh", "*.h"],
    "js": ["*.js", "*.mjs", "*.cjs", "*.jsx"],
    "ts": ["*.ts", "*.tsx"],
    "py": ["*.py"], "python": ["*.py"],
    "rb": ["*.rb"], "ruby": ["*.rb"],
    "go": ["*.go"],
    "rust": ["*.rs"],
    "md": ["*.md", "*.markdown"], "markdown": ["*.md", "*.markdown"],
    "json": ["*.json"],
    "yaml": ["*.yml", "*.yaml"],
    "xml": ["*.xml"],
    "html": ["*.html", "*.htm"],
    "css": ["*.css", "*.scss"],
    "sh": ["*.sh", "*.bash", "*.zsh"],
    "gradle": ["*.gradle", "*.gradle.kts"],
    "plist": ["*.plist"]
]

extension CommandContext {
    // MARK: grep

    /// `-I` (skip binary files) describes what every search does, so it is accepted as it is.
    private static let grepSpecification: OptionSpec = {
        var specification = OptionSpec(
            flags: ["r", "R", "n", "i", "E", "F", "G", "w", "l", "c", "H", "h", "s", "I"],
            valueFlags: ["m", "e", "A", "B", "C"]
        )
        specification.longFlags = [
            "recursive": "r", "dereference-recursive": "R", "line-number": "n", "ignore-case": "i",
            "extended-regexp": "E", "fixed-strings": "F", "basic-regexp": "G", "word-regexp": "w",
            "files-with-matches": "l", "count": "c", "with-filename": "H", "no-filename": "h", "no-messages": "s"
        ]
        specification.longValueFlags = [
            "max-count": "m", "regexp": "e", "include": "include", "exclude": "exclude",
            "exclude-dir": "exclude-dir", "after-context": "A", "before-context": "B", "context": "C"
        ]
        specification.hints = [
            "-v": "inverted matching is not available",
            "-o": "only-matching output is not available",
            "-P": "Perl regular expressions are not available; use -E",
            "-a": "binary files are never searched"
        ]
        return specification
    }()

    func grep(_ arguments: [ShellToken]) async throws -> CommandOutput {
        let parsed = try OptionParser.parse(arguments, spec: Self.grepSpecification, command: "grep")
        var operands = parsed.positionals
        let patterns = try Self.takePatterns(parsed, operands: &operands, command: "grep")
        let syntax = try Self.grepSyntax(parsed)
        let pattern = try Self.combine(patterns, syntax: syntax, command: "grep")
        let recursive = parsed.has("r") || parsed.has("R")
        let readsPipe = operands.isEmpty && !recursive && standardInput != nil
        if operands.isEmpty, !readsPipe {
            guard recursive else {
                let message = "grep: no input files (pass a file, use -r to search a directory, or pipe text in)"
                throw CommandError.usage(message)
            }
            operands = ["."]
        }
        let excludedDirectories = parsed.all("exclude-dir").flatMap { [$0 + "/**", "**/" + $0 + "/**"] }
        let maxMatchesPerFile = try Self.maxMatchesPerFile(parsed, command: "grep")
        let options = SearchOptions(
            syntax: syntax,
            caseInsensitive: parsed.has("i"),
            wholeWord: parsed.has("w"),
            includeGlobs: parsed.all("include"),
            excludeGlobs: parsed.all("exclude") + excludedDirectories,
            maxMatches: Self.matchLimit(parsed, limits: limits),
            maxMatchesPerFile: maxMatchesPerFile,
            maxFileBytes: limits.maxSearchFileBytes,
            timeout: limits.timeLimit
        )
        let showFilename = !parsed.has("h") && (parsed.has("H") || recursive || operands.count > 1)
        let context = try Self.contextLines(parsed, command: "grep")
        let request = SearchRequest(
            command: "grep",
            pattern: pattern,
            options: options,
            operands: operands,
            showFilename: showFilename,
            showLineNumbers: parsed.has("n"),
            mode: Self.outputMode(parsed),
            recursive: recursive,
            rebaseGlobs: false,
            suppressErrors: parsed.has("s"),
            before: context.before,
            after: context.after
        )
        if readsPipe, let input = pipedText {
            return try searchStandardInput(request, input: input)
        }
        return try await runSearch(request)
    }

    // MARK: rg

    /// `-u`, `--hidden`, `--no-ignore` and `--no-heading` describe what every search does (hidden
    /// files are searched, ignore files are not read, matches are printed one per line), so they are
    /// accepted as they are.
    private static let ripgrepSpecification: OptionSpec = {
        var specification = OptionSpec(
            flags: ["i", "n", "N", "H", "I", "s", "S", "F", "w", "l", "c", "u"],
            valueFlags: ["e", "g", "t", "m", "A", "B", "C"]
        )
        specification.longFlags = [
            "files": "files", "no-heading": "u", "hidden": "u", "no-ignore": "u", "unrestricted": "u",
            "line-number": "n", "no-line-number": "N", "ignore-case": "i", "fixed-strings": "F",
            "word-regexp": "w", "files-with-matches": "l", "count": "c", "case-sensitive": "s",
            "smart-case": "S", "with-filename": "H", "no-filename": "I"
        ]
        specification.longValueFlags = [
            "glob": "g", "type": "t", "max-count": "m", "regexp": "e", "color": "color",
            "after-context": "A", "before-context": "B", "context": "C"
        ]
        specification.hints = [
            "-v": "inverted matching is not available",
            "-o": "only-matching output is not available",
            "-P": "PCRE2 is not available",
            "-a": "binary files are never searched",
            "--text": "binary files are never searched",
            "--heading": "matches are printed one per line with their path"
        ]
        return specification
    }()

    func ripgrep(_ arguments: [ShellToken]) async throws -> CommandOutput {
        let parsed = try OptionParser.parse(arguments, spec: Self.ripgrepSpecification, command: "rg")
        if let color = try parsed.singleValue("color", command: "rg"), !["never", "auto"].contains(color) {
            throw CommandError.usage("rg: output is never colored; --color takes never or auto, not '\(color)'")
        }
        let (includes, excludes) = try Self.ripgrepGlobs(parsed)
        if parsed.has("files") {
            return try await listFiles(operands: parsed.positionals, includes: includes, excludes: excludes)
        }
        var operands = parsed.positionals
        let patterns = try Self.takePatterns(parsed, operands: &operands, command: "rg")
        let syntax: PatternSyntax = parsed.has("F") ? .fixed : .extended
        let pattern = try Self.combine(patterns, syntax: syntax, command: "rg")
        let smartCase = parsed.has("S") && !parsed.has("s") && pattern == pattern.lowercased()
        let maxMatchesPerFile = try Self.maxMatchesPerFile(parsed, command: "rg")
        let options = SearchOptions(
            syntax: syntax,
            caseInsensitive: parsed.has("i") || smartCase,
            wholeWord: parsed.has("w"),
            includeGlobs: includes,
            excludeGlobs: excludes,
            maxMatches: Self.matchLimit(parsed, limits: limits),
            maxMatchesPerFile: maxMatchesPerFile,
            maxFileBytes: limits.maxSearchFileBytes,
            timeout: limits.timeLimit
        )
        let context = try Self.contextLines(parsed, command: "rg")
        let readsPipe = operands.isEmpty && standardInput != nil
        let showFilename = try Self.ripgrepShows(parsed, on: "H", off: "I", byDefault: !readsPipe)
        let showLineNumbers = try Self.ripgrepShows(parsed, on: "n", off: "N", byDefault: !readsPipe)
        let request = SearchRequest(
            command: "rg",
            pattern: pattern,
            options: options,
            operands: operands.isEmpty ? ["."] : operands,
            showFilename: showFilename,
            showLineNumbers: showLineNumbers,
            mode: Self.outputMode(parsed),
            recursive: true,
            rebaseGlobs: true,
            before: context.before,
            after: context.after
        )
        if readsPipe, let input = pipedText {
            return try searchStandardInput(request, input: input)
        }
        return try await runSearch(request)
    }

    /// Whether rg prints a column switched on by one flag and off by another. Which of the two came
    /// last is not known, so giving both is refused.
    private static func ripgrepShows(
        _ parsed: ParsedArguments,
        on shownFlag: String,
        off hiddenFlag: String,
        byDefault: Bool
    ) throws -> Bool {
        switch (parsed.has(shownFlag), parsed.has(hiddenFlag)) {
        case (true, true):
            throw CommandError.usage("rg: -\(shownFlag) and -\(hiddenFlag) contradict each other; give one")
        case (true, false): true
        case (false, true): false
        case (false, false): byDefault
        }
    }

    /// The include and exclude globs from `-g` (a leading `!` excludes) and `-t`.
    private static func ripgrepGlobs(_ parsed: ParsedArguments) throws -> (includes: [String], excludes: [String]) {
        var includes: [String] = []
        var excludes: [String] = []
        for glob in parsed.all("g") {
            if glob.hasPrefix("!") {
                excludes.append(String(glob.dropFirst()))
            } else {
                includes.append(glob)
            }
        }
        for type in parsed.all("t") {
            guard let globs = ripgrepTypes[type] else {
                let known = ripgrepTypes.keys.sorted().joined(separator: ", ")
                throw CommandError.usage("rg: unknown file type '\(type)'; known types: \(known)")
            }
            includes.append(contentsOf: globs)
        }
        return (includes, excludes)
    }

    private func listFiles(operands: [String], includes: [String], excludes: [String]) async throws -> CommandOutput {
        var output = CommandOutput()
        for operand in operands.isEmpty ? ["."] : operands {
            do {
                let root = try resolvePath(operand)
                let base = root.mountPath
                let includeSet = try GlobSet(includes.map { Self.rebase($0, onto: base) })
                let excludeSet = try GlobSet(excludes.map { Self.rebase($0, onto: base) })
                let query = FindQuery(kinds: [.file], limit: limits.maxFindEntries)
                let findResult = try await fileSystem.find(path: root.description, query: query)
                for entry in findResult.entries {
                    let path = try VFSPath(normalizing: entry.path, relativeTo: .root)
                    let mountPath = path.mountPath
                    if !includeSet.isEmpty, !includeSet.matches(name: path.name, mountPath: mountPath) { continue }
                    if excludeSet.matches(name: path.name, mountPath: mountPath) { continue }
                    output.line(entry.path)
                }
                if !findResult.isComplete {
                    let reasons = findResult.truncation.map(\.message).joined(separator: "; ")
                    output.error("[file list incomplete: \(reasons). Results may be missing.]", code: 0)
                }
            } catch let error as VFSError {
                output.fail("rg", describe(error), code: 2)
            }
        }
        return output
    }

    // MARK: Shared option handling

    /// The `-e` patterns, or else the first operand, which is then removed from `operands`.
    private static func takePatterns(
        _ parsed: ParsedArguments,
        operands: inout [String],
        command: String
    ) throws -> [String] {
        let patterns = parsed.all("e")
        guard patterns.isEmpty else { return patterns }
        guard !operands.isEmpty else {
            throw CommandError.usage("\(command): missing pattern")
        }
        return [operands.removeFirst()]
    }

    /// The syntax `-E`, `-F` or `-G` selects, basic by default. Throws `CommandError.usage` for more
    /// than one of them.
    private static func grepSyntax(_ parsed: ParsedArguments) throws -> PatternSyntax {
        let selected: [(flag: String, syntax: PatternSyntax)] = [("E", .extended), ("F", .fixed), ("G", .basic)]
            .filter { parsed.has($0.0) }
        guard selected.count <= 1 else {
            throw CommandError.usage("grep: -E, -F and -G conflict; give one of them")
        }
        return selected.first?.syntax ?? .basic
    }

    /// The `-m N` limit, or `nil` without it.
    private static func maxMatchesPerFile(_ parsed: ParsedArguments, command: String) throws -> Int? {
        guard let raw = parsed.value("m") else { return nil }
        guard let count = Int(raw), count > 0 else {
            throw CommandError.usage("\(command): invalid max count '\(raw)'")
        }
        return count
    }

    /// Matches collected: those shown, or for `-c` and `-l`, which print no lines, enough to count them.
    private static func matchLimit(_ parsed: ParsedArguments, limits: OutputLimits) -> Int {
        let printsLines = outputMode(parsed) == .lines
        return printsLines ? limits.maxSearchMatches : max(limits.maxSearchMatches, OutputLimits.maxCollectedEntries)
    }

    private static func outputMode(_ parsed: ParsedArguments) -> SearchOutputMode {
        parsed.has("l") ? .filesWithMatches : (parsed.has("c") ? .count : .lines)
    }

    private static func combine(_ patterns: [String], syntax: PatternSyntax, command: String) throws -> String {
        guard patterns.count > 1 else { return patterns.first ?? "" }
        switch syntax {
        case .fixed:
            let message = "\(command): several patterns are not supported together with fixed strings; "
                + "run one search per string"
            throw CommandError.usage(message)
        case .basic:
            return patterns.joined(separator: "\\|")
        case .extended:
            return patterns.map { "(?:\($0))" }.joined(separator: "|")
        }
    }

    /// `-A N`, `-B N` and `-C N`. `-C` sets both sides, and `-A`/`-B` override it.
    private static func contextLines(_ parsed: ParsedArguments, command: String) throws -> (before: Int, after: Int) {
        func number(_ key: String) throws -> Int? {
            guard let raw = parsed.value(key) else { return nil }
            guard let value = Int(raw), value >= 0 else {
                throw CommandError.usage("\(command): invalid context length '\(raw)'")
            }
            guard value <= maxContextLines else {
                let message = "\(command): context of more than \(maxContextLines) lines is not available; "
                    + "read a region with sed -n 'START,ENDp' FILE"
                throw CommandError.usage(message)
            }
            return value
        }
        let both = try number("C") ?? 0
        let before = try number("B") ?? both
        let after = try number("A") ?? both
        return (before, after)
    }

    /// Prefixes a glob that contains `/` with the mount path of the searched directory, as ripgrep does.
    static func rebase(_ glob: String, onto base: String) -> String {
        guard glob.contains("/"), !base.isEmpty, !glob.hasPrefix("**/") else { return glob }
        return base + "/" + glob
    }
}
