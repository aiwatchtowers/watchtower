# Session state during a spec review — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A session whose ask is in the spec review author loop shows **Spec review · round N** instead of **Idle** on the Mac, in the hub and on the phone.

**Architecture:** The state is derived, nothing new is written. One new row input (`spec_review_round`, the highest `spec_reviews.round` of the session's open asks with `loop = 'author'`) feeds the resting tail of the state order on both twins (Swift `SessionAgentStatus`, Go `sessionstate`), pinned by the shared `status_cases.json`. The "hidden by the loop" predicate lives once per language and is pinned by a second shared fixture.

**Tech Stack:** Go 1.26 (`database/sql`, SQLCipher), Swift 5.10 mode (GRDB, WatchtowerCore), WatchtowerKit, iPhone app (xcodegen).

**Spec:** `docs/superpowers/specs/2026-11-18-session-spec-review-state-design.md` (approved, ask #1501; decisions asks #1492, #1497).

## Global Constraints

- Wire kind `spec_review`; caption `Spec review · round N` (`Spec review` when the round is 0); tone `green`; glyph `doc.text.magnifyingglass`; ring when not live.
- Order: approval > error > working > agents working > ready to check > finished > open ask > **spec review** > stopped > running > not started.
- No state notice (D3). Quick delete off (D10). Home lists it after Agents working, pane `.terminal` (D10). Fix-board-drift in Spec review is not done (D7). Idle for input when the turn is over (D7).
- Hidden predicate: an ask is in the loop iff a `spec_reviews` row with `ask_id = ask.id AND loop = 'author'` exists.
- No live-install data in fixtures (`acme`, `example.com`). Inner loop only per task (`go test ./internal/<pkg>`, `make test-swift FILTER=…`, `make kit-test FILTER=…`, `make mobile-test MOBILE_FILTER=…`, `make lint-diff`, `make lint-swift`); the full gate runs once before the PR.
- Already on the branch (commits `a57b974ba`, `67d5bf511`): `Kind.specReview`, `State.specReviewRound`, `SessionStatePresentation` tone/glyph/caption (`specReviewCaption(round:)`), the exhaustive-switch cases in `SessionDeletePolicy`, `SessionAgentNoticePolicy`, `SessionControl`, `SessionAgentStatus.isAtPrompt`, `HomeWorkbenchBuilder.kindOrder`, the Desktop shots and fixture, the phone demo session 22 and its shot. Tasks build on these; they do not redo them.

## Review Focus

1. A revealed loop (`loop = 'owner'` or `''`) must read Ready for review on the very next poll, never stay Spec review — Task 1 and Task 2 fixture case "revealed review ask".
2. A session with a loop ask **and** a visible question ask must read Waiting for you — fixture case "open question + loop".
3. The agent answering findings must read Working, not Spec review — fixture case "working + loop".
4. Hub input to a Spec review session must be accepted like Idle (`IsIdle` true) — Task 1 test `TestSpecReviewSessionTakesInput`.
5. Two loop asks of one session show the higher round — fixture case "two loop asks, rounds 1 and 3" → round 3.

---

### Task 1: Go — shared predicate, `sessionstate`, hub slice

**Depends on:** none.

**Files:**
- Modify: `internal/db/owner_asks.go` (add `AskInSpecLoopSQL`, use it in `ExcludeSpecLoop`)
- Create: `internal/db/testdata/spec_loop_asks.json`, test in `internal/db/owner_asks_test.go`
- Modify: `internal/sessionstate/status.go`, `internal/sessionstate/testdata/status_cases.json`, `internal/sessionstate/status_test.go`
- Modify: `internal/hub/slices/sources/clip.go` (`askVisible`), `internal/hub/slices/sources/terminal_session.go`, `internal/hub/slices/sources/terminal_session_test.go`
- Modify: `internal/hub/actions/handlers/ask.go` (its inline predicate at line ~194, alias `owner_asks` → `"NOT " + db.AskInSpecLoopSQL("owner_asks")`)

**Interfaces:**
- Produces: `func AskInSpecLoopSQL(alias string) string` in package `db` → `EXISTS (SELECT 1 FROM spec_reviews r WHERE r.ask_id = <alias>.id AND r.loop = 'author')`.
- Produces: `sessionstate.Row.SpecReviewRound int`; `sessionstate.StateSpecReview State = "spec_review"`.
- Produces: fixture `internal/db/testdata/spec_loop_asks.json`:
  ```json
  {"asks": [{"id": 1, "loop": "author"}, {"id": 2, "loop": "owner"}, {"id": 3, "loop": ""}, {"id": 4, "loop": null}],
   "visible": [2, 3, 4]}
  ```
  (`loop: null` = no `spec_reviews` row.) Task 2 reads it from Swift.
- Produces: `status_cases.json` rows gain `"spec_review_round"` (0 on every existing case) and the new cases below. Task 2 reads it from Swift.

- [ ] **Step 1: Failing tests.**
  - `TestAskInSpecLoopSQLFixture` (`internal/db`): load the fixture into a test DB (one workbench, one open ask per entry, a `spec_reviews` row when `loop` is not null), select `id FROM owner_asks a WHERE NOT ` + `AskInSpecLoopSQL("a")` ORDER BY id → `[2,3,4]`; `ListOwnerAsks` with `ExcludeSpecLoop: true` returns the same ids.
  - New `status_cases.json` cases (`expect.state`, `idle`):
    - "live, turn over, loop round 1": hook `waiting` this run, open_asks 0, round 1 → `spec_review`, idle true, working false.
    - "not live, loop round 2": no hook, round 2 → `spec_review`, idle false.
    - "working + loop": hook `working`, round 1 → `working`.
    - "finished + loop": finished_at set, round 1 → `finished`.
    - "open question + loop": open_asks 1, open_question_asks 1, round 1 → `waiting_for_you`.
    - "revealed review ask": open_asks 1, open_review_asks 1, round 0 → `ready_to_check`.
  - `TestLoadReadsRowAndOpenAsks` extended: a session with a loop ask (round 1) and a loop ask (round 3) and no visible ask → `OpenAsks 0`, `SpecReviewRound 3`.
  - `TestSpecReviewSessionTakesInput`: `IsIdle(row, StateSpecReview)` true for a live row with a trusted `waiting`.
  - `TestEveryStateKindPublishesTheMacsPresentation`: add case `{"spec review", true, seed: waiting state + loop ask round 2, want{"spec_review", "Spec review · round 2", "doc.text.magnifyingglass", "green"}}`; assert `open_asks` 0 and no `oldest_ask_id` for it.
  - Hub counts test (new `TestSpecReviewCountsAsWorking`): one Spec review session → workbench `session_counts.working == 1`.
- [ ] **Step 2: Run** `go test ./internal/db ./internal/sessionstate ./internal/hub/slices/sources -run 'SpecLoop|StatusFixtures|LoadReads|SpecReview|EveryStateKind'` → FAIL.
- [ ] **Step 3: Implement.** `AskInSpecLoopSQL`; `askVisible = "NOT " + db.AskInSpecLoopSQL("a")`; `ExcludeSpecLoop` and `handlers/ask.go` use it. `sessionstate.Load`: the three counts get `AND NOT `+`db.AskInSpecLoopSQL("a")`, plus `(SELECT COALESCE(MAX(sr.round),0) FROM spec_reviews sr JOIN owner_asks a ON a.id = sr.ask_id WHERE a.session_id = t.id AND a.status = 'open' AND sr.loop = 'author')`. `Resolve`: after `case r.OpenAsks > 0: StateWaitingForYou` add `case r.SpecReviewRound > 0: return StateSpecReview` (before the `hook == "waiting"` case). `IsIdle`: `StateSpecReview` with the turn-ended states. Hub slice: same round subquery in its read, `kindSpecReview = "spec_review"`, `resolveState` maps it and copies the round, `caption()` / tone / glyph per Global Constraints, `counts` → `Working`.
- [ ] **Step 4: Run** the Step 2 command, then `go test ./internal/db ./internal/sessionstate ./internal/hub/... ./cmd -run 'Proj11|SessionState|Ask'` and `make lint-diff` → PASS, no new issues.
- [ ] **Step 5: Commit** `feat(sessionstate): spec review state in Go and the hub (#1945)`.

### Task 2: Desktop — read the round, resolve, retire the round line

**Depends on:** Task 1 (`status_cases.json` cases, `spec_loop_asks.json`).

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/SessionAgentStatus.swift` (`SessionAgentStateRow.specReviewRound`, `restingKind`, `effective` passes the round into `State`)
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/TerminalSessionQueries.swift` (`fetchAgentStates` reads `spec_review_round`)
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/SessionsPanelFinishedGroup.swift`, `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel+Report.swift` (remove `specReviewLine` and its use), `WatchtowerDesktop/Sources/Services/SpecReviewLoopCenter.swift` (remove `progressLine`/`progress` only if no caller remains)
- Tests: `WatchtowerDesktop/Tests/Core/SessionAgentStatusTests.swift`, `WatchtowerDesktop/Tests/SessionAgentStatusFixtureTests.swift`, `WatchtowerDesktop/Tests/Core/SessionStatePresentationTests.swift`, `WatchtowerDesktop/Tests/Core/SessionAgentNoticePolicyTests.swift`, `WatchtowerDesktop/Tests/Core/HomeWorkbenchBuilderTests.swift`, `WatchtowerDesktop/Tests/Core/SessionDeletePolicyTests.swift`, `WatchtowerDesktop/Tests/Core/TerminalSessionQueriesTests.swift` (the `fetchAgentStates` case), new `WatchtowerDesktop/Tests/Core/OwnerAskQueriesSpecLoopFixtureTests.swift`, `WatchtowerDesktop/Tests/WorkbenchesViewModelDriftTests.swift`

**Interfaces:**
- Consumes: Task 1's fixtures; already-present `State(kind:live:…, specReviewRound:)`.
- Produces: `SessionAgentStateRow.specReviewRound: Int` (column `spec_review_round`, 0 when NULL).

- [ ] **Step 1: Failing tests.**
  - `SessionAgentStatusFixtureTests` decodes `spec_review_round` and passes the new cases (its `name(of:)` already maps `.specReview` → `"spec_review"`).
  - `testProj11_StateOrder` gains the spec-review row between open ask and stopped, live and not live (guard extended, never relaxed).
  - `SessionStatePresentationTests`: `.specReview` round 2 → `.green`, `"doc.text.magnifyingglass"`, `"Spec review · round 2"`; round 0 → `"Spec review"`; not live → `isRing` true; `pulses` false.
  - `SessionAgentNoticePolicyTests`: stopped → spec review posts nothing; spec review → working posts nothing.
  - `SessionDeletePolicyTests`: live spec review → not quick (already compiles; add the explicit assert).
  - `HomeWorkbenchBuilderTests`: a spec-review session is listed, after background, before working; pane `.terminal`.
  - DriftFix: a Fix session in `.specReview` is still working (`liveDriftFix` returns it).
  - `fetchAgentStates` on a temp DB with two loop asks (rounds 1, 3) and no visible ask → `openAsks 0`, `specReviewRound 3`.
  - `OwnerAskQueriesSpecLoopFixtureTests`: load `internal/db/testdata/spec_loop_asks.json` (path from the repo root, as `SessionAgentStatusFixtureTests` does) into a temp GRDB DB with the test schema; `SELECT id FROM owner_asks a WHERE \(OwnerAskQueries.notInSpecLoop("a"))` → the fixture's `visible`.
- [ ] **Step 2: Run** `make test-swift FILTER='SessionAgentStatus|SessionStatePresentation|SessionAgentNoticePolicy|SessionDeletePolicy|HomeWorkbenchBuilder|OwnerAskQueriesSpecLoop|DriftFix|TerminalSessionQueries'` → FAIL.
- [ ] **Step 3: Implement.** Row column + query subquery (same SQL as Task 1, alias `s`); `restingKind`: `if row.specReviewRound > 0 { return .specReview }` after the open-ask line, before `turnEnded`; `effective` passes `specReviewRound: row.specReviewRound`. Remove the round line (D6): `reportLine` no longer consults `specReviewLine`; delete `showsSpecReviewLine` and its use; delete `WorkbenchesViewModel.specReviewLine`; drop `SpecReviewLoopCenter.progressLine`/`progress` reads if nothing else uses them (grep first).
- [ ] **Step 4: Run** the Step 2 command, and `make lint-swift` → PASS. Then render the two Mac shots: `cd WatchtowerDesktop && DESKTOP_SHOTS_DIR=$PWD/../build/shots swift test --filter DesignShotsTests/testSpecReviewStateShotsRender` → writes `build/shots/session-state-spec-review{,-narrow}-{light,dark}.png`; open them with Read next to the same names in `docs/design/mockups/session-spec-review-state/` and confirm dot, glyph, caption and the report line under the Spec review row match.
- [ ] **Step 5: Commit** `feat(desktop): Spec review session state (#1945)`.

### Task 3: Kit and phone

**Depends on:** none.

**Files:**
- Modify: `WatchtowerKit/Sources/WatchtowerKit/Models/TerminalSessionState.swift` (`Kind.specReview`, appended to `knownValues`)
- Modify: `WatchtowerKit/Tests/WatchtowerKitTests/WorkbenchMirrorFixtureTests.swift` (lines ~81 and ~99: `.last` becomes `.specReview`, the raw list gains `"spec_review"`)
- Tests: `WatchtowerMobile/Tests/WorkbenchSessionsOrderTests.swift`, `WatchtowerMobile/Tests/NowWiringTests.swift`

**Interfaces:**
- Produces: `TerminalSessionState.Kind.specReview` (`"spec_review"`).

- [ ] **Step 1: Failing tests.** Kit: `knownValues.last == .specReview`, raw list ends `…, "ready_to_check", "spec_review"`. Phone: `testASpecReviewSessionGroupsByLive` — live `spec_review` → Working section, not-live → Ended; `NowWiringTests`: demo session 22 is not in `model.ended`.
- [ ] **Step 2: Run** `make kit-test FILTER=WorkbenchMirrorFixtureTests` and `make mobile-test MOBILE_FILTER=WorkbenchSessionsOrderTests` (and `NowWiringTests`) → FAIL on the Kit asserts (the phone ones may already pass through `default`; they pin it).
- [ ] **Step 3: Implement** the Kit constant. No phone source change (D11).
- [ ] **Step 4: Run** Step 2 commands plus `make mobile-test MOBILE_FILTER=WorkbenchWiringTests`, `make lint-swift` → PASS. Compare `make mobile-shots SHOTS_ONLY=spec-review` with the committed `05r` mockup.
- [ ] **Step 5: Commit** `feat(kit): spec_review session kind (#1945)`.

### Task 4: Docs and the PROJ-11 amendment

**Depends on:** Tasks 1–3.

**Files:**
- Modify: `docs/inventory/workbench.md` (PROJ-11: status line amendment "2026-11-18 for Spec review, owner approved in asks #1492 and #1497, board #1945"; the order sentence; guard list gains `TestAskInSpecLoopSQLFixture`, `OwnerAskQueriesSpecLoopFixtureTests`, the extended `testProj11_StateOrder`)
- Modify: `docs/features/spec-review.md` (the session shows Spec review; the round line is gone), `docs/features/workbench.md` (state list), `docs/features/README.md` (the spec-review summary's "shows `Spec review: round R` on the session" → the state)
- Modify: `docs/guide/features/workbench/sessions.md` (states table: a **Spec review** row, green — "An independent reviewer is checking the agent's spec or plan; it comes to you when the review is done."; the `changed:` front-matter line), per `docs/guide/WRITING.md`

- [ ] **Step 1:** Edit the files above.
- [ ] **Step 2: Run** `go test ./docs/guide` (8 KB page cap) → PASS.
- [ ] **Step 3: Commit** `docs: Spec review session state (#1945)`.

### Gate (controller, before the PR)

`make test`, `make test-swift`, `make lint-all`, `make mobile-test`; then the PR into `main`.
