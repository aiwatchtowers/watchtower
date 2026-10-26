# Spec review author loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A spec or plan review ask first goes through a hidden reviewer ↔ author loop (up to 3 reviewer rounds). The owner gets one ask with the disputed findings on top, the author's own fixes folded, and a one-press Approve.

**Architecture:** The loop state lives on the ask's own `spec_reviews` row, so the reviewer keeps writing only its row (SPECREVIEW-01). Every round is today's re-round: a new `ask_owner` with `previous_ask_id` that supersedes the hidden previous ask, plus the author's replies. Pure functions in `internal/specreview/loop.go` decide each round:
- the items open for the author;
- the ledger of settled items;
- whether the loop ends.

`specreview.Reveal` is the one writer that ends a loop early. It is called by the run, by `ask_owner`, by the daemon sweep and by a CLI the Desktop calls. The Desktop hides asks whose row is `loop='author'` from every owner surface. A new app-lifetime center types the findings line into the author's session. A loop-mode screen replaces the per-finding marks for asks whose loop ended.

**Tech Stack:** Go 1.26, goose, SQLCipher `database/sql`, `internal/prompts`, cobra; SwiftUI + GRDB (WatchtowerCore + Desktop), DesignKit.

**Spec:** `docs/superpowers/specs/2026-10-26-spec-review-author-loop-design.md`. It builds on `docs/superpowers/specs/2026-10-25-spec-review-design.md` and `docs/features/spec-review.md`. Contracts: `docs/inventory/spec-review.md` (read first).

## Global Constraints

- SPECREVIEW-01..03 stay as they are. The reviewer process writes only its own `spec_reviews` row. Delivery is done by the Desktop, and reveals happen through `specreview.Reveal` on the ask's own row.
- SPECREVIEW-02 holds: `ask_owner` files the ask at once whatever the loop does.
- Round cap: **3 reviewer rounds** per loop. Round 1 runs on the first version; rounds 2 and 3 run on the author's fixes. Constant `specreview.MaxLoopRounds = 3`.
- Author timeout: **30 minutes** per round, counted from the round's `finished_at`. Constant `specreview.AuthorTimeout = 30 * time.Minute`.
  - *Plan's call:* the spec counts from delivery. `finished_at` comes within the Desktop's 3 s poll of it, and it still counts when the Desktop is closed.
- `loop_end` values: `settled`, `cap`, `reviewer_failed`, `session_gone`, `timeout`.
- A loop starts only for a `spec`/`plan` ask that is session-bound (`terminalSessionOf` found a session) on a surface with a launcher. Anything else is today's visible ask.
- Rows and asks that exist before the migration keep today's flow (`loop=''`). No backfill.
- *Plan's call:* spec §1's "the Stop ask guard counts it" and "the brief's open-asks line" need no code. The guard is text-based and never counts asks; the brief lists only answered asks. A hidden ask stays `status='open'`, so `get_ask`/`list_asks`, the open-ask cap and `previous_ask_id` treat it as today.
- Answer JSON (`internal/asks/answer.go`) is unchanged. The final answer is `verdict: approved`, with comments for **Reviewer is right** picks.
- Findings sent to the author:
  - agreements with status `differs`/`missing`;
  - every `decided_alone`;
  - every `blind_spot`;
  - checks with answer `concern`.
- Copy:
  - findings line: `Spec review of ask #<N>, round <R>: <K> findings to address — read them with get_spec_review <N> using the watchtower-workbench skill.` (`finding` when K = 1; one line via `asks.OneLine`)
  - progress line: `Spec review: round <R> of 3`
  - buttons: `Reviewer is right`, `Author is right`, `Reopen`, `Approve`
  - section titles: `Disputed`, `Fixed by the author`
  - cap label: `Not settled in 3 rounds`
  - no-answer reason: `The author did not answer`
- Public repo hygiene: no live data in tests or fixtures.
- Inner loop per task (`go test ./internal/<pkg>`, `make test-swift FILTER=…`, `make lint-diff`, and `make lint-swift` for Swift). Full gate once per phase.

## Review Focus

- **The loop ends (timeout) while the author is filing the next round.** The previous ask is now visible. `ask_owner` with `review_replies` must refuse ("the owner has this review now"), so the owner never gets a second ask — Task 3.
- **The reviewer omits verdicts, invents keys, or calls a `fixed` item `disputed`.** A missing verdict means `open`. Unknown keys are dropped and counted. `disputed` is valid only after a `disagree`; otherwise it counts as `open` — Task 2.
- **The app restarts mid-loop.** The current round's line may be typed again (acceptable). A superseded or revealed round must never be typed — Task 9.
- **The owner re-runs the reviewer on a revealed loop ask** (`start --force`). The row stays `loop='owner'`, and its ledger and replies are kept — Task 1 and Task 2.
- **A hidden ask is answered through a stale path** (the phone relay, an old drawer). The guarded answer refuses and nothing is written — Task 7.

---

