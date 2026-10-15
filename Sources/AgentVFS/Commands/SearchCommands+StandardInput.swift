//
//  SearchCommands+StandardInput.swift
//  AgentVFS
//
//  Created by Yevhenii Kalashnikov on 14.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

extension CommandContext {
    /// `grep` or `rg` over the output of the previous command in a pipeline, printed the way grep
    /// prints a single file: matching lines with `-n` numbers and `-A`/`-B`/`-C` context.
    func searchStandardInput(_ request: SearchRequest, input: LargeText) throws -> CommandOutput {
        let pattern = try PatternCompiler.compile(
            request.pattern,
            syntax: request.options.syntax,
            caseInsensitive: request.options.caseInsensitive,
            wholeWord: request.options.wholeWord,
            timeLimit: limits.timeLimit
        )
        let printsLines = request.mode == .lines
        let limit = request.options.maxMatchesPerFile ?? (printsLines ? limits.maxLines + 1 : Int.max)
        let (hits, timedOut) = input.scan(pattern, limit: limit, deadline: pattern.deadline)
        var output = CommandOutput()
        switch request.mode {
        case .count:
            output.line("\(hits.count)")
        case .filesWithMatches:
            if !hits.isEmpty { output.line(Self.standardInputName) }
        case .lines where request.before > 0 || request.after > 0:
            var groups = 0
            let matched = (path: Self.standardInputName, lines: hits.map(\.line))
            try printContext(around: matched, of: input, request: request, into: &output, groups: &groups)
        case .lines:
            for hit in hits {
                let linePrefix = prefix(path: Self.standardInputName, line: hit.line, isMatch: true, request: request)
                output.line(linePrefix + hit.text)
            }
        }
        if timedOut {
            let note = "[\(request.command): stopped at the time limit; the input was not searched to the end]"
            output.error(note, code: 0)
        }
        if hits.isEmpty { output.exitCode = max(output.exitCode, 1) }
        return output
    }
}
