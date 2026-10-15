//
//  DriverTests.swift
//  AgentVFSTests
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation
import Synchronization
import Testing
@testable import AgentVFS

/// A driver over a pretend issue tracker: each issue is a Markdown file, listed and fetched lazily.
private struct IssueTrackerDriver: MountDriver {
    struct Issue: Sendable {
        let key: String
        let title: String
        let body: String
        let revision: Int
    }

    final class Calls: Sendable {
        private let counts = Mutex<[String: Int]>([:])
        func record(_ name: String) { counts.withLock { $0[name, default: 0] += 1 } }
        func count(_ name: String) -> Int { counts.withLock { $0[name] ?? 0 } }
    }

    let issues: [String: [Issue]]
    let calls = Calls()

    var info: MountInfo {
        let linkTemplate = "https://tracker.example.com/<path>"
        return MountInfo(
            kind: "tracker",
            source: "tracker.example.com",
            summary: "issue tracker, live",
            linkTemplate: linkTemplate
        )
    }

    func list(_ directory: EntryRef) async throws -> [DriverEntry] {
        calls.record("list")
        if directory.path.isEmpty {
            return issues.keys.map { DriverEntry(name: $0, kind: .directory) }
        }
        guard let project = issues[directory.path] else { throw VFSError.notFound(directory.path) }
        return project.map { DriverEntry(name: "\($0.key).md", kind: .file, size: nil, id: "\($0.key)@\($0.revision)") }
    }

    func read(_ file: EntryRef) async throws -> FileContent {
        calls.record("read")
        let key = String(file.name.dropLast(3))
        guard let issue = issues.values.joined().first(where: { $0.key == key }) else {
            throw VFSError.notFound(file.path)
        }
        return .text(Data("# \(issue.key): \(issue.title)\n\n\(issue.body)\n".utf8))
    }

    func searchCandidates(for term: String) async throws -> SearchCandidates {
        calls.record("search")
        var paths = Set<String>()
        for (project, list) in issues {
            for issue in list where issue.body.contains(term) || issue.title.contains(term) {
                paths.insert("\(project)/\(issue.key).md")
            }
        }
        return .paths(paths)
    }

    func link(to path: String, line: Int?) -> URL? {
        URL(string: "https://tracker.example.com/" + path)
    }
}

