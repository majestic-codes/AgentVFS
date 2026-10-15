//
//  Execution.swift
//  AgentVFSJQ
//
//  Created by Yevhenii Kalashnikov on 15.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

/// Thrown when the output is full: the program stops without an error message.
private struct OutputFull: Error {}

/// One run of a program over its inputs.
final class Execution {
    let program: Expr
    let queue: InputQueue
    let options: JQ.Options
    let budget: Budget
    let format: JSONFormat
    var output = ""
    var outputBytes = 0
    var truncated = false
    var lastOutput: JSONValue?
    var failed = false
    var parseFailed = false
    var halted: Int?

    init(program: Expr, queue: InputQueue, options: JQ.Options, budget: Budget) {
        self.program = program
        self.queue = queue
        self.options = options
        self.budget = budget
        format = JSONFormat(
            indent: options.compactOutput ? 0 : options.indent,
            useTabs: options.tab && !options.compactOutput,
            sortKeys: options.sortKeys,
            asciiOnly: options.asciiOutput
        )
    }

    private var room: Int { max(options.maxOutputBytes - outputBytes, 0) }

    /// Appends `text`, cut where the output reaches `maxOutputBytes`. Returns whether there is
    /// room for more.
    @discardableResult
    private func write(_ text: String) -> Bool {
        guard !truncated else { return false }
        let bytes = text.utf8.count
        guard bytes > room else {
            output += text
            outputBytes += bytes
            return true
        }
        output += String(repairingUTF8: text.utf8.prefix(room))
        outputBytes = options.maxOutputBytes
        truncated = true
        return false
    }

    /// The value as JSON text, laid out by `format`, serialized only as far as the output has room.
    private func json(_ value: JSONValue, _ layout: JSONFormat) -> String {
        value.serialized(layout, limit: room)
    }

    /// An output as jq prints it. Throws once the budget runs out while it is serialized.
    private func render(_ value: JSONValue) throws -> String {
        var text: String
        if options.rawOutput || options.joinOutput, case let .string(string) = value {
            let ascii = JSONFormat(indent: 0, asciiOnly: true)
            text = options.asciiOutput ? try value.serialized(ascii, limit: room, budget: budget) : string
        } else {
            text = try value.serialized(format, limit: room, budget: budget)
        }
        if !options.joinOutput { text += "\n" }
        return text
    }

    func run() -> JQ.Result {
        let interpreter = Interpreter(maxSteps: options.maxSteps, budget: budget, inputs: queue) { text in
            guard self.write(text) else { throw OutputFull() }
        }
        let env = JQ.rootEnvironment(options)
        if options.nullInput {
            _ = runProgram(.null, interpreter, env)
        } else {
            while let value = nextInput(), runProgram(value, interpreter, env) {}
        }
        return JQ.Result(output: output, exitCode: exitCode, truncated: truncated)
    }

    /// The next input, or `nil` at the end or after an error reading it.
    private func nextInput() -> JSONValue? {
        do {
            return try queue.next()
        } catch {
            _ = report(error)
            return nil
        }
    }

    private var exitCode: Int {
        if let halted { return halted }
        if parseFailed || failed { return 5 }
        if options.exitStatus { return lastOutput.map { $0.isTruthy ? 0 : 1 } ?? 4 }
        return 0
    }

    /// Runs the program once and returns whether to go on with the next input.
    private func runProgram(_ value: JSONValue, _ interpreter: Interpreter, _ env: Env) -> Bool {
        // Like jq, the exit status reflects the last input processed.
        failed = false
        do {
            _ = try interpreter.eval(program, Item(value), env, false) { item in
                lastOutput = item.value
                let text = try render(item.value)
                return write(text)
            }
            return !truncated
        } catch {
            return report(error)
        }
    }

    /// Writes the message for an error that stopped the program and returns whether to go on with the
    /// next input.
    private func report(_ error: any Error) -> Bool {
        switch error {
        case let error as JQError:
            failed = true
            if case let .string(message) = error.value {
                write("jq: error (at \(queue.location)): \(message)\n")
            } else {
                write("jq: error (at \(queue.location)) (not a string): \(json(error.value, .compact))\n")
            }
            return !truncated
        case let halt as JQHalt:
            if let message = halt.message {
                if case let .string(text) = message { write(text) } else { write(json(message, .compact) + "\n") }
            }
            halted = halt.exitCode
            return false
        case let abort as JQAbort:
            failed = true
            write("jq: error (at \(queue.location)): \(abort.message)\n")
            return false
        case let error as JSONParseError:
            parseFailed = true
            write("jq: parse error: \(error.message)\n")
            return false
        case is OutputFull:
            return false
        case is BreakSignal:
            failed = true
            write("jq: error (at \(queue.location)): break\n")
            return !truncated
        case let passthrough as Passthrough:
            return report(passthrough.error)
        default:
            failed = true
            write("jq: error (at \(queue.location)): \(error)\n")
            return false
        }
    }
}
