# Diff Reviewer — Plan 2: Deep mode (phases, chapters, role checklists, pace)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A round can be switched from Quick to **Deep**: the owner goes through three phases — **Meaning** (intent card, design comments), **Chapters** (the diff in chapters of at most ~400 changed lines, each with role checklists built from built-in lenses plus the folder's `.watchtower/review.md`), **Wrap-up** (each intent item marked done / partial / not done, a summary of the round's comments by chapter, Send). Progress and active time are shown, a break hint appears after ~60 active minutes, and a review picks up where it stopped.

**Architecture:** Go owns the lenses: the built-in ones are embedded (`internal/reviewdiff/lenses.md`) and merged with the workbench folder's `.watchtower/review.md` (lstat-only, no symlinks, 64 KB); `workbench review context` returns them with the intent card. One new table, `review_checks` (migration 00124), written by Swift. The chapter split, pace and wrap-up grouping are pure WatchtowerCore code; `ReviewChangesModel` gains the Deep state and persists mode, phase, chapter and active seconds on the open round. The views add a phase strip, a chapter list, a checklist panel and a wrap-up view to the existing Changes pane.

**Tech Stack:** Go 1.26 (cobra, `database/sql` + modernc sqlite, goose, `embed`), SwiftUI + GRDB (WatchtowerCore).