## Phase 1 — Go core

### Task 1: Migration 00160 and the loop columns

**Files:**
- Create: `internal/db/migrations/00160_spec_review_loop.sql`
- Modify: `internal/db/spec_reviews.go`, `internal/db/spec_reviews_test.go`, `internal/db/schema.sql`, golden and `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (regenerated)

**Interfaces:**
- Produces:
  - Columns on `spec_reviews`:
    - `loop TEXT NOT NULL DEFAULT '' CHECK(loop IN ('','author','owner'))`
    - `round INTEGER NOT NULL DEFAULT 0`
    - `replies TEXT NOT NULL DEFAULT ''` (JSON `[]Reply` the author sent with this round)
    - `open_items TEXT NOT NULL DEFAULT ''` (JSON `[]AuthorItem` this round hands the author)
    - `ledger TEXT NOT NULL DEFAULT ''` (JSON `[]LedgerEntry`, the whole loop's settled items so far)
    - `loop_end TEXT NOT NULL DEFAULT ''`
  - `db.SpecReview` gains `Loop, Replies, OpenItems, Ledger, LoopEnd string; Round int`, and `specReviewCols`/`scanSpecReview` read them.
  - `type SpecLoopStart struct{ Round int; Replies string }`.
  - `func (db *DB) QueueSpecReview(tx *sql.Tx, askID int64, now time.Time, loop *SpecLoopStart) error`:
    - nil keeps every loop column on conflict;
    - non-nil sets `loop='author'`, `round`, `replies`, and clears `open_items`, `ledger` and `loop_end`.
  - `FinishSpecReview` also writes `Loop, OpenItems, Ledger, LoopEnd` from `r`, but only when the row's `loop='author'`. An `owner` row keeps them.
  - `func (db *DB) RevealSpecLoop(askID int64, end, ledger string, now time.Time) (bool, error)`: `UPDATE … SET loop='owner', loop_end=?, ledger=?, open_items='' WHERE ask_id=? AND loop='author'`. Returns false when it changed nothing.
  - `func (db *DB) SpecLoopsToSweep() ([]SpecLoopRow, error)` with `type SpecLoopRow struct{ AskID int64; Status, FinishedAt string; SessionBound bool }`. It covers rows with `loop='author'` joined to an `owner_asks` row that is still `status='open'`. `SessionBound` = `owner_asks.session_id IS NOT NULL`.

- [ ] **Step 1:** Write tests in `spec_reviews_test.go`:
  - `TestQueueSpecReview_LoopStart` (non-nil sets author/round/replies);
  - `TestQueueSpecReview_NilKeepsLoop` (an `owner` row requeued with nil keeps `loop`, `ledger`, `replies`, `loop_end`);
  - `TestRevealSpecLoop_OnlyFromAuthor` (second call returns false, the ledger is unchanged);
  - `TestSpecLoopsToSweep_OpenAuthorRowsOnly` (a withdrawn ask's row and an `owner` row are not listed).
- [ ] **Step 2:** Run `go test ./internal/db -run 'SpecReview|SpecLoop'` and see FAIL.
- [ ] **Step 3:** Write the migration (`ALTER TABLE spec_reviews ADD COLUMN …` ×6; the Down drops them) and mirror it in `schema.sql`. Update every `QueueSpecReview` caller to pass `nil` (Task 3 passes the loop).
- [ ] **Step 4:** Run `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`, then `go test ./internal/db` and see PASS.
- [ ] **Step 5:** Commit `feat(db): spec review loop columns (00160) (#1121)`.

### Task 2: `internal/specreview` — loop model, verdicts, prompt v2, run

**Depends on:** Task 1.

**Files:**
- Create: `internal/specreview/loop.go`, `internal/specreview/loop_test.go`
- Modify:
  - `internal/specreview/result.go` (`Verdicts`), `testdata/result_keys.golden`
  - `validate.go` (`Parse` validates verdicts), `inputs.go` (`previous` for loop rows), `run.go`
  - `internal/prompts/defaults.go` (`defaultSpecReview` v2, `DefaultVersions[SpecReview] = 2` with its comment)
  - `internal/specreview/run_test.go`, `specreview_test.go`, `prompt_test.go`

**Interfaces:**
- Consumes: Task 1's `db.SpecReview` loop fields, `QueueSpecReview`, `FinishSpecReview` and `RevealSpecLoop`.
- Produces (`loop.go`):
  - `const MaxLoopRounds = 3`; `const AuthorTimeout = 30 * time.Minute`
  - `type Reply struct{ Key string `json:"key"`; Reply string `json:"reply"` /* fixed|disagree */; Note string `json:"note"` }`
  - `type Verdict struct{ Key string `json:"key"`; Verdict string `json:"verdict"` /* resolved|disputed|open */; Note string `json:"note"` }`. `Result` gains `Verdicts []Verdict `json:"verdicts,omitempty"``.
  - `type AuthorItem struct{ Key, Kind, Text, Note string; Where *Anchor; Round int; Reply *Reply }`. `Kind` is `agreement|decided_alone|blind_spot|check`; `Round` is the round that raised it; `Reply` is the author's last reply when the item is carried over.
  - `type LedgerEntry struct{ AuthorItem; Verdict, VerdictNote string; Settled int }`. `Verdict` is `resolved|disputed|unsettled`; `unsettled` also carries the reason in `VerdictNote`.
  - `func Findings(r Result, round int) []AuthorItem` — the four kinds of Global Constraints.
  - `type RoundOutcome struct{ Open []AuthorItem; Ledger []LedgerEntry; End string }`
  - `func NextRound(round int, prevOpen []AuthorItem, prevLedger []LedgerEntry, replies []Reply, r Result) RoundOutcome`
  - `func Reveal(d *db.DB, askID int64, end string, now time.Time) error`

`NextRound` rules:
- **Round 1:** `Open = Findings(r, 1)`, empty ledger.
- **Round n ≥ 2:**
  - Look up each prevOpen item's reply. A missing reply means `fixed` with note `""`.
  - Then apply its verdict:
    - `resolved` → ledger, `Settled=n`;
    - `disputed` with a `disagree` reply → ledger;
    - `disputed` after `fixed`, or a missing verdict → stays open, carrying the reply.
  - New findings are `Findings(r, n)` minus every key already in prevOpen or the ledger.
  - `Open` = the still-open items plus the new findings.
- **End:** `settled` when `Open` is empty. Otherwise `cap` when `n >= MaxLoopRounds`: the open items move to the ledger as `unsettled` with note `Not settled in 3 rounds`, and `Open` becomes empty. Otherwise `""`.

`Reveal` rules:
- It reads the ask's row and, through `owner_asks.previous_ask_id`, the previous row.
- When the row is `done`, the ledger is the row's ledger plus its `open_items` as `unsettled`.
- Otherwise (failed, skipped, queued, running) it is the previous row's ledger plus the previous row's `open_items` as `unsettled`.
- Notes:
  - an item with a `disagree` reply keeps the author's reason in `VerdictNote`;
  - any other item gets `The author did not answer` (timeout or session gone);
  - after a reviewer failure in round ≥ 2, the items the author answered `fixed` were never checked, so their note is the end reason.
- Then `RevealSpecLoop`.

Other changes in this task:
- **Parse:** `Sources` gains `PrevOpenKeys map[string]bool`. A verdict whose key is not in it, or whose verdict is not in the enum, is dropped and counted in `Dropped`. A note is capped like other notes.
- **Inputs:** for a row with `round >= 2`, `previous` replaces the `previous_findings` text with a `previous_open_items ask:<id>` block. It has one line per previous open item: `[<key>] <kind>: <text> — author: fixed (<note>) | disagree: <reason>`.
- **Prompt v2:**
  - On a round ≥ 2, return one `verdicts` entry per `[key]` line.
  - Raise a new finding only about text changed since the previous version or when it would block the work (a broken promise to the owner, a missing contract, a data-loss path).
  - Do not repeat a previous finding as a new item.
  - The rules work on both providers. Keep it data, not instructions, per `add-ai-prompt`.
- **Run**, when the claimed row has `Loop == "author"`:
  - after `Parse`, read the previous row's `open_items`/`ledger` and this row's `replies`;
  - set `OpenItems`, `Ledger`, `LoopEnd` from `NextRound`, with `Loop="owner"` when `End != ""`;
  - then call `FinishSpecReview`.
  - On any failure after the claim: `FailSpecReview`, then `Reveal(…, "reviewer_failed")`.

- [ ] **Step 1:** Write table tests in `loop_test.go`:
  - `TestNextRound_RoundOneOpensFindings` (an `as_agreed` agreement and an `ok` check are not opened);
  - `TestNextRound_ResolvedAndDisputedSettle`;
  - `TestNextRound_DisputedAfterFixedStaysOpen`;
  - `TestNextRound_MissingVerdictStaysOpen`;
  - `TestNextRound_MissingReplyIsFixed`;
  - `TestNextRound_NewFindingsSkipKnownKeys`;
  - `TestNextRound_SettledWhenNothingOpen`;
  - `TestNextRound_CapMovesOpenToUnsettled` (round 3, note `Not settled in 3 rounds`).
- [ ] **Step 2:** Write the remaining tests:
  - in `run_test.go`:
    - `TestReveal_DoneRowUsesItsOpenItems`, `TestReveal_FailedRowUsesPrevious`, `TestReveal_NoOpOnOwnerRow`;
    - `TestRun_LoopRoundTwoFinishes` (a fake agent returns verdicts; the row's `open_items`/`ledger`/`loop` match);
    - `TestRun_LoopFailureReveals`;
  - in `specreview_test.go`: `TestParse_VerdictsUnknownKeyDropped`;
  - in `run_test.go`: `TestSpecReview01_RunWritesOnlyItsRow` gains a loop case (round 2 with a previous row; still only this row changes).
- [ ] **Step 3:** Run `go test ./internal/specreview ./internal/prompts` and see FAIL.
- [ ] **Step 4:** Implement `loop.go`, the Parse/inputs/run changes and prompt v2, then update `result_keys.golden` (`-update` if the test has it, else by hand).
- [ ] **Step 5:** Run `go test ./internal/specreview ./internal/prompts ./internal/digest` and see PASS.
- [ ] **Step 6:** Commit `feat(specreview): author loop rounds, verdicts, reveal (#1121)`.

### Task 3: Tools — loop start, author replies, `get_spec_review`, loop state in reads

**Depends on:** Task 2.

**Files:**
- Modify:
  - `internal/tools/workbench_asks.go`, `internal/asks/asks.go` (`Input` field if it carries args)
  - `internal/tools/workbenches.go` (tool list), `internal/tools/company_data.go` (`unmarkedReadTools`)
  - `internal/tools/workbench_names_test.go` (19), `cmd/actions_registry_test.go`
- Create: `internal/tools/workbench_spec_review.go` and `internal/tools/workbench_spec_review_loop_test.go`

**Interfaces:**
- Consumes: `specreview.Reply`, `AuthorItem`, `LedgerEntry`, `MaxLoopRounds`, `Reveal`, and `db.QueueSpecReview(…, *SpecLoopStart)`.
- Produces:
  - `askOwnerArgs.ReviewReplies []specreview.Reply `json:"review_replies,omitempty"``. Schema description: "with previous_ask_id on a spec review the reviewer is looping with you: one reply per finding of get_spec_review — fixed (optional note) or disagree (reason required)".
  - Tool `get_spec_review` (`AccessRead`, `workbenchSurfaces`). Args: `{ask_id}`. Result keys:
    - `ask_id`, `round`, `max_rounds`;
    - `loop` (`author|owner|""`);
    - `status`, `reason`;
    - `items`: the row's `open_items` when `loop='author'` and `status='done'`, else `[]`;
    - `hint`: one sentence on what to do next.
  - `get_ask` and `list_asks` rows gain `spec_loop` (`author`, `owner`, or omitted).

Loop decision in `fileAsk`/`launchSpecReview`:
- `reviewed && ask.SessionID.Valid && launch != nil` → loop.
- `round` is the previous row's `round + 1` when `previous_ask_id`'s row has `loop='author'`, else 1.
- `QueueSpecReview(…, &SpecLoopStart{round, repliesJSON})`.
- The result key is `spec_review: "author_loop"`.
- A skip or launch failure of a loop row records the skip, then:
  - round 1: `RevealSpecLoop(id, "reviewer_failed", "", now)`;
  - round ≥ 2: `Reveal(…, "reviewer_failed")`.
- The result is then `skipped: <reason>` as today, and the ask is visible.

Validation of `review_replies` (refused with a clear error, the ask not filed):
- only with a `previous_ask_id` whose row is `loop='author'` and whose ask is still `open`. When that ask was revealed (`loop='owner'`), the error is "the owner has this review now — wait for their answer";
- every key must be in that row's `open_items`;
- `reply` must be in `fixed|disagree`;
- `disagree` needs a note; notes are at most 500 runes.

`previous_ask_id` on a hidden ask without replies is allowed: every reply is then `fixed`.

- [ ] **Step 1:** Write tests in `workbench_spec_review_loop_test.go`:
  - `TestAskOwner_SessionBoundSpecStartsLoop` (`spec_review: "author_loop"`, row `loop='author'`, `round=1`);
  - `TestAskOwner_NoSessionNoLoop`;
  - `TestAskOwner_LoopSkipReveals` (a launcher returning `ErrSpecReviewSkipped` leaves `loop='owner'`, `loop_end='reviewer_failed'`);
  - `TestAskOwner_RepliesNeedLoopingPrevious`;
  - `TestAskOwner_RepliesRefusedAfterReveal`;
  - `TestAskOwner_RepliesUnknownKeyRefused`;
  - `TestAskOwner_DisagreeNeedsNote`;
  - `TestAskOwner_RoundTwoQueuedWithReplies`;
  - `TestGetSpecReview_ItemsOnlyForAuthorDone`;
  - `TestGetAsk_SpecLoopKey`.
- [ ] **Step 2:** Run `go test ./internal/tools -run 'SpecReview|AskOwner|GetAsk'` and see FAIL.
- [ ] **Step 3:** Implement. Register `NewGetSpecReview()` after `NewGetReview()` in `workbenchTools`, add it to `unmarkedReadTools` ("the owner's own review loop"), and update the DEV-06 count comment and `require.Len` to 19, plus the `cmd/actions_registry_test.go` list.
- [ ] **Step 4:** Run `go test ./internal/tools ./internal/mcp ./internal/devpack` and `go test ./cmd -run 'Registry|Workbench'`, and see PASS.
- [ ] **Step 5:** Commit `feat(tools): spec review author loop in ask_owner, get_spec_review (#1121)`.

### Task 4: Sweep exits, `spec-review reveal` CLI, `show` keys, session report

**Depends on:** Task 2.

**Files:**
- Modify:
  - `internal/daemon/spec_review_sweep.go` and its test
  - `cmd/workbench_spec_review.go` and its test
  - `internal/sessionreport/report.go` and its test
  - `cmd/workbench_asks_cli.go` and its test

**Interfaces:**
- Consumes: `db.SpecLoopsToSweep`, `specreview.Reveal`, `AuthorTimeout`.
- Produces:
  - `watchtower workbench spec-review reveal --ask N --reason session_gone`. It is hidden from help and accepts only `session_gone`. Exit 0 when it revealed or the row is already `owner`, 1 on error.
  - `show --json` gains the keys `loop`, `round`, `loop_end`, `open_items`, `ledger` (decoded arrays, `[]` when empty). Pin them in the existing keys test.

Sweep:
- A new step `sweepSpecLoops(now)` runs at the start of `phaseSpecReviewSweep`, before the `specReviewLaunch == nil` early return. It is not gated on the launcher.
- For each `SpecLoopsToSweep` row:
  - `!SessionBound` → `Reveal(session_gone)`;
  - `Status == "done"` and `FinishedAt` + `AuthorTimeout` < now → `Reveal(timeout)`.
- The existing dead-reviewer path: after `FailSpecReview` on a loop row, also `Reveal(reviewer_failed)`. The "could not start" path does the same.

`sessionreport` and `workbench asks --json` leave out open asks whose row is `loop='author'`. One db helper serves both: `OwnerAskFilter.ExcludeSpecLoop bool`, applied in `ListOwnerAsks` as `NOT EXISTS (SELECT 1 FROM spec_reviews r WHERE r.ask_id = owner_asks.id AND r.loop = 'author')`.

- [ ] **Step 1:** Write tests:
  - `TestSpecReviewSweep_LoopTimeoutReveals`, `TestSpecReviewSweep_LoopSessionGoneReveals`, `TestSpecReviewSweep_LoopRunsWithoutLauncher`, `TestSpecReviewSweep_DeadReviewerRevealsLoop`;
  - `TestSpecReviewReveal_CLI` (only `session_gone` accepted);
  - `TestSpecReviewShow_JSONKeys` (extend);
  - `TestSessionReport_HiddenLoopAskNotOnYou`.
- [ ] **Step 2:** Run the targeted packages and see FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `go test ./internal/daemon -run SpecReview`, `go test ./cmd -run 'SpecReview|WorkbenchAsks'`, `go test ./internal/sessionreport ./internal/db` and see PASS.
- [ ] **Step 5:** Commit `feat(spec-review): loop exits in the sweep, reveal CLI, hidden asks off the report (#1121)`.

### Task 5: Findings line — Go twin and fixtures

**Depends on:** none.

**Files:**
- Modify: `internal/asks/line.go`, `internal/asks/line_test.go`
- Create: `internal/asks/testdata/spec_review_lines/{one,many}.json`

**Interfaces:**
- Produces:
  - `func SpecReviewLine(askID int64, round, items int) string` — the Global Constraints copy, through `OneLine`.
  - Fixtures `{ask_id, round, items, line}`, read by the Swift twin in Task 8.

- [ ] **Step 1:** Write the test: `TestSpecReviewLine_Fixtures` globs `testdata/spec_review_lines/*.json` (`items: 1` gives "1 finding").
- [ ] **Step 2:** Run it and see FAIL. Implement it. Run it and see PASS.
- [ ] **Step 3:** Commit `feat(asks): spec review findings line (#1121)`.

**Phase 1 gate (controller):** `make test`, `go test ./cmd/...`, `make lint`.

---

## Phase 2 — Desktop

### Task 6: Swift loop model

**Depends on:** Task 1 (schema).

**Files:**
- Modify: `WatchtowerCore/Models/SpecReview.swift` (`SpecReviewRow` init reads `loop`, `round`, `open_items`, `ledger`, `loop_end`)
- Create: `WatchtowerCore/Models/SpecReviewLoop.swift`, `Tests/Core/SpecReviewLoopTests.swift`

**Interfaces:**
- Produces:
  - `SpecReviewRow.loop: Loop` (`enum Loop: String { none = "", author, owner }`), `round: Int`, `loopEnd: String`, `openItems: [SpecReviewLoopItem]`, `ledger: [SpecReviewLedgerEntry]`. These are Decodable twins of Go's `AuthorItem`/`LedgerEntry`; a malformed JSON gives `[]` plus `loopUnreadable = true`.
  - `package enum SpecReviewLoop`:
    - `static func disputed(_ row: SpecReviewRow) -> [SpecReviewLedgerEntry]` (verdict `disputed` or `unsettled`);
    - `static func fixed(_ row: SpecReviewRow) -> [SpecReviewLedgerEntry]` (verdict `resolved`);
    - `static func endedEarly(_ row: SpecReviewRow) -> Bool` (`loopEnd` not in `["settled", ""]`);
    - `static func endLine(_ row: SpecReviewRow) -> String?` (one sentence per end reason; nil for `settled`).

- [ ] **Step 1:** Write tests in `SpecReviewLoopTests`: decoding a Go-shaped row (insert through `TestDatabase.create()`), the `disputed`/`fixed` split, `endedEarly`, and a malformed ledger.
- [ ] **Step 2:** Run `make test-swift FILTER=SpecReviewLoopTests` and see FAIL. Implement it. Run it and see PASS. Run `make lint-swift`.
- [ ] **Step 3:** Commit `feat(desktop): spec review loop model (#1121)`.

### Task 7: Hide author-loop asks from every owner surface

**Depends on:** Task 6.

**Files:**
- Modify:
  - Every site in this list:
    - `OwnerAskQueries.swift`: `openAsks`, `openAsksAllWorkbenches`, `closedAsks`, `closedCounts`, `closedAutomationCount`, `answer`;
    - `WorkbenchQueries+Activity.swift` (`activitySnapshot`), `WorkbenchQueries.swift` (open count);
    - `TerminalSessionQueries.swift` (`fetchAgentStates`, four subqueries);
    - `OwnerAsksViewModel.swift` (`fingerprint`), `WorkbenchBoardViewModel.swift` (two fingerprints);
    - `MobileHub/Slices/WorkbenchTargetSlice.swift`, `AskAlertSlice.swift`, `OwnerAskSlice.swift`;
    - `AutomationQueries.swift`.
  - `MobileHub/FastLane.swift`: observe `spec_reviews` for `[.ownerAsk, .askAlert]` too. `HomeQueries.observedTables` gains `spec_reviews`.
- Test: `Tests/Core/OwnerAskQueriesTests.swift`, `Tests/MobileHub/OwnerAskSliceTests.swift`, `AskAlertSliceTests.swift`, and a TerminalSessionQueries test.

**Interfaces:**
- Produces:
  - `OwnerAskQueries.notInSpecLoop(_ alias: String) -> String`, which returns `NOT EXISTS (SELECT 1 FROM spec_reviews sr WHERE sr.ask_id = <alias>.id AND sr.loop = 'author')`. Every site uses it with its own alias.
  - `answer` adds the clause to its guarded `WHERE`, so a hidden ask throws `AskAnswerError.notOpen` (PROJ-12 stays as it is: still one guarded update).
  - `ask(_:id:projectID:)` stays unfiltered.

- [ ] **Step 1:** Write tests:
  - `testOpenAsksSkipsAuthorLoop`, `testOpenAsksShowsOwnerLoop`, `testAnswerRefusesAuthorLoop`;
  - `testClosedAsksSkipAuthorLoop` (superseded hidden rounds never clutter the closed list);
  - `testAgentStatesIgnoreAuthorLoop` (a session with only a hidden review ask is not "Ready for review");
  - `testOwnerAskSliceSkipsAuthorLoop`, `testAskAlertSkipsAuthorLoop`;
  - `testFastLaneObservesSpecReviews`.
- [ ] **Step 2:** Run `make test-swift FILTER='OwnerAskQueriesTests|OwnerAskSliceTests|AskAlertSliceTests|TerminalSessionQueriesTests|FastLaneTests'` and see FAIL.
- [ ] **Step 3:** Implement. Run `grep -rn "status = 'open'\|status != 'open'" WatchtowerDesktop/Sources` and check every `owner_asks` hit has the clause.
- [ ] **Step 4:** Re-run the tests and see PASS. Run `make lint-swift`.
- [ ] **Step 5:** Commit `feat(desktop): asks in the spec review author loop stay off owner surfaces (#1121)`.

### Task 8: Findings line twin

**Depends on:** Task 5.

**Files:**
- Modify: `WatchtowerCore/Services/OwnerAskPrompt.swift`, `Tests/Core/OwnerAskPromptTests.swift`

**Interfaces:**
- Produces: `package static func specReviewLine(askID: Int64, round: Int, items: Int) -> String`, pinned by `internal/asks/testdata/spec_review_lines` (read with `OwnerAskFixtures`-style loading from the Go testdata path, as the `lines` fixtures are).

- [ ] **Step 1:** Write the test `testSpecReviewLineMatchesGoFixtures`. Run it and see FAIL. Implement it. Run it and see PASS.
- [ ] **Step 2:** Commit `feat(desktop): spec review findings line twin (#1121)`.

### Task 9: `SpecReviewLoopCenter` — delivery and progress

**Depends on:** Tasks 6, 7, 8.

**Files:**
- Create:
  - `WatchtowerCore/Database/Queries/SpecReviewLoopQueries.swift`
  - `Sources/Services/SpecReviewLoopCenter.swift`
  - `Tests/SpecReviewLoopCenterTests.swift`, `Tests/Core/SpecReviewLoopQueriesTests.swift`
- Modify:
  - `Sources/Services/SessionLineDelivery.swift` (`LineKey.specReview(Int64)` and its `logSource`/`logNoun`/`keepsLineBreaks`/`keepsFormatCharacters` cases: one line, no format characters)
  - `Sources/App/AppState.swift` (create and start the center next to `SessionLineDelivery`)
  - `Sources/Views/Workbench/TerminalSessionRow.swift` (progress line in the `reportLine` slot, caption2 secondary)
  - `CLIRunner`/the CLI wrapper that has `specReviewStart` (add `specReviewReveal(askID:)`)

**Interfaces:**
- Consumes: `OwnerAskPrompt.specReviewLine`, `SessionLineDelivery.deliverLine`, `SpecReviewRow`.
- Produces:
  - `SpecReviewLoopQueries.pending(_ db: Database) throws -> [PendingRound]`, where `PendingRound { askID, sessionID, round, items: Int, finishedAt: String }`. It returns rows with `loop='author'` and `status='done'`, with `open_items` non-empty and the ask `status='open'` with a session.
  - `SpecReviewLoopQueries.progress(_ db: Database) throws -> [Int64: Int]`, mapping session id to round for `loop='author'` rows of open asks.
  - `@MainActor final class SpecReviewLoopCenter`:
    - `init(dbPool:delivery:cli:pollInterval: Duration = .seconds(3))`, `start()`, `stop()`;
    - `progress: [Int64: Int]` (observable).
    - It delivers each `(askID, finishedAt)` once per app run. On `.noSession` it calls `cli.specReviewReveal(askID:)` once. On `.held`/`.queued` it retries on the next poll.

- [ ] **Step 1:** Write tests:
  - `testPendingListsDoneAuthorRoundsOnly` (a superseded ask, an `owner` row and a running row are not listed);
  - `testDeliversOncePerFinishedAt`;
  - `testNoSessionRevealsOnce`;
  - `testHeldRetriesNextPoll` (a fake delivery and a fake CLI);
  - `testProgressBySession`.
- [ ] **Step 2:** Run `make test-swift FILTER='SpecReviewLoopCenterTests|SpecReviewLoopQueriesTests|SessionLineDeliveryTests'` and see FAIL.
- [ ] **Step 3:** Implement. The row line reads `Spec review: round <R> of 3`.
- [ ] **Step 4:** Re-run the tests and see PASS. Run `make lint-swift`.
- [ ] **Step 5:** Commit `feat(desktop): deliver spec review rounds to the author, show loop progress (#1121)`.

### Task 10: Loop-mode findings screen and answer

**Depends on:** Tasks 6, 7.

**Files:**
- Create: `Sources/Views/Workbench/Asks/SpecReview/SpecReviewLoopView.swift` (Disputed + Fixed by the author)
- Modify:
  - `SpecReviewView.swift` (`SpecReviewPresentation.drawerMode`: a row with `loop == .owner` gives `.review`, and the view switches to the loop layout; Meaning and chapters stay below, with no mark controls)
  - `SpecReviewModel.swift` (`pick(_ key:, reviewerRight: Bool, body: String)`, `reopen(_ key:, body:)`, `approve()` without the unmarked confirm unless `endedEarly` and a dispute is unpicked)
  - `SpecReviewWrapUpView.swift` (hidden for loop rows)
  - `WatchtowerCore/Services/SpecReviewAnswer.swift` (loop comments)
  - `Tests/SpecReviewModelTests.swift`, `Tests/SpecReviewViewTests.swift`, `Tests/Core/SpecReviewTests.swift`, `Tests/DesignShots/DesignShotFixtures+SpecReview.swift`

**Interfaces:**
- Consumes: `SpecReviewLoop.disputed/fixed/endedEarly/endLine`, `SpecReviewQueries.setMark/clearMark`.
- Produces:
  - Marks reuse the existing states:
    - **Reviewer is right** = `comment` with the owner's optional body;
    - **Author is right** = `ok`;
    - **Reopen** on a fixed item = `comment` with a required body.
    - No marks migration.
  - `SpecReviewAnswer.build` for a loop row turns each `comment` mark on a ledger key into a comment anchored at the entry's `where` (or its chapter heading). Body:
    - for a dispute: `Reviewer is right: <text> — <verdictNote>` plus `\n\n<owner body>` when given;
    - for a reopened fix: `Reopened: <text>\n\n<owner body>`.
    - Verdict is always `approved`. **Send round** is not shown for loop rows.
- Screen:
  - `endLine` banner on top when the loop ended early;
  - **Disputed** cards: finding, reviewer position (`verdictNote`, or the cap or no-answer note), author's reason (`reply.note`), two buttons, an optional comment field;
  - **Fixed by the author**, folded (DisclosureGroup): text, `Round <n>`, author note or `no note`, **Reopen**;
  - **Approve**: one press. After an early end with an unpicked dispute, it asks once ("<n> disputed findings were never answered — approve anyway?").
  - Unpicked disputes count as **Author is right**.
  - DesignKit components only (`Card`, `KitButtonStyles`, `SectionHeader`).

- [ ] **Step 1:** Write tests:
  - `testDrawerModeLoopOwnerIsReview`;
  - `testAnswerReviewerRightBecomesComment`;
  - `testAnswerAuthorRightSendsNothing`;
  - `testReopenNeedsBody`;
  - `testApproveConfirmsOnlyAfterEarlyEnd`;
  - `testLoopAnswerAlwaysApproved`;
  - `testUnpickedDisputeIsAuthorRight`.
- [ ] **Step 2:** Run `make test-swift FILTER='SpecReviewModelTests|SpecReviewViewTests|SpecReviewTests'` and see FAIL.
- [ ] **Step 3:** Implement, and add a design-shot fixture for a loop row (two disputes, three fixes, one early end).
- [ ] **Step 4:** Re-run the tests and see PASS. Run `make lint-swift`. Run `make desktop-shots DESKTOP_SHOTS=<scratch dir>` and look at the loop screen in light and dark.
- [ ] **Step 5:** Commit `feat(desktop): spec review loop screen — disputes, folded fixes, one-press approve (#1121)`.

### Task 11: Phone line counts disputes

**Depends on:** Task 6.

**Files:**
- Modify: `WatchtowerCore/Models/SpecReviewSummary.swift` (`phoneLine`), `MobileHub/Slices/OwnerAskSlice.swift` (`SpecReviewLines` selects `loop, ledger`), `Tests/MobileHub/OwnerAskSliceTests.swift`

**Interfaces:**
- Produces: for a row with `loop == .owner`, the phone line reads `Reviewer and author disagree on <n> · <m> fixed by the author`, or `<m> fixed by the author` when n = 0. The per-`finished_at` cache key also includes `loop_end`.

- [ ] **Step 1:** Write the test `testPhoneLineForLoopRow`. Run it and see FAIL. Implement it. Run it and see PASS. Run `make lint-swift`.
- [ ] **Step 2:** Commit `feat(mobile-hub): spec review loop line on the phone (#1121)`.

**Phase 2 gate (controller):** `make test-swift` and `make lint-all`.

---

## Phase 3 — Pack, docs, contracts

### Task 12: Skill pack, guide, feature note, inventory

**Depends on:** Tasks 3, 10.

**Files:**
- Modify:
  - `internal/devpack/workbenchskill/watchtower-workbench/SKILL.md` (v18) and `watchtower-flow/SKILL.md` (v12);
  - `internal/devpack/testdata/watchtower-workbench-v17.md` (create, the shipped v17 bytes), `methodology.go` (`v17CoreSHA256` and the adoption list);
  - tests `workbench_test.go`, `workbench_methodology_test.go`, `workbench_flow_skill_test.go`;
  - `docs/guide/features/workbench/spec-review.md`, `docs/guide/features/workbench/asks.md`;
  - `docs/features/spec-review.md`;
  - `docs/inventory/spec-review.md` (SPECREVIEW-04, -05, module line, changelog), `docs/inventory/README.md`;
  - `CLAUDE.md` (the spec review line: author loop; DEV-06 nineteen tools in the Diff reviewer line).

Content:
- **Core skill:**
  - After a `spec`/`plan` review ask returns `spec_review: "author_loop"`, wait for the findings line, not the owner's answer.
  - Read `get_spec_review`, then fix or disagree. A disagreement needs a real reason; never disagree to save work.
  - File the next round with `previous_ask_id` + `review_replies`.
  - After `approved` with comments, apply them and carry on without another review round.
- **Flow skill:** the same, in the spec and plan steps.
- **SPECREVIEW-04** guards:
  - `TestSpecReviewSweep_LoopTimeoutReveals`, `TestSpecReviewSweep_LoopSessionGoneReveals`, `TestSpecReviewSweep_DeadReviewerRevealsLoop`;
  - `TestAskOwner_LoopSkipReveals`;
  - `TestRun_LoopFailureReveals`;
  - `TestNextRound_CapMovesOpenToUnsettled`.
- **SPECREVIEW-05** guards: `TestNextRound_*` (every `fixed` reply ends in the ledger or open), `TestReveal_DoneRowUsesItsOpenItems`, `TestReveal_FailedRowUsesPrevious`.

- [ ] **Step 1:** Update the skills and the pack tests. Run `go test ./internal/devpack` and see PASS.
- [ ] **Step 2:** Update the guide, the feature note, the inventory and CLAUDE.md. Run `go test ./docs/guide` (8 KB cap) and see PASS.
- [ ] **Step 3:** Commit `docs(spec-review): author loop — pack v18, guide, SPECREVIEW-04/05 (#1121)`.

**Final gate (controller):** `make test`, `go test ./cmd/...`, `make test-swift`, `make lint-all`. Then the `local-review` skill (debate-review on the PR).
