//
//  WorkspaceCommand.swift
//  AgentVFS
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

/// How much a command may print, and how much it may search, per call.
public struct OutputLimits: Sendable, Hashable {
    /// Bytes of output the agent sees. Longer output is cut with a note.
    public var maxBytes: Int
    /// Lines of output the agent sees.
    public var maxLines: Int
    /// Matches requested from the search engine per path.
    public var maxSearchMatches: Int
    /// Entries `find` returns.
    public var maxFindEntries: Int
    /// Files larger than this are not searched.
    public var maxSearchFileBytes: Int
    /// Output one command in a pipeline may pass to the next. Only the last command's output is
    /// held to `maxBytes`, so `sort | uniq -c` or `wc -l` see the whole data.
    public var maxPipeBytes: Int
    /// How long one command may run. A command past it stops with "time limit reached". This is the
    /// ceiling for every command, and a tool's own timeout, such as `sqlite3`'s, can only shorten it.
    public var timeLimit: Duration

    /// Limits that suit a model's context window.
    public init(
        maxBytes: Int = 40_000,
        maxLines: Int = 1000,
        maxSearchMatches: Int = 500,
        maxFindEntries: Int = 1000,
        maxSearchFileBytes: Int = 512_000,
        maxPipeBytes: Int = 8_000_000,
        timeLimit: Duration = .seconds(15)
    ) {
        self.maxBytes = maxBytes
        self.maxLines = maxLines
        self.maxSearchMatches = maxSearchMatches
        self.maxFindEntries = maxFindEntries
        self.maxSearchFileBytes = maxSearchFileBytes
        self.maxPipeBytes = maxPipeBytes
        self.timeLimit = timeLimit
    }

    /// Largest value a count limit may have, so the limit plus one still fits in an `Int`.
    static let maxCount = Int.max / 2

    /// Throws `VFSError.invalidConfiguration` unless every count is between 1 and `Int.max / 2`
    /// and the time limit is positive.
    public func validate() throws {
        let counts = [
            ("maxBytes", maxBytes), ("maxLines", maxLines), ("maxSearchMatches", maxSearchMatches),
            ("maxFindEntries", maxFindEntries), ("maxSearchFileBytes", maxSearchFileBytes),
            ("maxPipeBytes", maxPipeBytes)
        ]
        for (name, value) in counts where !(1...Self.maxCount).contains(value) {
            let message = "OutputLimits.\(name) must be between 1 and \(Self.maxCount), not \(value)"
            throw VFSError.invalidConfiguration(message)
        }
        guard timeLimit > .zero else {
            throw VFSError.invalidConfiguration("OutputLimits.timeLimit must be positive, not \(timeLimit)")
        }
    }

    /// Matches and `find` entries collected for a pipe or a count, which the agent does not read one by one.
    static let maxCollectedEntries = 50_000

    /// The limits for a command whose output goes into a pipe instead of to the agent.
    var forPipe: Self {
        var limits = self
        limits.maxBytes = maxPipeBytes
        limits.maxLines = maxPipeBytes
        limits.maxSearchMatches = max(maxSearchMatches, Self.maxCollectedEntries)
        limits.maxFindEntries = max(maxFindEntries, Self.maxCollectedEntries)
        return limits
    }
}

/// The finished result of one command line.
public struct CommandResult: Sendable, Equatable {
    /// Standard output and standard error, merged in order.
    public var output: String
    /// The exit status: 0 for success.
    public var exitCode: Int
    /// `true` when the output was cut to fit the limits.
    public var truncated: Bool

    /// A result as the interpreter returns it.
    public init(output: String, exitCode: Int, truncated: Bool = false) {
        self.output = output
        self.exitCode = exitCode
        self.truncated = truncated
    }
}

/// Text and exit status accumulated by one command.
///
/// Messages written with `fail` are the command's standard error: they show in `text` where they
/// happened, but a pipe passes only `standardOutput` on to the next command.
///
/// Each stream keeps at most `byteLimit` bytes, which the interpreter sets to just over what it
/// shows or pipes on. Writes past it are dropped and set `isFull`, so a command cannot fill memory,
/// and a long loop can stop early by checking `isFull`.
public struct CommandOutput: Sendable {
    /// Everything the command wrote, errors included, in order.
    public private(set) var text = ""
    /// What the command wrote without its error messages.
    public private(set) var standardOutput = ""
    /// Only the error messages.
    public private(set) var standardError = ""
    /// The exit status: 0 for success.
    public var exitCode: Int
    /// Set by a command such as `cd` to change the interpreter's working directory.
    public var newWorkingDirectory: VFSPath?
    /// Bytes kept of standard output, and separately of standard error.
    public let byteLimit: Int
    /// `true` once a write was dropped for going past `byteLimit`.
    public private(set) var isFull = false

    /// The byte limit of outputs made while a command runs. The interpreter sets it per command.
    @TaskLocal static var currentByteLimit = 64_000_000

    /// Output that starts with `text` as standard output.
    public init(text: String = "", exitCode: Int = 0) {
        self.exitCode = exitCode
        byteLimit = Self.currentByteLimit
        write(text)
    }

    /// Appends `value` to the output as it is.
    public mutating func write(_ value: String) {
        guard let kept = kept(value, after: standardOutput) else { return }
        text += kept
        standardOutput += kept
    }

