//
//  VFSShell.swift
//  vfsh
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import AgentVFSTools
import Foundation

/// `vfsh`: the workspace shell over local directories.
///
///     vfsh [--mount NAME=PATH]... [PATH]... [-c COMMAND]
///
/// Every PATH is mounted under `/workspace/<its folder name>`. Without `-c` commands are read
/// from standard input, one per line.
@main
struct VFSShell {
    /// The commands the shell offers.
    static let commands: [any WorkspaceCommand] = DataTools.all

    static var usage: String {
        let standardNames = StandardCommands.all.map(\.name)
        let extraNames = commands.map(\.name)
        let names = Set(standardNames + extraNames + ["help"]).sorted().joined(separator: ", ")
        return """
        usage: vfsh [--mount NAME=PATH]... [PATH]... [-c COMMAND]

        Mounts local directories read-only under /workspace and runs the agent's commands on them:
        \(names).
        Without -c, reads one command per line.
        """
    }

    static func main() async {
        do {
            let (mounts, command) = try parse(Array(CommandLine.arguments.dropFirst()))
            let fileSystem = try WorkspaceFileSystem(mounts: mounts)
            let interpreter = CommandInterpreter(fileSystem: fileSystem, commands: commands)
            if let command {
                let commandResult = await interpreter.run(command)
                emit(commandResult.output)
                exit(Int32(clamping: commandResult.exitCode))
            }
            let interactive = isatty(STDIN_FILENO) == 1
            while true {
                if interactive {
                    let directory = await interpreter.currentDirectory
                    FileHandle.standardOutput.write(Data(TerminalText.escaped("\(directory)$ ").utf8))
                }
                guard let line = readLine() else { break }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "exit" || trimmed == "quit" { break }
                if trimmed.isEmpty { continue }
                let commandResult = await interpreter.run(trimmed)
                emit(commandResult.output)
            }
        } catch {
            let message = TerminalText.escaped("vfsh: \(error.localizedDescription)")
            FileHandle.standardError.write(Data("\(message)\n\n\(usage)\n".utf8))
            exit(2)
        }
    }

    /// Writes command output as one block ending in a newline, with control characters escaped.
    /// Empty output writes nothing.
    private static func emit(_ output: String) {
        guard !output.isEmpty else { return }
        FileHandle.standardOutput.write(Data((TerminalText.escaped(output) + "\n").utf8))
    }

    static func parse(_ arguments: [String]) throws -> ([WorkspaceMount], String?) {
        var mounts: [WorkspaceMount] = []
        var command: String?
        var index = 0
        func next(_ option: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw VFSError.invalidConfiguration("\(option) needs a value") }
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help":
                FileHandle.standardOutput.write(Data((usage + "\n").utf8))
                exit(0)
            case "-c":
                command = try next(argument)
            case "--mount", "-m":
                let mountArgument = try next(argument)
                guard let equals = mountArgument.firstIndex(of: "=") else {
                    throw VFSError.invalidConfiguration("--mount expects NAME=PATH")
                }
                let name = String(mountArgument[..<equals])
                let path = String(mountArgument[mountArgument.index(after: equals)...])
                let driver = try LocalDirectoryDriver(path: path)
                mounts.append(WorkspaceMount(name: name, driver: driver))
            default:
                let driver = try LocalDirectoryDriver(path: argument)
                mounts.append(WorkspaceMount(name: driver.root.lastPathComponent, driver: driver))
            }
            index += 1
        }
        if mounts.isEmpty {
            let driver = try LocalDirectoryDriver(path: FileManager.default.currentDirectoryPath)
            mounts.append(WorkspaceMount(name: driver.root.lastPathComponent, driver: driver))
        }
        return (mounts, command)
    }
}
