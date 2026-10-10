# Session state "Agents working" (board #411) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A workbench session whose main agent ended its turn while background subagents/workflows still run shows **Agents working** (green, pulsing, with the count) instead of Stopped / Waiting for you, and announces Stopped once when the background work is really over.

**Architecture:** The sync Stop hook snapshots `background_tasks` (types `subagent` + `workflow`) into two new `terminal_sessions` columns next to the stored `waiting`; later hook events (subagent `PostToolUse`, a new async `SubagentStop` state hook) can only refresh the report time or lower the count, and main-turn events / new runs clear it. No new `agent_state` value: the Desktop derives `.background` from "trusted `waiting` + live count" in `SessionAgentStatus.effective`, behind one seam (`SessionBackgroundPolicy`). A count that goes 30 min without a report is never ended blindly: the Desktop asks Go to probe the session (spec §10) — stage 1 reads Claude Code's session registry and subagent transcripts, stage 2 pings the main agent over Claude Code's peer messaging socket so its next Stop re-snapshots; every probe failure ends the count (Stopped, one notice). Go stays the only writer of the two columns.

**Tech Stack:** Go 1.25 (`cmd/`, `internal/db`, `internal/devpack`), SQLite + goose migrations, SwiftUI / GRDB (WatchtowerCore + app target).

**Spec:** `docs/superpowers/specs/2026-10-10-session-background-agents-design.md` (source of truth, §9 = owner decisions) and `docs/superpowers/specs/2026-10-10-session-background-agents-business.md`. Executors read both before their task.

