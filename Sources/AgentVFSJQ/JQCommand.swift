//
//  JQCommand.swift
//  AgentVFSJQ
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import Foundation

/// `jq`: query and transform JSON files in the workspace.
///
/// A Swift implementation of jq 1.7. It reads FILE operands, the output of the previous command
/// in a pipeline, or nothing with `-n`. `$ENV` is empty.
public struct JQCommand: WorkspaceCommand {
    /// The command name the shell dispatches on.
    public let name = "jq"
    /// The one-line synopsis `help` and usage errors print.
    public let usage = "jq [-rcjsnReS] [--arg N V] [--argjson N JSON] FILTER [FILE...]   query JSON (jq 1.7)"
    /// `jq` reads the previous command's output when no FILE is given.
    public let readsStandardInput = true

    /// Largest JSON file read. jq parses the whole file into a tree several times its size, so the
    /// limit is lower on iOS. Larger data belongs in `sqlite3`.
    public let maxFileBytes: Int

    /// The default `maxFileBytes`: less on iOS, where apps get less memory.
    #if os(iOS)
    public static let defaultMaxFileBytes = 20_000_000
    #else
    public static let defaultMaxFileBytes = 50_000_000
    #endif

    /// A `jq` that reads at most `maxFileBytes` of files per run, which must be positive.
    public init(maxFileBytes: Int = Self.defaultMaxFileBytes) {
        precondition(maxFileBytes > 0, "JQCommand.maxFileBytes must be positive, not \(maxFileBytes)")
        self.maxFileBytes = maxFileBytes
    }

    /// Runs `jq` over workspace files. Usage errors throw. Unreadable files and jq errors are
    /// reported in the output with jq's exit status.
    public func run(_ arguments: [ShellToken], in context: CommandContext) async throws -> CommandOutput {
        var parsed = try JQArguments(arguments, usage: usage)
        if parsed.showHelp { return CommandOutput(text: usage + "\n") }
        var options = parsed.options
        let doubled = context.limits.maxBytes.multipliedReportingOverflow(by: 2)
        options.maxOutputBytes = doubled.overflow ? .max : doubled.partialValue
        var reader = Reader(context: context, remainingBytes: maxFileBytes, maxFileBytes: maxFileBytes)
        if let filterFile = parsed.filterFile {
            guard let text = await reader.read(filterFile) else { return reader.output }
            if let filter = parsed.filter { parsed.operands.insert(filter, at: 0) }
            parsed.filter = text
        }
        guard let filter = parsed.filter else { throw CommandError.usage(usage) }
        guard await loadFileArguments(parsed, &reader, into: &options) else { return reader.output }
        let inputs = try await inputs(parsed.operands, nullInput: options.nullInput, &reader)
        guard !reader.isOverBudget else { return reader.output }
        let remaining = context.deadline - ContinuousClock.now
        guard remaining > .zero else { throw VFSError.timeLimitReached }
        options.timeout = min(options.timeout, remaining)
        let result = await JQ.run(filter: filter, inputs: inputs, options: options)
        var output = reader.output
        output.write(result.output)
        output.exitCode = max(output.exitCode, result.exitCode)
        return output
    }

    /// The JSON texts to run the filter on: the FILE operands, else the piped input, else none
    /// with `-n`. Files that cannot be read are reported and left out. Reading stops once the
    /// files add up to more than jq reads.
    private func inputs(_ operands: [String], nullInput: Bool, _ reader: inout Reader) async throws -> [JQ.Input] {
        guard !operands.isEmpty else {
            if nullInput { return [] }
            guard let piped = reader.context.standardInput else {
                throw CommandError.usage("jq: no input: pass FILE operands, pipe JSON in, or use -n")
            }
            return [JQ.Input(name: "<stdin>", text: piped)]
        }
        var inputs: [JQ.Input] = []
        for operand in operands {
            if let text = await reader.read(operand) {
                inputs.append(JQ.Input(name: operand, text: text))
            } else if reader.isOverBudget {
                break
            }
        }
        return inputs
    }

    /// Adds `--slurpfile` and `--rawfile` values to the named arguments. Returns `false` after
    /// reporting a file that could not be read or parsed.
    private func loadFileArguments(
        _ parsed: JQArguments,
        _ reader: inout Reader,
        into options: inout JQ.Options
    ) async -> Bool {
        for (name, path) in parsed.slurpFiles {
            guard let text = await reader.read(path) else { return false }
            var slurp = JQ.Options()
            slurp.maxMemoryGrowth = options.maxMemoryGrowth
            let budget = Budget(slurp, cancellation: nil)
            let queue = InputQueue(inputs: [JQ.Input(name: path, text: text)], options: slurp, budget: budget)
            let values: [JSONValue]
            do {
                values = try queue.remainingValues()
            } catch let error as JSONParseError {
                reader.output.error("jq: Bad JSON in --slurpfile \(name) \(path): \(error.message)", code: 2)
                return false
            } catch let error as JQError {
                reader.output.error("jq: error: --slurpfile \(name) \(path): \(error.message)", code: 2)
                return false
            } catch let abort as JQAbort {
                reader.output.error("jq: error: --slurpfile \(name) \(path): \(abort.message)", code: 2)
                return false
            } catch {
                reader.output.error("jq: error: --slurpfile \(name) \(path): \(error)", code: 2)
                return false
            }
            options.namedArguments.append((name, .array(values)))
        }
        for (name, path) in parsed.rawFiles {
            guard let text = await reader.read(path) else { return false }
            options.namedArguments.append((name, .string(text)))
        }
        return true
    }
}

/// Reads the files of one `jq` run. jq holds all of them while it runs, so together they get the
/// size one file may have.
private struct Reader {
    let context: CommandContext
    var remainingBytes: Int
    let maxFileBytes: Int
    var output = CommandOutput()

    var isOverBudget: Bool { remainingBytes < 0 }

    /// The text of a workspace file, or `nil` after reporting why it could not be read.
    mutating func read(_ operand: String) async -> String? {
        let text: String
        do {
            let path = try context.resolvePath(operand).description
            text = try await context.fileSystem.largeText(path: path, maxBytes: maxFileBytes).text
        } catch let error as VFSError {
            output.error("jq: error: Could not open \(operand): \(context.describe(error))", code: 2)
            return nil
        } catch {
            output.error("jq: error: Could not open \(operand): \(error.localizedDescription)", code: 2)
            return nil
        }
        remainingBytes -= text.utf8.count
        guard !isOverBudget else {
            let message = "the files add up to more than \(maxFileBytes) bytes; give fewer at a time"
            output.error("jq: error: \(message)", code: 2)
            return nil
        }
        return text
    }
}
