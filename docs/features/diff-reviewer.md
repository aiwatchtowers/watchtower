# Diff reviewer — guided review of a session's changes (2026-10-16, Plans 1–2 of 3)

Board #328. Spec: `docs/superpowers/specs/2026-10-16-workbench-diff-reviewer-design.md`.
Plan 1: `docs/superpowers/plans/2026-10-16-diff-reviewer-p1-core.md`.
Plan 2 (Deep mode): `docs/superpowers/plans/2026-10-16-diff-reviewer-p2-deep.md`. Contracts:
`docs/inventory/review.md` (REVIEW-01/03/04/05; REVIEW-02 Undo is reserved for Plan 3)
and the PROJ-12 amendment in `docs/inventory/workbench.md`.

The owner reviews what an agent session changed in a folder-bound workbench, writes
comments on lines, sends them as a **round**, and the agent reads them with
`get_review`. The next round shows only what changed since, carries the unresolved
comments and keeps the Viewed mark of every file whose content is unchanged.

## What Plan 1 ships

**Go, read side (`internal/reviewdiff`).**
- `Snapshot` writes the work tree (tracked and untracked, not ignored) as a tree
  object through a private temporary index, seeded from a copy of the owner's index
  (read only, its mtime kept so racy entries are still re-hashed; `read-tree HEAD` when
  the index is split or the copy fails), then `add -A`, `write-tree`. Both seeds give the
  same tree. Only objects are written — no ref, not the owner's index, no work-tree file
  (REVIEW-01).
- `Base` picks the comparison base (merge-base with the default branch, a label for it);
  `TreeExists` tells whether a stored tree is still in the object store. A done
  context (the 30 s budget, a cancel) is an error in `Base`, `File`, `TreeExists` and
  the HEAD check, never "no commit", "not in the tree" or "pruned": `start` then answers
  an envelope and persists no round.
- `Diff(from, to)` parses `diff-tree -p` plus `diff-tree -z --raw` into files (status,
  the new side's `new_blob` and `new_mode` — "" for a deleted file —, hunks with stable
  hunk ids, collapsed reasons by name pattern, caps in `limits.go`). An empty line inside
  a hunk (`diff.suppressBlankEmpty`) is a blank context line.
  A type change (file to symlink and back) consumes two patch sections; a scanner error
  fails the whole `Diff` rather than returning a partial one.
- `File(tree, path)` returns one side of one file; `review file --old-path` reads a
  renamed file's old side at its old path.
- `DeliveryLine` / `CommentCount` render the one fixed line typed after Send and the
  brief's count; pinned against Swift by `internal/reviewdiff/testdata/lines`.
- Every git call goes through `internal/gitbin` `ExecEnv` with the background-read
  hardening; `add`, `write-tree` and `diff-tree -p` count as content reads and blank the
  folder's `filter.*` drivers (REVIEW-05).

**Go, storage and CLI.**
- Migration 00121: `review_rounds` (status `open|sent|delivered`, one open round per
  session by a partial unique index), `review_comments` (status
  `draft|sent|carried|resolved|outdated`, anchored by path, side, lines and a quote with
  prefix/suffix), `review_viewed`. `internal/db/review_rounds.go` owns create, tree
  refresh, the guarded `SendReviewRound`, `MarkReviewRoundDelivered` and the brief's
  `ReviewRoundsWaiting` (REVIEW-04).
- `watchtower workbench review start|diff|file|send|context` (`cmd/workbench_review.go`).
  `start` opens or reuses the session's round on a fresh snapshot (`--refresh`
  re-snapshots the open round and, with none open, answers `ok: false` "no open review
  round" — it never creates one), `diff` takes the
  all-changes or since-round view, `send` stores the round, and
  `context` (`cmd/workbench_review_context.go`) gives the review a plan or task to read
  against: it checks session ownership, resolves symlinks of plan reads, stays inside
  the folder and caps a read at 1 MB. A non-repository folder answers an envelope.
- `get_review` (`internal/tools/workbench_review.go`): the agent reads a sent round's
  comments (quote, body, lens, carried-from) by id; its text names an old-side comment
  `path:a-b (old side)` and keeps blank quote lines as `> `. Its one write,
  `sent → delivered`, made only after the comments were read, is unaudited like `get_ask` — an AGENT-06 scope exception. Open rounds, drafts and
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
drives a round: open, select a file, add/delete/resolve comments, Viewed (per file: `review_viewed(round_id, path, content_sha)`, the sha a hash of the file's
`new_mode + "\n" + new_blob` from the *all* diff in every view, so binary, too-large,
truncated and mode-only changes move it too), refresh, new round with carry-over
(sent and carried comments carried or outdated, outdated ones carried as outdated,
resolved ones never; deleting a carried comment resolves it, so reopening does not carry
it again), the **All changes / Since round N** view (old-side comments are refused in
the since view), and Send, which types the line once. After Send the round is closed
in the model too: adding or editing a comment is refused, and Refresh on it opens the
next round through `open()` (the one path that creates a round and carries); Go
answering `sent: false` shows "This round was already sent". The header **Changes**
button is disabled while there is no session to review.

