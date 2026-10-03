# Workbench code navigation and code questions — design (2026-10-02)

Board: umbrella #257, spec task #259, spike #258. Design mock (v5): the
"Workbench Code Navigation" artifact linked from #257. Owner decisions of
2026-10-02 are fixed inputs (§2); this document only decides how they land.

Spike results (#258): `docs/superpowers/specs/2026-10-02-code-navigation-spike.md`.

---

## 1. For the owner (one page)

**Problem.** The Files pane can open and edit a file, but finding your way in
code Claude wrote is slow: no "open by name", no jump to a definition, no list
of usages, and a question about a piece of code means switching to a terminal
and typing context by hand.

**What you will see.**
- **Open Quickly** (double Shift or ⇧⌘O, ⇧⌘F jumps straight to text): a
  Spotlight-style floating panel over the workbench. Files, symbols (functions,
  methods, types) and text in one list, with a preview of the doc comment and the
  first lines of code. On the highlighted result:
  - Return opens it in the Files pane, at the right line;
  - Option-Return opens it in a second editor pane next to the current one
    (side by side), so the file you were in stays visible;
  - Command-Return does not open anything: it sends what you typed to the AI
    as a question, and the answer appears right in the panel.
- **⌘-click / ⌃⌘J** on a name jumps to its definition; several candidates show a
  regular macOS menu at the cursor. ⌃⌘← / ⌃⌘→ go back and forth.
- **Usages** (⇧⌘U, U for Usages) in an inspector on the right, grouped by file.
- **Jump bar** above the editor: folder › file › type › method, each segment a
  menu of its neighbours; ⌃6 lists the file's symbols.
- **Ask the AI** about a selection: a ✦ button next to it (like Writing Tools),
  ⌘I, or right-click. The answer appears in a popover right there, with
  clickable `file:line` links and a field for follow-ups. "Suggest a change"
  shows a diff you can apply into the editor. All conversations stay in a
  **Questions** tab of the inspector.
- **Hand it to Claude Code** (⌥⌘↩): when a question turns into a task, the
  conversation goes to a terminal session, which does the work. `file:line` in
  the terminal output becomes clickable.

**Your decisions (2026-10-02):**
1. The AI reads the workbench folder itself, with its own read tools — it is
   started in that folder (no Watchtower-specific read tools).
2. Conversations are kept (history in the Questions tab) but never show up in
   the main AI Chat.
3. You pick the model in the question popover; the default tier is preselected.

**Out of scope (POC).** Type-aware precision (same-named symbols appear in the
candidate list and in Usages), hover types, refactoring, compile errors (LSP,
later); the index as an MCP tool for Claude; adding languages without a release
(WASM packs). All recorded on #274.

**Done when.** On this repo: Open Quickly answers files and symbols in ≤ 50 ms
per keystroke and first text matches in ≤ 300 ms; a full index finishes in the
background in ≤ 5 s and a saved file is re-indexed in ≤ 200 ms; ⌘-click lands
on the definition for every built-in language's fixture; a question about a
selection answers in the popover with working `file:line` links, and ⌥⌘↩ puts it
in a Claude Code session.

---

## 2. Owner decisions (not re-opened)

1. Mac-native, like Xcode and Spotlight, not VS Code: navigation UI is SwiftUI /
   AppKit drawn over the editor; Monaco stays a text editor only (it draws the
   ⌘-hover underline, nothing else of navigation).
2. Code colours and kind badges come from our editor theme (`wt-light`/`wt-dark`
   = Monaco `vs`/`vs-dark`): methods/functions in the keyword colour, types in
   the type colour, text matches in the string colour. Panels and menus are
   system ones.
3. Open Quickly works only while a workbench is on screen.
4. Usages and the AI question history live in the inspector on the right.
5. AI: **ask** answers in place (popover at the selection, card in Open
   Quickly); **delegate** goes to Claude Code.
6. Languages: native tree-sitter grammars in the Go CLI for ~40 popular
   languages, behind a build tag so CI and the inner loop do not compile them,
   parsing in a separate process so the editor never stalls. Others: owner
   regex rules plus a generic heuristic. No dynamic WASM packs now.
7. Path: spike → spec → owner review → plan → tasks.
8. Keys as in Xcode (table in §10).

---

## 3. Architecture

```
Go CLI                                   Desktop (Swift)
───────────────────────────────          ─────────────────────────────────────
watchtower code index  ──JSON lines──▶   CodeIndexCenter (AppState)
  internal/codeindex                       per-workbench in-memory index
  (tree-sitter + tags.scm,                 FolderWatcher → `code index --serve`
   regex rules, heuristic)                 fuzzy match + ranking (Core, pure)
watchtower code search ──JSON lines──▶   CodeSearchRun (one process per query,
  internal/codesearch                      killed on the next keystroke)
                                         Views: OpenQuicklyPanel, JumpBar,
watchtower ai query --read-folder ◀────     DefinitionMenu, CodeInspector
  (provider's own read tools, cwd = folder) CodeQuestionSurface (EmbeddedChat)
```

- Go owns parsing and searching (one implementation, testable, shared later by
  an MCP tool). Swift owns state, matching and UI.
- No database tables: the index is rebuilt from the folder; it lives in memory
  only (no cache file — §6.4).
- Every CLI run is a child process with lowered priority (`setpriority` /
  `taskpolicy -b` equivalent via `Process.qualityOfService = .utility`), killed
  and reaped when its workbench closes or the query changes.

---

## 4. File walk (shared by index and search)

One Go function, `codewalk.Files(ctx, root) iter.Seq2[File, error]`, used by
both commands so they agree on what "the workbench's files" are:

- Inside a git repository: `git ls-files -z --cached --others --exclude-standard`
  run from the folder (git found as `gitbin` finds it, never the `/usr/bin/git`
  shim — the PROJ-07 / #248 rule). Paths relative to the workbench folder.
- No repository (or git missing): a directory walk that skips
  `CodeFileTree.hiddenNames` — the Go list is a copy pinned to the Swift one by
  a fixture test (`code_hidden_names.json`, read by both test suites). Git
  failing, or listing nothing (a folder the repository ignores), also falls
  back to the walk, with one stderr line.
- Always skipped: symlinks that leave the folder, files > 2 MB (index) / > 5 MB
  (search, same cap as the editor), files whose first 8 KB contain NUL.
- Order: as git/the walk yields; consumers do not depend on it.
- Limit (parked): a non-ignored folder whose every file is git-ignored is
  walked in full, while `--files` reports those files as ignored.

---

## 5. `watchtower code search`

```
watchtower code search --folder DIR --query Q [--word] [--case] [--regex]
                       [--max N=2000] [--context 2] [--json]
```

- No external dependency (no ripgrep). Workers = `GOMAXPROCS`, each reads a file
  and scans it with `bytes.Index` (literal) or `regexp` (`--regex`); `--word`
  wraps the query in `\b…\b` semantics (identifier boundaries `[A-Za-z0-9_$]`,
  not regexp `\b`, so `$x` in PHP/JS matches).
- Smart case by default: case-insensitive unless Q has an upper-case letter;
  `--case` forces sensitive.
- Output: one JSON object per line, flushed per file:
  `{"path","line","col","text","text_col","before":[…],"after":[…]}` — `col`
  in UTF-16 units (what Monaco and NSString use) of the full line, `text`
  capped at 400 chars around the match, `text_col` the match's column inside
  `text` (an invalid UTF-8 byte counts one unit). A final
  `{"done":true,"files":N,"matches":M,"truncated":bool}`, `files` = files
  searched.
- The enclosing function ("in `saveNow`") is **not** computed in Go: Swift adds
  it from its index when it has one (keeps search independent of the index).
- Cancellation: SIGTERM/SIGINT → stop within 50 ms (`signal.NotifyContext`),
  exit 0 with no `done` line. Swift kills the previous run on every keystroke
  after a 120 ms debounce.
- Exit codes: 0 always for a search that ran (zero matches included); 2 for a
  usage error or an unreadable folder, with a message on stderr.
- Target: first match line ≤ 300 ms on this repo (warm FS cache).

Usages (§8.3) are `code search --word --case --query NAME`.

---

## 6. Symbol index — `watchtower code index`

### 6.1 Symbol record (contract, fixed now)

```json
{"name":"saveNow","kind":"method","path":"WatchtowerDesktop/Sources/ViewModels/CodeFileBuffer.swift",
 "line":182,"col":10,"end_line":215,"container":"CodeFileBuffer",
 "signature":"func saveNow(explicit: Bool = false, overwrite: Bool = false) -> Bool",
 "doc":"Writes `text` when the disk still holds the version it was edited on.",
 "lang":"swift"}
```

- `kind` ∈ `function, method, class, struct, enum, protocol, interface, type,
  const, var, field, module, macro` — a closed set; a grammar's capture that
  maps to nothing is dropped. Badges: M method, F function, C class, S struct,
  E enum, P protocol/interface, T type alias, K const/var/field, N module.
- `line`/`end_line` 1-based, `col` 1-based UTF-16 of the name.
- `container`: nearest enclosing type or module name, `""` at top level.
- `signature`: the definition's first line(s) up to the body opener, whitespace
  collapsed, ≤ 200 chars. `doc`: the first sentence of the preceding doc
  comment (`///`, `/** */`, `#`/`"""` docstring per language), ≤ 200 chars.
- `outline` (bool, omitted when false): a document-outline entry — Markdown
  headings and config files' top-level keys — shown in the jump bar, kept out
  of Open Quickly's Symbols scope.

### 6.2 CLI

```
watchtower code index --folder DIR --json            # full, streamed
watchtower code index --folder DIR --files a b --json  # only these paths
watchtower code index --folder DIR --serve            # long-lived, §6.4
```

Stream: `{"file":path,"lang":"swift","symbols":[…]}` per file (an empty list
for a file that parsed with none, `"lang":""` for an unsupported file), then
`{"done":true,"files":N,"symbols":M,"ms":T}`. A path given to `--files` that no
longer exists yields `{"file":path,"deleted":true}`. Same cancel/exit rules as
search.

- A `--files`/`--serve` path the full run would not list — a directory, binary,
  over 2 MB, outside the folder, or `.gitignore`d (one `git check-ignore
  --stdin` per batch, inside a repository) — yields `"lang":""` with no
  symbols and `"skipped":true`, not `deleted` (R21: a readable file of an
  unsupported language is `"lang":""` without `skipped`).
- A file of a language indexed without a grammar of its own — HTML, CSS, SCSS,
  Dockerfile, Markdown, YAML, TOML, JSON (derived from the language table:
  the languages indexed by a scan) — carries `"defs":false`: its entries are
  never code definitions, so the Desktop treats it as unsupported for
  navigation (the text-search heuristic on a miss, the jump bar's "Language X:
  text search"; R32). Absent means the file may hold definitions.
- Every `--files`/`--serve` result (and its symbols' `path`) echoes the request
  path verbatim, deleted ones included (`./a.go` stays `./a.go`).
- A file whose parse fails or panics, or whose language's query does not
  compile, yields `"lang":""` and one stderr line; the run goes on.

### 6.3 Runtime, grammars and queries (from the spike)

- **Runtime:** the official `github.com/tree-sitter/go-tree-sitter` (v0.25, MIT,
  ABI 15) behind a small adapter in `internal/codeindex/ts` that owns every
  `Close()` (the official binding has no finalizers; a leaked tree or cursor is
  a C leak). One parser and one query cursor per worker, reused.
- **Grammars:** `github.com/alexaandru/go-sitter-forest/<lang>`, one module per
  language, each pinned in `go.mod` (forest vendors the generated `parser.c`
  that some upstream grammar repos do not commit — e.g. Swift's — so `go get`
  of an upstream binding alone cannot build). smacker is not used (stale since
  2024, ABI 14 grammars, no queries).
- **Build constraints:** the full set — one `grammar_<id>.go` per language,
  each registering itself into the `grammars_full.go` map from `init` — under
  `//go:build codegrammars && cgo`; Go, Swift and Python in
  `grammars_min.go` under `//go:build !codegrammars && cgo`; a `!cgo` stub
  registers none, so `CGO_ENABLED=0` builds and tools still compile (the index
  then reports every file as `"lang":""`). The CLI today has **no** cgo package
  (`modernc.org/sqlite` is pure Go); these are the first.
- **Languages — 45** (`codegrammars`): C, C++, C#, Rust, Go, Java, JavaScript,
  TypeScript, TSX, Python, PHP, Swift, Ruby, Lua, Scala, Elixir, OCaml, Elm,
  Dart, R, Kotlin, Bash, Groovy, SQL, HCL/Terraform, Protobuf, Dockerfile, HTML,
  CSS, SCSS, YAML, TOML, JSON, Markdown, Svelte, Vue, Erlang, Haskell, Zig,
  Objective-C, Julia, Perl, Nim, Clojure, GraphQL — 35 grammars; the 10 markup
  and config formats below have none of their own.
- **Queries are ours**, vendored as `internal/codeindex/queries/<lang>.scm`,
  each with a golden fixture (`testdata/<lang>/` source + expected symbols):
  - 20 start from upstream `tags.scm` (C, C++, C#, Dart, Elixir, Elm, Go, Java,
    JS, Lua, OCaml, PHP, Python, R, Ruby, Rust, Scala, Swift, TS, TSX), with
    these known fixes: **Swift rewritten** (upstream's property pattern reports
    the enclosing type as a fake class per property; methods inside enums come
    out as functions); **PHP extended** (enums, class constants, promoted
    constructor properties; methods vs functions); **Ruby** without the
    `#is-not? local`/`#strip!` predicates the Go runtime does not implement;
    **TS/TSX** = JS query + TS query concatenated.
  - 15 written from scratch (~20 lines each): Kotlin, Bash, Groovy, Haskell,
    Erlang, Clojure, Julia, Nim, Objective-C, Perl, Zig, SQL (`CREATE
    TABLE/VIEW/INDEX/TRIGGER`), HCL (`resource`/`data`/`module`/`variable`/
    `output` blocks), Protobuf (`message`/`enum`/`service`/`rpc`), GraphQL
    (type and operation definitions).
  - 10 markup/config, by line scanners in Go, not grammars (work in every
    build, past what a parser rejects): Markdown headings and YAML/TOML/JSON
    top-level keys as `module`/`field` outline symbols (for the jump bar and
    ⌃6 only, excluded from Open Quickly's Symbols scope); HTML, CSS, SCSS,
    Dockerfile: known by name, no symbols in the POC; Svelte and Vue: the
    `<script>` blocks parsed with the JS/TS grammar and query, the rest masked.
- **Signature and doc are extracted in Go, not by the query** (no query
  predicate is relied on): signature = the definition node's source from its
  start to the first body child (per-language body node names in the language
  table), whitespace collapsed; doc = the contiguous comment nodes directly
  above the definition (attributes/decorators in between allowed), accepted
  only with the language's doc prefix (`///`, `/**`, `##`, `--|`…; PHP only
  `/**`, so a plain `//` is not a doc), plus Python's first-statement
  docstring. First sentence, ≤ 200 chars.
- **Parse errors stay local:** a file with `ERROR` nodes is indexed for what
  parsed (the Swift grammar still fails on `nonisolated(unsafe)`, typed
  throws, `switch await`, some `#if` placements — 14 of 1 161 Swift files in
  this repo, the rest of each file indexed).
- Language table (extensions, file names, shebangs → language id): one Go
  table, and a fixture test that every association in `languages.js` /
  Monaco's built-ins for a supported language maps to the same id.
- Licences: `THIRD_PARTY_NOTICES.md` lists every grammar and carries the
  copyright lines, the MIT and Apache-2.0 texts, the Elixir NOTICE and the
  MPL-2.0 source pointer (Nim); `build-app.sh` ships it in the app's
  `Contents/Resources`.

### 6.4 Performance (measured by the spike, loaded machine, M1 Pro)

| Measure | Result | Target |
|---|---|---|
| CLI size, all 45 grammars | 37.7 → 104.6 MiB (+70 MB; app +27 %) | none (owner: size not a concern) |
| Cold build, empty cache | 21 s → 39 s wall, +51 s CPU | — |
| Warm rebuild | no change (1.4 s) | — |
| Full index, this repo (3 134 files, 61 k symbols) | 6.6 s ×1, 3.9 s ×2, 1.7 s ×4, 1.4 s ×8 workers; peak RSS 130–185 MB | ≤ 5 s |
| One-file re-index | 10–75 ms (+90–257 ms for the first file of a language: query compile) | ≤ 200 ms |

Decisions from these numbers:
- Workers = `max(2, GOMAXPROCS/2)` for a full run (leaves the editor and the
  app cores), at `QualityOfService.utility`.
- Markdown is parsed for headings only with a line scanner, not tree-sitter
  (it was ~40 % of parse CPU and yields no code symbols).
- Queries compile lazily per language and stay cached for the process; the
  `--files` path keeps one long-lived process instead of one per change:
  `watchtower code index --folder DIR --serve` reads a path list per stdin
  line and answers with the same JSON stream ending in a `done` line, so the
  first-file query compile is paid once per workbench, not per save. Swift
  restarts it if it exits.
- No cache file: a full rebuild on workbench open is ≤ 2 s on 4 workers.
- Size trim (drop nim/julia/objc/haskell/perl, ≈ −25 MB): not now; the owner
  said size does not matter.

### 6.4a CI and release (#262)

- Ordinary CI jobs and the inner loop stay untagged: they compile only the
  three minimal grammars (Go, Swift, Python), enough for the index's own tests.
- `scripts/build-app.sh` and `release.yml` build and test with
  `-tags codegrammars` (native macOS build, cgo already on; nothing is
  cross-compiled).
- A CI job `codeindex-full` (ubuntu, gcc present) runs
  `go test -tags codegrammars ./internal/codeindex/...` only when
  `internal/codeindex/**`, `internal/codewalk/**`, `go.mod`, `go.sum`,
  `Makefile` or `.github/workflows/ci.yml` change; ≈ +50 s CPU cold, cached by
  `setup-go` afterwards.
- `.golangci.yml` adds `build-tags: [codegrammars]` so tagged files are linted.
- `go mod tidy` keeps the grammar modules in `go.mod` regardless of tags
  (expected; untagged builds never download them).

### 6.5 Regex rules and the heuristic (#269, low priority)

- YAML: `<lang>: {extensions: [...], filenames: [...], definitions: [{kind, pattern}]}`;
  `pattern` is RE2, group 1 = name. Invalid YAML or pattern → the file is
  ignored as a whole and the jump bar of an affected file says
  "Rules file: <error>", never a crash or a silent partial load.
- Heuristic for unsupported files (⌘-click only): lines matching
  `\b(func|function|def|fn|class|struct|interface|enum|type|proc|sub)\s+NAME\b`
  first, then every whole-word occurrence; the jump bar shows
  "Language X: text search".

---

## 7. `CodeIndexCenter` (Swift)

- On `AppState`, one index per workbench, alive while the workbench is on
  screen (Files pane, FILES section or Open Quickly) and for 5 min after (the
  same idle-release shape as `EmbeddedChatCenter`), so navigating away and back
  does not reindex ([[async state survives navigation]]).
- Files list is available immediately (from the walk, before symbols); symbols
  arrive file by file. State: `.idle | .indexing(done, total) | .ready | .failed(message)`,
  the failure shown in the jump bar and the Open Quickly footer.
- Updates: `FolderWatcher` batches (already realpath'd, hidden names excluded)
  → 300 ms debounce → the changed paths written to the workbench's `--serve`
  process; a rescan event → full run. While a run is in flight, queries answer from the current index.
  At most one run per workbench at a time; a newer batch waits and merges.
- An unsaved buffer is indexed from disk only (the index lags the editor until
  autosave, ≤ 300 ms + run time). Accepted.
- Matching (WatchtowerCore, pure, tested): fzf-style subsequence scoring
  (word starts, camelCase humps, path separators, consecutive runs), case-smart;
  `cfbuf` → `CodeFileBuffer`, `vm/cfb` → `ViewModels/CodeFileBuffer.swift`.
  Ranking boosts: open tabs > recently opened (last 50 per workbench) > git
  modified > the rest; symbol kind order type > method/function > others.
- Target: ≤ 50 ms per keystroke for files + symbols on this repo, measured by a
  Core test over a synthetic 3 000-file / 30 000-symbol index.

---

## 8. Navigation UI

### 8.1 Open Quickly (#265)

- `NSPanel` (non-activating, floating, `.regularMaterial`), centred over the
  window's top third, 680 pt wide; Esc, a click outside, or the workbench
  leaving the screen closes it.
- Shortcuts: double Shift (two Shift key-downs within 300 ms with no other key
  between, via a local `NSEvent` monitor active only while a workbench window
  is key), ⇧⌘O, ⇧⌘F (scope = Text). Not global.
- Scope segments: All · Files · Symbols · Text. All = "Best match" + sections,
  each capped at 8 rows (Text at 20, "more…" switches to the Text scope).
- Row: kind badge or Finder file icon (`NSWorkspace.icon(forFile:)`), name with
  matched characters bold, subtitle = container · file (files: folder + git
  mark; text: path:line). Last row of All: "✦ Ask AI: "<query>"".
- Preview (right): kind, name, `container › path:line`, doc, the first 12 lines
  from `line` (text: 3 lines around the match), coloured with our theme. Space
  toggles Quick Look (`QLPreviewPanel`) for the selected file.
- ↩ opens in the Files pane at the line (a preview tab), ⌥↩ in the other pane
  of a split (creating it), ⌘↩ asks the AI (§9.3), ⌥⌘↩ delegates (§9.5).

### 8.2 Go to definition (#266)

- Page → Swift: `definition {req, id, word, line, col}` on ⌘-click or ⌃⌘J;
  Swift → page: `definitionDone(req)` (clears the busy underline). `req` is a
  page counter; a reply for a stale `req` is dropped.
- Candidates = index symbols with `name == word` (case-sensitive); order: same
  file → same folder → same top-level folder → rest; then kind order. One → open
  (a kept tab, not preview) and put the cursor on the name; several →
  `NSMenu` at the click point ("word — N definitions", badge + `Type.name`,
  `path:line`, separator, "Show All Usages…"); none → the heuristic (§6.5),
  then a beep and "No definition of `word`" in the jump bar for 2 s.
- History: back/forward stack per Files pane (cap 100), a jump pushes the
  current `path:line:col`; ⌃⌘← / ⌃⌘→ and the jump bar's ‹ ›.

### 8.3 Usages (#267)

- SwiftUI `.inspector` on the Files pane, tab "Usages" (and "Questions", §9.4).
  Header "Usages — name · N"; groups per file, disclosure triangles, rows
  `line  text` with the name bold; click opens at the line.
- Source: `code search --word --case` (same-named symbols included — accepted).
  Streaming fills the list; a new query cancels the old one.
- Triggers: ⇧⌘U (word under cursor), context menu, "Show All Usages…".

### 8.4 Jump bar (#268)

- Replaces the path line above the editor; keeps its git mark and
  Saved/Edited state. Segments: folders › file › type › method at the cursor
  (from the index by line range; cursor position comes from a new page message
  `cursor {id, line, col}`, throttled to 10/s).
- Each segment is an `NSMenu` of neighbours (folder files, the file's types, the
  type's members). The last segment's menu (and ⌃6) is the file's symbol list
  with a filter field.
- Unsupported language: a muted "Language X: text search" at the end.

### 8.5 Page protocol additions

Added to the header comment of `CodeEditorWeb/index.html` and to the #275
harness:

| Direction | Message | Payload |
|---|---|---|
| page → Swift | `definition` | `{req, id, word, line, col}` |
| page → Swift | `cursor` | `{id, line, col}` |
| page → Swift | `selection` | `{id, text, startLine, startCol, endLine, endCol}` (≤ 20 KB; empty = none) |
| page → Swift | `askAI` | `{id}` (⌘I in the editor) |
| Swift → page | `definitionDone(req)` | — |
| Swift → page | `reveal({id, line, col})` | put the cursor on and scroll to |
| Swift → page | `selectionRect()` → `{x, y, w, h}` | for anchoring the popover |
| Swift → page | `proposeEdit({id, range, text})` / `clearProposal(id)` | inline diff decoration |
| Swift → page | `applyEdit({id, range, text})` | one undoable edit; then the normal `text` message |

---

## 9. Code questions (AI)

### 9.1 Surface (#270)

- A new `CodeQuestionSurface` (`ChatSurfaceSpec`), persistence `.database`,
  `toolAccess` `.draftOnly` (it never writes — AGENT-04), engine from
  `EmbeddedChatCenter` keyed `code-question:<workbench>:<conversation>`.
- First-turn context (built in Swift, no file content beyond this): workbench
  folder name, file path, language, the selection (or the cursor line) with
  ±40 lines around it, and up to 10 index entries (signature + doc) for names the
  selection references that the index resolves uniquely.
- Reading more of the folder (owner decision 1): the provider's own read
  tools, run in the workbench folder. `watchtower ai query` gains
  `--read-folder DIR` (DIR must resolve to a workbench folder; refused
  otherwise, exit 2):
  - Claude: the process starts with cwd = DIR, and `Read`, `Grep`, `Glob`, `LS`
    are removed from `--disallowedTools` for this run only; everything else in
    `DisallowedTools` stays hidden (`Edit`, `Write`, `Bash`, `WebFetch`,
    `WebSearch`, `Task`, …), and no watchtower write tools are mounted
    (`toolAccess` `.draftOnly`).
  - Codex: `--cd DIR` with its read-only sandbox, same no-write tool set.
  - Ollama: no file tools; the answer uses the first-turn context only, and the
    popover says so once ("this model cannot read other files").
  - Accepted (owner): these tools can read outside the folder; nothing can
    write or reach the network.
- Model (owner decision 3): the popover and the Questions tab carry the same
  provider/model picker as the main chat composer, preselected to the default
  tier; the choice is kept per conversation (`chat_conversations.provider`/
  `model`), and a follow-up keeps it.
- System prompt (in the surface spec, Swift, as every embedded surface):
  answers in the owner's language, cites code as
  `path:line` (repo-relative), never claims to have changed a file; "Suggest a
  change" replies end with one fenced block tagged `wt-edit` holding the
  replacement for the selection only.

### 9.2 Popover at the selection (#271)

- A ✦ button appears 0.5 s after a non-empty selection settles (hidden while
  typing, on scroll, and when the selection clears), anchored by
  `selectionRect()`. ⌘I or the context menu "Ask AI" open the popover directly;
  with no selection, the cursor line is the context.
- `NSPopover` (`.semitransient`) with quick actions — Explain · Find problems ·
  Where is it used? · Suggest a change — that send a fixed prompt; a field
  "Ask a follow-up…" continues the same conversation.
- Answer: `EmbeddedChatView` `.compact`; `path:line` links open in Files.
  Actions: Copy · Pin to inspector · Hand to Claude Code (⌥⌘↩).
- Suggest a change: the `wt-edit` block is shown as an inline diff over the
  selection (`proposeEdit`); Apply → `applyEdit` (undoable in Monaco), then the
  usual autosave and PROJ-03 conflict rules — Apply is refused with a message if
  the buffer is in conflict or the selection's text changed since the question.
- Esc closes; the conversation stays in Questions.

### 9.3 In Open Quickly (#272)

- ⌘↩ or the "✦ Ask AI" row: the query becomes a question with no selection
  context (the open file, if any, is named in the context); the answer renders
  as a card in the panel. ↩ follows up; a link click opens the file and closes
  the panel.

### 9.4 Questions tab (#272)

- Inspector tab listing this workbench's code conversations (newest first):
  first question, `path:line` it was asked from, time. Click opens it in the
  inspector (`EmbeddedChatView` `.compact`). Delete removes the conversation.
- Storage (owner decision 2): `chat_conversations` rows with
  `context_type = 'code_question'` and `context_id = '<workbench id>:<path>:<line>'`;
  `context_type` has no CHECK, so no migration. **Never in the main AI Chat:**
  its list, search and FTS read `context_type IS NULL` only
  (`ChatConversationQueries`, `ChatSearchQueries`); a guard test inserts a
  `code_question` conversation with messages and asserts it appears in none of
  the main chat's list, title search or full-text search, nor in the Go
  chat history/search tools.

### 9.5 Hand to Claude Code (#273)

- ⌥⌘↩ from the popover, the Questions tab or Open Quickly. A sheet picks a
  running session of the workbench or "New session"; the text sent is the
  question, the answer's text and `path:line` references (never file bodies),
  prefixed by one line "From a Watchtower code question:".
- Running session: typed into its PTY like Send comments, then Return — the
  sheet's Send is the confirmation. New session: started with the text as its
  first prompt. The terminal pane opens beside the editor in a split
  (`Placement.keeping`).
- Terminal links: SwiftTerm's link detection extended with a `path:line(:col)`
  matcher resolved against the session's folder; ⌘-click opens it in Files.
  Paths outside the folder are not links.

---

## 10. Keys

| Action | Keys |
|---|---|
| Open Quickly | ⇧⇧, ⇧⌘O |
| Find text in workbench | ⇧⌘F |
| Go to definition | ⌘-click, ⌃⌘J |
| Usages | ⇧⌘U |
| File symbols | ⌃6 |
| Back / Forward | ⌃⌘← / ⌃⌘→ |
| Quick Look | Space (in Open Quickly) |
| Ask AI | ⌘I, ✦ |
| Hand to Claude Code | ⌥⌘↩ |

All are active only while a workbench is the key window's content; inside
Monaco, the page forwards them (Monaco's own bindings for these chords are
removed so they do not double-fire).

---

## 11. Tests and targets

- Go: walk (git and non-git, hidden names fixture, size/binary skips, symlink
  escape); search (literal, word boundaries incl. `$x`, smart case, regex,
  UTF-16 columns with emoji, cancel within 50 ms, truncation); index per
  language fixture golden (§6.3), `--files` with a deleted path, unsupported
  file. Benchmarks for the §1 targets run manually and recorded in the PR.
- Swift Core: fuzzy match and ranking tables; definition candidate ordering;
  history stack; jump bar segment resolution by line range; `wt-edit` parsing;
  `path:line` link matcher.
- Swift: `CodeIndexCenter` (start → navigate away → back keeps the index;
  watcher batch → `--files` run; rescan → full run; failure state);
  `CodeQuestionSurface` spec (draft-only, context assembly); bridge messages via
  the #275 harness.
- Full-index and one-file benchmarks (`-tags codegrammars`) rerun on an idle
  machine before the PR; results recorded in the PR body against §6.4.

---

## 12. Owner decisions on this spec (2026-10-02)

1. File reading: the provider's own read tools in the workbench folder (§9.1),
   not Watchtower read tools.
2. Storage: chat tables, hidden from the main chat (§9.4).
3. Model: picker in the popover, default tier preselected (§9.1).
4. Keys: Open Quickly keeps ↩ / ⌥↩ / ⌘↩; Usages is ⇧⌘U (not ⌃⇧⌘F).

---

## 13. Out of scope

LSP precision and hover types; refactoring; the index as an MCP tool for Claude
Code sessions; dynamic WASM language packs; indexing unsaved buffers; search
and replace across files; multi-workbench Open Quickly. See #274.
