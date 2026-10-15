//
//  APIService.swift
//  AgentVFSAPI
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS

/// One endpoint of an `APIService`, run as `<service> <endpoint> [--filter VALUE]...`.
///
/// The text of an error `fetchPage` throws is shown to the agent, so it must not contain
/// credentials, or the service's `describeError` must leave them out.
public struct APIEndpoint<Client: Sendable>: Sendable {
    /// The subcommand name, unique within the service and not `help`.
    public let name: String
    /// What the endpoint returns, shown by `--help`.
    public let summary: String
    /// The filters the endpoint accepts, under the same rules as `APIQueryCommand`'s.
    public let filters: [APIFilter]
    let fetchPage: @Sendable (Client, APIQuery) async throws -> APIPage

    /// An endpoint whose `fetchPage` gets the service's client with each query.
    public init(
        _ name: String,
        summary: String,
        filters: [APIFilter] = [],
        fetchPage: @escaping @Sendable (_ client: Client, _ query: APIQuery) async throws -> APIPage
    ) {
        self.name = name
        self.summary = summary
        self.filters = filters
        self.fetchPage = fetchPage
    }
}

/// One command for a whole API, with its endpoints as subcommands, the way `gh` or `aws` work:
/// `jira issues --status open`, `jira comments --issue APP-42`, `jira --help`.
///
/// The client, with its credentials, is shared by the endpoints and never shown to the agent.
/// Error text from `fetchPage` is, so it must not contain credentials. Each endpoint behaves
/// like an `APIQueryCommand`. Results are saved as `/workspace/results/<service>-<endpoint>-N.json`.
public struct APIService<Client: Sendable>: WorkspaceCommand {
    public let name: String
    public let usage: String
    /// What the service is, shown by `--help`.
    public let summary: String
    private let runners: [Subcommand]

    /// Words that ask for help instead of naming an endpoint.
    private static var helpWords: Set<String> { ["--help", "-h", "help"] }

    private struct Subcommand: Sendable {
        let name: String
        let summary: String
        let runner: APIQueryRunner
    }

    /// A service named `name` over `endpoints`. Endpoint names must be unique and not `help`, and
    /// each endpoint's filters must follow `APIQueryCommand`'s rules. Breaking these stops the program.
    ///
    /// - Parameter describeError: The text the agent sees for an error an endpoint throws. It must
    ///   not contain credentials.
    public init(
        _ name: String,
        summary: String,
        client: Client,
        results: APIResults,
        limits: APIQueryLimits = APIQueryLimits(),
        describeError: @escaping @Sendable (any Error) -> String = APIQueryCommand.describe,
        endpoints: [APIEndpoint<Client>]
    ) {
        var seen: Set<String> = []
        for endpoint in endpoints {
            let endpointName = endpoint.name
            let isHelpWord = Self.helpWords.contains(endpointName)
            precondition(!isHelpWord, "\(name): an endpoint may not be named '\(endpointName)'")
            let isNew = seen.insert(endpointName).inserted
            precondition(isNew, "\(name): the endpoint '\(endpointName)' is declared twice")
        }
        self.name = name
        self.summary = summary
        runners = endpoints.map { endpoint in
            let fetch = endpoint.fetchPage
            let runner = APIQueryRunner(
                name: "\(name) \(endpoint.name)",
                fileStem: "\(name)-\(endpoint.name)",
                summary: endpoint.summary,
                filters: endpoint.filters,
                results: results,
                limits: limits,
                describeError: describeError
            ) { query in try await fetch(client, query) }
            return Subcommand(name: endpoint.name, summary: endpoint.summary, runner: runner)
        }
        let names = endpoints.map(\.name).joined(separator: "|")
        let synopsis = "\(name) \(names) [--FILTER VALUE]... [--max N] [--jq FILTER]"
        usage = "\(synopsis)   \(summary); \(name) --help lists endpoints and filters"
    }

    public func run(_ arguments: [ShellToken], in context: CommandContext) async throws -> CommandOutput {
        guard let first = arguments.first, !Self.helpWords.contains(first.text) else {
            return CommandOutput(text: help)
        }
        guard let endpoint = runners.first(where: { $0.name == first.text }) else {
            let available = runners.map(\.name).joined(separator: ", ")
            throw CommandError.usage("\(name): unknown endpoint '\(first.text)'; available: \(available)")
        }
        return try await endpoint.runner.run(Array(arguments.dropFirst()), in: context)
    }

    private var help: String {
        var lines = ["\(name): \(summary)", "", "Endpoints:"]
        let width = runners.map(\.name.count).max() ?? 0
        for endpoint in runners {
            let paddedName = endpoint.name.padding(toLength: width, withPad: " ", startingAt: 0)
            lines.append("  \(paddedName)  \(endpoint.runner.optionsSynopsis)  \(endpoint.summary)")
        }
        lines += ["", "\(name) ENDPOINT --help describes the filters of one endpoint."]
        return lines.joined(separator: "\n") + "\n"
    }
}
