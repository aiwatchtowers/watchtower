# Diff reviewer — Behavior Inventory

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/reviewdiff/`, `internal/reviewai/`,
> `internal/db/review_rounds.go`, `internal/db/review_agent.go`,
> `cmd/workbench_review*.go`, `internal/tools/workbench_review*.go`,
> `WatchtowerDesktop/Sources/WatchtowerCore/Services/Review/`,
> `WatchtowerDesktop/Sources/ViewModels/ReviewChangesModel.swift`, or the review parts
> of `internal/gitbin/run.go` and `cmd/workbench_brief.go`, read this file first.
> Any proposed change that would break a guard test or remove a contract must be
> raised as a question before touching code.

**Module:** `internal/reviewdiff/` + `internal/reviewai/` + `internal/db/review_rounds.go` + `internal/db/review_agent.go` + `internal/db/migrations/{00121,00124,00128}_*.sql` + `cmd/workbench_review.go` + `cmd/workbench_review_context.go` + `cmd/workbench_review_{revert,overview,lessons}.go` + `internal/tools/workbench_review{,_annotate,_reply}.go` + `internal/gitbin/run.go` + `WatchtowerDesktop/Sources/WatchtowerCore/{Models/ReviewModels.swift,Database/Queries/ReviewQueries.swift,Services/Review/}` + `WatchtowerDesktop/Sources/ViewModels/ReviewChangesModel.swift`
**Last full audit:** 2026-10-16 (created; Plan 3 amendments the same day)
**Owner approval:** spec review ask #179 (2026-10-16), board #328; spec `docs/superpowers/specs/2026-10-16-workbench-diff-reviewer-design.md` §13; Plan 3 amendments (REVIEW-01/03 amended, REVIEW-02 new, REVIEW-05 strengthened) ask #214.

---

## REVIEW-01 — the reviewer never writes a ref or the owner's index, and writes a work-tree file only on the owner's Undo or Accept

**Status:** Enforced (Go). Amended 2026-10-16 (Plan 3, ask #214): Undo and
Accept are the two owner-pressed writes.

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
that is not a repository answers an envelope, writes nothing. The AI overview
(`review overview`) and Find repeats (`review lessons propose`) write only
database rows (`review_overviews`, `review_lessons`), never a file.

The two exceptions, both pressed by the owner in the Desktop:
- **Undo** (`workbench review revert-hunk`, `reviewdiff.Repo.RevertHunk`)
  writes one work-tree file — the file of the one hunk taken back — with
  `git apply -R` run from the repository top (`git rev-parse
  --show-toplevel`), never with `--index` or `--cached`: the owner's index and
  every ref stay as they were. A path whose parent directory is a symlink is
  refused ("undo is not available for a symlink file"), so the apply cannot
  write or unlink outside the repository; renamed, binary, symlink, submodule,
  too-large and truncated files are refused too. REVIEW-02 holds its
  preconditions. The undone hunk is recorded in `review_reverts` (one row per
  `(round_id, hunk_id)`; a second Undo of it is refused).
- **Accept** (`workbench review lessons accept`, `reviewdiff.AppendLessonRule`,
  its only writer) writes `.watchtower/review.md` in the **workbench folder**
  (`projects.folder_path`): `- <rule>` under the lens's `## <name>` heading
  (created when missing, the file too). `.watchtower` must be a real directory
  (lstat; created when absent) and an existing `review.md` a regular file read
  under the Plan 2 lens-file rules (no symlink, `O_NOFOLLOW|O_NONBLOCK`, fstat
  re-check, at most 65,536 bytes); a result over 64 KB is refused; a rule
  already in the lens writes nothing. When `review.md` is absent it is created
  with `O_EXCL|O_NOFOLLOW`; otherwise the new text goes to a temp file in
  `.watchtower` renamed over it. A refusal writes nothing and the
  lesson stays `proposed`.

Both commands refuse to run under an AI agent's environment marker
(`refuseUnderAgent`, the AGENT-07 marker set) and, without one, run only after
the owner's Confirm in the running Desktop (`confirmWithOwner`, board #568; the
Desktop's own press is confirmed at once, the window shows the hunk or the
lesson text), so "owner-pressed" holds: an agent in the session cannot undo a
hunk or write a house rule through the CLI.

