# Session state during a spec review — "Spec review", not "Idle" — design

Board #1945. Owner report (2026-11-18): "while specs are being reviewed, the session's tasks hang as idle".

## 1. Why

An agent files a spec or a plan with `ask_owner` (`doc_type: spec|plan`); the ask enters the spec review author loop (`spec_reviews.loop = 'author'`, `docs/features/spec-review.md`). While it is in the loop the ask is hidden from every owner surface (`OwnerAskQueries.notInSpecLoop`, Go `askVisible`). The session state reads its open asks through the same filter (`TerminalSessionQueries.fetchAgentStates`, the hub's `terminal_session` slice), so:

1. the agent ends its turn and sits at its prompt (hook `waiting`);
2. the session has no visible open ask, so neither Waiting for you nor Ready to check applies;
3. the reviewer is a detached process (`workbench spec-review run --ask N`), not a background agent of the session, so not Agents working either;
4. the state falls through to `stopped`, captioned **Idle**, a grey dot.

The only hint is the row's second line, "Spec review: round N" (`SpecReviewLoopCenter.progressLine`), which replaces the report line. The session reads Idle for the reviewer's run (up to 10 min) and while the author's next round waits (up to 30 min).

A second, smaller defect: Go `sessionstate.Load` (hub actions: session input, ask answers) counts the hidden asks, so it resolves the same session as `ready_to_check` while the Mac and the phone show Idle.

## 2. Goals, non-goals

- **Goal.** A session with an open ask in the author loop shows its own state, **Spec review · round N**, on the Mac (sessions panel, header switcher, Home), and on the phone through the hub, from one rule pinned by the shared fixture.
- **Goal.** The Go state for hub actions agrees with what the owner sees: hidden asks are not counted there either.
- **Non-goal.** Revealing anything of the hidden ask (its id, title, findings). The state says only that a spec review runs and its round.
- **One caption for the whole loop** (D9): "reviewer running" and "waiting for the author" share it. When the findings land the Desktop types them into the session and the agent's turn starts (Working), so "waiting for the author" is visible only while the line is held until the session reattaches.

## 3. Decisions

| # | Decision | Source |
|---|----------|--------|
| D1 | New session state `spec_review`, placed in the PROJ-11 order between *open ask* and *stopped*: approval > error > working > agents working > ready to check > finished > open ask > **spec review** > stopped > running > not started | ask #1492 |
| D2 | Look: green dot, glyph `doc.text.magnifyingglass`, caption "Spec review · round N"; ring when the session is not live, like every state | ask #1492 |
| D3 | No state notice for it (like waiting on an ask) | ask #1492 |
| D4 | The state needs no hook state of the run: a session not live with a loop ask shows it too (as a ring), like the open-ask states. The owner called this a corner case not worth special handling, so the rule's natural outcome stays and no code is added for it | ask #1497 |
| D5 | Go `sessionstate.Load` drops hidden asks from its counts and reads the loop round, so Go and Swift resolve the same state | decided by the agent |
| D6 | The row's second line "Spec review: round N" goes away; the round lives in the caption, the report line comes back | ask #1497 |
| D7 | The session is idle for input (`IsIdle`, `isAtPrompt`) in this state when its turn is over, as for stopped (the findings line must be typable). A Fix-board-drift session in this state is **not** done: it is left out of `driftFixDoneKinds`, like a Fix waiting on an ask | decided by the agent (internal; no owner-visible change beyond the popover button staying "Open Fix") |
| D8 | Wire: `state_kind` `spec_review` is appended to the Kit's `Kind.knownValues`; tone stays `green`, so no new tone | decided by the agent (wire detail) |
| D9 | One caption for the whole loop, no "reviewer working" / "findings sent" split | ask #1497 |
| D10 | Quick delete off (✕ asks first, like a session with an open ask); Home lists it among the active states, after Agents working, opening the terminal pane | ask #1497 |
| D11 | Phone: no phone code change. A live session in Spec review lands under Working through the Sessions tab's existing default (live → working), the hub's `session_counts` counts it in `working` (green, like running and agents working), and Now's ended list leaves it out (it filters on stopped/finished/failed). A not-live one falls to the default's ended group, the same on old and new phones — the corner case the owner chose not to handle | follows D2 (ask #1492) and D4 (ask #1497) |
| D12 | The "hidden by the author loop" predicate lives once in `internal/db` (`db.AskInSpecLoopSQL(alias)`); `OwnerAskFilter.ExcludeSpecLoop`, the hub's `askVisible`, `sessionstate.Load` and `handlers/ask.go` all use it | decided by the agent (refactor, no behaviour change) |
| D13 | The hub's session timeline records a milestone with the constant text "Spec review" when the state is entered (no round in it, so a new round adds none), like every other state; without it the last milestone could stay "Ready for review" from the filing window | decided by the agent while implementing (task review I1; mirrors the approved D1/D2 state, no new behaviour) |

## 4. The rule

"In the loop" = the session has an open ask with a `spec_reviews` row whose `loop = 'author'` (the row `notInSpecLoop` hides). Its round = `MAX(spec_reviews.round)` over those rows — the value `SpecReviewLoopQueries.progress` already reads.

New row input on both sides: `spec_review_round` (`Int`, 0 = not in the loop), read in the same statement as the open-ask counts:

```sql
(SELECT COALESCE(MAX(sr.round), 0) FROM spec_reviews sr JOIN owner_asks a ON a.id = sr.ask_id
 WHERE a.session_id = s.id AND a.status = 'open' AND sr.loop = 'author') AS spec_review_round
```

Resolution, the resting tail (`SessionAgentStatus.restingKind` / `sessionstate.Resolve`), after the hook-driven states:

```
ready to check (visible asks, none a question)
> finished
> open ask (visible)
> spec review        ← spec_review_round > 0
> stopped (hook waiting)
> running / marked idle / not started
```

Hook-driven states keep winning: while the agent answers findings it is Working; a permission prompt is Needs approval.

## 5. Changes by side

### 5.1 Desktop (WatchtowerCore)

- `SessionSwitcherPresentation.State.Kind.specReview`; `State.specReviewRound: Int` (0 for other kinds).
- `SessionAgentStateRow.specReviewRound` from the query above in `TerminalSessionQueries.fetchAgentStates`.
- `SessionAgentStatus.restingKind` as §4; `isAtPrompt` includes `.specReview`.
- `SessionStatePresentation`: tone `.green`, glyph `doc.text.magnifyingglass`, caption `"Spec review · round \(n)"` (with `· N asks open` when visible asks exist — impossible by the order, so no suffix code), all in the presentation model and unit-tested.
- Exhaustive switches the compiler names: `SessionDeletePolicy` (D10), `SessionAgentNoticePolicy` (nil, D3), `SessionControl.isIdle`/`isWorking` (idle, not working, D7). Sets the compiler does not check: `HomeWorkbenchBuilder.kindOrder` (D10), `WorkbenchesViewModel.driftFixDoneKinds` (left out, D7).
- `SessionsPanelFinishedGroup.reportLine`/`showsSpecReviewLine` and `WorkbenchesViewModel.specReviewLine` removed (D6). `SpecReviewLoopCenter.progressLine` and `progress` stay only if another caller remains; otherwise removed.

### 5.2 Go

- `internal/sessionstate`: `Row.SpecReviewRound`; `StateSpecReview = "spec_review"`; `Resolve` as §4; `IsIdle` lists it with the turn-ended states; `Load` adds the shared predicate (D12) negated to its three counts and the round subquery (D5).
- `internal/db`: `AskInSpecLoopSQL(alias string) string` — `EXISTS (SELECT 1 FROM spec_reviews r WHERE r.ask_id = <alias>.id AND r.loop = 'author')`; `sources.askVisible` becomes `"NOT " + db.AskInSpecLoopSQL("a")`, the `ExcludeSpecLoop` filter and `handlers/ask.go` call it too (`sessionstate` already imports `db`, so no import cycle). The Swift twin `OwnerAskQueries.notInSpecLoop` stays; the two sides are pinned by one shared fixture, `internal/db/testdata/spec_loop_asks.json` (asks with their `spec_reviews.loop`: `author` hidden; `owner`, `''` and no row visible): Go's test runs `AskInSpecLoopSQL` over it, Swift's `OwnerAskQueriesSpecLoopFixtureTests` (Tests/Core) runs `notInSpecLoop` over the same rows in a temp GRDB database, both asserting the expected visible ids.
- `internal/hub/slices/sources/terminal_session.go`: the read adds the round subquery; `resolveState` maps `StateSpecReview` → `kindSpecReview`; `caption()`, tone, glyph as §5.1; `counts` adds it to `Working` (D11); the payload is unchanged in shape (`state_kind` = `spec_review`).
- The shared fixture `internal/sessionstate/testdata/status_cases.json` gains `spec_review_round` on every row (0) and the cases of §8; `SessionAgentStatusFixtureTests` reads it on the Swift side.

### 5.3 Kit and phone

- `TerminalSessionState.Kind.specReview` (`"spec_review"`) appended to `knownValues` (D8). The phone draws caption, tone, glyph and ring as given (PROJ-11); an older phone decodes the open value and draws the same caption/tone/glyph.
- The phone's own per-kind rules need no change (D11): `WorkbenchModels` session grouping's `default` gives working for a live session and ended for a not-live one; `NowModel`'s ended list filters on stopped/finished/failed; `WorkchatStateCard` falls to its default (no card). Tests pin the outcome: `WorkbenchSessionsOrderTests` and `NowWiringTests` gain a spec-review case (Task 3).
- Demo seed: the website workbench gains session 22 "Checkout spec" in Spec review · round 2 (counts `working: 2`) for the screenshot tour.

## 6. Writers and races

The state is derived; nothing new is written.

- `owner_asks`: Go `ask_owner` (inserts `open`), Go withdraw/supersede (`previous_ask_id`), the Desktop's guarded `open → answered` (refused for a loop ask).
- `spec_reviews`: Go only — `ask_owner` queues a row after the ask's transaction commits; `specreview.Run`; daemon `phaseSpecReviewSweep`; `spec-review reveal` (Desktop calls it, Go writes) which sets `loop = 'owner'` or `''`.
- Readers: the Desktop's agent-state poll and the hub's slice read; both read the counts and the round in one statement, so a reveal is seen whole: before it Spec review, after it Ready for review.
- **Window at filing:** between the ask's commit and the `spec_reviews` insert the ask is visible and the session shows Ready for review for one poll at most. Existing behaviour, unchanged; the next poll shows Spec review.
- **Next round:** the author files round N+1 with `previous_ask_id`; the old ask is withdrawn and the new one queued in their own writes. Between them the session may read Working (the agent's turn) — no gap reads Idle while the turn runs.

## 7. Failure paths

| Event | What the session shows | Test |
|-------|------------------------|------|
| The session's host closes (not live) during the loop | Spec review · round N as a ring | fixture "not live, loop round 2" |
| The reviewer crashes / times out | the sweep marks it failed and reveals (`reviewer_failed`) → the ask is visible → Ready for review | fixture "reveal: loop owner" (row with round 0, visible review ask) |
| The session is gone | the sweep reveals `session_gone`; the session row is deleted — nothing to show | existing sweep tests; no new path |
| The app restarts mid-loop | state is derived from the DB on the first poll: Spec review | Swift `SessionAgentStatusTests` resolved from a row, no in-memory state |
| The findings line is held until the session reattaches | Spec review until the agent's turn starts, then Working | fixture "loop + hook working" → working |
| The agent called `finish_session` with a loop running | Finished (higher in the order) | fixture "finished + loop" |
| A visible question ask in the same session | Waiting for you (higher) | fixture "open question + loop" |
| An older phone gets `spec_review` | draws the caption/tone/glyph as sent; groups it as working while live, ended as a ring | Kit decode test with an unknown value already exists; add a known-value case |

## 8. Tests (every promise → task → test)

- Shared fixture cases (Go `TestStatusCases`, Swift `SessionAgentStatusFixtureTests`): live + waiting + round 1 → `spec_review`, idle true; not live + round 2 → `spec_review`, idle false; working + round 1 → `working`; finished + round 1 → `finished`; open question + round 1 → `waiting_for_you`; round 0 + visible review → `ready_to_check`. (Task 1, Task 2)
- `sessionstate.Load` on a DB with a hidden loop ask: counts 0, round N (Task 1).
- Hub slice: a session with a loop ask publishes `state_kind` `spec_review`, caption "Spec review · round 2", tone `green`, glyph `doc.text.magnifyingglass`, `open_asks` 0, no `oldest_ask_id` (Task 1).
- `SessionStatePresentationTests`: colour, glyph, caption, ring for the new kind (Task 2).
- `fetchAgentStates` reads `spec_review_round` (Task 2).
- `SessionAgentNoticePolicy` gives no notice; `SessionDeletePolicy` not quick; `driftFixWorking` true for a Fix in Spec review; Home lists it after Agents working (Task 2).
- Hub `counts`: a spec-review session counts in `working` (Task 1).
- `db.AskInSpecLoopSQL`: on one fixture DB a loop ask is hidden and a revealed one visible through `ListOwnerAsks(ExcludeSpecLoop)`, the slice read and `sessionstate.Load` alike (Task 1).
- Kit: `Kind.specReview` decodes, `knownValues` order appended (Task 3).
- Shared fixture `spec_loop_asks.json`: Go `TestAskInSpecLoopSQLFixture` and Swift `OwnerAskQueriesSpecLoopFixtureTests` give the same visible ids (Tasks 1, 2).
- Phone: `WorkbenchSessionsOrderTests` — a live spec-review session groups under Working, a ring one under Ended; `NowWiringTests` — not in the ended list; `WorkbenchWiringTests` counts updated for the demo session (Task 3).
- Snapshot check of the Mac panel and the phone Sessions tab against the mockups (Tasks 2, 3).

## 9. Contracts touched (owner approved in ask #1492)

- **PROJ-11** (`docs/inventory/workbench.md`): the state set and the order gain *spec review* (D1). Amendment text added with the approval; no guard test weakened — the order guard tests gain the new case.
- **DEV-06 / PROJ-12:** unchanged (no tool, no ask behaviour change).

## 10. Mockups

All under [`docs/design/mockups/session-spec-review-state/`](../../design/mockups/session-spec-review-state/README.md), sample data only, light and dark:

- **Mac sessions panel** — `make desktop-shots` (`DesignShotsTests.testSpecReviewStateShotsRender`, fixture `DesignShotFixtures+SpecReviewState.swift`): `session-state-spec-review-*.png` at 276 pt (Spec review · round 1 live and selected with its report line back, round 3 not live as a ring, then Working, Ready for review, Idle); `session-state-spec-review-narrow-*.png` at 190 pt (captions truncate, dot and glyph stay).
- **iPhone Sessions tab** — `make mobile-shots SHOTS_ONLY=spec-review` (`ScreenshotTourTests.testTheSpecReviewShots`, demo seed session 22): `05r-workbench-sessions-spec-review-*.png`, the session under Working with the green magnifier and "Spec review · round 2".
- The Mac header popover and Home draw the same `SessionLiveDot` + `SessionStateLabel` row parts as the panel shot; their layout does not change, only the state they are given.

No loading, empty or error state exists for this change: the row is drawn from the poll that already runs, and a failed poll keeps the last state as today. The shots are compared again after Tasks 2 and 3.

## 11. Plan outline

1. Go: `sessionstate` + fixture + hub slice + tests. Depends on: none.
2. Desktop: presentation, query, resolution, switches, round line removal, shots. Depends on: Task 1 (fixture).
3. Kit and phone: `Kind.specReview`, the phone's grouping case, demo seed session, tests and the phone shot. Depends on: none.
4. Docs: PROJ-11 amendment, `docs/features/spec-review.md` and `workbench.md` notes, `docs/features/README.md` summary, the states table in `docs/guide/features/workbench/sessions.md` (a **Spec review** row, green). Depends on: 1–3.

## 12. v1 limits

- The caption does not say whether the reviewer is running or the round waits on the author (§2).
- A session with loop asks of two documents shows the highest round.
