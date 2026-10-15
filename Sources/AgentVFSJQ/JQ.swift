//
//  JQ.swift
//  AgentVFSJQ
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import Foundation

/// A jq 1.7 implementation in Swift: compile a filter, run it over JSON texts, get jq's output.
public enum JQ {
    /// How a run reads its inputs, prints its outputs and what it may spend. `validate()` lists
    /// the values each limit accepts.
    public struct Options: Sendable {
        /// `-r`: strings without quotes.
        public var rawOutput = false
        /// `-j`: like `-r`, without newlines between outputs.
        public var joinOutput = false
        /// `-a`: escape everything outside ASCII.
        public var asciiOutput = false
        /// `-c`: one line per output, without whitespace between tokens.
        public var compactOutput = false
        /// `--tab`: indent pretty output with one tab per level.
        public var tab = false
        /// `--indent N`: spaces per level of pretty output, from 0 to 7.
        public var indent = 2
        /// `-S`: object keys in sorted order.
        public var sortKeys = false
        /// `-n`: run once with `null`. `input` and `inputs` still read the files.
        public var nullInput = false
        /// `-s`: all inputs as one array (or one string with `-R`).
        public var slurp = false
        /// `-R`: each line is a string input.
        public var rawInput = false
        /// `-e`: exit status from the last output.
        public var exitStatus = false
        /// `--stream`: inputs in streaming form, as `tostream` produces.
        public var stream = false
        /// `--arg`, `--argjson` and friends, in order.
        public var namedArguments: [(name: String, value: JSONValue)] = []
        /// `--args` / `--jsonargs`.
        public var positionalArguments: [JSONValue] = []
        /// Evaluation steps before the program is stopped. At least 1.
        public var maxSteps = 20_000_000
        /// Output size at which the program is stopped. Not negative.
        public var maxOutputBytes = 10_000_000
        /// Wall-clock time after which the program is stopped. Positive and at most `maxTimeout`.
        public var timeout: Duration = .seconds(30)
        /// Growth of the process's memory footprint at which the program is stopped. At least 1.
        ///
        /// Growth is measured from the footprint when the run starts, so memory the app held before
        /// does not count. While other runs are active at the same time, a run is stopped only when
        /// it has itself allocated at least half of this, by the estimate of the values it built.
        /// When the system does not report the footprint, the run is stopped once the values it
        /// built add up to this, which counts memory it already released too.
        public var maxMemoryGrowth = Self.defaultMaxMemoryGrowth

        /// The memory growth a run may cause by default: less on iOS, where apps get less memory.
        #if os(iOS)
        public static let defaultMaxMemoryGrowth = 512 << 20
        #else
        public static let defaultMaxMemoryGrowth = 1 << 30
        #endif

        /// The longest `timeout` accepted.
        public static let maxTimeout: Duration = .seconds(24 * 60 * 60)

        /// The largest `indent` accepted, as in jq.
        public static let maxIndent = 7

        /// jq's defaults: pretty output with two spaces, inputs read as JSON texts.
        public init() {}

        /// Throws `VFSError.invalidConfiguration` for a value no run can use: an indent outside
        /// 0 to 7, a step or memory limit below 1, a negative output limit, or a timeout that is not
        /// positive or is longer than `maxTimeout`.
        public func validate() throws {
            if indent < 0 { throw VFSError.invalidConfiguration("Cannot indent less than 0 characters") }
            if indent > Self.maxIndent {
                throw VFSError.invalidConfiguration("Cannot indent more than \(Self.maxIndent) characters")
            }
            if maxSteps < 1 { throw VFSError.invalidConfiguration("maxSteps must be at least 1, not \(maxSteps)") }
            if maxOutputBytes < 0 {
                throw VFSError.invalidConfiguration("maxOutputBytes must not be negative, not \(maxOutputBytes)")
            }
            guard timeout > .zero, timeout <= Self.maxTimeout else {
                let message = "timeout must be positive and at most \(Self.maxTimeout), not \(timeout)"
                throw VFSError.invalidConfiguration(message)
            }
            if maxMemoryGrowth < 1 {
                throw VFSError.invalidConfiguration("maxMemoryGrowth must be at least 1, not \(maxMemoryGrowth)")
            }
        }
    }

    /// One JSON text to run the filter on, and the name jq shows for it in messages and
    /// `input_filename`.
    public struct Input: Sendable {
        /// The file name, or a label such as `<stdin>`.
        public var name: String
        /// The JSON text, or the lines read with `-R`.
        public var text: String

        /// An input named `name` holding `text`.
        public init(name: String, text: String) {
            self.name = name
            self.text = text
        }
    }

    /// What a run printed and how it ended.
    public struct Result: Sendable, Equatable {
        /// Outputs and messages in the order jq would print them.
        public var output: String
        /// jq's exit status: 0 on success, 5 after an error, 3 for a compile error, 2 for a usage
        /// error, 1 or 4 with `-e`, or the code given to `halt_error`.
        public var exitCode: Int
        /// `true` when output reached `maxOutputBytes` and the program was stopped.
        public var truncated: Bool

