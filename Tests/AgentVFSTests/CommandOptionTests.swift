//
//  CommandOptionTests.swift
//  AgentVFSTests
//
//  Created by Yevhenii Kalashnikov on 15.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation
import Testing
@testable import AgentVFS

/// A shell over a `data` mount with two small files.
private func optionShell() throws -> CommandInterpreter {
    let driver = try InMemoryDriver(texts: ["a.txt": "needle\nhay\n", "b.txt": "needle\nneedle\n"])
    let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "data", driver: driver)])
    return CommandInterpreter(fileSystem: fileSystem)
}

@Suite("search output options")
struct SearchOutputOptionTests {
    @Test("options that change what is printed take effect", arguments: [
        ("rg -N needle data/a.txt", "/workspace/data/a.txt:needle"),
        ("rg --no-line-number needle data/a.txt", "/workspace/data/a.txt:needle"),
        ("rg -I needle data/a.txt", "1:needle"),
        ("grep -c -h needle data/a.txt data/b.txt", "1\n2\n[files without matches are not listed]"),
        ("grep -s needle data/missing.txt data/a.txt", "/workspace/data/a.txt:needle"),
        ("grep -I needle data/a.txt", "needle"),
        ("grep -G 'need.e' data/a.txt", "needle"),
        ("rg -u --hidden --no-ignore --color=never needle data/a.txt", "/workspace/data/a.txt:1:needle")
    ])
    func printed(line: String, expected: String) async throws {
        #expect(try await optionShell().run(line).output == expected)
    }

    @Test("grep -s still reports the failure in its exit status")
    func silentStatus() async throws {
        #expect(try await optionShell().run("grep -s needle data/missing.txt").exitCode == 2)
    }

    @Test("options that cannot be honoured, or contradict each other, are refused", arguments: [
        "grep -E -F needle data/a.txt",
        "grep -G -E needle data/a.txt",
        "grep -C 51 needle data/a.txt",
        "rg -a needle data",
        "rg --heading needle data",
        "rg --color=always needle data",
        "rg -n -N needle data",
        "sed -n -e 1p -e 2p data/a.txt",
        "find data -name a.txt -name b.txt",
        "find data -name a.txt -iname b.txt",
        "find data -type f -type d",
        "sort -t , -t : data/a.txt",
        "cut -f 1 -f 2 data/a.txt",
        "cut -d , -d : -f 1 data/a.txt",
        "cut -c 1 -c 2 data/a.txt"
    ])
    func refused(line: String) async throws {
        let result = try await optionShell().run(line)
        #expect(result.exitCode == 2, "output was: \(result.output)")
    }
}

@Suite("interpreter checks")
struct InterpreterCheckTests {
    @Test("command names are letters, digits, '.', '_' and '-', and never help", arguments: [
        ("sqlite3", true), ("pdf-text", true), ("help", false), ("", false), ("a b", false), ("rm;", false)
    ])
    func names(name: String, isValid: Bool) {
        #expect(CommandInterpreter.isValid(name: name) == isValid)
    }

    @Test("help is listed once")
    func helpOnce() async throws {
        let shell = try optionShell()
        let names = await shell.commandNames
        #expect(names.filter { $0 == "help" }.count == 1)
    }

    @Test("a command cannot move the working directory to a file or a missing path", arguments: [
        "/workspace/data/a.txt", "/workspace/data/missing"
    ])
    func workingDirectory(target: String) async throws {
        let jump = Command("jump", usage: "") { _, context in
            var output = CommandOutput()
            output.newWorkingDirectory = try context.resolvePath(target)
            return output
        }
        let driver = try InMemoryDriver(texts: ["a.txt": "x"])
        let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "data", driver: driver)])
        let shell = CommandInterpreter(fileSystem: fileSystem, commands: [jump])
        let result = await shell.run("jump")
        #expect(result.exitCode == 2)
        #expect(await shell.currentDirectory == "/workspace")
    }
}

@Suite("shell syntax the tokenizer refuses")
struct TokenizerRefusalTests {
    @Test("line breaks are refused anywhere, quoted or escaped", arguments: [
        "cat 'a\nb'", "cat \"a\nb\"", "cat a\\\nb", "cat 'a\rb'"
    ])
    func lineBreaks(line: String) {
        #expect(throws: CommandError.unsupported("multi-line input is not supported; send one command per call")) {
            try ShellTokenizer.pipeline(line)
        }
    }

    @Test("brace expansion and a leading ~ are refused", arguments: ["ls {a,b}", "ls a}", "cat ~/x", "cat ~"])
    func expansions(line: String) {
        #expect(throws: CommandError.self) { try ShellTokenizer.pipeline(line) }
    }

    @Test("quoted braces, ~ inside a word and ! are literal")
    func literals() throws {
        let words = try ShellTokenizer.pipeline("grep '{a,b}' a~b !x").first?.map(\.text)
        #expect(words == ["grep", "{a,b}", "a~b", "!x"])
    }
}

@Suite("terminal text")
struct TerminalTextTests {
    @Test("control characters other than tab and newline are escaped")
    func escaped() {
        let raw = "a\u{1B}[31mb\tc\n\u{9B}d\re\u{7F}"
        #expect(TerminalText.escaped(raw) == "a\\u{1B}[31mb\tc\n\\u{9B}d\\u{D}e\\u{7F}")
    }
}
