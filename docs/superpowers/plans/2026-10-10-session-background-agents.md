# Session state "Agents working" (board #411) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A workbench session whose main agent ended its turn while background subagents/workflows still run shows **Agents working** (green, pulsing, with the count) instead of Stopped / Waiting for you, and announces Stopped once when the background work is really over.

**Architecture:** The sync Stop hook snapshots `background_tasks` (types `subagent` + `workflow`) into two new `terminal_sessions` columns next to the stored `waiting`; later hook events (subagent `PostToolUse`, a new async `SubagentStop` state hook) can only refresh the report time or lower the count, and main-turn events / new runs clear it. No new `agent_state` value: the Desktop derives `.background` from "trusted `waiting` + live count" in `SessionAgentStatus.effective`, behind one staleness seam (`SessionBackgroundPolicy`) whose final shape is pending owner ask #140.

**Tech Stack:** Go 1.25 (`cmd/`, `internal/db`, `internal/devpack`), SQLite + goose migrations, SwiftUI / GRDB (WatchtowerCore + app target).

**Spec:** `docs/superpowers/specs/2026-10-10-session-background-agents-design.md` (source of truth, §9 = owner decisions) and `docs/superpowers/specs/2026-10-10-session-background-agents-business.md`. Executors read both before their task.

**Plan style (owner preference, overrides the skill's defaults):** no code bodies. Each task gives files, interfaces/signatures, test cases (name + what it asserts) and verification commands. Task-scope checks only; the full gate runs once, in the final task.

## Global Constraints

- Work only in the worktree `/Users/user/PhpstormProjects/watchtower-411`, branch `feat/411-background-agents`. Before every git command: `cd /Users/user/PhpstormProjects/watchtower-411 && git branch --show-current` must print `feat/411-background-agents`.
- What counts: `background_tasks` entries with `type` `subagent` or `workflow` (ask #138). `shell`, `monitor`, `teammate`, `cloud session`, `MCP task` and unknown types never count.
- Grace after the count reaches 0: **120 s** (ask #138). Staleness bound (count > 0, no report): **30 min**, then the probe — shape pending ask #140 (Tasks 10–11 only).
- `SubagentStop` state hook is installed (async, timeout 5, no matcher). `SubagentStart` is **not** installed.
- Older Claude Code without `background_tasks` in the Stop input: Stopped as today (no fallback).
- Label/glyph: caption "Agents working" / "1 agent working" / "N agents working"; with asks + " · 1 ask open" / " · N asks open"; glyph `person.2.fill` (no asks) or `questionmark` (asks open); tone `.green`; dot filled and pulsing, honouring Reduce Motion. UI strings English only.
- Ask #20 grant behaviour unchanged: after a granted subagent permission the row shows Working until the next Stop.
- State order (first match wins): approval > error > working > **background** > finished > open ask > stopped > running > not started.
- No new `agent_state` value; no change to the `agent_state` CHECK.
- Invariant (guarded): `agent_background` goes from NULL to a number only in the Stop's write; every other write leaves it, lowers it, or NULLs it. Subagent `PostToolUse` and `SubagentStop` never touch `agent_state`, `agent_state_at`, `finished_at`, `agent_turn_end`, `agent_tool_run`.
- Stamps: `agent_background_at` uses the `agent_state_at` layout (UTC, milliseconds); Swift parses it with the existing UTC `SessionAgentStatus.parseStamp`.
- Guard tests follow `TestProj11_*` / `testProj11_*` (`TestProj04_*`, `testProj12_*` where those contracts are touched). Existing guards are never weakened, renamed out of the convention or split; the subagent-`PostToolUse`-over-`waiting` guard is rewritten with equal strictness.
- Public repo: fixtures and docs carry no real session ids, agent ids, user names or local absolute paths (placeholders, `example`); `make hooks` must be installed in the worktree.
- Commit messages in English, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. No push from task implementers.
- Inner loop only per task (`go test ./internal/<pkg>`, `go test ./cmd -run '<regex>'`, `make test-swift FILTER=…`, `make lint-diff`). No `-count=1`. Logs to a file with an explicit exit code (`cmd > log 2>&1; echo "exit=$?"`), never piped through `tail`.
- Swift tasks (6, 7, 8, 10, 11) run strictly one at a time.

## Review Focus

1. **Grace/staleness expiry with no DB write.** Nothing writes when the 120 s grace or a staleness bound runs out; the row must still turn Stopped within one poll and post its one notice. Pinned in Task 6 (`testBackgroundEndsOnTheClockWithoutAWrite`, center level).
2. **A malformed `background_tasks` (null, an object, entries with non-string `type`) must never cost the Stop its `waiting`.** Pinned in Task 3 (`TestProj11_MalformedBackgroundTasksStillRecordWaiting`).
3. **A Stop that repeats the same non-zero count** (the main woke for a teammate message or one notification while the same N still run) is a state repeat, but it is a fresh report: it must refresh `agent_background_at`, or the staleness bound would fire on agents Claude Code just said are running. Pinned in Task 3 (`TestProj11_StopWithTheSameCountRefreshesTheReportTime`). (Spec §4.1 names the Stop among the reports the column records.)
4. **An unreadable or future `agent_background_at`** (clock skew, hand-edited DB) must read as no background (Stopped), never as background forever. Pinned in Task 6 (`testProj11_UnreadableOrFutureBackgroundStampIsNotBackground`).
5. **Down migration on a database holding a count.** `DROP COLUMN` on a column with its own CHECK must succeed and re-Up must restore both columns. Pinned in Task 1 (`TestMigration00106_DownDropsAndReUpRestoresTheColumns`).

---

## Task list

| # | Title | Depends on |
|---|---|---|
| 0 | Capture real Stop / SubagentStop inputs as redacted fixtures | none |
| 1 | Migration 00106: `agent_background`, `agent_background_at` | none |
| 2 | DB write path: snapshot, clear, `LowerTerminalBackground` | Task 1 |
| 3 | Stop hook stores the snapshot | Task 0, Task 2 |
| 4 | session-state hook: subagent heartbeat and `SubagentStop` | Task 3 |
| 5 | Hook pack: `SubagentStop` entry, core vs full state hooks | Task 4 |
| 6 | Swift Core: `.background` kind, row columns, staleness seam, clock | Task 1 |
| 7 | Swift presentation and notices | Task 6 |
| 8 | Hand-off and ask-answer guards for Agents working | Task 7 |
| 9 | Inventory (PROJ-11 amendment), feature notes, app guide | Task 5, Task 8 |
| 10 | Subagent transcript probe — **shape pending ask #140** | Task 8 |
| 11 | Staleness verdict wiring — **shape pending ask #140** | Task 9, Task 10 |
| 12 | Final gate | Task 11 |

Parallel lanes allowed by the dependencies: Task 0 ‖ Task 1; after Task 1, the Go lane (2 → 3 → 4 → 5) ‖ the Swift lane (6 → 7 → 8). Each lane in its own worktree/branch merged by the controller; never two implementers in one tree.

---

### Task 0: Capture real Stop / SubagentStop inputs as redacted fixtures

Pins the parse against what Claude Code actually sends and answers the spec's unverified facts (§2 "Not verifiable", Appendix A.6) where the capture can.

**Files:**
- Create: `cmd/testdata/stop_background_tasks.json` (a Stop input with ≥ 2 in-flight background subagents)
- Create: `cmd/testdata/subagentstop_background_tasks.json` (a `SubagentStop` of one of those subagents, with the parent's `background_tasks`)
- Create: `cmd/testdata/stop_no_background_tasks.json` (a Stop input with nothing in flight — expected `"background_tasks": []`)
- Modify: `docs/superpowers/specs/2026-10-10-session-background-agents-design.md` — add Appendix A.7 "Observed inputs (Claude Code <version>, 2026-10-xx)"

**Interfaces:**
- Consumes: none.
- Produces: the three fixture files (consumed by Tasks 3 and 4 tests by file name); A.7 answers (consumed by Task 3: whether to filter a `status` value; Task 4: whether the stopping subagent is listed in its own `SubagentStop` and whether task `id` equals `agent_id`).

- [ ] **Step 1: Set up a capture folder outside the repo.** In the scratchpad, make an empty folder with `.claude/settings.local.json` holding two command hooks, `Stop` and `SubagentStop`, each `cat > <capture dir>/<event>-$(date +%s%N).json` (plain shell, exits 0). Record `claude --version`.
- [ ] **Step 2: Produce the events.** In that folder run an interactive `claude` session (or `claude -p` first; if its Stop input carries no in-flight entries, use an interactive session) with a prompt asking it to launch two background subagents that each run `sleep 20` via Bash then report, a background `Bash` `sleep 30` (shell, must not count), and to end its turn immediately. Wait until both subagents finish and the main agent wakes and stops again.
- [ ] **Step 3: If capture is impossible from the agent's session** (no interactive TTY, CLI missing), raise one owner ask (via the workbench skill) with the exact two-step recipe above and stop the task until the files arrive. Do not invent fixtures.
- [ ] **Step 4: Redact.** Replace every `session_id` with `00000000-0000-4000-8000-000000000411`, every `agent_id`/task `id` with stable fakes (`agent-a`, `agent-b`, `task-shell-1`, keeping equal ids equal), paths with `/tmp/example/...`, `description`/`last_assistant_message` with neutral text. Keep every key, value type and `status` value as observed. Run `bash scripts/leak-check.sh` (or the pre-push hook path) over the new files.
- [ ] **Step 5: Write A.7.** One line per unverified fact: observed `status` values; whether the stopping subagent appears in its own `SubagentStop`'s `background_tasks`; whether a task `id` equals the subagent's `agent_id`; the `agent_type` of the user's subagents; whether `background_tasks` is present in an empty Stop. Facts the capture could not show stay "not observed".
- [ ] **Step 6: Verify.** `jq . cmd/testdata/stop_background_tasks.json cmd/testdata/subagentstop_background_tasks.json cmd/testdata/stop_no_background_tasks.json > /dev/null; echo "exit=$?"` → `exit=0`.
- [ ] **Step 7: Commit** `test(workbench): real Stop and SubagentStop inputs with background tasks (#411)`.

---

### Task 1: Migration 00106 — `agent_background`, `agent_background_at`

**Files:**
- Create: `internal/db/migrations/00106_terminal_session_background_agents.sql` (verify 00106 is still the next free number: `ls internal/db/migrations | tail -2` shows `00105_workbench_archive_now.sql` last; if main moved, renumber at merge)
- Modify: `internal/db/schema.sql` (the `terminal_sessions` block, after `agent_tool_run`, with one-line comments as in the spec §4.1)
- Regenerate: `internal/db/testdata/schema_v73.golden`, `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`
- Modify: `internal/db/terminal_sessions.go` — `TerminalSession` gains the two fields; `GetTerminalSession` selects them
- Create: `internal/db/terminal_background_migration_test.go`

**Interfaces:**
- Produces:
  - Columns: `agent_background INTEGER CHECK (agent_background IS NULL OR agent_background >= 0)`, `agent_background_at TEXT`. Up comment states: written by the hooks only; meaningful only under `agent_state = 'waiting'`; Swift reads both.
  - Down: `ALTER TABLE terminal_sessions DROP COLUMN agent_background_at; … DROP COLUMN agent_background;` (00102 precedent).
  - `db.TerminalSession.Background sql.NullInt64` (`agent_background`), `db.TerminalSession.BackgroundAt time.Time` (zero when NULL or unreadable, same parse as `AgentStateAt`).

- [ ] **Step 1: Write the failing tests** in `terminal_background_migration_test.go`:
  - `TestMigration00106_AddsTheBackgroundColumns` — after `Open`, `columnNames(t, d.DB, "terminal_sessions")` has both columns; a fresh row reads `Background.Valid == false`, `BackgroundAt.IsZero()`.
  - `TestMigration00106_CountCannotBeNegative` — `UPDATE … SET agent_background = -1` fails with a CHECK error; `0` and `3` succeed.
  - `TestMigration00106_DownDropsAndReUpRestoresTheColumns` — seed a row with `agent_background = 2`, `agent_background_at` set; `goose.DownTo(d.DB, "migrations", 105)` succeeds and both columns are gone, the row and its other columns survive; `goose.Up` restores both columns (NULL). (Review Focus 5)
  - `TestGetTerminalSessionReadsTheBackgroundColumns` — a row with `2` and a valid stamp reads back `Background = {2, true}` and the parsed time; an unreadable stamp reads as zero time.
- [ ] **Step 2: Run, expect FAIL** — `go test ./internal/db -run 'TestMigration00106|TestGetTerminalSessionReadsTheBackgroundColumns' > /tmp/t1.log 2>&1; echo "exit=$?"` (log in the scratchpad).
- [ ] **Step 3: Implement** the migration, `schema.sql` mirror, struct fields and select.
- [ ] **Step 4: Regenerate** `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`, then re-run without `-update`.
- [ ] **Step 5: Run, expect PASS** — `go test ./internal/db` (whole package: the golden, `TestAllTablesExist` unchanged since no new table) and `make lint-diff`.
- [ ] **Step 6: Commit** `feat(db): terminal_sessions background agent count columns, migration 00106 (#411)`.

---

### Task 2: DB write path — snapshot, clear, `LowerTerminalBackground`

**Files:**
- Modify: `internal/db/terminal_sessions.go` — `AgentOrder`, `SetTerminalAgentState`, `MarkTerminalAgentRun`, `ClearTerminalAgentState`, `SetTerminalClaudeSessionID`, new `LowerTerminalBackground`
- Test: `internal/db/terminal_sessions_test.go`, `internal/db/session_report_test.go` (existing PROJ-11 db guards stay green unchanged)

**Interfaces:**
- Consumes: Task 1 columns and `TerminalSession.Background/BackgroundAt`.
- Produces:
  - `AgentOrder` gains `Background sql.NullInt64` — set only by the Stop's write (`Stop == true`): `Valid && Int64 > 0` → store the count and `agent_background_at = stamp`; otherwise both NULL. Doc comment states the invariant.
  - `SetTerminalAgentState(...)` keeps its signature. Column rules inside the one guarded UPDATE:
    - `state == 'working'` (any `working` write — prompt, main tool run, and a subagent's tool result over `approval`): both NULL. (The spec names prompt and main tool run; a subagent's `working` over `approval` NULLs too — Working outranks background and the next Stop re-snapshots, which is ask #20's unchanged behaviour.)
    - `state == 'waiting'` with `order.Stop`: both from `order.Background`.
    - `state == 'waiting'` without `order.Stop` (StopFailure, `idle_prompt`): both NULL.
    - `state == 'approval'`: both kept.
    - The "is a change" clause gains `OR agent_background IS NOT ?` (bound to the value the write would store) for a `waiting` write, so a Stop with another count and an `idle_prompt` over a counted `waiting` are not repeats; such a write advances `agent_state_at` as any change does.
  - `func (db *DB) LowerTerminalBackground(id, workbenchID int64, sessionID string, at time.Time, count *int64) (bool, error)` — the same row guards as `SetTerminalAgentState` (`project_id`, `kind = 'claude'`, `claude_session_id`) plus `agent_state = 'waiting' AND agent_background > 0 AND (agent_background_at IS NULL OR agent_background_at < stamp OR agent_background_at NOT GLOB <stamp glob>)`. Sets `agent_background_at = stamp`; with `count != nil` also `agent_background = MIN(agent_background, *count)` (a negative count is clamped to 0). Never touches any other column. false when a guard held it back.
  - `MarkTerminalAgentRun`, `ClearTerminalAgentState`, `SetTerminalClaudeSessionID` also NULL both columns.

- [ ] **Step 1: Write the failing tests** (`internal/db/terminal_sessions_test.go`):
  - `TestProj11_StopWriteStoresTheSnapshot` — a Stop write with `Background = {2, true}` stores 2 and `agent_background_at == agent_state_at`; with `{0, true}` or invalid stores NULL/NULL.
  - `TestProj11_OnlyTheStopStartsBackground` (db half) — over a `waiting` with NULL count: `LowerTerminalBackground` with nil and with `&1` returns false and the row is byte-identical (compare a full-row snapshot helper); a non-Stop `waiting` write never sets a count.
  - `TestProj11_LowerTerminalBackgroundOnlyLowers` — stored 3: count 5 keeps 3 and refreshes the stamp; count 1 stores 1; nil only refreshes the stamp; an older or equal stamp writes nothing; over `working`/`approval` writes nothing; `agent_state`, `agent_state_at`, `finished_at`, `agent_turn_end`, `agent_tool_run`, `agent_failed_at` unchanged in every case; another `claude_session_id` or workbench writes nothing.
  - `TestProj11_StopOverWaitingWithAnotherCountWrites` (db half) — `waiting` with 2, then a Stop with 1: written, count 1, `agent_state_at` advanced; a Stop with NULL over a counted `waiting`: written, both NULL.
  - `TestProj11_MainTurnAndIdleNoticeClearTheCount` (db half) — from a counted `waiting`: a prompt `working`, a tool-run `working`, a StopFailure `waiting`, a plain (`idle_prompt`) `waiting` each leave both NULL; an `approval` write keeps them.
  - `TestProj11_NewRunAndConversationSwitchClearTheCount` — `MarkTerminalAgentRun`, `ClearTerminalAgentState`, `SetTerminalClaudeSessionID` each leave both NULL.
- [ ] **Step 2: Run, expect FAIL** — `go test ./internal/db -run 'TestProj11_' > log 2>&1; echo "exit=$?"`.
- [ ] **Step 3: Implement.** Keep one UPDATE per call, no transaction (house pattern); update the doc comments of every touched function to name the new columns.
- [ ] **Step 4: Run, expect PASS** — `go test ./internal/db` (all existing `TestProj11_*` there unchanged and green), `make lint-diff`.
- [ ] **Step 5: Commit** `feat(db): background agent count write rules and LowerTerminalBackground (#411)`.

---

### Task 3: Stop hook stores the snapshot

**Files:**
- Modify: `cmd/workbench_check.go` — `stopHookInput`, `backgroundTask`, `backgroundSubagents`, `writeStopAgentState`
- Modify: `cmd/workbench_session_state.go` — `recordAgentState` gains the snapshot; `repeatsAgentState` learns the count
- Test: `cmd/workbench_check_test.go`, `cmd/workbench_session_state_test.go`

**Interfaces:**
- Consumes: Task 0 fixtures and A.7; Task 2 `AgentOrder.Background`, `LowerTerminalBackground`.
- Produces:
  - `stopHookInput.BackgroundTasks backgroundTasks` with `json:"background_tasks"`.
  - `type backgroundTask struct{ ID, Type string }` and `type backgroundTasks struct{ present bool; list []backgroundTask }` with a tolerant `UnmarshalJSON`: absent → `present == false`; `null`, a non-array, or an array → present; a non-object entry or one whose `id`/`type` is not a string is kept as an entry with empty fields (never counts). Never returns an error, so a malformed field cannot fail the whole input. (Replaces the spec's `*[]backgroundTask`, which would fail the whole decode on a non-array.)
  - `func backgroundSubagents(tasks backgroundTasks, except string) (n int64, ok bool)` — counts entries with `Type` `subagent` or `workflow` and `ID != except` (`except == ""` excludes nothing); `ok == false` when the field is absent. If A.7 shows a terminal `status` value inside the list, filter it here and say so in the doc comment.
  - `recordAgentState(..., turn hookTurn)` — `hookTurn` gains `background sql.NullInt64` (Stop only); the order passed to `SetTerminalAgentState` carries it.
  - `repeatsAgentState(row, state, failure, prompt, background sql.NullInt64)` — a `waiting` whose stored count differs from the one the write would store is not a repeat.
  - Same-count repeat refresh: when the Stop is a repeat only because the stored count equals a non-zero snapshot, `recordAgentState` calls `LowerTerminalBackground(…, at, nil)` (stamp refresh, no state write).

- [ ] **Step 1: Write the failing tests:**
  - `TestBackgroundSubagentsCountsSubagentsAndWorkflows` (table) — 2 subagents + 1 workflow + shell + monitor + teammate + `cloud session` + `MCP task` + unknown type → 3; `except` drops its id; empty list → (0, true); absent → (0, false); `null` → (0, true); object instead of array → (0, true); entries with non-string `type` → not counted.
  - `TestStopHookInputParsesTheCapturedFixtures` — `stop_background_tasks.json` decodes with `present` and the expected count (as observed in A.7); `stop_no_background_tasks.json` → (0, true).
  - `TestProj11_StopRecordsBackgroundSubagents` (`cmd/workbench_session_state_test.go`, through `runStopHook` with the terminal env set, like the existing Stop state tests) — fixture with 2 subagents + shell + teammate → stored 2, `agent_background_at == agent_state_at`; empty → NULL; absent → NULL; malformed entries ignored. Stdout stays empty in every case.
  - `TestProj11_MalformedBackgroundTasksStillRecordWaiting` — `"background_tasks": {"x":1}` and `"background_tasks": [1, "a", {"type": 7}]`: `waiting` recorded, count NULL, exit path 0, stderr empty. (Review Focus 2)
  - `TestProj11_StopOverWaitingWithAnotherCountWrites` (hook half) — Stop with 2 then Stop with 1: second writes, `agent_state_at` advances; then Stop with none: count NULL, stamp advances.
  - `TestProj11_StopWithTheSameCountRefreshesTheReportTime` — Stop with 2 at t1, Stop with 2 at t2: `agent_state_at` stays t1 (a repeat), `agent_background_at` becomes t2. (Review Focus 3)
  - `TestProj11_StopReplacesItsTurnsLateToolResult` and `TestProj11_EndedTurnsToolResultNeverOverwritesTheStop` — unchanged and green (turn order untouched).
- [ ] **Step 2: Run, expect FAIL** — `go test ./cmd -run 'TestBackgroundSubagents|TestStopHookInputParses|TestProj11_' > log 2>&1; echo "exit=$?"`.
- [ ] **Step 3: Implement.** The Stop hook still reads its input once; drift output and the block decision are untouched (stdout byte-identical for every existing Stop test).
- [ ] **Step 4: Run, expect PASS** — `go test ./cmd -run 'TestBackgroundSubagents|TestStopHook|TestProj11_|TestProj07_' > log 2>&1; echo "exit=$?"`, `make lint-diff`.
- [ ] **Step 5: Commit** `feat(workbench): Stop hook records the background subagent count (#411)`.

---

### Task 4: session-state hook — subagent heartbeat and `SubagentStop`

**Files:**
- Modify: `cmd/workbench_session_state.go` — `sessionStateInput`, `agentStateFor`, `recordHookAgentState`
- Test: `cmd/workbench_session_state_test.go`

**Interfaces:**
- Consumes: Task 3 `backgroundTasks`, `backgroundSubagents`; Task 2 `LowerTerminalBackground`.
- Produces:
  - `sessionStateInput` gains `AgentType string \`json:"agent_type"\`` and `BackgroundTasks backgroundTasks \`json:"background_tasks"\``.
  - `agentStateFor("SubagentStop", _)` → `("", "", true)`; doc comment says it records no state and is routed to the count.
  - `recordHookAgentState` routing (read-first stays; the common no-change path never takes the write lock):
    - `PostToolUse` with `AgentID != ""`: if the stored state is `approval` → today's write (`onlyFrom = approval`); if `waiting` with `Background > 0` → `LowerTerminalBackground(…, at, nil)` (heartbeat); otherwise nothing.
    - `SubagentStop`: ignored when `AgentType == ""` or `BackgroundTasks` absent; else `m, _ := backgroundSubagents(in.BackgroundTasks, in.AgentID)` and `LowerTerminalBackground(…, at, &m)` only when the read row is `waiting` with `Background > 0` and `at` after `BackgroundAt`.
  - Helper `func recordBackgroundReport(database *db.DB, rowID, workbenchID int64, sessionID string, at time.Time, count *int64) error` — the read-first wrapper both branches share (same row/session guards as `recordAgentState`, `SetBusyTimeout` before the write).

- [ ] **Step 1: Rewrite the guard and write the failing tests:**
  - Rewrite `TestProj11_PostToolUseIntoWorkingClearsFinished`, `from == "waiting"` half, with equal strictness: (a) Stop with no background → a subagent `PostToolUse` writes nothing at all — the full row (every column, via a row-snapshot helper) is byte-identical; (b) Stop whose input reports 2 subagents → a subagent `PostToolUse` changes only `agent_background_at` (`agent_state`, `agent_state_at`, `finished_at`, `agent_turn_end`, `agent_tool_run`, `agent_background`, `agent_failed_at`, `agent_error` unchanged); then a main-thread `PostToolUse` turns it `working`, clears `finished_at` and NULLs both columns — the existing final assertions kept verbatim. The `approval` half is unchanged. (The Desktop half — `isAtPrompt == true` — is pinned in Task 6.)
  - `TestProj11_OnlyTheStopStartsBackground` (hook half) — over a NULL-count `waiting`: a late subagent `PostToolUse`, a `SubagentStop` with 3 in-flight entries, an `idle_prompt` each leave the count NULL.
  - `TestProj11_SubagentStopOnlyLowersTheCount` — after a Stop with 3: `SubagentStop` (fixture-shaped) whose list holds its own id + 2 others → 2; one whose list is larger than the stored count → unchanged count, stamp refreshed; `agent_type == ""` → nothing; no `background_tasks` → nothing; an older `at` → nothing; over `working` → nothing; `agent_state`, `agent_state_at`, `finished_at` untouched throughout. Uses `cmd/testdata/subagentstop_background_tasks.json` for one case.
  - `TestProj11_MainTurnAndIdleNoticeClearTheCount` (hook half) — from a counted `waiting`: `UserPromptSubmit`, main `PostToolUse`, `StopFailure`, `Notification idle_prompt` each NULL both columns; `permission_prompt` keeps them.
  - Extend `TestProj11_HookNeverWritesStdoutAndExitsZero` with a `SubagentStop` input (valid, malformed JSON, `background_tasks` non-array): stdout empty, no panic.
  - Extend `TestProj11_NestedSessionNeverMovesTheRow` with a `SubagentStop` and a subagent `PostToolUse` of another session id: nothing written.
- [ ] **Step 2: Run, expect FAIL** — `go test ./cmd -run 'TestProj11_' > log 2>&1; echo "exit=$?"`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS** — `go test ./cmd -run 'TestProj11_|TestWorkbenchSessionState' > log 2>&1; echo "exit=$?"`, `make lint-diff`.
- [ ] **Step 5: Commit** `feat(workbench): subagent heartbeat and SubagentStop lower the background count (#411)`.

---

### Task 5: Hook pack — `SubagentStop` entry, core vs full state hooks

**Files:**
- Modify: `internal/devpack/workbench_settings.go` — `stateHookSpecs`, new `coreStateHookSpecs`, `HasCoreStateHooks`
- Modify: `cmd/workbench_check.go` — `workbenchHasStateHooks` uses the core check (it gates the Stop write and, via `cmd/workbench_brief_session.go:137`, the run mark #396)
- Test: `internal/devpack/workbench_state_hooks_test.go`, `cmd/workbench_check_test.go` (or `cmd/workbench_session_state_test.go`, wherever the Stop state fixtures live)

**Interfaces:**
- Produces:
  - `coreStateHookSpecs = []hookSpec{UserPromptSubmit, Notification, PostToolUse, StopFailure}` (today's four); `stateHookSpecs = append(coreStateHookSpecs, stateHookSpec("SubagentStop"))`. `ownedHookSpecs`, `InstallStateHooks`, `RemoveStateHooks` iterate `stateHookSpecs` (five).
  - `func HasCoreStateHooks(dir string, workbenchID int64) (bool, error)` — every core entry installed.
  - `HasStateHooks` keeps name and meaning: all five (status JSON `state_hooks`, `internal/devpack/workbench.go:384`), so an old folder reads "state hooks missing" and the Desktop offers Repair.
  - `workbenchHasStateHooks` (cmd) → `devpack.HasCoreStateHooks`.
  - No skill-pack text change, no ask-guard prompt version bump.

- [ ] **Step 1: Write the failing tests:**
  - `TestInstallStateHooksAddsSubagentStop` — install writes five async entries, the `SubagentStop` one with `timeout: 5`, no matcher, the same command line as the others; install twice is idempotent.
  - `TestHasStateHooksNeedsAllFiveCoreNeedsFour` — a settings file with the four old entries: `HasStateHooks == false`, `HasCoreStateHooks == true`; with five: both true; without `PostToolUse`: both false.
  - Extend `TestProj04_MalformedStateEventLeavesTheFileByteIdentical` to a malformed `SubagentStop` value (file byte-identical, error returned).
  - Extend `TestProj04_StateHooksKeepOwnerHooksAndKeys` with an owner `SubagentStop` entry that survives install and remove.
  - `TestProj11_StopStateWriteNeedsOnlyTheCoreHooks` (cmd) — a folder with only the four old entries still gets `waiting` (and the run mark) from the Stop hook; `integrate workbench --status` (or the status JSON builder the Desktop reads) reports `state_hooks: false` for that folder.
- [ ] **Step 2: Run, expect FAIL** — `go test ./internal/devpack > log 2>&1; echo "exit=$?"`; `go test ./cmd -run 'TestProj11_StopStateWriteNeedsOnlyTheCoreHooks' > log2 2>&1; echo "exit=$?"`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS** — `go test ./internal/devpack`, `go test ./cmd -run 'TestProj11_|TestProj04_|TestIntegrateWorkbench' > log 2>&1; echo "exit=$?"`, `make lint-diff`.
- [ ] **Step 5: Commit** `feat(devpack): SubagentStop state hook; Stop write gated on the core state hooks (#411)`.

---

### Task 6: Swift Core — `.background` kind, row columns, staleness seam, clock

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/SessionAgentStatus.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/SessionSwitcherPresentation.swift` (`State.Kind.background`, `State.backgroundAgents`)
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Models/SessionBackgroundPolicy.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/TerminalSessionQueries.swift` (`fetchAgentStates` selects both columns)
- Modify: `WatchtowerDesktop/Sources/Services/SessionAgentStateCenter.swift` (injectable clock, passes `now` to `resolve`)
- Test: `WatchtowerDesktop/Tests/Core/SessionAgentStatusTests.swift`, `Tests/Core/TerminalSessionQueriesTests.swift`, `Tests/SessionAgentStateCenterTests.swift`

Exhaustive `switch`es over `Kind` that must gain `.background` in this task to compile: `SessionAgentStatus.isAtPrompt`, `SessionStatePresentation.color/glyph/caption`, `SessionAgentNoticePolicy.transition`. In this task they get the minimal arms Task 7 then pins with tests: color `.green`, glyph `person.2.fill` / `questionmark`, caption via a `backgroundCaption(_:)` helper, transition `nil`.

**Interfaces:**
- Consumes: Task 1 columns (via the regenerated `TestDatabase+Schema.swift`).
- Produces:
  - `SessionAgentStateRow.agentBackground: Int?` (`agent_background`), `.agentBackgroundAt: String?` (`agent_background_at`); init params with `nil` defaults.
  - `SessionSwitcherPresentation.State.Kind.background` (doc: "the main turn is over, background subagents run"); `State.backgroundAgents: Int` (0 unless `.background`), added to `init` and `live(...)` with default 0.
  - `SessionBackgroundPolicy` (the one staleness seam):
    - `package enum SessionBackgroundVerdict: Equatable, Sendable { case running, over }` (Task 11 may add cases; nothing else switches on it outside this file and `SessionAgentStatus`).
    - `package struct SessionBackgroundPolicy: Sendable { package static let grace: TimeInterval = 120; package func verdict(count: Int, lastReport: Date, now: Date, sessionID: Int64) -> SessionBackgroundVerdict; package static let current: Self }`.
    - Task 6 rule: `lastReport > now` (future) → `.over`; `count == 0` → `.running` while `now - lastReport < grace`, else `.over`; `count > 0` → `.running`. The bound for `count > 0` is **deliberately absent here** and lives only in Task 11 behind `verdict`; no other code may compare `agentBackgroundAt` with a duration. Doc comment says so and names ask #140. The branch must not merge without Task 11.
  - `SessionAgentStatus.effective(row:live:startedAt:now:policy:)` — `now: Date`, `policy: SessionBackgroundPolicy = .current`; new branch after `working`: `hook == .waiting && !failed && count != nil && stamp parses && verdict == .running` → `.background` with `backgroundAgents = count`. An unreadable `agentBackgroundAt` → not background.
  - `SessionAgentStatus.resolve(_:liveIDs:startedAt:now:policy:)` — same new params.
  - `isAtPrompt` true set gains `.background`; `hooksReported` unchanged.
  - `SessionAgentStateCenter.init(…, clock: @escaping @Sendable () -> Date = Date.init)`; `publishResolved` passes `clock()`. The 1 s poll already re-resolves every tick, so an expiry with no write publishes within one tick.

- [ ] **Step 1: Write the failing tests** (Core unless noted):
  - Rewrite `testProj11_StateOrder` as a table over nine kinds × live / not live, adding `background` between `working` and `finished` (a row with approval+count → needsApproval; failed+count → failed; working+count → working; waiting+count+finished → background; waiting+count+asks → background; not live + count → never background). Every existing row of the table kept.
  - `testProj11_BackgroundAgentsAreNotStopped` — trusted `waiting` with count 2 and a fresh stamp → `.background`, `backgroundAgents == 2`, `live`.
  - `testProj11_BackgroundWithAsksIsNotWaitingOnAsk` — same with `openAsks = 1` → `.background`, `openAsks == 1`, `oldestAskID` carried.
  - `testProj11_BackgroundEndsOnGrace` — count 0, report 119 s ago → `.background` with 0 agents; 121 s ago → `.stopped` (or `.waitingOnAsk` with asks, `.finished` when finished).
  - `testProj11_UnreadableOrFutureBackgroundStampIsNotBackground` — `agentBackgroundAt` garbage → `.stopped`; 10 min in the future → `.stopped`. (Review Focus 4)
  - Extend `testProj11_StateFromAnEarlierRunIsIgnored` — a row whose `waiting` + count was written before `startedAt` → `.running` live, `.notStarted` not live.
  - `testProj11_BackgroundIsAtPrompt` — a resolved background status has `isAtPrompt == true`, `hooksReported == true`, `isTrusted(startedAt:)` as for stopped.
  - `TerminalSessionQueriesTests.testFetchAgentStatesReadsTheBackgroundColumns` — seeded row's count and stamp come through; NULLs read as nil.
  - `SessionAgentStateCenterTests.testBackgroundEndsOnTheClockWithoutAWrite` (app tests) — fake reader returns the same row every poll (count 0, report at T); clock at T+60 s → `.background`; advance the injected clock to T+121 s, one `poll()` → `.stopped` published, `onChange` fired once, exactly one "stopped" notice posted through the fake notifier. (Review Focus 1)
- [ ] **Step 2: Run, expect FAIL** — `make test-swift FILTER='SessionAgentStatusTests|TerminalSessionQueriesTests' > log 2>&1; echo "exit=$?"` (compile failure counts).
- [ ] **Step 3: Implement.** Keep `effective` pure; the policy is a value, the center owns the clock. Update every call site of `effective`/`resolve` (grep `SessionAgentStatus.resolve(` and `.effective(` in `Sources` and `Tests`).
- [ ] **Step 4: Run, expect PASS** — `make test-swift FILTER='SessionAgentStatusTests|TerminalSessionQueriesTests|SessionAgentStateCenterTests|SessionSwitcherPresentationTests' > log 2>&1; echo "exit=$?"`; check the log for XCTest failures above the swift-testing tail. `make lint-diff`.
- [ ] **Step 5: Commit** `feat(desktop): Agents working session state from the background count (#411)`.

---

### Task 7: Swift presentation and notices

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/SessionStatePresentation.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/SessionAgentNoticePolicy.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/WorkbenchSessionsPanel.swift` (`SessionLiveDot` pulse, `SessionStateLabel` count beside the glyph)
- Check (no expected change, verify they read `SessionStatePresentation`): `GoToPalette.swift`, `SessionSwitcherButton.swift`, `SessionSwitcherPopover.swift`, `WorkbenchSessionReportView.swift`
- Test: `Tests/Core/SessionStatePresentationTests.swift`, `Tests/Core/SessionAgentNoticePolicyTests.swift`, `Tests/Core/SessionSwitcherPresentationTests.swift`, `Tests/WorkbenchHeaderSwitcherTests.swift`

**Interfaces:**
- Consumes: Task 6 `Kind.background`, `State.backgroundAgents`.
- Produces:
  - `color(.background) == .green`; `glyph` = `person.2.fill` without asks, `questionmark` with asks; `caption` = `"Agents working"` when `backgroundAgents == 0`, `"1 agent working"`, `"N agents working"`, each + `" · 1 ask open"` / `" · N asks open"` (existing `asksOpen`).
  - `package static func pulses(_ state: State) -> Bool` — true only for a live `.background`.
  - `SessionLiveDot` applies a pulse when `pulses(state)`: `symbolEffect(.pulse)` (the `QuickCaptureView` precedent), none under `@Environment(\.accessibilityReduceMotion)`.
  - `SessionStateLabel` shows the ask count beside `questionmark` for `.background` too (today only `.working`).
  - `SessionAgentNoticePolicy.transition(.background) == nil` (never announced; an earlier banner of the session is withdrawn by the existing loop).

- [ ] **Step 1: Write the failing tests:**
  - `testBackgroundIsGreenWithAgentCount` — table: (0 agents, no asks) → green, `person.2.fill`, "Agents working"; (1) → "1 agent working"; (3, 2 asks) → green, `questionmark`, "3 agents working · 2 asks open"; not live → ring (`isRing`), never pulses.
  - `testOnlyALiveBackgroundPulses` — every kind × live: `pulses` true only for live `.background`.
  - Extend `testProj11_OneNoticePerTransition`: working → background → stopped(t1) posts exactly one "stopped" notice; background alone posts nothing; a "stopped" banner seen before background is withdrawn when background appears.
  - `testProj11_BackgroundIsNeverAnnouncedTheStopAfterOnce` — background (stamp t1) for several updates → no post; then stopped with the same t1 (grace expiry) → one post; then the same status again → none; main wakes, working, stopped(t2) → one more post.
  - `SessionSwitcherPresentationTests.testABackgroundRowCarriesItsCaption` — a row's caption is the background caption.
  - `WorkbenchHeaderSwitcherTests` — extend the existing caption/accessibility test with a background state (label reads the caption).
- [ ] **Step 2: Run, expect FAIL** — `make test-swift FILTER='SessionStatePresentationTests|SessionAgentNoticePolicyTests|SessionSwitcherPresentationTests' > log 2>&1; echo "exit=$?"`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS** — `make test-swift FILTER='SessionStatePresentationTests|SessionAgentNoticePolicyTests|SessionSwitcherPresentationTests|WorkbenchHeaderSwitcherTests|WorkbenchGoToPaletteTests|WorkbenchSessionReportLineTests' > log 2>&1; echo "exit=$?"`, `make lint-diff`.
- [ ] **Step 5: Commit** `feat(desktop): Agents working caption, glyph, pulse; never announced (#411)`.

---

### Task 8: Hand-off and ask-answer guards for Agents working

No production change expected (spec §5.4); this task pins it. If a test fails, stop and report to the controller — the fix would touch PROJ-12 behaviour.

**Files:**
- Test: `WatchtowerDesktop/Tests/OwnerAsksViewModelTests.swift` (the PROJ-12 guards live there), `WatchtowerDesktop/Tests/CodeNav/CodeHandoffCenterTests.swift`

**Interfaces:**
- Consumes: Task 6 resolve/`isAtPrompt`, Task 7.

- [ ] **Step 1: Write the tests:**
  - `testProj12_AnAnswerIntoABackgroundSessionGetsTheReturn` — seed a live session whose row is a trusted `waiting` with count 2 (fresh stamp) and one open ask; answering it types exactly one bracketed paste then `[0x0D]` alone (same assertions as `testProj12_TheAnswerIsStoredBeforeTheLineIsTypedThenSubmitted`), delivery `.submitted`.
  - `testProj12_ABackgroundSessionAtASubagentPermissionPromptHoldsTheLine` — same row but `agent_state = 'approval'` with the count kept → the line is held, nothing typed (approval outranks background).
  - `CodeHandoffCenterTests.testAHandOffIntoABackgroundSessionIsAtThePrompt` — a hand-off into a background session behaves as into a stopped one (the Return is sent; same assertions as the existing stopped-session hand-off test).
- [ ] **Step 2: Run** — `make test-swift FILTER='OwnerAsksViewModelTests|CodeHandoffCenterTests' > log 2>&1; echo "exit=$?"` → PASS.
- [ ] **Step 3: Commit** `test(desktop): ask answers and hand-offs treat Agents working as at the prompt (#411)`.

---

### Task 9: Inventory (PROJ-11 amendment), feature notes, app guide

**Files:**
- Modify: `docs/inventory/workbench.md` — PROJ-11 Observable (insert the spec §6 text after the states paragraph, with the date `2026-10-10` and "owner approved, ask #139"), the order sentence, the PROJ-11 guard list (new and rewritten guard names from Tasks 2–8), the Status line (append "amended 2026-10-10 with the owner's approval, board #411, ask #139"), v1 limits note "Session agent state ordering and subagents (PROJ-11, board #367)" gains (d): `SubagentStop` on kill/crash unverified; staleness double notice; teammates/shells not counted; older CLI without the field shows Stopped; Re-run Setup needed for the live count. Changelog line.
- Modify: `docs/features/workbench.md` — session state section: the new state, the two columns, the write table (spec §4.2), the core vs full state hooks split, Re-run Setup / Repair once.
- Modify: `docs/app-guide.md` — the session states list: Agents working, its caption and glyph, the order, "never announced", Re-run Setup once.
- Modify: `CLAUDE.md` feature-notes bullet for the workbench — append a short "(2026-10-10: Agents working, migration 00106, `SubagentStop` state hook, PROJ-11 amended)" clause.

The staleness sentence in the PROJ-11 text is written as "30 minutes with no report, then the probe described in Task 11" only after Task 11; in this task write the spec's §6 text but leave the staleness clause as "a staleness bound (see v1 limits)" and add one v1 limit line "staleness shape: owner ask #140" that Task 11 replaces.

- [ ] **Step 1: Edit the four documents.**
- [ ] **Step 2: Verify** guard names in the inventory exist: for each `TestProj11_…`/`testProj11_…` named, `grep -rn "<name>" cmd internal WatchtowerDesktop/Tests` finds it. `bash scripts/leak-check.sh` style scan over the diff (no ids, no paths).
- [ ] **Step 3: Commit** `docs(workbench): PROJ-11 amended for Agents working, feature notes, app guide (#411)`.

---

### Task 10: Subagent transcript probe — **shape pending ask #140**

**Before starting:** read owner ask #140's answer (`get_ask 140`). If the answer differs from the shape below (30 min → probe; process alive + subagent transcript freshness; fresh → stay; silent → stay green with a "no news" caption, Stopped after another 30 min with one notice), stop and hand back to the controller for a plan amendment. Do not start on an open ask.

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/SubagentTranscriptProbe.swift`
- Test: `WatchtowerDesktop/Tests/Core/SubagentTranscriptProbeTests.swift`

**Interfaces:**
- Consumes: Task 0 A.7 (the observed transcript layout).
- Produces:
  - `package struct SubagentTranscriptProbe: Sendable { package init(projectsRoot: URL, fileManager: FileManager = .default); package func latestActivity(claudeSessionID: String) -> Date? }` — finds `<projectsRoot>/*/<claudeSessionID>/subagents/agent-*.jsonl` (glob by the session id, so no project-slug derivation) and returns the newest modification date; nil when none exists or the directory cannot be read. Never throws, never reads file contents.
  - `package static func defaultProjectsRoot(environment: [String: String]) -> URL` — `$CLAUDE_CONFIG_DIR/projects` when set, else `~/.claude/projects`.
  - Liveness of the claude process is already `live` (TerminalCenter); the probe does not re-check it.

- [ ] **Step 1: Write the failing tests** (temp directory as root):
  - `testNewestSubagentTranscriptWins` — two projects dirs, the session's `subagents/` holds `agent-a.jsonl` (mtime T1) and `agent-b.jsonl` (T2 > T1) → T2; another session's files ignored.
  - `testNoSubagentsDirectoryIsNil` and `testUnreadableDirectoryIsNil` (permissions 000, restored in teardown).
  - `testOnlyAgentJSONLFilesCount` — `notes.txt` newer than the agent files is ignored.
  - `testProjectsRootHonoursClaudeConfigDir`.
  - `testAnInvalidSessionIDNeverEscapesTheRoot` — a session id with `/` or `..` → nil, nothing outside root touched.
- [ ] **Step 2: Run, expect FAIL**, implement, **run, expect PASS** — `make test-swift FILTER=SubagentTranscriptProbeTests > log 2>&1; echo "exit=$?"`; `make lint-diff`.
- [ ] **Step 3: Commit** `feat(desktop): subagent transcript probe for quiet background sessions (#411)`.

---

### Task 11: Staleness verdict wiring — **shape pending ask #140**

Same pre-check as Task 10 (ask #140 answered and matching; otherwise stop).

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/SessionBackgroundPolicy.swift` (the seam), `SessionSwitcherPresentation.swift` (`State.backgroundQuietSince`), `SessionStatePresentation.swift` (quiet caption), `WatchtowerDesktop/Sources/Services/SessionAgentStateCenter.swift` (throttled probe off the main actor)
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/TerminalSessionQueries.swift` (select `claude_session_id` into the row if not already there) and `SessionAgentStateRow`
- Modify: `docs/inventory/workbench.md`, `docs/features/workbench.md`, `docs/app-guide.md` (replace Task 9's staleness placeholder lines with the decided shape)
- Test: `Tests/Core/SessionBackgroundPolicyTests.swift` (create), `Tests/Core/SessionAgentStatusTests.swift`, `Tests/Core/SessionStatePresentationTests.swift`, `Tests/Core/SessionAgentNoticePolicyTests.swift`, `Tests/SessionAgentStateCenterTests.swift`

**Interfaces:**
- Consumes: Task 6 seam, Task 10 probe.
- Produces:
  - `SessionBackgroundPolicy` gains `staleAfter: TimeInterval = 30 * 60`, `quietFor: TimeInterval = 30 * 60` and `evidence: [Int64: Date]` (latest probe activity per session id); `verdict` uses `lastSeen = max(lastReport, evidence[sessionID])`: `now - lastSeen < staleAfter` → `.running`; `< staleAfter + quietFor` → `.quiet(since: lastSeen)`; else `.over`. The count-0 grace rule is unchanged.
  - `SessionBackgroundVerdict` gains `.quiet(since: Date)`; `effective` maps `.running` and `.quiet` to `.background`, the latter with `State.backgroundQuietSince = since`.
  - Caption with `backgroundQuietSince`: the background caption + `" · no news for 30 min"` (exact copy per ask #140's answer).
  - The center probes a live background session only when `now - lastReport ≥ staleAfter`, at most once per 60 s per session, on a background task (never on the main actor), and resolves with the evidence map; probe results never write the DB.
  - Notice: `.over` yields `.stopped` keyed `stopped@agent_state_at` → one notice (existing policy; no new code expected).

- [ ] **Step 1: Write the failing tests:**
  - `SessionBackgroundPolicyTests.testVerdictTable` — count > 0 with lastSeen 29 min ago → running; 31 min → quiet; 61 min → over; fresh evidence 5 min ago with an old report → running; future evidence ignored; count 0 grace rows unchanged.
  - `testProj11_BackgroundEndsOnStalenessAndGrace` (SessionAgentStatusTests) — the full ladder running → quiet (still green, still `isAtPrompt`) → stopped.
  - `SessionStatePresentationTests.testQuietBackgroundCaption` — "2 agents working · no news for 30 min", with asks appended after.
  - `SessionAgentNoticePolicyTests.testAQuietBackgroundIsNotAnnouncedItsEndIsOnce` — quiet posts nothing; over → one "stopped"; the known double (a revived count then a later Stop) posts a second notice, pinned as the v1 limit.
  - `SessionAgentStateCenterTests.testTheProbeRunsOnlyForQuietSessionsAndAtMostOncePerMinute` — fake probe counting calls: none before 30 min; one per 60 s of injected clock after; a fresh probe result keeps `.background` without `quiet`.
- [ ] **Step 2: Run, expect FAIL**, implement, **run, expect PASS** — `make test-swift FILTER='SessionBackgroundPolicyTests|SessionAgentStatusTests|SessionStatePresentationTests|SessionAgentNoticePolicyTests|SessionAgentStateCenterTests' > log 2>&1; echo "exit=$?"`; `make lint-diff`.
- [ ] **Step 3: Update the docs** (inventory PROJ-11 staleness clause and v1 limit, feature notes, app guide) to the decided shape; verify guard names as in Task 9 Step 2.
- [ ] **Step 4: Commit** `feat(desktop): staleness probe for quiet background sessions, ask #140 shape (#411)`.

---

### Task 12: Final gate

**Files:** none expected (fixes only, each its own commit).

- [ ] **Step 1:** `bash scripts/dev-health.sh > health.log 2>&1; echo "exit=$?"` — if the last line is `HEALTH: overloaded`, stop and report to the controller.
- [ ] **Step 2:** `make test > gate-go.log 2>&1; echo "exit=$?"` → `exit=0`.
- [ ] **Step 3:** `make test-swift > gate-swift.log 2>&1; echo "exit=$?"` → `exit=0`; grep the log for XCTest failures (not only the swift-testing tail).
- [ ] **Step 4:** `make lint-all > gate-lint.log 2>&1; echo "exit=$?"` → `exit=0`.
- [ ] **Step 5:** Self-check against the spec: every row of §4.2 has a test; every §7 guard name exists (`grep`); migration number still free against `origin/main` (`git fetch && git ls-tree origin/main internal/db/migrations/ | tail -2`); renumber if not (rename + golden + Swift schema regen, own commit).
- [ ] **Step 6:** Hand back to the controller for the `local-review` / `debate-review` pass and the manual check ask (Re-run Setup on a real folder; a session with two background subagents shows "2 agents working", counts down, turns Stopped once with one notice).
