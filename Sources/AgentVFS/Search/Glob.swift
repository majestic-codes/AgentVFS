//
//  Glob.swift
//  AgentVFS
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

/// A shell-style glob matched against a whole string.
///
/// Supports `*`, `?`, `[...]`, `[!...]`, `{a,b}` and `**`. Every other character is literal.
/// Matching runs all alternatives side by side, so its time grows with the text times the
/// pattern and never explodes on patterns such as `*a*a*a*b`.
public struct Glob: Sendable {
    /// Longer patterns are refused.
    static let maxPatternLength = 1000
    /// Deeper `{...}` nesting is refused.
    static let maxBraceDepth = 10

    private let states: [GlobState]
    /// For each state, the consuming states and the accept state it reaches without consuming.
    private let closures: [[Int]]
    private let start: Int
    private let caseInsensitive: Bool

    /// Compiles `pattern`. Throws `VFSError.invalidPattern` for an overlong or malformed one.
    public init(_ pattern: String, caseInsensitive: Bool = false) throws {
        guard pattern.count <= Self.maxPatternLength else {
            throw VFSError.invalidPattern("glob is longer than \(Self.maxPatternLength) characters")
        }
        var parser = GlobParser(characters: Array(pattern))
        let tokens = try parser.parseSequence(depth: 0)
        var builder = GlobBuilder()
        let accept = builder.add(.accept)
        start = builder.build(tokens, then: accept)
        states = builder.states
        closures = states.indices.map { [states] index in Self.closure(of: index, in: states) }
        self.caseInsensitive = caseInsensitive
    }

    /// Whether the glob matches the whole of `text`.
    public func matches(_ text: String) -> Bool {
        var current = closures[start]
        var isCurrent = [Bool](repeating: false, count: states.count)
        for character in text {
            var next: [Int] = []
            for index in current {
                guard case let .consume(matcher, target) = states[index],
                      matcher.accepts(character, caseInsensitive: caseInsensitive)
                else { continue }
                for reached in closures[target] where !isCurrent[reached] {
                    isCurrent[reached] = true
                    next.append(reached)
                }
            }
            for index in next { isCurrent[index] = false }
            current = next
            if current.isEmpty { return false }
        }
        return current.contains { if case .accept = states[$0] { true } else { false } }
    }

    /// The states reachable from `index` without consuming a character, without the splits.
    private static func closure(of index: Int, in states: [GlobState]) -> [Int] {
        var seen = Set<Int>()
        var pending = [index]
        var reachable: [Int] = []
        while let next = pending.popLast() {
            guard seen.insert(next).inserted else { continue }
            if case let .split(targets) = states[next] {
                pending += targets
            } else {
                reachable.append(next)
            }
        }
        return reachable
    }
}

/// One element of a parsed glob.
private enum GlobToken {
    case character(Character)
    /// `?`
    case anyCharacter
    case set(GlobCharacterSet)
    /// `*`, within one path component.
    case star
    /// `**` not followed by `/`, across components.
    case anyPath
    /// `**/`: any number of whole directories, none included.
    case anyDirectories
    /// `{a,b}`
    case alternatives([[Self]])
}

/// What one consuming step of a glob accepts.
private enum GlobMatcher: Sendable {
    case character(Character)
    case anyExceptSlash
    case anyCharacter
    case set(GlobCharacterSet)

    func accepts(_ candidate: Character, caseInsensitive: Bool) -> Bool {
        switch self {
        case let .character(expected):
            candidate == expected || caseInsensitive && candidate.lowercased() == expected.lowercased()
        case .anyExceptSlash: candidate != "/"
        case .anyCharacter: true
        case let .set(set): set.contains(candidate, caseInsensitive: caseInsensitive)
        }
    }
}

/// `[...]`: single characters and ranges such as `a-z`, possibly negated.
private struct GlobCharacterSet: Sendable {
    var ranges: [ClosedRange<Character>] = []
    var negated = false

    func contains(_ candidate: Character, caseInsensitive: Bool) -> Bool {
        guard candidate != "/" else { return false }
        var variants = [candidate]
        if caseInsensitive {
            // A case mapping can be longer than one character, such as ß to SS. Such a mapping is no variant.
            let mapped = [candidate.lowercased(), candidate.uppercased()].filter { $0.count == 1 }
            variants += mapped.compactMap(\.first)
        }
        let found = variants.contains { variant in ranges.contains { $0.contains(variant) } }
        return found != negated
    }
}

private enum GlobState: Sendable {
    case consume(GlobMatcher, next: Int)
    case split([Int])
    case accept
}

private struct GlobParser {
    let characters: [Character]
    var index = 0

