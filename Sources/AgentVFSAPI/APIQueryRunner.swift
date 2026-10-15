//
//  APIQueryRunner.swift
//  AgentVFSAPI
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import AgentVFSJQ
import Foundation

/// Runs one query command: options, pages, saving, summary and `--jq`.
struct APIQueryRunner: Sendable {
    /// The command words shown in messages, e.g. `jira issues`.
    let name: String
    /// The start of saved file names, e.g. `jira-issues`.
    let fileStem: String
    let summary: String
    let filters: [APIFilter]
    let results: APIResults
    let limits: APIQueryLimits
    let describeError: @Sendable (any Error) -> String
    let fetchPage: @Sendable (APIQuery) async throws -> APIPage

    /// Options every query command has, which no filter may take.
    static let reservedOptions: Set<String> = ["max", "jq", "refresh", "help"]

    /// Stops the program on a filter name that is reserved or given twice, or on limits out of
    /// range: these are programmer errors in the host.
    init(
        name: String,
        fileStem: String,
        summary: String,
        filters: [APIFilter],
        results: APIResults,
        limits: APIQueryLimits,
        describeError: @escaping @Sendable (any Error) -> String,
        fetchPage: @escaping @Sendable (APIQuery) async throws -> APIPage
    ) {
        limits.validate(command: name)
        var seen: Set<String> = []
        for filter in filters {
            precondition(
                !Self.reservedOptions.contains(filter.name),
                "\(name): a filter may not be named '\(filter.name)', which is an option of every query command"
            )
            precondition(seen.insert(filter.name).inserted, "\(name): the filter '\(filter.name)' is declared twice")
        }
        self.name = name
        self.fileStem = fileStem
        self.summary = summary
        self.filters = filters
        self.results = results
        self.limits = limits
        self.describeError = describeError
        self.fetchPage = fetchPage
    }

    var maxRecords: Int { limits.maxRecords }
    var defaultRecords: Int { limits.defaultRecords }
    var maxPages: Int { limits.maxPages }
    var timeout: Duration { limits.timeout }

    var optionsSynopsis: String {
        let options = filters.map { filter in
            let value = filter.allowed.isEmpty ? filter.name.uppercased() : filter.allowed.joined(separator: "|")
            return filter.required ? "--\(filter.name) \(value)" : "[--\(filter.name) \(value)]"
        }
        return (options + ["[--max N] [--jq FILTER] [--refresh]"]).joined(separator: " ")
    }

    /// What one invocation asks for, once its options are checked.
    private struct Request {
        let parameters: [String: String]
        let wanted: Int
        let refresh: Bool
        /// The `--jq` filter, or `nil` to print the summary.
        let jqFilter: String?
    }

    func run(_ arguments: [ShellToken], in context: CommandContext) async throws -> CommandOutput {
        let parsed = try OptionParser.parse(arguments, spec: optionSpecification, command: name)
        if parsed.has("help") {
            return CommandOutput(text: help)
        }
        let request = try request(from: parsed)
        try await results.ensureMounted(in: context.fileSystem)
        let key = try cacheKey(request)
        guard !request.refresh, let cached = await results.cached(key) else {
            return try await fetchAndSave(request, key: key, context: context)
        }
        var output = CommandOutput()
        guard let filter = request.jqFilter else {
            output.line("reusing earlier result of the same query: \(cached.path) (use --refresh to fetch again)")
            let description = try await describe(file: cached.name)
            output.content(description)
            return output
        }
        try await filterSaved(cached.name, through: filter, context: context, into: &output)
        return output
    }

    private var optionSpecification: OptionSpec {
        var specification = OptionSpec()
        for filter in filters {
            specification.longValueFlags[filter.name] = "filter:" + filter.name
        }
        specification.longValueFlags["max"] = "max"
        specification.longValueFlags["jq"] = "jq"
        specification.longFlags["refresh"] = "refresh"
        specification.longFlags["help"] = "help"
        return specification
    }

    private func request(from parsed: ParsedArguments) throws -> Request {
        guard parsed.positionals.isEmpty else {
            let hint = "filters are options, see \(name) --help"
            throw CommandError.usage("\(name): unexpected argument '\(parsed.positionals[0])'; \(hint)")
        }
        let parameters = try parameters(from: parsed)
        var wanted = defaultRecords
        if let raw = parsed.value("max") {
            guard let number = Int(raw), number > 0 else {
                throw CommandError.usage("\(name): --max expects a positive number")
            }
            wanted = min(number, maxRecords)
        }
        return Request(
            parameters: parameters,
            wanted: wanted,
            refresh: parsed.has("refresh"),
            jqFilter: parsed.value("jq")
        )
    }

