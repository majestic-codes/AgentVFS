# AgentVFS

An emulated file environment for an AI agent. Any source (a local folder, a remote repository, any API) appears as a
folder under `/workspace`, and the agent works with it through a small set of Unix commands: `ls cat head tail sed
find grep rg wc sort uniq cut pwd cd`.
Everything is read-only. There is no real shell, nothing is executed, and nothing outside `/workspace` is reachable.

The package depends on no particular source and no particular agent. Drivers for other systems and the adapter to
an agent are built on top of it.

```text
CommandInterpreter     ls cat head tail sed find grep rg wc sort uniq cut pwd cd + your commands
        │
WorkspaceFileSystem    /workspace, paths, listing and content caches, find, search, limits
        │
   MountDriver         LocalDirectoryDriver · InMemoryDriver · your driver
```

## Installation

Swift 6.0 or later, macOS 15+ or iOS 18+. The package runs on Apple platforms only: the local driver, `sqlite3` and
the PDF commands rely on Darwin, the system SQLite, PDFKit and Vision.

```swift
.package(url: "https://github.com/majestic-codes/AgentVFS.git", from: "0.1.0"),
```

Each module is added on its own: `AgentVFS` (the core), `AgentVFSSQLite`, `AgentVFSJQ`, `AgentVFSPDF`, `AgentVFSAPI`
and `AgentVFSTools` (all data tools together).

## Quick start

```swift
import AgentVFS

let fileSystem = try WorkspaceFileSystem(mounts: [
    WorkspaceMount(name: "app", driver: try LocalDirectoryDriver(path: "~/Projects/app")),
    WorkspaceMount(name: "notes", driver: try InMemoryDriver(texts: ["todo.md": "- ship it\n"])),
])
let shell = CommandInterpreter(fileSystem: fileSystem)
print(await shell.run("grep -rn 'TODO' /workspace/app").output)
```

The same from a terminal:

```bash
swift run vfsh ~/Projects/app                      # interactive, one command per line
swift run vfsh -m app=~/Projects/app -c "find /workspace -name '*.swift'"
```

## Your own driver

A driver answers only three questions: what is in a folder, what is in a file, and how to describe the source.
Everything else (paths, caching, `find`, `grep`, output limits, commands) is done by `WorkspaceFileSystem`, the same
way for every driver.

```swift
struct JiraDriver: MountDriver {
    let client: JiraClient          // your API client, with its authorization

    var info: MountInfo {
        MountInfo(kind: "Jira", source: "acme.atlassian.net",
                  summary: "Jira, project PROJ, live data",
                  linkTemplate: "https://acme.atlassian.net/browse/<path>")
    }

    // "" → the list of projects, "PROJ" → its issues as files
    func list(_ directory: EntryRef) async throws -> [DriverEntry] {
        if directory.path.isEmpty {
            return try await client.projects().map { DriverEntry(name: $0.key, kind: .directory) }
        }
        return try await client.issues(project: directory.path).map {
            // The id changes with the content, so the cache refreshes by itself
            DriverEntry(name: "\($0.key).md", kind: .file, id: "\($0.key)@\($0.updated)")
        }
    }

    func read(_ file: EntryRef) async throws -> FileContent {
        let issue = try await client.issue(key: String(file.name.dropLast(3)))
        return .text(Data(issue.renderedAsMarkdown().utf8))
    }
}
```

An agent works best with text, so serve API records as readable files (Markdown, formatted JSON) rather than raw
responses full of service fields.

Optional methods (each has a default implementation):

