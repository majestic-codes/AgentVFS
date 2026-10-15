//
//  PipelineTests.swift
//  AgentVFSTests
//
//  Created by Yevhenii Kalashnikov on 14.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation
import Testing
@testable import AgentVFS

/// A shell over a `data` mount with a log, a CSV file and a word list.
private func pipeShell(limits: OutputLimits = roomyLimits) throws -> CommandInterpreter {
    let driver = try InMemoryDriver(texts: [
        "app.log": "INFO start\nERROR disk full\nINFO retry\nERROR disk full\nWARN slow\nERROR timeout\n",
        "users.csv": "id,name,city\n3,Ann,Kyiv\n1,Bob,Lviv\n2,Cid,Kyiv\n10,Dan,Odesa\n",
        "words.txt": "pear\napple\npear\nApple\nfig\n"
    ])
    let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "data", driver: driver)])
    return CommandInterpreter(fileSystem: fileSystem, limits: limits)
}

@Suite("pipelines")
struct PipelineTests {
    @Test("passes each command's output to the next", arguments: [
        ("cat data/app.log | grep ERROR | wc -l", "3"),
        ("grep ERROR data/app.log | sort | uniq -c | sort -rn | head -1", "      2 ERROR disk full"),
        ("cut -d, -f3 data/users.csv | tail -n +2 | sort -u", "Kyiv\nLviv\nOdesa"),
        ("cat data/app.log | sed -n '2,3p'", "ERROR disk full\nINFO retry"),
        ("cat data/app.log | grep -c INFO", "2"),
        ("cat data/app.log | grep -n WARN", "5:WARN slow"),
        ("cat data/app.log | grep -A1 WARN", "WARN slow\nERROR timeout"),
        ("cat data/app.log | rg -i timeout", "ERROR timeout"),
        ("cat data/app.log | grep -l WARN", "(standard input)"),
        ("cat -n data/words.txt | tail -n 1", "     5\tfig")
    ])
    func chains(line: String, expected: String) async throws {
        let result = try await pipeShell().run(line)
        #expect(result.output == expected)
        #expect(result.exitCode == 0)
    }

    @Test("the exit status is the last command's, as in bash")
    func exitStatus() async throws {
        let shell = try pipeShell()
        #expect(await shell.run("cat data/app.log | grep NOTHING").exitCode == 1)
        let missing = await shell.run("cat data/missing.log | wc -l")
        #expect(missing.exitCode == 0)
        #expect(missing.output == "cat: /workspace/data/missing.log: No such file or directory\n0")
    }

    @Test("errors of earlier commands are shown but not passed on")
    func errorsStayOutOfThePipe() async throws {
        let result = try await pipeShell().run("cat data/app.log data/missing.log | wc -l")
        #expect(result.output == "cat: /workspace/data/missing.log: No such file or directory\n6")
    }

    @Test("a command that does not read a pipe cannot follow one")
    func refusesNonReaders() async throws {
        let result = try await pipeShell().run("cat data/app.log | ls")
        #expect(result.exitCode == 2)
        #expect(result.output.hasPrefix("bash: ls does not read from a pipe; after | use one of: cat, cut, grep"))
    }

    @Test("cd inside a pipeline does not change the working directory")
    func changeDirectoryInPipeline() async throws {
        let shell = try pipeShell()
        _ = await shell.run("cd data | wc -l")
        #expect(await shell.currentDirectory == "/workspace")
    }

    @Test("only the last command is held to the output limit")
    func limits() async throws {
        let shell = try pipeShell(limits: OutputLimits(maxBytes: 20, maxPipeBytes: 100))
        #expect(await shell.run("cat data/app.log | wc -l").output == "6")
        let roomy = try pipeShell(limits: OutputLimits(maxPipeBytes: 100))
        let cut = await roomy.run("cat data/app.log data/users.csv | wc -l")
        #expect(cut.output.contains("bash: the output of cat was cut at 100 bytes before the pipe"))
    }
}

@Suite("wc, sort, uniq and cut")
struct TextFilterTests {
    @Test("wc counts lines, words and bytes of files with a total", arguments: [
        ("wc -l data/app.log data/words.txt", " 6 data/app.log\n 5 data/words.txt\n11 total"),
        ("wc data/words.txt", " 5  5 26 data/words.txt"),
        ("cat data/words.txt | wc -w", "5")
    ])
    func wordCount(line: String, expected: String) async throws {
        #expect(try await pipeShell().run(line).output == expected)
    }

    @Test("sort orders lines by text, number, field, case and reversed", arguments: [
        ("sort data/words.txt", "Apple\napple\nfig\npear\npear"),
        ("sort -f -u data/words.txt", "apple\nfig\npear"),
        ("sort -r data/words.txt", "pear\npear\nfig\napple\nApple"),
        ("tail -n +2 data/users.csv | sort -t, -k1,1 -n", "1,Bob,Lviv\n2,Cid,Kyiv\n3,Ann,Kyiv\n10,Dan,Odesa"),
        ("tail -n +2 data/users.csv | sort -t, -k3 | head -2", "2,Cid,Kyiv\n3,Ann,Kyiv")
    ])
    func sorting(line: String, expected: String) async throws {
        #expect(try await pipeShell().run(line).output == expected)
    }

    @Test("uniq collapses adjacent repeats, counts them and filters them", arguments: [
        ("sort data/words.txt | uniq", "Apple\napple\nfig\npear"),
        ("sort data/words.txt | uniq -d", "pear"),
        ("sort data/words.txt | uniq -u", "Apple\napple\nfig"),
        ("sort data/words.txt | uniq -i -c", "      2 Apple\n      1 fig\n      2 pear")
    ])
    func uniqueLines(line: String, expected: String) async throws {
        #expect(try await pipeShell().run(line).output == expected)
    }

    @Test("cut picks fields and characters", arguments: [
        ("cut -d, -f1,3 data/users.csv", "id,city\n3,Kyiv\n1,Lviv\n2,Kyiv\n10,Odesa"),
        ("cut -c 1-3 data/words.txt", "pea\napp\npea\nApp\nfig"),
        ("cut -d, -f2- data/users.csv | head -2", "name,city\nAnn,Kyiv")
    ])
    func cutting(line: String, expected: String) async throws {
        #expect(try await pipeShell().run(line).output == expected)
    }

    @Test("filters without a file or a pipe say what they need", arguments: ["wc -l", "sort", "uniq", "cut -f1"])
    func missingInput(line: String) async throws {
        let result = try await pipeShell().run(line)
        #expect(result.exitCode == 2)
        #expect(result.output.contains("pass a file path or pipe text in"))
    }
}
