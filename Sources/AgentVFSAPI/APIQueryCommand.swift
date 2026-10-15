//
//  APIQueryCommand.swift
//  AgentVFSAPI
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import AgentVFSJQ
import Foundation

/// One filter an API command accepts, as `--name VALUE`. Only declared filters reach `fetchPage`.
public struct APIFilter: Sendable {
    /// The option name without `--`, such as `status`. It may not be `max`, `jq`, `refresh` or `help`.
    public let name: String
    /// What the filter does, shown by `--help`.
    public let summary: String
    /// The only values accepted. Empty accepts any value.
    public let allowed: [String]
    /// When `true` the query is refused without it.
    public let required: Bool

    /// A filter named `name`, such as `APIFilter("status", "order state", allowed: ["open", "closed"])`.
    public init(_ name: String, _ summary: String = "", allowed: [String] = [], required: Bool = false) {
        self.name = name
        self.summary = summary
        self.allowed = allowed
        self.required = required
    }
}

/// What `fetchPage` is asked for.
public struct APIQuery: Sendable, Hashable {
    /// Filter values keyed by filter name, only for filters the agent gave.
    public var parameters: [String: String]
    /// `nil` for the first page, then whatever the previous page returned as `nextCursor`.
    public var cursor: String?
    /// 1 for the first page.
    public var page: Int
    /// Records still wanted. An API with a page-size parameter can ask for no more than this.
    public var remaining: Int

    /// A query, for calling a `fetchPage` closure in your own tests.
    public init(parameters: [String: String] = [:], cursor: String? = nil, page: Int = 1, remaining: Int) {
        self.parameters = parameters
        self.cursor = cursor
        self.page = page
        self.remaining = remaining
    }
}

/// One page of records, as `fetchPage` returns it.
public struct APIPage: Sendable {
    /// The records of this page, saved one per line.
    public var records: [JSONValue]
    /// `nil` when this is the last page.
    public var nextCursor: String?
    /// The total number of matching records, if the API reports it.
    public var total: Int?

    /// A page of `records`, with the cursor of the next page and the total when the API gives them.
    public init(records: [JSONValue], nextCursor: String? = nil, total: Int? = nil) {
        self.records = records
        self.nextCursor = nextCursor
        self.total = total
    }

    /// Reads a page from a JSON response, picking its parts out with jq filters, for example
    /// `APIPage.decode(data, records: ".items", next: ".meta.next_cursor", total: ".meta.total")`.
    ///
    /// The cursor must be a string or an integer and the total an integer, or `null` when absent.
    /// Any other value throws `VFSError.invalidConfiguration`.
    public static func decode(
        _ data: Data,
        records: String = ".",
        next: String? = nil,
        total: String? = nil
    ) throws -> Self {
        let body: JSONValue
        do {
            body = try JQ.parse(String(repairingUTF8: data))
        } catch {
            // The parser quotes the whole input. The start of the response is enough to see what came back.
            let start = String(repairingUTF8: data.prefix(200))
            let ellipsis = data.count > 200 ? "…" : ""
            throw VFSError.unreadable(path: "API response", reason: "not valid JSON: \(start)\(ellipsis)")
        }
        guard case let .array(pageRecords)? = try JQ.evaluate(records, input: body).first else {
            throw VFSError.invalidConfiguration("the records filter '\(records)' did not select an array")
        }
        var nextCursor: String?
        if let next, let value = try JQ.evaluate(next, input: body).first {
            nextCursor = try cursor(from: value, filter: next)
        }
        var totalCount: Int?
        if let total, let value = try JQ.evaluate(total, input: body).first {
            totalCount = try Self.total(from: value, filter: total)
        }
        return Self(records: pageRecords, nextCursor: nextCursor, total: totalCount)
    }

    /// A cursor is a string or an integer. An empty string or `null` ends the pages.
    private static func cursor(from value: JSONValue, filter: String) throws -> String? {
        switch value {
        case .null: nil
        case let .string(text): text.isEmpty ? nil : text
        case let .number(number, literal): try integerText(number, literal: literal, filter: filter, role: "cursor")
        default: throw wrongKind(value, filter: filter, role: "cursor", expected: "a string or an integer")
        }
    }

    private static func total(from value: JSONValue, filter: String) throws -> Int? {
        switch value {
        case .null:
            return nil
        case let .number(number, _):
            guard number.isFinite, let integer = Int(exactly: number) else {
                throw VFSError.invalidConfiguration("the total filter '\(filter)' selected \(number), not an integer")
            }
            return integer
        case let .string(text):
            guard let integer = Int(text) else {
                throw VFSError.invalidConfiguration("the total filter '\(filter)' selected \"\(text)\", not an integer")
            }
            return integer
        default:
            throw wrongKind(value, filter: filter, role: "total", expected: "an integer")
        }
    }