| Method | Purpose |
|---|---|
| `listAll()` | Return the whole tree in one request when the source can (for example, a repository's recursive tree) |
| `read(_ files:)` | Read many files in one batch (by default, one at a time in parallel) |
| `readExactBytes(_:)` | Exact bytes, when `read` returned `.transcodedText` or `.truncated` |
| `searchCandidates(for:)` | Server-side search: narrows `grep`/`rg` to the files the source's index found |
| `link(to:line:)` | A link for citations |
| `listingIsCheap` | `true` when listing a folder costs nothing (disk, memory), so a walk needs no request budget |

Rules worth keeping:

- **Errors.** A missing path throws `VFSError.notFound`, and the message shows the virtual path. Use `.unauthorized`
  for authorization and `.rateLimited` for rate limits: a search then returns what it found so far, marked incomplete.
- **Caching.** Content is cached by `DriverEntry.id` (a SHA, an ETag, a revision), or by path for the rest of the
  session when there is no `id`. Folder listings are cached for the lifetime of the `WorkspaceFileSystem`, so for live
  data create a new workspace for each conversation.
- **Authorization** belongs to the driver: give it a ready client or a token provider. The core knows nothing about
  tokens.
- **Request statistics.** If your client counts traffic, implement `RequestStatsSource` and pass it to
  `WorkspaceFileSystem(mounts:limits:statistics:)`. It shows up in `metrics().requests`.

## Large files and encodings

- **Text of any size from local sources** (`LocalDirectoryDriver`, `InMemoryDriver`). `head`, `tail`, `sed -n`,
  `grep`, `rg` and `grep -C` read line by line from a memory-mapped file (`WorkspaceFileSystem.largeText`). The
  `VFSLimits.maxLocalTextBytes` limit is 1 GB by default. A line longer than `LargeText.maxLineBytes` (1 MB) is cut, so
  a file without line breaks is never decoded whole. On a 1.2 GB log in a release build, a literal search took about
  2 s, `grep -i` about 2 s, and a regular expression without a literal (`ERROR|WARN`) about 6 s, with a peak process
  footprint of up to 6 MB.
- **`cat` and `read`** return the whole file, so they keep the `maxReadBytes` limit (2 MB) and suggest that the agent
  read in parts.
- **Remote sources** (network drivers, APIs) keep the `maxReadBytes` and `maxSearchFileBytes` limits, because every
  file has to be downloaded.
- **`jq`** reads up to 50 MB of JSON per run, counting all files and `--slurpfile`/`--rawfile` (20 MB on iOS,
  `JQCommand(maxFileBytes:)`), because it parses files into a tree in memory. Larger data belongs in SQLite.
- **Encodings.** UTF-8, UTF-16 and UTF-32 with a BOM, UTF-16 without a BOM (ASCII text), Windows-1251 (accounting
  exports, bank statements) and Windows-1252/Latin-1 are converted to UTF-8 automatically (`FileContent.classify`).

## Changing files at run time

Mounts and files can change while the workspace is in use:

```swift
let uploads = InMemoryDriver()
try await fileSystem.addMount(WorkspaceMount(name: "uploads", driver: uploads))
try uploads.put("report.json", data: data)        // visible at once as /workspace/uploads/report.json
try uploads.remove("report.json")
try await fileSystem.removeMount(named: "uploads")
try await fileSystem.refresh(mountNamed: "app")   // the local folder changed outside the program
```

Mount caches reset by themselves: `InMemoryDriver` reports changes through `MountDriver.revision`, and `addMount` and
`removeMount` clear what they own. Your own driver with changing data can report a `revision` too. For sources that
cannot report changes (a local folder, an API), call `refresh`.

How the agent learns about changes is up to the host, for example with a note before the next question:
`[The workspace changed since your last turn] - added /workspace/uploads: …`.

## Ready-made data tools

Separate modules of the package, added as ordinary commands:

```swift
import AgentVFS
import AgentVFSSQLite
import AgentVFSJQ

let shell = CommandInterpreter(fileSystem: fileSystem, commands: [SQLiteCommand(), JQCommand()])
```

- **`sqlite3`** (`AgentVFSSQLite`) works with an SQLite database from any driver: a local folder, a remote
  repository, your API.
  ```text
  sqlite3 data/app.db                                      # tables
  sqlite3 data/app.db '.schema users'
  sqlite3 -header -csv data/app.db 'SELECT id, email FROM users LIMIT 10'
  ```
  Output modes: `-list` (the default), `-csv`, `-json`, `-line`, `-column`, `-tabs`, plus the `-header` and
  `-nullvalue` options.
  - **A local database** (`LocalDirectoryDriver`) is opened in place, read-only. SQLite reads only the pages it needs,
    so multi-gigabyte databases work: on a 1.9 GB database the process used up to 13 MB of memory. SQLite gets the
    descriptor the driver already checked (`/dev/fd/N`), not a path, so swapping the file for a link achieves
    nothing. Because of this, changes still held only in the `-wal` file are not visible until a checkpoint.
  - **A database from another source** (a network driver, an API, memory) is downloaded once to a temporary file on
    disk through `MountDriver.download(_:to:)` and opened from there. The download limit `maxDownloadBytes` is 1 GB
    (200 MB on iOS), and `downloadCacheBytes` (2 GB) caps the space for copies. The default `download` holds the file
    in memory once. A driver for large files overrides it and writes a stream (for example,
    `URLSession.download(for:)`).
  - **Safety.** The authorizer allows reading only: any write (including to temp), `CREATE TEMP`, `ATTACH`,
    `VACUUM INTO`, transactions and pragmas with a value are denied, and the pragmas that read the schema remain.
    Extensions are not loaded, and symbolic links are not opened (`SQLITE_OPEN_NOFOLLOW`). Sorting spills to disk, but
    temporary files are capped (`maxTemporaryBytes`, 256 MB, 64 MB on iOS). A result row is capped at 32 MB, and a
    cell is read only as far as the output limit. Each query has a time limit (`timeout`, 30 s, but no longer than
    `OutputLimits.timeLimit`), runs outside the Swift concurrency pool and stops when its task is cancelled.
  - So that a tool can open a file in place, a driver implements `MountDriver.openLocalFile(for:)` and returns an
    opened, checked `LocalFile`.
- **`jq`** (`AgentVFSJQ`): the jq 1.7 language in pure Swift, which works on iOS too.
  ```text
  jq -r '.items[] | select(.done) | .title' data/todo.json
  jq -c --arg id 42 '.users[] | select(.id == ($id | tonumber))' data/users.json
  ```
  It supports the full grammar (`def`, `reduce`, `foreach`, `try`, `label`, assignment, `path`), about 200 builtins
  (regular expressions, dates, `@csv`/`@tsv`/`@base64`, `tostream`) and the options `-r -j -c -n -s -R -e -S --tab
  --arg --argjson --slurpfile --rawfile --args`. Without a file it reads JSON from a pipe (`cat a.json | jq .x`), and
  with `-n` it reads nothing. `$ENV` is always empty. Endless generators, recursion or nesting that is too deep (over
  10,000 levels) and backtracking regular expressions stop with an error instead of hanging. A run is limited by time
  (`JQ.Options.timeout`, 30 s, no longer than `OutputLimits.timeLimit`), by step count and by memory growth
  (`maxMemoryGrowth`, 1 GB, 512 MB on iOS). Large arrays, sorting and JSON parsing reserve their memory first, so a
  request is refused before the memory is spent. The engine can also be called without the command:
  `JQ.evaluate(_:input:options:)`. Errors have public types: `JQCompileError` (syntax), `JQError` (a runtime error),
  `JQAbort` (a limit) and `JQHalt` (`halt`).

- **`pdfinfo`, `pdfgrep`, `pdftotext`** (`AgentVFSPDF`): PDF through the system PDFKit and Vision, with no
  dependencies. The commands are built for large documents and few tokens: first the map, then search, then only the
  pages needed.
  ```text
  pdfinfo docs/report.pdf                        # pages, metadata, text size in tokens, outline with pages
  pdfgrep -i 'invoice|receipt' docs/report.pdf   # matches with page numbers
  pdfgrep -r -l 4711 docs                        # which PDFs in a folder mention 4711
  pdftotext -f 12 -l 14 docs/report.pdf          # the text of pages 12–14
  pdftotext --ocr -f 45 -l 45 docs/scan.pdf      # a scanned page without a text layer
  ```
  - **`pdfgrep`** shows at most 40 matches and only counts the rest, listing their pages. Long lines are cut around the
    match. Options: `-i -F -G -w -c -l -H -h -r -m N -A/-B/-C N --page-range=A-B`, with extended patterns as in pdfgrep.
  - **`pdftotext`** stops output at a page boundary and says which page to continue from. Without a range, a long
    document shows its first two pages and hints instead of spending the whole limit on the beginning. Whitespace is
    collapsed.
  - **Scans.** `pdfinfo` and `pdfgrep` name the pages without a text layer, and `pdftotext --ocr` recognizes them
    through Vision (up to 10 pages per command, `PDFOptions.maxRecognizedPages`). Recognized text is cached, so
    `pdfgrep` then searches it too.
  - Files come through a `DownloadCache`, as in `sqlite3`, but a separate one (`PDFOptions.downloadCacheBytes`,
    1 GB): local files are read from disk within `maxDownloadBytes`, others are downloaded once. Extracted text is
    cached by file version (`textCacheBytes`, 64 MB). The version includes the workspace identifier and the path, so a
    cache shared by several sessions never mixes their files. A password-protected PDF is not opened.
  - **Protection from malicious PDFs.** A page whose content stream decodes to more than `maxPageContentBytes` (4 MB)
    is not read, and a compressed stream that could decode to more is refused before it is decoded. Text and OCR are
    extracted on a separate queue with a time limit (`timeout`, 30 s, no longer than `OutputLimits.timeLimit`): a page
    that does not finish in time is skipped, and the command returns a partial result.
  - The three commands share a cache, so they are added together: `PDFTools.all` or `PDFTools.commands(options:)`.

All of this is gathered in `AgentVFSTools`: `commands: DataTools.all` with the default limits, or
`DataTools.commands(sqlite:json:pdf:)` with your own. It does not re-export the tool modules themselves: to name
`SQLiteCommand`, `JQCommand` or `PDFOptions`, import their module. `vfsh` uses `AgentVFSTools`. An agent adapter does
not depend on the tools and takes whichever commands it is given.

A driver that wants to serve binary files to these tools implements `readExactBytes`: the default works for text
only.

## APIs with filters and pagination

Queries against an API are awkward to mount as files, because each combination of filters gives its own result. For
them there is `APIQueryCommand` (module `AgentVFSAPI`). The agent calls the command with filters, and the command
walks the pages itself, saves every record to `/workspace/results/<command>-N.json` and prints only a short summary.
The records themselves never pass through the model's context until the agent asks for them (`jq`, `grep`, `sed` on
the saved file).

