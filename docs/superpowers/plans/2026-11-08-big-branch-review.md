# Reviewing a big branch — Implementation Plan (board #1025)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Each task runs in its own worktree/branch off `feature/1025-big-branch-review`; the controller merges each lane on green.

**Goal:** Branch review shows danger-ordered chapters of a 700-file branch within seconds without AI, describes them per chapter in size-budgeted parallel calls with a goal summary that never waits for every chapter, and (phase 3) offers an independent reviewer chat.

**Architecture:** A new Go leaf package `internal/reviewmap` builds the map (lanes, noise, danger, chapters) from git reads through `reviewdiff.Repo`'s hardened runner; `workbench review map` serves it. `internal/reviewai` packs the map's chapters into ≈2,500-line batches (one batch = today's single call), caches one description per chapter in `review_overview_parts`, streams events and writes the assembled overview to `review_overviews`. The Desktop drops its Swift chapter builder and drives everything from the map and the stream.

**Tech Stack:** Go 1.26 (cobra, SQLite/goose), SwiftUI + WatchtowerCore (GRDB), the strong-tier `digest.Generator`.

**Spec:** business `docs/superpowers/specs/2026-11-07-big-branch-review-design.md` (owner-approved, ask #591), technical `docs/superpowers/specs/2026-11-07-big-branch-review-technical.md` (§ numbers below refer to it). Executors read both; the plan does not repeat them.

## Global Constraints

- Repo text in English; no live data, corp names or local paths (public repo).
- REVIEW-01 amendment exactly as spec "Contracts and storage that change": new rows in `review_overview_parts` and `review_rounds.head_sha` only; `review map` writes nothing; REVIEW-02..05 unchanged. REVIEW-05: every new git call through `reviewdiff.Repo`'s runner, listed in the guard test.
- Migration **00174** (`review_overview_parts`, `review_rounds.head_sha`); phase 3's thread table is **00175**. 00173 is #1012's `review_rounds.branch`.
- Chapter keys: `agent:<n>`, `collapsed`, `dir:<dir>[#N]` byte-identical to today's Swift; new `lane:<lane>`, `lane:<lane>/<dir>[#N]`; no `ai:` keys.
- Numbers: `MaxBatchLines = 2500`, `MaxOverviewFileLines = 300`, lane split 400 lines, call budget `90 s + 60 s × ceil(lines/1000)`, parallel `min(batches, 4)`, summary 2 min, run ceiling `waves × max(call) + summary` capped at 45 min, `LockWaitCap = 50 min`, map budget 20 s, walk bounds 2,000 commits / 200 lanes, Desktop map timeout 60 s (the map's own budget is 20 s), stream heartbeat `tick` every 30 s and Desktop stream silence 5 min (so only a stuck process trips it, never a slow call; tech spec §3.2/§3.5), part pruning 30 days, review-map.md ≤ 65,536 bytes.
- Error classes `timeout|provider|parse|cancelled|too_large|busy`; owner texts verbatim from §3.6/§3.7; logs carry class, index and counts only (FILES-01).
- Prompts through the `add-ai-prompt` skill: `review.overview` v3, `review.chapters` v1, `review.summary` v1, both providers; ledger purposes of the same names.
- Desktop screens match `docs/design/mockups/big-branch-review/` and use the design kit's shared empty/loading/error states; `make desktop-shots` before review.
- Inner loop per task (`go test ./internal/<pkg>`, `make test-swift FILTER=…`, `make lint-diff`); full gate once per phase by the controller.

## Review Focus

1. **Paths with spaces, quotes or non-ASCII in `git log --name-only`** — attribution must use `-z` output; a test with `dir with space/ü.go` lands in its lane (Task 3).
2. **A branch-tip round (#1012) or a pre-release round with empty `head_sha`** — tip rounds attribute lanes from the tip commit; empty `head_sha` gives package chapters and `lanes_partial`, never today's folder HEAD (Tasks 1, 5).
3. **The model answers keys or paths outside its batch** — dropped entry by entry; a batch whose reply names none of its chapters is `parse` for those chapters only (Task 6).
4. **A chapter whose files all lie past the diff's 50k cap or are binary** — no empty batch is sent; such a chapter is described as "not shown" without a call (Task 6).
5. **Refresh while the stream is mid-line or the CLI is killed** — the partial line is dropped, finished parts stay, the model shows the chapters as cached on the next run (Tasks 7, 12).

---

## Phase 1 — Go

### Task 1: Migration 00174 and the database layer

**Depends on:** none.

**Files:**
- Create: `internal/db/migrations/00174_review_overview_parts.sql`
- Modify: `internal/db/schema.sql`, `internal/db/review_rounds.go`, `internal/db/review_agent.go` (parts), `internal/db/targets.go`, `internal/db/db_test.go` (`TestAllTablesExist`), goldens + `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (`-update`)
- Test: `internal/db/review_overview_parts_test.go`, `internal/db/review_rounds_test.go`

**Interfaces — Produces:**
- `type ReviewOverviewPart struct { ProjectID int64; Hash, JSON, Model string; CreatedAt time.Time }`
- `func (db *DB) ReviewOverviewParts(projectID int64, hashes []string) (map[string]ReviewOverviewPart, error)`
- `func (db *DB) PutReviewOverviewPart(p ReviewOverviewPart, now time.Time) error` — one short `INSERT OR REPLACE` tx; prunes this project's rows older than 30 days in the same tx.
- `ReviewRound.HeadSHA string`; `CreateReviewRound`, `UpdateReviewRoundTree` (gains a `head string` parameter) and `RepointReviewRound` store it.
- `func (db *DB) TargetsByBranches(projectID int64, branches []string) (map[string]Target, error)` — open or closed, newest first wins.

- [ ] Write tests: put/get round-trip; same hash replaced; a 31-day-old row pruned on the next put, a 29-day-old kept; cascade on project delete; `head_sha` stored by create, refresh and repoint, default `''` on an old row; `TargetsByBranches` returns the newest of two targets on one branch and ignores other workbenches.
- [ ] Run, see them fail; add migration (follow `add-migration`), mirrors, code; run `go test ./internal/db -run 'TestAllTablesExist|TestSchemaGolden|TestDesktopTestSchema|ReviewOverviewPart|ReviewRounds|TargetsByBranches'` → PASS.
- [ ] Commit.

### Task 2: reviewmap — noise, danger, repository patterns

**Depends on:** none.

**Files:**
- Create: `internal/reviewmap/{noise.go,danger.go,patterns.go,testheur.go}` + tests, `internal/reviewmap/testdata/`
- Modify: `internal/reviewdiff/collapse.go` (export `CollapsedReason(path string) string`)

**Interfaces — Produces:**
- `type Level int` with `Normal < Significant < Breaking`, `String()` = `normal|significant|breaking`.
- `type Patterns struct { Breaking, Significant, Skip []string; Notes []string }`; `func LoadPatterns(workbenchFolder string) Patterns` (lens-file safety rules of §2.4; refusal → empty + note); `func ParsePatterns(text string) Patterns`; `func (p Patterns) Match(path string) (level Level, skip bool, ok bool)` (`path.Match` per segment, `**` any depth).
- `func IsNoise(f reviewdiff.File, p Patterns) bool` (§2.2).
- `func Signals(f reviewdiff.File, p Patterns) []string` and `func LevelOf(signals []string) Level` (§2.3 table; `repo:<level>`).
- `func IsTest(path string) bool` (port of Swift `isTest`, §2.5).

- [ ] Tests (table-driven, one row per §2.3 signal and §2.2 rule): `api_removed` fires on `-func Foo(` with no `+func Foo(` and does **not** fire on a rename in place (removed and re-added `Foo`); Swift `public func` removal fires; `migration_edited` vs `migration_added`; `test_deleted` only for a test path; `security_path` case-insensitive on `OAuthClient.swift`; `file_deleted` not for noise; patterns: `docs/inventory/**` → breaking, `## Can skip` glob → noise, a symlinked `review-map.md` refused with a note, a 70 KB file refused; `IsTest` parity table copied from `ReviewChaptersTests`.
- [ ] Implement; `go test ./internal/reviewmap ./internal/reviewdiff` → PASS. Commit.

### Task 3: reviewmap — lane attribution

**Depends on:** none (titles through an interface; Task 5 wires the db).

**Files:**
- Create: `internal/reviewmap/lanes.go`, `lanes_test.go` (synthetic repos via `internal/gittest`, `TestMain` calls `gittest.DisableBackgroundGit()`)
- Modify: `internal/reviewdiff/reviewdiff.go` or new `internal/reviewdiff/history.go` — read-only methods on `Repo`: `FirstParentWalk(ctx, tip string, exclude []string, limit int) ([]Commit, error)` (`rev-list --first-parent --parents`) and `CommitFiles(ctx, tip string, exclude []string) (map[string][]string, error)` (`log --first-parent --no-renames --name-only -z`, one call per walk); `IsAncestor(ctx, a, b string) (bool, error)`; REVIEW-05 guard list updated.

**Interfaces — Produces:**
- `type Lane struct { Name, Branch, Title string; TargetID int64; JiraKey string }`
- `type TitleSource interface { Titles(branches []string, jiraKeys []string, boardRefs []int64) LaneTitles }` (+ `LaneTitles` maps).
- `func Attribute(ctx context.Context, repo *reviewdiff.Repo, base, head, defaultTip string, titles TitleSource, budget time.Duration) (Attribution, error)` where `Attribution{ FileLane map[string]string; Also map[string][]string; Lanes map[string]Lane; Partial bool }`.

- [ ] Tests (one synthetic repo, §8 first bullet): integration branch with two lanes, a nested integration lane, a base sync (skipped), a fast-forward `into` merge (named by `into`), `Merge pull request #N from o/b`, tagged direct commits (Jira key validated / not, `#N` kept only for a workbench target id, plan tag, conventional scope), untagged direct commit → the lane, a file touched by two lanes → most commits wins, tie → later, other in `Also`; uncommitted file → no lane; `head = ""` → `Partial`, no lanes; bounds (limit 3 commits in test) → rest unlaned, no error; budget 1 ns → `Partial`, empty; path with space and `ü` (Review Focus 1).
- [ ] Implement per §2.1; `go test ./internal/reviewmap ./internal/reviewdiff` → PASS. Commit.

### Task 4: reviewmap — chapters, order and `Build`

**Depends on:** Tasks 2, 3.

**Files:**
- Create: `internal/reviewmap/{chapters.go,map.go}` + tests; shared fixture `internal/reviewmap/testdata/chapters_golden.json`
- Create: `WatchtowerDesktop/Tests/Core/ReviewChaptersGoldenTests.swift` (decodes the same fixture, asserts today's Swift `mechanical`/`resolve` produce exactly its keys, titles and order — must pass **before** Task 11 deletes the Swift code)

**Interfaces — Produces:**
- `type Chapter struct { Key, Title string; Level Level; Core bool; Paths []string; ChangedLines int; Lane string; TargetID int64; JiraKey string; SignalsSummary map[string]int }`
- `type FileInfo struct { Path, Chapter string; Level Level; Signals []string; Lane string; Also []string }`
- `type Map struct { Chapters []Chapter; Files []FileInfo; LanesPartial, DiffTruncated bool; Notes []string }` with JSON tags = §2.6 keys (`level` as string).
- `type Input struct { Diff reviewdiff.Diff; AgentChapters []db.ReviewNote; Attribution Attribution; Patterns Patterns }`
- `func Build(in Input) Map` (pure; Task 5 does the git/db).

- [ ] Tests: agent chapter numbering with gaps and core-first (golden); noise → `collapsed` titled `Can skip`; lane > 400 lines split by dir with tests beside their subject; `dir:` keys equal Swift's on the golden; reading order level → agent → lines desc → `collapsed` last; `core` for breaking; Swift golden test passes on the current Swift code.
- [ ] Implement; `go test ./internal/reviewmap` and `make test-swift FILTER=ReviewChaptersGoldenTests` → PASS. Commit.

### Task 5: `workbench review map` and `head_sha` capture

**Depends on:** Tasks 1, 4.

**Files:**
- Create: `cmd/workbench_review_map.go`, `cmd/workbench_review_map_test.go`, `cmd/testdata/review-map.golden.json` (also copied to WatchtowerCore test fixtures in Task 11)
- Modify: `cmd/workbench_review.go` (start/refresh/repoint store `head_sha`: `rev-parse HEAD` of the folder; a branch-tip round stores the tip commit), `internal/tools/workbench_review_session.go` (a `ReviewSource.Head(ctx, repo) (string, error)` read), `internal/reviewmap/titles_db.go` (`DBTitles` implementing `TitleSource` over `TargetsByBranches` + `GetJiraIssuesByKeysMap` + target ids)

**Interfaces — Produces:**
- `func BuildReviewMap(ctx context.Context, d *db.DB, p *db.Workbench, repo *reviewdiff.Repo, round *db.ReviewRound /*or nil*/, sessionID int64) (reviewmap.Map, reviewdiff.Diff, error)` in `cmd` (shared by map and overview commands).
- CLI: `watchtower workbench review map (--round R | --session S) --workbench W --json` → `{"ok":true,"map":{…}}`; writes nothing.

- [ ] Tests: pinned JSON keys (golden `review-map.json`); a round with `head_sha = ''` → `lanes_partial: true`, `dir:` chapters; a branch-tip round → lanes from the tip; `diff_truncated` set past 50k; map writes no row (row counts before/after); start, refresh and repoint store `head_sha`; `DBTitles` resolves a lane's Jira title with the Jira client unset / an HTTP transport that fails the test on any request (local database only).
- [ ] Implement; `go test ./cmd -run 'ReviewMap|WorkbenchReview_'` and `go test ./internal/tools ./internal/reviewmap` → PASS. Commit.

### Task 6: reviewai — packing, budgets, prompts, parsing

**Depends on:** Task 4.

**Files:**
- Create: `internal/reviewai/{pack.go,budget.go,chapters.go,summary.go}` + tests
- Modify: `internal/reviewai/overview.go` (v3 single-call parse: chapter descriptions + summary), `limits.go` (`MaxBatchLines = 2500`; `MaxOverviewLines` retired), `internal/prompts/defaults.go`, `internal/prompts/store.go` (`ReviewChapters = "review.chapters"`, `ReviewSummary = "review.summary"`; overview v3), prompt tests for both providers

**Interfaces — Produces:**
- `type Batch struct { Chapters []reviewmap.Chapter; Files []reviewdiff.File; Lines int }`
- `func Pack(m reviewmap.Map, d reviewdiff.Diff, have map[string]bool) []Batch` — first fit in reading order; never `collapsed`; an oversized chapter alone, files by level desc then path, each file ≤ 300 lines + `(+N lines not shown)`; when every packable chapter fits one batch, one batch of all of them regardless of `have` (§3.1).
- `func CallBudget(lines int) time.Duration`, `func Parallel(batches int) int`, `func RunCeiling(batches []Batch) time.Duration` (§3.2).
- `type ChapterDesc struct { Key, What string; Risks []Risk }`; `func ParseChapters(raw string, b Batch) (map[string]ChapterDesc, error)`; `func ParseSummary(raw string, in SummaryInput) (Summary, error)` with `NotCovered []string` validated against the input.
- `IntentItem` gains `Source string` (`session|lane`); `Coverage` gains `Source`; `IntentHash` covers both lists.
- `func (p *Pipeline) DescribeBatch(ctx, b Batch, intent []IntentItem /*nil for multi-batch*/, notes []db.ReviewNote) (map[string]ChapterDesc, *Summary, error)`; `func (p *Pipeline) Summarize(ctx, in SummaryInput) (Summary, error)`.

- [ ] Tests: 3-file diff → 1 batch with summary (one generator call, stub counts); synthetic 700-file map → no noise file in any batch, every batch ≤ 2,500 lines, each non-noise chapter in exactly one batch; oversized chapter cut with the marker, dangerous file first; budgets for 1, 4, 20 batches (1 → 1 parallel; 20 → 4 parallel, 5 waves; cap 45 min); reply naming a foreign key/path drops just that entry; reply naming none of the batch → `parse` (Review Focus 3); chapter whose files are all unshown (binary / past cap) is not packed and gets a "not shown" description (Review Focus 4); `not_covered` entries outside the input dropped; summary prompt rule caps such items at `partial` (prompt golden).
- [ ] Implement via `add-ai-prompt`; `go test ./internal/reviewai ./internal/prompts` → PASS. Commit.

### Task 7: the overview run — cache, stream, flags, errors

**Depends on:** Tasks 1, 5, 6.

**Files:**
- Create: `internal/reviewai/run.go` (+ test) — the orchestrator, no cobra
- Modify: `internal/tools/workbench_review_context.go` (`LaneIntent`), `cmd/workbench_review_overview.go` (flags `--stream`, `--chapter` repeatable, `--summary`, `--continue`, `--caller desktop|agent|cli`; `--cached-only` unchanged; the 5-min `reviewAIBudget` replaced by `RunCeiling`), `cmd/workbench_review_overview_test.go`, `cmd/testdata/review-overview-stream.jsonl`

**Interfaces — Produces:**
- `func PartHash(ch reviewmap.Chapter, files []reviewdiff.File, notes []db.ReviewNote, promptID string, promptVersion int) string` (§3.3).
- `type Event struct { Event, Key, State string; … }` — JSON lines per §3.5 (`map`, `waiting`, `chapter`, `summary`, final envelope).
- `type RunOptions struct { Chapters []string; SummaryOnly, Continue bool; Emit func(Event); Now func() time.Time }`
- `func (p *Pipeline) Run(ctx context.Context, store PartStore, m reviewmap.Map, d reviewdiff.Diff, intent []IntentItem, notes []db.ReviewNote, opt RunOptions) (Overview, error)` with `PartStore` = the Task 1 methods.
- `func LaneIntent(d *db.DB, p *db.Workbench, m reviewmap.Map) ([]reviewai.IntentItem, error)` in `internal/tools/workbench_review_context.go` — one item per distinct lane with a board target (title + intent) or a synced Jira issue (summary + clipped description), `Source: "lane"`, after the session's items (`Source: "session"`); `ReviewOverviewInput` and the round form both append it.
- `Overview` gains `Incomplete []string` (always present) and chapters `{key,title,level,paths,core,what}`; `risk` = union.

- [ ] Tests: a map with two lane tickets (a board target and a Jira issue) → the summary input and the coverage carry both lane items with `source: "lane"` after the session's items, and `IntentHash` changes when a lane ticket is added; a round with no session gets lane items only; one batch failing (stub error) and one hanging past its budget → others `ok`, `incomplete` lists both, summary made with them under `not_covered`, assembled row written; zero described → no summary, no `review_overviews` row; `--chapter K1 --chapter K2` redoes only those then the summary; `--summary` with a missing part → `missing_parts`; `--continue` describes only part-less chapters; cache: Refresh after editing one file calls only its chapter; parts survive a new `DB` handle; stream golden; FILES-01 canary (`internal/logcanary`) over a failing run — no title, path or provider text in the log; error texts verbatim (§3.6, `<N> min` rounded up); SIGTERM mid-run (`cancelled`) keeps finished parts (Review Focus 5); `tick` printed every 30 s during a slow stub call (fake clock).
- [ ] Implement; `go test ./internal/reviewai` and `go test ./cmd -run ReviewOverview` → PASS. Commit.

### Task 8: one run at a time

**Depends on:** Task 7.

**Files:**
- Create: `internal/reviewai/runlock.go` (+ test)
- Modify: `cmd/workbench_review_overview.go`

**Interfaces — Produces:**
- `func LockPath(workspaceDir string, projectID int64, folderRealPath string) string` — `<workspace>/locks/review-overview-<project>-<sha256[:16]>.lock`.
- `func AcquireRun(ctx context.Context, path, by string, wait bool, onWait func(holder Holder)) (release func(), err error)` — `fsutil.TryLockFile` / `LockFile`; writes `{"by","started_at"}`; non-waiting held → `ErrBusy{Holder}`; `LockWaitCap = 50 * time.Minute`.
- Streamed form waits, re-reads parts every 5 s and emits `cached` events, `waiting` once and every 60 s; every other form answers `busy` at once (exit 1, §3.7 text).

- [ ] Tests (two processes via the test binary re-exec, reaped in `t.Cleanup`): holder + streamed waiter → waiter emits `waiting` and the holder's chapters as `cached`, then calls only for the rest (call counter; no `part_hash` twice); non-streamed against a held lock → `busy` at once (< 1 s); holder killed → lock free; shortened cap with a never-releasing holder → `busy` with "Another overview of this branch is still running."; agent run killed after 2 of 4 batches → 2 parts kept, re-run calls 2; the wait does not count into the run ceiling.
- [ ] Implement; `go test ./internal/reviewai -run RunLock` and `go test ./cmd -run ReviewOverviewLock` → PASS. Commit.

### Task 9: finish gate, skill pack, this repo's review map, docs

**Depends on:** Task 8.

**Files:**
- Modify: `internal/tools/workbench_finish_gate.go` (+ test): only `source: session` items gate; an `incomplete` overview counts; missing-overview refusal + "Re-run it; only the missing chapters are redone." + run it in the background when the map's shown lines exceed one batch; `finish_session` never runs the model.
- Modify: `internal/devpack` skill pack (version bump, the background rule, `busy` meaning) + its goldens.
- Create: `.watchtower/review-map.md` for this repo (§2.4 list).
- Modify: `docs/inventory/review.md` (REVIEW-01 amendment entry, owner approval ask #591), `docs/features/diff-reviewer.md` (section "Big branches (#1025)"), `docs/features/workbench.md` pointer if the pack line changes, `CLAUDE.md` feature-note line.

- [ ] Tests: lane items `not_found` do not refuse; a session item only in an `incomplete` chapter at `partial` refuses with today's text; handover ask passes; refusal text pinned; pack golden.
- [ ] `go test ./internal/tools ./internal/devpack` → PASS. Commit.

**Phase 1 gate (controller):** `make test`, `make lint-all`, `go test ./cmd/...`; local-review per lane.

---

## Phase 2 — Desktop

### Task 10: WatchtowerCore — map, stream and chapter presentation

**Depends on:** Tasks 5, 7 (fixtures).

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Models/ReviewMap.swift`, `.../Services/Review/ReviewOverviewStream.swift`, `.../Services/Review/ReviewChapterList.swift`; tests in `WatchtowerDesktop/Tests/Core/` with fixtures `review-map.json`, `review-overview-stream.jsonl` copied from `cmd/testdata`
- Modify: `.../Models/ReviewModels.swift` (`ReviewOverview.incomplete`, chapter `key/level/what`, coverage `source` — optional decoding)

**Interfaces — Produces:**
- `struct ReviewMap: Decodable` (§2.6 keys), `enum ReviewDangerLevel: String { case breaking, significant, normal }`.
- `enum ReviewStreamEvent { case map(ReviewMap), waiting(by: String), tick, chapter(key: String, state: ChapterRunState, what: String?, risks: [ReviewRisk], error: ReviewRunError?), summary(ok: Bool, error: ReviewRunError?), final(ReviewEnvelope) }`; `struct ReviewOverviewStreamDecoder { mutating func feed(_ data: Data) -> [ReviewStreamEvent] }` (line-buffered; a partial last line held, Review Focus 5).
- `enum ChapterRunState { case pending, running, queued, waiting, ok, cached, failed(text: String, detail: String?), notStarted }`.
- `enum ReviewChapterList { static func sections(_ map: ReviewMap) -> [Section]; static func counter(map:, isViewed:) -> (chapters: Int, files: Int); static func next(map:, isViewed:) -> String?; static func showsList(_ map: ReviewMap) -> Bool }` (single non-noise chapter → false).

- [ ] Tests: fixtures decode; sections Breaking-and-significant / Other / Can skip; counter excludes `collapsed`; next in danger order; one-chapter map hides the list; decoder across split reads and a truncated last line; `{"event":"tick"}` decodes to `.tick` and an unknown event name decodes to `.tick` too (any complete line counts as life).
- [ ] `make test-swift FILTER='ReviewMap|ReviewOverviewStream|ReviewChapterList'` → PASS. Commit.

### Task 11: ReviewChangesModel — map-driven, streamed, Retry queue

**Depends on:** Task 10 (and Task 4's golden passing on the old code).

**Files:**
- Modify: `WatchtowerDesktop/Sources/ViewModels/ReviewChangesModel.swift`, `.../Services/WorkbenchCLI.swift` (`reviewMap`, `reviewOverviewStream(…, chapters:, summaryOnly:, continue:) -> AsyncThrowingStream<ReviewStreamEvent, Error>` with `--caller desktop`, process group reaped on cancel)
- Delete: `ReviewChapters.mechanical`, `resolve`, `lenses(for:)` and their tests (keep `done`, `estimateMinutes`, `isTest` if still used)
- Test: `WatchtowerDesktop/Tests/ReviewChangesModelBigBranchTests.swift`

**Interfaces — Produces:** on the model: `map: MapState` (`.loading | .ready(ReviewMap) | .failed`), `chapterStates: [String: ChapterRunState]`, `summaryState`, `waitingFor: String?`, `retry(chapter:)`, `retrySummary()`, `describeRemaining()`, `retryMap()`.

- [ ] Tests (fake CLI): map on open and Refresh; map failure / 60 s silence → `.failed`, file list still shown, `retryMap` rebuilds; stream fills states; Retry during a run → `queued`, one follow-up `--chapter` run with all queued keys; Refresh during own run terminates it and keeps cached; Refresh while `waiting` restarts the waiter, never signals another pid; `busy` → card text with Retry; 5-min stream silence → failed, while a fake stream of only `tick` lines every 30 s for 10 min (fake clock) never trips it — the silence timer resets on every complete line, recognised or not; state survives navigating away and back (`reviewModels`); saved `ai:` chapter key → first chapter; a failed chapter keeps the owner sentence and the provider's `detail` apart (`failed(text, detail)`).
- [ ] `make test-swift FILTER='ReviewChangesModel|ReviewChapters'` → PASS. Commit.

### Task 12: Branch review views

**Depends on:** Task 11.

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/Review/` (chapter list, `ReviewOverviewView.swift`, toolbar counter, file header badges), design shots catalog + fixtures for every mockup frame (1, 1b, 2a–2c, 3, 4a, 4b)
- Modify: `docs/guide/features/workbench/diff-review.md`

- [ ] View test: a failed chapter shows the one-sentence text, and the provider's `detail` only after the disclosure is opened (folded by default); the same for a failed summary.
- [ ] Shots: `make desktop-shots DESKTOP_SHOTS=<scratch>` for each frame, compared with `docs/design/mockups/big-branch-review/` (light and dark); shared empty/loading/error components only.
- [ ] `make test-swift FILTER='DesignShot|ReviewPresentation'`, `make lint-diff` → PASS. Commit.

**Phase 2 gate (controller):** `make test-swift`, `make lint-all`; local-review per lane.

---

## Phase 3 — Reviewer

### Task 13: `ai query --read-folder` widened

**Depends on:** none (may run in parallel with phase 1).

**Files:** `cmd/ai.go` (`resolveReadFolder`) + test; spec 2026-10-02 §9.1 amendment note; `docs/features/embedded-chat.md`; `docs/inventory/chat.md` (changelog entry: read-folder widened to the workbench's registered session worktrees, owner ask #560 — no guard relaxed).

- [ ] Tests: the workbench folder accepted; a worktree in `terminal_session_worktrees` of that workbench accepted (real path, symlink resolved); another workbench's worktree, a sibling dir and a symlink into a worktree refused as today.
- [ ] `go test ./cmd -run ReadFolder` → PASS. Commit.

### Task 14: reviewer panel, threads and Send to author

**Depends on:** Tasks 12, 13.

**Files:**
- Create: `internal/db/migrations/00175_review_reviewer_threads.sql` (+ mirrors, Desktop writer), `WatchtowerDesktop/Sources/WatchtowerCore/Services/Review/ReviewerSurface.swift`, `ReviewerMapBrief.swift` (the compact per-turn map: chapters, danger, summary, open chapter)
- Modify: the review chat panel (`ReviewAgentChatPanel`) → **Reviewer | Author** segmented switch; design shots catalog + fixtures for frame 5; Send to author → design comment in the open round (disabled "Start a round to send")
- Test: `ReviewerSurfaceTests`, `ReviewerThreadQueriesTests`

- [ ] End-to-end test (fake provider that reads files through the tool call it is given): a session in its own registered worktree, a question that needs files of two chapters → the turn runs with `--read-folder` = that worktree, the answer cites both files, nothing is written to the round.
- [ ] Shots: `make desktop-shots` of mockup frame 5 (Reviewer side with an answer, Sent line, failed turn with Retry, Author side) in light and dark, compared with `docs/design/mockups/big-branch-review/`.
- [ ] Tests: thread key = round `branch` else folder branch, detached → `session:<id>`; two sessions on one branch share it; the brief stays under its cap on a 700-file map; Send writes exactly one design comment and nothing else; disabled without an open round; failed turn shows Retry; `toolAccess` `.draftOnly`.
- [ ] `make test-swift FILTER='Reviewer'`, `go test ./internal/db` → PASS. Commit.

**Phase 3 gate + final:** full gate, debate-review of the whole branch, PR to `main` only with the owner's ok.

## Lanes

- Parallel from the start: Task 1, Task 2, Task 3, Task 13.
- Then Task 4 (after 2, 3); then Task 5 (1, 4) ∥ Task 6 (4); Task 7 (1, 5, 6); Task 8; then Task 9 ∥ Task 10 (5, 7).
- Task 11 → Task 12 → Task 14.
- One table per lane: Task 1 owns migration 00174, Task 14 owns 00175.
