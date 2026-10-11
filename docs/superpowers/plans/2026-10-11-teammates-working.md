# Teammates in their turn count as Agents working (board #543) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (one lane, small change). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A named agent-team teammate counts toward "N agents working" only while it is inside its own turn (owner, ask #167); a finished subagent still listed in `background_tasks` stops counting at its `SubagentStop` (#543 tail 3).

**Architecture:** A Go-only JSON column `terminal_sessions.agent_turns` records, per hook `agent_id`, the last `SubagentStart` and `SubagentStop` stamps (forward-only). The Stop and `SubagentStop` count = listed subagents/workflows not closed + open turns not listed, capped by the listed teammates. A new async `SubagentStart` state hook opens turns. The count columns, the Desktop and the presentation are unchanged.

**Tech Stack:** Go 1.25 (`cmd/`, `internal/db`, `internal/devpack`), SQLite + goose.

**Spec:** `docs/superpowers/specs/2026-10-10-session-background-agents-design.md` §11 and Appendix C; business page decision 6.

**Plan style:** no code bodies; interfaces, test cases and commands only.

## Global Constraints

- Only the Stop sets a count; `SubagentStart` never writes `agent_state`, `agent_state_at`, `finished_at`, the turn order or `agent_background*`; `SubagentStop` only lowers.
- `agent_turns` is Go-only (not in the Swift row), cleared by a new run and a conversation switch, never by a main turn.
- Empty `agent_type` or `agent_id` → the turn is not recorded (internal agents).
- Core four state hooks still gate the Stop write and run mark; `state_hooks` needs all six.
- Inner loop only: `go test ./internal/db`, `go test ./internal/devpack`, `go test ./cmd -run '<regex>'`, `make lint-diff`; logs to files with explicit exit codes.
- Fixtures carry placeholders only (no real session ids, agent ids, names or local paths).

## Task 1: Migration 00108 and the db write path

**Files:** `internal/db/migrations/00108_terminal_session_agent_turns.sql`, `internal/db/schema.sql`, `internal/db/terminal_sessions.go`, goldens + `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (regenerated), `internal/db/terminal_sessions_test.go`.

**Interfaces:**
- `ALTER TABLE terminal_sessions ADD COLUMN agent_turns TEXT` (Down: DROP COLUMN).
- `type AgentTurn struct{ Start, Stop string }` (stamps, `agent_state_at` layout); `type AgentTurns map[string]AgentTurn` with `Open(id) bool`, `Closed(id) bool`.
- `TerminalSession.AgentTurns AgentTurns` (an unreadable value reads as empty).
- `func (db *DB) RecordTerminalAgentTurn(id, workbenchID int64, sessionID, agentID string, start bool, at time.Time) (AgentTurns, error)` — one `BEGIN IMMEDIATE` read-modify-write with the row guards of `SetTerminalAgentState`; moves `start` or `stop` forward only; caps at 256 entries (oldest closed first, then oldest); returns the stored map (nil, nil when a guard held it back).
- `MarkTerminalAgentRun`, `ClearTerminalAgentState` (its "something to clear" clause gains `agent_turns IS NOT NULL`), `SetTerminalClaudeSessionID` NULL the column.

**Tests:** `TestProj11_AgentTurnStampsOnlyMoveForward` (late older start/stop never moves back, start == stop is closed), `TestProj11_AgentTurnsCapDropsOldestClosed`, `TestProj11_AgentTurnWriteNeverTouchesTheState` (every other column byte-identical; another conversation or workbench writes nothing), `TestProj11_NewRunAndConversationSwitchClearTheCount` extended (the three resets NULL `agent_turns`, a row holding only turns is cleared). `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`, then `go test ./internal/db`.

## Task 2: The count and the hooks

**Files:** `cmd/workbench_check.go`, `cmd/workbench_session_state.go`, `cmd/workbench_check_test.go`, `cmd/workbench_session_state_test.go`, `cmd/testdata/*.json` (Appendix C fixtures).

**Interfaces:**
- `backgroundTask` keeps `ID`, `Type`. `backgroundSubagents(tasks, except)` is replaced by `func backgroundAgents(tasks backgroundTasks, turns db.AgentTurns) (n int64, ok bool)` (spec §11.3).
- `hookTurn` carries the Stop's `tasks`; `recordAgentState` computes `turn.background` from the read row's `AgentTurns` (the Stop's count needs the stored turns).
- `agentStateFor("SubagentStart", _)` → `("", "", true)`. `recordHookAgentState` routes `SubagentStart` to `RecordTerminalAgentTurn(start)` and `SubagentStop` to `RecordTerminalAgentTurn(stop)` then, with a list, `recordBackgroundReport` with the count over the returned turns.

**Tests:** `TestBackgroundAgentsCountTable` (old cases: 2 subagents + shell + teammate → 2, empty → 0 ok, absent/null/object → not ok, malformed entries; new: closed subagent listed → not counted, reopened (resumed) subagent counted, open teammate turn + teammate entry → 1, two open turns but one teammate entry → 1, open turn with no teammate entry → 0, open turn whose id is a listed subagent counted once), `TestProj11_TeammateCountsOnlyInItsTurn`, `TestProj11_FinishedSubagentStillListedIsNotCounted`, `TestProj11_SubagentStartNeverStartsOrRaisesTheCount`, `TestProj11_LostTeammateStopIsCappedByTheList`, `TestStopHookInputParsesTheCapturedFixtures` extended to the new fixtures; `TestProj11_OnlyTheStopStartsBackground`, `TestProj11_HookNeverWritesStdoutAndExitsZero`, `TestProj11_NestedSessionNeverMovesTheRow` extended with `SubagentStart`. `go test ./cmd -run 'TestProj11_|TestBackgroundAgents|TestStopHookInput|TestSessionState'`.

## Task 3: Hook pack

**Files:** `internal/devpack/workbench_settings.go`, `internal/devpack/workbench_state_hooks_test.go`, `cmd/integrate_workbench.go` (doc text), `cmd/workbench_session_state.go` (`Long`), `WatchtowerDesktop/Sources/Services/WorkbenchCLI.swift` (doc comment only).

**Interfaces:** `stateHookSpecs = append(coreStateHookSpecs, SubagentStop, SubagentStart)`.

**Tests:** `TestInstallStateHooksAddsSubagentStopAndStart` (was `…AddsSubagentStop`), `TestHasStateHooksNeedsAllSixCoreNeedsFour` (was `…AllFive…`), PROJ-04 malformed-event guard extended to `SubagentStart`. `go test ./internal/devpack`, `go test ./cmd -run 'TestProj04_|TestProj11_StopStateWriteNeedsOnlyTheCoreHooks|TestIntegrateWorkbench'`.

## Task 4: Docs and gate

- `docs/inventory/workbench.md`: PROJ-04 (six state hooks), PROJ-11 amendment paragraph + guards + v1 limits + changelog line (owner approved in ask #167).
- `docs/features/workbench.md`: the Agents working bullet. `docs/app-guide.md` only if UI text changes (it does not).
- `gocyclo -over 13` on touched packages, `bash scripts/sentrux-gate.sh`; full gate once: `make test`, `make lint-all`.