**The Changes pane (Task 9, built in parallel).** A workspace pane `Changes` (a
`WorkspacePane.changes(sessionID)`, picked in the pane picker) with a file list (status,
Viewed, comment counts, collapsed files) and a Monaco diff page (`diff.html`) in
side-by-side or inline mode; selecting lines offers **Comment**. It opens from the
session row menu **Review Changes**; one model per session.

## What Plan 2 ships (Deep mode)

**Lenses (`internal/reviewdiff/lenses.go`, `lenses.md`).** Built-in review lenses, in
order: `correctness`, `tests`, `security`, `simplicity`, `house_rules` (no built-in
questions). A lens id is its name lowercased, every run of non `[a-z0-9]` characters
replaced by `_` and trimmed; comments store the id in `review_comments.lens`, and
`intent` is the Wrap-up lens. The workbench folder may extend them with
`.watchtower/review.md` (the **workbench folder**, `projects.folder_path`, not the
session worktree; only read, never written). Grammar: `## <name>` names a lens (a
built-in is matched case-insensitively and extended; any other name is added after the
built-ins in file order), `- <question>` is a question, blank lines are ignored, any
other line (text before the first heading too) is skipped and reported as
`line N: not a "## lens" heading or a "- question"`. A leading UTF-8 BOM is ignored. An
item key is the first 16 hex characters of sha256 of the trimmed question; a duplicate
question in one lens is kept once. Read rules: the file is read only when `.watchtower`
is a real directory (lstat) and `review.md` a regular file opened
`O_NOFOLLOW|O_NONBLOCK` and re-checked with fstat (same inode); over 65,536 bytes it is
not read. Any refusal gives the built-in lenses plus one note; a missing file is no note.
`workbench review context` returns `lenses` and `lens_notes` next to the items (the
Desktop shows the notes; Refresh re-reads the file).

**Checks (migration 00124 `review_checks`).** One row per
`(round_id, chapter_key, lens, item_key)` with `state` in `checked` (a checklist
question ticked), `commented` (turned into a comment), and the Wrap-up marks `done`,
`partial`, `not_done`. Unticking deletes the row; rows cascade with the round. Checks of
a chapter that no longer exists stay in the table.

**Round state.** `review_rounds` carries `phase` (`meaning`, `chapters`, `wrapup`; `''`
reads as `meaning`), `chapter_key` and `active_seconds`, returned in the round JSON of
`review start`/`review diff`. `mode` (`quick|deep`) is now set by the Desktop, and a new
round inherits the previous sent round's mode (Go, at create). Swift writes `mode`,
`phase`, `chapter_key` and `active_seconds` only with `WHERE id = ? AND status = 'open'`;
on a sent round the state is read-only (moving on screen is not saved). Reopening the
app lands on the same phase and chapter.

**Mechanical chapters (`ReviewChapters.swift`, no model).** The changed files are
grouped by directory; a test file sits next to its one subject and comes first in the
chapter; a chapter is capped at 400 changed lines (additions + deletions) and a larger
directory is split into parts; generated and lock files (collapsed) go last. A chapter
is done when all its files are Viewed.

**Pace (`ReviewPace.swift`).** Active review time counts only while the window is key and
the owner interacted within 120 s; one tick gap never counts more than 15 s. It is
persisted to `active_seconds` about every 30 s (open rounds only). At 3,600 active
seconds the header shows a break hint.

**Phases and views (`ReviewChangesModel`, `// MARK: - Deep`; `Views/Workbench/Review/`).**
Quick/Deep switch and a phase strip in the header. *Meaning*: the intent card (linked
targets with their intent and plan task) and the design comments. *Chapters*: the chapter
list, the per-chapter checklist (all lenses, ticking, **Comment** on a question turns it
into a design comment and marks it `commented`), the Monaco diff. *Wrap-up*: comments
grouped by chapter plus a General group, and the intent checklist — one item per linked
target (`target:<id>`); Done / Partly / Not done are `done` / `partial` / `not_done`
checks; Partly and Not done add a comment under the `intent` lens (`ReviewWrapUp`), and
re-marking an item replaces its earlier intent draft.

**Agent side.** `get_review` prints a comment's lens as a tag after its location, e.g.
`[tests]` or `[intent]`.

## Flow

1. Row menu **Review Changes** → `review start` snapshots the tree and opens the round.
2. Owner reads, marks files Viewed, comments lines (drafts stay local to the round).
3. **Send** → `review send` stores the round and its comments as `sent`; only then the
   Desktop types `Review round #N sent (n comments) — read it with get_review N …`
   into the session (held at a prompt, pasted only over a draft — PROJ-12).
4. The agent calls `get_review N` (round becomes `delivered`), edits, replies.
5. Next round: **Since round N** — unresolved comments are carried (moved if the quote
   moved, outdated with their quote if it is gone; an outdated one stays outdated) and a
   file's Viewed mark stays while its new blob and mode are unchanged.

## v1 limits

- Generated and vendored files are collapsed by name pattern only; `linguist-generated`
  attributes are not read.
- Deep mode uses mechanical chapters and all lenses on every chapter until Plan 3's overview; intent items are linked targets only (no free-form intent).
- A repository with a local `filter.lfs.*` is snapshotted with raw content (filters are
  blanked, REVIEW-05), so LFS files show their pointer or raw bytes.
- No Undo and no lessons yet (Plan 3, REVIEW-02); no PR source (the `source` column
  accepts `pr`).
