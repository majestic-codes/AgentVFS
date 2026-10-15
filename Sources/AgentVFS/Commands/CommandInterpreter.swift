//
//  CommandInterpreter.swift
//  AgentVFS
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

/// Runs a small, read-only subset of Unix commands, plus any you register, against a
/// `WorkspaceFileSystem`.
///
/// No shell is involved. The command line is tokenized without any expansion and each command
/// is implemented in Swift, so nothing can run, write or reach outside `/workspace`.
public actor CommandInterpreter {
    let fileSystem: WorkspaceFileSystem
    let limits: OutputLimits
    private var directory: VFSPath = .root
    private var commands: [any WorkspaceCommand]

    /// Limits that `OutputLimits.validate` refuses, a command named `help`, a name with characters
    /// other than letters, digits, `.`, `_` and `-`, and two extra commands with the same name are
    /// programming errors and stop the program.
    ///
    /// - Parameters:
    ///   - commands: extra commands. One with the name of a standard command replaces it.
    ///   - includeStandardCommands: `false` starts from `help` alone.
    public init(
        fileSystem: WorkspaceFileSystem,
        limits: OutputLimits = OutputLimits(),
        commands: [any WorkspaceCommand] = [],
        includeStandardCommands: Bool = true
    ) {
        do {
            try limits.validate()
        } catch {
            preconditionFailure("CommandInterpreter: \(error.localizedDescription)")
        }
        var seen = Set<String>()
        for command in commands {
            let isNew = seen.insert(command.name).inserted
            precondition(isNew, "CommandInterpreter: two commands are named '\(command.name)'")
        }
        self.fileSystem = fileSystem
        self.limits = limits
        self.commands = includeStandardCommands ? StandardCommands.all : []
        for command in commands {
            Self.insert(command, into: &self.commands)
        }
    }

    /// Adds a command, replacing any registered under the same name. A name `init` refuses stops the program.
    public func register(_ command: any WorkspaceCommand) {
        Self.insert(command, into: &commands)
    }

    private static func insert(_ command: any WorkspaceCommand, into list: inout [any WorkspaceCommand]) {
        precondition(isValid(name: command.name), "CommandInterpreter: '\(command.name)' is not a valid command name")
        if let index = list.firstIndex(where: { $0.name == command.name }) {
            list[index] = command
        } else {
            list.append(command)
        }
    }

    /// Whether `name` can name a command: letters, digits, `.`, `_` and `-`, and not `help`.
    static func isValid(name: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return !name.isEmpty && name != "help" && name.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// The names of every registered command plus `help`, sorted.
    public var commandNames: [String] {
        (commands.map(\.name) + ["help"]).sorted()
    }

    /// The working directory as an absolute virtual path, changed by `cd`.
    public var currentDirectory: String { directory.description }

    /// The text `help` prints.
    public var helpText: String {
        let usages = commands.map(\.usage).filter { !$0.isEmpty }
        return ([Self.helpHeader] + usages + [Self.helpUsage]).joined(separator: "\n")
    }

    /// Tokenizes and runs one command line, which may be a pipeline such as `grep -c x a | head`.
    /// Never throws: errors become output with a non-zero exit code (2 for errors, 127 for an
    /// unknown command, 130 when cancelled), and long output is truncated.
    public func run(_ commandLine: String) async -> CommandResult {
        let pipeline: [[ShellToken]]
        do {
            pipeline = try ShellTokenizer.pipeline(commandLine)
        } catch let error as CommandError {
            return finish(Self.failure("bash: \(Self.message(of: error))", code: 2))
        } catch {
            return finish(Self.failure("bash: \(error.localizedDescription)", code: 2))
        }
        guard !pipeline.isEmpty else {
            return CommandResult(output: "", exitCode: 0)
        }
        if let refusal = pipeRefusal(pipeline) {
            return finish(Self.failure("bash: \(refusal)", code: 2))
        }
        guard pipeline.count <= Self.maxPipelineCommands else {
            let message = "bash: a pipeline may join at most \(Self.maxPipelineCommands) commands"
            return finish(Self.failure(message, code: 2))
        }
        var input: String?
        var earlierErrors = ""
        for words in pipeline.dropLast() {
            guard let output = await runStage(words, limits: limits.forPipe, input: input, alone: false) else {
                return Self.cancelled
            }
            earlierErrors += output.standardError
            input = passOn(output, from: words[0].text, errors: &earlierErrors)
        }
        let alone = pipeline.count == 1
        guard let lastWords = pipeline.last,
              let output = await runStage(lastWords, limits: limits, input: input, alone: alone)
        else {
            return Self.cancelled
        }
        return finish(output, after: earlierErrors)
    }

    private static let cancelled = CommandResult(output: "[cancelled]", exitCode: 130)

    /// Runs one command of a pipeline. `nil` when it was cancelled.
    private func runStage(
        _ words: [ShellToken],
        limits stageLimits: OutputLimits,
        input: String?,
        alone: Bool
    ) async -> CommandOutput? {
        let context = CommandContext(
            fileSystem: fileSystem,
            limits: stageLimits,
            workingDirectory: directory,
            commands: commands,
            standardInput: input
        )
        let name = words[0].text
        let arguments = Array(words.dropFirst())
        let ran = await CommandOutput.$currentByteLimit.withValue(stageLimits.maxBytes + 1) {
            await runCommand(name, arguments: arguments, context: context, alone: alone)
        }
        return Task.isCancelled ? nil : ran
    }

    /// Longer pipelines are refused.
    static let maxPipelineCommands = 16

    /// Why a pipeline cannot run: a command after `|` that does not read its input.
    private func pipeRefusal(_ pipeline: [[ShellToken]]) -> String? {
        for words in pipeline.dropFirst() {
            let name = words[0].text
            guard let command = commands.first(where: { $0.name == name }) else { continue }
            if !command.readsStandardInput {
                let readers = commands.filter(\.readsStandardInput).map(\.name).sorted().joined(separator: ", ")
                return "\(name) does not read from a pipe; after | use one of: \(readers)"
            }
        }
        return nil
    }

    /// Standard output on its way to the next command, cut at a line once it passes `maxPipeBytes`.
    private func passOn(_ output: CommandOutput, from name: String, errors: inout String) -> String {
        let text = output.standardOutput
        guard output.isFull || text.utf8.count > limits.maxPipeBytes else { return text }
        let bytes = text.utf8.prefix(limits.maxPipeBytes)
        let end = bytes.lastIndex(of: UInt8(ascii: "\n")).map { text.utf8.index(after: $0) } ?? bytes.endIndex
        errors += "bash: the output of \(name) was cut at \(limits.maxPipeBytes) bytes before the pipe\n"
        return String(Substring(text.utf8[..<end]))
    }

    /// Runs one command, turning errors into output. `nil` when it was cancelled.
    private func runCommand(
        _ name: String,
        arguments: [ShellToken],
        context: CommandContext,
        alone: Bool
    ) async -> CommandOutput? {
        do {
            return try await execute(name: name, arguments: arguments, context: context, alone: alone)
        } catch let error as CommandError {
            return Self.failure(Self.message(of: error), code: 2)
        } catch is CancellationError {
            return nil
        } catch VFSError.cancelled {
            return nil
        } catch let error as VFSError {
            return Self.failure("\(name): \(context.describe(error))", code: 2)
        } catch {
            return Self.failure("\(name): \(error.localizedDescription)", code: 2)
        }
    }

    private static func failure(_ message: String, code: Int) -> CommandOutput {
        var output = CommandOutput()
        output.error(message, code: code)
        return output
    }

    private static func message(of error: CommandError) -> String {
        switch error {
        case let .unsupported(message), let .usage(message): message
        }
    }

    /// Runs a registered command. A command alone on its line may change the working directory, to
    /// a directory that exists. In a pipeline it cannot, as in a shell, where each part runs in its
    /// own process.
    private func execute(
        name: String,
        arguments: [ShellToken],
        context: CommandContext,
        alone: Bool
    ) async throws -> CommandOutput {
        if name == "help" {
            return CommandOutput(text: helpText + "\n", exitCode: 0)
        }
        guard let command = commands.first(where: { $0.name == name }) else {
            let supported = commandNames.joined(separator: ", ")
            let message = "bash: \(name): command not found. "
                + "Only these commands are available here, read-only: \(supported)."
            return Self.failure(message, code: 127)
        }
        let output = try await command.run(arguments, in: context)
        if alone, let target = output.newWorkingDirectory {
            let entry = try await fileSystem.stat(path: target.description)
            guard entry.kind == .directory else {
                throw VFSError.notADirectory(target.description)
            }
            directory = target
        }
        return output
    }

    /// The result the agent sees: errors of earlier commands in a pipeline, then the last
    /// command's output, cut to the limits.
    private func finish(_ output: CommandOutput, after earlierErrors: String = "") -> CommandResult {
        var text = earlierErrors + output.text
        // By scalar, since a final "\r\n" is one Character and would not end with "\n".
        if text.unicodeScalars.last == "\n" {
            text.unicodeScalars.removeLast()
        }
        let lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        let totalLines = lines.count
        var kept: [String] = []
        var bytes = 0
        var cut = false
        for line in lines {
            let cost = line.utf8.count + (kept.isEmpty ? 0 : 1)
            if kept.count >= limits.maxLines || (bytes + cost > limits.maxBytes && !kept.isEmpty) {
                cut = true
                break
            }
            if bytes + cost > limits.maxBytes {
                kept.append(String(repairingUTF8: line.utf8.prefix(limits.maxBytes)))
                cut = true
                break
            }
            kept.append(line)
            bytes += cost
        }
        guard cut || output.isFull else {
            return CommandResult(output: text, exitCode: output.exitCode)
        }
        let total = output.isFull ? "more" : "\(totalLines)"
        let note = "[output truncated: showing \(kept.count) of \(total) lines; "
            + "narrow the path or pattern, or read a range with sed -n 'START,ENDp' FILE]"
        let shown = (kept + [note]).joined(separator: "\n")
        return CommandResult(output: shown, exitCode: output.exitCode, truncated: true)
    }

    static let helpHeader = """
    Read-only commands available in the workspace under /workspace.
    One command per call, or a pipeline joined with |; after | only commands that read input work.
    No redirects, globbing, variables or chaining (; && ||).

    """

    static let helpUsage = "help                               show this text"
}