        /// A result with the given output, exit status and truncation.
        public init(output: String, exitCode: Int, truncated: Bool) {
            self.output = output
            self.exitCode = exitCode
            self.truncated = truncated
        }
    }

    /// Runs on a thread with a large stack, so deeply nested data and recursive filters work.
    /// Cancelling the task stops the program at its next check.
    public static func run(filter: String, inputs: [Input], options: Options = Options()) async -> Result {
        let cancellation = JQCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let thread = Thread {
                    let result = runSynchronously(filter: filter, inputs: inputs, options: options, cancellation)
                    continuation.resume(returning: result)
                }
                thread.stackSize = stackSize
                thread.start()
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    #if os(macOS)
    static let stackSize = 512 << 20
    #else
    static let stackSize = 128 << 20
    #endif

    /// Runs on the calling thread. Deep recursion needs a large stack, so prefer `run`.
    public static func runSynchronously(filter: String, inputs: [Input], options: Options = Options()) -> Result {
        runSynchronously(filter: filter, inputs: inputs, options: options, nil)
    }

    private static func runSynchronously(
        filter: String,
        inputs: [Input],
        options: Options,
        _ cancellation: JQCancellation?
    ) -> Result {
        do {
            try options.validate()
        } catch let VFSError.invalidConfiguration(message) {
            return Result(output: "jq: error: \(message)\n", exitCode: 2, truncated: false)
        } catch {
            return Result(output: "jq: error: \(error)\n", exitCode: 2, truncated: false)
        }
        let program: Expr
        do {
            program = try compile(filter, options: options)
        } catch let error as JQCompileError {
            // Like jq, the message quotes the filter, but only its start when it is long.
            let quoted = filter.count > 500 ? String(filter.prefix(500)) + "…" : filter
            let output = "jq: error: \(error.message):\n\(quoted)\njq: 1 compile error\n"
            return Result(output: output, exitCode: 3, truncated: false)
        } catch {
            return Result(output: "jq: error: \(error)\n", exitCode: 3, truncated: false)
        }
        let budget = Budget(options, cancellation: cancellation)
        let queue = InputQueue(inputs: inputs, options: options, budget: budget)
        return Execution(program: program, queue: queue, options: options, budget: budget).run()
    }

    /// Longest filter text compiled.
    static let maxFilterBytes = 1_000_000

    static func compile(_ filter: String, options: Options) throws -> Expr {
        guard filter.utf8.count <= maxFilterBytes else {
            throw JQCompileError(message: "filter too long (more than \(maxFilterBytes) bytes)")
        }
        let program = try Parser.parse(filter)
        let functions = Set(Builtins.natives.keys).union(Prelude.table.keys)
        let variables = Set(["ENV", "__loc__", "ARGS"] + options.namedArguments.map(\.name))
        try Checker.check(program, Checker.Scope(functions: functions, variables: variables))
        return program
    }

    /// Every output of `filter` on `input`, for callers that want values rather than text.
    /// Throws `JQCompileError` for a filter that does not compile, `JQError` for an error the filter
    /// raised, `JQAbort` when a limit of `options` stopped it, `JQHalt` for `halt` and
    /// `halt_error`, and `VFSError.invalidConfiguration` for options that do not validate.
    public static func evaluate(
        _ filter: String,
        input: JSONValue = .null,
        options: Options = Options()
    ) throws -> [JSONValue] {
        try options.validate()
        let program = try compile(filter, options: options)
        let budget = Budget(options, cancellation: nil)
        let interpreter = Interpreter(maxSteps: options.maxSteps, budget: budget, inputs: nil) { _ in }
        var results: [JSONValue] = []
        let environment = rootEnvironment(options)
        _ = try interpreter.eval(program, Item(input), environment, false) { item in
            results.append(item.value)
            return true
        }
        return results
    }

    /// How deeply `parse` lets JSON nest. It runs on the caller's thread, whose stack may be small.
    public static let maxParseDepth = 256

    /// Parses JSON text holding one value. Throws `JQError` for text that is not one JSON value or
    /// nests deeper than `maxParseDepth`.
    public static func parse(_ text: String) throws -> JSONValue {
        do {
            return try JSONStreamParser.parseSingle(text, maxDepth: maxParseDepth)
        } catch let error as JSONParseError {
            throw JQError(error.message)
        }
    }

    static func rootEnvironment(_ options: Options) -> Env {
        // `$ENV` is bound below the builtin library, whose `env` refers to it.
        let environment = Env(Env(nil, .root), .variable("ENV", .object(JSONObject())))
        var env = Env(environment, .table(Prelude.table))
        var named = JSONObject()
        for (name, value) in options.namedArguments { named[name] = value }
        let arguments = JSONObject([("positional", .array(options.positionalArguments)), ("named", .object(named))])
        env = Env(env, .variable("ARGS", .object(arguments)))
        for (name, value) in options.namedArguments { env = Env(env, .variable(name, value)) }
        return env
    }
}
