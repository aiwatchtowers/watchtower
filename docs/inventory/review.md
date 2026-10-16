# Diff reviewer — Behavior Inventory

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/reviewdiff/`, `internal/db/review_rounds.go`,
> `cmd/workbench_review*.go`, `internal/tools/workbench_review.go`,
> `WatchtowerDesktop/Sources/WatchtowerCore/Services/Review/`,
> `WatchtowerDesktop/Sources/ViewModels/ReviewChangesModel.swift`, or the review parts
> of `internal/gitbin/run.go` and `cmd/workbench_brief.go`, read this file first.
> Any proposed change that would break a guard test or remove a contract must be
> raised as a question before touching code.

**Module:** `internal/reviewdiff/` + `internal/db/review_rounds.go` + `internal/db/migrations/00119_*.sql` + `cmd/workbench_review.go` + `cmd/workbench_review_context.go` + `internal/tools/workbench_review.go` + `internal/gitbin/run.go` + `WatchtowerDesktop/Sources/WatchtowerCore/{Models/ReviewModels.swift,Database/Queries/ReviewQueries.swift,Services/Review/}` + `WatchtowerDesktop/Sources/ViewModels/ReviewChangesModel.swift`
**Last full audit:** 2026-10-16 (created)
**Owner approval:** spec review ask #179 (2026-10-16), board #328; spec `docs/superpowers/specs/2026-10-16-workbench-diff-reviewer-design.md` §13.

> REVIEW-02 (Undo) is reserved for Plan 3 and does not exist yet. Plan 3 also adds
> lessons; both are owner-pressed writes and amend REVIEW-01 when they land.

---

## REVIEW-01 — the reviewer never writes a ref, the owner's index or a work-tree file

**Status:** Enforced (Go). Plan 1 has no writer at all; Plan 3 adds Undo and
lessons as the two owner-pressed exceptions and amends this entry.

**Observable:** Opening, refreshing or diffing a review (`workbench review
start|diff|file|send|context`) only reads the folder. The snapshot of the work
tree (tracked and untracked files, not ignored ones) is built through a private
temporary index (`GIT_INDEX_FILE` in a fresh temp directory, removed
afterwards): seeded from a copy of the owner's index (read, never written —
copied into the temp directory; `read-tree HEAD` instead for a split index or a
failed copy), then `add -A`, `write-tree`; both seeds give the same tree. The
repo's split-index config is overridden for the temp index (`core.splitIndex=false` through
`GIT_CONFIG_*` env), so no `sharedindex.*` file appears in the owner's `$GIT_DIR`. The
only things written are git objects; no ref is created or moved, the owner's
`.git/index` keeps its bytes, and no work-tree file changes. The diff and the file sides are read
from tree objects (`diff-tree`, `cat-file`), never from the work tree. A folder
that is not a repository answers an envelope, writes nothing.

**Why locked:** The reviewer runs over the owner's live work while an agent may
be editing it. A staged file, a moved ref or a rewritten file under the owner's
hands is a loss they cannot see coming; a temporary index and loose objects
(collected by git's own gc) cost nothing visible.

**Test guards:**
- `internal/reviewdiff/snapshot_test.go::TestReview01_SnapshotWritesNoRefNoIndex` (untracked files are in the tree; the index bytes and every ref are unchanged)
- `internal/reviewdiff/snapshot_test.go::TestReview01_SnapshotWritesNoSharedIndex` (`core.splitIndex=true`, and an already split owner index with `sharedIndexExpire`: the files in `.git` outside `objects/` and the index bytes are unchanged)
- supporting: `TestSnapshot_NoCommitYet`, `TestSnapshot_OwnerIndexSeedMatchesReadTree` (both seeds, the owner's index bytes unchanged, split index falls back), `TestSnapshot_DoneContextIsAnError`, `TestTreeExists`, `TestBase_MergeBaseWithDefaultBranch` (`internal/reviewdiff`); `internal/gitbin/run_test.go::TestExecEnv_KeepsCallerIndexDropsInherited`

**Locked since:** 2026-10-16

---

## REVIEW-03 — a review comment is never silently lost across rounds

**Status:** Enforced (Desktop)

**Observable:** When the owner opens the next round of a session, every comment
of the previous round that is not resolved goes with it: it is copied into the
new open round as `carried` (its `carried_from` pointing at the original, its
anchor moved to the new snapshot when the quoted lines moved —
`ReviewCommentAnchor`), or, when its quote is gone or its file is gone, kept as
`outdated` with its quote and body still showing; a comment already `outdated`
goes on as `outdated` with its quote. A design comment (no file)
never moves. Nothing is dropped: a comment leaves the owner's list only by the
owner resolving it (`resolve`, including deleting a carried one, which resolves
it so that reopening does not carry it again). Sent rows are immutable;
`outdated` rows are never sent. A sent round takes no new or edited comment
(the Desktop refuses it), and the next round is opened only by `open()` — the
path that carries: Refresh on a sent round opens the next one, and Go's
`start --refresh` with no open round answers `ok: false` and creates nothing. Old-side comments are refused in the "Since
round N" view, where the old side is not the base.

**Why locked:** The point of rounds is that a remark survives the agent's edit.
A comment that vanishes because the line moved teaches the owner not to trust
the tool, and they cannot notice an absence.

**Test guards:**
- `WatchtowerDesktop/Tests/Core/ReviewQueriesTests.swift::testReview03_CarryNeverDropsAComment` (moved copies, lost outdated, nothing disappears)
- `WatchtowerDesktop/Tests/ReviewChangesModelTests.swift::testSendThenRefreshOpensTheNextRoundAndCarries` (no comment into a sent round; Refresh after Send opens the next round, carrying comments and Viewed marks)
- supporting: `ReviewQueriesTests` (`testCarryKeepsOutdatedAndLeavesResolvedBehind`, `testReplaceMovesAndMarkOutdatedKeepsTheRow`, `testResolveClosesCarriedAndOutdatedOnly`, `testDraftLifecycleAndSentRowsAreImmutable`); `WatchtowerDesktop/Tests/Core/ReviewCommentAnchorTests.swift` (`testLostWhenQuoteGone`, `testLostWhenFileGone`, `testMovedWhenLinesShift`, `testDesignCommentNeverMoves`); `WatchtowerDesktop/Tests/ReviewChangesModelTests.swift` (`testNewRoundCarriesPreviousComments`, `testDeletingACarriedCommentResolvesItAndReopenDoesNotCarryAgain`, `testRefreshMovesAndOutdatesDrafts`, `testOldSideCommentIsRefusedInTheSinceView`); `cmd/workbench_review_test.go::TestWorkbenchReview_RefreshNeverCreatesARound`

**Locked since:** 2026-10-16

---

## REVIEW-04 — a round's delivery is stored before anything is typed, and the line goes only through PROJ-12's gates

**Status:** Enforced (Go and Desktop — a dual path)

**Observable:** Send is one guarded transaction first — `workbench review send`
(`db.SendReviewRound`): the open round becomes `sent` and its draft and carried
comments become `sent` together; a round that is not open, or belongs to
another workbench, writes nothing (`ok` false). A session has at most one open
round (unique index `review_rounds_one_open`). Only after that call returned
does the Desktop type anything: the fixed line `Review round #<id> sent (<n>
comment[s]) — read it with get_review <id> using the watchtower-workbench
skill.` (Swift `ReviewDeliveryLine`, Go `reviewdiff.DeliveryLine`, pinned by
`internal/reviewdiff/testdata/lines`) goes through `SessionLineDelivery` with
`LineKey.review`, under exactly PROJ-12's gates (hooks reported this run, no
permission prompt, no half-typed owner text, one delivery per session at a
time). The line holds an id and a count, never owner or agent text. A second
Send of the same round, or a Send that finds the round already sent, types
nothing (the latter shows "This round was already sent"). If the line is not delivered (the session is gone or held), the round
stays `sent` and the brief carries `Review round #N waiting (<n> comment[s]) →
get_review N`, rendered with the rules block and never cut.

**Scope exception (AGENT-06):** `get_review` is a read tool whose one write —
`sent → delivered` (`MarkReviewRoundDelivered`) — is not audited, exactly like
`get_ask`. It is bound to the session's workbench and writes nothing for a
round of another workbench, an open round or a draft.

**Why locked:** A line typed before the round is stored sends the agent to read
a round that does not exist; two lines pasted into one prompt are one message;
a stray Return can confirm a permission dialog. Same reasons as PROJ-12, which
this entry reuses rather than restates.

**Test guards:**
- `internal/db/review_rounds_test.go::TestReview04_SendIsGuardedAndStoredBeforeTheLine`
- `WatchtowerDesktop/Tests/ReviewChangesModelTests.swift::testReview04_SendTypesOnce`
- supporting: `TestReviewRounds_RefusedSendFromAnotherWorkbenchWritesNothing`, `TestReviewRounds_SendIncludesCarried` (`internal/db`); `internal/reviewdiff/line_test.go::TestDeliveryLine_Fixtures`; `WatchtowerDesktop/Tests/Core/ReviewDeliveryLineTests.swift::testMatchesGoFixtures`; `WatchtowerDesktop/Tests/SessionLineDeliveryReviewTests.swift`; `ReviewChangesModelTests` (`testAlreadySentTypesNothing`, `testRefusedSendSetsLastError`); `internal/tools/workbench_review_test.go` (`TestGetReview_ReadsCommentsAndMarksDelivered`, `TestGetReview_OtherWorkbenchRefused`, `TestGetReview_OpenRoundAndDraftsStayHidden`)

**Locked since:** 2026-10-16

---

## REVIEW-05 — every git call of the reviewer runs with the background-read hardening; none runs a filter driver, hook or fsmonitor from the folder

**Status:** Enforced (Go)

**Observable:** The folder is the owner's to bind, not ours to trust. Every git
process of the reviewer (`reviewdiff.Repo.git`, via `gitbin.ExecEnv`) runs with
the read hardening of `internal/gitbin` (`core.fsmonitor=false`,
`core.hooksPath=/dev/null`, no signature display, inherited repository
variables dropped), and the calls that read file content — `add`, `write-tree`
and `diff-tree -p` — additionally blank the folder's `filter.*` drivers
(`gitbin.ReadArgsIn`, the unexported `readsContent`), so a clean/smudge/process filter or an
fsmonitor named in the folder's own `.git/config` or `.gitattributes` never
runs. A scanner error while splitting the patch fails the whole diff instead of
returning a partial one; a type change consumes two patch sections.

**Why locked:** A config in a repository an agent just worked in can name
commands; running one from a background snapshot would execute whatever the
agent (or a cloned repository) planted, with no owner action.

**Test guards:**
- `internal/reviewdiff/guard_test.go::TestReview05_SnapshotAndDiffRunNothingFromTheFolder` (a filter driver and an fsmonitor named by the folder never run through snapshot, diff and file)
- supporting: `internal/gitbin/run_test.go` (`TestReadArgsIn_BlanksTheFoldersFilterDrivers`, `TestReadsContent` (the unexported `readsContent`), `TestReadsContent_AddAndPatchDiffTree`, `TestReadArgsIn_NoFilterIsReadArgs`); `internal/reviewdiff/diff_test.go` (`TestDiff_TypeChangeToSymlink`, `TestSplitSections_LineOverMaxIsAnError`)

**Locked since:** 2026-10-16

---

## Changelog

- 2026-10-16 (board #328, diff reviewer Plan 1, spec review ask #179): file created with REVIEW-01, 03, 04, 05. REVIEW-02 (Undo) reserved for Plan 3. PROJ-12 amended to cover the round line (see `workbench.md`).
- 2026-10-16 (board #328, final review fix wave): REVIEW-01 — the temp index is seeded from a read-only copy of the owner's index (read-tree HEAD fallback). REVIEW-03 — outdated rows are carried as outdated; a sent round takes no comment and only `open()` opens the next round (`start --refresh` never creates one). REVIEW-04 — Go's `sent: false` now shows "This round was already sent"; `get_review` marks delivered only after the comments read.
- 2026-10-16 (board #328, owner ask #183): REVIEW-01 — the temp index is forced unsplit (`core.splitIndex=false` via `GIT_CONFIG_*` env); no `sharedindex.*` is written into the owner's `$GIT_DIR`.
