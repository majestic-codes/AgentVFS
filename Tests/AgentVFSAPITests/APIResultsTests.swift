//
//  APIResultsTests.swift
//  AgentVFSAPITests
//
//  Created by Yevhenii Kalashnikov on 14.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import AgentVFSAPI
import AgentVFSJQ
import Testing

@Suite("APIResults for your own commands")
struct APIResultsTests {
    /// A command like one a client app would write: it answers with a fixed JSON object.
    private func getCommand(results: APIResults) -> Command {
        Command("api", usage: "api get PATH   read the client API", readsStandardInput: false) { arguments, context in
            guard arguments.count == 2, arguments[0].text == "get" else {
                throw CommandError.usage("usage: api get PATH")
            }
            let path = arguments[1].text
            try await results.ensureMounted(in: context.fileSystem)
            let key = "get " + path
            let saved = if let cached = await results.cached(key) {
                cached
            } else {
                try await results.save(text: #"{"id":42,"status":"open"}"#, command: "api-get", key: key)
            }
            return CommandOutput(text: "saved \(saved.path) (\(saved.bytes) bytes)\n")
        }
    }

    @Test("a command saves a response, reuses it for the same request, and jq reads it")
    func saveAndRead() async throws {
        let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "code", driver: InMemoryDriver())])
        let results = APIResults()
        let shell = CommandInterpreter(fileSystem: fileSystem, commands: [getCommand(results: results), JQCommand()])
        let first = await shell.run("api get /v1/orders/42")
        #expect(first.output == "saved /workspace/results/api-get-1.json (25 bytes)")
        #expect(await shell.run("api get /v1/orders/42").output == first.output)
        #expect(await shell.run("jq -r .status results/api-get-1.json").output == "open")
    }

    @Test("records are saved one per line, numbered per command")
    func records() async throws {
        let results = APIResults()
        let firstRecord = try JQ.parse(#"{"id":1}"#)
        let secondRecord = try JQ.parse(#"{"id":2}"#)
        let records = [firstRecord, secondRecord]
        let first = try await results.save(records, command: "orders", key: "a")
        let second = try await results.save([], command: "orders", key: "b")
        #expect(first.name == "orders-1.json")
        #expect(second.name == "orders-2.json")
        #expect(await results.cached("a") == first)
        #expect(await results.cached("missing") == nil)
    }
}
