//
//  StandardCommands.swift
//  AgentVFS
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

/// The built-in read-only commands, in `help` order.
public enum StandardCommands {
    /// `ls`: lists directories.
    public static let list = Command(
        "ls",
        usage: "ls [-l] [PATH...]                  list directories ('/' marks directories, '@' symbolic links)"
    ) { arguments, context in try await context.list(arguments) }

    /// `cat`: prints files, optionally with line numbers.
    public static let cat = Command(
        "cat",
        usage: "cat [-n] FILE...                   print files",
        readsStandardInput: true
    ) { arguments, context in try await context.concatenate(arguments) }

    /// `head`: prints the first lines of files. Its usage line also covers `tail`.
    public static let head = Command(
        "head",
        usage: "head|tail [-n N] FILE...           first or last N lines (tail -n +N starts at line N)",
        readsStandardInput: true
    ) { arguments, context in try await context.headOrTail(arguments, command: "head") }

    /// `tail`: prints the last lines of files, or from a line on with `-n +N`. Its usage is listed under `head`.
    public static let tail = Command("tail", usage: "", readsStandardInput: true) { arguments, context in
        try await context.headOrTail(arguments, command: "tail")
    }

    /// `sed`: prints a line range. Only `-n 'START,ENDp'` is supported.
    public static let sed = Command(
        "sed",
        usage: "sed -n 'START,ENDp' FILE           print a line range ('$' means the last line)",
        readsStandardInput: true
    ) { arguments, context in try await context.streamEdit(arguments) }

    /// `find`: walks directories and prints the paths that match name, type and depth filters.
    public static let find = Command(
        "find",
        usage: "find [PATH...] [-name GLOB] [-iname GLOB] [-type f|d|l] [-maxdepth N] [-mindepth N]"
    ) { arguments, context in try await context.find(arguments) }

    /// `grep`: searches file contents with a regular expression or a fixed string.
    public static let grep = Command(
        "grep",
        usage: "grep [-rniEFwlc] [-m N] [-A|-B|-C N] [-e PATTERN] "
            + "[--include=GLOB] [--exclude=GLOB] [--exclude-dir=DIR] PATTERN [PATH...]",
        readsStandardInput: true
    ) { arguments, context in try await context.grep(arguments) }

    /// `rg`: searches file contents recursively, ripgrep style, or lists files with `--files`.
    public static let ripgrep = Command(
        "rg",
        usage: "rg [-iFwlcS] [-g GLOB] [-t TYPE] [-m N] [-A|-B|-C N] [--files] PATTERN [PATH...]",
        readsStandardInput: true
    ) { arguments, context in try await context.ripgrep(arguments) }

    /// `wc`: counts lines, words, characters and bytes.
    public static let wordCount = Command(
        "wc",
        usage: "wc [-lwmc] [FILE...]               count lines, words, characters, bytes",
        readsStandardInput: true
    ) { arguments, context in try await context.wordCount(arguments) }

    /// `sort`: sorts lines, by a field, as numbers, reversed or unique.
    public static let sort = Command(
        "sort",
        usage: "sort [-rnuf] [-k N[,M]] [-t SEP] [FILE...]   sort lines (-n numbers, -k field)",
        readsStandardInput: true
    ) { arguments, context in try await context.sortLines(arguments) }

    /// `uniq`: collapses repeated adjacent lines, optionally counting them.
    public static let uniq = Command(
        "uniq",
        usage: "uniq [-cdui] [FILE]                collapse repeated adjacent lines (-c counts them)",
        readsStandardInput: true
    ) { arguments, context in try await context.unique(arguments) }

    /// `cut`: prints selected fields or characters of each line.
    public static let cut = Command(
        "cut",
        usage: "cut -d SEP -f LIST | -c LIST [FILE...]   fields or characters (LIST like 1,3-5,7-)",
        readsStandardInput: true
    ) { arguments, context in try await context.cut(arguments) }

    /// `cd`: changes the working directory. Its usage line also covers `pwd`.
    public static let changeDirectory = Command(
        "cd",
        usage: "pwd, cd [PATH]                     show or change the working directory"
    ) { arguments, context in try await context.changeDirectory(arguments) }

    /// `pwd`: prints the working directory. Its usage is listed under `cd`.
    public static let pwd = Command("pwd", usage: "") { _, context in
        CommandOutput(text: context.workingDirectory.description + "\n", exitCode: 0)
    }

    /// Every standard command, in `help` order.
    public static let all: [any WorkspaceCommand] = [
        list, cat, head, tail, sed, find, grep, ripgrep, wordCount, sort, uniq, cut, changeDirectory, pwd
    ]
}
