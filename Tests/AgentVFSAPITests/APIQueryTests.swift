//
//  APIQueryTests.swift
//  AgentVFSAPITests
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import AgentVFSAPI
import AgentVFSJQ
import Foundation
import Synchronization
import Testing

private struct FakeOrder {
    let id: Int
    let status: String
    let total: Double
    let email: String

    init(id: Int) {
        self.id = id
        status = id.isMultiple(of: 5) ? "open" : "closed"
        total = Double(id) * 10.5
        email = "c\(id % 7)@example.com"
    }

    var json: String {
        let customer = #"{"email":"\#(email)"}"#
        return #"{"id":\#(id),"status":"\#(status)","total":\#(total),"customer":\#(customer),"tags":["a"]}"#
    }
}

/// A pretend orders API: 250 orders, 40 per page, filterable by status, answering with JSON.
private final class FakeOrdersAPI: Sendable {
    let requests = Mutex<[APIQuery]>([])

    func page(_ query: APIQuery) throws -> Data {
        requests.withLock { $0.append(query) }
        if query.parameters["status"] == "broken" {
            throw VFSError.api(status: 500, message: "server exploded")
        }
        let status = query.parameters["status"]
        let all = (1...250).map(FakeOrder.init).filter { status == nil || $0.status == status }
        let start = try #require(Int(query.cursor ?? "0"))
        let orders = all.dropFirst(start).prefix(40).map(\.json).joined(separator: ",")
        let next = start + 40 < all.count ? #""\#(start + 40)""# : "null"
        let meta = #"{"next":\#(next),"total":\#(all.count)}"#
        return Data(#"{"items":[\#(orders)],"meta":\#(meta)}"#.utf8)
    }

    var requestCount: Int { requests.withLock { $0.count } }
}

private struct OrdersFixture {
    let shell: CommandInterpreter
    let api: FakeOrdersAPI
    let fileSystem: WorkspaceFileSystem
}

private func emptyWorkspace(mountName: String = "n") throws -> WorkspaceFileSystem {
    try WorkspaceFileSystem(mounts: [WorkspaceMount(name: mountName, driver: InMemoryDriver())])
}

@Suite("API query command")
struct APIQueryCommandTests {
    private func setup(maxRecords: Int = 10_000) throws -> OrdersFixture {
        let api = FakeOrdersAPI()
        let results = APIResults()
        let status = APIFilter("status", "order state", allowed: ["open", "closed", "broken"])
        let orders = APIQueryCommand(
            "orders",
            summary: "fetch shop orders",
            filters: [status, APIFilter("customer")],
            results: results,
            limits: APIQueryLimits(maxRecords: maxRecords)
        ) { query in
            let data = try api.page(query)
            return try APIPage.decode(data, records: ".items", next: ".meta.next", total: ".meta.total")
        }
        let driver = try InMemoryDriver(texts: ["a.md": "hi\n"])
        let notes = WorkspaceMount(name: "notes", driver: driver)
        let fileSystem = try WorkspaceFileSystem(mounts: [notes])
        let shell = CommandInterpreter(fileSystem: fileSystem, commands: [orders, JQCommand()])
        return OrdersFixture(shell: shell, api: api, fileSystem: fileSystem)
    }

    @Test("follows every page, saves the records and prints only a summary")
    func summary() async throws {
        let fixture = try setup()
        let shell = fixture.shell
        let api = fixture.api
        let result = await shell.run("orders --status open")
        #expect(result.exitCode == 0)
        let lines = result.output.components(separatedBy: "\n")
        try #require(lines.count == 4)
        #expect(lines[0].hasPrefix("saved 50 records ("))
        #expect(lines[0].hasSuffix(", 2 pages) to /workspace/results/orders-1.json"))
        #expect(lines[1] == "matching records reported by the API: 50")
        let fields = "id: number, status: string, total: number, customer.email: string, tags: array of string"
        #expect(lines[2] == "fields: " + fields)
        #expect(lines[3].hasPrefix(#"first record: {"id":5,"status":"open""#))
        #expect(api.requestCount == 2)
        #expect(api.requests.withLock { $0.map(\.cursor) } == [nil, "40"])

        // The records are in the workspace for the usual tools.
        #expect(fixture.fileSystem.mount(named: "results") != nil)
        #expect(await shell.run("jq 'length' results/orders-1.json").output == "50")
        let head = await shell.run("head -n 2 results/orders-1.json").output.components(separatedBy: "\n")
        try #require(head.count == 2)
        #expect(head[1].hasPrefix(#"{"id":5,"#))
        #expect(await shell.run("grep -c '\"id\":250,' results/orders-1.json").output == "1")
    }