    /// Tokens up to the end, or up to a `,` or `}` that closes the brace group at `depth`.
    mutating func parseSequence(depth: Int) throws -> [GlobToken] {
        var tokens: [GlobToken] = []
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "*":
                tokens.append(parseStars())
            case "?":
                tokens.append(.anyCharacter)
                index += 1
            case "[":
                let set = try parseSet()
                tokens.append(.set(set))
            case "{":
                guard depth < Glob.maxBraceDepth else {
                    throw VFSError.invalidPattern("glob nests '{' deeper than \(Glob.maxBraceDepth) levels")
                }
                let alternatives = try parseAlternatives(depth: depth + 1)
                tokens.append(.alternatives(alternatives))
            case "}", ",":
                if depth > 0 { return tokens }
                tokens.append(.character(character))
                index += 1
            case "\\":
                index += 1
                if index < characters.count {
                    tokens.append(.character(characters[index]))
                    index += 1
                } else {
                    tokens.append(.character("\\"))
                }
            default:
                tokens.append(.character(character))
                index += 1
            }
        }
        if depth > 0 {
            throw VFSError.invalidPattern("glob has an unterminated '{'")
        }
        return tokens
    }

    private mutating func parseStars() -> GlobToken {
        var count = 0
        while index < characters.count, characters[index] == "*" {
            count += 1
            index += 1
        }
        guard count >= 2 else { return .star }
        guard index < characters.count, characters[index] == "/" else { return .anyPath }
        index += 1
        return .anyDirectories
    }

    private mutating func parseAlternatives(depth: Int) throws -> [[GlobToken]] {
        index += 1
        var alternatives: [[GlobToken]] = []
        while index < characters.count {
            let alternative = try parseSequence(depth: depth)
            alternatives.append(alternative)
            guard index < characters.count else { break }
            let separator = characters[index]
            index += 1
            if separator == "}" { return alternatives }
        }
        throw VFSError.invalidPattern("glob has an unterminated '{'")
    }

    private mutating func parseSet() throws -> GlobCharacterSet {
        var cursor = index + 1
        var set = GlobCharacterSet()
        if cursor < characters.count, characters[cursor] == "!" || characters[cursor] == "^" {
            set.negated = true
            cursor += 1
        }
        var first = true
        while cursor < characters.count {
            let character = characters[cursor]
            if character == "]", !first {
                index = cursor + 1
                return set
            }
            first = false
            let hasUpperBound = cursor + 2 < characters.count && characters[cursor + 2] != "]"
            let isRange = hasUpperBound && characters[cursor + 1] == "-"
            if isRange {
                let upper = characters[cursor + 2]
                guard character <= upper else {
                    throw VFSError.invalidPattern("glob range '\(character)-\(upper)' is reversed")
                }
                set.ranges.append(character...upper)
                cursor += 3
            } else {
                set.ranges.append(character...character)
                cursor += 1
            }
        }
        throw VFSError.invalidPattern("glob has an unterminated '['")
    }
}

/// Builds the states of a glob back to front, each token pointing at what follows it.
private struct GlobBuilder {
    private(set) var states: [GlobState] = []

    mutating func add(_ state: GlobState) -> Int {
        states.append(state)
        return states.count - 1
    }

    mutating func build(_ tokens: [GlobToken], then next: Int) -> Int {
        tokens.reversed().reduce(next) { following, token in build(token, then: following) }
    }

    private mutating func build(_ token: GlobToken, then next: Int) -> Int {
        switch token {
        case let .character(character): add(.consume(.character(character), next: next))
        case .anyCharacter: add(.consume(.anyExceptSlash, next: next))
        case let .set(set): add(.consume(.set(set), next: next))
        case .star: repeating(.anyExceptSlash, then: next)
        case .anyPath: repeating(.anyCharacter, then: next)
        case .anyDirectories:
            add(.split([repeating(.anyCharacter, then: add(.consume(.character("/"), next: next))), next]))
        case let .alternatives(alternatives):
            add(.split(alternatives.map { build($0, then: next) }))
        }
    }

    /// Any number of characters `matcher` accepts, then `next`.
    private mutating func repeating(_ matcher: GlobMatcher, then next: Int) -> Int {
        let loop = add(.split([]))
        let step = add(.consume(matcher, next: loop))
        states[loop] = .split([step, next])
        return loop
    }
}

/// A set of globs applied to file names or mount paths.
public struct GlobSet: Sendable {
    private let entries: [(glob: Glob, matchesPath: Bool)]

    /// Compiles every pattern. Throws `VFSError.invalidPattern` for one that does not compile.
    public init(_ patterns: [String]) throws {
        entries = try patterns.map { pattern in
            let glob = try Glob(pattern)
            return (glob, pattern.contains("/"))
        }
    }

    /// Whether the set has no patterns.
    public var isEmpty: Bool { entries.isEmpty }

    /// Patterns containing `/` match the mount-relative path. Others match the file name.
    public func matches(name: String, mountPath: String) -> Bool {
        entries.contains { $0.matchesPath ? $0.glob.matches(mountPath) : $0.glob.matches(name) }
    }
}
