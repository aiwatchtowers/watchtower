# Diff Reviewer — Plan 3: agent tools, AI overview, Undo, learning loop

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The agent annotates its changes (notes and chapters) and answers each review comment; an AI overview (summary, intent coverage, out-of-scope files, risk per file, chapters with their lenses) starts when a round opens and feeds Deep and Quick mode; the owner can **Undo** one hunk in the work tree; **Find repeats** turns repeated comments into rules the owner accepts into `.watchtower/review.md`.

**Architecture:** One migration adds `review_notes`, `review_overviews`, `review_reverts`, `review_lessons`. Go owns every write that touches git or the folder: `reviewdiff.RevertHunk` (`git apply -R` on the work tree after a blob check), `reviewdiff.AppendLessonRule`, and the two LLM calls in a new package `internal/reviewai` (prompts `review.overview`, `review.lessons`, strong tier). Two workbench write tools (`annotate_changes`, `reply_review_comment`) join the MCP surface; `get_review` lists reverts. Swift plugs the agent's and the AI's chapters ahead of Plan 2's mechanical fallback, shows notes and Undo inside the Monaco diff, and adds the overview, the "Resolved by the agent" group and the Find repeats sheet.

**Tech Stack:** Go 1.26 (cobra, `database/sql` + modernc sqlite, goose, `digest.Generator`, `internal/prompts`), SwiftUI + GRDB (WatchtowerCore), Monaco diff editor (`CodeEditorWeb/diff.js`).