@Suite("Drivers")
struct DriverTests {
    @Test("a local directory is listed, read and searched")
    func localDirectory() async throws {
        let root = try makeTemporaryDirectory([
            "README.md": "# Demo\n",
            "Sources/App.swift": "struct App {\n    let name = \"demo\"\n}\n",
            ".git/config": "secret\n"
        ])
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
        let driver = try LocalDirectoryDriver(root: root)
        let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "app", driver: driver)])
        let shell = CommandInterpreter(fileSystem: fileSystem)

        #expect(await shell.run("ls /workspace/app").output == "README.md\nSources/")
        #expect(await shell.run("cat app/Sources/App.swift").output.contains("struct App"))
        let found = await shell.run("grep -rn demo /workspace").output
        #expect(found == "/workspace/app/Sources/App.swift:2:    let name = \"demo\"")
        #expect(await shell.run("cat app/.git/config").exitCode != 0)
    }

    @Test("a symbolic link inside a local mount is never followed")
    func localSymlink() async throws {
        let root = try makeTemporaryDirectory(["inside.txt": "ok\n"])
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
        let linkPath = root.appendingPathComponent("hosts").path
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: "/etc/hosts")
        let driver = try LocalDirectoryDriver(root: root)
        let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "m", driver: driver)])

        await #expect(throws: VFSError.symbolicLink(path: "/workspace/m/hosts")) {
            try await fileSystem.read(path: "/workspace/m/hosts")
        }
        await #expect(throws: VFSError.outsideWorkspace("/etc/hosts")) {
            try await fileSystem.read(path: "/etc/hosts")
        }
    }

    @Test("in-memory files get implicit directories and binary detection")
    func inMemory() async throws {
        let driver = try InMemoryDriver(files: [
            "docs/guide/intro.md": Data("hello\n".utf8),
            "logo.png": Data([0x89, 0x50, 0x00, 0x01])
        ])
        let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "kb", driver: driver)])

        #expect(try await fileSystem.list(path: "/workspace/kb").map(\.name) == ["docs", "logo.png"])
        #expect(try await fileSystem.readText(path: "/workspace/kb/docs/guide/intro.md").text == "hello\n")
        await #expect(throws: VFSError.binaryFile(path: "/workspace/kb/logo.png", size: 4)) {
            try await fileSystem.read(path: "/workspace/kb/logo.png")
        }
    }

    @Test("an API driver is listed lazily, cached by entry id and cited with its links")
    func apiDriver() async throws {
        let driver = IssueTrackerDriver(issues: [
            "PROJ": [
                .init(key: "PROJ-1", title: "Crash on launch", body: "The sync queue deadlocks.", revision: 3),
                .init(key: "PROJ-2", title: "Dark mode", body: "Colors are wrong.", revision: 1)
            ]
        ])
        let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "issues", driver: driver)])
        let shell = CommandInterpreter(fileSystem: fileSystem)

        #expect(await shell.run("ls issues/PROJ").output == "PROJ-1.md\nPROJ-2.md")
        #expect(await shell.run("head -n 1 issues/PROJ/PROJ-1.md").output == "# PROJ-1: Crash on launch")
        #expect(await shell.run("cat issues/PROJ/PROJ-1.md").exitCode == 0)
        #expect(driver.calls.count("read") == 1)

        let options = SearchOptions(syntax: .fixed, strategy: .remote)
        let page = try await fileSystem.search(pattern: "deadlocks", path: "/workspace", options: options)
        #expect(page.strategy == .remote)
        #expect(driver.calls.count("search") == 1)
        #expect(page.matches.map(\.path) == ["/workspace/issues/PROJ/PROJ-1.md"])
        #expect(page.matches.first?.url?.absoluteString == "https://tracker.example.com/PROJ/PROJ-1.md")
        let reads = driver.calls.count("read")
        #expect(reads == 1, "PROJ-2 is ruled out by the index and PROJ-1 comes from the cache")
    }

    @Test("drivers of different kinds share one workspace")
    func mixedMounts() async throws {
        let firstDriver = try InMemoryDriver(texts: ["x.txt": "needle in a\n"])
        let secondDriver = try InMemoryDriver(texts: ["y.txt": "needle in b\n"])
        let fileSystem = try WorkspaceFileSystem(mounts: [
            WorkspaceMount(name: "a", driver: firstDriver),
            WorkspaceMount(name: "b", driver: secondDriver)
        ])
        let shell = CommandInterpreter(fileSystem: fileSystem)
        #expect(await shell.run("grep -rl needle /workspace").output == "/workspace/a/x.txt\n/workspace/b/y.txt")
    }

    @Test("mount names are validated and must be unique")
    func mountValidation() throws {
        let driver = try InMemoryDriver(texts: [:])
        #expect(throws: VFSError.self) { try WorkspaceFileSystem(mounts: []) }
        let escaping = WorkspaceMount(name: "../x", driver: driver)
        let invalidName = "mount name '../x' may only contain letters, digits, '.', '_' and '-'"
        #expect(throws: VFSError.invalidConfiguration(invalidName)) { try WorkspaceFileSystem(mounts: [escaping]) }
        let mount = WorkspaceMount(name: "a", driver: driver)
        let repeated = VFSError.invalidConfiguration("mount name 'a' is used more than once")
        #expect(throws: repeated) { try WorkspaceFileSystem(mounts: [mount, mount]) }
    }
}

