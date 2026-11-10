# Spec review — open-ended loop, Discuss threads and the summary — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The author loop runs while the author's fixes hold (fuse 8, `stalled` end, drift guards in Go, a new hidden loop after the owner's Request changes), every finding and thesis gets a **Discuss** thread with a read-only agent that can ask the author and propose findings, and the review opens on a short summary.

**Architecture:** Go keeps every rule and every write: loop rules and drift guards in `internal/specreview`, two new tables (author questions, thread findings) written only by Go through CLI verbs, the `answer_review_question` workbench tool and the daemon sweep. The Desktop reads those tables, runs the thread as an embedded chat (`ChatSurfaceSpec`, persisted in `chat_messages` under a context id both sides compute), delivers questions through `SessionLineDelivery`, and shows the summary and per-kind buttons. Screens are built on fixtures and shown to the owner before the logic is wired.

**Tech Stack:** Go 1.26 (goose SQL migrations, cobra, `internal/tools` registry), SwiftUI + GRDB (WatchtowerCore, DesignKit, `EmbeddedChatEngine`).

**Spec:** `docs/superpowers/specs/2026-11-08-spec-review-discuss-design.md` (owner-approved, ask #593). Read with it: `docs/features/spec-review.md`, `docs/inventory/spec-review.md` (SPECREVIEW-01..05), `docs/features/embedded-chat.md`, `docs/review/review-rules.md` ("Swift / Desktop conventions", "The assistant & chat contracts"), `.claude/skills/add-migration`, `.claude/skills/add-desktop-feature`.

## Global Constraints

- Loop fuse: `specreview.MaxLoopRounds = 8`; `AuthorTimeout` stays 30 min; every other exit (`reviewer_failed`, `session_gone`, `timeout`, `owner`) unchanged.
- New loop end `stalled`; `cap` keeps its value. Rising floor from round 3 of a loop: a new finding below `major` (empty severity counts as minor) is dropped.
- Rows and asks from before this ships keep their behaviour: a loop already running finishes under the old cap of 3 (no backfill).
- Reviewer stays read-only and writes only its own `spec_reviews` row (SPECREVIEW-01); every stored quote is a real substring (SPECREVIEW-03). No guard test is weakened or renamed.
- New tables: Go is the only writer; the Desktop only reads them. Every question state change is `UPDATE … WHERE state = 'open'`; the loser gets "the question is closed".
- `answer_review_question`: args `question_id`, `answer` (≤ 2000 runes), workbench surface only; at most one open question per thread; author answer timeout 30 min.
- Thread: embedded chat, strong tier, `--read-folder` on the reviewer's folder (session worktree when recorded, else workbench folder), `toolAccess: .draftOnly` (AGENT-04), counts against the 3-turn embedded gate, LLM usage purpose `spec_review.discuss`. The thread agent never writes and never sets a mark; a proposed finding is added only by the owner's press.
- Summary: `brief` 3–5 lines, `theses` 5–10, thesis kinds `goal`, `decision`, `owner_change`, `non_goal`, `risk`; a thesis whose where-quote is not found is dropped and counted.
- Skip = today's `ok` mark (no new state, no table rebuild); Checked = the same `ok` mark.
- Phone unchanged (one-line status).
- UI strings English; repo text English; no live-install data in tests or docs (CLAUDE.md "Public repo hygiene").
- Migration rules per CLAUDE.md: SQL goose file, `schema.sql`, `TestAllTablesExist`, `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`.
- Inner loop only per task (`go test ./internal/<pkg>`, `make test-swift FILTER=…`, `make lint-diff`); the full gate runs once, in Task 17.

## Review Focus

1. **Thread rows leaking into other features.** Owner chat rows under `context_type = 'spec_review_thread'` must not feed the ideas miner, chat knowledge artifacts or the main chat list, and must go when their workbench is deleted. Test in Task 7.
2. **Answer and expiry racing.** The author answers at 29:59 while the sweep expires the question: exactly one wins, the other gets "the question is closed". Test in Task 8.
3. **Question line over the owner's typing.** The question is delivered only through `SessionLineDelivery` (held mid-turn, typed-not-submitted over a draft, held until hosted sessions reattach). Test in Task 15.
4. **Old loops after the upgrade.** A loop row queued before this ships (`loop_rules = 0`) still ends as `cap` at round 3 with "Not settled in 3 rounds" and never as `stalled`. Test in Task 1.
5. **Forged or foreign thread quotes in add-finding.** A quote from the agent's reply (not an owner row), from another chain's thread, or a `--thread` of another workbench is refused with "not added: quote not found" / a scope error. Test in Task 10.

---

## File map

Go (lane A — loop rules): `internal/specreview/loop.go`, new `chain.go`, `drift.go`, `owner_items.go`; `validate.go`, `result.go`, `inputs.go`, `run.go`; `internal/db/spec_reviews.go`; migration `internal/db/migrations/00177_spec_review_loop_rules.sql`; `internal/tools/workbench_spec_review.go`; `internal/asks/answer.go` (`Comment.ItemKey`).
Go (lane B — threads): migration `00178_spec_review_threads.sql`, new `internal/db/spec_review_threads.go`, `internal/db/chat_knowledge.go`, `internal/kb/source_chat_artifact.go`, `internal/db/workbenches.go`; new `internal/specreview/thread.go`; new `cmd/workbench_spec_review_thread.go`; new `internal/tools/workbench_spec_review_question.go`, `internal/tools/workbenches.go`; `internal/daemon/spec_review_sweep.go`; `internal/asks/line.go` + `testdata/spec_review_question_lines/`; `internal/devpack/workbenchskill/watchtower-workbench/SKILL.md`; `cmd/ai.go` (`--purpose`).
Go (lane C — summary): `internal/specreview/result.go`, `validate.go`, `testdata/result_keys.golden`; `internal/prompts/defaults.go`, `store.go`.
Swift (lanes D/E): `WatchtowerCore/Models/SpecReview.swift`, `SpecReviewLoop.swift`, new `SpecReviewThread.swift`, new `SpecReviewCardActions.swift`; `WatchtowerCore/Database/Queries/` new `SpecReviewThreadQueries.swift`; `WatchtowerCore/Services/` new `SpecReviewThreadBlocks.swift`, `OwnerAskPrompt.swift`, `SpecReviewAnswer.swift`, `WatchtowerAIService.swift`, `Chat/Embedded/ChatSurfaceSpec.swift`, `LLMPurposeNames.swift`; `Services/ChatSurfaces/` new `SpecReviewThreadSurface.swift`; `Services/` new `SpecReviewThreadCenter.swift`, `SpecReviewLoopCenter.swift`, `SessionLineDelivery.swift`, `WorkbenchCLI.swift`; `ViewModels/SpecReviewModel.swift`; `Views/Workbench/Asks/SpecReview/` new `SpecReviewThreadView.swift`, `SpecReviewSummaryView.swift`, `SpecReviewFindingCard.swift`, `SpecReviewLoopView.swift`, `SpecReviewMeaningView.swift`; `Views/Workbench/Asks/OwnerAskStackSection.swift`; `Tests/DesignShots/DesignShotFixtures+SpecReview.swift`, `DesignShotCatalog.swift`.
Docs (lane F): `docs/features/spec-review.md`, `docs/inventory/spec-review.md`, `docs/inventory/dev-surface.md`, `docs/guide/features/workbench/spec-review.md`, `CLAUDE.md`.

Lanes: A = Tasks 1–4; B = Tasks 7–11; C = Task 6, then Task 5 (prompt, after A and C); D = Task 12; E = Tasks 13–15 (after the owner's review of Task 12); F = Task 16; gate = Task 17. Migrations are numbered up front (00174 lane A, 00175 lane B; renumbered to 00177 and 00178 when main took 00174–00176); the controller regenerates the schema golden and the Swift test schema once after merging both.

---

### Task 1: Continue rule, `stalled`, fuse 8, old loops keep the cap of 3

**Depends on:** none

**Files:**
- Create: `internal/db/migrations/00177_spec_review_loop_rules.sql`
- Modify: `internal/db/schema.sql`, `internal/db/spec_reviews.go`, `internal/specreview/loop.go`, `internal/specreview/run.go` (`advanceLoop`), `internal/tools/workbench_spec_review.go` (`specLoopStart`)
- Test: `internal/specreview/loop_test.go`, `internal/db/spec_reviews_test.go`, `internal/tools/workbench_spec_review_loop_test.go`

**Interfaces:**
- Produces: `spec_reviews.loop_rules INTEGER NOT NULL DEFAULT 0` (0 = rules of 2026-10-26, 2 = this spec); `db.SpecReview.LoopRules int`; `db.SpecLoopStart.LoopRules int` (written by `QueueSpecReview`); `specreview.LoopRulesOpen = 2`, `specreview.LegacyMaxLoopRounds = 3`, `specreview.MaxLoopRounds = 8`, `specreview.EndStalled = "stalled"`, `specreview.MaxRoundsFor(rules int) int`; `NextRound(round int, rules int, prevOpen []AuthorItem, prevLedger []LedgerEntry, replies []Reply, r Result) RoundOutcome` (new `rules` parameter).

- [ ] **Step 1: Write the failing tests** in `loop_test.go`:
  - `TestNextRound_ExplicitFixHeldContinues`: round 2, rules 2, one prev item with an explicit `fixed` reply and verdict `resolved`, another prev item with verdict `open` → `End == ""`, one open item.
  - `TestNextRound_NoFixHeldStalls`: round 2, rules 2, one item replied `disagree` + verdict `disputed`… plus one item `fixed` + verdict `open` → `End == EndStalled`, `Open` empty, the still-open item in the ledger as `unsettled` with `VerdictNote == "The reviewer and the author stopped making progress"`; a `disagree` item left open keeps its reply note.
  - `TestNextRound_MissingReplyDoesNotKeepLoopGoing`: no replies, verdict `resolved` on one of two items → ledger has it (SPECREVIEW-05 unchanged) but `End == EndStalled`.
  - `TestNextRound_Round1NeverStalls`: round 1 with findings → `End == ""`.
  - `TestNextRound_FuseAt8`: round 8, rules 2, a held fix and an open item → `End == EndCap`, note `"Not settled in 8 rounds"`.
  - `TestNextRound_LegacyRulesCapAt3`: rules 0, round 3, open items with no held fix → `End == EndCap`, note `"Not settled in 3 rounds"`, never `EndStalled` (Review Focus 4).
  - Update the existing `TestNextRound_*` calls to the new signature with `rules: 0`; `TestNextRound_CapMovesOpenToUnsettled` keeps its assertions (SPECREVIEW-04 guard).
- [ ] **Step 2: Run** `go test ./internal/specreview -run TestNextRound` — expect FAIL (signature / missing constants).
- [ ] **Step 3: Migration + db.** `00177_spec_review_loop_rules.sql`: `ALTER TABLE spec_reviews ADD COLUMN loop_rules INTEGER NOT NULL DEFAULT 0;` (Down: drop column). Mirror in `schema.sql`. `QueueSpecReview` writes `loop.LoopRules` when `loop != nil`; `specReviewCols`/`scanSpecReview` read it. Test `TestQueueSpecReview_StoresLoopRules`.
- [ ] **Step 4: Implement `NextRound`** per the spec §1 continue rule: progress = some prev item whose reply came from `replies` with `Reply == fixed` and whose verdict is `resolved`. Order of ends: nothing open → `settled`; `round >= MaxRoundsFor(rules)` → `cap`; `rules >= LoopRulesOpen && round >= 2 && !progress` → `stalled` (open items to the ledger as `unsettled`; a `disagree` item's note is its reply note, else the stalled note); rules 0 never stalls and continues as today. `advanceLoop` passes `row.LoopRules`. `specLoopStart` sets `LoopRules` = the previous loop row's value when advancing a loop, else `LoopRulesOpen`, and compares `start.Round` with `MaxRoundsFor(LoopRules)`.
- [ ] **Step 5: Run** `go test ./internal/specreview ./internal/db ./internal/tools` — expect PASS; `make lint-diff`.
- [ ] **Step 6: Commit** `feat(spec-review): loop runs while fixes hold — stalled end, fuse of 8, old loops keep 3`.

---

### Task 2: The review chain and the closed list

**Depends on:** Task 1

**Files:**
- Create: `internal/specreview/chain.go`
- Modify: `internal/db/spec_reviews.go`, `internal/specreview/result.go` (`Sources`), `internal/specreview/inputs.go`
- Test: `internal/specreview/chain_test.go`, `internal/db/spec_reviews_test.go`, `internal/specreview/inputs_test.go`

**Interfaces:**
- Produces: `func (db *DB) SpecReviewChain(askID int64) ([]int64, error)` — ask ids along `owner_asks.previous_ask_id`, root first, ending with `askID` (recursive CTE, cycle-safe by a depth cap of 100); `type ClosedItem struct { Key, Kind, WhereQuote string }`; `func ClosedList(d *db.DB, askID int64) ([]ClosedItem, error)` — over every earlier ask of the chain: ledger entries with verdict `resolved` whose reply is `fixed` (or missing), every key with an `ok` or `not_useful` mark, and every ledger key the owner picked **Author is right** (an `ok` mark on a disputed entry); `Sources.Closed []ClosedItem`, `Sources.KnownKeys map[string]bool` (every key in a ledger or open list along the chain).

- [ ] **Step 1: Write failing tests**: `TestSpecReviewChain_RootFirst` (three linked asks → `[a1, a2, a3]`; an ask with no previous → `[id]`); `TestClosedList_FixedSkippedAuthorRight` (resolved-after-fixed, `ok` mark, `not_useful` mark, `ok` on a disputed entry all listed with kind and where-quote; a `comment` mark is not); `TestClosedList_CarriesAcrossLoops` (a key closed in a loop before the owner's answer is on the list of the next loop's round 1); `TestBuildInputs_ClosedItemsBlock` (the user message has a `closed_items` block, one line `[<key>] <kind>: <where-quote>` each; empty list → no block).
- [ ] **Step 2: Run** `go test ./internal/specreview ./internal/db -run 'Chain|Closed'` — FAIL.
- [ ] **Step 3: Implement** `SpecReviewChain`, `ClosedList` (reads each chain row with `GetSpecReview`, its marks with `ListSpecReviewMarks`, the finding kind/where from the row's result or ledger), and in `BuildInputs` fill `Sources.Closed`/`KnownKeys` and add the fenced `closed_items` block after the previous round's blocks.
- [ ] **Step 4: Run** `go test ./internal/specreview ./internal/db` — PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(spec-review): review chain and the closed list`.

---

### Task 3: Drift guards in `Parse`

**Depends on:** Task 2

**Files:**
- Create: `internal/specreview/drift.go`
- Modify: `internal/specreview/result.go`, `internal/specreview/validate.go`, `internal/specreview/inputs.go`, `internal/specreview/testdata/result_keys.golden`
- Test: `internal/specreview/drift_test.go`, `internal/specreview/specreview_test.go`

**Interfaces:**
- Consumes: `Sources.Closed`, `Sources.KnownKeys`, `Sources.PrevOpenKeys` (Task 2).
- Produces: `Sources.LoopRound int` (0 = not a loop round), `Sources.PrevDoc string` (previous ask's snapshot along the chain, "" for none), `Sources.NewRefs map[string]bool` (conversation entries, asks and comments newer than the previous ask's `created_at`); `Result.DroppedBy map[string]int \`json:"dropped_by,omitempty"\``; drop reasons `DropUnchangedText = "on unchanged text"`, `DropMinorLate = "minor finding after round 2"`, `DropDecided = "already decided"`; `func unchangedIn(prevDoc, doc string) func(quote string) bool` (drift.go).

Decisions this task fixes (spec §1 leaves the diff method open):
- *Unchanged text* is paragraph-level: the document is split into blank-line-separated blocks, each normalised; a where-quote is "wholly in unchanged text" when it lies inside one block of the current document that also occurs as a whole block of `PrevDoc`. A quote spanning blocks, or in a changed block, is changed text.
- A *new finding* is one whose key is in neither `PrevOpenKeys` nor `KnownKeys`; carried items pass untouched.
- A `concern` check (no where-quote) is on changed text when its chapter contains a changed block.
- A finding with no where-quote passes from round 2 only when it is a blocker or its `source.ref` is in `NewRefs` (blind spots without a where have no source: blocker only).
- The guards apply only when `LoopRound >= 2`, or `LoopRound == 1` with `PrevDoc != ""` (a new loop after the owner's answer, Task 4); the rising floor only when `LoopRound >= 3`. The closed-list drop applies on every loop round.

- [ ] **Step 1: Write failing tests**: `TestUnchangedIn` (quote in a kept paragraph → true; edited paragraph → false; quote across two paragraphs → false); `TestParse_Round2DropsNonBlockerOnUnchangedText` (major on unchanged text dropped with `DroppedBy["on unchanged text"] == 1`; blocker kept; same finding on changed text kept); `TestParse_Round2UnanchoredNeedsNewSource` (missing agreement quoting an old entry dropped, quoting a `NewRefs` entry kept); `TestParse_Round3DropsMinorAndEmptySeverity` (minor and empty dropped as "minor finding after round 2", major kept, a carried minor item with a `PrevOpenKeys` key kept); `TestParse_ClosedKeyAndRewordedRepeatDropped` (key on `Closed` dropped; new text with the same where-quote and kind dropped; same where-quote, other kind kept); `TestParse_NotALoopRoundUnchanged` (`LoopRound 0`: none of the guards); existing SPECREVIEW-03 tests unchanged and passing.
- [ ] **Step 2: Run** `go test ./internal/specreview -run 'Unchanged|Parse_'` — FAIL.
- [ ] **Step 3: Implement** a `validator.drift(kind, key, severity string, where *Anchor, srcRef, chapter string) (reason string)` called by `agreements`, `decidedAlone`, `blindSpots`, `checks` after their existing checks; a non-empty reason drops and counts in both `Dropped` and `DroppedBy[reason]`. `BuildInputs` sets `LoopRound` from the row (`loop = 'author'`), `PrevDoc` from the previous ask's snapshot (same trim as `maxPrevDocRunes`), `NewRefs` from entry/ask/comment times. Update `result_keys.golden` for `dropped_by`.
- [ ] **Step 4: Run** `go test ./internal/specreview` — PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(spec-review): drift guards in Parse — changed text, rising floor, closed stays closed`.

---

### Task 4: A new hidden loop after Request changes (D8), owner items, `get_spec_review` wording

**Depends on:** Task 3, Task 7

**Files:**
- Create: `internal/specreview/owner_items.go`
- Modify: `internal/asks/answer.go` (`Comment`), `internal/tools/workbench_spec_review.go`, `internal/specreview/run.go`, `internal/specreview/loop.go` (`Reveal`), `internal/specreview/inputs.go` (`previous`, `loopRound`)
- Test: `internal/specreview/owner_items_test.go`, `internal/specreview/run_test.go`, `internal/tools/workbench_spec_review_loop_test.go`, `internal/asks/answer_test.go`

**Interfaces:**
- Consumes: `NextRound(..., rules, ...)` (Task 1), `ClosedList` (Task 2), `db.ListSpecReviewThreadFindings(askID int64) ([]db.SpecReviewThreadFinding, error)` (Task 7).
- Produces: `asks.Comment.ItemKey string \`json:"item_key,omitempty"\`` (the mark key a findings comment came from; margin comments leave it empty); `specreview.KindOwnerComment = "owner_comment"`; `func SeedOf(d *db.DB, ask *db.OwnerAsk) ([]AuthorItem, error)` — nil unless `ask` is round 1 of a loop whose previous ask's review the owner had (`ownerHas`) and answered with verdict `changes`; then one item per previous answer comment (key = `ItemKey`, else `itemKey("oc:", body, quote)`; kind/text/severity from that key's finding — result, ledger or thread finding — else `owner_comment` with the comment body; `Where` = comment heading + quote) plus every thread finding of the previous ask not already keyed and not on the closed list; `Round: 1`.

- [ ] **Step 1: Write failing tests**:
  - `TestComment_ItemKeyRoundTrips` (omitted when empty; old answers decode).
  - `TestSeedOf_ChangesAnswerSeedsOwnerItems` (two comments, one with `item_key` of a finding, one margin comment, one thread finding → three items; a key with an `ok` mark is not seeded); `TestSeedOf_ApprovedSeedsNothing`; `TestSeedOf_NotRound1SeedsNothing`.
  - `TestSpecLoopStart_ChangesStartsNewLoop` (previous row `loop='owner'`, ask answered `changes`, session + launcher → `SpecLoopStart{Round: 1, LoopRules: 2}`); `TestSpecLoopStart_ApprovedStaysClassic` (answered `approved` → nil); `TestSpecLoopStart_NoSessionStaysClassic`.
  - `TestRun_SeededRound1VerdictsOwnerItems` (the reviewer's verdicts on seeded keys settle them as in round 2: a resolved owner item lands in the ledger, an `open` one stays open; the input carries a `previous_open_items` block listing the seed; no stall at round 1).
  - `TestReveal_SeededRoundFailedShowsOwnerItems` (a failed seeded round 1 reveals the owner items as unsettled with "The fix was not checked: the reviewer failed").
  - `TestGetSpecReview_HintHasNoRoundCap` (round 3 of a loop: `hint` never contains "last round" and `max_rounds == 8`).
- [ ] **Step 2: Run** `go test ./internal/specreview ./internal/tools ./internal/asks -run 'Seed|Comment_ItemKey|SpecLoopStart|SeededRound|GetSpecReview_Hint'` — FAIL.
- [ ] **Step 3: Implement.** `specLoopStart`: the `ownerHas(row)` case starts `Round: 1` when `prev.Status` is `answered`/`delivered` and the stored answer's verdict is `changes`, else nil as today (replies on such an ask stay refused with `errOwnerHasReview`). `advanceLoop` and `inputs.previous` use `SeedOf` as `prevOpen` / the `previous_open_items` block when it is non-nil (`PrevOpenKeys` = seed keys). `Reveal` on a not-done seeded round 1 uses the seed as `open`. `specReviewOf` reports `MaxRounds: MaxRoundsFor(row.LoopRules)`; the hint texts name no cap.
- [ ] **Step 4: Run** `go test ./internal/specreview ./internal/tools ./internal/asks` — PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(spec-review): a hidden loop after Request changes checks the owner's items first`.

---

### Task 5: Prompt `review.spec` v4

**Depends on:** Task 3, Task 4, Task 6

**Files:**
- Modify: `internal/prompts/defaults.go` (`defaultSpecReview`), `internal/prompts/store.go` (version map)
- Test: `internal/specreview/prompt_test.go`, `internal/prompts/store_test.go`

- [ ] **Step 1: Write failing tests** in `prompt_test.go`: `TestSpecReviewPrompt_V4` — version 4; the text names the `closed_items` block ("already decided, do not raise"), the rising floor ("from round 3 … only major or blocker"), owner items in `previous_open_items` (kind `owner_comment`), `brief` and `theses` with the five kinds and the 5–10 bound, and the reply shape shows `"brief"` and `"theses"`; the round-2 rule paragraph stays.
- [ ] **Step 2: Run** `go test ./internal/specreview ./internal/prompts -run 'Prompt|Version'` — FAIL.
- [ ] **Step 3: Edit the prompt** (wording is the builder's, spec "Left to the builder"); version comment: `v4: open-ended loop — closed list, rising floor, owner items; brief and theses (2026-11-08-spec-review-discuss-design §1, §4)`. Per `.claude/skills/add-ai-prompt`, the text must work on claude and codex.
- [ ] **Step 4: Run** the same tests — PASS. **Commit** `feat(spec-review): reviewer prompt v4`.

---

### Task 6: `brief` and `theses` in the reviewer's result

**Depends on:** none

**Files:**
- Modify: `internal/specreview/result.go`, `internal/specreview/validate.go`, `internal/specreview/limits.go`, `internal/specreview/testdata/result_keys.golden`
- Test: `internal/specreview/summary_test.go`

**Interfaces:**
- Produces: `Result.Brief string \`json:"brief"\``, `Result.Theses []Thesis \`json:"theses"\``; `type Thesis struct { Key, Kind, Text, Chapter string; Where Anchor }` (JSON `key`, `kind`, `text`, `chapter`, `where`); thesis kinds `ThesisGoal = "goal"`, `ThesisDecision = "decision"`, `ThesisOwnerChange = "owner_change"`, `ThesisNonGoal = "non_goal"`, `ThesisRisk = "risk"`; `maxTheses = 10`, `maxBriefRunes = 1200`; key `itemKey("th:", kind+"\x00"+text, "")` (spec §4: kind and normalised text only, so a thread survives a re-run).

- [ ] **Step 1: Write failing tests**: `TestParse_ThesesValidated` (unknown kind dropped, where-quote not in its chapter dropped, both counted in `Dropped`; chapter comes from the anchor; an 11th dropped); `TestParse_ThesisKeyIgnoresQuote` (same kind+text, different where → same key); `TestParse_BriefClipped`; `TestParse_NoBriefIsFine` (old reply → `Brief == ""`, `Theses == []`); golden keys updated.
- [ ] **Step 2: Run** `go test ./internal/specreview -run 'Theses|Thesis|Brief'` — FAIL.
- [ ] **Step 3: Implement** `validator.theses(in []Thesis) []Thesis` beside `decidedAlone` (the same `anchor` check) and clip `Brief`.
- [ ] **Step 4: Run** `go test ./internal/specreview` — PASS. **Commit** `feat(spec-review): summary brief and theses in the result`.

---

### Task 7: Tables for author questions and thread findings

**Depends on:** none

**Files:**
- Create: `internal/db/migrations/00178_spec_review_threads.sql`, `internal/db/spec_review_threads.go`
- Modify: `internal/db/schema.sql`, `internal/db/db_test.go` (`TestAllTablesExist`), `internal/db/chat_knowledge.go`, `internal/kb/source_chat_artifact.go`, `internal/db/workbenches.go`
- Test: `internal/db/spec_review_threads_test.go`, `internal/db/chat_knowledge_test.go`, `internal/db/workbenches_test.go`, `internal/tools/code_question_guard_test.go`, `internal/memory/code_question_guard_test.go`

**Interfaces:**
- Produces (schema):
  - `spec_review_questions(id INTEGER PRIMARY KEY AUTOINCREMENT, ask_id INTEGER NOT NULL REFERENCES owner_asks(id) ON DELETE CASCADE, thread TEXT NOT NULL, item_key TEXT NOT NULL, question TEXT NOT NULL, answer TEXT NOT NULL DEFAULT '', state TEXT NOT NULL DEFAULT 'open' CHECK(state IN ('open','answered','expired','gone')), created_at TEXT NOT NULL, closed_at TEXT NOT NULL DEFAULT '')` + `CREATE UNIQUE INDEX idx_spec_review_questions_open ON spec_review_questions(thread) WHERE state = 'open'` (one open question per thread).
  - `spec_review_thread_findings(ask_id INTEGER NOT NULL REFERENCES owner_asks(id) ON DELETE CASCADE, item_key TEXT NOT NULL, thread TEXT NOT NULL, finding TEXT NOT NULL, created_at TEXT NOT NULL, PRIMARY KEY(ask_id, item_key))`.
- Produces (Go): `const SpecReviewThreadContextType = "spec_review_thread"`; `type SpecReviewQuestion struct { ID, AskID int64; Thread, ItemKey, Question, Answer, State, CreatedAt, ClosedAt string }`; `ErrQuestionClosed = errors.New("the question is closed")`; `ErrQuestionOpen` (a thread already has one); `(db *DB) FileSpecReviewQuestion(askID int64, thread, itemKey, question string, now time.Time) (int64, error)`; `AnswerSpecReviewQuestion(id int64, answer string, now time.Time) error` / `CloseSpecReviewQuestion(id int64, state string, now time.Time) error` (both `WHERE id = ? AND state = 'open'`, zero rows → `ErrQuestionClosed`); `GetSpecReviewQuestion(id int64) (*SpecReviewQuestion, error)`; `OpenSpecReviewQuestionsToSweep() ([]SpecReviewQuestionSweep, error)` (`{ID, CreatedAt string, SessionBound bool}`, session bound = the ask's `session_id IS NOT NULL`); `type SpecReviewThreadFinding struct { AskID int64; ItemKey, Thread, Finding, CreatedAt string }`; `InsertSpecReviewThreadFinding(f SpecReviewThreadFinding) error`; `ListSpecReviewThreadFindings(askID int64) ([]SpecReviewThreadFinding, error)`; `OwnerThreadLines(contextID string) ([]string, error)` (texts of `role = 'user'` rows of the conversation with `context_type = 'spec_review_thread'` and that `context_id`, active branch only).

- [ ] **Step 1: Write failing tests**: `TestSpecReviewQuestions_OneOpenPerThread` (second file on the same thread → `ErrQuestionOpen`); `TestSpecReviewQuestions_AnswerAndCloseRace` (answer then expire → expire gets `ErrQuestionClosed`; expire then answer → answer gets it; row state is the winner's) — Review Focus 2; `TestSpecReviewThreadFindings_CascadeWithAsk`; `TestOwnerThreadLines_OwnerRowsOnly` (assistant and system rows excluded); `TestListChatTurnsForIdeas_SkipsSpecReviewThreads` and the chat-artifact source skip (Review Focus 1); `TestDeleteWorkbench_DropsSpecReviewThreads` (conversations with `context_type = 'spec_review_thread'` **and** `context_id` starting with `<workbench>:` — both conditions, as `deleteWorkbenchCodeQuestions`; a test conversation of another `context_type` with the same prefix survives); the existing guards `TestCodeQuestionGuard_NoGoToolReadsChatHistory` (`internal/tools/code_question_guard_test.go`) and `TestCodeQuestionGuard_ChatIngestNeverReadsCodeQuestions` (`internal/memory/code_question_guard_test.go`) extended so they also require every chat reader to exclude `spec_review_thread` (a new case beside `code_question`, assertions only added, nothing relaxed); `TestAllTablesExist` lists both tables.
- [ ] **Step 2: Run** `go test ./internal/db ./internal/kb ./internal/tools ./internal/memory -run 'SpecReview|ThreadLines|Ideas|ChatArtifact|DeleteWorkbench|AllTables|CodeQuestionGuard'` — FAIL.
- [ ] **Step 3: Implement** the migration (follow `add-migration`; plain `CREATE TABLE`, no rebuild), `schema.sql`, the access file, `'spec_review_thread'` added to both `NOT IN` lists of `ListChatTurnsForIdeas` and to `source_chat_artifact.go`'s filter, and `deleteWorkbenchSpecReviewThreads(tx, workbenchID)` beside `deleteWorkbenchCodeQuestions`.
- [ ] **Step 4: Run** the tests — PASS; regenerate `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update` (the controller reruns it after merging Task 1); `make lint-diff`.
- [ ] **Step 5: Commit** `feat(spec-review): tables for author questions and thread findings`.

---

### Task 8: Thread key and `spec-review question`; the sweep expires questions

**Depends on:** Task 2, Task 7

**Files:**
- Create: `internal/specreview/thread.go`, `internal/specreview/testdata/thread_keys.json`, `cmd/workbench_spec_review_thread.go`
- Modify: `cmd/workbench_spec_review.go` (register subcommands), `internal/daemon/spec_review_sweep.go`
- Test: `internal/specreview/thread_test.go`, `cmd/workbench_spec_review_thread_test.go`, `internal/daemon/spec_review_sweep_test.go`

**Interfaces:**
- Consumes: `db.SpecReviewChain` (Task 2), question methods (Task 7).
- Produces: `func ThreadContextID(workbenchID, rootAskID int64, itemKey string) string` = `"<workbench>:<root>:<key>"`; `func ParseThreadContextID(s string) (workbenchID, rootAskID int64, itemKey string, ok bool)`; `QuestionTimeout = AuthorTimeout`; `maxQuestionRunes = 1000`; CLI `watchtower workbench spec-review question --ask N --item K` (question on stdin; prints the id; exit 3 with "a question is already open in this thread" or "ask N has no session"); `watchtower workbench spec-review question --close ID --reason gone` (exit 0 when closed, exit 3 "the question is closed"). Thread for `--ask N --item K` = `ThreadContextID(ask.WorkbenchID, chain[0], K)`.

- [ ] **Step 1: Write failing tests**: `TestThreadContextID_Fixture` (every case in `testdata/thread_keys.json` — `{workbench_id, root_ask_id, item_key, context_id}` — round-trips; the Swift twin reads the same file in Task 13); `TestSpecReviewQuestionCmd_FilesAndPrintsID`; `TestSpecReviewQuestionCmd_RefusesSecondOpen`; `TestSpecReviewQuestionCmd_RefusesNoSession`; `TestSpecReviewQuestionCmd_CloseGone`; `TestSpecReviewSweep_ExpiresQuestions` (open > 30 min → `expired`; session unbound → `gone`; answered row untouched) — sweep step runs in `phaseSpecReviewSweep` next to `sweepSpecLoops`, without the launcher.
- [ ] **Step 2: Run** `go test ./internal/specreview ./internal/daemon -run 'Thread|Question'` and `go test ./cmd -run SpecReviewQuestion` — FAIL.
- [ ] **Step 3: Implement**; the CLI opens the database writable (`db.Open`), reads stdin to `maxQuestionRunes` (longer → usage error), trims; the sweep logs and continues on errors (`ErrQuestionClosed` is not an error).
- [ ] **Step 4: Run** the same — PASS; `make lint-diff`. **Commit** `feat(spec-review): author questions from a thread — file, close, expire`.

---

### Task 9: `answer_review_question` tool, the question line, skill pack v20

**Depends on:** Task 8

**Files:**
- Create: `internal/tools/workbench_spec_review_question.go`, `internal/asks/testdata/spec_review_question_lines/*.json`
- Modify: `internal/tools/workbenches.go` (`WorkbenchTools`), `internal/tools/workbench_names_test.go`, `internal/tools/company_data.go`, `internal/asks/line.go`, `internal/devpack/workbenchskill/watchtower-workbench/SKILL.md` (pack v20) + `internal/devpack/testdata/watchtower-workbench-v19.md` snapshot per the devpack test convention
- Test: `internal/tools/workbench_spec_review_question_test.go`, `internal/asks/line_test.go`, `internal/devpack/workbench_test.go`

**Interfaces:**
- Produces: tool `answer_review_question` (a workbench write tool registered like `reply_review_comment`, surfaces `workbenchSurfaces`; it writes only the answer of the calling session's own question) with args `{question_id int64, answer string}`; refusals: unknown id or another workbench → not found; the question's ask session ≠ the calling terminal session (`terminalSessionOf`) → "this question is not for your session"; not open → "the question is closed"; empty or > 2000 runes → validation error. Result `{question_id, state: "answered"}`. `func SpecReviewQuestionLine(askID, questionID int64, question string) string` = `OneLine("Owner's thread on spec review ask #<askID> asks you: <question> — answer with answer_review_question <questionID>.")`.

- [ ] **Step 1: Write failing tests**: `TestAnswerReviewQuestion_WritesAnswer`, `_RefusesOtherSession`, `_RefusesClosed`, `_RefusesTooLong` (2001 runes); `TestCanonicalToolName_MapsTheRenamedWorkbenchTools` → `require.Len(t, names, 21)` with the comment extended ("plus answer_review_question since 2026-11-08: twenty-one"); `TestSpecReviewQuestionLine_Fixtures` over the new fixture dir (one case with a newline in the question → one line); devpack test expects `x-watchtower-pack: v20` and the skill text naming `answer_review_question` and the line's shape.
- [ ] **Step 2: Run** `go test ./internal/tools ./internal/asks ./internal/devpack` — FAIL.
- [ ] **Step 3: Implement**; mark the tool in `company_data.go` as not company data ("the owner's own review thread"). Skill text: when a line "Owner's thread on spec review ask #N asks you: …" arrives, answer only that question with `answer_review_question`, then carry on.
- [ ] **Step 4: Run** the same — PASS; `make lint-diff`. **Commit** `feat(spec-review): answer_review_question for the author, pack v20`.

---

### Task 10: `spec-review add-finding` and thread findings in `show --json`

**Depends on:** Task 3, Task 7, Task 8

**Files:**
- Modify: `internal/specreview/thread.go`, `internal/specreview/validate.go` (export a quote check reused, no second implementation), `cmd/workbench_spec_review_thread.go`, `cmd/workbench_spec_review.go` (`show`)
- Create: `internal/specreview/testdata/thread_blocks/*.json`
- Test: `internal/specreview/thread_test.go`, `cmd/workbench_spec_review_thread_test.go`, `cmd/workbench_spec_review_test.go`

**Interfaces:**
- Produces: `type ThreadFindingInput struct { Kind, Severity, Title, Text string; Quote ThreadQuote; Where *Anchor }` (JSON `kind`, `severity`, `title`, `text`, `quote`, `where`); `type ThreadQuote struct { Source, Text string }` (`source` = `document` | `thread`); `type ThreadFinding struct { Key, Kind, Severity, Title, Text, Chapter string; Quote ThreadQuote; Speaker string; Where *Anchor; Thread string }` (stored as the row's `finding` JSON); `func ValidateThreadFinding(in ThreadFindingInput, doc string, t DocType, ownerLines []string) (ThreadFinding, error)` — kind in `differs`/`missing`/`decided_alone`/`blind_spot`, severity via `normSeverity`, title/text through `field`, quote via `contains` on the document or any owner line (speaker `agent` / `owner`), where via `validator.anchor`; a bad quote → `ErrQuoteNotFound` (`"not added: quote not found"`); key `itemKey("tf:", text, whereQuote)`. CLI `watchtower workbench spec-review add-finding --ask N --thread CONTEXT_ID` (block JSON on stdin; prints `{"key": "tf:…"}`; exit 3 with the refusal text). `show --json` gains the pinned key `thread_findings` (array of stored findings, `[]` when none). `watchtower workbench spec-review thread-context --ask N --item K` (read-only database) prints the thread agent's first-turn context as fenced blocks: the document snapshot, the item (finding, ledger entry, thread finding or thesis) with its quotes, the whole stored result, the ledger and replies, and the `conversation` and `asks` blocks that `BuildInputs` builds for the reviewer (one implementation, in Go); unknown key → exit 3 "no such item".

- [ ] **Step 1: Write failing tests**: `TestValidateThreadFinding_DocumentQuote`, `_OwnerThreadQuote` (speaker `owner`), `_AgentWordsRefused` (a quote only in an assistant row → `ErrQuoteNotFound`), `_BadKind`, `_WhereChapter`; `TestThreadBlockFixtures_DecodeAndValidateShape` (each `testdata/thread_blocks/*.json` case `{reply, question, finding}` — `finding` decodes as `ThreadFindingInput`; the Swift parser test in Task 14 reads the same files); `TestAddFindingCmd_WritesRow`; `TestAddFindingCmd_RefusesForeignThread` (`--thread` of another workbench, or whose root is not this ask's chain root → exit 3 "this thread is not part of ask N's review") and `TestAddFindingCmd_RefusesInventedQuote` — Review Focus 5; `TestSpecReviewShowJSON_ThreadFindings` (pinned key list updated); `TestThreadContextCmd_Blocks` (document, item, result, conversation and asks blocks present; unknown key → exit 3).
- [ ] **Step 2: Run** `go test ./internal/specreview -run Thread` and `go test ./cmd -run 'AddFinding|SpecReviewShow'` — FAIL.
- [ ] **Step 3: Implement**; the command reads owner lines with `db.OwnerThreadLines(thread)` and the ask's `DocSnapshot`/`DocType`.
- [ ] **Step 4: Run** the same — PASS; `make lint-diff`. **Commit** `feat(spec-review): add a finding from a thread, quote-checked in Go`.

---

### Task 11: `ai query --purpose`

**Depends on:** none

**Files:**
- Modify: `cmd/ai.go`
- Test: `cmd/ai_purpose_test.go`

**Interfaces:**
- Produces: flag `--purpose` on `ai query`; allowed values `queryPurposes = map[string]bool{"spec_review.discuss": true}`; an unknown value exits 2 with "unknown --purpose"; a set value wraps the query context with `llmusage.WithPurpose`.

- [ ] **Step 1: Write failing tests**: `TestAIQueryPurpose_TagsContext` (the helper `queryContext(ctx, purpose) (context.Context, error)` returns a context whose `llmusage.PurposeFrom` is `spec_review.discuss`); `TestAIQueryPurpose_RefusesUnknown`.
- [ ] **Step 2: Run** `go test ./cmd -run AIQueryPurpose` — FAIL. **Step 3: Implement** in `runAIQuery` before `aiClient.Query`. **Step 4:** PASS, `make lint-diff`. **Step 5: Commit** `feat(ai): ai query --purpose for tagged embedded chats`.

---

### Task 12: Screens first — every new state on fixtures, then the owner's review

**Depends on:** none

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Models/SpecReviewThread.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Models/SpecReviewCardActions.swift`, `WatchtowerDesktop/Sources/Views/Workbench/Asks/SpecReview/SpecReviewThreadView.swift`, `WatchtowerDesktop/Sources/Views/Workbench/Asks/SpecReview/SpecReviewSummaryView.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/SpecReview.swift` (decode `brief`, `theses`), `WatchtowerDesktop/Sources/WatchtowerCore/Models/SpecReviewLoop.swift` (`endLine`), `WatchtowerDesktop/Sources/Views/Workbench/Asks/SpecReview/SpecReviewFindingCard.swift`, `SpecReviewLoopView.swift`, `SpecReviewMeaningView.swift`, `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+SpecReview.swift`, `DesignShotCatalog.swift`
- Test: `WatchtowerDesktop/Tests/Core/SpecReviewCardActionsTests.swift`, `WatchtowerDesktop/Tests/Core/SpecReviewTests.swift`

**Interfaces:**
- Produces (WatchtowerCore, pure): `SpecReviewResult.brief: String`, `SpecReviewResult.theses: [SpecReviewResult.Thesis]` (`key`, `kind`, `text`, `chapter`, `anchor` from `where`; missing keys decode as empty); `enum SpecReviewCardKind { case asAgreed, actionable, checkToVerify, thesis, dispute, fixedByAuthor, unanswered, fromDiscussion }`; `enum SpecReviewCardButton { case fix, skip, discuss, notUseful, checked, reviewerRight, authorRight, reopen }`; `enum SpecReviewCardActions { static func buttons(for kind: SpecReviewCardKind) -> [SpecReviewCardButton] }` implementing spec §2's table (as agreed → discuss, notUseful; actionable/fromDiscussion → fix, skip, discuss, notUseful; checkToVerify → discuss, checked; thesis → discuss; dispute → reviewerRight, authorRight, discuss; fixedByAuthor → reopen, discuss; unanswered → fix, skip, discuss); `struct SpecReviewQuestionRow` (`id`, `askID`, `thread`, `itemKey`, `question`, `answer`, `state: State` = `open|answered|expired|gone|unknown`); `struct SpecReviewProposedFinding` (Swift mirror of `ThreadFindingInput`) with `enum Status { case proposed, added(key: String), refused(String) }`; `SpecReviewLoop.endLine` gains `stalled` → `"The reviewer and the author stopped making progress: these are still open."` and `cap` → `"The reviewer and the author were still going after \(row.round) rounds."`.
- Produces (views, fed by fixtures only here): `SpecReviewSummaryView(brief:theses:onDiscuss:)` (theses grouped by kind, disclosure with the quoted passage and a **Read the spec** link); `SpecReviewThreadView` (thread rows, composer, "Asked the author…" pending, answered row, "The author did not answer", proposed-finding card with **Add to review** and its refused line, "thread · N" folded line); finding cards drawing their buttons from `SpecReviewCardActions`, **Skip**/**Checked** labels on the `ok` mark, **From discussion** chip.

- [ ] **Step 1: Write failing tests**: `SpecReviewCardActionsTests.testTableMatchesSpec` (each kind's exact button list above); `SpecReviewTests.testDecodesBriefAndTheses` and `testOldResultHasNoTheses`; `SpecReviewLoopTests.testEndLineStalledAndCapUsesRound` (round 8 → "after 8 rounds"). The fixture screens include a card with a picked Fix showing **Add Comment**, and a seeded loop screen with the owner's items marked fixed / still open.
- [ ] **Step 2: Run** `make test-swift FILTER='SpecReviewCardActionsTests|SpecReviewTests|SpecReviewLoopTests'` — FAIL.
- [ ] **Step 3: Implement** the Core types and the views from the DesignKit (`docs/design/desktop-style-guide.md`); add DesignShot catalog entries: summary, open thread, question pending / answered / expired, proposed finding valid / refused, the `stalled` and `cap` lines, the per-kind buttons (one card per kind), the folded "thread · N" line.
- [ ] **Step 4: Run** the tests — PASS; `make desktop-shots DESKTOP_SHOTS=build/desktop-shots/spec-review-discuss`; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(spec-review): screens for the summary, threads and per-kind buttons on fixtures`.
- [ ] **Step 6: Review ask to the owner** (`ask_owner`, kind `review`, the shot PNGs attached or listed, one check item per state). Tasks 13–15 wait for the answer; apply its comments to these views before they start.

---

### Task 13: Desktop reads — thread key twin, queries, per-kind buttons and round wording wired

**Depends on:** Task 1, Task 6, Task 8, Task 12 (owner's answer)

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/SpecReviewThreadQueries.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/SpecReviewThread.swift`, `WatchtowerDesktop/Sources/ViewModels/SpecReviewModel.swift`, `WatchtowerDesktop/Sources/Services/SpecReviewLoopCenter.swift`, `WatchtowerDesktop/Sources/Views/Workbench/Asks/OwnerAskStackSection.swift`, `SpecReviewFindingCard.swift`, `SpecReviewLoopView.swift`, `SpecReviewMeaningView.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Models/SpecReviewLoop.swift` (accept item kind `owner_comment`)
- Test: `WatchtowerDesktop/Tests/Core/SpecReviewThreadQueriesTests.swift`, `WatchtowerDesktop/Tests/SpecReviewModelTests.swift`, `WatchtowerDesktop/Tests/SpecReviewLoopCenterTests.swift`

**Interfaces:**
- Consumes: `internal/specreview/testdata/thread_keys.json` (Task 8); tables of Task 7.
- Produces: `enum SpecReviewThreadKey { static let contextType = "spec_review_thread"; static func contextID(workbenchID: Int64, rootAskID: Int64, itemKey: String) -> String }`; `SpecReviewThreadQueries.chainRoot(_ db: Database, askID: Int64) throws -> Int64` (recursive CTE, same depth cap 100 as Go); `.questions(_ db: Database, threads: [String]) throws -> [SpecReviewQuestionRow]`; `.threadFindings(_ db: Database, askID: Int64) throws -> [SpecReviewProposedFinding]`; `.messageCounts(_ db: Database, contextIDs: [String]) throws -> [String: Int]`; `SpecReviewModel.cardKind(for key: String) -> SpecReviewCardKind`, `SpecReviewModel.threadFindings`, `SpecReviewModel.rootAskID`; `SpecReviewLoopCenter.progressLine(round:)` → `"Spec review: round \(round)"` (the `maxRounds` constant removed); the stack row → `"ask #N · spec · round R"`.

- [ ] **Step 1: Write failing tests**: `testThreadKeyMatchesGoFixture` (reads `thread_keys.json` like `OwnerAskFixtures.files`); `testChainRootWalksPreviousAsks`; `testThreadFindingsDecode`; `SpecReviewModelTests.testCardKinds` (as agreed, differs, concern check, ok check, thread finding → `fromDiscussion`); `testSkipWritesOkMark`; `testPickedFixKeepsAddComment` (after Fix the card still offers today's **Add Comment** — `SpecReviewMarkComment` — for a one-line note without a thread); `testOwnerItemsShowFixedOrOpen` (in a loop seeded from the owner's Request changes, each `owner_comment` item shows "Your item — fixed by the author" when the ledger resolved it and "Your item — still open" otherwise); `SpecReviewLoopCenterTests.testProgressLineHasNoCap`.
- [ ] **Step 2: Run** `make test-swift FILTER='SpecReviewThreadQueriesTests|SpecReviewModelTests|SpecReviewLoopCenterTests'` — FAIL.
- [ ] **Step 3: Implement**; the owner's own items of a seeded loop render with the line above on the loop screen; thread findings appear in their chapter (or Other) by `chapter`; the summary leads the Meaning step; the end lines come from `SpecReviewLoop.endLine`.
- [ ] **Step 4: Run** — PASS; `make lint-diff`. **Commit** `feat(spec-review): Desktop reads threads, summary on Meaning, per-kind buttons, round R`.

---

### Task 14: The Discuss thread surface and its fenced blocks

**Depends on:** Task 10, Task 11, Task 13

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/ChatSurfaces/SpecReviewThreadSurface.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/SpecReviewThreadBlocks.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/Embedded/ChatSurfaceSpec.swift` (`ChatRunOptions.purpose`), `WatchtowerDesktop/Sources/WatchtowerCore/Services/WatchtowerAIService.swift` (`buildArgs(…, purpose:)`), `WatchtowerDesktop/Sources/WatchtowerCore/Services/LLMPurposeNames.swift`, `SpecReviewThreadView.swift`, `SpecReviewModel.swift`
- Test: `WatchtowerDesktop/Tests/Core/SpecReviewThreadBlocksTests.swift`, `WatchtowerDesktop/Tests/SpecReviewThreadSurfaceTests.swift`, `WatchtowerDesktop/Tests/Core/WatchtowerAIServiceTests.swift`

**Interfaces:**
- Consumes: `internal/specreview/testdata/thread_blocks/*.json` (Task 10), `ai query --purpose` (Task 11).
- Produces: fences ```` ```watchtower-ask-author ```` (`{"question": "…"}`) and ```` ```watchtower-finding ```` (`ThreadFindingInput` JSON); `enum SpecReviewThreadBlocks { static func parse(_ text: String, final: Bool) -> (text: String, question: String?, finding: SpecReviewProposedFinding?) }` (same rules as `ChatQuestionParser`: last valid block wins, open block hidden while streaming); `ChatRunOptions.purpose: String?` → `--purpose`; `enum SpecReviewThreadSurface { static func conversationID(workbenchID:rootAskID:itemKey:title:dbPool:) async throws -> Int64; static func spec(context: SpecReviewThreadContext, conversationID: Int64, dbPool: DatabasePool) -> ChatSurfaceSpec }` with `toolAccess: .draftOnly`, `ownerInstructions: true`, `runOptions` = configured provider, strong tier, `readFolder` = the session's recorded worktree when it is a directory else the workbench folder (nil on ollama, and the "cannot read files" notice once, as `CodeQuestionSurface`), `purpose: "spec_review.discuss"`; `willSend` false for an orphaned item (key not in the current result, ledger, thread findings or theses: "from the previous run", readable only); `WorkbenchCLI.specReviewThreadContext(askID:itemKey:) async throws -> String` (Task 10's `thread-context`), fetched once when a thread opens and held by the surface for the system prompt (a failed fetch shows the embedded chat's error card with Retry). System prompt per spec §3: it did not write the finding; explain, check against the document and code, say plainly when it does not hold; no write tools; the two block contracts. `LLMPurposeNames`: `("spec_review.discuss", "Spec review — Discuss")`.

- [ ] **Step 1: Write failing tests**: `testFixturesParseLikeGo` (every `thread_blocks` fixture: Swift `parse` gives the fixture's `question` and `finding`); `testStreamingHidesOpenBlock`; `SpecReviewThreadSurfaceTests.testDraftOnlyAndPurpose` (AGENT-04: `toolAccess == .draftOnly`; run options carry the purpose and the folder); `testOrphanRefusesNewTurns`; `WatchtowerAIServiceTests.testBuildArgsPurpose`.
- [ ] **Step 2: Run** `make test-swift FILTER='SpecReviewThreadBlocksTests|SpecReviewThreadSurfaceTests|WatchtowerAIServiceTests'` — FAIL.
- [ ] **Step 3: Implement**; `postTurn` strips the blocks from the displayed text and hands the question/finding to the model (`SpecReviewModel.threadReplied(key:question:finding:)`).
- [ ] **Step 4: Run** — PASS; `make lint-diff`. **Commit** `feat(spec-review): Discuss thread on findings and theses`.

---

### Task 15: Questions to the author, Add to review, Fix with a drafted conclusion

**Depends on:** Task 9, Task 14

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/SpecReviewThreadCenter.swift`
- Modify: `WatchtowerDesktop/Sources/Services/SessionLineDelivery.swift` (`LineKey.specReviewQuestion(Int64)`), `WatchtowerDesktop/Sources/Services/WorkbenchCLI.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/OwnerAskPrompt.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/SpecReviewAnswer.swift` (comments carry `itemKey`; thread findings marked Fix are sent like reviewer findings), `WatchtowerDesktop/Sources/WatchtowerCore/Models/OwnerAskAnswer*.swift` (`Comment.itemKey`, JSON `item_key`, omitted when nil), `WatchtowerDesktop/Sources/App/AppState.swift`, `SpecReviewModel.swift`, `SpecReviewThreadView.swift`
- Test: `WatchtowerDesktop/Tests/SpecReviewThreadCenterTests.swift`, `WatchtowerDesktop/Tests/Core/OwnerAskPromptTests.swift`, `WatchtowerDesktop/Tests/Core/SpecReviewAnswerTests.swift`, `WatchtowerDesktop/Tests/SpecReviewModelTests.swift`

**Interfaces:**
- Consumes: CLI verbs of Tasks 8 and 10; `asks.SpecReviewQuestionLine` fixtures (Task 9); `asks.Comment.ItemKey` (Task 4).
- Produces: `WorkbenchCLI.specReviewQuestion(askID:itemKey:question:) async throws -> Int64`, `.specReviewCloseQuestion(id:reason:) async throws`, `.specReviewAddFinding(askID:thread:block:) async throws -> String` (refusal text surfaced as the error message); `OwnerAskPrompt.specReviewQuestionLine(askID:questionID:question:)`; `@MainActor @Observable final class SpecReviewThreadCenter` (AppState-owned, app lifetime: delivers a filed question once through `SessionLineDelivery` with key `.specReviewQuestion(id)` — the same per-session queue as the loop's findings line, so when a newer hidden loop runs on the same session the lines arrive one at a time in filing order and neither interrupts a turn — `.noSession` closes it with `--reason gone` and the thread gets "The author's session has ended: the question was not sent"; polls `SpecReviewThreadQueries.questions` every 3 s only while some thread has an open question; on `answered` it calls `engine.sendFollowUp(prompt:notice:)` with notice `"The author answered (question #<id>): <answer>"`, on `expired`/`gone` notice `"The author did not answer"` and a follow-up telling the agent to continue without it; a follow-up already present as that system row is never sent twice, so a thread opened later picks up an answer that landed while the Desktop was closed); `SpecReviewModel.fix(key:)` with a thread: writes the `comment` mark at once, opens an empty comment field, `engine.sendHidden(conclusionPrompt)` and fills the field with the reply unless the owner typed meanwhile; after 30 s or on failure the field stays and shows "Couldn't draft a conclusion"; `SpecReviewModel.addToReview(_ finding:thread:)`.

- [ ] **Step 1: Write failing tests**: `OwnerAskPromptTests.testSpecReviewQuestionLineFixtures`; `SpecReviewThreadCenterTests.testDeliversOnceThroughLineDelivery`, `testHeldWhileOwnerTyping` (fake delivery returns `.held` → retried on the next poll, never pasted twice) — Review Focus 3; `testNoSessionClosesGone`; `testQuestionAndFindingsLineQueueInOrder` (a findings line and a thread question for the same session: delivered one after the other in filing order); `testAnswerStartsFollowUpOnce`; `testExpiredSaysAuthorDidNotAnswer`; `testAnswerLandedWhileClosedPickedUpOnOpen`; `SpecReviewModelTests.testFixPrefillDoesNotOverwriteTyping`, `testFixPrefillTimeoutShowsLine` (injected clock, 30 s), `testAddToReviewRefusalShownOnCard`; `SpecReviewAnswerTests.testCommentsCarryItemKey` and `testThreadFindingFixSent`.
- [ ] **Step 2: Run** `make test-swift FILTER='SpecReviewThreadCenterTests|OwnerAskPromptTests|SpecReviewModelTests|SpecReviewAnswerTests'` — FAIL.
- [ ] **Step 3: Implement**; one open question per thread is the Go guard — the Desktop shows Go's refusal text and does not file a second one.
- [ ] **Step 4: Run** — PASS; `make lint-diff`. **Commit** `feat(spec-review): ask the author from a thread, add findings, Fix with a drafted conclusion`.

---

### Task 16: Docs — feature note, inventory, guide, CLAUDE.md

**Depends on:** Task 4, Task 9, Task 10, Task 15

**Files:**
- Modify: `docs/features/spec-review.md` (new section "Open-ended loop, Discuss and the summary (2026-11-08)": everything in Tasks 1–15, v1 limits: no thread on the phone, follow-up turns need the Desktop, Go-only writes), `docs/inventory/spec-review.md`, `docs/inventory/dev-surface.md` (DEV-06: twenty-one tools), `docs/guide/features/workbench/spec-review.md` (per `docs/guide/WRITING.md`: Discuss, Skip/Checked, the summary, what "stopped making progress" means; a Learn card only if WRITING.md requires one for a new section), `CLAUDE.md` (Spec review line: open-ended loop, threads, summary, migrations 00174/00175, pack v20)

- [ ] **Step 1: Amend SPECREVIEW-04** Observable: the round cap becomes a fuse of 8 (`cap`; 3 for loops started before 2026-11-08, `loop_rules = 0`), new end `stalled`, the owner gets one ask per loop and a loop can follow the owner's Request changes; guards add `TestNextRound_FuseAt8`, `TestNextRound_NoFixHeldStalls`, `TestNextRound_LegacyRulesCapAt3`. **SPECREVIEW-05**: the explicit-`fixed` continue rule, the closed list, seeded owner items in a new loop; guards add `TestRun_SeededRound1VerdictsOwnerItems`, `TestReveal_SeededRoundFailedShowsOwnerItems`. Changelog entry citing the spec and ask #593: "no guard weakened". Write it as a proposal in the PR for the owner's approval (CLAUDE.md "Behavior Inventory").
- [ ] **Step 2: Check** `make lint-diff` (doc lints) and `go test ./internal/learn` if the guide gained a card.
- [ ] **Step 3: Commit** `docs(spec-review): open-ended loop, Discuss threads and the summary`.

---

### Task 17: Full gate

**Depends on:** Tasks 1–16

- [ ] **Step 1:** Regenerate after merging all lanes: `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`; commit if changed.
- [ ] **Step 2:** `make test > build/gate-go.log 2>&1; echo "exit=$?"` — expect `exit=0`.
- [ ] **Step 3:** `make test-swift > build/gate-swift.log 2>&1; echo "exit=$?"` — expect `exit=0` (XCTest failures appear above the swift-testing summary: grep the log for `error:`).
- [ ] **Step 4:** `make lint-all > build/gate-lint.log 2>&1; echo "exit=$?"` — expect `exit=0`.
- [ ] **Step 5:** Manual check ask to the owner: a spec loop that stalls, a Discuss thread that asks the author and gets an answer, an Add to review, Fix with a drafted conclusion, Request changes → hidden loop → one ask.
