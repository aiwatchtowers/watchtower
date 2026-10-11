# Owner asks v2 — plan

**Spec:** `docs/superpowers/specs/2026-10-10-owner-asks-v2-design.md` (Part numbers below refer to it) · **Business:** `docs/superpowers/specs/2026-10-10-owner-asks-v2-business.md`
**Branch:** `feature/314-owner-asks-v2` · **Board:** #395, #501, #503, #412
**Revised** 2026-10-10 after the spec review (F1–F23).

Lean plan: files, interfaces produced/consumed, dependencies, test cases. No code. Each implementer runs the inner loop for what it touched (CLAUDE.md "Agent-driven runs"); the controller runs the phase gates. Every task brief carries the relevant `docs/review/review-rules.md` sections and, for any task touching PROJ-02/04/11/12/13, the inventory entry verbatim; a guard test is rewritten only to the wording in spec Part 11, never relaxed.

Lanes: **Go** tasks can run in parallel where dependencies allow (one table = one lane: G3/G5/G8/G9 all write `terminal_sessions` — serial). **Swift** runs one lane at a time. Swift tasks touching the `OwnerAsk*` Core files, the stack, banner or drawer (C1, U3, U5) start only after the already-running Swift lane (#500 ask number, #502 checklist) is merged into this branch.

## Phase 0 — controller

**T0. Keep the branch on `origin/main`.** `origin/main` (with #411: migration 00106, `SubagentStop`, Agents working, `workbench session-probe`, `SessionBackgroundProber`) is merged into the branch (`cf931eb0`), and the ask guard v3 lane #478 too (`a65390dd`). Merge `origin/main` again before dispatching and check `internal/db/migrations` on `origin/main` for the highest number — G1 takes the next (00107 unless another lane landed one). `bash scripts/dev-health.sh` before dispatching.

## Phase 1 — Go

### G1. Migration 00107 (Go)
- **Files:** `internal/db/migrations/00107_owner_asks_v2.sql`, `internal/db/schema.sql`, `internal/db/db_test.go` (`TestAllTablesExist` + `owner_presence`), schema golden, `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (regenerated with `-update`). Follow the `add-migration` skill.
- **Produces:** table `owner_presence(id, session_id, seen_at)` (Part 2.2); `terminal_sessions.chat_question`, `chat_question_at` (Part 4.7); `owner_asks.level`, `origin`, `chat_asked_at` (Part 3.4).
- **Depends on:** T0.
- **Tests:** Up then Down then Up on a DB holding open and answered asks and a terminal session: old asks read `full`/`agent`/`''`; `owner_presence` rejects `id = 2`; `level = 'x'` and `origin = 'x'` rejected by CHECK; deleting a session sets `owner_presence.session_id` NULL.

### G2. Level classification and the zero-option rule (Go)
- **Files:** `internal/asks/level.go` (+ `level_test.go`), `internal/asks/asks.go` (`Validate` gains the origin), `internal/asks/answer_test.go` (test only — `ValidateAnswer` already accepts an `other`-only answer), `internal/asks/testdata/cards/owner_ask_zero_options.json` (new Go↔Swift fixture).
- **Produces:** `asks.Level(kind string, p Payload, origin string) string`; `asks.LevelNote(kind, p, origin) string` (first failed rule, '' when quick); constants `LevelQuick`, `LevelFull`, `OriginAgent`, `OriginChat`, `MaxQuickOptions = 3`, `MaxQuickLabelRunes = 40`, `MaxQuickDescriptionRunes = 100`; `Validate` accepting 0 options only for `OriginChat`.
- **Depends on:** none.
- **Tests:** `TestLevelTable` (every row of spec 3.2); `TestLevelNoteNamesTheFirstFailedRule`; `TestValidateZeroOptionsOnlyFromChat` (over the fixture: origin chat accepts, origin agent refuses; 1 option refused for both); `TestValidateAnswerZeroOptionsNeedsOther` (labels empty + other non-empty passes; empty other or any label refused).

### G3. DB layer (Go)
- **Files:** `internal/db/db.go` (`OpenExistingRW`), `internal/db/owner_presence.go` (+ test), `internal/db/terminal_sessions.go` (+ test), `internal/db/owner_asks.go` (+ test), `internal/db/testdata/stamps` (shared stamp fixture).
- **Produces:**
  - `OpenExistingRW(path string, busy time.Duration) (*DB, error)` — `mode=rw`, never creates, never migrates, no `query_only`; `HasColumns(table string, cols ...string) (bool, error)` by schema lookup (F1).
  - `OwnerPresentIn(sessionID int64, now time.Time) (bool, error)` (90 s, 5 s future tolerance).
  - `SetChatQuestion(sessionID int64, claudeSessionID string, q ChatQuestion, at time.Time) error`; `ClearChatQuestionBefore(sessionID int64, claudeSessionID string, eventAt time.Time) error` (clears only when `chat_question_at` < eventAt); `TakeChatQuestion(tx, sessionID int64, at string) (*ChatQuestion, error)` — compare-and-take with the F9 conditions (`agent_state = 'waiting'`, `agent_state_at ≤ chat_question_at + 30 s`).
  - `MarkTerminalAgentRun`, `ClearTerminalAgentState`, `SetTerminalClaudeSessionID` add `chat_question = NULL, chat_question_at = NULL` to their `SET`; only `ClearTerminalAgentState`'s "has something to clear" guard gains `OR chat_question IS NOT NULL` — the other two keep their guards unchanged (N3).
  - `InsertOwnerAsk` stores `level`/`origin`/`chat_asked_at` and refuses `origin chat` without `chat_asked_at` (and the reverse); `OwnerAsk` gains the three fields; `LastWithdrawnByTitle(projectID int64, normTitle string, since time.Time) (*OwnerAsk, error)`; `RecentOpenQuestionAsk(sessionID int64, since time.Time)`.
- **Consumes:** G1, G2 types.
- **Depends on:** G1, G2.
- **Tests:** `TestOpenExistingRWNeverCreatesNeverMigrates` (missing file → error, no file created; an old schema → opens, `HasColumns` false, no migration run; a write succeeds); `TestOwnerPresentInStaleWriteIsAbsent` (89 s present, 91 s absent, another session absent, future 6 s absent, no row absent); `TestChatQuestionSetReplaceClear`; `TestClearChatQuestionBeforeKeepsANewerQuestion`; `TestTakeChatQuestionIsCompareAndTake` (matching `at` and waiting → taken once; mismatched `at`, state `working`/`approval`, `agent_state_at` 31 s after → nil, nothing written; 29 s after → taken); `TestProj11_ChatQuestionWritesNeverTouchTheState` (every write above leaves `agent_state`, `agent_state_at`, `finished_at`, `agent_turn_end`, `agent_tool_run`, `agent_background*` byte-identical); `TestProj11_NewRunAndConversationSwitchClearTheCount` extended (the question cleared by mark, clear and switch; `ClearTerminalAgentState` clears a row holding only a question); `TestOlderRunMarkOverANewerStateKeepsTheQuestion` (a mark stamped before the stored `agent_state_at` changes nothing, the question included); `TestInsertOwnerAskOriginInvariant`; `TestStampFixtureRoundTrips`; `TestProj02_DeleteProjectLeavesNoRows` extended (presence row on a deleted workbench's session → `session_id` NULL).

### G4. `ask_owner`, `get_ask`, `list_asks` (Go)
- **Files:** `internal/tools/workbench_asks.go` (+ test), `internal/tools/registry_workbench_test.go` if the schema snapshot lists tool args.
- **Produces:** `level` arg; result `level`, `level_note`, `hint`; the withdrawn-title and withdrawn-revision refusals (Part 8); `get_ask`/`list_asks` fields `level`, `origin`, `chat_asked_at`.
- **Consumes:** G2 `Level`/`LevelNote`, G3 reads.
- **Depends on:** G3.
- **Tests:** `TestAskOwnerStoresTheComputedLevel` (2 options → quick; review → full); `TestAskOwnerLevelHintDowngradesWithANote` (E23); `TestAskOwnerFullOverrideWins`; `TestAskOwnerRefusesARefiledWithdrawnTitle` (E24, normalisation: case, spaces, trailing "?"); 8-day-old withdrawal allowed (E25); a `superseded` withdrawal never triggers it; `TestAskOwnerRevisionOfAWithdrawnAskNeedsChanges` (E26); `TestAskOwnerSeriesHint` (E27; 11 min → no hint; another session's ask → no hint); `TestGetAsk_ReturnsLevelAndOrigin`.

### G5. Stop ask guard command + classifier v4 (Go)
- **Files:** `cmd/workbench_askguard.go` (+ test), `cmd/workbench_askguard_stop.go` (new), `internal/devpack/askguard_classifier.md` (new, embedded) and `internal/devpack/testdata/askguard_classifier_v4.golden`, `internal/devpack/askguard_prompt.md` (unchanged — the v3 marker prompt, now a fixture for the upgrade), `internal/digest/models.go` (source tag `workbench.ask_guard` → `TierLight`; the same table routes the codex backend through `internal/codex/generator.go`), `docs/features/workbench.md` note on the prompt-store exception. Follow the `add-ai-prompt` skill (light tier; claude and codex) except its prompt-store step, which PROJ-13 overrides (Part 4.4).
- **Produces:** `workbench ask-guard --workbench N --stop`; the model-output decoder and normaliser (Part 4.3, F3); the pure decision function `decideStop(input, verdict, resolution) stopDecision` (Part 4.5, two phases); the resolution of session, core state hooks and presence with the failure split (Part 4.6); the clear-on-every-other-outcome rule (4.2 step 6); fixed reasons `askGuardReasonFull`, `askGuardReasonAway`, `askGuardReasonFinish`, `askGuardReasonFinishAsk`; the classifier field `request_outside_ask` (N2); `signal.NotifyContext` and a process-group model child killed and waited on cancel; a classifier seam (interface) so tests inject a stub — no real model call in tests.
- **Consumes:** G3 `OpenExistingRW`, `HasColumns`, `OwnerPresentIn`, `SetChatQuestion`, `ClearChatQuestionBefore`; the core-state-hooks check the Stop hook already uses (`cmd/workbench_check.go`).
- **Depends on:** G3; #478 (merged).
- **Tests:** `TestProj13_StopGuardDecisionTable` (E1–E9c, every row of 4.5: E7 present/absent, E7a covered, E7b named ask plus a review request → `R-full`, E8a chat candidate plus complete → `R-finish-ask` with nothing recorded, a record failure on row 9 → `R-away`); `TestProj13_ChatPassesOnlyWhenPresentAndRecorded` (E2–E4, E10d, no env, nested session, read error, write error, missing columns → away); `TestProj13_ContinuedTurnNeverBlocks` (E10b; every verdict with `stop_hook_active` prints nothing; a chat request is recorded present or away); `TestStopWithoutAQuestionClearsTheOlderOne` (E10c: a Stop on which the drift check blocks, built from the captured fixtures of `TestStopHookInputParsesTheCapturedFixtures`, records a question; the next Stop with no question clears it; a blocked Stop clears too); `TestAskGuardModelOutputNormalisation` (E10e: 300/40 runes, trim, duplicates case-folded with `recommended` OR-ed, >4 dropped, 1 → 0, unknown request → none, chat with empty question → full); `TestProj13_AskGuardFailurePrintsNothingAndExitsZero` extended to `--stop` (empty, unreadable, never-closed stdin; stub timeout; stub error; prose output; panic); `TestProj13_AskGuardFinishesFastOnALockedDatabase` (`--stop`, stub classifier, locked DB → within the stub's time plus 2 s, decision away); `TestProj13_AskGuardWithNoDatabaseCreatesNothing` and `TestProj13_AskGuardNeverRunsAMigration` for `--stop`; `TestProj13_StopGuardNeverTouchesTheStateColumns`; `TestProj13_ACancelledModelCallLeavesNoProcess` (E10a: SIGTERM mid-call; the stub's process group is gone before exit; the test reaps it in `t.Cleanup` on every path); `TestProj13_AskGuardPromptPassesAContinuedTurnAndAFiledAsk` on the v4 classifier golden; `TestTierForSourceAskGuardIsLight`.

### G6. Install, status, remove (Go)
- **Files:** `internal/devpack/workbench_settings.go`, `internal/devpack/workbench_ask_guard_test.go`, `cmd/integrate_workbench.go` (+ test).
- **Produces:** the command entry replacing marker prompts (Part 4.8); `ask_guard` true only for the command entry (no new status key).
- **Depends on:** G5.
- **Tests:** `TestProj13_OlderPromptsAreUpgradedToTheCurrent` rewritten (#478's guard, same strictness: v1/v2/v3/edited → one command entry; another workbench's prompt kept; idempotent; owner hooks and keys byte-exact); `TestProj04_AskGuardReplacesOurEditedPromptAndKeepsOwnerHooks` rewritten to the command entry with the same owner-key assertions; `TestProj04_MalformedPreToolUseLeavesTheFileByteIdentical` unchanged and a `Stop` twin; `TestProj04_RemoveDeletesOnlyOurHook` covers the command entry and a leftover marker prompt; `TestStatusWorkbench_AskGuardFlagsEachMissingHook` and `TestIntegrateWorkbenchStatusJSON_AskGuardKeys` (prompt only → `ask_guard: false`).

### G7. `AskUserQuestion` reasons by presence (Go)
- **Files:** `cmd/workbench_askguard.go` (+ test).
- **Produces:** `askToolDenialReasonPresent`, `askToolDenialReasonAway` (Part 6); keeps `db.OpenExisting` (read only).
- **Consumes:** G3 `OwnerPresentIn`.
- **Depends on:** G3, G5 (same file → same lane, after G5).
- **Tests:** `TestAskGuard_DeniesAskUserQuestionInALiveWorkbench` (present → present reason; stale, absent, read error → away reason); the PROJ-13 failure, locked-DB, no-DB and no-migration guards still pass for `--pre-tool-use` unchanged.

### G8. State hooks clear the chat question (Go)
- **Files:** `cmd/workbench_session_state.go` (+ test).
- **Produces:** `UserPromptSubmit` → `ClearChatQuestionBefore(event time)`; a main-thread `PostToolUse` that writes `working` out of `waiting` → the same clear.
- **Consumes:** G3.
- **Depends on:** G3, G5 (serial chain G5 → G8 → G9 on the same table — N6).
- **Tests:** `TestChatQuestionClearedByTheOwnersPrompt` (E11); `TestChatQuestionKeptByAnOlderPrompt` (event earlier than `chat_question_at` → kept); `TestChatQuestionClearedByASelfStartedTurn`; a subagent `PostToolUse`, a `SubagentStop`, a notification and a StopFailure keep it; `TestProj11_HookNeverWritesStdoutAndExitsZero` and every existing PROJ-11 hook guard unchanged and green.

### G9. `workbench escalate-question` (Go)
- **Files:** `cmd/workbench_escalate.go` (+ `cmd/workbench_escalate_test.go`).
- **Produces:** the CLI and its JSON envelope (Part 5.3): `{"ok", "outcome": "filed"|"gone", "ask_id", "level", "error_code", "error"}` with `error_code ∈ {busy, open_cap, not_found, bad_args, schema, internal}`; flags `--workbench` (legacy `--project` alias as the other workbench verbs), `--session`, `--at`, `--reason timeout|left|away`.
- **Consumes:** G2 `Validate`/`Level`, G3 `TakeChatQuestion`, `InsertOwnerAsk`.
- **Depends on:** G3, G8 (the G5 → G8 → G9 chain).
- **Tests:** `TestEscalateFilesAQuickAskWithTheSameOptions` (E12: kind, title clip, summary line per reason, options and recommended flags, `origin chat`, `chat_asked_at`, session, single linked target / none for 0 or 2 links); `TestProj13_EscalationIsCompareAndTake` (E11a, E16, E17: a state off `waiting` or stamped past the 30 s tolerance → `gone`); `TestEscalateFourOptionsIsFull` (E19); `TestEscalateZeroOptionsIsQuick` (E18, E10e); `TestEscalateAtTheOpenCapKeepsTheQuestion` (E20, `open_cap`); `TestEscalateEnvelopeShape` (missing row → `not_found`, bad flags → `bad_args`, a locked DB → `busy`; exit 0 always).

### G10. List asks for other clients (Go)
- **Files:** `cmd/workbench_asks_cli.go` (+ test).
- **Produces:** `workbench asks --json [--workbench N] [--open]` (Part 10.1). The answer verb is **deferred** (Part 10.3, F19).
- **Consumes:** G3 reads.
- **Depends on:** G3.
- **Tests:** `TestAsksJSONShape` (every field of 10.1; `--open` keeps only open asks; `--workbench` filters; a row with an unreadable payload is reported, never blanks the others).

### G11. Skill pack v5 and the brief rule (Go)
- **Files:** `internal/devpack/workbenchskill/watchtower-workbench/SKILL.md` (`x-watchtower-pack: v5`, or the next free), `internal/devpack/testdata/watchtower-workbench-v4.md` (the shipped v4), `internal/devpack/workbench_test.go`, `cmd/workbench_brief.go` (`briefRules[0]`), `cmd/workbench_brief_test.go`.
- **Produces:** "Asking the owner" with parts 1–6 of spec Part 7; the `ask_owner` line with `level`; the new brief rule line.
- **Consumes:** G4 (arg names), G5 (guard behaviour it describes).
- **Depends on:** G4, G5.
- **Tests:** the DEV-04 re-install test with the v4 fixture (unedited v4 → v5; edited v4 kept); `workbench_test.go` heading list still finds "## Asking the owner"; a content test asserting the skill names the three levels, the "do not ask" list, "up to 4 questions", `previous_ask_id` with `changes` for a withdrawn ask and `origin: chat`; `TestProj12_AnsweredAskSurvivesAFullBoard` green at the 4000-rune cap with the new rule.

### G12. Docs and inventory (docs only)
- **Files:** `docs/inventory/workbench.md` (PROJ-13 rewritten, PROJ-11/04/02 amended — exact wording in spec Part 11; no PROJ-12 wording change, only its supporting guards from U3), `docs/inventory/dev-surface.md` (DEV-04 fixture note), `docs/features/workbench.md` (levels, presence, guard v4 and the prompt-store exception, escalation, Quick ask, "Asks for other clients" contract from Part 10), `docs/handoff/2026-10-10-mobile-owner-asks.md` (for the mobile project: Part 10.1–10.2 contract, `workbench asks --json` example with placeholder ids, the planned answer verb and delivery of 10.3 as the next step, owner decision D3), CLAUDE.md feature-notes line for workbench updated.
- **Depends on:** G4–G11; the supporting guard names re-checked after U3.
- **Tests:** none (docs); the leak check must pass (no real ids, names, paths).

**Phase 1 gate (controller):** `make test`, `go test ./cmd/...`, `make lint-all`.

## Phase 2 — Swift-Core (one Swift lane)

### C2. Presence policy and queries (Swift-Core)
- **Files:** `WatchtowerCore/Services/OwnerPresencePolicy.swift`, `WatchtowerCore/Database/Queries/OwnerPresenceQueries.swift`, `Tests/Core/OwnerPresencePolicyTests.swift`, `Tests/Core/OwnerPresenceQueriesTests.swift`.
- **Produces:** `OwnerPresencePolicy.presentSession(appActive:keyWindowShows:selectedSession:screenLocked:displaysAsleep:) -> Int64?`; `OwnerPresenceQueries.upsert(sessionID: Int64?, at:)` (enter, heartbeat and leave are one upsert — F11).
- **Depends on:** G1, G3 (stamp fixture).
- **Tests:** `testAppInactiveIsAbsent`, `testLockedScreenIsAbsent` (E32), `testDisplaysAsleepIsAbsent`, `testAnotherSessionOnScreenIsThatSession`, `testDrawerOpenIsStillPresent`; queries: the upsert creates the singleton, overwrites it, and a nil session clears it; the written stamp matches the shared fixture's layout.

### C3. Escalation policy (Swift-Core)
- **Files:** `WatchtowerCore/Services/ChatQuestionEscalationPolicy.swift`, the terminal session row model (`chatQuestionAt` kept as the raw string — F16), `Tests/Core/ChatQuestionEscalationPolicyTests.swift`, `Tests/Core/StampFixtureTests.swift` (reads `internal/db/testdata/stamps`).
- **Produces:** `ChatQuestionEscalationPolicy.decide(row:live:startedAt:presence:hasOwnerDraft:now:) -> Decision (.none / .unreadableStamp / .escalate(.timeout | .left | .away))` — `row` is the `fetchAgentStates` row (`SessionAgentStateRow` with `chatQuestion`/`chatQuestionAt`), `live`/`startedAt` carry `SessionAgentStatus.effective`'s run rules, `presence` is `.present` or `.away(since:)`, `.unreadableStamp` is the spec's "none (logged once)" row for the runner to log; constants `timeout = 600 s`, `leaveGrace = 90 s`, `draftCap = 1800 s`.
- **Depends on:** G1, G3 (stamp fixture).
- **Tests:** a table over spec Part 5.2: `testTenMinutesPresentEscalates` (599 s none, 600 s escalate), `testLeavingEscalatesAfterTheGrace` (89 s none, 90 s left), `testComingBackInsideTheGraceKeepsTheQuestion` (E13a), `testAQuestionRecordedWhileAwayEscalatesAtOnce` (E10b), `testADraftDefersUpToTheCap` (E13b, E15), `testNotWaitingNeverEscalates` (E11, E11a), `testNotLiveNeverEscalates` (E22), `testEarlierRunNeverEscalates`, `testFutureOrUnparsableStampIsNone`; the stamp fixture parses and is kept byte-identical (E35).

### C1. `OwnerAsk` level and origin (Swift-Core) — after #500/#502
- **Files:** `WatchtowerCore/Models/OwnerAsk.swift`, `WatchtowerCore/Services/Chat/ChatQuestionCard.swift` (`ChatQuestionParser`: the owner-ask decode path allows 0 options — F2; the chat card path unchanged), `WatchtowerCore/Database/Queries/OwnerAskQueries.swift`, `WatchtowerCore/Services/OwnerAskPresentation.swift`, `WatchtowerCore/Services/OwnerAskAnswer.swift`, `Tests/Core/OwnerAskTests.swift`, `Tests/Core/ChatQuestionParserTests.swift`, `Tests/Core/OwnerAskPresentationTests.swift`.
- **Produces:** `OwnerAsk.level: Level (.quick/.full)`, `origin: Origin (.agent/.chat)`, `chatAskedAt: String` (raw, '' when not from chat; an unknown level or origin makes the row unreadable, as an unknown kind does today); `OwnerAskPresentation.chatMark(askedAt:now:) -> String?` ("From chat · <1 min" / "· N min"; nil for an unparsable stamp); `OwnerAskAnswer.quick(label:questionID:)`, `.reply(_:questionID:)` builders for the ask's own question id (`payload.questions[0].id` — Go's default id is `"1"`, not `q1`); `reply` cleans the text itself (one line, trimmed, ≤ 500 runes) and returns nil when blank.
- **Consumes:** G1 schema (via `TestDatabase+Schema.swift`), G2's fixture.
- **Depends on:** G1, G2; the #500/#502 Swift lane merged (it edits the same `OwnerAsk*` files — F18).
- **Tests:** decode quick/full/chat rows; unknown level → named in the stack's error line; `testZeroOptionAskDecodes` and `ChatQuestionParserTests.testZeroOptionCardIsRefused` over `owner_ask_zero_options.json` (E18a); a 1-option owner ask still refused; `chatMark` at 0 s, 59 s, 60 s, 12 min, a future stamp, an unparsable stamp; `quick(label:)` and `reply(_:)` JSON accepted by Go's `ValidateAnswer` (shared fixture under `internal/asks/testdata/answers`).

## Phase 3 — Swift services and UI (one Swift lane; U3 and U5 after the #500/#502 lane is merged)

### U1. `OwnerPresenceCenter` (Swift-UI/Services)
- **Files:** `Sources/Services/OwnerPresenceCenter.swift`, wiring in `AppState` and the workbench page/session view (reports the selected session pane), `Tests/OwnerPresenceCenterTests.swift`.
- **Produces:** `OwnerPresenceCenter.presentSessionID`, `awaySince(sessionID:)`, `hasSettled` (observable), `onChange`; writes per Part 2.3 with an injected clock and writer.
- **Consumes:** C2.
- **Depends on:** C2. Does not touch the stack, banner or drawer → may run before the #500/#502 lane lands, but not concurrently with another Swift lane.
- **Tests:** `testAFlickerUnderTwoSecondsIsNotLeaving` (E14), `testEnteringWritesAtOnce`, `testHeartbeatEveryThirtySeconds`, `testAFailedEnterIsRecoveredByTheHeartbeat` (E31), `testQuitClearsPresence` (E33), `testScreenLockClears`, `testSettlesAfterTheFirstComputation`.

### U2. `ChatQuestionEscalator` (Swift-UI/Services)
- **Files:** `Sources/Services/ChatQuestionEscalator.swift`, `Sources/Services/WorkbenchCLI.swift` (the `escalate-question` call; result type in Core `Models/ChatQuestionEscalationResult.swift`), `Tests/ChatQuestionEscalatorTests.swift`, `Tests/Core/ChatQuestionEscalationResultTests.swift`.
- **Produces:** the runner of Part 5.2 (modelled on `SessionBackgroundProber`).
- **Consumes:** C3, U1, `SessionAgentStateCenter` reads, `TerminalCenter.promptDrafts`, G9's envelope.
- **Depends on:** C3, U1, G9.
- **Tests:** `testNothingBeforePresenceSettles` (E22a), `testOneRunInFlightPerSession`, `testATransientFailureIsRetriedAtMostOncePerMinute` (E20: `busy`, `open_cap`), `testANonTransientFailureStopsRetrying` (E20a; a new `chat_question_at` starts fresh), `testGoneOutcomeStopsRetrying`, `testFiledOutcomeAsksTheAsksPollForARead`, `testStopCancelsAndReapsTheRun`, `testPresenceChangeTriggersAnEvaluation`; decode tests for every outcome, every `error_code` and the failure envelope.

### U3. Quick ask in the banner and the stack (Swift-UI) — after #500/#502
- **Files:** `Views/Workbench/Asks/OwnerAskBanner.swift`, `Views/Workbench/Asks/OwnerAskQuickActions.swift` (new, shared), `Views/Workbench/Asks/OwnerAskStackSection.swift`, `ViewModels/OwnerAsksViewModel.swift` (`answer(_:with:)` — the drawer's `answer` refactored onto it, behaviour unchanged), `docs/app-guide.md`, `Tests/OwnerAsksViewModelTests.swift`, `Tests/Core/OwnerAskQuickActionsTests.swift` (presentation model of the row: order, prominence, tooltip, Reply-only).
- **Produces:** Part 9.1–9.3.
- **Consumes:** C1.
- **Depends on:** C1; the #500/#502 Swift lane merged.
- **Tests:** `testProj12_AQuickAnswerFromTheBannerIsStoredThenDeliveredLikeTheDrawers` (E28: identical bytes, pause and Return rules as the drawer path; held at a permission prompt; only pasted over a draft); `testProj12_AReplyIsSentAsOtherOnOneLine` (newlines and control characters become spaces, trimmed, 500-rune clip, empty does nothing); `testAQuickTapOnAWithdrawnAskTypesNothing` (E29); `testRecommendedFirstAndProminent`; `testZeroOptionsShowsOnlyReply` (E18); `testAFullAskKeepsTheOpenButton`; `testButtonsDisabledWhileAnswering`; every existing `testProj12_…` in `OwnerAsksViewModelTests` green unchanged.

### U5. Keyboard navigation of the stack and drawer, #412 (Swift-UI) — last Swift task
- **Files:** `Views/Workbench/Asks/OwnerAskKeyCatcher.swift`, `OwnerAskDrawer.swift`, `OwnerAskDrawerHeader.swift`, `OwnerAskStackSection.swift`, `OwnerAskQuickActions.swift`, `OwnerAskChecklistBody.swift`, `OwnerAskMarginComments.swift`, `docs/app-guide.md`; pure key mapping in Core `WatchtowerCore/Services/OwnerAskKeyMap.swift` with `Tests/Core/OwnerAskKeyMapTests.swift`.
- **Produces:** a key to open the stack; next/previous ask ("k of N"); Tab/Shift-Tab through fields and checklist steps; digits 1–9 choose an option in the focused question (1–3 on a Quick ask card or banner); next/previous review comment; ⌘↩ / ⌘⇧↩ unchanged; every key shown in the controls' hints and in `docs/app-guide.md`. Exact key choices are set in the task's brief from the existing app shortcuts (no conflict with the terminal, Files or Navigate menu keys) and shown to the owner in the manual check — no separate ask (a UI default, per the skill's own "do not ask" rule).
- **Consumes:** U3.
- **Depends on:** U3.
- **Tests:** `OwnerAskKeyMapTests` (each key → action; digits beyond the option count → nothing; any key while the terminal or an editor is focused → nothing, the terminal keeps its keys); `testDigitPicksAQuickOptionOnlyWithTheBannerFocused`; `testCommandReturnStillAnswers` (the existing ⌘↩ tests unchanged).

(U4, delivery of answers written outside the app, is deferred with the answer verb — spec Part 10.3.)

**Phase 2–3 gate (controller):** `make test-swift`, `make lint-all`; then the full gate (`make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`) before the PR, with the G12 docs re-checked against the final test names.

## Manual check (owner, filed as one `kind: check` ask after the PR is green)

1. Repair an existing workbench; `integrate status` shows the new guard.
2. Terminal on screen, window focused: ask the agent something it should ask back briefly → the question stays in the terminal.
3. Same, with Watchtower in the background → the agent files an ask.
4. Chat question, then switch to another app for 2 minutes → a Quick ask "From chat" appears after about 90 s; a 30 s look elsewhere does not raise it.
5. Chat question, stay and wait 10 minutes → a Quick ask "From chat · 10 min".
6. Tap an option in the banner → the agent gets the answer and continues by itself.
7. "Reply…" with a free answer → delivered as text.
8. A review ask still opens the drawer.
9. Keyboard: open the stack, switch asks, pick an option with a digit.
10. Latency and cost: note the end-of-turn delay on a few turns on the claude provider and, if used, on codex; compare the provider's usage before and after a working hour.

## Dependency summary

| Task | Kind | Depends on |
|---|---|---|
| T0 | controller | none |
| G1 | Go | T0 |
| G2 | Go | none |
| G3 | Go | G1, G2 |
| G4 | Go | G3 |
| G5 | Go | G3 (#478 merged) |
| G6 | Go | G5 |
| G7 | Go | G3, G5 (same file) |
| G8 | Go | G3, G5 |
| G9 | Go | G3, G8 |
| G10 | Go | G3 |
| G11 | Go | G4, G5 |
| G12 | Docs | G4–G11 (supporting guard names re-checked after U3) |
| C2 | Swift-Core | G1, G3 |
| C3 | Swift-Core | G1, G3 |
| C1 | Swift-Core | G1, G2, #500/#502 lane merged |
| U1 | Swift-UI/Services | C2 |
| U2 | Swift-UI/Services | C3, U1, G9 |
| U3 | Swift-UI | C1, #500/#502 lane merged |
| U5 | Swift-UI (#412) | U3 |