```swift
import AgentVFS
import AgentVFSAPI
import AgentVFSTools

let results = APIResults()                         // /workspace/results, mounted on the first query
let orders = APIQueryCommand(
    "orders",
    summary: "fetch shop orders",
    filters: [APIFilter("status", "order state", allowed: ["open", "closed"]),
              APIFilter("since", "created on or after, YYYY-MM-DD")],
    results: results
) { query in
    // query.parameters: declared filters only; query.cursor: nil, then the previous page's nextCursor
    let data = try await client.get("/orders", params: query.parameters, cursor: query.cursor, limit: min(query.remaining, 100))
    return try APIPage.decode(data, records: ".items", next: ".meta.next_cursor", total: ".meta.total")
}
let shell = CommandInterpreter(fileSystem: fileSystem, commands: DataTools.all + [orders])
```

What the agent sees:

```text
$ orders --status open --since 2026-10-01
saved 1240 records (380 KB, 25 pages) to /workspace/results/orders-1.json
matching records reported by the API: 1240
fields: id: number, status: string, total: number, customer.email: string, items: array of object
first record: {"id":981,"status":"open","total":120.5,...}

$ jq -c '[.[] | select(.total > 1000)] | length' results/orders-1.json
37

$ orders --status open --jq '[.[] | .customer.email] | unique | length'     # query and filter in one step
212
(all records: /workspace/results/orders-1.json)
```