**Why locked:** The reviewer runs over the owner's live work while an agent may
be editing it. A staged file, a moved ref or a rewritten file under the owner's
hands is a loss they cannot see coming; a temporary index and loose objects
(collected by git's own gc) cost nothing visible. Undo and Accept are writes the
owner asked for, one file each; an agent able to run them would turn the
reviewer into an unreviewed write path.

**Test guards:**
- `internal/reviewdiff/snapshot_test.go::TestReview01_SnapshotWritesNoRefNoIndex` (untracked files are in the tree; the index bytes and every ref are unchanged)
- `internal/reviewdiff/snapshot_test.go::TestReview01_SnapshotWritesNoSharedIndex` (`core.splitIndex=true`, and an already split owner index with `sharedIndexExpire`: the files in `.git` outside `objects/` and the index bytes are unchanged)
- `internal/reviewdiff/revert_test.go::TestReview01_UndoWritesOnlyTheHunksFile` (only the hunk's file changes; the index bytes and every ref are unchanged)
- `internal/reviewdiff/lessonfile_test.go::TestReview01_LessonAcceptWritesOnlyReviewMD` (only `.watchtower/review.md` changes)
- `cmd/workbench_review_revert_test.go::TestWorkbenchReviewRevertHunk_RefusedUnderAgentMarkers`, `cmd/workbench_review_lessons_test.go::TestWorkbenchReviewLessons_AcceptRefusedUnderAgentMarkers` (per marker: refused, the file and the rows unchanged)
- supporting: `TestSnapshot_NoCommitYet`, `TestSnapshot_OwnerIndexSeedMatchesReadTree` (both seeds, the owner's index bytes unchanged, split index falls back), `TestSnapshot_DoneContextIsAnError`, `TestTreeExists`, `TestBase_MergeBaseWithDefaultBranch` (`internal/reviewdiff`); `internal/gitbin/run_test.go::TestExecEnv_KeepsCallerIndexDropsInherited`; Undo: `TestRevertHunk_RefusesASymlinkedParent`, `TestRevertHunk_FromASubfolderWorksAtTheTop`, `TestRevertHunk_RefusesUnsupported`, `TestRevertHunk_ModifiedKeepsTheOtherHunk`, `TestRevertHunk_AddedFileIsRemoved`, `TestRevertHunk_DeletedFileIsRestored`, `TestRevertHunk_NoNewlineAtEOF`, `TestRevertHunk_OddPathRoundTrips` (`internal/reviewdiff`), `TestWorkbenchReviewRevertHunk_RecordsOnce`, `TestWorkbenchReviewRevertHunk_SinceView` (`cmd`); Accept: `TestAppendLessonRule_RefusesUnsafe` (symlinked `.watchtower`, symlinked or FIFO `review.md`, a result over 64 KB), `TestAppendLessonRule_InsertsUnderTheHeading` (`internal/reviewdiff`), `TestWorkbenchReviewLessons_AcceptWritesAndDecides`, `TestWorkbenchReviewLessons_DecideOnlyProposed` (`cmd`)

**Locked since:** 2026-10-16

---

## REVIEW-02 — Undo applies only to the file the owner reviewed, in an open round, while the agent is not working

**Status:** Enforced (Go and Desktop — a dual path). Added 2026-10-16 (Plan 3, ask #214).

**Observable:** `workbench review revert-hunk --round R --hunk H` takes a hunk
back only when every check passes, in this order, and otherwise writes nothing
— no file byte, no `review_reverts` row — and answers `ok: false` with the
reason:
- the round is open ("the round is not open");
- the round's session agent does not report `working`
  (`db.TerminalAgentWorking`: "the agent is working in this session — undo
  when it stops");
- the hunk was not undone in this round already ("this hunk was already
  undone in this round");
- the hunk is in the round's diff (all or since view; "hunk … is not in this
  round's diff") and its file is a supported kind (REVIEW-01);
- no parent directory of the file under the repository top is a symlink
  (REVIEW-01: "undo is not available for a symlink file");
- the work-tree file is still the round tree's blob (`git hash-object`; a
  deleted file is still absent; otherwise "the file changed since this round's
  snapshot — refresh first");
- `git apply --check -R` of the one-hunk patch passed ("this hunk no longer
  applies to the file").

The Desktop refuses before calling the CLI while the session's dot is
**working** or **Agents working** (`ReviewChangesModel.agentWorkingKinds`;
"The agent is working in this session — undo when it stops."), on a round that
is not open, and while another Undo or a Send runs; the diff page shows Undo
disabled with its reason. After an Undo the model reloads the reverts and
refreshes the round. Accepted window: the agent-state read and the blob check
precede the apply, so a write landing in between is bounded by `apply --check
-R` and apply's own context check to one hunk's lines.

**Why locked:** Undo is the reviewer's only write to the owner's code. A file
the agent changed since the snapshot, or is changing right now, would be
patched against content the owner never saw; a revert of a sent round would
land outside the review the agent will read.

**Test guards:**
- `internal/reviewdiff/revert_test.go::TestReview02_RefusedWhenFileChanged` (the file byte-identical afterwards)
- `internal/reviewdiff/revert_test.go::TestReview02_CheckFailureAppliesNothing`
- `cmd/workbench_review_revert_test.go::TestWorkbenchReviewRevertHunk_RefusedWhileAgentWorking` (no file change, no `review_reverts` row)
- `WatchtowerDesktop/Tests/ReviewChangesModelTests.swift::testUndoRefusedWhileAgentWorkingCallsNoCLI`
- supporting: `TestWorkbenchReviewRevertHunk_SentRoundRefused`, `TestWorkbenchReviewRevertHunk_RecordsOnce` (`cmd`); `ReviewChangesModelTests` (`testUndoRefusalShowsGoText`, `testUndoReloadsRevertsAndRefreshes`, `testUndoInTheSinceViewPassesSince`, `testUndoWhileTheCloseIsPendingCommitsNothing`); `WatchtowerDesktop/Tests/ReviewPresentationTests.swift::testUndoReasonByState`

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
it so that reopening does not carry it again), or by the agent resolving it, in
which case it stays listed with **Reopen** (amended 2026-10-16, Plan 3, ask
#214). The agent resolves through `reply_review_comment` with `resolved: true`
(`db.ReplyReviewComment`): a `sent` (or already `resolved`) comment of a sent or
delivered round of the session's workbench gets `agent_reply`/`agent_reply_at`
and `resolved`, and in the same transaction its open `carried`/`outdated` copy
in the same session follows; `resolved: false` only stores the reply. Such a
comment is not carried into the next round, but the Desktop lists it under
**Resolved by the agent** with its reply (`ReviewQueries.agentResolved`: the
previous round and the open one, the open copy standing in for its source).
**Reopen** (`ReviewQueries.reopen`) puts it back into the open round — the open
copy back to `carried` (a copy-less draft to `draft`), or a new `carried` copy
of the resolved source; a comment of neither the open round nor the round it
follows changes nothing, and a round that is not open throws, rolling the
transaction back. Sent rows are immutable;
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
- `internal/tools/workbench_review_agent_test.go::TestReplyReviewComment_RepliesResolvesAndFollowsTheOpenCopy` (also in `internal/db/review_rounds_test.go` for the accessor)
- `WatchtowerDesktop/Tests/Core/ReviewQueriesTests.swift::testAgentResolvedListsOnlyAgentResolved`, `testReopenInsertsACarriedCopy`
- supporting (agent resolution): `TestReplyReviewComment_RefusesDraftsOpenRoundsAndOtherWorkbenches` (`internal/tools`, `internal/db`); `ReviewQueriesTests` (`testReopenRestoresTheOpenCopy`, `testReopenRefusedForAnUnrelatedRound`, `testReopenRefusedOnSentRound`); `ReviewChangesModelTests` (`testReopenAgentResolvedComment`, `testReopenOnASentRoundThrows`, `testReopenWhenTheRoundWasSentBehindTheModelThrowsRoundClosed`)
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
variables dropped), and the calls that read file content — `add`, `write-tree`,
`diff-tree -p` and, since Plan 3 (ask #214), Undo's `apply` and `hash-object` —
additionally blank the folder's `filter.*` drivers
(`gitbin.ReadArgsIn`, the unexported `readsContent`), so a clean/smudge/process filter or an
fsmonitor named in the folder's own `.git/config` or `.gitattributes` never
runs. A scanner error while splitting the patch fails the whole diff instead of
returning a partial one; a type change consumes two patch sections.

**Why locked:** A config in a repository an agent just worked in can name
commands; running one from a background snapshot would execute whatever the
agent (or a cloned repository) planted, with no owner action.

**Test guards:**
- `internal/reviewdiff/guard_test.go::TestReview05_SnapshotAndDiffRunNothingFromTheFolder` (a filter driver and an fsmonitor named by the folder never run through snapshot, diff and file)
- `internal/reviewdiff/guard_test.go::TestReview05_UndoRunsNothingFromTheFolder` (the same through Undo's `hash-object` and `apply`)
- supporting: `internal/gitbin/run_test.go` (`TestReadArgsIn_BlanksTheFoldersFilterDrivers`, `TestReadsContent` (the unexported `readsContent`), `TestReadsContent_AddAndPatchDiffTree`, `TestReadsContent_ApplyAndHashObject`, `TestReadArgsIn_NoFilterIsReadArgs`); `internal/reviewdiff/diff_test.go` (`TestDiff_TypeChangeToSymlink`, `TestSplitSections_LineOverMaxIsAnError`)

**Locked since:** 2026-10-16

---

## Changelog

- 2026-10-16 (board #328, diff reviewer Plan 1, spec review ask #179): file created with REVIEW-01, 03, 04, 05. REVIEW-02 (Undo) reserved for Plan 3. PROJ-12 amended to cover the round line (see `workbench.md`).
- 2026-10-16 (board #328, final review fix wave): REVIEW-01 — the temp index is seeded from a read-only copy of the owner's index (read-tree HEAD fallback). REVIEW-03 — outdated rows are carried as outdated; a sent round takes no comment and only `open()` opens the next round (`start --refresh` never creates one). REVIEW-04 — Go's `sent: false` now shows "This round was already sent"; `get_review` marks delivered only after the comments read.
- 2026-10-16 (board #328, owner ask #183): REVIEW-01 — the temp index is forced unsplit (`core.splitIndex=false` via `GIT_CONFIG_*` env); no `sharedindex.*` is written into the owner's `$GIT_DIR`.
- 2026-10-16 (board #328, diff reviewer Plan 3, **owner approved in ask #214**): REVIEW-01 amended — Undo (one hunk's work-tree file, `apply -R` from the repository top, never `--index`/`--cached`, symlinked parents refused) and Accept (`.watchtower/review.md` in the workbench folder, `AppendLessonRule` only) are the two owner-pressed writes; both CLI commands refuse under the AGENT-07 agent markers (`refuseUnderAgent`). REVIEW-02 added (Undo's preconditions: open round, agent not working — Go `agent_state`, Desktop working/Agents working —, not undone yet, blob unchanged, `apply --check -R`). REVIEW-03 amended — the agent may resolve a comment with `reply_review_comment`; it is not carried but stays listed under Resolved by the agent with Reopen. REVIEW-05 strengthened — `apply` and `hash-object` join `contentReads`. Module list gains migration 00128 (`review_agent_ai`, renumbered from 00125 at the merges with main, which took 00125–00127; 00124 is Plan 2's `review_checks`), `internal/reviewai/`, `internal/db/review_agent.go`, the new cmd and tools files. No guard relaxed or renamed. `agent-actions.md` needs no change: `annotate_changes` and `reply_review_comment` are ordinary audited workbench writes under DEV-06's DirectApply, and the two refusals reuse the AGENT-07 marker set without widening AGENT-07's list (their guards live here).
- 2026-10-18 (board #568, AGENT-07 amended, owner approved in ask #357): strengthening, no guard changed. Undo and the lessons commands keep the marker refusal; without a marker they also need the owner's Confirm in the running Desktop (`confirmWithOwner`), whose window shows the hunk or the lesson text.
