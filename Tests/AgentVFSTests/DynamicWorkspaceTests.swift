//
//  DynamicWorkspaceTests.swift
//  AgentVFSTests
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation
import Testing
@testable import AgentVFS

@Suite("Changing the workspace")
struct DynamicWorkspaceTests {
    @Test("files put into an in-memory driver show up in listings, reads and searches")
    func putAndRemove() async throws {
        let notes = try InMemoryDriver(texts: ["a.txt": "alpha\n"])
        let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "kb", driver: notes)])
        let shell = CommandInterpreter(fileSystem: fileSystem)

        #expect(await shell.run("ls kb").output == "a.txt")
        #expect(await shell.run("grep -rl needle /workspace").exitCode == 1)

        try notes.put("data/x.json", data: Data(#"{"needle": 1}"#.utf8))
        #expect(await shell.run("ls kb").output == "a.txt\ndata/")
        #expect(await shell.run("cat kb/data/x.json").output == #"{"needle": 1}"#)
        let found = await shell.run("grep -rl needle /workspace").output
        #expect(found == "/workspace/kb/data/x.json", "the cached search result is dropped")

        try notes.put("a.txt", text: "beta\n")
        #expect(await shell.run("cat kb/a.txt").output == "beta", "the cached content is dropped")

        #expect(try notes.remove("data"))
        #expect(await shell.run("ls kb").output == "a.txt")
        #expect(await shell.run("cat kb/data/x.json").exitCode == 1)
        #expect(try notes.remove("data") == false)
    }

    @Test("paths are checked when files are put")
    func putValidation() throws {
        let notes = InMemoryDriver()
        #expect(throws: VFSError.self) { try notes.put("../x", text: "") }
        #expect(throws: VFSError.self) { try notes.put("", text: "") }
        try notes.put("dir/file", text: "")
        #expect(throws: VFSError.self) { try notes.put("dir", text: "") }
        #expect(throws: VFSError.self) { try notes.put("dir/file/inner", text: "") }
        #expect(notes.paths == ["dir/file"])
    }

    @Test("mounts can be added and removed while the workspace is in use")
    func addAndRemoveMounts() async throws {
        let first = try InMemoryDriver(texts: ["x.txt": "needle\n"])
        let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "a", driver: first)])
        let shell = CommandInterpreter(fileSystem: fileSystem)
        #expect(await shell.run("grep -rl needle /workspace").output == "/workspace/a/x.txt")

        let second = try InMemoryDriver(texts: ["y.txt": "needle\n"])
        try await fileSystem.addMount(WorkspaceMount(name: "b", driver: second))
        #expect(await shell.run("ls /workspace").output == "a/\nb/")
        #expect(await shell.run("grep -rl needle /workspace").output == "/workspace/a/x.txt\n/workspace/b/y.txt")

        await #expect(throws: VFSError.self) {
            try await fileSystem.addMount(WorkspaceMount(name: "b", driver: InMemoryDriver()))
        }
        await #expect(throws: VFSError.self) {
            try await fileSystem.addMount(WorkspaceMount(name: "../c", driver: InMemoryDriver()))
        }

        try await fileSystem.removeMount(named: "b")
        #expect(await shell.run("ls /workspace").output == "a/")
        #expect(await shell.run("cat b/y.txt").output.contains("no such mount"))

        // The same name may come back with other content. Nothing cached for the old one leaks.
        let replacement = try InMemoryDriver(texts: ["y.txt": "other\n"])
        try await fileSystem.addMount(WorkspaceMount(name: "b", driver: replacement))
        #expect(await shell.run("cat b/y.txt").output == "other")

        await #expect(throws: VFSError.unknownMount("nope")) { try await fileSystem.removeMount(named: "nope") }
        try await fileSystem.removeMount(named: "b")
        await #expect(throws: VFSError.self) { try await fileSystem.removeMount(named: "a") }
    }

    @Test("refresh picks up files added to a local directory")
    func refreshLocal() async throws {
        let root = try makeTemporaryDirectory()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
        try Data("one\n".utf8).write(to: root.appendingPathComponent("one.txt"))
        let driver = try LocalDirectoryDriver(root: root)
        let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "d", driver: driver)])
        let shell = CommandInterpreter(fileSystem: fileSystem)
        #expect(await shell.run("ls d").output == "one.txt")

        try Data("two\n".utf8).write(to: root.appendingPathComponent("two.txt"))
        #expect(await shell.run("ls d").output == "one.txt", "listings are cached until refreshed")
        try await fileSystem.refresh(mountNamed: "d")
        #expect(await shell.run("ls d").output == "one.txt\ntwo.txt")
    }
}
