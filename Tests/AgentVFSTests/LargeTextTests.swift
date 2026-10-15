//
//  LargeTextTests.swift
//  AgentVFSTests
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation
import Testing
@testable import AgentVFS

@Suite("Large text files")
struct LargeTextTests {
    /// A log far over the tiny read limits used here, so every command takes the large-file path.
    private let log = (1...2000)
        .map { $0.isMultiple(of: 500) ? "line \($0) ERROR disk full" : "line \($0) INFO ok" }
        .joined(separator: "\n") + "\n"
    private let limits = VFSLimits(maxReadBytes: 1_000)
    private let output = OutputLimits(maxSearchFileBytes: 1_000)

    private func local() throws -> (CommandInterpreter, URL) {
        let root = try makeTemporaryDirectory()
        try Data(log.utf8).write(to: root.appendingPathComponent("app.log"))
        let legacy = try #require("заголовок\nрядок два\nостанній\n".data(using: .windowsCP1251))
        try legacy.write(to: root.appendingPathComponent("legacy.txt"))
        let fileSystem = try localFileSystem(root: root)
        return (CommandInterpreter(fileSystem: fileSystem, limits: output), root)
    }

    private func localFileSystem(root: URL) throws -> WorkspaceFileSystem {
        let driver = try LocalDirectoryDriver(root: root)
        let mount = WorkspaceMount(name: "d", driver: driver)
        return try WorkspaceFileSystem(mounts: [mount], limits: VFSLimits(maxReadBytes: 20))
    }

    @Test("head, tail and sed read large local files line by line")
    func lineCommands() async throws {
        let (shell, root) = try local()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
        #expect(await shell.run("head -n 2 d/app.log").output == "line 1 INFO ok\nline 2 INFO ok")
        #expect(await shell.run("tail -n 2 d/app.log").output == "line 1999 INFO ok\nline 2000 ERROR disk full")
        #expect(await shell.run("sed -n '500,501p' d/app.log").output == "line 500 ERROR disk full\nline 501 INFO ok")
        #expect(await shell.run("tail -n +1999 d/app.log").output == "line 1999 INFO ok\nline 2000 ERROR disk full")
        #expect(await shell.run("tail -n 1 d/legacy.txt").output == "останній", "legacy encodings are decoded per line")
        let cat = await shell.run("cat d/app.log")
        #expect(cat.exitCode == 1)
        #expect(cat.output.contains("read parts with head, tail, sed -n"))
    }

