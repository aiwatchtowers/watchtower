# Session Chat Feed Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the dialog of a workbench agent session (owner messages, agent text, ask answers, subagents) as a chat, built from the Claude Code transcript without AI: a Go reader + CLI (phase 1), a Mac pane (phase 2), the iPhone (phase 3, stub).

**Architecture:** A new pure Go package `internal/sessionfeed` parses transcript JSONL into typed entries; the cmd layer resolves a terminal session to its transcripts (a new ledger table keeps every Claude session id a tab had), joins ask answers from `owner_asks`, and prints text or pinned JSON. The Desktop runs that CLI (no Swift twin of the filter) and renders the feed in a new workspace pane, polling with a cursor while it is visible.

**Tech Stack:** Go 1.26, cobra, `modernc.org/sqlite` via `internal/db`, goose migrations; SwiftUI + `WatchtowerCore` (`CLIRunnerProtocol`).

**Spec:** `docs/superpowers/specs/2026-10-16-session-chat-feed-design.md` (approved, ask #224; mockup approved, ask #225: https://claude.ai/artifact/1EAYTPBmtEHkRBkRUhpYYh)

## Global Constraints

- No transcript text is stored in SQLite (AGENTLOG-01 stays as it is). The ledger stores ids and times only.
- Read-only on transcript files: open for read, never write, lock or rename (as AGENTLOG-05).
- No AI calls anywhere in this feature.
- Claude Code only in v1; reader types must not assume Claude so Codex can be added (entry kinds are agent-neutral).
- Tests use fabricated JSONL records only — no live transcripts, ids, paths or names (public repo hygiene; `leak-check:allow` only on deliberate fakes).
- Line limit: reuse `agentlog`'s `maxLineBytes` (8 MiB) semantics — an overlong line is skipped and counted, never fatal.
- Inner loop per task: `go test ./internal/<pkg>`, `go test ./cmd -run <Name>`, `make test-swift FILTER=<Class>`, `make lint-diff`, `make lint-swift` for Swift tasks. Full gate once at the end of each phase.
- Docs in English; owner-facing strings in the Desktop follow the app's existing localisation (English UI copy).

## Review Focus

1. A session with `/clear` in the middle: the feed shows both conversations with a separator, in order — tested in Task 4.
2. A streamed assistant message written several times: exactly one entry, last text wins, and `--after` re-emits it with the same id — Task 2 and Task 4.
3. A transcript line cut mid-write while the session runs (no trailing newline): not parsed, cursor stays before it, next call picks it up — Task 2.
4. An `Ask #N answered` line whose ask is missing or belongs to another workbench: shown as an owner message with the raw line, never an error, never another workbench's answer — Task 4.
5. A subagent whose `meta.json` is missing or unreadable: the marker still appears (description from the `Agent` call input), status `unknown`, drill-in shows the task only — Task 3.

---

## Phase 1 — Go reader and CLI

### Task 1: Ledger of a tab's Claude sessions

**Files:**
- Create: `internal/db/migrations/00124_terminal_session_agent_sessions.sql`
- Create: `internal/db/terminal_session_agent_sessions.go`, `internal/db/terminal_session_agent_sessions_test.go`
- Modify: `internal/db/terminal_sessions.go` (`SetTerminalClaudeSessionID` at ~248, and the insert that creates a claude/codex row with an id), `internal/db/schema.sql`, `internal/db/db_test.go` (`TestAllTablesExist`), golden snapshot + `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (regenerate)

**Interfaces:**
- Produces:
  - table `terminal_session_agent_sessions(terminal_session_id INTEGER NOT NULL REFERENCES terminal_sessions(id) ON DELETE CASCADE, agent_session_id TEXT NOT NULL, first_seen_at TEXT NOT NULL, PRIMARY KEY (terminal_session_id, agent_session_id))`
  - `type TerminalAgentSession struct { AgentSessionID string; FirstSeenAt time.Time }`
  - `func (db *DB) ListTerminalAgentSessions(terminalSessionID int64) ([]TerminalAgentSession, error)` — ordered by `first_seen_at`, then rowid
- The migration backfills one row per existing `terminal_sessions` row with a non-NULL `claude_session_id` (`first_seen_at` = `created_at`).

Use the `add-migration` skill.

- [ ] **Step 1: Failing tests** in `terminal_session_agent_sessions_test.go`:
  - `TestTerminalAgentSessions_RecordsEachID`: create a claude terminal session with id `s-1`, call `SetTerminalClaudeSessionID` with `s-2`, then `s-2` again, then `s-3`; `ListTerminalAgentSessions` returns `["s-1","s-2","s-3"]` in that order.
  - `TestTerminalAgentSessions_CascadeOnDelete`: delete the workbench; the ledger has no rows (PROJ-02).
  - `TestMigration00124_Backfill`: a row present before the migration gets exactly one ledger row.
- [ ] **Step 2:** `go test ./internal/db -run 'TerminalAgentSessions|Migration00124'` → FAIL.
- [ ] **Step 3:** Migration + `INSERT OR IGNORE` into the ledger in the same transaction as the id write (the session-create path and `SetTerminalClaudeSessionID` when it returns true). Mirror into `schema.sql`, add to `TestAllTablesExist`, run `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`.
- [ ] **Step 4:** `go test ./internal/db` → PASS; also `go test ./cmd -run 'Proj02|SessionStart'`.
- [ ] **Step 5:** Commit `feat(db): remember every agent session id a terminal tab had`.

### Task 2: Transcript → entries (main conversation)

**Files:**
- Create: `internal/sessionfeed/entry.go`, `internal/sessionfeed/parse.go`, `internal/sessionfeed/parse_test.go`, `internal/sessionfeed/testdata_test.go` (record builders)

**Interfaces:**
- Produces:
```go
type Kind string // "owner", "agent", "ask_answer", "watchtower", "brief", "subagent", "separator"
type Entry struct {
    ID        string    // record uuid, assistant message id, tool_use id, or "<conv>:sep"
    Kind      Kind
    At        time.Time
    Text      string    // owner/agent/watchtower/brief text; empty for subagent/separator
    AskID     int64     // ask_answer only
    Title     string    // ask_answer only, filled in Task 4
    Via       string    // "review", "handoff" for kind watchtower
    Subagent  *SubagentRef // subagent only (Task 3)
    Conversation string // the agent session id the entry came from
}
type Result struct { Entries []Entry; Offset int64; Skipped int; Unknown map[string]int }
func Parse(r io.Reader, startOffset int64, conv string) (*Result, error)
```
- `Offset` = byte offset after the last complete (newline-terminated) line.

Rules (from the spec and the spike):
- `user`, not `isMeta`, not `isCompactSummary`, content a string or `text` blocks with no `tool_result` → strip every `<system-reminder>…</system-reminder>`, trim; empty → drop. Image blocks append `[image]`.
- Starts with `<command-name>` → owner entry `/name args` from `<command-name>`/`<command-args>`; `<local-command` or `[Request interrupted` → drop.
- `^Ask #(\d+) answered ` → `ask_answer` with `AskID`, `Text` = the raw line (Task 4 replaces it).
- Starts with `Review round #` (`reviewdiff.DeliveryLine`) → kind `watchtower`, `Via` `review`; starts with `From a Watchtower code question:` → kind `watchtower`, `Via` `handoff`. Text kept as typed.
- `assistant`, not `isSidechain`: concatenate `text` blocks per `message.id` (blank line between); one entry per message id, placed where the id first appears, text = the latest record's text. `thinking` and `tool_use` never produce text.
- `attachment` `hook_success` with `hookEvent` `SessionStart` and `stdout` starting `Watchtower workbench #` → `brief`.
- Any other type → `Unknown[type]++` only for types not in a known-ignored list (`attachment`, `system`, `mode`, `permission-mode`, `file-history-snapshot`, `ai-title`, `last-prompt`, `api-request*`, `cost-state`, `pr-link`, `summary`).

- [ ] **Step 1: Failing tests** (`parse_test.go`), each with fabricated lines:
  - `TestParse_OwnerAndAgentOnly`: owner string, assistant `[thinking, text "A", tool_use]`, user `tool_result`, meta user → entries `[owner, agent "A"]`.
  - `TestParse_StreamedMessageOnce`: three assistant records with the same `message.id` and growing text → one entry, final text, position of the first.
  - `TestParse_StripsSystemReminder`: owner text `"hi<system-reminder>x</system-reminder>"` → `"hi"`; reminder-only text → no entry.
  - `TestParse_SlashCommand`: `<command-name>/review</command-name><command-args>42</command-args>` → owner `"/review 42"`.
  - `TestParse_WatchtowerLines`: ask line → `ask_answer` AskID 7; review line → `watchtower`/`review`; handoff header → `watchtower`/`handoff`.
  - `TestParse_Brief`: SessionStart `hook_success` with Watchtower stdout → `brief`; another SessionStart stdout → nothing.
  - `TestParse_PartialLastLine`: input ends without `\n` → that line not parsed, `Offset` = end of the previous line (Review Focus 3).
  - `TestParse_StartOffset`: parsing from a mid-file offset returns only later entries.
  - `TestParse_OverlongLineSkipped`: a line over the limit → `Skipped == 1`, later lines parsed.
- [ ] **Step 2:** `go test ./internal/sessionfeed` → FAIL.
- [ ] **Step 3:** Implement. Reuse the line reader approach of `agentlog.nextLine`; if exporting it is cleaner than copying, export it from `agentlog` (one small change, no behaviour change there).
- [ ] **Step 4:** `go test ./internal/sessionfeed` → PASS; `make lint-diff`.
- [ ] **Step 5:** Commit `feat(sessionfeed): parse a transcript into chat entries`.

### Task 3: Subagent markers and subagent feeds

**Files:**
- Create: `internal/sessionfeed/subagent.go`, `internal/sessionfeed/subagent_test.go`
- Modify: `internal/sessionfeed/parse.go`, `entry.go`

**Interfaces:**
- Consumes: `Parse`, `Entry` (Task 2).
- Produces:
```go
type SubagentRef struct {
    ToolUseID, AgentID, Type, Description string
    Status string // "running", "finished", "unknown"
    ParentReport string // the parent's tool_result text for this call; not in JSON
}
// Markers: Parse emits a subagent entry for each `Agent` tool_use (ID = tool_use id,
// Type = input.subagent_type or "general-purpose", Description = input.description).
func ResolveSubagents(sessionDir string, entries []Entry) []Entry // fills AgentID + Status from <sessionDir>/subagents/*.meta.json by toolUseId
func ParseSubagent(path string, parentReport string) (*Result, error)
```
- A subagent's feed: first entry kind `owner` with the task (first `user` string record of the subagent file), then its `agent` entries, then the report as the last `agent` entry: the subagent's own `SubagentHandback` tool_use `input.message` if present, else `parentReport` (the parent's `tool_result` text for that `Agent` call — `Parse` records it on the marker so the caller can pass it).
- Nested: a subagent file's own `Agent` calls become markers inside its feed the same way.

- [ ] **Step 1: Failing tests:**
  - `TestSubagent_MarkerFromAgentCall`: parent with an `Agent` tool_use → one `subagent` entry, Type/Description from input.
  - `TestSubagent_StatusFromMeta`: meta `finished:true` → `finished`; `finished:false` → `running`; no meta → `unknown` (Review Focus 5).
  - `TestSubagent_FeedTaskRepliesReport`: subagent file with task, `text` reply, `SubagentHandback{message:"R"}` → `[owner task, agent reply, agent "R"]`.
  - `TestSubagent_ForegroundReportFromParent`: no handback, parent `tool_result` "P" → last entry `agent "P"`.
- [ ] **Step 2:** `go test ./internal/sessionfeed -run Subagent` → FAIL.
- [ ] **Step 3:** Implement; read meta files with `os.Lstat` first and skip symlinks (as agentlog does).
- [ ] **Step 4:** `go test ./internal/sessionfeed` → PASS.
- [ ] **Step 5:** Commit `feat(sessionfeed): subagent markers and drill-in feeds`.

### Task 4: Whole-tab feed, cursor, ask answers

**Files:**
- Create: `internal/sessionfeed/feed.go`, `internal/sessionfeed/feed_test.go`

**Interfaces:**
- Consumes: Tasks 1–3; `agentlog.DefaultClaudeDir`, `agentlog.CandidateDirs`, `agentlog.ListTranscripts`, `agentlog.WorktreeRoots`; `db.GetOwnerAsk(workbenchID, id)`; `asks.Render(kind, payload, answer)`.
- Produces:
```go
type Conversation struct { AgentSessionID, Path string }
type Cursor struct { Conv string; Offset int64 } // encoded "conv:offset"
func ParseCursor(s string) (Cursor, error)
func (c Cursor) String() string
type AskLookup func(id int64) (title, answerText string, ok bool)
type Feed struct { Entries []Entry; Subagents []Entry; Cursor Cursor; Skipped int; Unknown map[string]int }
func Build(convs []Conversation, after *Cursor, asks AskLookup) (*Feed, error)
func Locate(claudeDir string, folderRoots []string, agentSessionID string) (path string, ok bool)
```
- `Build` walks conversations in ledger order; with `after`, skips conversations before `after.Conv` and starts that one at `after.Offset`. A `separator` entry (ID `<conv>:sep`) precedes every conversation but the first. `Subagents` always carries every subagent marker of all conversations read so far with fresh status (callers upsert them; this is how running→finished reaches a caller that polls with `after`). A missing transcript file is skipped (no entries), not an error.
- `ask_answer`: when `asks(id)` is ok, `Text` = rendered answer and `Title` = the ask title; not ok → kind stays `ask_answer`, `Text` the raw line (Review Focus 4). The cmd layer builds `AskLookup` with the session's own workbench id, so another workbench's ask is never found.
- Entries that changed after an earlier call are re-emitted with the same ID; callers upsert by ID (spec "Entries that change").

- [ ] **Step 1: Failing tests:**
  - `TestBuild_TwoConversationsWithSeparator`: two files → entries of A, separator, entries of B (Review Focus 1).
  - `TestBuild_AfterCursor`: cursor at end of A's 2nd line → only later entries; a streamed message continued after the cursor is re-emitted with its original ID (Review Focus 2).
  - `TestBuild_SubagentsAlwaysListed`: `after` past the `Agent` call → `Subagents` still has the marker with current status.
  - `TestBuild_AskLookup`: found → rendered text + title; not found → raw line.
  - `TestCursor_RoundTrip` and `TestParseCursor_Rejects` (`""`, `"x"`, `"a:-1"`).
  - `TestLocate_FindsInCandidateDirs`: a temp projects dir with `<slug>/<uuid>.jsonl` → found; unknown uuid → not ok.
- [ ] **Step 2:** `go test ./internal/sessionfeed -run 'Build|Cursor|Locate'` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `go test ./internal/sessionfeed` → PASS.
- [ ] **Step 5:** Commit `feat(sessionfeed): whole-tab feed with cursor and ask answers`.

### Task 5: `watchtower workbench session-feed`

**Files:**
- Create: `cmd/workbench_session_feed.go`, `cmd/workbench_session_feed_test.go`

**Interfaces:**
- Consumes: Task 1 `ListTerminalAgentSessions`, Task 4 `Build`/`Locate`/`ParseCursor`, `db.GetTerminalSession`.
- Produces the CLI contract the Desktop and the phone use:
  - `watchtower workbench session-feed --session <terminal id> [--after <cursor>] [--subagent <tool_use id>] [--json]`
  - JSON object with exactly the keys `session_id`, `cursor`, `entries`, `subagents`, `skipped`, `unknown_records`; each entry exactly `id`, `kind`, `at` (RFC 3339), `text`, `conversation`, plus `ask_id`, `title` (ask_answer), `via` (watchtower), `subagent` {`tool_use_id`,`agent_id`,`type`,`description`,`status`} only on their kinds (omitempty).
  - `--subagent` returns that subagent's feed in the same shape (`subagents` = its nested markers; `cursor` empty — the drill-in is re-read whole).
  - Plain output: `HH:MM  You:` / `HH:MM  Agent:` / `HH:MM  Ask #N answered — <title>` / `── new conversation ──` / `HH:MM  Subagent <type>: <description> [<status>]`, text indented under the header; the brief prints as one line `Watchtower: brief`.
  - Errors: unknown session → exit 1 `session N not found`; a shell session → exit 1 `session N is not an agent session`; a codex session → exit 1 `session N: codex sessions are not supported yet`.

- [ ] **Step 1: Failing tests:**
  - `TestSessionFeedJSON_PinnedKeys` (pattern of `TestAgentsStatsJSON_PinnedKeys`): top-level and entry key sets exactly as above.
  - `TestSessionFeed_TabAcrossClear`: a session whose ledger has two ids with fake transcripts under a temp `HOME`/claude dir → JSON has a `separator` between them.
  - `TestSessionFeed_AskFromOwnWorkbenchOnly`: an ask with the same id in another workbench is not used.
  - `TestSessionFeed_Errors`: unknown id, shell row, codex row → messages above.
- [ ] **Step 2:** `go test ./cmd -run SessionFeed` → FAIL.
- [ ] **Step 3:** Implement; register with `workbenchCmd.AddCommand` like `workbench_session_report.go`. Open the DB read-only (`BeginTx` ReadOnly / no writes at all). Folder roots = the session's `folder_path` plus `agentlog.WorktreeRoots`.
- [ ] **Step 4:** `go test ./cmd -run SessionFeed` and `go test ./internal/sessionfeed` → PASS; `make lint-diff`.
- [ ] **Step 5:** Commit `feat(cmd): workbench session-feed`.

**Phase 1 gate (controller):** `make test`, `make lint`, `go test ./cmd/...`; run `watchtower workbench session-feed --session <a real session>` locally and read it against the terminal (do not paste its output anywhere in the repo).

## Phase 2 — Mac pane

### Task 6: Swift feed model and merge

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Models/SessionFeed.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/SessionFeedStore.swift`
- Test: `WatchtowerDesktop/Tests/Core/SessionFeedStoreTests.swift`

**Interfaces:**
- Consumes: the Task 5 JSON; `CLIRunnerProtocol.run(args:)`.
- Produces:
```swift
package struct SessionFeedEntry: Decodable, Identifiable, Equatable { id, kind, at, text, conversation, askID?, title?, via?, subagent: SessionFeedSubagent? }
package struct SessionFeedPayload: Decodable { sessionID: Int64; cursor: String; entries: [SessionFeedEntry]; subagents: [SessionFeedEntry] }
@MainActor package final class SessionFeedStore: ObservableObject {
    @Published package private(set) var entries: [SessionFeedEntry]
    @Published package private(set) var error: String?
    package init(sessionID: Int64, runner: CLIRunnerProtocol)
    package func refresh() async        // runs with --after <cursor> once a cursor exists
    package func subagentFeed(_ toolUseID: String) async throws -> [SessionFeedEntry]
}
```
- Merge: upsert by `id` keeping first position; markers from `subagents` upsert the same way. An unknown `kind` decodes and is not shown (forward compatible).

- [ ] **Step 1: Failing tests:** `testDecodesPinnedPayload` (fixture JSON with every kind), `testRefreshUpsertsByID` (second payload re-emits id `m1` with longer text → one entry, new text, same index), `testSubagentStatusUpdatedFromSubagentsList`, `testUnknownKindIgnored`, `testRunnerFailureSetsError` (fake runner throws `nonZeroExit` → `error` set, entries kept).
- [ ] **Step 2:** `make test-swift FILTER=SessionFeedStoreTests` → FAIL.
- [ ] **Step 3:** Implement; args `["workbench","session-feed","--session",id,"--json"]` + `["--after",cursor]`.
- [ ] **Step 4:** `make test-swift FILTER=SessionFeedStoreTests` → PASS; `make lint-swift`.
- [ ] **Step 5:** Commit `feat(desktop): session feed model and store`.

### Task 7: Chat pane in the workbench

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Workbench/SessionChatView.swift`, `WatchtowerDesktop/Sources/Views/Workbench/SessionChatSubagentSheet.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/WorkspaceLayout.swift` (`WorkspacePane.sessionChat(Int64)`), `WatchtowerDesktop/Sources/Views/Workbench/WorkspacePaneView.swift` (switch case), `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel+Panel.swift` (open beside the session like `.sessionReport`), the session row / session header menu (entry point **Show Chat**)
- Test: `WatchtowerDesktop/Tests/Core/WorkspaceLayoutTests.swift` (add cases)

**Interfaces:**
- Consumes: `SessionFeedStore` (Task 6).
- Layout per the approved mockup: owner text right in a tinted bubble; agent text left, no bubble, rendered as Markdown (`AttributedString(markdown:)` with `.inlineOnlyPreservingWhitespace`, code blocks monospaced); `ask_answer` as an owner bubble with "Ask #N" label, title, answer text, caption "via Watchtower"; `watchtower` as an owner bubble with caption "via Watchtower"; `brief` as one centered collapsed row "Watchtower: brief" (DisclosureGroup); `separator` as a centered "New conversation" rule; `subagent` as a card (type, description, status) opening `SessionChatSubagentSheet` (task, replies, report).
- Behaviour: opens scrolled to the bottom; while the pane is visible, `refresh()` every 3 s if the session agent state is working/agents-working, else once on appear and when `SessionAgentStateCenter` reports a change; stops when the pane disappears. An error shows inline with a Retry button; entries already shown stay.

- [ ] **Step 1: Failing tests:** `WorkspaceLayoutTests` — `.sessionChat(id)` round-trips through the layout's persistence and closes with its session like `.sessionReport`.
- [ ] **Step 2:** `make test-swift FILTER=WorkspaceLayoutTests` → FAIL.
- [ ] **Step 3:** Implement the pane case, views and entry point; follow `docs/review/review-rules.md` "Swift / Desktop conventions" (task cancellation on disappear, no work in `body`).
- [ ] **Step 4:** `make test-swift FILTER='WorkspaceLayoutTests|SessionFeedStoreTests'` → PASS; `make lint-swift`; launch the app (`run` skill) and open Show Chat on a live session.
- [ ] **Step 5:** Commit `feat(desktop): session chat pane`.

### Task 8: Contracts and docs

**Files:**
- Create: `docs/features/session-chat-feed.md`, `docs/inventory/session-feed.md`
- Modify: `docs/inventory/README.md`, `CLAUDE.md` (Feature Notes line), `docs/inventory/workbench.md` (changelog line: the ledger, PROJ-02 still holds)

Contracts (new ids, guard tests already written above):
- FEED-01 No transcript text in SQLite; the reader is read-only on transcripts — guard: a test in `internal/sessionfeed` that opens the fixture read-only and checks mtime unchanged, plus `TestTerminalAgentSessions_*` showing ids only.
- FEED-02 The feed carries no tool calls, tool results, meta records or thinking — guard `TestParse_OwnerAndAgentOnly`.
- FEED-03 Pinned JSON keys — guard `TestSessionFeedJSON_PinnedKeys`.
- FEED-04 An ask answer comes only from the session's own workbench — guard `TestSessionFeed_AskFromOwnWorkbenchOnly`.

- [ ] **Step 1:** Write the docs; feature doc covers record rules, the cursor and upsert contract, the ledger, v1 limits (Claude only, no search, phone pending).
- [ ] **Step 2:** Commit `docs: session chat feed`.

**Phase 2 gate (controller):** `make test`, `make test-swift`, `make lint-all`; then the local-review skill and the PR.

## Phase 3 — iPhone (stub, re-plan before starting)

Goal: the same chat on the phone for recent sessions. To be planned against `docs/features/mobile-companion.md` with these fixed inputs: the Mac produces the feed by the Task 5 CLI/`internal/sessionfeed` (no second parser); records go in the E2E data envelope (≤ 900 000 bytes), so the phone receives the newest tail of a feed and older entries / subagent feeds on request via a relay action; the phone view follows the same mockup. Open questions for that plan: which sessions count as recent, tail size, how often the Mac republishes a live session.
