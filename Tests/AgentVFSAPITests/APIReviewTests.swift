//
//  APIReviewTests.swift
//  AgentVFSAPITests
//
//  Created by Yevhenii Kalashnikov on 15.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import AgentVFSAPI
import AgentVFSJQ
import Foundation
import Synchronization
import Testing

/// Counts the pages a fake API was asked for.
private final class PageLog: Sendable {
    private let queries = Mutex<[APIQuery]>([])

    func record(_ query: APIQuery) {
        queries.withLock { $0.append(query) }
    }

    var count: Int { queries.withLock { $0.count } }
}

/// `count` numbered records, `pageSize` per page, with the cursor as the next start.
private func numberedPage(_ query: APIQuery, count: Int, pageSize: Int) throws -> APIPage {
    let start = try #require(Int(query.cursor ?? "0"))
    let end = min(start + pageSize, count)
    let records = (start..<end).map { JSONValue.object(JSONObject([("id", .int($0))])) }
    return APIPage(records: records, nextCursor: end < count ? String(end) : nil, total: count)
}

private func shell(_ commands: [any WorkspaceCommand]) throws -> CommandInterpreter {
    let driver = try InMemoryDriver(texts: ["a.md": "hi\n"])
    let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "notes", driver: driver)])
    return CommandInterpreter(fileSystem: fileSystem, commands: commands + [JQCommand()])
}

@Suite("APIPage.decode")
struct APIPageDecodeTests {
    private func decode(_ json: String, next: String? = nil, total: String? = nil) throws -> APIPage {
        try APIPage.decode(Data(json.utf8), records: ".items", next: next, total: total)
    }