When there are several APIs, or one API has many endpoints, use `APIService`: one command per service, with the
endpoints as subcommands, as in `gh` or `aws`. The client with its token is shared by all endpoints of the service.

```swift
let jira = APIService("jira", summary: "Jira issues and comments", client: jiraClient, results: results, endpoints: [
    APIEndpoint("issues", summary: "search issues",
                filters: [APIFilter("project", required: true), APIFilter("status")]) { client, query in
        let response = try await client.search(query.parameters, cursor: query.cursor)
        return try APIPage.decode(response, records: ".issues", next: ".nextPageToken", total: ".total")
    },
    APIEndpoint("comments", summary: "comments of one issue",
                filters: [APIFilter("issue", "issue key", required: true)]) { client, query in
        guard let issue = query.parameters["issue"] else { throw JiraError.missingIssue }
        let response = try await client.comments(issue)
        return try APIPage.decode(response, records: ".comments")
    },
])
let shop = APIService("shop", summary: "store orders and products", client: shopClient, results: results, endpoints: [/* ... */])
// commands: DataTools.all + [jira, shop]
```

```text
$ jira --help                      # endpoints and their filters
$ jira issues --project APP --status open
saved 87 records (41 KB, 1 page) to /workspace/results/jira-issues-1.json
```

The agent's prompt gets one line per service: `jira issues|comments [--FILTER VALUE]... …`. The agent sees an
endpoint's filters through `--help` when it needs them.