@Suite("Custom commands")
struct CustomCommandTests {
    private func workspace() throws -> WorkspaceFileSystem {
        let driver = try InMemoryDriver(texts: ["a.txt": "one\ntwo\nthree\n"])
        return try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "kb", driver: driver)])
    }

    /// `wc -l FILE...`, written the way a user of the package would.
    private static let wordCountUsage = "wc -l FILE...                      count lines"

    private let wordCount = Command("wc", usage: Self.wordCountUsage) { arguments, context in
        let parsed = try OptionParser.parse(arguments, spec: OptionSpec(flags: ["l"]), command: "wc")
        guard parsed.has("l") else { throw CommandError.usage("wc: only -l is supported") }
        var output = CommandOutput()
        for operand in parsed.positionals {
            do {
                let path = try context.resolvePath(operand).description
                let file = try await context.fileSystem.readText(path: path)
                output.line("\(CommandContext.lines(of: file.text).count) \(file.path)")
            } catch let error as VFSError {
                output.fail("wc", context.describe(error), code: 1)
            }
        }
        return output
    }

    @Test("a registered command runs, shows in help and in the not-found message")
    func register() async throws {
        let shell = CommandInterpreter(fileSystem: try workspace(), commands: [wordCount])
        #expect(await shell.run("wc -l kb/a.txt").output == "3 /workspace/kb/a.txt")
        #expect(await shell.run("wc kb/a.txt").output == "wc: only -l is supported")
        #expect(await shell.run("wc -l kb/missing").exitCode == 1)
        #expect(await shell.run("help").output.contains("wc -l FILE..."))
        #expect(await shell.run("nope").output.contains("wc"))
        #expect(await shell.commandNames.contains("wc"))
    }

    @Test("a command can replace a standard one, or the standard set can be left out")
    func replaceAndRestrict() async throws {
        let quietLs = Command("ls", usage: "ls    nothing to see") { _, _ in CommandOutput(text: "(hidden)\n") }
        let replaced = CommandInterpreter(fileSystem: try workspace(), commands: [quietLs])
        #expect(await replaced.run("ls").output == "(hidden)")

        let fileSystem = try workspace()
        let minimal = CommandInterpreter(fileSystem: fileSystem, commands: [wordCount], includeStandardCommands: false)
        #expect(await minimal.commandNames == ["help", "wc"])
        #expect(await minimal.run("cat kb/a.txt").exitCode == 127)
    }

    @Test("a command can change the working directory")
    func changesDirectory() async throws {
        let home = Command("home", usage: "") { _, context in
            var output = CommandOutput()
            output.newWorkingDirectory = try context.resolvePath("/workspace/kb")
            return output
        }
        let shell = CommandInterpreter(fileSystem: try workspace(), commands: [home])
        _ = await shell.run("home")
        #expect(await shell.currentDirectory == "/workspace/kb")
        #expect(await shell.run("cat a.txt").exitCode == 0)
    }
}

@Suite("Local directory safety")
struct LocalDirectorySafetyTests {
    private func directory() throws -> URL {
        try makeTemporaryDirectory(["docs/a.txt": "inside\n"])
    }

