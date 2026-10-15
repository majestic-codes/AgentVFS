//
//  HardeningTests.swift
//  AgentVFSTests
//
//  Created by Yevhenii Kalashnikov on 14.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation
import Testing
@testable import AgentVFS

/// A shell over one in-memory mount named `data`.
private func shell(_ files: [String: String], limits: OutputLimits = roomyLimits) throws -> CommandInterpreter {
    let driver = try InMemoryDriver(texts: files)
    let mount = WorkspaceMount(name: "data", driver: driver)
    let fileSystem = try WorkspaceFileSystem(mounts: [mount])
    return CommandInterpreter(fileSystem: fileSystem, limits: limits)
}

/// A driver whose root lists the given file names, whatever they are.
private struct NamedEntriesDriver: MountDriver {
    let names: [String]
    var info: MountInfo { MountInfo(kind: "test", source: "named entries") }

    func list(_ directory: EntryRef) async throws -> [DriverEntry] {
        names.map { DriverEntry(name: $0, kind: .file, size: 1) }
    }

    func read(_ file: EntryRef) async throws -> FileContent { .text(Data("x".utf8)) }
}

@Suite("patterns that cannot hang")
struct PatternTimeTests {
    @Test("globs that backtrack in a regular expression match in linear time")
    func globWithManyStars() throws {
        let glob = try Glob("*a*a*a*a*a*a*a*a*a*a*b")
        let started = ContinuousClock.now
        #expect(glob.matches(String(repeating: "a", count: 2000)) == false)
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test("overlong globs and deep brace nesting are refused", arguments: [
        String(repeating: "{a,", count: 11) + String(repeating: "}", count: 11),
        String(repeating: "a", count: 1001)
    ])
    func refusedGlobs(pattern: String) {
        #expect(throws: VFSError.self) { try Glob(pattern) }
    }

    @Test("case-insensitive classes cope with case mappings longer than one character")
    func caseMapping() throws {
        let glob = try Glob("[ß]*", caseInsensitive: true)
        #expect(glob.matches("ßtraße"))
        #expect(glob.matches("x") == false)
    }

    @Test("a backtracking regular expression gives up at its deadline")
    func regexDeadline() throws {
        let pattern = try PatternCompiler.compile(
            "(a+)+$",
            syntax: .extended,
            caseInsensitive: false,
            wholeWord: false,
            timeLimit: .milliseconds(200)
        )
        let started = ContinuousClock.now
        #expect(pattern.matches(String(repeating: "a", count: 44) + "!") == false)
        #expect(ContinuousClock.now - started < .seconds(12))
        #expect(pattern.isPastDeadline)
    }
}

@Suite("output and pipeline bounds")
struct OutputBoundTests {
    @Test("output keeps at most its byte limit, cut at a character")
    func byteLimit() {
        var output = CommandOutput.$currentByteLimit.withValue(5) { CommandOutput() }
        output.write("aé")
        output.write("éé")
        #expect(output.standardOutput == "aéé")
        #expect(output.isFull)
        output.error("still reported", code: 1)
        #expect(output.standardError == "still")
        #expect(output.exitCode == 1)
    }

    @Test("a command repeating a file many times stops at the limit")
    func repeatedFile() async throws {
        let big = String(repeating: "0123456789\n", count: 1000)
        let interpreter = try shell(["big.txt": big], limits: OutputLimits(maxBytes: 1000))
        let line = "cat " + Array(repeating: "data/big.txt", count: 300).joined(separator: " ")
        let result = await interpreter.run(line)
        #expect(result.truncated)
        #expect(result.output.utf8.count < 2000)
    }

    @Test("pipelines are limited in length")
    func longPipeline() async throws {
        let line = "cat data/a.txt" + String(repeating: " | head", count: CommandInterpreter.maxPipelineCommands)
        let result = try await shell(["a.txt": "x\n"]).run(line)
        #expect(result.exitCode == 2)
        #expect(result.output.contains("at most"))
    }

    @Test("search notes go to standard error, so they are not counted after a pipe")
    func notesStayOutOfPipes() async throws {
        let result = try await shell(["a.txt": "x\n"]).run("grep -r zz data | wc -l")
        #expect(result.output.hasSuffix("\n0"))
    }