    /// An integer as the response wrote it, so a cursor past 2^53 keeps every digit.
    private static func integerText(_ number: Double, literal: String?, filter: String, role: String) throws -> String {
        if let literal, isIntegerLiteral(literal) { return literal }
        guard number.isFinite, let integer = Int(exactly: number) else {
            throw VFSError.invalidConfiguration("the \(role) filter '\(filter)' selected \(number), not an integer")
        }
        return String(integer)
    }

    private static func isIntegerLiteral(_ text: String) -> Bool {
        let digits = text.hasPrefix("-") ? text.dropFirst() : Substring(text)
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func wrongKind(_ value: JSONValue, filter: String, role: String, expected: String) -> VFSError {
        .invalidConfiguration("the \(role) filter '\(filter)' selected \(value.typeName), not \(expected)")
    }
}

/// The limits every query of an API command keeps to. Every value must be positive.
public struct APIQueryLimits: Sendable {
    /// Records kept at most, whatever `--max` asks for.
    public var maxRecords: Int
    /// Records kept when the agent gives no `--max`, at most `maxRecords`.
    public var defaultRecords: Int
    /// Pages fetched at most for one query.
    public var maxPages: Int
    /// Wall-clock limit for fetching all pages of one query. The command's own
    /// `OutputLimits.timeLimit` applies too.
    public var timeout: Duration

    /// Limits for a typical paginated API. `defaultRecords` above `maxRecords` is lowered to it.
    public init(
        maxRecords: Int = 10_000,
        defaultRecords: Int = 1_000,
        maxPages: Int = 200,
        timeout: Duration = .seconds(60)
    ) {
        self.maxRecords = maxRecords
        self.defaultRecords = min(defaultRecords, maxRecords)
        self.maxPages = maxPages
        self.timeout = timeout
    }

    /// Stops the program when a limit is out of range: a programmer error in the host.
    func validate(command: String) {
        precondition(maxRecords > 0, "\(command): APIQueryLimits.maxRecords must be positive")
        precondition(
            (1...maxRecords).contains(defaultRecords),
            "\(command): APIQueryLimits.defaultRecords must be between 1 and maxRecords"
        )
        precondition(maxPages > 0, "\(command): APIQueryLimits.maxPages must be positive")
        precondition(timeout > .zero, "\(command): APIQueryLimits.timeout must be positive")
    }
}

/// A command over a paginated API: it maps `--filter VALUE` options to the API, follows the
/// pages itself, saves every record into `/workspace/results/<name>-N.json` and prints only a
/// short summary (count, fields, a sample), so the records never pass through the model's context
/// unless it asks for them, typically with `jq` on the saved file.
///
/// The agent cannot reach anything else: only the filters you declare become parameters, and
/// the credentials stay inside `fetchPage`. The text of an error `fetchPage` throws is shown to the
/// agent, so it must not contain credentials, or `describeError` must leave them out. Identical
/// queries in one session reuse the saved file. For a service with several endpoints, `APIService`
/// groups them under one command.
public struct APIQueryCommand: WorkspaceCommand {
    public let name: String
    public let usage: String
    let runner: APIQueryRunner

    /// The default `describeError`: the error's own description, as the agent will see it.
    public static func describe(_ error: any Error) -> String {
        error.localizedDescription
    }

    /// A command named `name`. Filter names must be unique and not `max`, `jq`, `refresh` or
    /// `help`, and the limits must be positive. Breaking these rules stops the program.
    ///
    /// - Parameters:
    ///   - describeError: The text the agent sees for an error `fetchPage` throws. It must not
    ///     contain credentials.
    ///   - fetchPage: Fetches one page. It is cancelled when the command's time limit passes.
    public init(
        _ name: String,
        summary: String,
        filters: [APIFilter] = [],
        results: APIResults,
        limits: APIQueryLimits = APIQueryLimits(),
        describeError: @escaping @Sendable (any Error) -> String = Self.describe,
        fetchPage: @escaping @Sendable (APIQuery) async throws -> APIPage
    ) {
        self.name = name
        runner = APIQueryRunner(
            name: name,
            fileStem: name,
            summary: summary,
            filters: filters,
            results: results,
            limits: limits,
            describeError: describeError,
            fetchPage: fetchPage
        )
        let destination = "saves to /workspace/\(results.mountName), --help for details"
        usage = "\(name) \(runner.optionsSynopsis)   \(summary); \(destination)"
    }

    public func run(_ arguments: [ShellToken], in context: CommandContext) async throws -> CommandOutput {
        try await runner.run(arguments, in: context)
    }
}
