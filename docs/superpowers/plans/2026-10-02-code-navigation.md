# Workbench Code Navigation and Code Questions — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Open Quickly, go to definition, usages, jump bar and in-place AI questions about code in the Workbench Files pane, backed by a tree-sitter symbol index and a text search in the Go CLI.

**Architecture:** Go owns parsing (`internal/codeindex`, `watchtower code index`) and searching (`internal/codesearch`, `watchtower code search`), streaming JSON lines; Swift keeps a per-workbench index in memory (`CodeIndexCenter`), matches and ranks in WatchtowerCore, and draws all navigation UI natively over Monaco. AI questions are one more embedded chat surface, run by `ai query --read-folder` in the workbench folder.

**Tech Stack:** Go 1.25 + cgo, `github.com/tree-sitter/go-tree-sitter` v0.25, `github.com/alexaandru/go-sitter-forest/<lang>`; SwiftUI/AppKit (macOS 14), WKWebView + Monaco 0.57, SwiftTerm, GRDB.

**Spec:** `docs/superpowers/specs/2026-10-02-code-navigation-design.md` (owner-approved 2026-10-02; §12 lists the owner's decisions). Spike numbers: `docs/superpowers/specs/2026-10-02-code-navigation-spike.md`. Executors read the spec section each task names — the plan does not repeat its contracts.

**Plan style (repo rule):** lean — files, interfaces, dependencies and the exact test cases per task; implementers write the code. Pinned values from the spec are binding even when not repeated here.

## Global Constraints

- Repo text, identifiers, comments and commits in English; board comments in Russian.
- No live-install data in fixtures (neutral samples only); `make hooks` leak check passes.
- Grammars: full set only under `//go:build codegrammars && cgo`; untagged cgo builds carry Go, Swift, Python; `!cgo` builds compile with no grammars (spec §6.3).
- git is found through `internal/gitbin` (Go) — never `/usr/bin/git` (PROJ-07 rule).
- Every spawned CLI process runs at `QualityOfService.utility`, is killed and reaped when its workbench leaves the screen or its query is superseded; tests that spawn processes reap the whole group in `t.Cleanup` / `tearDown`.
- Columns crossing the Go↔Swift boundary are 1-based UTF-16 units; lines are 1-based.
- Search and index exit 0 for any run that ran; 2 for a usage error or unreadable folder, message on stderr; SIGTERM/SIGINT stop within 50 ms with no `done` line.
- Desktop rules of `docs/review/review-rules.md` "Swift / Desktop conventions" apply (async state on `AppState` centers, no TCC prompts, every DB write throws).
- Inner loop only per task (`go test ./internal/<pkg>`, `make test-swift FILTER=…`, `make lint-diff`); full gates once per phase by the controller.
- Keys exactly as spec §10 (Usages = ⇧⌘U).

## Review Focus

1. **A workbench that is not a git repository, or whose git is missing** — the walk must fall back to the directory walk with `hiddenNames`, never return zero files. Test in Task 1.
2. **Files with non-ASCII before the symbol** (emoji, Cyrillic, CJK) — UTF-16 columns must land the cursor on the name in Monaco. Tests in Task 1 (index) and Task 2 (search), and Task 7 (`reveal` with an emoji line).
3. **The owner edits fast while the index updates** — a newer watcher batch during a `--serve` run must not be lost or reorder results. Test in Task 5.
4. **A huge or generated file** (minified JS 2 MB+, lockfiles) — skipped by size, never stalls search or index. Tests in Tasks 1 and 2.
5. **A code question whose conversation must never surface in the main AI Chat** — guard test in Task 10 (list, title search, FTS, Go chat tools).

## Lanes and order

```
Phase A (Go lane)        T1 index core → T3 CI/build → T4a/T4b/T4c languages
                         T2 search (parallel with T1, own worktree)
Phase B (Swift lane)     T5 CodeIndexCenter (needs T1, T2)
                         → T6 Open Quickly → T7 definition → T8 usages → T9 jump bar
Phase C (AI)             T10 ai query --read-folder + surface (Go part may start in Phase A)
                         → T11 popover → T12 OQ answer + Questions tab → T13 hand to Claude Code
Phase D (low)            T14 regex rules + heuristic (after T1; Swift part after T7)
```

One Swift lane at a time (CLAUDE.md). Each phase is one PR (repo rule: one PR per lane, merge on green).

| Task | Board |
|---|---|
| T1 | #260 |
| T2 | #263 |
| T3 | #262 |
| T4a/b/c | #261 (sub-targets) |
| T5 | #264 |
| T6 | #265 |
| T7 | #266 |
| T8 | #267 |
| T9 | #268 |
| T10 | #270 |
| T11 | #271 |
| T12 | #272 |
| T13 | #273 |
| T14 | #269 |

---

### Task 1: File walk and symbol index core (`internal/codewalk`, `internal/codeindex`, `watchtower code index`)

Spec §4, §6.1, §6.2, §6.3 (runtime, build constraints, signature/doc extraction), §6.4 (`--serve`, workers, Markdown).

**Files:**
- Create: `internal/codewalk/walk.go`, `walk_test.go`, `testdata/hidden_names.json` (copied from Swift's `CodeFileTree.hiddenNames`; Swift test reading the same file added in Task 5)
- Create: `internal/codeindex/ts/adapter.go` (owns parser/tree/cursor `Close()`), `internal/codeindex/{index.go,symbol.go,extract.go,lang.go,grammars_min.go,grammars_full.go,grammars_nocgo.go,serve.go}`, `queries/{go,swift,python}.scm`, `testdata/{go,swift,python}/` (source + `expected.json`), tests
- Create: `cmd/code.go` (`code` parent + `index` subcommand), `cmd/code_test.go`
- Modify: `go.mod`/`go.sum`

**Interfaces:**
- Produces: `codewalk.Files(ctx, root string) iter.Seq2[codewalk.File, error]` with `File{Rel string; Size int64}`; `codewalk.MaxIndexBytes = 2<<20`, `MaxSearchBytes = 5<<20`.
- Produces: `codeindex.Symbol` (fields exactly spec §6.1, JSON names as shown), `codeindex.Kind` closed set, `codeindex.FileResult{File, Lang string; Symbols []Symbol; Deleted bool}`, `codeindex.Run(ctx, root string, paths []string /*nil = all*/, workers int, emit func(FileResult) error) (Summary, error)`, `codeindex.LanguageFor(rel string, head []byte) string`.
- Produces CLI: `watchtower code index --folder DIR [--files …] [--serve] --json` (stream format spec §6.2; `--serve`: one stdin line = tab-separated paths → that run's lines then a `done` line; EOF → exit 0).

**Test cases (must pass):**
- [ ] walk, git repo: tracked + untracked-not-ignored files listed, ignored and `.git/` not; paths relative to the workbench folder when it is a subfolder of the repo.
- [ ] walk, no repo: directory walk skips every name in `hidden_names.json`; walk with git binary not found (injected locator) falls back the same way.
- [ ] walk skips: symlink pointing outside the folder; file > 2 MB for index; file with NUL in its first 8 KB; a symlink inside the folder to a file inside it is listed once.
- [ ] Go/Swift/Python fixtures: symbols equal `expected.json` (name, kind, line, col, end_line, container, signature, doc).
- [ ] Swift fixture includes: struct/class/enum/actor/protocol/extension, methods inside an enum report `method`, a property does **not** produce a fake class row, `///` doc above an `@MainActor` attribute is picked up, `#expect` macro lines do not abort the file.
- [ ] Column: a Swift line `let 🙂 = 1; func après()` reports `col` of `après` in UTF-16 units.
- [ ] Python: docstring as first statement becomes `doc`; `#` comment above `def` does not.
- [ ] `--files` with one deleted path emits `{"file":…, "deleted":true}`; unsupported file emits `"lang":""` with no symbols.
- [ ] `--serve`: two stdin lines produce two runs each ending in `done`; closing stdin exits 0; SIGTERM during a run exits within 50 ms, no `done` (process group reaped in cleanup).
- [ ] Markdown file: headings only (line scanner), kind `module`, no tree-sitter parse.
- [ ] `CGO_ENABLED=0 go build ./...` succeeds (stub registers no grammars; index reports `"lang":""`).
- [ ] Bench (not in CI, recorded in PR): full run of this repo at `max(2, GOMAXPROCS/2)` workers ≤ 5 s; one-file `--serve` run after warm-up ≤ 200 ms.

**Steps:** write fixtures + failing tests → walk → adapter + min grammars → extraction → CLI → `--serve` → `go test ./internal/codewalk ./internal/codeindex ./cmd -run Code` → commit per component.

---

### Task 2: Text search (`internal/codesearch`, `watchtower code search`)

Spec §5. Depends on: Task 1's `codewalk` only (if T1 is not merged yet, T2's lane rebases on it before PR; the walk API above is fixed).

**Files:**
- Create: `internal/codesearch/{search.go,boundary.go,search_test.go}`, `cmd/code_search.go`, test in `cmd/code_test.go`

**Interfaces:**
- Produces: `codesearch.Options{Query string; Word, Case, Regex bool; Max, Context int}`, `codesearch.Match{Path string; Line, Col int; Text string; Before, After []string}`, `codesearch.Run(ctx, root string, opt Options, emit func(Match) error) (Summary, error)`.
- Produces CLI exactly spec §5 (`--word --case --regex --max --context --json`).

**Test cases:**
- [ ] literal, smart case: `savenow` matches `saveNow`; `SaveNow` does not match `savenow`; `--case` forces sensitive.
- [ ] `--word`: `id` does not match `idx` or `user_id`; `$x` matches in PHP `$x = 1` and not in `$xy`.
- [ ] `--regex` with an invalid pattern → exit 2, stderr message.
- [ ] UTF-16 `col` after an emoji and after Cyrillic text.
- [ ] `text` capped at 400 chars around the match on a 10 000-char line; `before`/`after` honour `--context`.
- [ ] `--max 5` stops at 5 and the `done` line says `truncated:true`.
- [ ] a 3 MB minified file is searched (≤ 5 MB); a 6 MB one is skipped; a binary file is skipped.
- [ ] SIGTERM mid-run: exit within 50 ms, no `done`.
- [ ] Bench (PR body): first match line ≤ 300 ms on this repo, warm cache.

---

### Task 3: CI and release wiring for grammars (#262)

Spec §6.4a. Depends on: Task 1.

**Files:**
- Modify: `scripts/build-app.sh` (`-tags codegrammars`), `.github/workflows/release.yml` (build + test tagged), `.github/workflows/ci.yml` (new job `codeindex-full`, paths filter `internal/codeindex/**`, `go.mod`, `go.sum`), `.golangci.yml` (`build-tags: [codegrammars]`), `Makefile` (`test-codeindex-full` target), `THIRD_PARTY_NOTICES` (licences of grammars added so far).

**Test cases:**
- [ ] `make test` (untagged) does not compile any forest grammar except go/swift/python (`go list -deps -tags '' ./cmd/... | grep go-sitter-forest` lists exactly those three).
- [ ] `make test-codeindex-full` runs `go test -tags codegrammars ./internal/codeindex/...` green.
- [ ] `build-app.sh` produces a CLI whose `watchtower code index --folder <fixture dir> --json` reports a Rust symbol for a `.rs` fixture (proves the tag reached the release build).
- [ ] CI job is skipped on a PR touching only `docs/` (dedupe/paths gate shows the job as skipped, not failed).

---

### Task 4a: Upstream-based queries (#261)

Spec §6.3 ("20 start from upstream"). Depends on: Task 3.

**Files:** `internal/codeindex/queries/{c,cpp,c_sharp,dart,elixir,elm,java,javascript,typescript,tsx,lua,ocaml,php,r,ruby,rust,scala}.scm`, `grammars_full.go`, `lang.go` rows, `testdata/<lang>/` + `expected.json` each, `THIRD_PARTY_NOTICES`.

**Test cases (tagged):**
- [ ] each language's fixture golden passes; every fixture has ≥ 1 function/method, ≥ 1 type, ≥ 1 doc comment where the language has one.
- [ ] PHP: enum, class constant, promoted constructor property present; methods `method`, free functions `function`; a `//` comment above a function is **not** `doc`, a `/** */` is.
- [ ] Ruby query compiles on the official runtime (no `#is-not? local`/`#strip!`).
- [ ] TS/TSX: JS-only constructs (plain `function`) and TS-only (`interface`, `type` alias) both found.
- [ ] Lua via forest grammar: `function M.foo()` → `foo`, container `M`.
- [ ] `lang.go` vs `languages.js`: fixture test that every extension/filename Monaco or `languages.js` maps for these languages maps to the same id here.

### Task 4b: Hand-written queries (#261)

Depends on: Task 3 (parallel with 4a in another worktree only if the controller merges `lang.go` rows carefully — default: after 4a).

**Files:** `queries/{kotlin,bash,groovy,haskell,erlang,clojure,julia,nim,objc,perl,zig,sql,hcl,proto,graphql}.scm`, fixtures, rows.

**Test cases (tagged):**
- [ ] each fixture golden; Kotlin covers class, object, interface, fun, extension fun, property.
- [ ] SQL: `CREATE TABLE`, `VIEW`, `INDEX`, `TRIGGER` names as `type`/`const`; a migration file with goose comments parses the statements after them.
- [ ] HCL: `resource "aws_x" "name"` → name `aws_x.name`; `module`, `variable`, `output`, `data`.
- [ ] Protobuf: message, enum, service, rpc (container = service).
- [ ] Bash: `foo() {` and `function foo {` both found.

### Task 4c: Markup/config outlines (#261)

Depends on: Task 4a.

**Files:** `extract_outline.go` (YAML/TOML/JSON top-level keys, Markdown already in T1), rows for HTML/CSS/SCSS/Dockerfile (language only, no symbols), Svelte/Vue `<script>` injection with the JS/TS query.

**Test cases:**
- [ ] YAML/TOML/JSON top-level keys as `field`, nested keys not listed.
- [ ] outline kinds are flagged `outline:true` in the record (new optional field) so Swift keeps them out of Open Quickly's Symbols scope.
- [ ] Vue: `<script setup lang="ts">` function found with the line number in the `.vue` file, not the block.
- [ ] HTML/CSS: `lang` set, zero symbols, no error.

---

### Task 5: `CodeIndexCenter` and matching (#264)

Spec §7. Depends on: Tasks 1, 2.

**Files:**
- Create Core: `WatchtowerCore/Services/CodeNav/{CodeSymbol.swift,CodeIndexStream.swift (JSON-line decoder),FuzzyMatch.swift,CodeRanking.swift}`; tests `Tests/Core/CodeNav/*Tests.swift`
- Create: `Sources/Services/CodeIndexCenter.swift` (on `AppState`), `Sources/Services/CodeCLIProcess.swift` (spawn at `.utility`, line reader, kill+reap)
- Modify: `AppState` (owns the center), `CodeFilesCenter` (forward `FolderWatcher` batches), `Tests/Support` (hidden-names fixture test reading `internal/codewalk/testdata/hidden_names.json`)

**Interfaces:**
- Produces: `CodeSymbol` (Codable mirror of spec §6.1 + `outline`), `CodeIndexState` = `.idle | .indexing(done: Int, total: Int) | .ready | .failed(String)`.
- Produces: `CodeIndexCenter.index(for workbenchID: Int64) -> WorkbenchCodeIndex` with `files: [String]`, `symbols(named:) -> [CodeSymbol]`, `symbols(in path:) -> [CodeSymbol]`, `state`, `query(_ text: String, scope: CodeSearchScope, boosts: CodeRankingBoosts) -> [CodeQuickResult]`.
- Produces: `FuzzyMatch.score(query:candidate:) -> (score: Int, matched: [Int])?`, `CodeRanking.rank(...)`.
- Produces: `CodeSearchRun.start(folder:options:onMatch:onDone:)`, `cancel()` (used by Tasks 6, 8, 12).

**Test cases:**
- [ ] Core: `cfbuf` → `CodeFileBuffer` scores above `ConfigBuffer`; `vm/cfb` matches `ViewModels/CodeFileBuffer.swift`; empty query returns boosts order; case-smart as in search.
- [ ] Core: ranking order open tab > recent > git-modified > rest; kind order type > method/function > others; ties stable.
- [ ] Core perf: synthetic 3 000 files / 30 000 symbols, 20 queries, each ≤ 50 ms (`measure` with a hard assert on the max).
- [ ] stream decoder: partial line across reads; a malformed line is skipped and counted, never crashes; `deleted` removes the file's symbols.
- [ ] center: start → navigate away (workbench off screen) → back within 5 min keeps the same index (no full run); after 5 min idle it is released.
- [ ] center: watcher batch → after 300 ms debounce exactly one `--serve` request with those paths; a second batch during that run is queued and merged, results applied in order (Review Focus 3).
- [ ] center: rescan event → full run; CLI exits non-zero → `.failed(message)` with stderr text.
- [ ] hidden-names fixture equals `CodeFileTree.hiddenNames`.

---

### Task 6: Open Quickly panel (#265)

Spec §8.1, §10. Depends on: Task 5.

**Files:** `Sources/Views/Workbench/CodeNav/{OpenQuicklyPanel.swift (NSPanel host),OpenQuicklyView.swift,OpenQuicklyRow.swift,OpenQuicklyPreview.swift,DoubleShiftMonitor.swift}`, `CodeKindBadge.swift` (colours from `wt-light`/`wt-dark` tokens, shared with Tasks 7–9), Core `OpenQuicklyModel.swift` (sections, caps, selection) + tests; menu commands in the app's command group.

**Test cases:**
- [ ] Core: All scope = Best match + Symbols(8) + Files(8) + Text(20, "more…"), last row "✦ Ask AI: "q"" ; switching scope keeps the query; ↑/↓ wrap off at ends.
- [ ] Core: double-Shift detector — two Shift downs ≤ 300 ms → fire; Shift, `a`, Shift → no; three Shifts → one fire.
- [ ] Core: outline symbols (`outline:true`) excluded from Symbols scope.
- [ ] ⇧⌘F opens with scope Text; panel not shown when no workbench is on screen (command disabled).
- [ ] Return on a symbol opens a preview tab at its line; ⌥Return opens in the other pane, creating the split; Esc closes, focus returns to the editor.
- [ ] Text scope uses `CodeSearchRun`; typing cancels the previous run (kill observed) after 120 ms debounce.
- [ ] Space toggles Quick Look for a file row; on a symbol or text row it previews the row's file; the preview pane shows doc + 12 lines (symbol) or 3 lines around (text) in theme colours.

---

### Task 7: Go to definition and history (#266)

Spec §8.2, §8.5. Depends on: Task 6 (`CodeKindBadge`), Task 5.

**Files:** `CodeEditorWeb/index.html` (messages `definition`, `cursor`, `definitionDone`, `reveal`; ⌘-hover underline; Monaco's own bindings for spec §10 chords removed), `CodeFilesPaneView.swift` Coordinator, Core `DefinitionCandidates.swift`, `NavigationHistory.swift` + tests, `Sources/Views/Workbench/CodeNav/DefinitionMenu.swift`; extend `scripts/editor-bridge-check.swift` with the new messages.

**Test cases:**
- [ ] Core: candidate order same file → same folder → same top-level folder → rest, then kind order.
- [ ] Core: history push/back/forward, cap 100, a jump after back truncates forward.
- [ ] bridge harness: ⌘-click posts `definition {req,id,word,line,col}`; `definitionDone(req)` clears the underline; a reply for an older `req` is ignored; `reveal` on a line with an emoji puts the cursor on the name (Review Focus 2).
- [ ] one candidate → kept tab, cursor on name; several → menu lists all with "Show All Usages…" last; none → heuristic fallback, then "No definition of `w`" in the jump bar area for 2 s.
- [ ] ⌃⌘← after a jump returns to the exact line and column.

---

### Task 8: Usages inspector (#267)

Spec §8.3. Depends on: Task 7.

**Files:** `Sources/Views/Workbench/CodeNav/{CodeInspector.swift (tabs Usages | Questions),UsagesView.swift}`, Core `UsagesModel.swift` + tests; `CodeFilesPaneView` `.inspector` host; ⇧⌘U command.

**Test cases:**
- [ ] Core: grouping by file in arrival order, counts, header "Usages — name · N"; a new query clears and cancels the old run.
- [ ] ⇧⌘U on a word starts `code search --word --case`; context menu and "Show All Usages…" do the same.
- [ ] click on a row opens the file at the line; collapsing a group survives new arrivals.

---

### Task 9: Jump bar (#268)

Spec §8.4. Depends on: Task 7 (`cursor` message).

**Files:** `Sources/Views/Workbench/CodeNav/{JumpBar.swift,JumpBarMenus.swift}`, Core `JumpBarSegments.swift` + tests; replaces the path line in `CodeFilesPaneView` keeping git mark and Saved/Edited.

**Test cases:**
- [ ] Core: segments for a cursor inside a method of a nested type = folders › file › outer › inner › method; on a blank line between methods = folders › file › type.
- [ ] Core: unsupported language → trailing "Language X: text search"; `.failed` index → the failure text instead.
- [ ] ⌃6 opens the last segment's menu with a filter field; ‹ › reflect history availability.
- [ ] git mark and Saved/Edited still shown (snapshot of the previous path line's states).

---

### Task 10: AI read-folder runs and `CodeQuestionSurface` (#270)

Spec §9.1, §9.4 storage. Depends on: none for the Go part; Swift part after Task 5.

**Files:**
- Go: `cmd/ai.go` (`--read-folder`), `internal/ai/client.go` (a `ReadFolder` option: cwd + `ReadOnlyFolderDisallowedTools` = `DisallowedTools` minus `Read,Grep,Glob,LS`), `internal/codex/client.go` (`--cd DIR` + read-only sandbox), tests.
- Swift: `Sources/Services/ChatSurfaces/CodeQuestionSurface.swift`, `WatchtowerAIService` arguments, Core `CodeQuestionContext.swift` (first-turn context builder) + tests; model picker reused from the main chat composer.

**Interfaces:**
- Produces: `CodeQuestionSurface.spec(workbench:, origin: CodeQuestionOrigin, conversationID:, dbPool:) -> ChatSurfaceSpec`; `CodeQuestionOrigin{path, line, selection?}`; context_type `"code_question"`, context_id `"<workbench>:<path>:<line>"`.

**Test cases:**
- [ ] Go: `--read-folder` with a path that is not a workbench folder → exit 2; with one → claude argv has cwd = folder, `--disallowedTools` lacks `Read`,`Grep`,`Glob`,`LS` and still has `Edit`,`Write`,`Bash`,`WebFetch`,`WebSearch`,`Task`; no `--tools chat` mount.
- [ ] Go: codex argv has `--cd <folder>` and the read-only sandbox flag; ollama run has no file tools and the surface shows the one-time notice.
- [ ] Go: without `--read-folder` the argv is byte-identical to today (golden).
- [ ] Core: context = folder name, path, lang, selection or cursor line, ±40 lines clipped at file edges, ≤ 10 uniquely resolved index entries; an empty selection uses the cursor line.
- [ ] Surface: `toolAccess == .draftOnly`, persistence `.database`, chosen model stored on the conversation and kept on a follow-up.
- [ ] **Guard (Review Focus 5):** a `code_question` conversation with messages is absent from `ChatConversationQueries` list and title search, `ChatSearchQueries` FTS, and the Go chat history/search tools.

---

### Task 11: Popover at the selection (#271)

Spec §9.2, §8.5 (`selection`, `askAI`, `selectionRect`, `proposeEdit`, `clearProposal`, `applyEdit`). Depends on: Task 10.

**Files:** `index.html` (new messages + inline diff decoration), Coordinator, `Sources/Views/Workbench/CodeNav/{AskAIButton.swift,CodeQuestionPopover.swift}`, Core `WtEditBlock.swift` (parse the `wt-edit` fence) + tests, harness extension.

**Test cases:**
- [ ] Core: `wt-edit` parser — one block → replacement; none → no Apply; two blocks → first only; an unterminated block while streaming → none.
- [ ] ✦ appears 0.5 s after the selection settles; hidden while typing, on scroll, on clear (timer-driven test with an injected clock).
- [ ] ⌘I with no selection → context is the cursor line.
- [ ] Apply: refused with a message when the buffer is in conflict or the selected text changed since the question; otherwise one undoable edit, then the normal autosave `text` message (harness).
- [ ] Esc closes; the conversation is listed in Questions.

---

### Task 12: Answer in Open Quickly and the Questions tab (#272)

Spec §9.3, §9.4. Depends on: Tasks 6, 8, 11.

**Files:** `OpenQuicklyView` answer card, `Sources/Views/Workbench/CodeNav/QuestionsView.swift`, Core `CodeQuestionList.swift` (query over `chat_conversations` by workbench) + tests.

**Test cases:**
- [ ] ⌘Return in Open Quickly creates a `code_question` conversation (no selection; the open file named in context) and renders the answer in the panel; Return follows up.
- [ ] link click opens the file and closes the panel.
- [ ] Questions lists this workbench's conversations only, newest first, with origin `path:line`; Delete removes the conversation and its messages.
- [ ] "Pin to inspector" moves the open popover conversation into the inspector, same engine (no second turn started).

---

### Task 13: Hand to Claude Code and terminal links (#273)

Spec §9.5. Depends on: Task 12.

**Files:** `Sources/Views/Workbench/CodeNav/HandToClaudeSheet.swift`, `TerminalCenter` (reuse `sendPrompt`), Core `HandoffText.swift`, `TerminalPathLinks.swift` + tests; SwiftTerm link hook in `WorkbenchSessionView`.

**Test cases:**
- [ ] Core: hand-off text = "From a Watchtower code question:" + question + answer text + `path:line` refs, never file bodies (a fenced code block from the answer is kept as the answer's text, the selection's source is not appended).
- [ ] running session → `sendPrompt` called once, then Return; New session → started with the text as first prompt; terminal pane opened with `Placement.keeping`.
- [ ] Core link matcher: `Sources/A.swift:12`, `./x/y.go:3:7`, `a b.txt:1` (quoted) resolve; a path outside the session folder or a non-existent file is not a link; `http://host:80` is not a path link.

---

### Task 14: Regex rules and heuristic (#269, low)

Spec §6.5. Depends on: Task 1 (Go), Task 7 (Swift fallback).

**Files:** `internal/codeindex/rules.go` + tests (loads `~/Library/Application Support/Watchtower/code-languages.yaml`, path injectable), `heuristic.go`; Swift: jump bar message for a rules error.

**Test cases:**
- [ ] valid rules file: `tcl` `proc foo` → function `foo`; rules apply only to their extensions and never override a grammar language.
- [ ] invalid YAML or an invalid RE2 pattern → whole file ignored, error surfaced as "Rules file: <error>" in `done` (`rules_error`) and the jump bar; no partial load.
- [ ] heuristic: `def foo` line ranked before a plain `foo` occurrence; works on a file with no language.