    @Test("counts in a pipe or with -c are not cut at the shown match limit")
    func countsAreWhole() async throws {
        let text = String(repeating: "match\n", count: 1500)
        let interpreter = try shell(["a.txt": text], limits: OutputLimits(maxSearchMatches: 100))
        #expect(await interpreter.run("grep -c match data/a.txt").output == "1500")
        #expect(await interpreter.run("grep match data/a.txt | wc -l").output == "1500")
    }
}

@Suite("text filters behave like the real tools")
struct TextFilterFidelityTests {
    @Test("wc -c counts the bytes of the file, not of its decoded text")
    func bytesOfFile() async throws {
        var data = Data([0xFF, 0xFE])
        let wide = try #require("a\nb\n".data(using: .utf16LittleEndian))
        data.append(wide)
        let driver = try InMemoryDriver(files: ["wide.txt": data])
        let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "data", driver: driver)])
        let result = await CommandInterpreter(fileSystem: fileSystem).run("wc -c data/wide.txt")
        #expect(result.output == "\(data.count) data/wide.txt")
    }

    @Test("wc -m counts carriage returns and combining marks", arguments: [
        ("a\r\nb\r\n", "6"),
        ("e\u{301}\n", "3")
    ])
    func characters(text: String, expected: String) async throws {
        #expect(try await shell(["a.txt": text]).run("cat data/a.txt | wc -m").output == expected)
    }

    @Test("sort -u keeps the first line of equal keys, in input order", arguments: [
        ("printf.txt", "b 1\na 1\n", "sort -u -k2 data/printf.txt", "b 1"),
        ("words.txt", "pear\napple\npear\nApple\nfig\n", "sort -f -u data/words.txt", "apple\nfig\npear")
    ])
    func uniqueKeys(name: String, text: String, line: String, expected: String) async throws {
        #expect(try await shell([name: text]).run(line).output == expected)
    }

    @Test("sort refuses what it would otherwise misread", arguments: [
        "sort -k2,2 -k1,1 data/a.txt",
        "sort -k2,2n data/a.txt",
        "sort -b data/a.txt"
    ])
    func sortRefusals(line: String) async throws {
        #expect(try await shell(["a.txt": "x\n"]).run(line).exitCode == 2)
    }

    @Test("cut refuses lists and options GNU cut refuses", arguments: [
        "cut -c 1 -d , data/a.txt",
        "cut -c 1 -s data/a.txt",
        "cut -f 1,,3 data/a.txt",
        "cut -f - data/a.txt"
    ])
    func cutRefusals(line: String) async throws {
        #expect(try await shell(["a.txt": "x\n"]).run(line).exitCode == 2)
    }

    @Test("cut with many ranges on a long line stays fast")
    func manyRanges() async throws {
        let list = stride(from: 1, to: 2000, by: 2).map(String.init).joined(separator: ",")
        let line = String(repeating: "x,", count: 200_000) + "\n"
        let started = ContinuousClock.now
        let result = try await shell(["a.txt": line]).run("cut -d , -f \(list) data/a.txt | wc -c")
        #expect(result.exitCode == 0)
        #expect(ContinuousClock.now - started < .seconds(12))
    }
}

@Suite("isolation")
struct IsolationTests {
    @Test("names that could make a listing lie are not listed", arguments: [
        "new\nline.txt", "esc\u{1B}[2J.txt", "right\u{202E}txt.exe", "isolate\u{2066}.txt",
        "mark\u{200F}.txt", "line\u{2028}sep.txt", "zero\u{200B}width.txt", "joiner\u{2060}.txt"
    ])
    func hidingNames(name: String) async throws {
        let driver = NamedEntriesDriver(names: [name, "ok.txt"])
        let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "data", driver: driver)])
        let result = await CommandInterpreter(fileSystem: fileSystem).run("ls data")
        #expect(result.output == "ok.txt")
    }

    @Test("a download cache shared by two workspaces keeps their files apart")
    func sharedCache() async throws {
        let firstDriver = try InMemoryDriver(texts: ["a.txt": "first"])
        let first = try WorkspaceFileSystem(mounts: [
            WorkspaceMount(name: "docs", driver: firstDriver)
        ])
        let secondDriver = try InMemoryDriver(texts: ["a.txt": "second"])
        let second = try WorkspaceFileSystem(mounts: [
            WorkspaceMount(name: "docs", driver: secondDriver)
        ])
        let cache = DownloadCache(capacity: 1_000, label: "Test")
        let firstLease = try await cache.lease(path: "/workspace/docs/a.txt", fileSystem: first, maxBytes: 100)
        let secondLease = try await cache.lease(path: "/workspace/docs/a.txt", fileSystem: second, maxBytes: 100)
        defer {
            firstLease.finish()
            secondLease.finish()
        }
        #expect(try String(contentsOf: firstLease.url, encoding: .utf8) == "first")
        #expect(try String(contentsOf: secondLease.url, encoding: .utf8) == "second")
    }

    @Test("an evicted download stays on disk until its lease finishes")
    func leasedFileOutlivesEviction() async throws {
        let driver = try InMemoryDriver(texts: ["a.txt": "0123456789", "b.txt": "abcdefghij"])
        let fileSystem = try WorkspaceFileSystem(mounts: [
            WorkspaceMount(name: "docs", driver: driver)
        ])
        let cache = DownloadCache(capacity: 15, label: "Test")
        let first = try await cache.lease(path: "/workspace/docs/a.txt", fileSystem: fileSystem, maxBytes: 100)
        let second = try await cache.lease(path: "/workspace/docs/b.txt", fileSystem: fileSystem, maxBytes: 100)
        #expect(FileManager.default.fileExists(atPath: first.url.path))
        first.finish()
        #expect(FileManager.default.fileExists(atPath: first.url.path) == false)
        second.finish()
        #expect(FileManager.default.fileExists(atPath: second.url.path))
    }

    @Test("a local file with a second hard link is not read")
    func hardLink() async throws {
        let root = try makeTemporaryDirectory()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
        let outside = try makeTemporaryDirectory(["secret.txt": "secret\n"])
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: outside) } }
        try FileManager.default.linkItem(
            at: outside.appendingPathComponent("secret.txt"),
            to: root.appendingPathComponent("linked.txt")
        )
        let driver = try LocalDirectoryDriver(root: root)
        let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "local", driver: driver)])
        let result = await CommandInterpreter(fileSystem: fileSystem).run("cat local/linked.txt")
        #expect(result.exitCode == 1)
        #expect(result.output.contains("hard links"))
        #expect(result.output.contains("secret") == false)
    }
}