    @Test("a file swapped for a link after listing is not followed")
    func swappedFile() async throws {
        let root = try directory()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
        let driver = try LocalDirectoryDriver(root: root)
        let entries = try await driver.list(EntryRef(path: "docs"))
        #expect(entries.map(\.name) == ["a.txt"])

        try FileManager.default.removeItem(at: root.appendingPathComponent("docs/a.txt"))
        let linkPath = root.appendingPathComponent("docs/a.txt").path
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: "/etc/hosts")
        await #expect(throws: VFSError.symbolicLink(path: "docs/a.txt")) {
            _ = try await driver.read(EntryRef(path: "docs/a.txt"))
        }
    }

    @Test("a directory swapped for a link after listing is not followed")
    func swappedDirectory() async throws {
        let root = try directory()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
        let outside = try directory()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: outside) } }
        try Data("secret\n".utf8).write(to: outside.appendingPathComponent("docs/a.txt"))
        let driver = try LocalDirectoryDriver(root: root)

        try FileManager.default.removeItem(at: root.appendingPathComponent("docs"))
        let linkPath = root.appendingPathComponent("docs").path
        let destination = outside.appendingPathComponent("docs").path
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: destination)
        let file = EntryRef(path: "docs/a.txt")
        await #expect(throws: VFSError.notFound("docs/a.txt")) { _ = try await driver.read(file) }
        await #expect(throws: VFSError.notFound("docs")) { _ = try await driver.list(EntryRef(path: "docs")) }
    }

    @Test("the root may be given through a link or in another letter case")
    func rootSpelling() async throws {
        let root = try directory()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("AgentVFSLink-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: link) } }
        let expected = FileContent.text(Data("inside\n".utf8))
        #expect(try await LocalDirectoryDriver(root: link).read(EntryRef(path: "docs/a.txt")) == expected)

        let upper = URL(fileURLWithPath: root.path.uppercased())
        if FileManager.default.fileExists(atPath: upper.path) {  // only on a case-insensitive volume
            #expect(try await LocalDirectoryDriver(root: upper).read(EntryRef(path: "docs/a.txt")) == expected)
        }
    }
}

@Suite("Local directory driver")
struct LocalDirectoryDriverTests {
    @Test("two files with the same size and modification time return their own contents")
    func sameSizeAndTime() async throws {
        let root = try makeTemporaryDirectory(["a.txt": "first\n", "b.txt": "other\n"])
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        for name in ["a.txt", "b.txt"] {
            let path = root.appendingPathComponent(name).path
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
        }
        let driver = try LocalDirectoryDriver(root: root)
        let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "d", driver: driver)])
        let shell = CommandInterpreter(fileSystem: fileSystem)
        #expect(await shell.run("cat d/a.txt").output == "first")
        #expect(await shell.run("cat d/b.txt").output == "other")
    }

    @Test("a hard-linked file does not stop a recursive search of the others")
    func hardLinkInSearch() async throws {
        let root = try makeTemporaryDirectory(["plain.txt": "needle\n"])
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
        let outside = try makeTemporaryDirectory(["linked.txt": "needle outside\n"])
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: outside) } }
        try FileManager.default.linkItem(
            at: outside.appendingPathComponent("linked.txt"),
            to: root.appendingPathComponent("linked.txt")
        )
        let driver = try LocalDirectoryDriver(root: root)
        let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "d", driver: driver)])
        let result = await CommandInterpreter(fileSystem: fileSystem).run("grep -r needle d")
        #expect(result.exitCode == 0)
        #expect(result.output.hasPrefix("/workspace/d/plain.txt:needle"))
        #expect(result.output.contains("outside") == false)
    }

    @Test("a file that grew after it was listed is refused")
    func grownFile() async throws {
        let root = try makeTemporaryDirectory(["a.txt": "short\n"])
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
        let driver = try LocalDirectoryDriver(root: root)
        let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "d", driver: driver)])
        _ = try await fileSystem.list(path: "/workspace/d")
        try Data("much longer than before\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        let result = await CommandInterpreter(fileSystem: fileSystem).run("cat d/a.txt")
        #expect(result.exitCode == 1)
        #expect(result.output.contains("changed after the workspace listed it"))
    }

    @Test("the root of the disk can be mounted")
    func diskRoot() async throws {
        let directory = try makeTemporaryDirectory(["a.txt": "at the root\n"])
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let realDirectory = try LocalDirectoryDriver(root: directory).root.path
        let driver = try LocalDirectoryDriver(root: URL(fileURLWithPath: "/"))
        #expect(driver.root.path == "/")
        let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "disk", driver: driver)])
        let path = "/workspace/disk" + realDirectory + "/a.txt"
        #expect(try await fileSystem.readText(path: path).text == "at the root\n")
    }
}