**Spec:** `docs/superpowers/specs/2026-10-16-workbench-diff-reviewer-design.md` (approved, ask #179) — §4.6, §7.1, §7.2, §8.1, §8.3, §8.4, §9, §13, §15 phases 4–5. Plan 1 (`…-p1-core.md`, merged) built the engine, rounds, Quick mode and delivery; Plan 2 (`…-p2-deep.md`) built Deep mode with mechanical chapters, lenses and `review_checks`. Feature note `docs/features/diff-reviewer.md`; contracts `docs/inventory/review.md`.

## Inventory changes — owner approval needed

Each lands only with the owner's explicit OK (an ask before Task 10 merges; the code tasks may proceed, their guards are written to the amended text):

1. **REVIEW-01 amended** (spec §13, approved in the spec): the reviewer writes a work-tree file only on an owner-pressed Undo (one hunk's file, never the index or a ref) and writes `.watchtower/review.md` in the workbench folder only on an owner-pressed Accept. Both CLI commands refuse under an agent marker (`refuseUnderAgent`) — a narrowing this plan adds so "owner-pressed" holds.
2. **REVIEW-02 new** (spec §13): Undo applies only after the file's blob equals the round tree's, `git apply --check -R` passed, the round is open, and the session's `agent_state` is not `working` (Go) / the session is not working or Agents working (Desktop).
3. **REVIEW-03 amended:** the agent can now resolve a comment (`reply_review_comment resolved: true`). Such a comment is not carried, but it is never dropped from the owner's view: it is listed under **Resolved by the agent** with its reply and **Reopen**. "Leaves the owner's list only by the owner resolving it" becomes "…by the owner resolving it, or by the agent resolving it, in which case it stays listed with Reopen".
4. **REVIEW-05 strengthened:** `apply` and `hash-object` join `gitbin`'s `contentReads` (filter drivers blanked).
5. **DEV-06:** the workbench tool set grows from sixteen to **eighteen** (`annotate_changes`, `reply_review_comment`, both audited workbench writes like `finish_session`). The guard keeps its historical name and asserts eighteen.
6. **PROJ-04:** pack marker `v10 → v11` only (install rules unchanged). **PROJ-12 unchanged** (the delivery line is not changed; reverts reach the agent through `get_review`).

## Global Constraints

- Migration file `internal/db/migrations/00125_review_agent_ai.sql` — 00125 is the first number free on this branch and on `origin/main` today; the executor re-checks both (`ls internal/db/migrations`, `git ls-tree --name-only origin/main internal/db/migrations/`) before Task 1 and renumbers if main moved.
- Every git call goes through `reviewdiff.Repo.git` → `gitbin.ReadArgsIn` + `ExecEnv` (REVIEW-05). Undo never passes `--index` or `--cached` to `apply`; nothing writes a ref.
- `.watchtower/review.md` lives in the **workbench folder** (`projects.folder_path`), as in Plan 2; written only by `AppendLessonRule` under the Plan 2 read rules (lstat, no symlinks, `O_NOFOLLOW`, 65,536 bytes).
- Source tags and tiers: `workbench.review_overview` and `workbench.review_lessons`, both **strong** (absent from the light switch in `internal/digest/models.go`). Prompt ids `review.overview`, `review.lessons`, version 1, registered in `internal/prompts` (Settings → Prompts can tune them).
- LLM budgets: one call ≤ **5 minutes** (`reviewAIBudget = 5 * time.Minute`, cmd); the Desktop runs these two CLI calls with a 330 s timeout.
- Overview input caps (`internal/reviewai/limits.go`, the only place): **300** diff lines per file, **6,000** diff lines in all; a file past either cap (or collapsed/too large) is listed as `<path> (+a −d) — not shown`.
- Overview cache key: `(project_id, tree_sha, base_sha, intent_hash)`; `intent_hash` = sha256 hex of the JSON of the context items plus the session's notes (so a new note re-runs the overview). Failures are never cached.
- Validation never trusts the model: unknown paths, lens ids and enum values are dropped entry by entry; malformed JSON or an empty `summary` fails the whole call.
- Chapter sources, first non-empty wins: the agent's (`annotate_changes`), the AI's, Plan 2's mechanical. Files no chosen chapter names go into mechanical chapters appended after. Keys `agent:<n>`, `ai:<n>` (n = 1-based index in the source list), mechanical keys unchanged.
- Lenses per chapter: mechanical and agent chapters show all lenses; an AI chapter shows the lenses it marks **plus** `house_rules` and every non-built-in lens (the owner's own rules never hide).
- Write tools: `annotate_changes` and `reply_review_comment` are workbench-surface `AccessWrite` tools, applied directly and audited (DirectApply), bound to workbench N; `annotate_changes` needs a `terminal_sessions` row of workbench N named by `WATCHTOWER_TERMINAL_SESSION_ID`.
- Swift: house conventions of `docs/review/review-rules.md` "Swift / Desktop conventions"; `make lint-swift` in every Swift task (lint-diff is Go-only). Bridge messages are validated (hunk id `^[0-9a-f]{16}$`); `diff.js` uses `textContent` only.
- Docs English; public repo hygiene (temp dirs, `example.com`, no real paths or ids).
- Task scope checks only; the full gate once by the controller after Task 10.

## Review Focus

1. **The agent edits the file between the owner's Refresh and Undo** — the blob check refuses with "the file changed since this round's snapshot — refresh first", the file is byte-identical afterwards, no `review_reverts` row (Task 2).
2. **The AI overview arrives after the owner already ticked checks in a mechanical chapter** — chapters are not swapped under them; a banner offers "Use AI chapters" (Task 8).
3. **The model names paths that are not in the diff, or lens ids that do not exist** — dropped one by one; a chapter left empty disappears; the rest of the overview is used (Task 4).
4. **Find repeats over carried comments** — a comment carried across three rounds is one remark, not a repeat: carried copies are not input (Task 1 query, Task 5 test).
5. **Accept when `.watchtower` is a symlink or `review.md` is a FIFO / would pass 64 KB** — refused, nothing written, the lesson stays `proposed` (Task 5).

---

## Dependencies and parallel lanes

| Task | Depends on |
|---|---|
| 1 Go migration, accessors, envelope fields | none |
| 2 Go Undo (`revert-hunk`) | 1 |
| 3 Go agent tools, `get_review` reverts, skill pack v11 | 1 |
| 4 Go AI overview (`internal/reviewai`, `review overview`) | 1 |
| 5 Go Find repeats (`review lessons …`, rule file write) | 4 (same package and prompt files) |
| 6 Swift core data (models, queries, CLI calls) | 1 (schema); envelopes as pinned below |
| 7 Swift core logic (chapter sources, lenses per chapter, coverage items, note placement) | none |
| 8 `ReviewChangesModel` + `ReviewLessonsModel` | 2, 4, 5, 6, 7 |
| 9 Views + `diff.js` | 8 |
| 10 Docs + inventory | 1–9 |

- **Wave 1:** Lane G = Task 1; Lane C = Task 7 (Core only).
- **Wave 2 (parallel, after G merges):** Lane U = Task 2; Lane A = Task 3; Lane O = Task 4 → 5; Lane S = Task 6 (Core build only).
- **Wave 3:** Lane S = Task 8 → 9 (the one heavy Swift lane).
- **Wave 4:** Task 10, then the phase gate.

Collision rules: Task 1 adds every new `reviewEnvelope` field and DB accessor; Tasks 2, 4, 5 put their subcommands in their own files (`cmd/workbench_review_revert.go`, `…_overview.go`, `…_lessons.go`) with their own `init()` adding to `workbenchReviewCmd`. Each lane in its own worktree off the Plan 3 integration branch; the controller merges.

---

## File Structure

**Go**
- Create `internal/db/migrations/00125_review_agent_ai.sql`, `internal/db/review_agent.go` (+ `_test.go`, `review_agent_migration_test.go`); modify `schema.sql`, `db_test.go`, golden, `TestDatabase+Schema.swift` (regenerated), `cmd/workbench_review.go` (envelope).
- Create `internal/reviewdiff/revert.go` (+ test), `internal/reviewdiff/lessonfile.go` (+ test); modify `internal/gitbin/run.go` (+ test), `internal/reviewdiff/guard_test.go`.
- Create `internal/reviewai/{limits.go,overview.go,lessons.go,pipeline.go}` + tests + `testdata/overview_ok.json`; modify `internal/prompts/store.go`, `defaults.go`, `internal/digest/models_test.go`.
- Create `cmd/workbench_review_revert.go`, `_overview.go`, `_lessons.go` + tests; modify `cmd/workbench_review_context.go` (extract `reviewContextItems`).
- Create `internal/tools/workbench_review_annotate.go`, `workbench_review_reply.go` + tests; modify `internal/tools/workbench_review.go`, `workbenches.go`, `internal/mcp/workbench_test.go`, `cmd/actions_registry_test.go`, `internal/devpack/workbenchskill/watchtower-workbench/SKILL.md` + pack tests.

**Swift (WatchtowerDesktop/Sources)**
- Modify `WatchtowerCore/Models/ReviewModels.swift`, `WatchtowerCore/Database/Queries/ReviewQueries.swift`, `Services/WorkbenchCLI.swift`.
- Modify `WatchtowerCore/Services/Review/ReviewChapters.swift`, `ReviewWrapUp.swift`, `ReviewCommentAnchor.swift`; create `ReviewNotePlacement.swift`.
- Modify `ViewModels/ReviewChangesModel.swift`; create `ViewModels/ReviewLessonsModel.swift`.
- Modify `CodeEditorWeb/diff.js`, `Views/Workbench/Review/MonacoDiffView.swift`, `ReviewChangesPaneView.swift`, `ReviewChangesHeader.swift`, `ReviewCommentListView.swift`, `ReviewFileListView.swift`, Plan 2's `ReviewMeaningView.swift`, `ReviewChapterListView.swift`, `ReviewChecklistView.swift`, `ReviewWrapUpView.swift`; create `ReviewOverviewView.swift`, `ReviewLessonsSheet.swift`; modify `scripts/editor-bridge-check.swift`.

**Docs:** `docs/features/diff-reviewer.md`, `docs/inventory/review.md`, `dev-surface.md`, `workbench.md` (PROJ-04 changelog), `agent-actions.md` (none expected — check), `CLAUDE.md`, spec status line.

---

### Task 1: Go — migration 00125, accessors, envelope fields

**Depends on:** none

**Files:** Create `internal/db/migrations/00125_review_agent_ai.sql`, `internal/db/review_agent.go`, `internal/db/review_agent_test.go`, `internal/db/review_agent_migration_test.go`; modify `internal/db/schema.sql`, `internal/db/db_test.go`, golden + Swift test schema (regenerated), `cmd/workbench_review.go`.

**Interfaces — Produces:**
- Tables (all timestamps `TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))`):
  - `review_notes(id INTEGER PK AUTOINCREMENT, project_id → projects ON DELETE CASCADE NOT NULL, session_id → terminal_sessions ON DELETE SET NULL, tree_sha TEXT NOT NULL, kind TEXT NOT NULL CHECK (kind IN ('note','chapter')), ord INTEGER NOT NULL, path TEXT NOT NULL DEFAULT '', start_line INTEGER NOT NULL DEFAULT 0, end_line INTEGER NOT NULL DEFAULT 0, quote TEXT NOT NULL DEFAULT '', text TEXT NOT NULL, paths_json TEXT NOT NULL DEFAULT '[]', core INTEGER NOT NULL DEFAULT 0 CHECK (core IN (0,1)), why TEXT NOT NULL DEFAULT '', created_at)`, index `(project_id, session_id, kind, ord)`. `text` = the note, or the chapter title.
  - `review_overviews(project_id → projects CASCADE NOT NULL, tree_sha, base_sha, intent_hash TEXT NOT NULL, json TEXT NOT NULL, model TEXT NOT NULL DEFAULT '', created_at, PRIMARY KEY (project_id, tree_sha, base_sha, intent_hash))`.
  - `review_reverts(id INTEGER PK AUTOINCREMENT, round_id → review_rounds ON DELETE CASCADE NOT NULL, hunk_id TEXT NOT NULL, path TEXT NOT NULL, header TEXT NOT NULL, patch TEXT NOT NULL, at, UNIQUE (round_id, hunk_id))` — `patch` (the hunk's lines) is beyond the spec's columns: the agent must see what was undone.
  - `review_lessons(id INTEGER PK AUTOINCREMENT, project_id → projects CASCADE NOT NULL, lens TEXT NOT NULL, text TEXT NOT NULL, source_comment_ids TEXT NOT NULL DEFAULT '[]', status TEXT NOT NULL DEFAULT 'proposed' CHECK (status IN ('proposed','accepted','dismissed')), created_at, decided_at TEXT)`.
  - Down drops the four.
- `internal/db/review_agent.go`:
  - `type ReviewNote struct { ID int64; Kind string; Ord int; Path string; StartLine, EndLine int; Quote, Text string; Paths []string; Core bool; Why, TreeSHA string }`
  - `ReplaceReviewNotes(projectID, sessionID int64, treeSHA string, notes []ReviewNote) error` — one tx: delete the session's rows, insert (ord = slice order per kind)
  - `ReviewNotes(projectID, sessionID int64) ([]ReviewNote, error)` — kind, ord order
  - `ReviewOverviewJSON(projectID int64, tree, base, intentHash string) (string, bool, error)`; `PutReviewOverview(projectID int64, tree, base, intentHash, json, model string) error` (INSERT OR REPLACE)
  - `type ReviewRevert struct { ID, RoundID int64; HunkID, Path, Header, Patch, At string }`; `ErrHunkAlreadyReverted`; `AddReviewRevert(r ReviewRevert) error` (unique violation → `ErrHunkAlreadyReverted`); `ReviewReverts(roundID int64) ([]ReviewRevert, error)`
  - `type ReviewLesson struct { ID, ProjectID int64; Lens, Text string; SourceCommentIDs []int64; Status string }`; `ReplaceProposedReviewLessons(projectID int64, ls []ReviewLesson) ([]ReviewLesson, error)` (tx: delete `proposed`, insert, return with ids); `ReviewLessons(projectID int64, status string) ([]ReviewLesson, error)`; `GetReviewLesson(projectID, id int64) (*ReviewLesson, error)`; `DecideReviewLesson(projectID, id int64, status string) (bool, error)` — `WHERE status='proposed'`, sets `decided_at`
  - `ReviewLessonInputComments(projectID int64, lastRounds int) ([]ReviewComment, error)` — comments of the workbench's newest `lastRounds` rounds with status `sent|delivered`, comment status `sent|resolved`, `carried_from IS NULL`, `path` any, and id not in any `accepted`/`dismissed` lesson's `source_comment_ids` (`json_each`)
  - `TerminalAgentWorking(sessionID int64) (bool, error)` — `agent_state = 'working'`
- `cmd/workbench_review.go` `reviewEnvelope` gains `Revert *reviewRevertJSON \`json:"revert,omitempty"\`` (`{hunk_id, path}`), `Overview json.RawMessage \`json:"overview,omitempty"\``, `OverviewCached bool \`json:"overview_cached,omitempty"\``, `Lessons []reviewLessonJSON \`json:"lessons,omitempty"\`` (`{id, lens, text, source_comment_ids, status}`), `Written string \`json:"written,omitempty"\``.

- [ ] **Step 1:** Re-check the migration number (Global Constraints). Write the migration with the `add-migration` skill; mirror into `schema.sql`; add the four tables to `TestAllTablesExist`; regenerate with `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`.
- [ ] **Step 2: Failing tests.** `TestMigration00125_ReviewAgentTables`: deleting the project removes rows of all four tables; deleting the terminal session leaves notes with `session_id` NULL; `kind='x'`, `status='x'`, `core=2` and a second `(round, hunk)` are rejected. In `review_agent_test.go`: `TestReplaceReviewNotes_ReplacesTheSessionsSetOnly` (another session's notes survive); `TestReviewOverview_PutAndGet` (miss → `false`; replace keeps one row); `TestAddReviewRevert_SecondIsAlreadyReverted`; `TestReplaceProposedReviewLessons_KeepsDecided`; `TestDecideReviewLesson_OnlyProposed` (second decide → false); `TestReviewLessonInputComments_ExcludesDraftsCarriedOpenAndDecided` (a draft, an open round's comment, a carried copy and a comment named by a dismissed lesson are out; 21 sent rounds → the oldest round's comments are out); `TestTerminalAgentWorking`.
- [ ] **Step 3: Run** `go test ./internal/db -run 'Review|Migration00125|AllTablesExist'` — FAIL; implement; run again plus `go build ./cmd/...` and `make lint-diff` — PASS.
- [ ] **Step 4: Commit** `feat(review): review_notes, overviews, reverts, lessons tables (board #328)`.

---

### Task 2: Go — Undo a hunk (`workbench review revert-hunk`)

**Depends on:** Task 1

**Files:** Create `internal/reviewdiff/revert.go`, `internal/reviewdiff/revert_test.go`, `cmd/workbench_review_revert.go`, `cmd/workbench_review_revert_test.go`; modify `internal/gitbin/run.go` (+ `run_test.go`), `internal/reviewdiff/diff.go` (`OldMode`), `internal/reviewdiff/guard_test.go`.

**Interfaces — Produces:**
- `File` gains `OldMode string \`json:"old_mode,omitempty"\`` (from the raw record).
- `type UndoRefused struct{ Msg string }` (an `error`); `type Reverted struct { Path, HunkID, Header, Patch string }`
- `func HunkPatch(f File, h Hunk) string` — `diff --git a/P b/P`, then `new file mode <NewMode>` + `--- /dev/null` for added, `deleted file mode <OldMode>` + `+++ /dev/null` for deleted, else `--- a/P` / `+++ b/P`; the header and lines verbatim (incl. `\ No newline at end of file`), trailing newline.
- `func (r *Repo) RevertHunk(ctx context.Context, d Diff, hunkID string) (Reverted, error)`.
- CLI `workbench review revert-hunk --workbench W --round R --hunk H [--since] --json` → `{ok, revert: {hunk_id, path}}` or `{ok:false, error}`.
- Refusal copy (exact): `the round is not open`; `the agent is working in this session — undo when it stops`; `hunk <H> is not in this round's diff`; `undo is not available for a <renamed|binary|symlink|submodule|too large|truncated> file`; `the file changed since this round's snapshot — refresh first`; `this hunk no longer applies to the file`; `this hunk was already undone in this round`.

- [ ] **Step 1: Failing tests** (`revert_test.go`, real temp repos via the package helpers):
  - `TestRevertHunk_ModifiedKeepsTheOtherHunk`: a file with two far-apart edits → revert one: that hunk's lines are back, the other edit stays.
  - `TestRevertHunk_AddedFileIsRemoved` and `TestRevertHunk_DeletedFileIsRestored` (content and mode back).
  - `TestRevertHunk_NoNewlineAtEOF`.
  - `TestRevertHunk_RefusesUnsupported` (table: renamed, binary, symlink, too large, truncated → each exact `UndoRefused` message).
  - `TestReview02_RefusedWhenFileChanged`: change the file after the snapshot → `the file changed…`; file bytes unchanged.
  - `TestReview02_CheckFailureAppliesNothing`: a `Runner` wrapper making `apply --check` exit 1 → `this hunk no longer applies…`; the recorded argv has no `apply` without `--check`.
  - `TestReview01_UndoWritesOnlyTheHunksFile`: `.git/index` bytes and every ref unchanged; `git status --porcelain` differs from before only in that path; no argv has `--index` or `--cached`.
  - `guard_test.go` `TestReview05_UndoRunsNothingFromTheFolder` (the filter driver and fsmonitor markers stay absent through `RevertHunk`); `run_test.go` `TestReadsContent_ApplyAndHashObject`.
- [ ] **Step 2: Failing CLI tests:** `TestWorkbenchReviewRevertHunk_RecordsOnce` (ok; a `review_reverts` row with header and patch; again → `already undone`); `TestWorkbenchReviewRevertHunk_SinceView` (a hunk id from the `--since` diff applies with `--since`); `TestWorkbenchReviewRevertHunk_RefusedWhileAgentWorking` (`agent_state='working'` by SQL → refused, file and table unchanged); `TestWorkbenchReviewRevertHunk_SentRoundRefused`; `TestWorkbenchReviewRevertHunk_RefusedUnderAgentMarkers` (each of `agentEnvMarkers`, file unchanged).
- [ ] **Step 3: Run** `go test ./internal/reviewdiff ./internal/gitbin -run 'Revert|Review0|ReadsContent' && go test ./cmd -run WorkbenchReviewRevert` — FAIL.
- [ ] **Step 4: Implement.** `contentReads` gains `apply`, `hash-object`. `RevertHunk`: find the hunk; refuse unsupported (`status` renamed, `Binary`, `NewMode`/`OldMode` 120000 or 160000, `CollapsedReason == "too_large"`, `Hunks == nil`); modified/added → lstat regular file and `git hash-object -- <path>` == `f.NewBlob`; deleted → lstat must be ENOENT; write `HunkPatch` into a file in a private `os.MkdirTemp` dir (removed after); `apply --check -R <file>` then `apply -R <file>`, cwd the folder root. CLI order: `refuseUnderAgent("undo a review hunk")` → round open → `TerminalAgentWorking` (session rounds only) → already-reverted lookup → `roundRange` → `Diff(from, round.TreeSHA)` → `RevertHunk` → `AddReviewRevert` (a failure here answers `undone, but not recorded: <err>`).
- [ ] **Step 5: Run** the Step 3 commands and `make lint-diff` — PASS.
- [ ] **Step 6: Commit** `feat(review): undo one hunk in the work tree (board #328)`.

---

### Task 3: Go — `annotate_changes`, `reply_review_comment`, reverts in `get_review`, skill pack v11

**Depends on:** Task 1

**Files:** Create `internal/tools/workbench_review_annotate.go`, `workbench_review_reply.go` + tests; modify `internal/tools/workbench_review.go` (+ test), `internal/tools/workbenches.go`, `internal/db/review_rounds.go` (`ReplyReviewComment`) + test, `cmd/workbench_review.go` (`sessionFolder` delegates), `internal/mcp/workbench_test.go`, `cmd/actions_registry_test.go`, `internal/devpack/workbenchskill/watchtower-workbench/SKILL.md`, the pack-marker tests in `internal/devpack/`.

**Interfaces — Produces:**
- `tools.ReviewSessionFolder(ctx context.Context, d *db.DB, p *db.Workbench, sessionID int64) (string, error)` — the body of cmd's `sessionFolder` + `checkSessionOnWorkbench` moved here; cmd calls it.
- `annotate_changes` args: `{notes: [{path, start_line, end_line, note}], chapters?: [{title, paths[], core, why}], reason}`. Limits: notes 0–40, `note` 1–800 runes; chapters 0–20, `title` 1–120 runes, `paths` 1–200, `why` ≤ 400 runes; `reason` 1–300 runes; at least one note or chapter. Execute: session folder → `Snapshot` → each note's path must be a file of T (`File`, not too large) with `1 ≤ start ≤ end ≤` its line count; `quote` = those lines; chapter paths trimmed and de-duplicated, not checked against the diff. `ReplaceReviewNotes`. Result `{tree_sha, notes, chapters}` and text `Stored <n> notes and <m> chapters for the current changes (tree <sha7>). They replace this session's earlier notes; the owner sees them in Review Changes.` No session → `annotate_changes needs a Watchtower terminal session`.
- `reply_review_comment` args: `{comment_id, reply (1–2000 runes), resolved, reason (1–300 runes)}`. `db.ReplyReviewComment(projectID, commentID int64, reply string, resolved bool) (bool, error)` — one tx: the comment must be in a `sent|delivered` round of the workbench with status `sent|resolved`; sets `agent_reply`, `agent_reply_at`, `status='resolved'` when `resolved`; then the same fields on its copies in the session's **open** round (`carried_from = id AND status IN ('carried','outdated')`). `resolved: false` never reopens. Refusal: `comment <id> is not in a sent review round of this workbench`.
- `get_review` view gains `reverts: [{hunk_id, path, header, patch}]`; its text, when any, ends with `Undone by the owner (reverted in the work tree — do not redo without asking):` and per revert `- <path> <header>` followed by the patch lines indented two spaces.

- [ ] **Step 1: Failing tests:**
  - `TestAnnotateChanges_StoresNotesWithQuotesAndReplaces`: temp repo workbench + session env; call with 2 notes and 1 chapter → rows with T's sha, quotes equal the file lines; a second call with 1 note → only that note remains.
  - `TestAnnotateChanges_RefusesBadInputWithoutWriting` (table: line past EOF, unknown path, empty note, 41 notes, no session env, a session of another workbench) → error, no `review_notes` row, no `agent_actions` row.
  - `TestReplyReviewComment_RepliesResolvesAndFollowsTheOpenCopy`: sent comment + its carried copy in an open round → both get the reply; `resolved:true` makes both `resolved`; an owner-`resolved` copy is untouched.
  - `TestReplyReviewComment_RefusesDraftsOpenRoundsAndOtherWorkbenches`.
  - `TestGetReview_ListsReverts` (text block as pinned above).
  - `internal/mcp/workbench_test.go` `TestWorkbenchMode_EachVocabularyListsFifteenToolsUnderItsOwnNames` now asserts **eighteen** (name kept); `TestBuildToolRegistry_PinsWriteToolsReadToolsAndSurfaces` pins both new writes on the workbench surface only.
- [ ] **Step 2: Run** `go test ./internal/tools -run 'Annotate|ReplyReview|GetReview' && go test ./internal/db -run ReplyReview && go test ./internal/mcp -run WorkbenchMode && go test ./cmd -run 'BuildToolRegistry|WorkbenchReview'` — FAIL.
- [ ] **Step 3: Implement** the Interfaces block; register both tools in `workbenchTools` after `NewGetReview()`.
- [ ] **Step 4: Skill pack.** Core `SKILL.md` marker `v10 → v11`; replace the "Review rounds" section with (exact copy):

```markdown
## Review rounds

The owner reviews your changes in Watchtower's diff reviewer and sends a round as one line: `Review round #N sent (K comments) — read it with get_review N …`. A waiting round is also listed in the session brief.

**Before you hand work back** (a task done, a PR opened, a stop for the owner):
- If the workbench folder has `.watchtower/review.md`, read it and check your changes against every rule in it.
- Call `annotate_changes` once: a note on each non-obvious change (why, not what) and, for more than ~400 changed lines, chapters in reading order (`core: true` for the heart of the change). Each call replaces your earlier notes for this session.

**When a round arrives:**
- Call `get_review N` first. Each comment names a file and lines of the snapshot the owner reviewed, with the quoted code; the code may have moved since — find it by the quote.
- Answer every comment with `reply_review_comment`: what you did, or why not. Pass `resolved: true` once it is fixed; the owner can reopen it.
- A design comment (no file) is about the approach as a whole; answer it before the line comments.
- Hunks listed as undone by the owner were reverted on purpose: do not redo them without asking.
- Do not ask the owner to re-review: they open the next round themselves.
```

  Update the pack tests that pin the marker (`internal/devpack/workbench_test.go` history comment + any `v10` assertion of the core); check that `methodology.go`'s pre-v10 upgrade rule still treats v11 as split (run its tests).
- [ ] **Step 5: Run** the Step 2 commands, `go test ./internal/devpack`, `make lint-diff` — PASS.
- [ ] **Step 6: Commit** `feat(review): annotate_changes, reply_review_comment, reverts in get_review, pack v11 (board #328)`.

---

### Task 4: Go — AI overview (`internal/reviewai`, `workbench review overview`)

**Depends on:** Task 1

**Files:** Create `internal/reviewai/{limits.go,pipeline.go,overview.go}`, `overview_test.go`, `testdata/overview_ok.json`, `cmd/workbench_review_overview.go`, `cmd/workbench_review_overview_test.go`; modify `internal/prompts/store.go`, `defaults.go`, `internal/digest/models_test.go`, `cmd/workbench_review_context.go`.

**Interfaces — Produces:**
- `type IntentItem struct { Text, Intent, Task string }`; `type Input struct { Intent []IntentItem; Notes []db.ReviewNote; Diff reviewdiff.Diff; LensIDs []string }`
- `type Overview struct { Summary string \`json:"summary"\`; Coverage []Coverage \`json:"coverage"\`; OutOfScope []string \`json:"out_of_scope"\`; Risk []Risk \`json:"risk"\`; Chapters []Chapter \`json:"chapters"\` }`, `Coverage{Item, Status ("done"|"partial"|"not_found"), Where []string}`, `Risk{Path, Level ("low"|"medium"|"high"), Why}`, `Chapter{Title, Paths []string, Core bool, Lenses []string}` (snake_case tags).
- `func IntentHash(items []IntentItem, notes []db.ReviewNote) string`
- `func BuildOverviewUser(in Input) string` (data part, caps from `limits.go`: `MaxOverviewFileLines = 300`, `MaxOverviewLines = 6000`)
- `func ParseOverview(raw string, in Input) (Overview, error)` — `prompts.ExtractJSONObject` → unmarshal → empty summary is an error; drop coverage/risk entries with unknown enums, paths not in `in.Diff` (from `where`, `out_of_scope`, `risk`, `chapters.paths`), lenses not in `LensIDs`; drop chapters left without paths; clip `summary` to 2,000 runes; caps coverage 50, risk 200, chapters 30.
- `type Pipeline struct`, `func New(gen digest.Generator) *Pipeline`, `func (p *Pipeline) SetPromptStore(s *prompts.Store)`, `func (p *Pipeline) Overview(ctx context.Context, in Input) (Overview, error)` — `prompts.Resolve(store, prompts.ReviewOverview, "")`, `digest.WithSource(ctx, "workbench.review_overview")`, session id `""`.
- `prompts.ReviewOverview = "review.overview"` (template v1: role "you brief a reviewer before they read an agent's changes", the exact JSON shape above, rules — coverage one entry per intent item, `where` only paths from the diff, risk for every changed file, chapters of at most ~400 changed lines with `core` and the relevant lens ids from the given list, no prose outside JSON; the data marker before the intent/notes/diff block).
- `cmd/workbench_review_context.go`: extract `reviewContextItems(ctx, database, p, sessionID) ([]reviewContextItem, error)` used by `context` and `overview`.
- CLI `workbench review overview --workbench W --round R --json` → `{ok, overview, overview_cached}` or `{ok:false, error:"AI overview unavailable: <reason>"}`; seam `var reviewAIGeneratorFactory = func(cfg *config.Config) digest.Generator { return cliBoundedGenerator(cfg) }`; the stored `model` is the resolved strong model id.

- [ ] **Step 1: Failing tests** (`reviewai`): `TestParseOverview_ValidFixture` (`testdata/overview_ok.json` → every field; the fixture is also Task 6's Swift decode fixture); `TestParseOverview_DropsUnknownPathsLensesAndEnums` (a `where` path not in the diff, a lens `perf`, a risk level `critical`, a chapter whose only path is unknown → each dropped, the rest kept); `TestParseOverview_RejectsInvalid` (not JSON, array root, empty summary); `TestBuildOverviewUser_CapsPerFileAndOverall` (a 1,000-line file is listed `(+1000 −0) — not shown`; 30 files of 300 lines stop at 6,000 and list the rest by name; collapsed files by name); `TestOverview_UsesPromptStoreAndSourceTag` (mock generator records `digest.SourceFrom(ctx)` == `workbench.review_overview` — use the package's existing accessor — and the stored template overrides the default); `TestIntentHash_ChangesWithANote`.
- [ ] **Step 2: Failing CLI tests:** `TestWorkbenchReviewOverview_CachesPerTreeBaseIntent` (counting fake factory: two calls → one generation, second `overview_cached:true`; link another target to the session → a second generation); `TestWorkbenchReviewOverview_FailureIsAnEnvelopeAndNotCached` (generator error → `ok:false` with the prefix, no row; next call generates); `TestWorkbenchReviewOverview_InvalidReplyNotCached`. Add `workbench.review_overview` to `TestTierForSource`'s strong list.
- [ ] **Step 3: Run** `go test ./internal/reviewai ./internal/digest -run 'Overview|Intent|TierForSource' && go test ./cmd -run 'WorkbenchReviewOverview|PromptStoreWiring'` — FAIL; implement with the `add-ai-prompt` skill (store id, `Defaults`, `AllIDs`, `DefaultVersions`, `SetPromptStore(prompts.New(database, nil))` at the cmd site); run again plus `make lint-diff` — PASS.
- [ ] **Step 4: Commit** `feat(review): AI overview with coverage, risk and chapters (board #328)`.

---

### Task 5: Go — Find repeats (`workbench review lessons propose|accept|dismiss`)

**Depends on:** Task 4

**Files:** Create `internal/reviewai/lessons.go` + test, `internal/reviewdiff/lessonfile.go` + test, `cmd/workbench_review_lessons.go` + test; modify `internal/prompts/store.go`, `defaults.go`, `internal/digest/models_test.go`.

**Interfaces — Produces:**
- `type Lesson struct { Lens, Text string; SourceCommentIDs []int64 }`; `func BuildLessonsUser(comments []db.ReviewComment, lenses []reviewdiff.Lens) string` (each comment as `#<id> [<lens>] <path or design>: <body>` with its quote); `func ParseLessons(raw string, inputIDs map[int64]bool, lensIDs []string) ([]Lesson, error)` — a lesson needs ≥ 2 distinct ids all in the input; unknown lens → `house_rules`; text trimmed, one line, 1–300 runes, a leading `#` or `- ` stripped; at most 20; `(p *Pipeline) Lessons(ctx, comments, lenses) ([]Lesson, error)` with `prompts.ReviewLessons = "review.lessons"`, source `workbench.review_lessons` (strong). Template v1: group comments that make the same point, one rule per group phrased as a checklist question ("Does …?"), JSON `{"lessons":[{"lens","text","source_comment_ids"}]}`.
- `func AppendLessonRule(workbenchFolder, lensName, text string) error` — `.watchtower`: missing → `os.Mkdir` 0o755; a symlink or non-directory → refuse. `review.md`: missing → created `O_CREAT|O_EXCL|O_NOFOLLOW` 0o644; present → read with Plan 2's `readLensFile` rules (any refusal → error). Insert `- <text>\n` after the last non-blank line of the section whose heading's `LensID` equals `LensID(lensName)`; no such section → append `\n## <lensName>\n- <text>\n` (a missing final newline added first; an empty file gets no leading blank line). Same question already there (`ItemKey`) → no write, nil. Result over `MaxLensFileBytes` → refuse. Write a temp file in `.watchtower` + `os.Rename`.
- CLI (`--workbench W [--lesson L] --json`): `propose` — `ReviewLessonInputComments(p.ID, 20)`; fewer than 2 → `{ok, lessons: []}` with no model call; lenses from `LoadLenses(p.FolderPath)`; `ReplaceProposedReviewLessons`; answers the proposed list. `accept` — `refuseUnderAgent("accept a review lesson")`; the lesson must be `proposed`; lens name from `LoadLenses` by id (`House rules` when absent); `AppendLessonRule`; then `DecideReviewLesson(accepted)`; `{ok, written: ".watchtower/review.md"}`. `dismiss` — `DecideReviewLesson(dismissed)`. Not proposed → `lesson <L> was already decided`.

- [ ] **Step 1: Failing tests:** `TestParseLessons_KeepsGroupsOfTwoOrMoreKnownIDs` (a single-id group and an unknown id are dropped; lens `perf` → `house_rules`; `"## Tests"` text stripped of `#`); `TestAppendLessonRule_InsertsUnderTheHeading` (`"## Tests\n- a\n\n## Docs\n- b\n"` + Tests/`new` → `"## Tests\n- a\n- new\n\n## Docs\n- b\n"`; lens `docs` matches `## Docs`; no file → `"## House rules\n- new\n"`; a file without a final newline; a duplicate → bytes unchanged); `TestAppendLessonRule_RefusesUnsafe` (symlinked `.watchtower`, symlinked `review.md`, a FIFO with a 2 s test timeout, a result over 64 KB → error, target bytes unchanged); `TestReview01_LessonAcceptWritesOnlyReviewMD` (in a temp repo: `.git/index` bytes, refs and every other path unchanged).
- [ ] **Step 2: Failing CLI tests:** `TestWorkbenchReviewLessons_ProposeFeedsOnlyFreshSentComments` (fake factory records the input ids: no carried copy, no dismissed source); `TestWorkbenchReviewLessons_ProposeWithFewCommentsCallsNoModel`; `TestWorkbenchReviewLessons_AcceptWritesAndDecides`; `TestWorkbenchReviewLessons_AcceptRefusedUnderAgentMarkers` (file absent, lesson still `proposed`); `TestWorkbenchReviewLessons_DecideOnlyProposed`. Add `workbench.review_lessons` to `TestTierForSource`'s strong list.
- [ ] **Step 3: Run** `go test ./internal/reviewai ./internal/reviewdiff -run 'Lesson|Review01' && go test ./cmd -run 'WorkbenchReviewLessons|PromptStoreWiring' && go test ./internal/digest -run TierForSource` — FAIL; implement; run again plus `make lint-diff` — PASS.
- [ ] **Step 4: Commit** `feat(review): find repeats and accept rules into .watchtower/review.md (board #328)`.

---

### Task 6: Swift core — models, queries, CLI calls

**Depends on:** Task 1 (schema); the envelopes as pinned in Tasks 2, 4, 5

**Files:** Modify `WatchtowerCore/Models/ReviewModels.swift`, `WatchtowerCore/Database/Queries/ReviewQueries.swift`, `Services/WorkbenchCLI.swift`. Test `Tests/Core/ReviewQueriesTests.swift`, `Tests/Core/ReviewModelsDecodeTests.swift` (or the existing decode test file).

**Interfaces — Produces:**
- `package struct ReviewNote: FetchableRecord, Decodable, Equatable, Sendable, Identifiable { id: Int64; kind: Kind (.note, .chapter); ord: Int; path: String; startLine, endLine: Int; quote, text: String; paths: [String] (decoded from paths_json); core: Bool; why: String; treeSHA: String }`
- `package struct ReviewOverview: Decodable, Equatable, Sendable { summary; coverage: [Coverage]; outOfScope: [String]; risk: [Risk]; chapters: [Chapter] }` with `Coverage { item; status: Status (.done, .partial, .notFound = "not_found"); where: [String] }`, `Risk { path; level: Level (.low, .medium, .high); why }`, `Chapter { title; paths; core; lenses: [String] }` — missing arrays decode as `[]`.
- `package struct ReviewRevert: FetchableRecord, Decodable, Equatable, Sendable { hunkID, path, header, at: String }`; `package struct ReviewLesson: FetchableRecord, Decodable, Equatable, Sendable, Identifiable { id: Int64; lens, text: String; sourceCommentIDs: [Int64]; status: String }`
- `ReviewEnvelope` gains `overview: ReviewOverview?`, `overviewCached: Bool?`, `revert: RevertInfo?` (`hunkId`, `path`), `lessons: [ReviewLesson]?`, `written: String?`. `ReviewComment` gains `agentReplyAt: String?`.
- `ReviewQueries.notes(_ db: Database, projectID: Int64, sessionID: Int64) throws -> [ReviewNote]`; `reverts(_:roundID:) -> [ReviewRevert]`; `proposedLessons(_:projectID:) -> [ReviewLesson]`; `agentResolved(_:previousRoundID: Int64, openRoundID: Int64) -> [ReviewComment]` — rows of either round with status `resolved` and `agent_reply_at` set, an open-round copy shadowing its source; `reopen(_:commentID: Int64, openRoundID: Int64) throws` — a resolved copy in the open round → `carried` (`draft` when it has no `carried_from`); a resolved source in the previous round → its open-round copy back to `carried`, else a new `carried` copy with its anchor fields and `carried_from` (the carry insert Plan 1 uses); refused (no-op) when the round is not open.
- `WorkbenchCLI.reviewOverview(projectID:roundID:)`, `reviewRevertHunk(projectID:roundID:hunkID:since:)`, `reviewLessons(projectID:action: LessonAction (.propose, .accept(Int64), .dismiss(Int64)))` — overview and propose with a 330 s timeout (add a per-call timeout parameter to the runner call if it has only one).

- [ ] **Step 1: Failing tests:** `testOverviewDecodesTheGoFixture` (reads `internal/reviewai/testdata/overview_ok.json` the way `ReviewDeliveryLineTests` reads Go fixtures; every field equal); `testNotesDecodePathsJSON`; `testRevertsInRoundOrder`; `testAgentResolvedListsOnlyAgentResolved` (owner-resolved left out; the copy shadows its source); `testReopenInsertsACarriedCopy`, `testReopenRestoresTheOpenCopy`, `testReopenRefusedOnSentRound`.
- [ ] **Step 2: Run** `make test-swift FILTER='ReviewQueriesTests|ReviewModelsDecodeTests'` — FAIL; implement; run again plus `make lint-swift` — PASS.
- [ ] **Step 3: Commit** `feat(review): Swift core models and queries for notes, overview, undo, lessons (board #328)`.

---

### Task 7: Swift core — chapter sources, lenses per chapter, coverage items, note placement

**Depends on:** none (Plan 2's `ReviewChapters`, `ReviewWrapUp`, `ReviewLens`)

**Files:** Modify `WatchtowerCore/Services/Review/ReviewChapters.swift`, `ReviewWrapUp.swift`, `ReviewCommentAnchor.swift`; create `ReviewNotePlacement.swift`. Tests `Tests/Core/ReviewChaptersTests.swift`, `ReviewWrapUpTests.swift`, `ReviewNotePlacementTests.swift`.

**Interfaces — Produces:**
- `ReviewChapter` gains `source: Source` (`enum Source: String { case agent, ai, mechanical }`, default `.mechanical`) and `lenses: [String]?` (nil = all), both defaulted in `init`.
- `package struct ReviewChapterSpec: Equatable, Sendable { title: String; paths: [String]; core: Bool; lenses: [String]? }`
- `ReviewChapters.resolve(_ files: [ReviewDiffFile], agent: [ReviewChapterSpec], ai: [ReviewChapterSpec]) -> [ReviewChapter]` — per Global Constraints; paths filtered to `files` (a path named twice stays in its first chapter); core chapters first, stable; tests first inside a chapter; leftovers via `mechanical(_:)` appended; `changedLines` summed.
- `ReviewChapters.lenses(for chapter: ReviewChapter, all: [ReviewLens]) -> [ReviewLens]` — in `all`'s order.
- `ReviewChapters.estimateMinutes(changedLines: Int) -> Int` — `ceil(lines × 60 / 400)`, 0 for 0.
- `ReviewIntentItem` gains `aiStatus: String?` (default nil); `ReviewWrapUp.intentItems(_ context: [ReviewContextItem], coverage: [(item: String, status: String)]) -> [ReviewIntentItem]` — non-empty coverage → one per entry, key `cov:` + first 16 hex of sha256(item text), `aiStatus` the raw status; else Plan 2's rule. A tuple, not `ReviewOverview.Coverage`, because Task 7 runs before Task 6 (Wave 1); Task 8 maps the overview into it.
- `ReviewCommentAnchor.locate(quote: String, prefix: String, suffix: String, in text: String) -> Placement?` — extracted from `plan(_:textFor:)`, which now calls it.
- `package enum ReviewNotePlacement { static func place(_ notes: [(id: Int64, quote: String, startLine: Int, endLine: Int, treeSHA: String)], currentTree: String, textFor: (Int64) -> String?) -> [Int64: ReviewCommentAnchor.Placement] }` — same tree → stored lines; else `locate(quote:prefix:"",suffix:"",in:)`; not found → absent.

- [ ] **Step 1: Failing tests:** `testAgentChaptersWinOverAI`; `testAIChaptersWhenNoAgentChapters` (keys `ai:1…`, lenses carried); `testUnknownPathsDroppedAndEmptyChapterSkipped`; `testLeftoverFilesGoToMechanicalChaptersAfter`; `testCoreFirstAndTestsFirstInside`; `testAllSourcesEmptyIsMechanical` (equals `mechanical(files)`); `testLensesForAIChapterKeepHouseRulesAndOwnerLenses` (AI marks `tests` → `tests`, `house_rules`, `docs`); `testLensesForMechanicalAreAll`; `testEstimateMinutes` (0→0, 1→1, 400→60, 1000→150); `testIntentItemsFromCoverage` (keys stable for the same text, `aiStatus` set; empty coverage → `target:` items); `ReviewNotePlacementTests` `testSameTreeKeepsLines`, `testMovedQuoteFollows`, `testLostQuoteIsAbsent`; existing `ReviewCommentAnchorTests` unchanged and green.
- [ ] **Step 2: Run** `make test-swift FILTER='ReviewChaptersTests|ReviewWrapUpTests|ReviewNotePlacementTests|ReviewCommentAnchorTests'` — FAIL; implement; run again plus `make lint-swift` — PASS.
- [ ] **Step 3: Commit** `feat(review): agent and AI chapter sources, lenses per chapter, note placement (board #328)`.

---

### Task 8: `ReviewChangesModel` and `ReviewLessonsModel`

**Depends on:** Tasks 2, 4, 5, 6, 7

**Files:** Modify `ViewModels/ReviewChangesModel.swift`; create `ViewModels/ReviewLessonsModel.swift`. Tests `Tests/ReviewChangesModelTests.swift` (extend, reuse its fake CLI), `Tests/ReviewLessonsModelTests.swift`.

**Interfaces — Produces** (`private(set)` unless noted):
- `init(…, isAgentWorking: @escaping @MainActor () -> Bool)` — wired by the pane from `SessionAgentStateCenter.statuses[sessionID]` (working, or the Agents working presentation).
- `overview: OverviewState` (`.idle, .loading, .ready(ReviewOverview), .failed(String)`); `func loadOverview() async` — started (not awaited) by `open()` and by a refresh that changed the tree, cancelled when the round changes; `func retryOverview()`.
- `notes: [ReviewNote]`, `notePlacements: [Int64: ReviewCommentAnchor.Placement]` (for the selected file); chapters now `ReviewChapters.resolve(files, agent: <note chapters>, ai: <overview chapters>)`.
- `aiChaptersPending: Bool`; `func useAIChapters()` — when the overview lands while `phase == .chapters` and a check exists for a current chapter key, chapters are kept and `aiChaptersPending = true`; otherwise they switch (Plan 2's vanished-chapter rule applies).
- `intentItems` from `ReviewWrapUp.intentItems(context, coverage:)` when the overview is ready.
- `func risk(for path: String) -> ReviewOverview.Risk?`; `var estimateMinutes: Int`.
- `reverts: [ReviewRevert]`; `var canUndo: Bool` (round open, not sending, `!isAgentWorking()`); `func undo(hunkID: String) async` — refused locally while the agent works (`lastError` `The agent is working in this session — undo when it stops.`, no CLI call); else CLI → on ok reload reverts and `refresh()`; on `ok:false` `lastError` = Go's text.
- `agentResolved: [ReviewComment]`; `func reopen(_ id: Int64) throws`; a comment's shown reply = its own `agentReply`, else its `carried_from` row's.
- `ReviewLessonsModel(projectID:cli:db:)`: `lessons: [ReviewLesson]`, `finding: Bool`, `lastError: String?`; `func load() throws`, `func findRepeats() async`, `func accept(_ id: Int64) async`, `func dismiss(_ id: Int64) async` (each reloads).

- [ ] **Step 1: Failing tests:** `testOpenStartsTheOverviewAndChaptersFollowIt`; `testOverviewFailureKeepsMechanicalChaptersAndShowsTheReason`; `testAgentChaptersWinOverAI`; `testAIChaptersDoNotReplaceChaptersWithChecks` (then `useAIChapters()` switches); `testWrapUpUsesCoverageItems`; `testUndoRefusedWhileAgentWorkingCallsNoCLI`; `testUndoReloadsRevertsAndRefreshes`; `testUndoRefusalShowsGoText`; `testReopenAgentResolvedComment`; `testCarriedCommentShowsSourceReply`; `ReviewLessonsModelTests` `testFindRepeatsListsProposals`, `testAcceptAndDismissReload`, `testAcceptRefusalSetsLastError`.
- [ ] **Step 2: Run** `make test-swift FILTER='ReviewChangesModelTests|ReviewLessonsModelTests'` — FAIL; implement; run again plus `make lint-swift` — PASS.
- [ ] **Step 3: Commit** `feat(review): overview, agent notes, undo and lessons in the review models (board #328)`.

---

### Task 9: Views and the diff editor

**Depends on:** Task 8

**Files:** As listed under File Structure (Swift views, `diff.js`, `MonacoDiffView.swift`, `scripts/editor-bridge-check.swift`).

- [ ] **Step 1: `diff.js`.** `wt.setNotes([{startLine, endLine, text}])` — read-only view zones above `startLine` in the modified editor (class `wt-note`, label `Agent note`), replacing the previous set; `wt.setHunks([{id, newStart, canUndo, reason}])` — a one-line zone above each hunk with an **Undo** button posting `{type: "undo", hunkId}`; a disabled button carries `reason` as its title. Both `textContent` only; both cleared by `showDiff`. `MonacoDiffView` handles `undo` only for a hunk id matching `^[0-9a-f]{16}$` that is in the selected file. Extend `scripts/editor-bridge-check.swift` with `setNotes`/`setHunks` and the `undo` message.
- [ ] **Step 2: Overview** (`ReviewOverviewView`): loading spinner "Preparing the AI overview…"; failed → the reason + **Retry**; ready → summary, coverage (item, status icon, where links selecting the file), "Outside the intent" files, size `<n> changed lines · about <m> min`. In Deep it sits in Meaning above the intent card, with the agent's notes as a walkthrough list (file:lines, note, "no longer in the file" when unplaced); in Quick a collapsed `DisclosureGroup` (first line of the summary + counts of high/medium risk) and the reading order (chapter titles) above the file list.
- [ ] **Step 3: Chapters and files.** Risk badge per file (high red, medium orange, none for low); chapter source caption (`by the agent` / `by AI`), a star for core; the banner "AI chapters are ready" + **Use them** while `aiChaptersPending`; `ReviewChecklistView` uses `ReviewChapters.lenses(for:all:)`.
- [ ] **Step 4: Comments and Undo.** In `ReviewCommentListView`: each comment's agent reply; a **Resolved by the agent** group with **Reopen**; an **Undone** list (`path header`). Wrap-up's summary shows the Undone list too. Hunk Undo zones get `canUndo` and, when false, the reason (`Undo is off while the agent is working`, `Round already sent`).
- [ ] **Step 5: Find repeats.** Header menu **Find Repeats…** opens `ReviewLessonsSheet`: progress while `finding`; each proposal with lens, text, "from <n> comments", **Accept** / **Dismiss**; empty state `No repeated comments found in the last 20 rounds.`; `lastError` inline.
- [ ] **Step 6: Check.** `make test-swift FILTER='ReviewChangesModelTests|ReviewLessonsModelTests|ReviewChaptersTests'`, `make lint-swift`, `bash scripts/editor-bridge-check.sh`; then the app (`run` skill): a session that called `annotate_changes`, open Review Changes — notes in the diff, agent chapters in Deep, the overview arriving, a risk badge; Undo one hunk while the agent is idle and see it listed; Find Repeats with two similar sent comments, Accept, and see the rule after Refresh in the checklist. Screenshots to the controller.
- [ ] **Step 7: Commit** `feat(review): overview, notes, undo and find repeats in the Changes pane (board #328)`.

---

### Task 10: Docs and inventory

**Depends on:** Tasks 1–9

- [ ] **Step 1:** `docs/inventory/review.md`: REVIEW-01 amended (Undo and Accept, refused under agent markers; guards `TestReview01_UndoWritesOnlyTheHunksFile`, `TestReview01_LessonAcceptWritesOnlyReviewMD`, `TestWorkbenchReviewRevertHunk_RefusedUnderAgentMarkers`, `TestWorkbenchReviewLessons_AcceptRefusedUnderAgentMarkers`); **REVIEW-02** (guards `TestReview02_RefusedWhenFileChanged`, `TestReview02_CheckFailureAppliesNothing`, `TestWorkbenchReviewRevertHunk_RefusedWhileAgentWorking`, `testUndoRefusedWhileAgentWorkingCallsNoCLI`); REVIEW-03 amended (agent resolution, Resolved by the agent + Reopen; guards `TestReplyReviewComment_RepliesResolvesAndFollowsTheOpenCopy`, `testAgentResolvedListsOnlyAgentResolved`, `testReopenInsertsACarriedCopy`); REVIEW-05 supporting guards; module list gains `00125`, `internal/reviewai/`, the new cmd files; changelog line naming the owner's approval ask. `dev-surface.md` DEV-06: eighteen tools + changelog. `workbench.md`: PROJ-04 changelog (pack v11). `agent-actions.md`: confirm no change needed (both tools are ordinary audited workbench writes) and say so in the review changelog.
- [ ] **Step 2:** Feature note: title `(2026-10-16, Plans 1–3 of 3)`; a "What Plan 3 ships" section (tables, Undo rules and refusals, overview cache key/caps/validation/failure, chapter sources and lenses per chapter, coverage-based intent items, the two tools and pack v11, reverts in `get_review`, Find repeats input and the rule-file write); v1 limits updated (Keep is implicit, no LFS-aware undo, one notes set per session). `CLAUDE.md` feature line `(… Plans 1–3 of 3)`; the spec's status line.
- [ ] **Step 3:** Commit `docs(review): agent tools, AI overview, undo, find repeats (board #328)`.

---

## Phase gate (controller, once, after Task 10)

`make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`; then an owner check (an ask with a checklist): the agent annotates and the notes and chapters show; the overview appears on round open and its failure (provider off) leaves the review usable; Undo one hunk, see it in `get_review`; the agent replies and resolves a comment, the owner reopens it; Find Repeats → Accept → the rule is in `.watchtower/review.md` and in the checklist. The inventory amendments above are approved in that ask before the PR.