**Spec:** `docs/superpowers/specs/2026-10-16-workbench-diff-reviewer-design.md` (approved, ask #179) — §5.1–5.4, §6.4, §15 phase 3. Plan 1 (`docs/superpowers/plans/2026-10-16-diff-reviewer-p1-core.md`, merged as PR #303) built the engine, rounds, Quick mode and delivery; feature note `docs/features/diff-reviewer.md`. Plan 3 = phases 4–5.

## What Plan 2 leaves to Plan 3

The AI overview (coverage, out-of-scope, risk, AI chapters and the lenses it marks relevant), agent notes and agent chapters (`annotate_changes`), Undo, Find repeats and the skill pack line about `.watchtower/review.md`. Plan 2 therefore uses, by design:

- **chapters:** the spec's mechanical fallback only (§5.2, "first found wins" — the agent's and the AI's sources plug in ahead of it in Plan 3); every chapter shows **all** lenses (the spec's rule for the mechanical fallback);
- **intent items** for Wrap-up: one per target linked to the session (the intent card's items, `target:<id>`); Plan 3 replaces them with the overview's coverage items when an overview exists.

## Global Constraints

- Every git call still goes through `internal/gitbin` (REVIEW-05); this plan adds **no** git call.
- Nothing in this plan writes a ref, the owner's index or a work-tree file (REVIEW-01). `.watchtower/review.md` is only read.
- `.watchtower/review.md` lives in the **workbench folder** (`projects.folder_path`), not the session worktree: one rules file per workbench, the file Plan 3's lessons write.
- The lens file is read only when `.watchtower` is a real directory (lstat) and `review.md` a regular file opened `O_NOFOLLOW|O_NONBLOCK`, re-checked with fstat (same inode); larger than **65,536 bytes** → not read. Any refusal → built-in lenses only, plus one note.
- Lens file grammar: a `## <name>` line names a lens (a built-in is matched by name case-insensitively and extended; any other name adds a lens after the built-ins, in file order); a `- <question>` line under a lens is a question; blank lines are ignored; any other line (text before the first heading included) is skipped and reported as `line N: not a "## lens" heading or a "- question"`.
- Built-in lenses, in this order, ids and names: `correctness` Correctness, `tests` Tests, `security` Security, `simplicity` Simplicity, `house_rules` House rules (no built-in questions). A lens id is its name lowercased with every run of non `[a-z0-9]` characters replaced by `_`, trimmed of `_`. Comments store the lens **id** in `review_comments.lens`; `intent` is the Wrap-up lens id.
- Item key = the first 16 hex characters of sha256 of the question text after trimming spaces. A duplicate question in one lens is kept once.
- Chapter cap: **400** changed lines (additions + deletions); the break hint at **3,600** active seconds; idle after **120** s without interaction. These live in one place on each side: `internal/reviewdiff/limits.go` is unchanged (no Go use); Swift `ReviewPace.Limits`.
- Phases stored in `review_rounds.phase`: `meaning`, `chapters`, `wrapup` (`''` reads as `meaning`). Mode `quick|deep`, already in the schema.
- Swift writes `mode`, `phase`, `chapter_key`, `active_seconds` only with `WHERE id = ? AND status = 'open'`; a sent round is read-only.
- A new round inherits the previous sent round's `mode` (Go, at create).
- `review_checks.state` ∈ `checked` (a checklist item ticked), `commented` (turned into a comment), `done`, `partial`, `not_done` (Wrap-up marks). Unticking deletes the row.
- Swift: house conventions of `docs/review/review-rules.md` "Swift / Desktop conventions"; `make lint-swift` in every Swift task (lint-diff is Go-only).
- Docs English; the board in the session language; public repo hygiene (temp dirs and `example.com` only).
- Task scope checks only; the full gate once by the controller after Task 7.

## Review Focus

1. **One file with 1,000 changed lines, and a directory with 30 small changed files** — the big file is one chapter of its own (never cut mid-file), the directory splits into parts of at most 400 lines each, a test and its subject stay in one part (Task 4).
2. **`.watchtower/review.md` that is a symlink, a FIFO, in a symlinked `.watchtower`, over 64 KB, or not UTF-8** — the review still opens with the built-in lenses and one note; nothing hangs (Task 1).
3. **`## tests` (other case) or `## House Rules` in the folder file** — extends the built-in lens, no duplicate lens appears (Task 1).
4. **Refresh in Deep mode removes the files of the current chapter** — the model falls back to the first chapter; the old chapter's checks stay stored but are not shown (Task 5).
5. **The app quits mid-review** — mode, phase, chapter are on the round and active seconds at most 30 s behind; reopening resumes there (Task 5).

---

## Dependencies and parallel lanes

| Task | Depends on |
|---|---|
| 1 Go lenses | none |
| 2 Go migration, context envelope, round fields, mode inherit, get_review lens | Task 1 |
| 3 Swift core data (models, queries) | Task 2 (schema + envelope) |
| 4 Swift core logic (chapters, pace, wrap-up) | none |
| 5 ReviewChangesModel Deep state | Tasks 3, 4 |
| 6 Views | Task 5 |
| 7 Docs | Tasks 1–6 |

- **Wave 1 (parallel):** Lane G = Task 1 → 2; Lane C = Task 4 (Core only, light build).
- **Wave 2:** Lane S = Task 3 → 5 → 6 (one Swift lane), after merging G and C.
- **Wave 3:** Task 7, then the phase gate.

Each lane in its own worktree off `feature/328-diff-reviewer-p2`; the controller merges.

---

## File Structure

**Go**
- Create `internal/reviewdiff/lenses.md` (built-ins), `internal/reviewdiff/lenses.go` (`ParseLenses`, `LoadLenses`, `ItemKey`, `LensID`), `internal/reviewdiff/lenses_test.go`.
- Create `internal/db/migrations/00124_review_checks.sql`; modify `internal/db/schema.sql`, `internal/db/db_test.go` (`TestAllTablesExist`), golden snapshot + `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (regenerated).
- Modify `cmd/workbench_review.go` (round JSON fields, mode inherit), `cmd/workbench_review_context.go` (lenses), `cmd/workbench_review_test.go`.
- Modify `internal/tools/workbench_review.go` (lens in the text) + its test.

**Swift (WatchtowerDesktop/Sources)**
- Modify `WatchtowerCore/Models/ReviewModels.swift` (`ReviewLens`, envelope + round fields, `ReviewCheck`).
- Modify `WatchtowerCore/Database/Queries/ReviewQueries.swift` (checks, round state, `addDraft` lens).
- Create `WatchtowerCore/Services/Review/ReviewChapters.swift`, `ReviewPace.swift`, `ReviewWrapUp.swift`.
- Modify `ViewModels/ReviewChangesModel.swift`.
- Create `Views/Workbench/Review/ReviewPhaseStrip.swift`, `ReviewMeaningView.swift`, `ReviewChapterListView.swift`, `ReviewChecklistView.swift`, `ReviewWrapUpView.swift`; modify `ReviewChangesPaneView.swift`, `ReviewChangesHeader.swift`.

**Tests:** `Tests/Core/ReviewChaptersTests.swift`, `ReviewPaceTests.swift`, `ReviewWrapUpTests.swift`, `ReviewQueriesTests.swift` (extend), `Tests/ReviewChangesModelTests.swift` (extend).

**Docs:** `docs/features/diff-reviewer.md`, `CLAUDE.md` (feature line), spec status line.

---

### Task 1: Go — lenses (built-in + `.watchtower/review.md`)

**Depends on:** none

**Files:**
- Create: `internal/reviewdiff/lenses.md`, `internal/reviewdiff/lenses.go`, `internal/reviewdiff/lenses_test.go`

**Interfaces:**
- Produces:
  - `type LensItem struct { Key string \`json:"key"\`; Text string \`json:"text"\` }`
  - `type Lens struct { ID string \`json:"id"\`; Name string \`json:"name"\`; Builtin bool \`json:"builtin"\`; Items []LensItem \`json:"items"\` }`
  - `func LensID(name string) string`
  - `func ItemKey(question string) string`
  - `func ParseLenses(folderFile []byte) (lenses []Lens, notes []string)` — built-ins merged with the file (nil = built-ins only)
  - `func LoadLenses(workbenchFolder string) (lenses []Lens, notes []string)` — reads `<folder>/.watchtower/review.md` under the Global Constraints rules; a missing file is no note
  - `const MaxLensFileBytes = 65536` (in `lenses.go`)

- [ ] **Step 1: Write `lenses.md`** (embedded with `//go:embed lenses.md`, parsed by the same grammar — exact copy):

```markdown
## Correctness
- Does the change do what the intent asks, including its edge cases?
- What happens on empty, missing or malformed input?
- Are errors handled, or returned with enough context to act on?
- Can two runs, two processes or a retry interleave badly here?
- Does anything that used to work now behave differently?
## Tests
- Does every new branch of behaviour have a test that fails without it?
- Do the tests check results, not only that the code ran?
- Are the failure and edge paths tested, not just the happy path?
- Would a test still pass if the change were reverted?
## Security
- Is input from files, the network or another process validated before use?
- Can a path, command or query be steered by untrusted text?
- Are secrets kept out of logs, errors and the repository?
- Does the change widen what runs without the owner's approval?
## Simplicity
- Is there code here that nothing needs yet?
- Could a smaller change do the same job?
- Does it reuse what the codebase already has instead of a copy?
- Will the next reader understand it without the author?
## House rules
```

- [ ] **Step 2: Write the failing tests** in `lenses_test.go`:
  - `TestParseLenses_BuiltinsOnly`: `ParseLenses(nil)` → 5 lenses with ids `correctness,tests,security,simplicity,house_rules`, all `Builtin`, item counts `5,4,4,4,0`, notes empty; `Items[0].Key == ItemKey("Does the change do what the intent asks, including its edge cases?")` and is 16 hex chars.
  - `TestParseLenses_ExtendsCaseInsensitivelyAndAddsNew`: file `"## tests\n- Is there a fuzz test?\n## House Rules\n- Git runs only in Go.\n## Docs\n- Is the feature note updated?\n"` → still one `tests` lens with 5 items, the last `Is there a fuzz test?`; `house_rules` has 1 item; a 6th lens `{ID:"docs", Name:"Docs", Builtin:false}` after the built-ins; notes empty.
  - `TestParseLenses_SkipsAndReportsBadLines`: `"intro\n## Tests\n- a\n* b\n\n- a\n"` → notes `["line 1: not a \"## lens\" heading or a \"- question\"", "line 4: not a \"## lens\" heading or a \"- question\""]`; `tests` gains exactly one item `a` (duplicate dropped); an empty `- ` bullet is skipped with a note too.
  - `TestLensID`: `"House rules" → "house_rules"`, `"  API / CLI  " → "api_cli"`, `"Тесты" → ""`; a heading whose id is empty is skipped with the note `line N: lens name has no latin letters or digits`.
  - `TestLoadLenses_RefusesUnsafeFiles` (table, each in `t.TempDir()`): no `.watchtower` → built-ins, no note; `review.md` a symlink to a real file → built-ins + note containing `not a regular file`; `.watchtower` a symlink to a dir holding `review.md` → built-ins + note; `review.md` a FIFO (`syscall.Mkfifo`) → returns (test with a 2 s timeout) built-ins + note; 65,537 bytes → note containing `larger than 64 KB`; invalid UTF-8 → note containing `not UTF-8`; a valid file → merged, no note.

- [ ] **Step 3: Run** `go test ./internal/reviewdiff -run 'Lens'` — expect FAIL (undefined).

- [ ] **Step 4: Implement** in `lenses.go`. `LoadLenses` notes are prefixed `.watchtower/review.md: ` and the reader follows `readRecipeFile` in `internal/automations/indexer.go` (lstat, `O_NOFOLLOW|O_NONBLOCK`, fstat + `os.SameFile`, `io.LimitReader(f, MaxLensFileBytes+1)`) — a private copy, the indexer's helper is not exported and carries hashing this read does not need.

- [ ] **Step 5: Run** `go test ./internal/reviewdiff && make lint-diff` — PASS, no new issues.

- [ ] **Step 6: Commit** `feat(review): built-in lenses and .watchtower/review.md (board #328)`.

---

### Task 2: Go — `review_checks`, context lenses, round fields, mode inherit, lens in `get_review`

**Depends on:** Task 1

**Files:**
- Create: `internal/db/migrations/00124_review_checks.sql`
- Modify: `internal/db/schema.sql`, `internal/db/db_test.go`, schema golden + `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (regenerated), `cmd/workbench_review.go`, `cmd/workbench_review_context.go`, `cmd/workbench_review_test.go`, `internal/tools/workbench_review.go` (+ its test)

**Interfaces:**
- Consumes: Task 1 `LoadLenses`, `Lens`.
- Produces:
  - table `review_checks(round_id INTEGER NOT NULL REFERENCES review_rounds(id) ON DELETE CASCADE, chapter_key TEXT NOT NULL, lens TEXT NOT NULL, item_key TEXT NOT NULL, state TEXT NOT NULL CHECK (state IN ('checked','commented','done','partial','not_done')), updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')), PRIMARY KEY (round_id, chapter_key, lens, item_key))`
  - `review context` envelope gains `lenses: [Lens]` (always present when `ok`) and `lens_notes: [string]` (omitted when empty).
  - `reviewRoundJSON` gains `phase` (string), `chapter_key` (string), `active_seconds` (int).
  - A round created after a sent round carries that round's `mode`.
  - `get_review` text: a comment with a lens reads `#<id> <where> [<lens>]`.

- [ ] **Step 1: Migration + schema** — use the `add-migration` skill: the file above with a `-- +goose Down` `DROP TABLE review_checks;`; mirror into `schema.sql`; add `review_checks` to `TestAllTablesExist`; regenerate with `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`.

- [ ] **Step 2: Write the failing tests** in `cmd/workbench_review_test.go` (reuse the file's temp-repo helpers):
  - `TestWorkbenchReviewContext_ReturnsLenses`: workbench folder with `.watchtower/review.md` = `"## Tests\n- Extra?\nbad\n"` → envelope `lenses` has 5 entries, `tests` ends with `Extra?`, `lens_notes == [".watchtower/review.md: line 3: not a \"## lens\" heading or a \"- question\""]`; with no file → 5 built-ins, no `lens_notes` key in the JSON.
  - `TestWorkbenchReviewStart_InheritsModeFromLastSentRound`: start, set the round's `mode='deep'` by SQL, send, change a file, start → the new round JSON has `"mode":"deep"`; a first round is `quick`.
  - `TestWorkbenchReviewStart_ReportsDeepState`: set `phase='chapters', chapter_key='dir:cmd', active_seconds=90` by SQL → `start` (reuse) JSON carries the three fields.
- [ ] **Step 3:** in `internal/tools/workbench_review_test.go`, `TestGetReview_TextShowsLens`: a sent comment with `lens='tests'` on `a.go:3-4` renders `#<id> a.go:3-4 [tests]`; a design comment with `lens='intent'` renders `#<id> design [intent]`; no lens → no brackets (existing expectations unchanged).
- [ ] **Step 4: Run** `go test ./cmd -run 'WorkbenchReview' && go test ./internal/tools -run GetReview` — FAIL.
- [ ] **Step 5: Implement.** `runWorkbenchReviewContext` calls `reviewdiff.LoadLenses(p.FolderPath)`; `createReviewRound` sets `r.Mode = last.Mode` from the `LastSentReviewRound` it already reads (and `db.CreateReviewRound` inserts `mode` — add the column to its INSERT if it is not there, default `quick` when empty); `roundJSON` copies the three fields from `db.ReviewRound` (add `Phase`, `ChapterKey`, `ActiveSeconds` to the struct and `scanReviewRound` if missing); `reviewText` appends ` [lens]`.
- [ ] **Step 6: Run** the Step 4 commands, `go test ./internal/db`, `make lint-diff` — PASS.
- [ ] **Step 7: Commit** `feat(review): review_checks, lenses in the context, deep round state (board #328)`.

---

### Task 3: Swift core — models and queries for Deep mode

**Depends on:** Task 2

**Files:**
- Modify: `WatchtowerCore/Models/ReviewModels.swift`, `WatchtowerCore/Database/Queries/ReviewQueries.swift`
- Test: `Tests/Core/ReviewQueriesTests.swift`, the envelope decode test next to the existing `ReviewEnvelope` tests

**Interfaces:**
- Produces:
  - `package struct ReviewLens: Decodable, Equatable, Sendable, Identifiable { id: String; name: String; builtin: Bool; items: [Item] }`, `package struct Item: Decodable, Equatable, Sendable { key: String; text: String }`
  - `ReviewEnvelope` gains `lenses: [ReviewLens]?`, `lensNotes: [String]?`; `ReviewRoundInfo` gains `phase: String`, `chapterKey: String`, `activeSeconds: Int` (decode defaults `""`, `""`, `0` when absent).
  - `package enum ReviewPhase: String, Sendable, CaseIterable { case meaning, chapters, wrapup; init(stored: String) }` (`""` and unknown → `.meaning`)
  - `package struct ReviewCheck: FetchableRecord, Decodable, Equatable, Sendable { chapterKey: String; lens: String; itemKey: String; state: State }`, `package enum State: String { case checked, commented, done, partial, notDone = "not_done" }`
  - `ReviewQueries.checks(_ db: Database, roundID: Int64) throws -> [ReviewCheck]`
  - `ReviewQueries.setCheck(_ db: Database, roundID: Int64, chapterKey: String, lens: String, itemKey: String, state: ReviewCheck.State?) throws` — nil deletes; refuses (no-op, returns) on a round that is not `open`
  - `ReviewQueries.saveRoundState(_ db: Database, roundID: Int64, mode: String, phase: ReviewPhase, chapterKey: String, activeSeconds: Int) throws -> Bool` — `UPDATE … WHERE id = ? AND status = 'open'`; returns whether a row changed
  - `ReviewQueries.addDraft` gains `lens: String = ""` (written to `review_comments.lens`); `path: nil` keeps meaning a design comment.

- [ ] **Step 1: Failing tests** (`ReviewQueriesTests`):
  - `testSetCheckUpsertsAndDeletes`: set `checked`, then `commented` on the same key → one row, `commented`; set nil → no row.
  - `testSetCheckAndRoundStateRefusedOnSentRound`: a `sent` round → `setCheck` writes nothing; `saveRoundState` returns false and the row is unchanged.
  - `testSaveRoundStatePersists`: open round → returns true; row has `mode='deep'`, `phase='wrapup'`, `chapter_key='dir:cmd'`, `active_seconds=125`.
  - `testAddDraftDesignCommentWithLens`: `path: nil, lens: "intent"` → row with NULL path and lens `intent`.
  - Decode: an envelope JSON with `lenses` and `lens_notes` decodes; a round JSON without the three new keys decodes with the defaults; `ReviewPhase(stored: "")` and `(stored: "x")` are `.meaning`.
- [ ] **Step 2: Run** `make test-swift FILTER='ReviewQueriesTests|ReviewModels'` — FAIL.
- [ ] **Step 3: Implement** the Interfaces block.
- [ ] **Step 4: Run** the Step 2 command and `make lint-swift` — PASS.
- [ ] **Step 5: Commit** `feat(review): Swift core models and queries for deep mode (board #328)`.

---

### Task 4: Swift core — chapters, pace, wrap-up (pure)

**Depends on:** none (uses Plan 1's `ReviewDiffFile` and `ReviewComment` only)

**Files:**
- Create: `WatchtowerCore/Services/Review/ReviewChapters.swift`, `ReviewPace.swift`, `ReviewWrapUp.swift`
- Test: `Tests/Core/ReviewChaptersTests.swift`, `ReviewPaceTests.swift`, `ReviewWrapUpTests.swift`

**Interfaces:**
- Produces:
  - `package struct ReviewChapter: Equatable, Sendable, Identifiable { let key: String; let title: String; let paths: [String]; let changedLines: Int; let core: Bool; var id: String { key } }`
  - `package enum ReviewChapters { static let maxChangedLines = 400; static func mechanical(_ files: [ReviewDiffFile]) -> [ReviewChapter]; static func isTest(_ path: String) -> Bool; static func done(_ chapter: ReviewChapter, isViewed: (String) -> Bool) -> Bool }`
  - `package struct ReviewPace: Equatable, Sendable { enum Limits { static let idleSeconds = 120.0; static let tickCap = 15.0; static let breakHintSeconds = 3600 }; private(set) var activeSeconds: Int; init(activeSeconds: Int); mutating func noteInteraction(at: Date); mutating func tick(at: Date, isKey: Bool); var breakHintDue: Bool }`
  - `package struct ReviewProgress: Equatable, Sendable { let viewedLines: Int; let totalLines: Int; let chaptersDone: Int; let chapterCount: Int }` and `ReviewProgress.make(files: [ReviewDiffFile], chapters: [ReviewChapter], isViewed: (String) -> Bool) -> ReviewProgress`
  - `package struct ReviewIntentItem: Equatable, Sendable, Identifiable { let key: String; let text: String; var id: String { key } }`
  - `package enum ReviewWrapUp { static func intentItems(_ context: [ReviewContextItem]) -> [ReviewIntentItem]; static func commentsByChapter(_ comments: [ReviewComment], chapters: [ReviewChapter]) -> [(title: String, comments: [ReviewComment])]; static func intentCommentBody(partial: Bool, item: ReviewIntentItem, note: String) -> String }` — `partial: Bool`, not `ReviewCheck.State`, because Task 4 runs before Task 3 (Wave 1); Task 5 maps `.partial`/`.notDone` to it.

- [ ] **Step 1: Failing tests — chapters** (`ReviewChaptersTests`, files built with a small helper `file(_ path:, add:, del:, collapsed:)`):
  - `testGroupsByDirectoryInPathOrder`: `cmd/a.go`(10), `internal/x/b.go`(10), `cmd/c.go`(10) → 2 chapters, keys `dir:cmd`, `dir:internal/x`, titles `cmd`, `internal/x`; a root file gets key `dir:` and title `(root)`.
  - `testTestJoinsItsSubjectAndComesFirst`: `internal/x/b.go`, `internal/x/b_test.go`, `WatchtowerDesktop/Sources/M/Foo.swift`, `WatchtowerDesktop/Tests/FooTests.swift` → the Swift test sits in `Foo.swift`'s chapter before it; `b_test.go` before `b.go`.
  - `testTestWithTwoPossibleSubjectsStaysInItsDirectory`: `a/Foo.swift`, `b/Foo.swift`, `Tests/FooTests.swift` → the test stays in `dir:Tests`.
  - `testSplitsOverCapAndKeepsBigFileWhole`: 30 files of 20 lines in `pkg/` → parts `dir:pkg`, `dir:pkg#2`, … each ≤ 400 lines, titles `pkg`, `pkg (2)`; one file of 1,000 lines → its own chapter of 1,000; a test + subject unit of 300 + 200 stays in one part (500).
  - `testCollapsedFilesGoLast`: a lockfile and a generated file → last chapter key `collapsed`, title `Generated and lock files`, `changedLines` 0.
  - `testIsTest`: true for `x_test.go`, `FooTests.swift`, `FooTest.kt`, `a.test.ts`, `a.spec.js`, `test_a.py`, `Tests/Support/Helper.swift` (path segment `Tests`/`tests`/`__tests__`); false for `contest.go`, `attestation.swift`.
  - `testDoneWhenEveryFileViewed`.
  - Mechanical chapters have `core == false`.
- [ ] **Step 2: Failing tests — pace and progress** (`ReviewPaceTests`, dates from a fixed `t0`):
  - `testCountsOnlyKeyAndRecentlyActiveTime`: interaction at t0, ticks every 10 s to t0+100 while key → 100 s; ticks at t0+130 … t0+200 → no growth (idle > 120 s after the last interaction); `isKey: false` ticks never add.
  - `testCapsOneTickGap`: interaction at t0, tick at t0+5, then tick at t0+65 (a sleeping Mac) → +5, +15 = 20.
  - `testBreakHintAt3600`: `init(activeSeconds: 3599)` → false; one 1 s active tick → true.
  - `testProgressCountsViewedLinesAndDoneChapters`.
- [ ] **Step 3: Failing tests — wrap-up** (`ReviewWrapUpTests`):
  - `testIntentItemsOnePerLinkedTarget`: two context items → keys `target:12`, `target:15`, texts the targets' texts.
  - `testCommentsGroupedByChapterInChapterOrder`: line comments land in their path's chapter; a design comment (nil path) and a comment on a path in no chapter go to a last group `General`; groups with no comments are left out; resolved comments are left out.
  - `testIntentCommentBody`: `partial: false, text "Add X", note ""` → `Not done: Add X`; `partial: true, note "tests missing"` → `Partly done: Add X — tests missing`.
- [ ] **Step 4: Run** `make test-swift FILTER='ReviewChaptersTests|ReviewPaceTests|ReviewWrapUpTests'` — FAIL.
- [ ] **Step 5: Implement.** Chapters: subject stem = basename without extension, stripped of `_test`, `Tests`, `Test`, `.test`, `.spec`, a leading `test_`; a test with exactly one changed non-test file of that stem joins it as a unit; units sorted by path (tests first inside a unit); pack units greedily in order into parts ≤ 400 lines; a unit over the cap is a part of its own. Pace: `tick` adds `min(now − lastTick, tickCap)` when `isKey` and `now − lastInteraction ≤ idleSeconds`, then sets `lastTick = now`; the first tick only sets `lastTick`.
- [ ] **Step 6: Run** the Step 4 command and `make lint-swift` — PASS.
- [ ] **Step 7: Commit** `feat(review): mechanical chapters, pace and wrap-up logic (board #328)`.

---

### Task 5: `ReviewChangesModel` — Deep state

**Depends on:** Tasks 3, 4

**Files:**
- Modify: `ViewModels/ReviewChangesModel.swift`
- Test: `Tests/ReviewChangesModelTests.swift` (reuse its fake CLI and line sink)

**Interfaces:**
- Consumes: Task 3 queries/models, Task 4 `ReviewChapters`, `ReviewPace`, `ReviewProgress`, `ReviewWrapUp`.
- Produces (all `private(set)` unless noted):
  - `mode: Mode` (`enum Mode: String { case quick, deep }`), `phase: ReviewPhase`, `chapters: [ReviewChapter]`, `currentChapterKey: String?`, `lenses: [ReviewLens]`, `lensNotes: [String]`, `checks: [ReviewCheck]`, `intentItems: [ReviewIntentItem]`, `pace: ReviewPace`, `progress: ReviewProgress`, `breakHintDismissed: Bool` (settable)
  - `func setMode(_ m: Mode) throws`, `func setPhase(_ p: ReviewPhase) throws`, `func selectChapter(_ key: String) async throws` (also selects the chapter's first non-collapsed file)
  - `func setCheck(chapterKey: String, lens: String, itemKey: String, checked: Bool) throws`
  - `func checks(forChapter key: String) -> [ReviewCheck]`
  - `func commentOnCheck(chapterKey: String, lens: String, item: ReviewLens.Item, body: String) throws` — a design comment (nil path) with that lens, body as written, and the check stored `commented`
  - `func addDesignComment(body: String, lens: String) throws`
  - `addComment(path:side:startLine:endLine:body:)` gains `lens: String = ""`
  - `func markIntent(_ item: ReviewIntentItem, state: ReviewCheck.State, note: String) throws` — stored under chapter `wrapup`, lens `intent`; `partial`/`notDone` also add a design comment with lens `intent` and `ReviewWrapUp.intentCommentBody`; `done` adds none
  - `func noteInteraction(at: Date = .now)`, `func tick(at: Date = .now, isKey: Bool)` — persists through `saveRoundState` when the unsaved active time reaches 30 s; `func flushState()` persists now (called on disappear and before Send)

- [ ] **Step 1: Failing tests:**
  - `testOpenRestoresDeepState`: the fake `start` answers a round with `mode deep, phase chapters, chapter_key dir:cmd, active_seconds 90` → `mode == .deep`, `phase == .chapters`, `currentChapterKey == "dir:cmd"`, `pace.activeSeconds == 90`; `lenses` from the fake `context` answer.
  - `testModeAndPhasePersistOnOpenRound`: `setMode(.deep)`, `setPhase(.wrapup)` → the DB row has both; on a sent round both throw `ModelError.roundClosed` (add the case; message `This round was already sent, so it cannot change.`) and nothing is written.
  - `testRefreshDropsVanishedChapter`: current chapter `dir:old`; refresh returns a diff without `old/` → `currentChapterKey` is the first chapter's key; the `dir:old` check row is still in the DB; `checks(forChapter:)` of every visible chapter leaves it out.
  - `testCommentOnCheckWritesLensCommentAndMarksCheck`.
  - `testMarkIntentNotDoneAddsIntentComment` and `testMarkIntentDoneAddsNoComment`.
  - `testActiveTimePersistsEvery30Seconds`: interaction + ticks to 29 s → row still 0; to 30 s → row 30; `flushState()` at 41 s → 41.
  - `testSendFlushesState`: active 12 s unsaved, `send()` → the row has 12 before the fake `send` is called (the fake records the DB value it saw).
- [ ] **Step 2: Run** `make test-swift FILTER=ReviewChangesModelTests` — FAIL.
- [ ] **Step 3: Implement.** Chapters are recomputed from `files` (the current view) after every diff load; `progress` from all chapters and `isViewed`; `intentItems` from `context`. `open()` already calls `context` — take `lenses`/`lensNotes` from that envelope.
- [ ] **Step 4: Run** the Step 2 command and `make lint-swift` — PASS.
- [ ] **Step 5: Commit** `feat(review): deep mode state in ReviewChangesModel (board #328)`.

---

### Task 6: Views — mode switch, phases, chapters, checklists, wrap-up, pace

**Depends on:** Task 5

**Files:**
- Create: `Views/Workbench/Review/ReviewPhaseStrip.swift`, `ReviewMeaningView.swift`, `ReviewChapterListView.swift`, `ReviewChecklistView.swift`, `ReviewWrapUpView.swift`
- Modify: `ReviewChangesPaneView.swift`, `ReviewChangesHeader.swift`

**Interfaces:** Consumes Task 5's model API; produces views only.

- [ ] **Step 1: Header.** A `Picker` `Quick | Deep` (segmented) → `model.setMode`; in Deep a progress line `<viewed>/<total> lines · <done>/<count> chapters · <h:mm> active`; when `pace.breakHintDue && !breakHintDismissed` a `ReviewBanner` "You have reviewed for an hour — a short break helps you catch more." with a close button setting `breakHintDismissed`.
- [ ] **Step 2: Phase strip** (Deep only, under the header): three steps `1 Meaning · 2 Chapters · 3 Wrap-up`, current highlighted, each clickable → `setPhase`; `Next` button on the right (Wrap-up shows `Send` instead, the same action as the header's Send).
- [ ] **Step 3: Meaning** (replaces the split view in phase `meaning`): the intent card — each context item with its text, intent, plan task text (monospace, collapsible) and `missing` shown as "plan file not found" / "task not found in the plan"; "No targets are linked to this session" when empty; the list of design comments (path nil) with add/edit/delete — add opens the existing comment sheet with no file, and a lens picker.
- [ ] **Step 4: Chapters** (phase `chapters`): the left column is `ReviewChapterListView` — chapters with title, `changedLines`, a check mark when `ReviewChapters.done`, expanding to their files (the existing file row, Viewed box, comment count); the right column is the diff as today with `ReviewChecklistView` as a collapsible panel under it: every lens of `model.lenses` with its items, a checkbox (`setCheck`) and a `Comment…` button (`commentOnCheck`, sheet prefilled with the question); lens notes at the top in secondary text. Lenses with no items are hidden.
- [ ] **Step 5: Wrap-up** (phase `wrapup`): each intent item with a three-way control `Done / Partly / Not done` (`markIntent`; Partly/Not done open a sheet for the note); then `ReviewWrapUp.commentsByChapter` as a read-only list (chapter title, each comment's place, lens tag, body); then `Send`.
- [ ] **Step 6: Quick mode** stays exactly as Plan 1 (no strip, no checklists). The line comment sheet gets an optional lens picker (`None` + `model.lenses`) in Deep mode only.
- [ ] **Step 7: Pace wiring.** A 15 s `Timer` while the pane is on screen calls `model.tick(isKey: window?.isKeyWindow ?? false)`; an `NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .scrollWheel])` scoped to the pane's window calls `noteInteraction()`; both removed in `onDisappear`, which also calls `flushState()`.
- [ ] **Step 8: Run** `make test-swift FILTER='ReviewChangesModelTests|ReviewChaptersTests'` (nothing broke) and `make lint-swift`; build and open the app (`run` skill), put a session's round in Deep, step through the three phases, tick a check, mark an intent item Partly, and check the comment appears in Wrap-up; screenshot each phase for the controller.
- [ ] **Step 9: Commit** `feat(review): deep mode views (board #328)`.

---

### Task 7: Docs

**Depends on:** Tasks 1–6

**Files:** Modify `docs/features/diff-reviewer.md`, `CLAUDE.md`, the spec's status line.

- [ ] **Step 1:** Feature note: title `(2026-10-16, Plans 1–2 of 3)`; a "What Plan 2 ships" section — lenses (built-ins, the folder file, its grammar and read rules, notes), `review_checks` and its states, the context envelope's `lenses`/`lens_notes`, the round's `phase`/`chapter_key`/`active_seconds` and mode inheritance, mechanical chapters (directory groups, test pairing, 400-line parts, collapsed last), pace (active time rule, 30 s persistence, break hint), Wrap-up intent items (one per linked target) and the `intent` lens, `get_review`'s `[lens]` tag; v1 limits updated (Deep mode uses mechanical chapters and all lenses until Plan 3's overview; intent items are linked targets only).
- [ ] **Step 2:** `CLAUDE.md` feature line: `(2026-10-16, Plans 1–2 of 3)`, add `Deep mode (phases, mechanical chapters, lenses + .watchtower/review.md, migration 00124 review_checks, pace)`.
- [ ] **Step 3:** Commit `docs(review): deep mode feature note (board #328)`.

---

## Phase gate (controller, once, after Task 7)

`make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`; then a manual check by the owner (an ask with a checklist): switch a round to Deep, read the intent card, write a design comment, go through two chapters ticking checks and turning one into a comment, add a question to `.watchtower/review.md` and see it after Refresh, mark one intent item Partly in Wrap-up, Send, see the agent's `get_review` show the `[tests]` / `[intent]` tags, reopen the app mid-review and land on the same phase and chapter.