    @Test("--max stops early and says more records exist")
    func maxRecords() async throws {
        let fixture = try setup()
        let api = fixture.api
        let output = await fixture.shell.run("orders --max 45").output
        #expect(output.hasPrefix("saved 45 records"))
        #expect(output.contains("more records are available"))
        #expect(api.requestCount == 2)
        #expect(api.requests.withLock { $0.map(\.remaining) } == [45, 5])
    }

    @Test("--max is capped by the command's own limit")
    func maxCap() async throws {
        let shell = try setup(maxRecords: 30).shell
        #expect(await shell.run("orders --max 1000").output.hasPrefix("saved 30 records"))
    }

    @Test("--jq filters the saved records in the same step")
    func jqOption() async throws {
        let shell = try setup().shell
        let result = await shell.run("orders --status open --jq '[.[] | select(.total > 2000) | .id] | length'")
        #expect(result.output == "12\n(all records: /workspace/results/orders-1.json)")
    }

    @Test("the same query reuses its file unless --refresh is given")
    func caching() async throws {
        let fixture = try setup()
        let shell = fixture.shell
        let api = fixture.api
        _ = await shell.run("orders --status open")
        #expect(api.requestCount == 2)
        let again = await shell.run("orders --status open")
        let reused = "reusing earlier result of the same query: /workspace/results/orders-1.json"
        #expect(again.output.hasPrefix(reused))
        #expect(again.output.contains("50 records"))
        #expect(await shell.run("orders --status open --jq length").output.hasPrefix("50"))
        #expect(api.requestCount == 2)

        #expect(await shell.run("orders --status open --refresh").output.contains("orders-2.json"))
        #expect(api.requestCount == 4)
        let closed = await shell.run("orders --status closed").output
        #expect(closed.contains("orders-3.json"), "other filters are another query")
    }

    @Test("only declared filters and values are accepted")
    func validation() async throws {
        let fixture = try setup()
        let shell = fixture.shell
        let api = fixture.api
        let pending = await shell.run("orders --status pending").output
        #expect(pending == "orders: --status must be one of open, closed, broken")
        #expect(await shell.run("orders --url http://evil").exitCode == 2)
        #expect(await shell.run("orders open").exitCode == 2)
        #expect(await shell.run("orders --max 0").exitCode == 2)
        #expect(api.requestCount == 0)
        let help = await shell.run("orders --help").output
        #expect(help.contains("--status VALUE  order state (one of: open, closed, broken)"))
        let usage = "orders [--status open|closed|broken] [--customer CUSTOMER] [--max N]"
        #expect(await shell.run("help").output.contains(usage))
    }

    @Test("API errors are reported, and earlier pages are kept as a partial result")
    func errors() async throws {
        let shell = try setup().shell
        let failed = await shell.run("orders --status broken")
        #expect(failed.exitCode == 1)
        #expect(failed.output.contains("server exploded"))

        let api = FakeOrdersAPI()
        let calls = Mutex(0)
        let flaky = APIQueryCommand("orders", summary: "s", results: APIResults()) { query in
            let callNumber = calls.withLock { $0 += 1; return $0 }
            if callNumber == 3 { throw VFSError.rateLimited(resetAt: nil) }
            let data = try api.page(query)
            return try APIPage.decode(data, records: ".items", next: ".meta.next")
        }
        let fileSystem = try emptyWorkspace()
        let output = await CommandInterpreter(fileSystem: fileSystem, commands: [flaky]).run("orders").output
        #expect(output.hasPrefix("saved 80 records"))
        #expect(output.contains("stopped early, results are partial: rate limit"))
    }

    @Test("several commands share one results mount, which must not be taken by another source")
    func sharedResults() async throws {
        let results = APIResults(mountName: "api")
        let one = APIQueryCommand("one", summary: "", results: results) { _ in APIPage(records: [.int(1)]) }
        let two = APIQueryCommand("two", summary: "", results: results) { _ in APIPage(records: [.string("x")]) }
        let fileSystem = try emptyWorkspace()
        let shell = CommandInterpreter(fileSystem: fileSystem, commands: [one, two])
        #expect(await shell.run("one").output.contains("/workspace/api/one-1.json"))
        #expect(await shell.run("two").output.contains("records are strings"))
        #expect(await shell.run("ls api").output == "one-1.json\ntwo-1.json")

        let taken = try emptyWorkspace(mountName: "api")
        let refused = await CommandInterpreter(fileSystem: taken, commands: [one]).run("one").output
        #expect(refused.contains("already used by another source"))
    }
}

/// Two pretend services with their own clients, the way an app would wire several APIs.
private final class TrackerClient: Sendable {
    let token: String
    let calls = Mutex<[String]>([])

