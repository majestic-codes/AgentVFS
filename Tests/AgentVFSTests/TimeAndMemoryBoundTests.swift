//
//  TimeAndMemoryBoundTests.swift
//  AgentVFSTests
//
//  Created by Yevhenii Kalashnikov on 15.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation
import Testing
@testable import AgentVFS

/// A shell over one in-memory mount named `data`.
private func boundShell(_ files: [String: String], limits: OutputLimits = roomyLimits) throws -> CommandInterpreter {
    let driver = try InMemoryDriver(texts: files)
    let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "data", driver: driver)])
    return CommandInterpreter(fileSystem: fileSystem, limits: limits)
}

private func text(_ string: String) -> LargeText {
    LargeText(path: "/x", data: Data(string.utf8), encoding: .utf8)
}

@Suite("sort bounds")
struct SortBoundTests {
    @Test("more lines than sort holds are refused")
    func lineCap() async throws {
        let lines = String(repeating: "\n", count: CommandContext.maxSortLines + 1)
        let result = try await boundShell(["a.txt": lines]).run("sort data/a.txt")
        #expect(result.exitCode == 2)
        #expect(result.output.contains("more than \(CommandContext.maxSortLines) lines"))
    }

    @Test("the byte limit counts all inputs together")
    func totalBytes() async throws {
        let line = String(repeating: "x", count: 99) + "\n"
        let half = String(repeating: line, count: CommandContext.maxSortBytes / 100 / 2 + 1_000)
        let result = try await boundShell(["a.txt": half, "b.txt": half]).run("sort data/a.txt data/b.txt")
        #expect(result.exitCode == 2)
        #expect(result.output.contains("bytes together"))
    }

    @Test("a leading minus sign is part of the number")
    func negativeNumbers() async throws {
        let result = try await boundShell(["a.txt": "3\n-10\n2\n"]).run("sort -n data/a.txt")
        #expect(result.output == "-10\n2\n3")
    }
}

@Suite("command time limits")
struct CommandTimeLimitTests {
    @Test("line loops stop at the command's time limit", arguments: [
        "wc -w data/big.txt", "uniq data/big.txt", "cut -c 1 data/big.txt", "sort data/big.txt",
        "head -n 3000 data/big.txt", "tail -n 3000 data/big.txt", "sed -n '4000,4001p' data/big.txt"
    ])
    func timeLimit(line: String) async throws {
        let big = (1...5000).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let limits = OutputLimits(maxLines: 5000, timeLimit: .nanoseconds(1))
        let result = try await boundShell(["big.txt": big], limits: limits).run(line)
        #expect(result.exitCode != 0)
        #expect(result.output.contains("time limit reached"))
    }

    @Test("a cancelled task stops reading lines")
    func cancellation() async throws {
        let lines = text(String(repeating: "a\n", count: 5000))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try lines.lines(from: 1, through: nil, limit: 10_000)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

@Suite("long lines")
struct LongLineTests {
    @Test("a line longer than the decode limit is cut and marked")
    func clippedLine() throws {
        let long = text(String(repeating: "x", count: 3 << 20))
        let firstLines = try long.lines(from: 1, through: 1, limit: 1)
        let first = try #require(firstLines.first)
        #expect(first.utf8.count == LargeText.maxLineBytes + "…".utf8.count)
        #expect(first.hasSuffix("…"))
        let lastLines = try long.lastLines(1)
        let last = try #require(lastLines.first)
        #expect(last.utf8.count == LargeText.maxLineBytes + "…".utf8.count)
    }

    @Test("a cut never splits a character")
    func characterBoundary() throws {
        let long = text(String(repeating: "€", count: LargeText.maxLineBytes))
        let firstLines = try long.lines(from: 1, through: 1, limit: 1)
        let first = try #require(firstLines.first)
        #expect(first.contains("\u{FFFD}") == false)
        #expect(first.utf8.count <= LargeText.maxLineBytes + "…".utf8.count)
    }

    @Test("a block without a newline is cut after the line limit")
    func blockCap() {
        let bytes = Data(repeating: UInt8(ascii: "x"), count: LargeText.blockSize + 2 * LargeText.maxLineBytes)
        let long = LargeText(path: "/x", data: bytes, encoding: .utf8)
        let end = bytes.withUnsafeBytes { raw in
            long.blockEnd(in: raw.bindMemory(to: UInt8.self), from: 0)
        }
        #expect(end == LargeText.blockSize + LargeText.maxLineBytes)
    }

    @Test("wc -w counts the words of a line far longer than the decode limit")
    func wordsOfLongLine() async throws {
        let words = String(repeating: "word ", count: 500_000) + String(repeating: "y", count: 2 << 20) + "\n"
        let result = try await boundShell(["a.txt": words]).run("wc -w data/a.txt")
        #expect(result.output == "500001 data/a.txt")
    }

    @Test("local text files are read up to 1 GB by default")
    func localTextDefault() {
        #expect(VFSLimits().maxLocalTextBytes == 1_000_000_000)
    }
}

@Suite("byte order marks in large text")
struct ByteOrderMarkTests {
    @Test("a literal search does not report the byte order mark")
    func literalHit() throws {
        let marked = text("\u{FEFF}needle here\nneedle two\n")
        let pattern = try PatternCompiler.compile("needle", syntax: .fixed, caseInsensitive: false, wholeWord: false)
        let scanned = marked.scan(pattern, limit: 10, deadline: pattern.deadline)
        #expect(scanned.hits.map(\.text) == ["needle here", "needle two"])
        #expect(scanned.hits.map(\.line) == [1, 2])
    }

    @Test("a file holding only a byte order mark has no lines")
    func onlyMark() throws {
        #expect(try text("\u{FEFF}").lastLines(3).isEmpty)
    }
}