    /// Appends `value` and a newline.
    public mutating func line(_ value: String) {
        write(value + "\n")
    }

    /// Appends file content, making sure it ends with a newline. Empty content writes nothing.
    public mutating func content(_ value: String) {
        write(value.isEmpty || value.unicodeScalars.last == "\n" ? value : value + "\n")
    }

    /// Reports `command: message` on standard error and raises the exit code to at least `code`.
    public mutating func fail(_ command: String, _ message: String, code: Int) {
        error("\(command): \(message)", code: code)
    }

    /// Writes `message` as a line on standard error and raises the exit code to at least `code`.
    public mutating func error(_ message: String, code: Int) {
        exitCode = max(exitCode, code)
        guard let kept = kept(message + "\n", after: standardError) else { return }
        text += kept
        standardError += kept
    }

    /// The part of `value` that fits after `stream`, cut at a character, or `nil` when nothing does.
    private mutating func kept(_ value: String, after stream: String) -> String? {
        let room = byteLimit - stream.utf8.count
        if value.utf8.count <= room { return value }
        isFull = true
        guard room > 0 else { return nil }
        let bytes = value.utf8
        var end = bytes.index(bytes.startIndex, offsetBy: room)
        while end > bytes.startIndex, UTF8.isContinuation(bytes[end]) {
            end = bytes.index(before: end)
        }
        return String(Substring(bytes[..<end]))
    }
}

/// A command the interpreter can run, such as `ls` or one of your own.
///
/// Commands get their arguments already tokenized and never see a real shell or disk: they can
/// only reach the workspace through `CommandContext.fileSystem`. Throw `CommandError.usage` for
/// wrong arguments. `VFSError`s are reported as `name: message`.
public protocol WorkspaceCommand: Sendable {
    /// The word that runs the command.
    var name: String { get }
    /// Lines for `help`, e.g. `"wc FILE... count lines"`. Empty hides the command from `help`.
    var usage: String { get }
    /// `true` when the command reads `CommandContext.standardInput`, so it may follow a `|`.
    var readsStandardInput: Bool { get }
    /// Runs the command once.
    func run(_ arguments: [ShellToken], in context: CommandContext) async throws -> CommandOutput
}

extension WorkspaceCommand {
    /// Commands do not read a pipe unless they say so.
    public var readsStandardInput: Bool { false }
}

/// A command defined by a closure.
public struct Command: WorkspaceCommand {
    /// The word that runs the command.
    public let name: String
    /// Lines for `help`.
    public let usage: String
    /// `true` when the command reads a pipe.
    public let readsStandardInput: Bool
    private let body: @Sendable ([ShellToken], CommandContext) async throws -> CommandOutput

    /// A command named `name` that runs `run`. Set `readsStandardInput` when it reads a pipe.
    public init(
        _ name: String,
        usage: String,
        readsStandardInput: Bool = false,
        run: @escaping @Sendable (_ arguments: [ShellToken], _ context: CommandContext) async throws -> CommandOutput
    ) {
        self.name = name
        self.usage = usage
        self.readsStandardInput = readsStandardInput
        self.body = run
    }

    /// Calls the closure.
    public func run(_ arguments: [ShellToken], in context: CommandContext) async throws -> CommandOutput {
        try await body(arguments, context)
    }
}

/// What a command can see while it runs.
public struct CommandContext: Sendable {
    /// The workspace, read-only.
    public let fileSystem: WorkspaceFileSystem
    /// What the command may print.
    public let limits: OutputLimits
    /// The directory relative paths start from.
    public let workingDirectory: VFSPath
    /// Every registered command, in `help` order.
    public let commands: [any WorkspaceCommand]
    /// The output of the previous command in a pipeline, or `nil` when nothing is piped in.
    public let standardInput: String?
    /// When the command's `OutputLimits.timeLimit` runs out, counted from when the context was made.
    public let deadline: ContinuousClock.Instant

    /// A context for one command, whose time limit starts now.
    public init(
        fileSystem: WorkspaceFileSystem,
        limits: OutputLimits,
        workingDirectory: VFSPath,
        commands: [any WorkspaceCommand],
        standardInput: String? = nil
    ) {
        self.fileSystem = fileSystem
        self.limits = limits
        self.workingDirectory = workingDirectory
        self.commands = commands
        self.standardInput = standardInput
        self.deadline = ContinuousClock.now + limits.timeLimit
    }

    /// Resolves a path argument against the working directory.
    public func resolvePath(_ raw: String) throws -> VFSPath {
        try VFSPath(normalizing: raw, relativeTo: workingDirectory)
    }

    /// An error message for the agent, listing the mounts when it named a missing one.
    public func describe(_ error: VFSError) -> String {
        if case let .unknownMount(name) = error {
            let available = fileSystem.mounts.map(\.name).sorted().joined(separator: ", ")
            return "\(name): no such mount (available: \(available))"
        }
        return error.localizedDescription
    }

    /// The piped input as a text file, for commands that read it like one.
    var pipedText: LargeText? {
        standardInput.map { LargeText(path: Self.standardInputName, data: Data($0.utf8), encoding: .utf8) }
    }

    /// How tools name piped input, as grep does.
    static let standardInputName = "(standard input)"

    /// Splits text into lines the way `head`, `tail` and `sed` see them.
    public static func lines(of text: String) -> [String] {
        text.lineSlices.map { String(Substring($0)) }
    }
}
