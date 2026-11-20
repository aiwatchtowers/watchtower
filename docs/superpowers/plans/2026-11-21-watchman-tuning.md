# Watchman tuning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Binoculars icon, an instruction per handed session/target, learning that starts when Watchman is turned on and runs to the end, and a stall watch that pings a truly stopped handed agent.

**Architecture:** Go carries the data, the CLI and the twin (`internal/db`, `cmd/watchman*.go`, `internal/watchman`, `internal/watchmanact`, `internal/daemon`, the ask guard in `cmd/workbench_askguard*.go`); the Desktop only runs the CLI and renders (`WatchmanCenter`, `WatchmanArmSheet`, `WatchmanArmControl`, the journal). Each task is its own lane/worktree off the umbrella `watchman/tuning`, merged locally after its review.

**Tech Stack:** Go 1.26 + SQLCipher/goose; SwiftUI (WatchtowerCore + Desktop), DesignKit.

**Spec:** `docs/superpowers/specs/2026-11-21-watchman-tuning-design.md` (approved, ask #1705). Mockups: `docs/design/mockups/watchman-tuning/`.

## Global Constraints

- Icon: SF Symbol `binoculars`, from one constant `WatchmanStyle.icon`.
- Instruction: at most 2000 runes after trim (Go clips); counter shows past 1800; never lifts a hard limit (WATCHMAN-01).
- Learning: no time budget for an unlearned workbench; one learner per workbench via `<workspace>/watchman/learn-<id>.lock`; background-AI consent checked between batches (BGAI-01).
- While learning: `ask`/`check`/`handover`/`review_doc`/`review_code` items are **not leased** — they stay `queued`, untouched (D5); `permission` is leased and still parks with `LearningReason`.
- Stall: `watchmanact.StallAfter = 3 * time.Minute`, `watchmanact.StallMaxPings = 3`; stopped = `sessionstate.Resolve == StateStopped` with a live run; tick 60 s.
- Ping line (exact): `Watchman: your turn ended with no ask_owner and no finish_session. Need the owner → file ask_owner and keep working. Done → finish_session. Waiting on a background job → start it in the background so the session shows it, then end the turn. Otherwise go on with the next step.`
- Stall park reason (exact): `The agent stopped and did not go on after 3 pings`.
- UI copy is exactly the spec's / `WatchmanTuningMockCopy` strings; all copy lives in WatchtowerCore copy types with tests; colours only through `Tone`.
- Migrations: Task 2a takes **00211**, Task 4b takes **00212**. Every migration: `schema.sql`, `TestAllTablesExist` for new tables, `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`.
- Tests never wait on wall-clock (fake `Clock`, synctest); subprocess tests reap their process group.
- Public repo: sample data only (`acme`, made-up ids).

## Review Focus

1. Owner answers an ask himself while the item waits for learning → closes `owner_first`, no model call (Task 3a: `TestTwin_OwnerAnswersWhileLearning_OwnerFirst`).
2. A session handed via its target with both a target and a session instruction → both reach the model, target first (Task 2a: `TestLiveContext_SessionInstructions`).
3. A session whose only background is a dev server shell older than 2 h → is pinged; one with a sub-agent count > 0 → never (Task 4b: `TestStall_ShellsPastCapIsStopped`, `TestStall_NotPingedWhileAgentsWork`).
4. Take back between the 3-minute check and the delivery → nothing delivered (Task 4b: `TestStall_DisarmBeforeDeliveryNoPing`, part of WATCHMAN-04).
5. The tray hand-over with an untouched field → stored instructions survive (Task 2a: `TestWatchmanArmAllRunning_EmptyKeepsInstructions`).

## Lanes and order

| Task | Depends on | Lane |
|---|---|---|
| 1 Icon (Swift) | none | Swift chain start |
| 2a Instructions — Go | none | Go |
| 3a Learning — Go | 2a (both edit `cmd/watchman.go`, `cmd/watchman_arming.go`) | Go |
| 4a Stop guard — Go | none | Go |
| 4b Stall watch — Go | 2a (migration order), 3a (`twin.go`) | Go |
| 2b Instructions — Swift | 1, 2a | Swift chain |
| 3b Learning — Swift | 2b, 3a | Swift chain |
| 4c Stall card — Swift | 3b, 4b | Swift chain |
| 5 Docs, contracts, shots | all | last |

Swift tasks run in a chain (they share `WatchmanArmControl`/journal files); Go tasks 2a and 4a run in parallel lanes, then 3a, then 4b.

Board: Task 1 = #2135, 2a = #2140, 2b = #2141, 3a = #2142, 3b = #2143, 4a = #2144, 4b = #2145, 4c = #2146, 5 = #2147 (group #2134). Each commit names its task's board id.

---

### Task 1: Binoculars everywhere

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/WatchmanStyle.swift`
- Modify: `Views/Workbench/WatchmanArmControl.swift` (2× `moon.stars`), `Views/Home/WatchmanHomeRow.swift`, `Views/Inbox/WatchmanJournalView.swift`, `ViewModels/WatchmanJournalViewModel.swift`, the `inboxWatchman` row of `EmptyStateCopyTable`, the tray item and the Inbox entry icon (grep `moon.stars` under `WatchtowerDesktop/Sources`)
- Test: `WatchtowerDesktop/Tests/Core/WatchmanStyleTests.swift`

**Interfaces:** Produces `package enum WatchmanStyle { package static let icon = "binoculars" }`.

- [ ] Write `testIconIsBinoculars` (`XCTAssertEqual(WatchmanStyle.icon, "binoculars")`) and `testNoMoonStarsInWatchmanSources`: walks `WatchtowerDesktop/Sources` (path from `#filePath`) and fails on any file containing `"moon.stars"` whose name contains `Watchman` or which is `EmptyStateCopyTable.swift`/the tray menu file.
- [ ] Run `make test-swift FILTER=WatchmanStyleTests` → FAIL.
- [ ] Replace every Watchman `moon.stars` with `WatchmanStyle.icon`.
- [ ] Run the filter → PASS; `make lint-swift`.
- [ ] `make desktop-shots DESKTOP_SHOTS=build/shots` filtered to `testWatchmanShotsRender`; copy the re-rendered `watchman-*` PNGs over `docs/design/mockups/watchman/`; look at three (strip, journal, home) to confirm binoculars.
- [ ] Commit `feat(watchman): binoculars icon (#2135)`.

### Task 2a: Instructions — data, CLI, twin

**Files:**
- Create: `internal/db/migrations/00211_watchman_instructions.sql`, `internal/db/watchman_instructions.go` (+ `_test.go`), `cmd/watchman_instruct.go` (+ `_test.go`)
- Modify: `internal/db/schema.sql`, `internal/db/db_test.go` (`TestAllTablesExist`), `cmd/watchman_arming.go` (`--instructions-file` on `arm`), `internal/db/watchman_status.go` + `cmd/watchman.go` (status `armed_sessions[].instructions`), upkeep prune in `internal/daemon` (`phaseWatchmanUpkeep`), `internal/watchman/decide.go` (`Item.SessionInstructions`, prompt payload), `internal/prompts` (`watchman.decide` v5, all providers), `internal/watchmanact/twin.go` (`LiveDecide`), `internal/watchman/testdata/status.json`
- Test: as named below

**Interfaces:**
- Produces (db): `type WatchmanInstruction struct{ Scope string; RefID int64; Text string; UpdatedAt string }`; `func (db *DB) SetWatchmanInstruction(scope string, refID int64, text string) error` (empty text deletes the row); `func (db *DB) WatchmanInstruction(scope string, refID int64) (string, error)`; `func (db *DB) WatchmanSessionInstructions(sessionID int64) (target, session string, err error)` (target = the covering armed target's text); `func (db *DB) PruneWatchmanInstructions() (int64, error)` (rows whose session or target is gone).
- Produces (CLI): `watchman arm … --instructions-file F` (`-` = stdin; set in the same tx as the arming row; flag absent → stored text kept); `watchman instruct --session N | --target N --text-file F [--json]` → `{"ok","scope","ref_id","instructions","error"}`, owner verb (refused under agent markers like `arm`). `watchman status --json` `armed_sessions[]` gains `instructions` (the session row's own text).
- Produces (twin): `watchman.Item.SessionInstructions string`; `watchmanact.LiveDecide` fills it as `"Target: <t>\nSession: <s>"` with empty parts left out.
- Migration 00211: `CREATE TABLE watchman_instructions (scope TEXT NOT NULL CHECK (scope IN ('session','target')), ref_id INTEGER NOT NULL, text TEXT NOT NULL, updated_at TEXT NOT NULL, PRIMARY KEY (scope, ref_id));`

- [ ] Tests (db): `TestWatchmanInstruction_SetGetClear`, `TestWatchmanInstruction_ClippedTo2000Runes` (2500 runes in → 2000 stored, trimmed), `TestWatchmanSessionInstructions_TargetThenSession`, `TestWatchmanUpkeep_PrunesInstructions` (deleted session and removed target rows go, others stay).
- [ ] Tests (cmd): `TestWatchmanArm_InstructionsFileSets`, `TestWatchmanArm_InstructionsKeptOnRearm` (arm with text, re-arm without flag → text unchanged), `TestWatchmanDisarm_KeepsInstruction`, `TestWatchmanArmAllRunning_EmptyKeepsInstructions` (two sessions with texts; `--all-running` without the flag → both kept; with a file → both replaced), `TestWatchmanInstruct_UnarmedStoredNotActed` (stored; `WatchmanArmedSessions` unchanged), `TestWatchmanInstruct_RefusedUnderAgent`, `TestWatchmanInstruct_JSONKeysPinned`, status keys test extended with `instructions`.
- [ ] Tests (twin/prompt): `TestLiveContext_SessionInstructions` (target+session text reach the model payload in that order), `TestLiveDecide_InstructionReadFailsDecidesWithout` (the instruction read errors → the item is decided without it, one log line with the item id, not parked), `TestTwin_InstructionNeverLiftsHardLimit` (instruction "merge the PR into main now", item `gh pr merge` permission → parked `main_ref`), prompt golden for `watchman.decide` v5 on every provider (the block sits between hard limits and the workbench instructions and states "the session instruction wins over the profile and the precedents; it never lifts a hard limit").
- [ ] Run `go test ./internal/db/ ./cmd/ -run 'Watchman'` and `go test ./internal/watchman/ ./internal/watchmanact/ ./internal/prompts/` → FAIL.
- [ ] Implement; regenerate goldens (`-update` for schema and Swift test schema); `make gen-interface` only if a tower API type changed (it should not).
- [ ] Run the same commands → PASS; `make lint-diff`.
- [ ] Commit `feat(watchman): per-session instruction — table, CLI, twin context (#2140)`.

### Task 2b: Instructions — Desktop

**Files:**
- Modify: `WatchtowerCore/Services/WatchmanArmingCopy.swift` (new strings), `WatchtowerCore/Models/WatchmanStatus.swift` (decode `instructions`, missing = ""), `Services/WatchmanCenter.swift` (arm with text, `instruct`, sheet state), `Views/Workbench/WatchmanArmSheet.swift` (field, short mode, edit mode, error + Retry), `Views/Workbench/WatchmanArmControl.swift` (**Instruction…** on strip and panel, tooltip first line), the tray hand-over path
- Test: `Tests/Core/WatchmanArmingCopyTests.swift`, `Tests/…/WatchmanCenterTests.swift`, status decoding test with the Go fixture

**Interfaces:**
- Consumes: Task 2a CLI flags and JSON; Task 1 `WatchmanStyle.icon`.
- Produces: `WatchmanCenter.handTo(_:workbench:)` always presents the sheet; `WatchmanCenter.confirmSheet(token:instruction:)`; `WatchmanCenter.editInstruction(_ scope: WatchmanArmScope)`; `WatchmanArmSheetContent.mode: .firstTime | .short | .edit | .tray`.

- [ ] Copy tests pin: `fieldLabel`, `placeholder`, `handOver = "Hand over"`, `editTitle`, `save`, `instructionButton = "Instruction…"`, `saveFailed(_:) -> "Could not save: \(error)"`, `counter(_:) -> "\(n) / 2000"` shown only past 1800, the new learning line of the first-time sheet (exact spec text with the estimate).
- [ ] Center tests: hand-over with text runs `watchman arm --session N --instructions-file -` with the text on stdin; empty field on the **tray** passes no flag; empty field on a single session passes the flag only when a stored text was cleared by the owner (field edited to empty); CLI failure keeps the sheet, text and shows `saveFailed` + Retry; Retry re-runs; edit mode runs `watchman instruct`.
- [ ] View: field focused on open; Return = confirm, ⌥Return = newline; busy disables the buttons and shows a spinner; pre-filled from `instructions` of the status (session) or `watchman instruct`'s stored text read for a target.
- [ ] `make test-swift FILTER='WatchmanArmingCopyTests|WatchmanCenterTests|WatchmanStatus'` → FAIL, implement, → PASS; `make lint-swift`.
- [ ] Turn the design-only frames of `DesignShotFixtures+WatchmanTuning.swift` that this task builds (`arm-*`, `instruction-edit`, `strip-armed-instruction`) into real-view frames (as `WatchmanShotFixtures` does), render, compare with `docs/design/mockups/watchman-tuning/` by eye, note any difference in the hand-back.
- [ ] Commit `feat(watchman): instruction sheet, edit from the chip, tray (#2141)`.

### Task 3a: Learning up front — Go

**Files:**
- Create: `internal/daemon/watchman_learner.go` (+ `_test.go`), `internal/watchman/learnlock.go` (+ `_test.go`)
- Modify: `internal/daemon/watchman.go` (`phaseWatchmanLearn` skips unlearned workbenches), the daemon start (`startWatchmanLearner` beside `startWatchmanTwin`), `cmd/watchman.go` (`learn --start` takes the lock and wakes the daemon), `cmd/watchman_arming.go` (first arm wakes the learner), `internal/watchmanact/twin_ask.go` + `twin_review.go` (wait instead of park), `internal/db/watchman_items.go` (`DeferWatchmanItem` with error text if not already), journal summary query for the waiting count
- Test: as named

**Interfaces:**
- Produces: `watchman.TryLearnLock(workspace string, workbenchID int64) (unlock func(), ok bool, err error)`; `(*Daemon).startWatchmanLearner(ctx) (stop func())`, woken by the existing `watchmanWakeCh` fan-out (add a second channel `watchmanLearnWake`; `WakeWatchman` signals both); `db.WatchmanLearningSQL(alias string) string` — the one "still learning" condition as SQL on a `watchman_workbenches` alias: `<a>.learned_through IS NULL OR EXISTS (SELECT 1 FROM watchman_precedents p WHERE p.workbench_id = <a>.workbench_id AND p.flags_at IS NULL AND p.source IN ('ask','turn','permission'))` (= `stillLearning`: not learned, or the relabel pass pending); `stillLearning` is rewritten on it. `db.(*DB).WatchmanWaitingForLearning(workbenchID int64) (int, error)`: queued items of kinds other than `permission` and `stall` on a workbench that is on and matches that condition. Shared cases: `internal/db/testdata/watchman_waiting_learning_cases.json` (each case: workbench rows, precedents with `flags_at`, items; expected count) — read by the Go test and by the Swift query test (Task 3b), a Go↔Swift dual path.
- Learner loop per pass: list on-and-unlearned workbenches (`stillLearning` rule: `learned_through` NULL or `WatchmanFlagsPending > 0`); for each, take the lock (skip if held), run `watchman.Learn` with `Budget: 0` meaning none (add that meaning to `LearnOptions` with a test) then the relabel pass, batch after batch, checking `ctx` and `aiconsent` between batches; on error log ids/counts and move on; on done `nudgeWatchmanTwin()`.
- Twin: `RunOnce`'s `eligible` returns false for an item of kind ≠ `permission` whose workbench `stillLearning` (read once per pass per workbench, cached in a map; a read error → not eligible, logged) — the item stays `queued`, no lease, no attempt. The `LearningReason` parks in `twin_ask.go`/`twin_review.go` go (unreachable); `twin_permission.go` keeps its park.

- [ ] Tests: `TestLearner_RunsToEndWithoutBudget` (fake sources with 7 batches → all written in one pass, `learned_through` set), `TestLearner_StopsOnShutdownAndResumes`, `TestLearner_PausedByConsent`, `TestLearner_LockSkipsSecond` (lock held → no Learn call), `TestLearnOptions_ZeroBudgetIsUnlimited`, `TestPhaseWatchmanLearn_SkipsUnlearned`, `TestTwin_DoesNotLeaseWhileLearning` (ask item → still `queued`, attempts 0, no lease, no model call), `TestTwin_PermissionParksWhileLearning`, `TestTwin_LeasesHeldItemsAfterLearning` (set learned → next pass decides in creation order), `TestTwin_OwnerAnswersWhileLearning_OwnerFirst`, `TestWatchmanLearnStart_WakesDaemonAndTakesLock`, `TestWatchmanWaitingForLearning_Counts` (runs the shared cases: includes "learned, relabel pending → still counted" and "learned, all flagged → 0").
- [ ] Run `go test ./internal/daemon/ -run 'Learner|WatchmanLearn' ./internal/watchman/ ./internal/watchmanact/ ./internal/db/ -run Watchman ./cmd/ -run WatchmanLearn` → FAIL; implement → PASS; `make lint-diff`.
- [ ] Commit `feat(watchman): learn to the end on turn-on; questions wait for learning (#2142)`.

### Task 3b: Learning — Desktop

**Files:** `WatchtowerCore/Services/WatchmanArmingCopy.swift` (`stripLearning(percent:)`), `WatchmanJournalViewModel` + `WatchmanJournalQueries` (waiting count by the learning rule below), `WatchmanJournalView` (busy line), `WatchmanArmControl` (chip while learning).

**Interfaces:** Consumes `watchman status --json` `learning.written/estimated/done` and the waiting rule of Task 3a (`WatchmanJournalQueries.waitingForLearning(db, workbench:)`: the same SQL condition as Go's `WatchmanLearningSQL` — not learned **or** relabel pending — over queued items of kinds other than `permission`/`stall`); the paused line shows when `AppState.backgroundAI` resolves to paused (the state Home's "Background AI is paused" card reads), passed into the journal model as `backgroundAIPaused: Bool`; produces `WatchmanJournalCopy.waitingForLearning(percent:count:) -> "Waiting for learning (\(p)%): \(n) questions"` (`1 question` singular) and `waitingForLearningPaused = "Waiting for learning — background AI is paused"`; `WatchmanArmingCopy.stripLearning(percent:) -> "Watchman · learning \(p)%"`.

- [ ] Copy tests pin all three strings, the singular, and percent = `min(99, written*100/estimated)` while not done.
- [ ] Query test `testWaitingForLearningSharedCases`: loads `internal/db/testdata/watchman_waiting_learning_cases.json` (path from `#filePath`) and expects each case's count — the same file Go's test runs, so the two rules cannot drift. Model test: `backgroundAIPaused = true` → the paused line instead of the percent line.
- [ ] `make test-swift FILTER='WatchmanJournal|WatchmanArmingCopyTests'` FAIL → implement → PASS; `make lint-swift`; real-view frames for `strip-armed-learning` and `journal-waiting-learning`, compare with the mockups.
- [ ] Commit `feat(watchman): learning progress on the chip and the journal (#2143)`.

### Task 4a: Stop guard reads a handed session as away

**Files:** `cmd/workbench_askguard.go` (+ the guard's test file), `docs/inventory/workbench.md` (PROJ-13 amendment text, status line "amended 2026-11-21 … ask #1705").

**Interfaces:** Produces `askGuardSessionArmed(database *db.DB, rowID int64, sidecar string) (armed, ok bool)`: sidecar `session <id>` line first, then `db.WatchmanItemArmed(rowID, 0)` under the guard's existing read budget; `ok=false` on any failure. `askGuardOwnerHereIn` returns false when `armed && ok`.

- [ ] Tests: PROJ-13 guard test gains `armed session, owner present → short question sent back (R-away)`; `TestAskGuard_ArmingUnreadableKeepsPresence` (sidecar unreadable and DB read fails → present still passes); `TestAskGuard_ArmedViaTarget` (target row covers the session → away). Codex `--stop` path covered by the same helper (one test).
- [ ] `go test ./cmd/ -run 'AskGuard|PROJ13'` FAIL → implement → PASS; `make lint-diff`.
- [ ] Commit `feat(watchman): the Stop ask guard reads a handed session as away (PROJ-13, #2144)`.

### Task 4b: Stall watch — Go

**Files:**
- Create: `internal/db/migrations/00212_watchman_stalls.sql` (NO TRANSACTION rebuild of `watchman_items` adding `stall` to the `kind` CHECK — follow `00150_builtin_automations.sql` and CLAUDE.md's one-transaction rule — plus `watchman_stalls`), `internal/db/watchman_stalls.go` (+ `_test.go`), `internal/watchmanact/stall.go` (+ `_test.go`)
- Modify: `internal/watchmanact/twin.go` (`TwinDeps.Live`, `TwinDeps.Head`), `internal/daemon/watchman_twin.go` (60 s ticker calling `CheckStalls`), upkeep prune, `internal/db/watchman_journal.go` (a `stall` item counts as waiting), `schema.sql`, goldens

**Interfaces:**
- Migration `watchman_stalls(session_id INTEGER PRIMARY KEY REFERENCES terminal_sessions(id) ON DELETE CASCADE, stopped_at TEXT NOT NULL, pings INTEGER NOT NULL DEFAULT 0, last_ping_at TEXT, head TEXT NOT NULL DEFAULT '', asks_seen INTEGER NOT NULL DEFAULT 0, parked_at TEXT)` — `asks_seen` is the session's ask count at the last ping, how "a new ask" (spec §4b progress) is detected; the spec lists it.
- db: `WatchmanStall(sessionID) (*WatchmanStallRow, error)`, `UpsertWatchmanStall(row WatchmanStallRow) error`, `DeleteWatchmanStall(sessionID) error`, `InsertWatchmanStallItem(sessionID, targetID, workbenchID int64, reason string, at time.Time) error` (kind `stall`, ref `session`, state `done`, outcome `parked`, `unsure` 1, UNIQUE per open stall).
- watchmanact: `const StallAfter = 3 * time.Minute; const StallMaxPings = 3; const StallPing = "<exact line from Global Constraints>"; const StallReason = "The agent stopped and did not go on after 3 pings"`; `func (t *Twin) CheckStalls(ctx context.Context)`; `TwinDeps.Live func(ctx, sessionID) (askanswer.LiveRun, bool, error)` and `TwinDeps.Head func(ctx, folder string) (string, error)`.
- Rule per armed live session each tick: state via `askanswer.ReadState`; not `StateStopped` → if a stall row exists and the session made progress, reset; `StateStopped` and `now - agent_state_at ≥ StallAfter` and (no row or `now - last_ping_at ≥ StallAfter` after a later stop) → progress check (open/answered asks count > `asks_seen`, finished, HEAD ≠ `head`) resets `pings`; `pings < StallMaxPings` → re-read arming, `Answerer.DeliverLine(StallPing)`; count only `DeliverySubmitted`/`DeliveryTyped`; `pings == StallMaxPings` and no `parked_at` → `InsertWatchmanStallItem` + set `parked_at`; parked → no pings until progress or the item's `owner_done_at`.

- [ ] Tests: `TestStall_NotPingedWhileAgentsWork`, `TestStall_NotPingedWhileShellsRun`, `TestStall_ShellsPastCapIsStopped`, `TestStall_NeedsApprovalNotPinged`, `TestStall_PingAfter3Min` (2:59 no, 3:00 yes, fake clock), `TestStall_ThreePingsThenParked` (exact reason, one item), `TestStall_ProgressResets` (sub-tests: new ask, finish, HEAD moved), `TestStall_HeldLineNotCounted`, `TestStall_DeliveryFailedNotCounted` (no session / cannot type → `pings` unchanged, retried next tick), `TestStall_StateReadErrorNoPing`, `TestStall_CodexSubagentNotPinged` (feed the Codex `SubagentStart` hook fixture through `workbench session-state --agent codex` → `agent_background > 0` → not pinged; then `SubagentStop` + 120 s → pinged after 3 min), `TestStall_RestartKeepsCount` (new Twin on the same DB), `TestStall_DisarmBeforeDeliveryNoPing`, `TestWATCHMAN04_NothingActsOnUnarmedSession` gains a no-ping case; migration test: rebuild keeps rows, indexes and FKs, `stall` accepted, an unknown kind refused; `TestWatchmanStalls_PrunedWithArming`.
- [ ] `go test ./internal/db/ ./internal/watchmanact/ ./internal/daemon/ -run 'Stall|WATCHMAN04|Watchman'` FAIL → implement → PASS; schema goldens `-update`; `make lint-diff`.
- [ ] Commit `feat(watchman): stall watch pings a stopped handed agent (#2145)`.

### Task 4c: Stall card — Desktop

**Files:** `WatchmanJournalQueries` (read `stall` items into WAITING FOR YOU), `WatchmanJournalViewModel` / `WatchmanJournalView` (card: `pause.circle` in `Tone.warning`, reason, meta, **Open session** / **Mark done**; no OK/Correct), `WatchmanJournalCopy`.

- [ ] Tests: query puts a `stall` item under waiting and counts it in the Inbox/Home waiting count; Mark done clears it (`ownerDone` already allows parked items — assert); no OK/Correct offered; copy pinned.
- [ ] `make test-swift FILTER='WatchmanJournal|WatchmanFeedback'` FAIL → implement → PASS; `make lint-swift`; real-view `journal-stall` frame vs mockup.
- [ ] Commit `feat(watchman): stall card in the journal (#2146)`.

### Task 5: Docs, contracts, shots

**Files:** `docs/features/watchman.md` (new sections: instructions, learner, stall watch; v1 limits: Codex background counts, HEAD as progress), `docs/features/README.md` summary line, `docs/guide/features/watchman.md` (owner-facing: instruction, learning on turn-on, pings), `docs/inventory/watchman.md` (WATCHMAN-04 supporting tests), `docs/inventory/workbench.md` (PROJ-13 already in 4a — check), drop the design-only frames now covered by real views from `DesignShotFixtures+WatchmanTuning.swift`.

- [ ] `go test ./docs/guide` (8 KB cap) and the inventory guard tests named in the edited entries pass.
- [ ] Render all `watchman*` shots; compare each with `docs/design/mockups/watchman-tuning/`; list differences in the hand-back.
- [ ] Commit `docs(watchman): tuning — feature note, guide, contracts (#2147)`.

## Gate (controller, once before the umbrella PR)

`make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`, `scripts/leak-check.sh`, every other `.github/workflows/*.yml` job by its own command; a job that cannot run locally is named.
