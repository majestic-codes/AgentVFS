# Lint

Swift must pass `swiftlint lint --strict` from the repository root. Read `.swiftlint.yml` first and match it. Changes to lint rules need the user's approval.

# Project knowledge base

AgentVFS is a standalone SwiftPM package with no third-party dependencies. It gives an LLM agent a read-only virtual
filesystem under `/workspace` and shell-like commands over it. `README.md` documents drivers, commands and limits.

- `AgentVFS`: `WorkspaceFileSystem` (mounts under `/workspace`, caches, search), the `MountDriver` protocol,
  `LocalDirectoryDriver`, `InMemoryDriver`, `CommandInterpreter` with the standard commands, and `LargeText` for big files.
- `AgentVFSSQLite` (`sqlite3`), `AgentVFSJQ` (`jq`), `AgentVFSPDF` (`pdfinfo`, `pdfgrep`, `pdftotext`),
  `AgentVFSTools` (`DataTools.all`), `AgentVFSAPI` (`APIQueryCommand`, `APIService`, `APIResults`).
- `vfsh`: a shell over local directories for trying commands by hand.

Security model: the workspace is read-only, and everything the agent types is untrusted input. The agent never sees
credentials: authorization belongs to the client a driver or API command is given. Every command bounds its output,
time and memory.

Tests: `swift test`.

# Code Style

Not caught by SwiftLint — obey anyway.

## `try?` exceptions: Codable kind probing, cleanup in `deinit`

`try?` stays banned everywhere except two shapes. First: probing a Codable container for a value's JSON
kind, where the thrown error carries no cause — it is the container's "no" — and discarding it is
the semantic intent. The probe site must carry a comment naming this exception, and the cascade
must end with a real `throw` so an unmatched value still fails loud.

Second shape: best-effort cleanup in a `deinit`, which cannot throw. The site carries a comment
naming this exception.

## No abbreviations

Identifier = full word. Always. SwiftLint catches <3 chars only.
`ctx`→`context`, `propName`→`propertyName`, `fm`→`fileManager`, `r/g/b/a`→`red/green/blue/alpha`.
Exception: a locked public API that cannot be renamed.

Accepted domain terms, kept as they are:
- `stats` in `APIStats`.
- In `AgentVFSJQ`: `Expr`, `env`/`Env`, `eval`/`evalX`, `lhs`/`rhs`, the usual terms of a jq interpreter.

New code outside these places uses full words.

## Name by type

Name after type/concept. No generic placeholder.
`Ticket` → `ticket` (not `item`), `Session` → `session` (not `data`).

## Long line → variable, not bracket-wrap

Long line from nested call → extract named variable. Not multi-line brackets to save lines.
`normalizeGeneratedWhitespace(try render(...))` too long → `let output = try render(...)` then `normalizeGeneratedWhitespace(output)`.
No nested `try`: not `try String(contentsOf: try #require(url))` — unwrap on its own line first.

## Shorthand optional binding

`if let fontSize` — not `if let f = fontSize`, not `if let fontSize = fontSize`.

## Pattern matching: `case let` outside, switch as expression

Bind once, in front: `case let .token(body, source)` — not `case .token(let body, let source)`.
Same in `guard case let` and `if case let`.

When a switch is the whole body, write it as an expression — no `return` per arm:
```swift
var kind: String {
    switch self {
    case .object: "an object"
    case .array: "an array"
    }
}
```

## Blank line before func after `{`

`{` directly followed by `func` → blank line between.

## Fail loud, validate once

Unknown input (a `$type`, a unit, a modifier) throws — never a skip or a silent default.
Validate at the boundary once; past it no `?`, `?? []` or "cannot happen" branches — carry the
proven value, not the key to look it up again.

## Test-only API lives in TestSupport

A method with no caller in app sources does not live in app sources. Conveniences needed only by
tests belong next to the tests that use them.

## Tests: no force, fail loud

Test suite is Swift Testing (`import Testing`, `@Test func ...`, `#expect`, `#require`). XCTest is gone.

No force-unwrap, no silent `?? default`.
- `x!` → `try #require(x)`
- `x as!` → `try #require(x as? T)`
- `try!` → `try` (test `throws`)

If a lint gate test is added, gate the `Foundation.Process` call to macOS hosts.

## Swift Testing rules

`#expect(!x)` defeats macro expansion — use `#expect(x == false)`.
`#expect(throws: (any Error).self)` accepts anything — use the specific type (e.g. `VFSError.self`).
Loop with N independent `#expect` rows → `@Test(arguments: [...])` so each row failure is isolated. Skip parametrize when iterations accumulate into one assertion.
Tags live once per test target in `Tests/<target>/TestSupport/Tags.swift`. Cross-target same-named tags are distinct values — that is by design (Swift module isolation), not duplication.

## No NS*

Foundation NS-prefixed types are forbidden. Exceptions (forced by Apple SDK / Foundation):
- `NSAttributedString` family (`.Key`, `NSMutableParagraphStyle`, `NSParagraphStyle`) — UIKit/AppKit interop.
- `NSNumber` — `JSONSerialization` deserialization. The cast covers int+double in one path; document at the site.
- `NSRegularExpression` with `NSString`/`NSRange`/`NSTextCheckingResult` — the regex engine behind `grep`, `rg` and
  `jq`. Its matching callback is the only way to stop a backtracking pattern at the time limit, which Swift `Regex`
  cannot do. Name this exception at each site.

Use Swift native: `Regex` not `NSRegularExpression`, `Date` not `NSDate`, `URLRequest` not `NSURLRequest`.

## Comments

Don't comment by default — write code that reads without one (names, small functions, one idea
per line). Comment only where the code alone cannot explain itself: a non-obvious rule the code
implements, a value's meaning, a sanctioned exception (`try?` probe, `swiftlint:disable`).

A comment says what the code does or means. Never: why an alternative was rejected, what the
spec or corpus does elsewhere, which phase or caller will use it, or that a branch is
"unreachable". One or two sentences, no semicolons — start a new sentence instead. If the code
needs an essay, simplify the code.