- **Safety.** Only declared filters become parameters, and with `allowed` only the allowed values. The token stays
  in your `client`, and the agent cannot set the URL or the method.
- **Limits.** `--max N` gives 1000 records by default, but never more than `maxRecords`. There are also `maxPages` and
  `timeout`. If the API fails partway through, the pages already fetched are saved and marked partial.
- **Caching.** The same query within a session reuses the saved file, and `--refresh` fetches again.
- **Records.** Each record takes one line of the file, so `grep -c` and `head` see whole records. `orders --help`
  shows the filters with their descriptions, and the `usage` line goes into the agent's prompt.
- **Your own command.** If an API does not fit filters, write your own command (for example, `api get PATH` with your
  client) and save responses with the same `APIResults`: `ensureMounted(in:)`, `cached(key)`, `save(records,...)` or
  `save(text:...)` return a `SavedResult` with a path such as `/workspace/results/<command>-N.json`. The agent then
  reads the file with `jq`, `grep` and `head`. Your command sets the host, the method and the path checks, not the
  agent.

## Pipes

`|` joins commands as in a shell: `grep -rh 'import ' app | sort | uniq -c | sort -rn | head`.

- Commands run one after another in memory, with no processes. Each gets the previous one's output in
  `CommandContext.standardInput`.
- Only commands with `readsStandardInput == true` may follow `|`: `grep`, `rg`, `head`, `tail`, `sed`, `cat`, `wc`,
  `sort`, `uniq`, `cut`, `jq`. Any other command after `|` gives a clear error listing the ones that read input.
- The output limit (`maxBytes`) applies only to the last command. Intermediate ones pass on up to `maxPipeBytes`
  (8 MB), so `… | wc -l` and `… | sort | uniq -c` see all the data.
- `fail` messages are stderr: the agent sees them, but they do not go down the pipe. The exit status is the last
  command's.
- `cd` in a pipe does not change the working directory. `;`, `&&`, `||`, `#` and redirections stay forbidden. A pipe
  holds up to 16 commands.