    private func parameters(from parsed: ParsedArguments) throws -> [String: String] {
        var parameters: [String: String] = [:]
        for filter in filters {
            guard let value = parsed.value("filter:" + filter.name) else { continue }
            if !filter.allowed.isEmpty, !filter.allowed.contains(value) {
                let allowed = filter.allowed.joined(separator: ", ")
                throw CommandError.usage("\(name): --\(filter.name) must be one of \(allowed)")
            }
            parameters[filter.name] = value
        }
        let missing = filters.filter { $0.required && parameters[$0.name] == nil }.map { "--" + $0.name }
        guard missing.isEmpty else {
            throw CommandError.usage("\(name): \(missing.joined(separator: ", ")) is required, see \(name) --help")
        }
        return parameters
    }

    /// What identifies a query: its command, filters and record count.
    private struct CacheKey: Encodable {
        let kind = "APIQueryCommand"
        let command: String
        /// Filter names and values, sorted by name.
        let parameters: [[String]]
        let wanted: Int
    }

    /// The query's identity as JSON, which no two different queries share.
    private func cacheKey(_ request: Request) throws -> String {
        let parameters = request.parameters.sorted { $0.key < $1.key }.map { [$0.key, $0.value] }
        let key = CacheKey(command: name, parameters: parameters, wanted: request.wanted)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(key)
        return String(repairingUTF8: data)
    }

    private func fetchAndSave(_ request: Request, key: String, context: CommandContext) async throws -> CommandOutput {
        var output = CommandOutput()
        let deadline = min(ContinuousClock.now + timeout, context.deadline)
        let fetched = try await fetch(parameters: request.parameters, wanted: request.wanted, deadline: deadline)
        if fetched.records.isEmpty, let failure = fetched.failure {
            output.fail(name, failure, code: 1)
            return output
        }
        // A partial result is not reused, so the same query later fetches again.
        let reuseKey = fetched.failure == nil ? key : nil
        let saved = try await results.save(fetched.records, command: fileStem, reuseKey: reuseKey)
        guard let filter = request.jqFilter else {
            output.content(report(fetched, path: saved.path, bytes: saved.bytes))
            return output
        }
        if let failure = fetched.failure {
            output.line("\(name): stopped early, results are partial: \(failure)")
        }
        try await filterSaved(saved.name, through: filter, context: context, into: &output)
        return output
    }

    /// `--jq`: filters the saved records right away, so a narrow question costs one step. The
    /// records are already in memory, so no file size limit applies.
    private func filterSaved(
        _ fileName: String,
        through filter: String,
        context: CommandContext,
        into output: inout CommandOutput
    ) async throws {
        let path = results.path(of: fileName)
        let text = try await results.text(of: fileName)
        var options = JQ.Options()
        options.compactOutput = true
        let remaining = context.deadline - ContinuousClock.now
        guard remaining > .zero else { throw VFSError.timeLimitReached }
        options.timeout = min(options.timeout, remaining)
        let (doubled, overflow) = context.limits.maxBytes.multipliedReportingOverflow(by: 2)
        options.maxOutputBytes = overflow ? .max : doubled
        let input = JQ.Input(name: path, text: text)
        let result = await JQ.run(filter: filter, inputs: [input], options: options)
        output.content(result.output)
        output.line("(all records: \(path))")
        output.exitCode = result.exitCode
    }

    var help: String {
        var lines = ["\(name): \(summary)", "", "Filters (applied by the API):"]
        if filters.isEmpty { lines.append("  none") }
        for filter in filters {
            var line = "  --\(filter.name) VALUE"
            if !filter.summary.isEmpty { line += "  \(filter.summary)" }
            if !filter.allowed.isEmpty { line += " (one of: \(filter.allowed.joined(separator: ", ")))" }
            if filter.required { line += " [required]" }
            lines.append(line)
        }
        lines += [
            "",
            "Options:",
            "  --max N        keep at most N records (default \(defaultRecords), limit \(maxRecords))",
            "  --jq FILTER    print the saved records through a jq filter instead of the summary",
            "  --refresh      fetch again instead of reusing the result of the same query",
            "",
            "Every record is saved to /workspace/\(results.mountName)/\(fileStem)-N.json, one record per line.",
            "Read it with jq, grep or sed instead of printing it whole."
        ]
        return lines.joined(separator: "\n") + "\n"
    }
}
