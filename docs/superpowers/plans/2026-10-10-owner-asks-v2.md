# Owner asks v2 — plan

**Spec:** `docs/superpowers/specs/2026-10-10-owner-asks-v2-design.md` (Part numbers below refer to it) · **Business:** `docs/superpowers/specs/2026-10-10-owner-asks-v2-business.md`
**Branch:** `feature/314-owner-asks-v2` · **Board:** #395, #501, #503, #412

Lean plan: files, interfaces produced/consumed, dependencies, test cases. No code. Each implementer runs the inner loop for what it touched (CLAUDE.md "Agent-driven runs"); the controller runs the phase gates. Every task brief carries the relevant `docs/review/review-rules.md` sections and, for any task touching PROJ-04/11/12/13, the inventory entry verbatim; a guard test is rewritten only to the wording in spec Part 11, never relaxed.

Lanes: **Go** tasks can run in parallel where dependencies allow (one table = one lane: G3/G8/G9 all touch `terminal_sessions` writes — serial). **Swift** runs one lane at a time. Swift-UI tasks touching the stack, banner or drawer (U3, U4, U5) start only after the already-running Swift lane (#500 ask number, #502 checklist) is merged into this branch.

## Phase 0 — controller

**T0. Merge `origin/main` into the branch.** Brings PR #185 (migration 00106, `SubagentStop`, Agents working, `workbench session-probe`, `SessionBackgroundProber`). Check `internal/db/migrations` for the highest number; take the next for G1 (00107 unless taken). Merge the #478 ask guard v3 lane before G5 starts. `bash scripts/dev-health.sh` before dispatching.

## Phase 1 — Go

### G1. Migration 00107 (Go)
- **Files:** `internal/db/migrations/00107_owner_asks_v2.sql`, `internal/db/schema.sql`, `internal/db/db_test.go` (`TestAllTablesExist` + `owner_presence`), schema golden, `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (regenerated with `-update`). Follow the `add-migration` skill.
- **Produces:** table `owner_presence` (Part 2.2); `terminal_sessions.chat_question`, `chat_question_at` (Part 4.6); `owner_asks.level`, `origin`, `chat_asked_at` (Part 3.4).
- **Depends on:** T0.
- **Tests:** Up then Down then Up on a DB holding open and answered asks and a terminal session: old asks read `full`/`agent`/`''`; `owner_presence` rejects `id = 2`; `level = 'x'` and `origin = 'x'` rejected by CHECK; deleting a session sets `owner_presence.session_id` NULL.

### G2. Level classification and the zero-option rule (Go)
- **Files:** `internal/asks/level.go` (+ `level_test.go`), `internal/asks/asks.go` (`Validate` gains the origin), `internal/asks/answer.go` (`ValidateAnswer`).
- **Produces:** `asks.Level(kind string, p Payload, origin string) string`; `asks.LevelNote(kind, p, origin) string` (first failed rule, '' when quick); constants `LevelQuick`, `LevelFull`, `OriginAgent`, `OriginChat`, `MaxQuickOptions = 3`, `MaxQuickLabelRunes = 40`, `MaxQuickDescriptionRunes = 100`; `Validate` accepting 0 options only for `OriginChat`.
- **Depends on:** none.
- **Tests:** `TestLevelTable` (every row of spec 3.2); `TestLevelNoteNamesTheFirstFailedRule`; `TestValidateZeroOptionsOnlyFromChat`; `TestValidateAnswerZeroOptionsNeedsOther` (labels empty + other non-empty passes; empty other or any label refused).

### G3. DB layer (Go)
- **Files:** `internal/db/owner_presence.go` (+ test), `internal/db/terminal_sessions.go` (+ test), `internal/db/owner_asks.go` (+ test).
- **Produces:** `OwnerPresentIn(sessionID int64, now time.Time) (bool, error)` (90 s, 5 s future tolerance); `SetChatQuestion(sessionID int64, claudeSessionID string, q ChatQuestion, at time.Time) error`; `ClearChatQuestionBefore(sessionID int64, claudeSessionID string, eventAt time.Time) error` (clears only when `chat_question_at` < eventAt); `TakeChatQuestion(tx, sessionID int64, at string) (*ChatQuestion, error)` (compare-and-take); the run mark, run clear and `SetTerminalClaudeSessionID` also clear the two columns; `InsertOwnerAsk` stores `level`/`origin`/`chat_asked_at` and refuses `origin chat` without `chat_asked_at` (and the reverse); `OwnerAsk` gains the three fields; `LastWithdrawnByTitle(projectID int64, normTitle string, since time.Time) (*OwnerAsk, error)`; `RecentOpenQuestionAsk(sessionID int64, since time.Time)`.
- **Consumes:** G1, G2 types.
- **Depends on:** G1, G2.
- **Tests:** `TestOwnerPresentInStaleHeartbeatIsAbsent` (89 s present, 91 s absent, another session absent, future 6 s absent, no row absent); `TestChatQuestionSetReplaceClear`; `TestClearChatQuestionBeforeKeepsANewerQuestion`; `TestTakeChatQuestionIsCompareAndTake` (matching `at` → taken once; mismatched → nil, nothing written); `TestProj11_ChatQuestionWritesNeverTouchTheState` (every write above leaves `agent_state`, `agent_state_at`, `finished_at`, `agent_turn_end`, `agent_tool_run`, `agent_background*` byte-identical); `TestChatQuestionClearedByANewRun` (mark, clear, conversation switch); `TestInsertOwnerAskOriginInvariant`; `TestProj02_DeleteProjectLeavesNoRows` extended (presence row on a deleted workbench's session → `session_id` NULL).

### G4. `ask_owner`, `get_ask`, `list_asks` (Go)
- **Files:** `internal/tools/workbench_asks.go` (+ test), `internal/tools/registry_workbench_test.go` if the schema snapshot lists tool args.
- **Produces:** `level` arg; result `level`, `level_note`, `hint`; the withdrawn-title and withdrawn-revision refusals (Part 8); `get_ask`/`list_asks` fields `level`, `origin`, `chat_asked_at`.
- **Consumes:** G2 `Level`/`LevelNote`, G3 reads.
- **Depends on:** G3.
- **Tests:** `TestAskOwnerStoresTheComputedLevel` (2 options → quick; review → full); `TestAskOwnerLevelHintDowngradesWithANote` (E23); `TestAskOwnerFullOverrideWins`; `TestAskOwnerRefusesARefiledWithdrawnTitle` (E24, normalisation: case, spaces, trailing "?"); 8-day-old withdrawal allowed (E25); a `superseded` withdrawal never triggers it; `TestAskOwnerRevisionOfAWithdrawnAskNeedsChanges` (E26); `TestAskOwnerSeriesHint` (E27; 11 min → no hint; another session's ask → no hint); `TestGetAsk_ReturnsLevelAndOrigin`.

### G5. Stop ask guard command + prompt v4 (Go)
- **Files:** `cmd/workbench_askguard.go` (+ test), `cmd/workbench_askguard_stop.go` (new), `internal/devpack/askguard_prompt.md` (v4), `internal/devpack/testdata/askguard_prompt_v3.md` (fixture of the shipped v3), golden. Follow the `add-ai-prompt` skill (light tier; claude and codex).
- **Produces:** `workbench ask-guard --workbench N --stop`; the model-output decoder (Part 4.3); the decision function `decideStop(input, verdict, presence) stopDecision` (pure, Part 4.5); fixed reasons `askGuardReasonFull`, `askGuardReasonAway`, `askGuardReasonFinish`; a model seam (interface) so tests inject a stub classifier — no real model call in tests.
- **Consumes:** G3 `OwnerPresentIn`, `SetChatQuestion`; `db.OpenExisting`.
- **Depends on:** G3; #478 merged into the branch.
- **Tests:** `TestProj13_StopGuardDecisionTable` (E1–E9, each row of 4.5); `TestProj13_ChatPassesOnlyWhenPresentAndRecorded` (E2–E4, no env, nested session, read error → away; write error → away); `TestProj13_AskGuardFailurePrintsNothingAndExitsZero` extended to `--stop` (empty, unreadable, never-closed stdin; stub timeout; stub error; prose output; panic); `TestProj13_AskGuardFinishesFastOnALockedDatabase` (`--stop`, stub classifier, locked DB → exits within 2 s plus the stub's time, decision away); `TestProj13_AskGuardWithNoDatabaseCreatesNothing` and `TestProj13_AskGuardNeverRunsAMigration` for `--stop`; `TestProj13_StopGuardNeverTouchesTheStateColumns`; `TestProj13_StopGuardSkipsTheModelOnAContinuedTurn` (stub never called with `stop_hook_active`); `TestProj13_AskGuardPromptPassesAContinuedTurnAndAFiledAsk` on the v4 golden; `TestAskGuardModelOutputClipping` (300/40 runes, >4 options, unknown request → none). Any test spawning a stub process reaps its process group in `t.Cleanup`.

### G6. Install, status, remove (Go)
- **Files:** `internal/devpack/workbench_settings.go`, `internal/devpack/workbench_ask_guard_test.go`, `cmd/integrate_workbench.go` (+ test).
- **Produces:** the command entry replacing marker prompts (Part 4.7); status keys `ask_guard` (command entry) and `ask_guard_legacy`.
- **Depends on:** G5.
- **Tests:** `TestProj13_PromptEntryIsReplacedByTheCommandHook` (v1/v2/v3/edited → one command entry; another workbench's prompt kept; idempotent; owner hooks and keys byte-exact); `TestProj04_AskGuardReplacesOurEditedPromptAndKeepsOwnerHooks` rewritten to the command entry with the same owner-key assertions; `TestProj04_MalformedPreToolUseLeavesTheFileByteIdentical` unchanged and a `Stop` twin; `TestProj04_RemoveDeletesOnlyOurHook` covers the command entry and a leftover marker prompt; `TestIntegrateWorkbenchStatusJSON_AskGuardKeys` (prompt only → `ask_guard: false, ask_guard_legacy: true`).

### G7. `AskUserQuestion` reasons by presence (Go)
- **Files:** `cmd/workbench_askguard.go` (+ test).
- **Produces:** `askToolDenialReasonPresent`, `askToolDenialReasonAway` (Part 6).
- **Consumes:** G3 `OwnerPresentIn`.
- **Depends on:** G3. Same file as G5 → run after G5 (or in the same lane).
- **Tests:** `TestAskGuard_DeniesAskUserQuestionInALiveWorkbench` (present → present reason; stale, absent, read error → away reason); the PROJ-13 failure, locked-DB, no-DB and no-migration guards still pass for `--pre-tool-use` unchanged.

### G8. State hooks clear the chat question (Go)
- **Files:** `cmd/workbench_session_state.go` (+ test), `cmd/workbench_brief_session.go` (run mark, already clears through G3 — test only).
- **Produces:** `UserPromptSubmit` → `ClearChatQuestionBefore(event time)`; a main-thread `PostToolUse` that writes `working` out of `waiting` → the same clear.
- **Consumes:** G3.
- **Depends on:** G3 (serial with G9: same table).
- **Tests:** `TestChatQuestionClearedByTheOwnersPrompt` (E11); `TestChatQuestionKeptByAnOlderPrompt` (event earlier than `chat_question_at` → kept); `TestChatQuestionClearedByASelfStartedTurn`; a subagent `PostToolUse`, a `SubagentStop`, a notification and a StopFailure keep it; `TestProj11_HookNeverWritesStdoutAndExitsZero` and every existing PROJ-11 hook guard unchanged and green.

### G9. `workbench escalate-question` (Go)
- **Files:** `cmd/workbench_escalate.go` (+ `cmd/workbench_escalate_test.go`).
- **Produces:** the CLI and its JSON envelope (Part 5.3): `{"ok", "outcome": "filed"|"gone", "ask_id", "level", "error"}`; flags `--workbench` (legacy `--project` alias as the other workbench verbs), `--session`, `--at`, `--reason timeout|left`.
- **Consumes:** G2 `Level`, G3 `TakeChatQuestion`, `InsertOwnerAsk`.
- **Depends on:** G3, G8 (serial on the table).
- **Tests:** `TestEscalateFilesAQuickAskWithTheSameOptions` (E12: kind, title clip, summary lines for both reasons, options and recommended flags, `origin chat`, `chat_asked_at`, session, single linked target / none for 0 or 2 links); `TestProj13_EscalationIsCompareAndTake` (E16, E17); `TestEscalateFourOptionsIsFull` (E19); `TestEscalateZeroOptionsIsQuick` (E18); `TestEscalateAtTheOpenCapKeepsTheQuestion` (E20); `TestEscalateEnvelopeShape` (missing row, another workbench, bad flags → `ok: false`, exit 0).

### G10. Asks for other clients: list and answer (Go)
- **Files:** `cmd/workbench_asks_cli.go` (+ `cmd/workbench_ask_answer_test.go`).
- **Produces:** `workbench asks --open --json [--workbench N]` and `workbench ask answer --id N --json <answer>` (Part 10.1, 10.3).
- **Consumes:** G2 `ValidateAnswer`, G3 reads, the guarded answer update (a Go twin of `OwnerAskQueries.answer`, same SQL guard).
- **Depends on:** G3.
- **Tests:** `TestAsksOpenJSONShape` (every field of 10.1; only open asks; another workbench filtered with `--workbench`); `TestAskAnswerWritesTheGuardedUpdate` (answered, `answered_at` set, `delivered` untouched); `TestAskAnswerRefusals` (E32: full, not open, label not offered, malformed JSON — nothing written); a race test: the ask withdrawn between read and write → `not_open`.

### G11. Skill pack v5 and the brief rule (Go)
- **Files:** `internal/devpack/workbenchskill/watchtower-workbench/SKILL.md` (`x-watchtower-pack: v5`, or the next free), `internal/devpack/testdata/watchtower-workbench-v4.md` (the shipped v4), `internal/devpack/workbench_test.go`, `cmd/workbench_brief.go` (`briefRules[0]`), `cmd/workbench_brief_test.go`.
- **Produces:** "Asking the owner" with parts 1–6 of spec Part 7; the `ask_owner` line with `level`; the new brief rule line.
- **Consumes:** G4 (arg names), G5 (guard behaviour it describes).
- **Depends on:** G4, G5.
- **Tests:** the DEV-04 re-install test with the v4 fixture (unedited v4 → v5; edited v4 kept); `workbench_test.go` heading list still finds "## Asking the owner"; a content test asserting the skill names the three levels, the "do not ask" list, "up to 4 questions", `previous_ask_id` with `changes` for a withdrawn ask and `origin: chat`; `TestProj12_AnsweredAskSurvivesAFullBoard` green at the 4000-rune cap with the new rule.

### G12. Docs and inventory (Go lane, docs only)
- **Files:** `docs/inventory/workbench.md` (PROJ-13 rewritten, PROJ-12/11/04/02 amended — exact wording in spec Part 11), `docs/inventory/dev-surface.md` (DEV-04 fixture note), `docs/features/workbench.md` (levels, presence, guard v4, escalation, Quick ask, "Asks for other clients" contract from Part 10), `docs/handoff/2026-10-10-mobile-owner-asks.md` (handoff note for the mobile project: Part 10 contract, CLI examples with placeholder ids, what is out of scope, the owner decisions D3/D6 taken), CLAUDE.md feature-notes line for workbench updated.
- **Depends on:** G4–G11 for the Go parts; the PROJ-12 amendment's test names are confirmed after U3/U4 (the controller re-checks before the PR).
- **Tests:** none (docs); the leak check must pass (no real ids, names, paths).

**Phase 1 gate (controller):** `make test`, `go test ./cmd/...`, `make lint-all`.

## Phase 2 — Swift-Core (one Swift lane)

### C1. `OwnerAsk` level and origin (Swift-Core)
- **Files:** `WatchtowerCore/Models/OwnerAsk.swift`, `WatchtowerCore/Database/Queries/OwnerAskQueries.swift`, `WatchtowerCore/Services/OwnerAskPresentation.swift`, `Tests/Core/OwnerAskTests.swift`, `Tests/Core/OwnerAskPresentationTests.swift`.
- **Produces:** `OwnerAsk.level: Level (.quick/.full)`, `origin: Origin (.agent/.chat)`, `chatAskedAt: Date?` (an unknown level or origin makes the row unreadable, as an unknown kind does today); `OwnerAskPresentation.chatMark(askedAt:now:) -> String` ("From chat · <1 min" / "· N min"); `OwnerAskAnswer.quick(label:)`, `.reply(_:)` builders for question `q1`.
- **Consumes:** G1 schema (via `TestDatabase+Schema.swift`).
- **Depends on:** G1.
- **Tests:** decode quick/full/chat rows; unknown level → named in the stack's error line; `chatMark` at 0 s, 59 s, 60 s, 12 min, future date; `quick(label:)` and `reply(_:)` JSON byte-equal to what Go's `ValidateAnswer` accepts (fixture shared with G2's test data).

### C2. Presence policy and queries (Swift-Core)
- **Files:** `WatchtowerCore/Services/OwnerPresencePolicy.swift`, `WatchtowerCore/Database/Queries/OwnerPresenceQueries.swift`, `Tests/Core/OwnerPresencePolicyTests.swift`, `Tests/Core/OwnerPresenceQueriesTests.swift`.
- **Produces:** `OwnerPresencePolicy.presentSession(appActive:keyWindowShows:selectedSession:screenLocked:displaysAsleep:) -> Int64?`; `OwnerPresenceQueries.enter(sessionID:at:)`, `.heartbeat(sessionID:at:)`, `.leave(at:)`.
- **Depends on:** G1.
- **Tests:** `testAppInactiveIsAbsent`, `testLockedScreenIsAbsent`, `testDisplaysAsleepIsAbsent`, `testAnotherSessionOnScreenIsThatSession`, `testDrawerOpenIsStillPresent`; queries: enter overwrites the singleton, heartbeat on another session writes nothing, leave clears.

### C3. Escalation policy (Swift-Core)
- **Files:** `WatchtowerCore/Services/ChatQuestionEscalationPolicy.swift`, the terminal session row model (`chatQuestionAt`), `Tests/Core/ChatQuestionEscalationPolicyTests.swift`.
- **Produces:** `ChatQuestionEscalationPolicy.decide(row:presentSession:hasOwnerDraft:now:) -> Decision (.none / .escalate(.timeout | .left))`, constant `timeout = 600 s`.
- **Depends on:** G1.
- **Tests:** a table over spec Part 5.2: `testLeavingEscalatesAtOnce`, `testTenMinutesPresentEscalates` (599 s none, 600 s escalate), `testADraftDefersTheTimeoutNotTheLeave`, `testClearedQuestionNeverEscalates`, `testNotLiveNeverEscalates`, `testEarlierRunNeverEscalates`, `testFutureOrUnparsableStampIsNone`.

## Phase 3 — Swift services and UI (one Swift lane; U3–U5 after the #500/#502 lane is merged)

### U1. `OwnerPresenceCenter` (Swift-UI/Services)
- **Files:** `Sources/Services/OwnerPresenceCenter.swift`, wiring in `AppState` and the workbench page/session view (reports the selected session pane), `Tests/OwnerPresenceCenterTests.swift`.
- **Produces:** `OwnerPresenceCenter.presentSessionID` (observable), `onChange`; writes per Part 2.3 with an injected clock and writer.
- **Consumes:** C2.
- **Depends on:** C2. Does not touch the stack, banner or drawer → may run before the #500/#502 lane lands, but not concurrently with another Swift lane.
- **Tests:** `testAFlickerUnderTwoSecondsIsNotLeaving` (E14), `testEnteringWritesAtOnce`, `testHeartbeatEveryThirtySeconds`, `testQuitClearsPresence` (E35), `testScreenLockClears`, `testAFailedWriteIsRetriedAtTheNextHeartbeat`.

### U2. `ChatQuestionEscalator` (Swift-UI/Services)
- **Files:** `Sources/Services/ChatQuestionEscalator.swift`, `Sources/Services/WorkbenchCLI.swift` (the `escalate-question` call and its result type in Core `Models/ChatQuestionEscalationResult.swift`), `Tests/ChatQuestionEscalatorTests.swift`, `Tests/Core/ChatQuestionEscalationResultTests.swift`.
- **Produces:** the runner of Part 5.2 (modelled on `SessionBackgroundProber`).
- **Consumes:** C3, U1, `SessionAgentStateCenter` reads, `TerminalCenter.promptDrafts`, G9's envelope.
- **Depends on:** C3, U1, G9.
- **Tests:** `testOneRunInFlightPerSession`, `testAFailedRunIsRetriedAtMostOncePerMinute` (E20), `testGoneOutcomeStopsRetrying`, `testFiledOutcomeAsksTheAsksPollForARead`, `testStopCancelsAndReapsTheRun`, `testPresenceChangeTriggersAnEvaluation`; decode tests for every outcome and the failure envelope.

### U3. Quick ask in the banner and the stack (Swift-UI) — after #500/#502
- **Files:** `Views/Workbench/Asks/OwnerAskBanner.swift`, `Views/Workbench/Asks/OwnerAskQuickActions.swift` (new, shared), `Views/Workbench/Asks/OwnerAskStackSection.swift`, `ViewModels/OwnerAsksViewModel.swift` (`answer(_:with:)` — the drawer's `answer` refactored onto it, behaviour unchanged), `docs/app-guide.md`, `Tests/OwnerAsksViewModelTests.swift`, `Tests/Core/OwnerAskQuickActionsTests.swift` (presentation model of the row: order, prominence, tooltip, Reply-only).
- **Produces:** Part 9.1–9.3.
- **Consumes:** C1.
- **Depends on:** C1; the #500/#502 Swift lane merged.
- **Tests:** `testProj12_AQuickAnswerFromTheBannerIsStoredThenDeliveredLikeTheDrawers` (E28: identical bytes, pause and Return rules as the drawer path; held at a permission prompt; only pasted over a draft); `testProj12_AReplyIsSentAsOtherOnOneLine` (newlines and control characters become spaces, trimmed, 500-rune clip, empty does nothing); `testAQuickTapOnAWithdrawnAskTypesNothing` (E29); `testRecommendedFirstAndProminent`; `testZeroOptionsShowsOnlyReply` (E18); `testAFullAskKeepsTheOpenButton`; `testButtonsDisabledWhileAnswering`; every existing `testProj12_…` in `OwnerAsksViewModelTests` green unchanged.

### U4. Deliver answers written outside the app (Swift-UI/VM) — after #500/#502
- **Files:** `ViewModels/OwnerAsksViewModel.swift`, `Tests/OwnerAsksViewModelTests.swift`.
- **Produces:** delivery of an ask seen going open → answered without a local answer call (Part 10.4), through the same `deliver` path.
- **Consumes:** C1; G10 only for the manual check (tests write the DB directly).
- **Depends on:** C1, U3 (same file).
- **Tests:** `testProj12_AnAnswerWrittenOutsideTheAppIsDeliveredOnce` (E31; second poll → none; the app's own answer is never delivered twice; a stopped session → nothing typed, the brief lists it; an ask answered before the app started is not typed — the brief lists it).

### U5. Keyboard navigation of the stack and drawer, #412 (Swift-UI) — last Swift task
- **Files:** `Views/Workbench/Asks/OwnerAskKeyCatcher.swift`, `OwnerAskDrawer.swift`, `OwnerAskDrawerHeader.swift`, `OwnerAskStackSection.swift`, `OwnerAskQuickActions.swift`, `OwnerAskChecklistBody.swift`, `OwnerAskMarginComments.swift`, `docs/app-guide.md`; pure key mapping in Core `WatchtowerCore/Services/OwnerAskKeyMap.swift` with `Tests/Core/OwnerAskKeyMapTests.swift`.
- **Produces:** a key to open the stack; next/previous ask ("k of N"); Tab/Shift-Tab through fields and checklist steps; digits 1–9 choose an option in the focused question (1–3 on a Quick ask card or banner); next/previous review comment; ⌘↩ / ⌘⇧↩ unchanged; every key shown in the controls' hints and in `docs/app-guide.md`. Exact key choices are set in the task's brief from the existing app shortcuts (no conflict with the terminal, Files or Navigate menu keys) and shown to the owner in the manual check — no separate ask (a UI default, per the skill's own "do not ask" rule).
- **Consumes:** U3.
- **Depends on:** U3, U4.
- **Tests:** `OwnerAskKeyMapTests` (each key → action; digits beyond the option count → nothing; any key while the terminal or an editor is focused → nothing, the terminal keeps its keys); `testDigitPicksAQuickOptionOnlyWithTheBannerFocused`; `testCommandReturnStillAnswers` (the existing ⌘↩ tests unchanged).

**Phase 2–3 gate (controller):** `make test-swift`, `make lint-all`; then the full gate (`make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`) before the PR, with the G12 docs re-checked against the final test names.

## Manual check (owner, filed as one `kind: check` ask after the PR is green)

1. Repair an existing workbench; `integrate status` shows the new guard.
2. Terminal on screen, window focused: ask the agent something it should ask back briefly → the question stays in the terminal.
3. Same, with Watchtower in the background → the agent files an ask.
4. Chat question, then switch to another app → a Quick ask "From chat" appears at once.
5. Chat question, stay and wait 10 minutes → a Quick ask "From chat · 10 min".
6. Tap an option in the banner → the agent gets the answer and continues by itself.
7. "Reply…" with a free answer → delivered as text.
8. A review ask still opens the drawer.
9. Keyboard: open the stack, switch asks, pick an option with a digit.

## Dependency summary

| Task | Kind | Depends on |
|---|---|---|
| T0 | controller | none |
| G1 | Go | T0 |
| G2 | Go | none |
| G3 | Go | G1, G2 |
| G4 | Go | G3 |
| G5 | Go | G3, #478 merged |
| G6 | Go | G5 |
| G7 | Go | G3, G5 (same file) |
| G8 | Go | G3 |
| G9 | Go | G3, G8 |
| G10 | Go | G3 |
| G11 | Go | G4, G5 |
| G12 | Docs | G4–G11 (PROJ-12 names re-checked after U3/U4) |
| C1 | Swift-Core | G1 |
| C2 | Swift-Core | G1 |
| C3 | Swift-Core | G1 |
| U1 | Swift-UI/Services | C2 |
| U2 | Swift-UI/Services | C3, U1, G9 |
| U3 | Swift-UI | C1, #500/#502 lane merged |
| U4 | Swift-UI/VM | C1, U3 |
| U5 | Swift-UI (#412) | U3, U4 |