- A pipe does not stop the left command early, as `SIGPIPE` would: `orders | head -1` fetches as many API pages as
  `orders`. It saves tokens, not requests.

## Your own commands

```swift
let usage = "todos [FILE...]                    count TODO lines"
let todos = Command("todos", usage: usage, readsStandardInput: true) { arguments, context in
    var output = CommandOutput()
    var texts: [String] = []
    if arguments.isEmpty, let piped = context.standardInput {
        texts.append(piped)
    }
    for argument in arguments {
        do {
            let path = try context.resolvePath(argument.text).description
            texts.append(try await context.fileSystem.readText(path: path).text)
        } catch let error as VFSError {
            output.fail("todos", context.describe(error), code: 1)
        }
    }
    let count = texts.flatMap(CommandContext.lines(of:)).filter { $0.contains("TODO") }.count
    output.line("\(count)")
    return output
}

let shell = CommandInterpreter(fileSystem: fileSystem, commands: [todos])
```

- A command gets already parsed arguments (`ShellToken`) and sees only its `CommandContext`: the workspace, the
  limits, the working directory. It cannot reach the disk or the network around the drivers unless it goes there
  itself.
- You can implement the `WorkspaceCommand` protocol in your own type instead of using `Command`.
- A command with a standard command's name replaces it, and `includeStandardCommands: false` keeps only your commands
  and `help`.
- `help`, the "command not found" message, `commandNames` and `helpText` (from which an adapter builds the tool
  description for the agent) pick up new commands automatically.
- To change the working directory (as `cd` does), set `output.newWorkingDirectory`.
- A command that may follow `|` sets `readsStandardInput: true` and reads `context.standardInput` when no files were
  given. Report errors through `output.fail`, so they do not reach the next command.
- The interpreter cuts long output. `CommandOutput` does not grow past the limit: extra writes are dropped, and
  `output.isFull` tells a long loop it can stop counting.

## Security and limits

The agent cannot change anything, leave `/workspace` or bring the app down. What stands behind that:

- **Read-only.** There are no write commands, and redirections, `;`, `&`, `$()`, `#` and globs in the command line
  are refused. The tokenizer looks at Unicode scalars, so `\r\n` or a combining mark after `;` cannot hide syntax.
- **Local folders.** Symbolic links are not opened, and a file with several hard links is not read. Tools get a
  checked descriptor, not a path, so swapping a file between the check and the read does not work. Names with control
  characters (such as a line break) are not shown, so they cannot forge output.
- **Memory.** Command output is limited (`maxBytes`, or `maxPipeBytes` in a pipe), `sort` reads up to 64 MB and a
  million lines across all files together, a pipe holds up to 16 commands, `uniq`, `cut` and `wc` read line by line,
  and a line longer than 1 MB is cut.
- **Time.** Every command has the `OutputLimits.timeLimit` limit (15 s). It is also the ceiling for `sqlite3`, `jq`,
  PDF and API commands, whose own timeouts can only shorten it. Globs match without backtracking (up to 1000
  characters long, `{}` nested up to 10 deep). A regular expression stops at the deadline, so `(a+)+$` cannot hang a
  command: the search says it is incomplete. Matching runs outside the workspace actor, so a slow expression does not
  block other operations. `find` visits up to 500,000 entries. Cancelling the task stops a command inside its loops.
- **Output.** Names with control characters, bidirectional controls or zero-width characters are not shown. `vfsh`
  escapes control characters in file contents (`TerminalText.escaped`), so a file cannot control the terminal.
- **API errors.** The agent sees the text of an error thrown by `fetchPage`, so it must not contain tokens or URLs
  that carry them. `describeError:` can turn an error into safe text.
- **Several sessions.** Each has its own `CommandInterpreter` and working directory. The download and PDF text caches
  are keyed by a version that includes the workspace identifier, and temporary files live in UUID-named folders and
  are removed once nobody reads them.

## License

MIT, see [LICENSE](LICENSE).