    @Test("grep and rg search large local files, with context")
    func search() async throws {
        let (shell, root) = try local()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
        #expect(await shell.run("grep -c ERROR d/app.log").output == "4")
        let firstMatch = await shell.run("grep -n 'ERROR disk' d/app.log").output.components(separatedBy: "\n").first
        #expect(firstMatch == "500:line 500 ERROR disk full")
        let insensitive = await shell.run("grep -in 'error DISK' d/app.log").output.components(separatedBy: "\n")
        #expect(insensitive.count == 4, "case-insensitive takes the line-by-line path")
        let context = await shell.run("rg -n -C1 'line 1500 ' d").output
        #expect(context == """
        /workspace/d/app.log-1499-line 1499 INFO ok
        /workspace/d/app.log:1500:line 1500 ERROR disk full
        /workspace/d/app.log-1501-line 1501 INFO ok
        """)
        #expect(await shell.run("grep -rn 'рядок' d").output == "/workspace/d/legacy.txt:2:рядок два")
    }

    @Test("in-memory files take the same path; remote-style sources keep the size limit")
    func sources() async throws {
        let driver = try InMemoryDriver(texts: ["app.log": log])
        let memoryMount = WorkspaceMount(name: "m", driver: driver)
        let memory = try WorkspaceFileSystem(mounts: [memoryMount], limits: limits)
        let shell = CommandInterpreter(fileSystem: memory, limits: output)
        #expect(await shell.run("grep -c ERROR m/app.log").output == "4")
        #expect(await shell.run("tail -n 1 m/app.log").output == "line 2000 ERROR disk full")

        await #expect(throws: VFSError.self) {
            _ = try await memory.largeText(path: "/workspace/m/app.log", maxBytes: 10)
        }

        // A source without cheap listings, such as a remote API, keeps the whole-read limit.
        struct Remote: MountDriver {
            let inner: InMemoryDriver
            var info: MountInfo { inner.info }
            func list(_ directory: EntryRef) async throws -> [DriverEntry] { try await inner.list(directory) }
            func read(_ file: EntryRef) async throws -> FileContent { try await inner.read(file) }
            func readExactBytes(_ file: EntryRef) async throws -> Data { try await inner.readExactBytes(file) }
        }
        let inner = try InMemoryDriver(texts: ["app.log": log])
        let remoteMount = WorkspaceMount(name: "r", driver: Remote(inner: inner))
        let remote = try WorkspaceFileSystem(mounts: [remoteMount], limits: limits)
        let remoteShell = CommandInterpreter(fileSystem: remote, limits: output)
        #expect(await remoteShell.run("tail -n 1 r/app.log").output.contains("too large"))
        #expect(await remoteShell.run("grep -c ERROR r/app.log").output.contains("skipped: larger than"))
        let largeText = try await remote.largeText(path: "/workspace/r/app.log", maxBytes: 1_000_000)
        #expect(try largeText.lastLines(1) == ["line 2000 ERROR disk full"])
    }

    @Test("output stops at the line limit instead of collecting the whole file")
    func outputCap() async throws {
        let (_, root) = try local()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
        let fileSystem = try localFileSystem(root: root)
        let shell = CommandInterpreter(fileSystem: fileSystem, limits: OutputLimits(maxLines: 5))
        let result = await shell.run("sed -n '1,$p' d/app.log")
        #expect(result.truncated)
        #expect(result.output.hasPrefix("line 1 INFO ok\nline 2 INFO ok"))
    }

    @Test("expressions without a literal are matched per line, even when searched in blocks")
    func expressions() async throws {
        let (shell, root) = try local()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
        #expect(await shell.run("grep -c -E 'ERROR|WARN' d/app.log").output == "4")
        let thousands = await shell.run("grep -n -E '^line 1[0-9]{3} ERROR' d/app.log").output
        #expect(thousands == "1000:line 1000 ERROR disk full\n1500:line 1500 ERROR disk full")
        #expect(await shell.run("grep -c -E 'full$' d/app.log").output == "4")
        // `full\sline` matches across a line break when the block is searched as a whole. Grep
        // matches lines, so it must report nothing.
        #expect(await shell.run("grep -c -E 'full\\sline' d/app.log").output.hasPrefix("0\n[no matches"))
        #expect(await shell.run("grep -n -i -E 'ПОВЕРН|рядок' d/legacy.txt").output == "2:рядок два")
    }

    @Test("lines and last lines at the edges")
    func edges() throws {
        func text(_ string: String) -> LargeText { LargeText(path: "/x", data: Data(string.utf8), encoding: .utf8) }
        #expect(try text("").lastLines(3).isEmpty)
        #expect(try text("\n").lastLines(3) == [""])
        #expect(try text("a").lastLines(3) == ["a"])
        #expect(try text("a\nb\n").lastLines(1) == ["b"])
        #expect(try text("a\n\n").lastLines(5) == ["a", ""])
        #expect(try text("a\r\nb\r\n").lastLines(5) == ["a", "b"])
        #expect(try text("\u{FEFF}first\nsecond").lastLines(5) == ["first", "second"])
        #expect(try text("\u{FEFF}first\nsecond").lines(from: 1, through: 1, limit: 9) == ["first"])
        #expect(try text("a\nb\nc\n").lines(from: 2, through: nil, limit: 9) == ["b", "c"])
        #expect(try text("a\nb\nc").lines(from: 2, through: 9, limit: 1) == ["b"])
    }
}