    init(token: String) {
        self.token = token
    }

    func issues(_ parameters: [String: String], cursor: String?) throws -> APIPage {
        let sortedParameters = parameters.sorted { $0.key < $1.key }
        calls.withLock { $0.append("issues \(sortedParameters) \(cursor ?? "-") \(token)") }
        let all = (1...5).map { number in
            let status = number < 3 ? "open" : "done"
            return JSONValue.object(JSONObject([("key", .string("APP-\(number)")), ("status", .string(status))]))
        }
        let matching = all.filter { record in
            guard let status = parameters["status"], case let .object(object) = record else { return true }
            return object["status"] == .string(status)
        }
        let start = try #require(Int(cursor ?? "0"))
        let next = start + 2 < matching.count ? String(start + 2) : nil
        return APIPage(records: Array(matching.dropFirst(start).prefix(2)), nextCursor: next, total: matching.count)
    }
}

@Suite("API service")
struct APIServiceTests {
    private func setup() throws -> (shell: CommandInterpreter, client: TrackerClient) {
        let results = APIResults()
        let client = TrackerClient(token: "secret-token")
        let statusFilter = APIFilter("status", allowed: ["open", "done"])
        let issues = APIEndpoint<TrackerClient>(
            "issues",
            summary: "search issues",
            filters: [statusFilter]
        ) { client, query in
            try client.issues(query.parameters, cursor: query.cursor)
        }
        let issueFilter = APIFilter("issue", "issue key", required: true)
        let comments = APIEndpoint<TrackerClient>(
            "comments",
            summary: "comments of one issue",
            filters: [issueFilter]
        ) { _, query in
            let issue = try #require(query.parameters["issue"])
            let comment = JSONObject([("issue", .string(issue)), ("text", .string("looks good"))])
            return APIPage(records: [.object(comment)])
        }
        let tracker = APIService(
            "tracker",
            summary: "issue tracker",
            client: client,
            results: results,
            endpoints: [issues, comments]
        )
        let orders = APIEndpoint<Void>("orders", summary: "orders") { _, _ in APIPage(records: [.int(1), .int(2)]) }
        let shop = APIService("shop", summary: "store", client: (), results: results, endpoints: [orders])
        let fileSystem = try emptyWorkspace()
        let shell = CommandInterpreter(fileSystem: fileSystem, commands: [tracker, shop, JQCommand()])
        return (shell, client)
    }

    @Test("endpoints run as subcommands with the shared client")
    func endpoints() async throws {
        let (shell, client) = try setup()
        let issues = await shell.run("tracker issues --status open")
        #expect(issues.output.hasPrefix("saved 2 records"))
        #expect(issues.output.contains("/workspace/results/tracker-issues-1.json"))
        #expect(client.calls.withLock { $0 } == [#"issues [(key: "status", value: "open")] - secret-token"#])

        let all = await shell.run("tracker issues")
        #expect(all.output.contains("saved 5 records"))
        #expect(all.output.contains("3 pages"))
        #expect(all.output.contains("secret-token") == false)

        let comment = await shell.run("tracker comments --issue APP-1 --jq '.[0].text'").output
        #expect(comment == "\"looks good\"\n(all records: /workspace/results/tracker-comments-1.json)")
        #expect(await shell.run("shop orders").output.contains("/workspace/results/shop-orders-1.json"))
        let saved = ["shop-orders-1.json", "tracker-comments-1.json", "tracker-issues-1.json", "tracker-issues-2.json"]
        #expect(await shell.run("ls results").output == saved.joined(separator: "\n"))
    }

    @Test("help lists endpoints, and mistakes are explained")
    func help() async throws {
        let (shell, client) = try setup()
        let help = await shell.run("tracker").output
        #expect(help.contains("tracker: issue tracker"))
        #expect(help.contains("issues    [--status open|done] [--max N] [--jq FILTER] [--refresh]  search issues"))
        #expect(help.contains("comments  --issue ISSUE [--max N]"))
        #expect(await shell.run("tracker --help").output == help)
        #expect(await shell.run("tracker comments --help").output.contains("--issue VALUE  issue key [required]"))
        let usage = "tracker issues|comments [--FILTER VALUE]... [--max N] [--jq FILTER]   issue tracker"
        #expect(await shell.run("help").output.contains(usage))

        let unknown = await shell.run("tracker users").output
        #expect(unknown == "tracker: unknown endpoint 'users'; available: issues, comments")
        let missing = await shell.run("tracker comments").output
        #expect(missing == "tracker comments: --issue is required, see tracker comments --help")
        #expect(await shell.run("tracker issues --status closed").exitCode == 2)
        #expect(client.calls.withLock { $0 }.isEmpty)
    }
}