    @Test("integer cursors keep every digit, and an integer total is read")
    func integers() throws {
        let page = try decode(#"{"items":[],"next":12345678901234567890123,"total":7}"#, next: ".next", total: ".total")
        #expect(page.nextCursor == "12345678901234567890123")
        #expect(page.total == 7)
        let computed = try decode(#"{"items":[],"next":40}"#, next: ".next * 2")
        #expect(computed.nextCursor == "80")
        let textTotal = try decode(#"{"items":[],"total":"12"}"#, total: ".total")
        #expect(textTotal.total == 12)
    }

    /// A response and the filters that pick a value of the wrong kind out of it.
    struct WrongKind: Sendable, CustomTestStringConvertible {
        let json: String
        var next: String?
        var total: String?
        var testDescription: String { json }
    }

    @Test("a cursor or total of the wrong kind throws instead of trapping or truncating", arguments: [
        WrongKind(json: #"{"items":[],"next":2.5}"#, next: ".next"),
        WrongKind(json: #"{"items":[],"next":5}"#, next: ".next * 1e19"),
        WrongKind(json: #"{"items":[],"next":{"page":2}}"#, next: ".next"),
        WrongKind(json: #"{"items":[],"next":[2]}"#, next: ".next"),
        WrongKind(json: #"{"items":[],"next":true}"#, next: ".next"),
        WrongKind(json: #"{"items":[],"total":2.5}"#, total: ".total"),
        WrongKind(json: #"{"items":[],"total":"many"}"#, total: ".total"),
        WrongKind(json: #"{"items":[],"total":{"value":3}}"#, total: ".total")
    ])
    func wrongKind(response: WrongKind) throws {
        #expect(throws: VFSError.self) { try decode(response.json, next: response.next, total: response.total) }
    }

    @Test("APIQuery can be made to test a fetch closure")
    func publicQuery() throws {
        let query = APIQuery(parameters: ["status": "open"], remaining: 10)
        let page = try numberedPage(query, count: 3, pageSize: 2)
        #expect(page.records.count == 2)
        #expect(page.nextCursor == "2")
    }
}

@Suite("API query command bounds")
struct APIQueryBoundTests {
    @Test("a page that never answers is cut off at the time limit and the rest is kept")
    func hungPage() async throws {
        let log = PageLog()
        let limits = APIQueryLimits(timeout: .milliseconds(300))
        let command = APIQueryCommand("items", summary: "s", results: APIResults(), limits: limits) { query in
            log.record(query)
            if query.page == 2 {
                try await Task.sleep(for: .seconds(30))
            }
            return try numberedPage(query, count: 100, pageSize: 10)
        }
        let started = ContinuousClock.now
        let output = try await shell([command]).run("items").output
        #expect(ContinuousClock.now - started < .seconds(15))
        #expect(output.hasPrefix("saved 10 records"))
        #expect(output.contains("stopped early, results are partial: time limit reached after 1 pages"))
    }

    @Test("filter values with & and = are a different query from separate filters")
    func cacheKeyEscaping() async throws {
        let log = PageLog()
        let filters = [APIFilter("a"), APIFilter("b")]
        let command = APIQueryCommand("items", summary: "s", filters: filters, results: APIResults()) { query in
            log.record(query)
            return try numberedPage(query, count: 1, pageSize: 10)
        }
        let shell = try shell([command])
        _ = await shell.run("items --a 'x&b=y'")
        let separate = await shell.run("items --a x --b y")
        #expect(separate.output.contains("reusing") == false)
        #expect(log.count == 2)
    }

    @Test("a service endpoint and a command with the same file stem do not share cached results")
    func stemCollision() async throws {
        let results = APIResults()
        let endpoint = APIEndpoint<Void>("issues", summary: "s") { _, _ in APIPage(records: [.int(1)]) }
        let service = APIService("jira", summary: "s", client: (), results: results, endpoints: [endpoint])
        let command = APIQueryCommand("jira-issues", summary: "s", results: results) { _ in
            APIPage(records: [.string("x")])
        }
        let shell = try shell([service, command])
        #expect(await shell.run("jira issues").output.contains("jira-issues-1.json"))
        let other = await shell.run("jira-issues").output
        #expect(other.contains("reusing") == false)
        #expect(other.contains("jira-issues-2.json"))
        #expect(other.contains("records are strings"))
    }

    @Test("more records are reported when the last page held more than was kept")
    func moreAvailableOnLastPage() async throws {
        let command = APIQueryCommand("items", summary: "s", results: APIResults()) { query in
            try numberedPage(query, count: 50, pageSize: 40)
        }
        let output = try await shell([command]).run("items --max 45").output
        #expect(output.hasPrefix("saved 45 records"))
        #expect(output.contains("more records are available"))
    }

    @Test("a partial result is not reused by the same query")
    func partialNotReused() async throws {
        let log = PageLog()
        let command = APIQueryCommand("items", summary: "s", results: APIResults()) { query in
            log.record(query)
            if query.page == 2 { throw VFSError.network("connection lost") }
            return try numberedPage(query, count: 30, pageSize: 10)
        }
        let shell = try shell([command])
        #expect(await shell.run("items").output.contains("results are partial: "))
        let again = await shell.run("items").output
        #expect(again.contains("reusing") == false)
        #expect(log.count == 4)
    }

    @Test("cancellation inside fetchPage cancels the command instead of saving a partial result")
    func cancellation() async throws {
        let command = APIQueryCommand("items", summary: "s", results: APIResults()) { query in
            if query.page == 2 { throw CancellationError() }
            return try numberedPage(query, count: 30, pageSize: 10)
        }
        let result = try await shell([command]).run("items")
        #expect(result.exitCode == 130)
        #expect(result.output == "[cancelled]")
    }

    @Test("describeError decides the text the agent sees for an API error")
    func describeError() async throws {
        let command = APIQueryCommand(
            "items",
            summary: "s",
            results: APIResults(),
            describeError: { _ in "the API failed" },
            fetchPage: { _ in throw VFSError.unauthorized("token secret-123 was refused") }
        )
        let output = try await shell([command]).run("items").output
        #expect(output == "items: the API failed")
    }

    @Test("a filter named like a built-in option stops the program")
    func reservedFilterName() async {
        await #expect(processExitsWith: .failure) {
            _ = APIQueryCommand("items", summary: "s", filters: [APIFilter("max")], results: APIResults()) { _ in
                APIPage(records: [])
            }
        }
    }

    @Test("an endpoint named twice stops the program")
    func duplicateEndpoint() async {
        await #expect(processExitsWith: .failure) {
            let endpoint = APIEndpoint<Void>("issues", summary: "s") { _, _ in APIPage(records: []) }
            _ = APIService("jira", summary: "s", client: (), results: APIResults(), endpoints: [endpoint, endpoint])
        }
    }

    @Test("limits out of range stop the program")
    func invalidLimits() async {
        await #expect(processExitsWith: .failure) {
            var limits = APIQueryLimits()
            limits.maxPages = 0
            _ = APIQueryCommand("items", summary: "s", results: APIResults(), limits: limits) { _ in
                APIPage(records: [])
            }
        }
    }
}
