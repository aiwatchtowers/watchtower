# Diff reviewer — guided review of a session's changes (2026-10-16, Plan 1 of 3)

Board #328. Spec: `docs/superpowers/specs/2026-10-16-workbench-diff-reviewer-design.md`.
Plan 1: `docs/superpowers/plans/2026-10-16-diff-reviewer-p1-core.md`. Contracts:
`docs/inventory/review.md` (REVIEW-01/03/04/05; REVIEW-02 Undo is reserved for Plan 3)
and the PROJ-12 amendment in `docs/inventory/workbench.md`.

The owner reviews what an agent session changed in a folder-bound workbench, writes
comments on lines, sends them as a **round**, and the agent reads them with
`get_review`. The next round shows only what changed since, carries the unresolved
comments and keeps the Viewed mark of every file whose hunks are unchanged.

## What Plan 1 ships

**Go, read side (`internal/reviewdiff`).**
- `Snapshot` writes the work tree (tracked and untracked, not ignored) as a tree
  object through a private temporary index: `read-tree HEAD`, `add -A`, `write-tree`.
  Only objects are written — no ref, not the owner's index, no work-tree file (REVIEW-01).
- `Base` picks the comparison base (merge-base with the default branch, a label for it);
  `TreeExists` tells whether a stored tree is still in the object store.
- `Diff(from, to)` parses `diff-tree -p` plus the name-status into files (status,
  hunks with stable hunk ids, collapsed reasons by name pattern, caps in `limits.go`).
  A type change (file to symlink and back) consumes two patch sections; a scanner error
  fails the whole `Diff` rather than returning a partial one.
- `File(tree, path)` returns both sides of one file.
- `DeliveryLine` / `CommentCount` render the one fixed line typed after Send and the
  brief's count; pinned against Swift by `internal/reviewdiff/testdata/lines`.
- Every git call goes through `internal/gitbin` `ExecEnv` with the background-read
  hardening; `add`, `write-tree` and `diff-tree -p` count as content reads and blank the
  folder's `filter.*` drivers (REVIEW-05).

**Go, storage and CLI.**
- Migration 00117: `review_rounds` (status `open|sent|delivered`, one open round per
  session by a partial unique index), `review_comments` (status
  `draft|sent|carried|resolved|outdated`, anchored by path, side, lines and a quote with
  prefix/suffix), `review_viewed`. `internal/db/review_rounds.go` owns create, tree
  refresh, the guarded `SendReviewRound`, `MarkReviewRoundDelivered` and the brief's
  `ReviewRoundsWaiting` (REVIEW-04).
- `watchtower workbench review start|diff|file|send|context` (`cmd/workbench_review.go`).
  `start` opens or reuses the session's round on a fresh snapshot, `diff` takes the
  all-changes or since-round view, `send` stores the round, and
  `context` (`cmd/workbench_review_context.go`) gives the review a plan or task to read
  against: it checks session ownership, resolves symlinks of plan reads, stays inside
  the folder and caps a read at 1 MB. A non-repository folder answers an envelope.
- `get_review` (`internal/tools/workbench_review.go`): the agent reads a sent round's
  comments (quote, body, lens, carried-from) by id. Its one write, `sent → delivered`,
  is unaudited like `get_ask` — an AGENT-06 scope exception. Open rounds, drafts and
  other workbenches' rounds are not readable. DEV-06's workbench tool set is now sixteen.
- The brief (`cmd/workbench_brief.go`) adds `Review round #N waiting (<n> comments) →
  get_review N` for sent, unread rounds of the session, rendered with the rules block
  and never cut. Skill pack v9 gets a "Review rounds" section.

**Swift core (`WatchtowerCore`).** `Models/ReviewModels.swift`,
`Database/Queries/ReviewQueries.swift` (drafts, Viewed with content sha, carry-over,
replace/mark outdated, resolve), `Services/Review/ReviewDeliveryLine.swift` (dual of the
Go line) and `ReviewCommentAnchor.swift` (quote anchoring: moved or lost; a design
comment without a file never moves — REVIEW-03).

**Swift app.** `Services/WorkbenchCLI.swift` review calls; `SessionLineDelivery` gets
`LineKey.review` so the round line goes through PROJ-12's gates; `ReviewChangesModel`
drives a round: open, select a file, add/delete/resolve comments, Viewed (per file: `review_viewed(round_id, path, content_sha)`, the sha a hash of the file's hunk
ids from the *all* diff in every view), refresh, new round with carry-over (deleting a
carried comment resolves it, so reopening does not carry it again), the
**All changes / Since round N** view (old-side comments are refused in the since view),
and Send, which types the line once.

**The Changes pane (Task 9, built in parallel).** A workspace pane `Changes` (a
`WorkspacePane.changes(sessionID)`, picked in the pane picker) with a file list (status,
Viewed, comment counts, collapsed files) and a Monaco diff page (`diff.html`) in
side-by-side or inline mode; selecting lines offers **Comment**. It opens from the
session row menu **Review Changes**; one model per session.

## Flow

1. Row menu **Review Changes** → `review start` snapshots the tree and opens the round.
2. Owner reads, marks files Viewed, comments lines (drafts stay local to the round).
3. **Send** → `review send` stores the round and its comments as `sent`; only then the
   Desktop types `Review round #N sent (n comments) — read it with get_review N …`
   into the session (held at a prompt, pasted only over a draft — PROJ-12).
4. The agent calls `get_review N` (round becomes `delivered`), edits, replies.
5. Next round: **Since round N** — unresolved comments are carried (moved if the quote
   moved, outdated with their quote if it is gone) and a file's Viewed mark stays while all of its hunks are unchanged.

## v1 limits

- Generated and vendored files are collapsed by name pattern only; `linguist-generated`
  attributes are not read.
- Quick mode only (the `mode` column accepts `deep`, nothing sets it).
- A repository with a local `filter.lfs.*` is snapshotted with raw content (filters are
  blanked, REVIEW-05), so LFS files show their pointer or raw bytes.
- No Undo and no lessons yet (Plan 3, REVIEW-02); no PR source (the `source` column
  accepts `pr`, Plan 2).