**Plan style (owner preference, overrides the skill's defaults):** no code bodies. Each task gives files, interfaces/signatures, test cases (name + what it asserts) and verification commands. Task-scope checks only; the full gate runs once, in the final task.

## Global Constraints

- Work only in the worktree `/Users/user/PhpstormProjects/watchtower-411`, branch `feat/411-background-agents`. Before every git command: `cd /Users/user/PhpstormProjects/watchtower-411 && git branch --show-current` must print `feat/411-background-agents`.
- What counts: `background_tasks` entries with `type` `subagent` or `workflow` (ask #138). `shell`, `monitor`, `teammate`, `cloud session`, `MCP task` and unknown types never count.
- Grace after the count reaches 0: **120 s** (ask #138). Staleness (count > 0, no report for **30 min**): the two-stage probe of spec §10 (asks #138, #140), Tasks 10–14 only. Stage 1 passive (registry `<claude config dir>/sessions/<pid>.json` + subagent transcript mtimes); stage 2 one ping over the peer socket, "checking…" caption while in flight, **5 min** to a Stop, at most one ping per run per 30-min silence window, never while `status == busy`, never at Needs approval, never within **2 min** of the owner typing into that terminal. Every failure → Stopped (one notice). Registry and peer channel are Claude Code internals: version-gated, failure falls through to Stopped, never sticks the state.
- Go is the only writer of `agent_background` / `agent_background_at`, the probe's writes included; the Desktop triggers the probe through the CLI and keeps only in-memory probe bookkeeping (ping in flight, window used).
- `SubagentStop` state hook is installed (async, timeout 5, no matcher). `SubagentStart` is **not** installed.
- Older Claude Code without `background_tasks` in the Stop input: Stopped as today (no fallback).
- Label/glyph: caption "Agents working" / "1 agent working" / "N agents working"; with asks + " · 1 ask open" / " · N asks open"; glyph `person.2.fill` (no asks) or `questionmark` (asks open); tone `.green`; dot filled and pulsing, honouring Reduce Motion. UI strings English only.
- Ask #20 grant behaviour unchanged: after a granted subagent permission the row shows Working until the next Stop.
- State order (first match wins): approval > error > working > **background** > finished > open ask > stopped > running > not started.
- No new `agent_state` value; no change to the `agent_state` CHECK.
- Invariant (guarded): `agent_background` goes from NULL to a number only in the Stop's write; every other write leaves it, lowers it, or NULLs it. Subagent `PostToolUse` over `waiting` and `SubagentStop` never touch `agent_state`, `agent_state_at`, `finished_at`, `agent_turn_end`, `agent_tool_run` (a subagent `PostToolUse` over `approval` writes `working` as today, ask #20).
- Stamps: `agent_background_at` uses the `agent_state_at` layout (UTC, milliseconds); Swift parses it with the existing UTC `SessionAgentStatus.parseStamp`.
- Guard tests follow `TestProj11_*` / `testProj11_*` (`TestProj04_*`, `testProj12_*` where those contracts are touched). Existing guards are never weakened, renamed out of the convention or split; the subagent-`PostToolUse`-over-`waiting` guard is rewritten with equal strictness.
- Public repo: fixtures and docs carry no real session ids, agent ids, user names or local absolute paths (placeholders, `example`); `make hooks` must be installed in the worktree.
- Commit messages in English, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. No push from task implementers.
- Inner loop only per task (`go test ./internal/<pkg>`, `go test ./cmd -run '<regex>'`, `make test-swift FILTER=…`, `make lint-diff`). No `-count=1`. Logs to a file with an explicit exit code (`cmd > log 2>&1; echo "exit=$?"`), never piped through `tail`.
- Swift tasks (6, 7, 8, 14) run strictly one at a time.

## Who runs the probe, and why (dual-path rules)

The probe runs in **Go** (`watchtower workbench session-probe`, Tasks 11 and 13); the Desktop only decides *when* (Task 14).
- `agent_background` / `agent_background_at` are hook-written columns read by Swift. If the Desktop also wrote them, every Go write guard (turn order, compare-and-clear, the "only the Stop starts background" invariant) would need a Swift twin with collision tests (review-rules "Go ↔ Swift dual-path contracts"). One writer keeps those guards in one place.
- The probe needs the registry, the pid check (`kill(pid, 0)` + process start time) and a Unix-socket client. All three are plain Go and testable with `t.TempDir()` listeners, next to the hook code that parses the same Claude Code inputs (`internal/claudesession`).
- Not the daemon: the daemon does not know which terminal is live, whether the owner typed in the last 2 minutes, or whether the row reads Needs approval. The Desktop knows all three (TerminalCenter, `SessionAgentStateCenter`). The trigger stays there, and it costs nothing when no session is live (the 1 s poll already stops).
- The Desktop keeps only in-memory bookkeeping (ping in flight, window used, 5-min timer). Losing it on relaunch at worst repeats one stage-1 probe.

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
| 10 | Go: Claude session registry + subagent transcript reader (`internal/claudesession`) | Task 0 |
| 11 | Go: `workbench session-probe` stage 1 + `EndTerminalBackground` | Task 5, Task 10 |
| 12 | Peer messaging protocol discovery + go/no-go (no product code) | Task 0 |
| 13 | Go: stage 2 ping (`--ping`, `--expire`) — or the no-go fallback | Task 11, Task 12 |
| 14 | Desktop: probe trigger, "checking…" caption, ping timeout, docs | Task 8, Task 9, Task 13 |
| 15 | Final gate | Task 14 |

Parallel lanes allowed by the dependencies: Task 0 ‖ Task 1; after Task 1, the Go lane (2 → 3 → 4 → 5 → 11 → 13) ‖ the Swift lane (6 → 7 → 8 → 14); Tasks 10 and 12 (after Task 0) ‖ either lane. Each lane in its own worktree/branch merged by the controller; never two implementers in one tree.

---

### Task 0: Capture real Stop / SubagentStop inputs as redacted fixtures

Pins the parse against what Claude Code actually sends and answers the spec's unverified facts (§2 "Not verifiable", Appendix A.6) where the capture can.

**Files:**
- Create: `cmd/testdata/stop_background_tasks.json` (a Stop input with ≥ 2 in-flight background subagents)
- Create: `cmd/testdata/subagentstop_background_tasks.json` (a `SubagentStop` of one of those subagents, with the parent's `background_tasks`)
- Create: `cmd/testdata/stop_no_background_tasks.json` (a Stop input with nothing in flight — expected `"background_tasks": []`)
- Create: `internal/claudesession/testdata/registry_idle.json`, `registry_busy.json` (a redacted `<claude config dir>/sessions/<pid>.json` entry of an idle and of a busy session)
- Create: `internal/claudesession/testdata/peer_inbound_frame.bin` + `peer_inbound_frame.md` (the bytes a local session sends when it messages another session, captured on a decoy socket, and a one-paragraph note of how they were captured) — only if Step 6b succeeds
- Modify: `docs/superpowers/specs/2026-10-10-session-background-agents-design.md` — add Appendix A.7 "Observed inputs (Claude Code <version>, 2026-10-xx)"

**Interfaces:**
- Consumes: none.
- Produces: the three hook fixtures (consumed by Tasks 3 and 4 tests by file name); the registry fixtures (Task 10); the inbound frame (Task 12 starts from it); A.7 answers (consumed by Task 3: whether to filter a `status` value; Task 4: whether the stopping subagent is listed in its own `SubagentStop` and whether task `id` equals `agent_id`).

- [ ] **Step 1: Set up a capture folder outside the repo.** In the scratchpad, make an empty folder with `.claude/settings.local.json` holding two command hooks, `Stop` and `SubagentStop`, each `cat > <capture dir>/<event>-$(date +%s%N).json` (plain shell, exits 0). Record `claude --version`.
- [ ] **Step 2: Produce the events.** In that folder run an interactive `claude` session (or `claude -p` first; if its Stop input carries no in-flight entries, use an interactive session) with a prompt asking it to launch two background subagents that each run `sleep 20` via Bash then report, a background `Bash` `sleep 30` (shell, must not count), and to end its turn immediately. Wait until both subagents finish and the main agent wakes and stops again.
- [ ] **Step 3: If capture is impossible from the agent's session** (no interactive TTY, CLI missing), raise one owner ask (via the workbench skill) with the exact two-step recipe above and stop the task until the files arrive. Do not invent fixtures.
- [ ] **Step 4: Redact.** Replace every `session_id` with `00000000-0000-4000-8000-000000000411`, every `agent_id`/task `id` with stable fakes (`agent-a`, `agent-b`, `task-shell-1`, keeping equal ids equal), paths with `/tmp/example/...`, `description`/`last_assistant_message` with neutral text. Keep every key, value type and `status` value as observed. Run `bash scripts/leak-check.sh` (or the pre-push hook path) over the new files.
- [ ] **Step 5: Write A.7.** One line per unverified fact: observed `status` values; whether the stopping subagent appears in its own `SubagentStop`'s `background_tasks`; whether a task `id` equals the subagent's `agent_id`; the `agent_type` of the user's subagents; whether `background_tasks` is present in an empty Stop. Facts the capture could not show stay "not observed".
- [ ] **Step 6a: Registry entry.** While the Step 2 session runs, copy its `<claude config dir>/sessions/<pid>.json` (the one whose `sessionId` matches the captured hook input) once while it is idle and once while busy. Redact `pid` → `4242`, `sessionId` → the Step 4 placeholder, `cwd`/`messagingSocketPath` → `/tmp/example/...`, `name` → `example`, timestamps kept as numbers but shifted to 2026-01-01. Keep every key, its type, `version`, `peerProtocol`, `peerFeatures`, `status`, `kind`, `entrypoint`, `pidDomain`, `procStart`, `startedAt`, `updatedAt`, `statusUpdatedAt` (Task 10 decodes them). Note in A.7 that a `<pid>.<hash>.key` file sits beside each entry; never open, copy or commit a `.key` file.
- [ ] **Step 6b: Inbound peer frame (decoy socket).** In the scratchpad, start a Unix-socket listener (a short Go or Python `-I` script outside the repo) that writes every received byte to a file and accepts but never answers; write a decoy registry entry for it (own pid, a fake `sessionId`, `messagingSocketPath` = the listener, `peerProtocol`/`peerFeatures` copied from Step 6a). From an agent session that has a cross-session `SendMessage` tool, send one plain message to the decoy's name. Save the received bytes as `peer_inbound_frame.bin` after redacting ids/paths in place (same lengths where the frame carries lengths — if lengths make redaction impossible, keep only `peer_inbound_frame.md` with the structure described and no bytes). Remove the decoy entry and stop the listener. If the sender refuses the decoy (it checks something else), write that in `peer_inbound_frame.md` and move on — Task 12 picks it up.
- [ ] **Step 6c: Verify.** `jq . cmd/testdata/stop_background_tasks.json cmd/testdata/subagentstop_background_tasks.json cmd/testdata/stop_no_background_tasks.json internal/claudesession/testdata/registry_idle.json internal/claudesession/testdata/registry_busy.json > /dev/null; echo "exit=$?"` → `exit=0`; `git status --short` shows no `.key` file.
- [ ] **Step 7: Commit** `test(workbench): real Stop, SubagentStop, registry and peer frame fixtures (#411)`.

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
    - Failure columns (pre-flight F3): a `waiting` write with `failure == nil` over a stored failed `waiting` (`agent_failed_at` set) keeps `agent_failed_at` and `agent_error` — the existing rule "a plain `waiting` keeps the error until a real state change" — also when only the count clause let it through; the count columns are still written per the rules above. Every other write sets the failure columns as today.
    - The "is a change" clause gains `OR agent_background IS NOT ?` (bound to the value the write would store) for a `waiting` write, so a Stop with another count and an `idle_prompt` over a counted `waiting` are not repeats; such a write advances `agent_state_at` as any change does.
  - `func (db *DB) LowerTerminalBackground(id, workbenchID int64, sessionID string, at time.Time, count *int64) (bool, error)` — the same row guards as `SetTerminalAgentState` (`project_id`, `kind = 'claude'`, `claude_session_id`) plus `agent_state = 'waiting' AND agent_background > 0 AND (agent_background_at IS NULL OR agent_background_at < stamp OR agent_background_at NOT GLOB <stamp glob>)`. Sets `agent_background_at = stamp`; with `count != nil` also `agent_background = MIN(agent_background, *count)`. No clamp: the only callers pass `nil` or a `backgroundSubagents` result, and the CHECK rejects a negative. Never touches any other column. false when a guard held it back.
  - `MarkTerminalAgentRun`, `ClearTerminalAgentState`, `SetTerminalClaudeSessionID` also NULL both columns.

- [ ] **Step 1: Write the failing tests** (`internal/db/terminal_sessions_test.go`):
  - `TestProj11_StopWriteStoresTheSnapshot` — a Stop write with `Background = {2, true}` stores 2 and `agent_background_at == agent_state_at`; with `{0, true}` or invalid stores NULL/NULL.
  - `TestProj11_OnlyTheStopStartsBackground` (db half) — over a `waiting` with NULL count: `LowerTerminalBackground` with nil and with `&1` returns false and the row is byte-identical (compare a full-row snapshot helper); a non-Stop `waiting` write never sets a count.
  - `TestProj11_LowerTerminalBackgroundOnlyLowers` — stored 3: count 5 keeps 3 and refreshes the stamp; count 1 stores 1; nil only refreshes the stamp; an older or equal stamp writes nothing; over `working`/`approval` writes nothing; `agent_state`, `agent_state_at`, `finished_at`, `agent_turn_end`, `agent_tool_run`, `agent_failed_at` unchanged in every case; another `claude_session_id` or workbench writes nothing.
  - `TestProj11_StopOverWaitingWithAnotherCountWrites` (db half) — `waiting` with 2, then a Stop with 1: written, count 1, `agent_state_at` advanced; a Stop with NULL over a counted `waiting`: written, both NULL; a failed `waiting` (StopFailure) then a Stop with 2: written, count 2, `agent_failed_at`/`agent_error` kept (F3); then an `idle_prompt` `waiting`: count NULL, error still kept.
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
  - `type backgroundTask struct{ ID, Type string }` and `type backgroundTasks struct{ present bool; list []backgroundTask }` with a tolerant `UnmarshalJSON`: absent, `null` or a non-array → `present == false` (treated as absent: the Stop stores NULL, a `SubagentStop` is ignored — pre-flight F2); an array → present; a non-object entry or one whose `id`/`type` is not a string is kept as an entry with empty fields (never counts). Never returns an error, so a malformed field cannot fail the whole input. (Spec §4.3 amended to this type, pre-flight F1: a `*[]backgroundTask` would fail the whole decode on a non-array.)
  - `func backgroundSubagents(tasks backgroundTasks, except string) (n int64, ok bool)` — counts entries with `Type` `subagent` or `workflow` and `ID != except` (`except == ""` excludes nothing); `ok == false` when the field is absent, `null` or not an array. If A.7 shows a terminal `status` value inside the list, filter it here and say so in the doc comment.
  - `recordAgentState(..., turn hookTurn)` — `hookTurn` gains `background sql.NullInt64` (Stop only); the order passed to `SetTerminalAgentState` carries it.
  - `repeatsAgentState(row, state, failure, prompt, background sql.NullInt64)` — a `waiting` whose stored count differs from the one the write would store is not a repeat.
  - Same-count repeat refresh: when the Stop is a repeat only because the stored count equals a non-zero snapshot, `recordAgentState` calls `LowerTerminalBackground(…, at, nil)` (stamp refresh, no state write).

- [ ] **Step 1: Write the failing tests:**
  - `TestBackgroundSubagentsCountsSubagentsAndWorkflows` (table) — 2 subagents + 1 workflow + shell + monitor + teammate + `cloud session` + `MCP task` + unknown type → 3; `except` drops its id; empty list → (0, true); absent → (0, false); `null` → (0, false); object instead of array → (0, false); entries with non-string `type` → not counted.
  - `TestStopHookInputParsesTheCapturedFixtures` — `stop_background_tasks.json` decodes with `present` and the expected count (as observed in A.7); `stop_no_background_tasks.json` → (0, true).
  - `TestProj11_StopRecordsBackgroundSubagents` (`cmd/workbench_session_state_test.go`, through `runStopHook` with the terminal env set, like the existing Stop state tests) — fixture with 2 subagents + shell + teammate → stored 2, `agent_background_at == agent_state_at`; empty → NULL; absent → NULL; malformed entries ignored. Stdout stays empty in every case.
  - `TestProj11_MalformedBackgroundTasksStillRecordWaiting` — `"background_tasks": {"x":1}` and `"background_tasks": [1, "a", {"type": 7}]`: `waiting` recorded, count NULL, exit path 0, stderr empty. (Review Focus 2)
  - `TestProj11_StopOverWaitingWithAnotherCountWrites` (hook half) — Stop with 2 then Stop with 1: second writes, `agent_state_at` advances; then Stop with none: count NULL, stamp advances.
  - `TestProj11_StopWithTheSameCountRefreshesTheReportTime` — Stop with 2 at t1, Stop with 2 at t2: `agent_state_at` stays t1 (a repeat), `agent_background_at` becomes t2. (Review Focus 3)
  - `TestProj11_StopReplacesItsTurnsLateToolResult` and `TestProj11_EndedTurnsToolResultNeverOverwritesTheStop` — unchanged and green (turn order untouched).
- [ ] **Step 2: Run, expect FAIL** — `go test ./cmd -run 'TestBackgroundSubagents|TestStopHookInputParses|TestProj11_' > log 2>&1; echo "exit=$?"`.
- [ ] **Step 3: Implement.** The Stop hook still reads its input once; drift output and the block decision are untouched (stdout byte-identical for every existing Stop test).
- [ ] **Step 4: Run, expect PASS** — `go test ./cmd -run 'TestBackgroundSubagents|TestStopHook|TestProj11_|TestProj07_|TestSessionState_' > log 2>&1; echo "exit=$?"` (`TestSessionState_` holds the existing Stop-state tests), `make lint-diff`.
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
    - `SubagentStop`: ignored when `AgentType == ""` or `BackgroundTasks` absent (absent includes `null` and a non-array, F2); else `m, _ := backgroundSubagents(in.BackgroundTasks, in.AgentID)` and `LowerTerminalBackground(…, at, &m)` only when the read row is `waiting` with `Background > 0` and `at` after `BackgroundAt`.
  - A `Stop` event reaching `workbench session-state` (not installed there; tests and manual runs) stays count-free: the snapshot is written only by the sync Stop hook (`writeStopAgentState`, Task 3) — pre-flight F4.
  - Helper `func recordBackgroundReport(database *db.DB, rowID, workbenchID int64, sessionID string, at time.Time, count *int64) error` — the read-first wrapper both branches share (same row/session guards as `recordAgentState`, `SetBusyTimeout` before the write).

- [ ] **Step 1: Rewrite the guard and write the failing tests:**
  - Rewrite `TestProj11_PostToolUseIntoWorkingClearsFinished`, `from == "waiting"` half, with equal strictness: (a) Stop with no background → a subagent `PostToolUse` writes nothing at all — the full row (every column, via a row-snapshot helper) is byte-identical; (b) Stop whose input reports 2 subagents — sent through `runStopHook` on a folder with the state hooks (`stopStateFixture`), since `workbench session-state` records no count for a `Stop` (F4); (a) may keep `runSessionState` — → a subagent `PostToolUse` changes only `agent_background_at` (`agent_state`, `agent_state_at`, `finished_at`, `agent_turn_end`, `agent_tool_run`, `agent_background`, `agent_failed_at`, `agent_error` unchanged); then a main-thread `PostToolUse` turns it `working`, clears `finished_at` and NULLs both columns — the existing final assertions kept verbatim. The `approval` half is unchanged. (The Desktop half — `isAtPrompt == true` — is pinned in Task 6.)
  - `TestProj11_OnlyTheStopStartsBackground` (hook half) — over a NULL-count `waiting`: a late subagent `PostToolUse`, a `SubagentStop` with 3 in-flight entries, an `idle_prompt` each leave the count NULL.
  - `TestProj11_SubagentStopOnlyLowersTheCount` — after a Stop with 3: `SubagentStop` (fixture-shaped) whose list holds its own id + 2 others → 2; one whose list is larger than the stored count → unchanged count, stamp refreshed; `agent_type == ""` → nothing; no `background_tasks` → nothing; `"background_tasks": null` or an object → nothing, count unchanged (F2); an older `at` → nothing; over `working` → nothing; `agent_state`, `agent_state_at`, `finished_at` untouched throughout. Uses `cmd/testdata/subagentstop_background_tasks.json` for one case.
  - `TestProj11_MainTurnAndIdleNoticeClearTheCount` (hook half) — from a counted `waiting`: `UserPromptSubmit`, main `PostToolUse`, `StopFailure`, `Notification idle_prompt` each NULL both columns; `permission_prompt` keeps them.
  - Extend `TestProj11_HookNeverWritesStdoutAndExitsZero` with a `SubagentStop` input (valid, malformed JSON, `background_tasks` non-array): stdout empty, no panic.
  - Extend `TestProj11_NestedSessionNeverMovesTheRow` with a `SubagentStop` and a subagent `PostToolUse` of another session id: nothing written.
- [ ] **Step 2: Run, expect FAIL** — `go test ./cmd -run 'TestProj11_' > log 2>&1; echo "exit=$?"`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS** — `go test ./cmd -run 'TestProj11_|TestSessionState_' > log 2>&1; echo "exit=$?"`, `make lint-diff`.
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
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/SessionStatePresentation.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/SessionAgentNoticePolicy.swift` — minimal `.background` arms only (exhaustive switches; pre-flight F6), tested in Task 7
- Test: `WatchtowerDesktop/Tests/Core/SessionAgentStatusTests.swift`, `Tests/Core/TerminalSessionQueriesTests.swift`, `Tests/SessionAgentStateCenterTests.swift`

Exhaustive `switch`es over `Kind` that must gain `.background` in this task to compile: `SessionAgentStatus.isAtPrompt`, `SessionStatePresentation.color/glyph/caption`, `SessionAgentNoticePolicy.transition`. In this task they get the minimal arms Task 7 then pins with tests: color `.green`, glyph `person.2.fill` / `questionmark`, caption via a `backgroundCaption(_:)` helper, transition `nil`.

**Interfaces:**
- Consumes: Task 1 columns (via the regenerated `TestDatabase+Schema.swift`).
- Produces:
  - `SessionAgentStateRow.agentBackground: Int?` (`agent_background`), `.agentBackgroundAt: String?` (`agent_background_at`); init params with `nil` defaults.
  - `SessionSwitcherPresentation.State.Kind.background` (doc: "the main turn is over, background subagents run"); `State.backgroundAgents: Int` (0 unless `.background`), added to `init` and `live(...)` with default 0.
  - `SessionBackgroundPolicy` (the one staleness seam):
    - `package enum SessionBackgroundVerdict: Equatable, Sendable { case running, over }` (Task 14 may add cases; nothing else switches on it outside this file and `SessionAgentStatus`).
    - `package struct SessionBackgroundPolicy: Sendable { package static let grace: TimeInterval = 120; package func verdict(count: Int, lastReport: Date, now: Date) -> SessionBackgroundVerdict; package static let current: Self }`.
    - Task 6 rule: `lastReport > now` (future) → `.over`; `count == 0` → `.running` while `now - lastReport < grace`, else `.over`; `count > 0` → `.running`. `count > 0` never ends on the Desktop's clock: Go ends it (Tasks 11, 13). The 30-min "needs a probe" check is added in Task 14 behind this same type (`needsProbe`); no other code may compare `agentBackgroundAt` with a duration. Doc comment says so and names spec §10. The branch must not merge without Tasks 11–14.
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
- [ ] **Step 2: Run, expect FAIL** — `make test-swift FILTER='SessionAgentStatusTests|TerminalSessionQueriesTests|SessionAgentStateCenterTests' > log 2>&1; echo "exit=$?"` (compile failure counts).
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
  - `SessionStateLabel` shows the ask count beside `questionmark` for `.background` too, only when `openAsks > 0` (never a `0` beside `person.2.fill`; pre-flight F22); `.working` unchanged.
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
- Modify: `docs/inventory/workbench.md` — PROJ-11 Observable (insert the spec §6 text — as amended by the pre-flight scan: `subagent` or `workflow`, the subagent-over-approval clear, the same-count refresh — after the states paragraph, with the date `2026-10-10` and "owner approved, ask #139"), the order sentence, the PROJ-11 guard list (new and rewritten guard names from Tasks 2–8; the three names that exist in both packages — `TestProj11_OnlyTheStopStartsBackground`, `TestProj11_StopOverWaitingWithAnotherCountWrites`, `TestProj11_MainTurnAndIdleNoticeClearTheCount` — listed once per package, `internal/db` and `cmd`, F14), the Status line (append "amended 2026-10-10 with the owner's approval, board #411, ask #139"), v1 limits note "Session agent state ordering and subagents (PROJ-11, board #367)" gains (d): `SubagentStop` on kill/crash unverified; staleness double notice; teammates/shells not counted; older CLI without the field shows Stopped; Re-run Setup needed for the live count. Changelog line.
- Modify: `docs/features/workbench.md` — session state section: the new state, the two columns, the write table (spec §4.2), the core vs full state hooks split, Re-run Setup / Repair once.
- Modify: `docs/app-guide.md` — the session states list: Agents working, its caption and glyph, the order, "never announced", Re-run Setup once.
- Modify: `CLAUDE.md` feature-notes bullet for the workbench — append a short "(2026-10-10: Agents working, migration 00106, `SubagentStop` state hook, PROJ-11 amended)" clause.

Write the final PROJ-11 staleness text now (spec §10, asks #138/#140), right after the amended §6 text, whose clause "a count > 0 (ended only by the probe below)" replaced "a count > 0 reported in the last 30 minutes" (F12). Task 9 owns this probe paragraph and its v1 limits; Task 14 Step 4 only adds the "checking…" caption, the NO-GO edit if any, and guard names (F13):

> A count with no report for 30 minutes is probed, never ended on the clock alone. Stage 1 (passive, no model turn) reads Claude Code's session registry entry for the session (`<claude config dir>/sessions/<pid>.json`, matched by `sessionId`): no entry or a dead process (pid gone or reused) ends the count; `status = busy` leaves the row alone; a subagent transcript of the session written in the last 30 minutes refreshes `agent_background_at`. Otherwise stage 2 sends the main agent one message over Claude Code's peer messaging channel (version-gated on `peerProtocol`/`peerFeatures`; at most one per run per 30-minute silence window; never while `busy`, at Needs approval, or within 2 minutes of the owner typing into that terminal); the row reads "… · checking…" while it is in flight, and the main agent's next Stop re-snapshots the count. No Stop within 5 minutes of the ping, or any channel failure, ends the count. Ending the count is a compare-and-clear on `agent_background_at` written by Go only; the row then reads Stopped (or its ask / finished state) with one notice. A probe that cannot run (the CLI answers `ok: false`) twice in a row for the same count makes the Desktop show the count as over — Stopped, one notice — without a write (display only; the stored count goes at the next main turn, Stop or run); a new report, a new run or a successful probe clears that.

Add the v1 limits line: the registry and the peer channel are undocumented Claude Code internals — a change in them loses the probe (the count ends at the first stale probe, as Stopped), never sticks the state; a probe CLI that keeps failing ends the display only (two failed probes), the stored count stays until the next main turn, Stop or run; the known double notice (§5.3). If Task 12 later returns NO-GO, Task 14 replaces the stage-2 sentence with "Otherwise the count ends" and records the NO-GO reason in v1 limits; nothing else in this text changes.

- [ ] **Step 1: Edit the four documents.**
- [ ] **Step 2: Verify** guard names in the inventory exist: for each `TestProj11_…`/`testProj11_…` named, `grep -rn "<name>" cmd internal WatchtowerDesktop/Tests` finds it. `bash scripts/leak-check.sh` style scan over the diff (no ids, no paths).
- [ ] **Step 3: Commit** `docs(workbench): PROJ-11 amended for Agents working, feature notes, app guide (#411)`.

---


### Task 10: Go — Claude session registry + subagent transcript reader (`internal/claudesession`)

Stage 1's read side (spec §10), pure reads, no DB, no network.

**Files:**
- Create: `internal/claudesession/registry.go`, `internal/claudesession/transcripts.go`
- Test: `internal/claudesession/registry_test.go`, `internal/claudesession/transcripts_test.go` (fixtures from Task 0)

**Interfaces:**
- Consumes: Task 0 registry fixtures and A.7.
- Produces:
  - `func ConfigDir(env func(string) string) string` — `$CLAUDE_CONFIG_DIR` when set, else `~/.claude`.
  - `type Entry struct { PID int; SessionID, Status, Version, MessagingSocketPath, ProcStart string; PeerProtocol int; PeerFeatures []string; StatusUpdatedAt time.Time }` — unknown keys ignored; `Status` raw (`busy`/`idle`/anything else); `ProcStart` ← `procStart` (string); `StatusUpdatedAt` decoded from the registry's epoch-milliseconds number (custom decode — default JSON cannot read a number into `time.Time`; pre-flight F16); `PeerProtocol` from a number.
  - `func FindSession(configDir, sessionID string) (Entry, bool, error)` — scans `<configDir>/sessions/*.json` (never `*.key`), returns the entry whose `sessionId` matches; `false, nil` when none; an unreadable/undecodable file is skipped, not an error (a third state is not needed here: any non-match means "not found", and the caller treats not found as gone). A missing `sessions` dir → `false, nil`.
  - `func Alive(e Entry) bool` — `syscall.Kill(pid, 0)` succeeds or fails with `EPERM`; and, when `ProcStart` is non-empty, the process's start time (via `ps -o lstart= -p <pid>` or `sysctl kern.proc.pid`, bounded 2 s) still matches — a reused pid is not alive. Exported seam so `cmd` tests can fake it (pre-flight F17): `type ProcInfo interface { Exists(pid int) bool; Start(pid int) (string, bool) }`, `func AliveWith(e Entry, p ProcInfo) bool`, `Alive(e)` = `AliveWith(e, systemProcInfo)` (or the equivalent exported shape Task 10 lands — Task 11 uses whatever it names).
  - `func LatestSubagentWrite(configDir, sessionID string) (time.Time, bool)` — newest mtime of `<configDir>/projects/*/<sessionID>/subagents/agent-*.jsonl` (glob by session id, no slug derivation); `false` when none. A session id that is not `terminal.IsSessionID` → `false` (no path escape).

- [ ] **Step 1: Write the failing tests:**
  - `TestFindSessionMatchesBySessionID` — temp `sessions/` with the two fixtures (ids changed per file) + a `.key` file + a garbage `.json`: finds the right entry with every field decoded; the `.key` is never opened (make it mode 000); garbage skipped.
  - `TestFindSessionWithoutRegistryIsNotFound` — no `sessions` dir → `false, nil`.
  - `TestAliveRejectsAReusedPID` — fake `ProcInfo`: pid exists with another start → false; same start → true; gone → false; `ProcStart` empty → existence only.
  - `TestLatestSubagentWriteNewestAgentFileWins` — two project dirs, files `agent-a.jsonl`/`agent-b.jsonl` with set mtimes, a newer `notes.txt` ignored, another session's files ignored.
  - `TestLatestSubagentWriteRejectsAnInvalidSessionID` — `../x`, `a/b` → false, nothing outside root stat'ed.
  - `TestConfigDirHonoursClaudeConfigDir`.
  - `TestEntryDecodesTheRegistryFixtures` — both Task 0 fixtures decode: `ProcStart` non-empty, `StatusUpdatedAt` equals the fixture's epoch ms, `PeerProtocol`, `PeerFeatures`.
- [ ] **Step 2: Run, expect FAIL**, implement, **run, expect PASS** — `go test ./internal/claudesession > log 2>&1; echo "exit=$?"`; `make lint-diff`.
- [ ] **Step 3: Commit** `feat(claudesession): read Claude Code's session registry and subagent transcripts (#411)`.

---

### Task 11: Go — `workbench session-probe` stage 1 + `EndTerminalBackground`

**Files:**
- Create: `cmd/workbench_session_probe.go`, `cmd/workbench_session_probe_test.go`
- Modify: `internal/db/terminal_sessions.go` (new `EndTerminalBackground`), `internal/db/terminal_sessions_test.go`

**Interfaces:**
- Consumes: Task 2 `LowerTerminalBackground`; Task 10 `FindSession`, `Alive`, `LatestSubagentWrite`, `ConfigDir`.
- Produces:
  - `func (db *DB) EndTerminalBackground(id, workbenchID int64, sessionID string, seenAt string) (bool, error)` — NULLs both columns only while `agent_state = 'waiting' AND agent_background IS NOT NULL AND agent_background_at = seenAt` (compare-and-clear: a Stop or report that landed since the probe read the row wins). Never touches any other column. The Desktop's notice key stays `stopped@agent_state_at` → one notice.
  - CLI `watchtower workbench session-probe --workbench <id> --session <terminal row id>` (stage 1; flags `--ping`, `--expire` are added in Task 13 and rejected here as unknown). Reads the row (`GetTerminalSession`); acts only when the row is `waiting` with `Background > 0` and `BackgroundAt` ≥ 30 min old (`probeStaleAfter = 30 * time.Minute`); otherwise outcome `not_stale`.
  - The compare-and-clear stamp: `seenAt = row.BackgroundAt.UTC().Format(agentStateAtLayout)` (`GetTerminalSession` keeps only the parsed time; pre-flight F18). A row whose `agent_background_at` does not parse (zero `BackgroundAt`) → `not_stale`, no write — the Desktop already shows it as not background.
  - `busy` (pre-flight F19): Task 0 saw the registry stay `busy` under `claude -p` while the main waited on subagents. Spec §10 "`busy` → leave alone" stays as written here; Task 12 checks an interactive session's `status` while it waits on background agents, and if it reads `busy` the controller raises an owner ask before this branch merges.
  - Stage 1 decision, in this order: no registry entry or `!Alive` → `EndTerminalBackground` → `gone`; `Status == "busy"` → nothing → `busy`; `LatestSubagentWrite` within 30 min → `LowerTerminalBackground(…, now, nil)` → `fresh`; otherwise → `silent` (no write; the Desktop decides on the ping).
  - stdout: one JSON object `{"ok": true, "outcome": "<not_stale|gone|busy|fresh|silent>", "agent_background_at": "<stamp or empty>", "peer": {"available": <bool>, "reason": "<string>"}}`; `peer.available` is computed in Task 13 and always `false` with reason `"not built"` here. On a failure: `{"ok": false, "error": "<one line>"}`, exit 0 (the Desktop reads the envelope; review-rules "Envelope symmetry"). Empty slices/strings never `null`.

- [ ] **Step 1: Write the failing tests:**
  - `TestEndTerminalBackgroundIsCompareAndClear` (db) — clears with the matching stamp; a newer `agent_background_at` → no write; over `working` → no write; other columns untouched.
  - `TestProj11_ProbeNeverStartsBackground` (cmd) — over a NULL-count `waiting` every outcome writes nothing (row byte-identical).
  - `TestSessionProbeStageOneTable` — fake registry/transcript roots via `CLAUDE_CONFIG_DIR` in `t.Setenv`, fake `ProcInfo` through Task 10's exported seam (F17): not stale → `not_stale`, nothing written; no entry → `gone`, count NULL; dead pid → `gone`; busy → `busy`, row unchanged; fresh transcript → `fresh`, only `agent_background_at` advanced; old transcript → `silent`, row unchanged; an unparsable `agent_background_at` → `not_stale`, row unchanged (F18); `gone` clears with the formatted stamp.
  - `TestSessionProbeEnvelopeShape` — success and failure JSON decode into the documented keys; no `null`; exit 0 on a missing row (`ok: false`).
  - `TestSessionProbeNeverTouchesStateOrFinished` — across all outcomes `agent_state`, `agent_state_at`, `finished_at`, `agent_turn_end`, `agent_tool_run` unchanged.
- [ ] **Step 2: Run, expect FAIL** — `go test ./internal/db -run TestEndTerminalBackground > log 2>&1; echo "exit=$?"`; `go test ./cmd -run 'TestSessionProbe|TestProj11_ProbeNeverStartsBackground' > log2 2>&1; echo "exit=$?"`.
- [ ] **Step 3: Implement**, **run, expect PASS** (same commands), `make lint-diff`.
- [ ] **Step 4: Commit** `feat(workbench): session-probe stage 1 ends or refreshes a silent background count (#411)`.

---

### Task 12: Peer messaging protocol discovery + go/no-go (no product code)

The ping uses Claude Code's local session-to-session channel, an undocumented internal. This task decides whether Task 13 builds it.

**Files:**
- Modify: `docs/superpowers/specs/2026-10-10-session-background-agents-design.md` — add Appendix B "Peer messaging channel (observed, Claude Code <version>)"
- Create (go only): `internal/claudesession/testdata/peer_roundtrip.md` and redacted request/response byte fixtures (`peer_request.bin`, `peer_response.bin`)

**Interfaces:**
- Consumes: Task 0 inbound frame and registry fixtures.
- Produces: Appendix B with the frame format (framing, encoding, fields, how the sender is identified, whether the `.key` file or another secret authenticates the sender, the response/ack shape, error replies), which `peerProtocol` values and `peerFeatures` it applies to, and how the receiver treats a message (does it start a turn when idle; does a different permission mode hold it for approval; does it show the message to the owner); and a verdict line **GO** or **NO-GO** with reasons. The verdict states whether the ping needs the `<pid>.<hash>.key` file (pre-flight F20) — Task 13's interface depends on it.

- [ ] **Step 1: Read only.** Inspect the installed Claude Code CLI's handling of `messagingSocketPath` (read-only grep of the installed package; nothing copied into the repo beyond a description in Appendix B) and the Task 0 inbound frame.
- [ ] **Step 2: Round trip on throwaway sessions.** In a scratch folder, start a throwaway interactive `claude` session (default permission mode, as workbench sessions run). Using a scratch client (outside the repo), send it the frame built per Step 1 with the ping text from spec §10; record the response bytes, whether the session started a turn, whether its Stop hook fired (a capture hook as in Task 0), and what the owner sees in that terminal. Repeat with the session in another permission mode, with a wrong/omitted key, and with a closed socket. Also record the registry `status` of an INTERACTIVE session sitting at its prompt while two background subagents run (pre-flight F19: under `claude -p` it stayed `busy`); write it into Appendix B and report it to the controller — `busy` there means spec §10's busy rule needs an owner ask.
- [ ] **Step 3: Decide.** **GO** only if all hold: the frame is reproducible from public inputs the Desktop's user owns (registry entry, and the `.key` file only if the CLI itself uses it for exactly this purpose); an idle default-mode session starts a turn and its Stop hook fires; the owner sees the message as a normal incoming message; failures are detectable (error reply, connect/write error, or no Stop). Anything else → **NO-GO**. Do not attempt to bypass a check the CLI enforces (approval holds, permission modes): that is a NO-GO, not a workaround.
- [ ] **Step 4: Redact and save fixtures** (GO only): ids/paths placeholders, no key material; leak-check the files.
- [ ] **Step 5: Report** the verdict to the controller; on NO-GO the controller raises an owner ask with the reason before Task 13 runs its fallback branch.
- [ ] **Step 6: Commit** `docs(spec): peer messaging channel findings for the staleness ping (#411)`.

---

### Task 13: Go — stage 2 ping (`--ping`, `--expire`) — or the no-go fallback

Run exactly one branch, chosen by Task 12's verdict.

**Files:**
- GO: Create `internal/claudesession/peer.go`, `internal/claudesession/peer_test.go`; modify `cmd/workbench_session_probe.go`, `cmd/workbench_session_probe_test.go`
- NO-GO: modify `cmd/workbench_session_probe.go`, `cmd/workbench_session_probe_test.go` only

**Interfaces:**
- Consumes: Task 11 CLI and `EndTerminalBackground`; Task 12 Appendix B.
- Produces (both branches):
  - `--expire --seen <agent_background_at stamp>` → `EndTerminalBackground(…, seen)` → outcome `expired` (or `not_stale` when the compare-and-clear did nothing because a fresh report landed).
  - `peer.available` / `peer.reason` in every stage-1 envelope.
- GO branch:
  - `const supportedPeerProtocol = <value from Appendix B>`; `func PeerAvailable(e Entry) (bool, string)` — socket path set, `PeerProtocol == supportedPeerProtocol`, required feature(s) present; reason names the failed check.
  - Key (pre-flight F20): if Appendix B's GO needs the `.key` file, `Entry` gains `KeyPath string` (the `<pid>.<hash>.key` beside the entry, found by `FindSession`), read only inside `Ping`, never logged, copied or committed; tests use a temp key file. If GO needs no key, nothing reads a `.key` file.
  - `func Ping(ctx context.Context, e Entry, text string) error` — one connect + one frame + read the ack per Appendix B, 2 s connect / 2 s write / 2 s read deadlines, never retries.
  - `const backgroundPingText` — the spec §10 message, fixed: asks the main agent to check on its background agents, reply in one line and end the turn without starting new work.
  - `--ping` (only after a stage-1 `silent` in the same run of the command; the command re-runs stage 1 first): `PeerAvailable` false → `EndTerminalBackground` → `ping_unavailable`; `Ping` error → `EndTerminalBackground` → `ping_failed`; success → no write → `pinged` (the main agent's Stop re-snapshots through the existing path).
- NO-GO branch: `peer.available` is always `false` with Task 12's reason; `--ping` behaves as `ping_unavailable` (ends the count). The ping code is not written.

- [ ] **Step 1: Write the failing tests:**
  - GO: `TestPeerAvailableGates` (table over socket path / protocol / features); `TestPingWritesTheRecordedFrame` — a test Unix listener (in `t.TempDir()`, closed in `t.Cleanup`) receives bytes equal to `peer_request.bin` modulo the redacted fields and answers `peer_response.bin` → nil; listener closes without ack → error; nothing listening → error within the deadline.
  - `TestSessionProbePingOutcomes` — unavailable → `ping_unavailable` + count NULL; failed write → `ping_failed` + count NULL; success → `pinged`, row byte-identical (GO); NO-GO: `--ping` → `ping_unavailable` + count NULL.
  - `TestSessionProbeExpireIsCompareAndClear` — matching `--seen` clears; a newer report → `not_stale`, nothing cleared.
  - `TestSessionProbePingNeverWhileBusy` — a busy entry with `--ping` → `busy`, no frame sent (listener sees nothing).
- [ ] **Step 2: Run, expect FAIL**, implement, **run, expect PASS** — `go test ./internal/claudesession > log 2>&1; echo "exit=$?"`; `go test ./cmd -run 'TestSessionProbe' > log2 2>&1; echo "exit=$?"`; `make lint-diff`.
- [ ] **Step 3: Commit** GO: `feat(workbench): session-probe pings a silent session over the peer channel (#411)`; NO-GO: `feat(workbench): session-probe ends a silent background count without a ping (#411)`.

---

### Task 14: Desktop — probe trigger, "checking…" caption, ping timeout, docs

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/SessionBackgroundPolicy.swift` (`needsProbe`), `SessionSwitcherPresentation.swift` (`State.backgroundChecking`), `SessionStatePresentation.swift` (caption)
- Create: `WatchtowerDesktop/Sources/Services/SessionBackgroundProber.swift` (owned by `SessionAgentStateCenter`; runs the CLI through `CLIRunnerProtocol`)
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Models/SessionProbeResult.swift` (decoder for the Task 11/13 envelope)
- Modify: `WatchtowerDesktop/Sources/Services/SessionAgentStateCenter.swift`, `WatchtowerDesktop/Sources/Services/TerminalCenter.swift` (`lastOwnerInputAt[id]`, stamped in the terminal delegate's `send(source:data:)` for owner keystrokes only — not for lines `OwnerAsksViewModel.deliver` types)
- Modify: `docs/inventory/workbench.md`, `docs/features/workbench.md`, `docs/app-guide.md` (probe details)
- Test: `Tests/Core/SessionBackgroundPolicyTests.swift` (create), `Tests/Core/SessionProbeResultTests.swift` (create), `Tests/Core/SessionStatePresentationTests.swift`, `Tests/SessionBackgroundProberTests.swift` (create), `Tests/SessionAgentStateCenterTests.swift`

**Interfaces:**
- Consumes: Task 6 seam and clock; Tasks 11/13 CLI envelope (`outcome`, `agent_background_at`, `peer.available`).
- Produces:
  - `SessionBackgroundPolicy.staleAfter: TimeInterval = 30 * 60`; `func needsProbe(count: Int, lastReport: Date, now: Date) -> Bool` (count > 0 and `now - lastReport ≥ staleAfter`). The verdict for `count > 0` stays `.running`: the Desktop never ends a count itself.
  - `SessionAgentStatus.resolve(_:liveIDs:startedAt:now:policy:checking:displayOver:)` gains `checking: Set<Int64> = []` and `displayOver: Set<Int64> = []`, threaded to `effective(…, checking: Bool = false, displayOver: Bool = false)` (pre-flight F8). `displayOver` makes a `count > 0` read as over (no `.background`).
  - `State.backgroundChecking: Bool` — set by `resolve` from the prober's in-flight set (`checking`); caption = the background caption + `" · checking…"` (asks suffix after it).
  - `SessionProbeResult: Decodable` (`ok`, `outcome`, `error`, `agentBackgroundAt`, `peer.available`, `peer.reason`), unknown outcome decodes as `.unknown` (treated like `silent` without a ping: no action, retried next window).
  - `@MainActor final class SessionBackgroundProber` — per session row and run: at most one stage-1 probe per 60 s while `needsProbe`; on `silent` with `peer.available` and all gates (row not Needs approval, registry status not busy — re-checked by the CLI —, no owner input for 2 min, no ping yet in this 30-min silence window of this run) runs `--ping`; on `pinged` marks the session checking with `pingedAt`; 5 min after `pingedAt` with `agent_background_at` unchanged runs `--expire --seen <stamp>`; on `silent` without `peer.available` runs `--ping` (Go ends it as `ping_unavailable`). A new run (`startedAt` changed) or a new `agent_background_at` resets the bookkeeping. CLI calls never on the main actor's critical path (async, one in flight per session); `ok: false` is logged once per streak and retried next window. After 2 consecutive `ok: false` probes for the same `agent_background_at`, the prober puts the session in its in-memory `displayOver` set (passed to `resolve`): the row shows Stopped (one notice, `stopped@agent_state_at`) with no write — Go stays the only writer (pre-flight F24). A new `agent_background_at`, a new run or a successful probe removes it.
  - Notices unchanged: the end is a plain `stopped@agent_state_at` → one notice.

- [ ] **Step 1: Write the failing tests:**
  - `SessionBackgroundPolicyTests.testNeedsProbeTable` — count 2 at 29:59 → false, 30:00 → true; count 0 → false; future stamp → false.
  - `SessionProbeResultTests.testDecodesEveryOutcomeAndTheFailureEnvelope` — fixtures for each outcome; `ok: false` with `error`; an unknown outcome.
  - `SessionStatePresentationTests.testCheckingCaption` — "2 agents working · checking…", with asks "2 agents working · checking… · 1 ask open".
  - `SessionBackgroundProberTests` (fake runner + injected clock + fake owner-input map):
    - `testNoProbeBeforeThirtyMinutes`, `testStageOneAtMostOncePerMinute`;
    - `testSilentWithPeerPingsOnceAndShowsChecking`; `testNoPingWithinTwoMinutesOfOwnerInput` (ping deferred, not skipped); `testNoPingAtNeedsApproval`;
    - `testPingWithoutAStopExpiresAfterFiveMinutes` — runs `--expire --seen` with the stamp read before the ping; `testAStopAfterThePingCancelsTheExpiry`;
    - `testOnePingPerSilenceWindowPerRun` — a second silent window after a fresh report may ping again; the same window never;
    - `testANewRunResetsTheBookkeeping`; `testOneFailedProbeNeverEndsTheCount` (one `ok: false` → no `--expire`, no `--ping`, still `.background`); `testTwoFailedProbesShowTheCountOverWithoutAWrite` (two consecutive `ok: false` for the same stamp → session in `displayOver`, no `--expire`/`--ping` run; a new stamp or run clears it).
  - `SessionAgentStateCenterTests.testAProbeThatEndsTheCountPostsOneStoppedNotice` — fake reader: count 2 old stamp → prober `gone` → next read count NULL → `.stopped`, exactly one notice.
  - `SessionAgentStateCenterTests.testTwoFailedProbesShowStoppedOnceWithoutAWrite` — fake runner answers `ok: false` twice, the row (count 2, old stamp) never changes → `.stopped` published, exactly one notice; then a new `agent_background_at` → `.background` again.
- [ ] **Step 2: Run, expect FAIL** — `make test-swift FILTER='SessionBackgroundPolicyTests|SessionProbeResultTests|SessionStatePresentationTests|SessionBackgroundProberTests|SessionAgentStateCenterTests' > log 2>&1; echo "exit=$?"`.
- [ ] **Step 3: Implement**, **run, expect PASS** (same command; check the log for XCTest failures), `make lint-diff`.
- [ ] **Step 4: Docs.** Inventory PROJ-11: Task 9 already holds the probe paragraph and its v1 limits (F13); here only the "checking…" caption, the NO-GO edit if Task 12 said so (stage-2 sentence → "Otherwise the count ends", reason in v1 limits), and the new guard names. `docs/features/workbench.md` and `docs/app-guide.md`: the "checking…" caption and what the owner sees in the terminal when pinged. Verify guard names as in Task 9 Step 2.
- [ ] **Step 5: Commit** `feat(desktop): probe silent background sessions, checking caption, ping timeout (#411)`.

---

### Task 15: Final gate

**Files:** none expected (fixes only, each its own commit).

- [ ] **Step 1:** `bash scripts/dev-health.sh > health.log 2>&1; echo "exit=$?"` — if the last line is `HEALTH: overloaded`, stop and report to the controller.
- [ ] **Step 2:** `make test > gate-go.log 2>&1; echo "exit=$?"` → `exit=0`.
- [ ] **Step 3:** `make test-swift > gate-swift.log 2>&1; echo "exit=$?"` → `exit=0`; grep the log for XCTest failures (not only the swift-testing tail).
- [ ] **Step 4:** `make lint-all > gate-lint.log 2>&1; echo "exit=$?"` → `exit=0`.
- [ ] **Step 5:** Self-check against the spec: every row of §4.2 and every bullet of §10 has a test; every §7 guard name exists (`grep`; spec §7 carries the plan's names since the pre-flight scan, F9); no `.key` file or real id in the diff (`bash scripts/leak-check.sh` over the branch); migration number still free against `origin/main` (`git fetch && git ls-tree origin/main internal/db/migrations/ | tail -2`), renumber if not (rename + golden + Swift schema regen, own commit).
- [ ] **Step 6:** Hand back to the controller for the `local-review` / `debate-review` pass and the manual check ask (Re-run Setup on a real folder; two background subagents show "2 agents working", count down, Stopped once with one notice; a session left silent 30 min is probed — and, on GO, pinged once with "checking…").
