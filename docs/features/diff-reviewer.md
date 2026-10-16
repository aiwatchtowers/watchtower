# Diff reviewer — guided review of a session's changes (2026-10-16, Plans 1–3 of 3)

Board #328. Spec: `docs/superpowers/specs/2026-10-16-workbench-diff-reviewer-design.md`.
Plan 1: `docs/superpowers/plans/2026-10-16-diff-reviewer-p1-core.md`.
Plan 2 (Deep mode): `docs/superpowers/plans/2026-10-16-diff-reviewer-p2-deep.md`.
Plan 3 (agent tools, AI overview, Undo, Find repeats): `docs/superpowers/plans/2026-10-16-diff-reviewer-p3-agent-ai.md`.
Contracts: `docs/inventory/review.md` (REVIEW-01..05), the PROJ-12 and PROJ-04 entries in
`docs/inventory/workbench.md` and DEV-06 in `docs/inventory/dev-surface.md` (eighteen workbench tools).

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
question in one lens is kept once. A heading without a latin letter or digit (a non-latin
name) has no id: it is skipped with a note and its bullets are dropped. A heading whose id
is `intent` is reserved for Wrap-up: skipped with `line N: "intent" is reserved for
Wrap-up`, bullets dropped. Read rules: the file is read only when `.watchtower`
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

## What Plan 3 ships (agent tools, AI overview, Undo, Find repeats)

**Tables (migration 00125 `review_agent_ai`; 00124 is Plan 2's `review_checks`, 00123
`workbench_methodology`).** `review_notes` (per workbench and session: `kind` `note` —
path, lines, quote, text — or `chapter` — title in `text`, `paths_json`, `core`, `why` —,
`tree_sha` of the snapshot they were checked against, `ord`); `review_overviews` (the
cached overview JSON, primary key `(project_id, tree_sha, base_sha, intent_hash)`, plus the
strong model's name); `review_reverts` (one row per undone hunk: `round_id`, `hunk_id`,
`path`, `header`, the reverse-applied `patch`, unique per `(round_id, hunk_id)`);
`review_lessons` (`lens`, one-line `text`, `source_comment_ids` JSON, `status`
`proposed|accepted|dismissed`, `decided_at`). Accessors in `internal/db/review_agent.go`;
the agent's reply lives in `review_comments.agent_reply`/`agent_reply_at` (Plan 1 columns).

**Undo (`workbench review revert-hunk`, `reviewdiff.Repo.RevertHunk`; REVIEW-01, REVIEW-02).**
The owner presses Undo on one hunk of the diff page. Refused under an agent marker
(`refuseUnderAgent`), on a round that is not open ("the round is not open"), while the
session's `agent_state` is `working` ("the agent is working in this session — undo when it
stops"), for a hunk already undone ("this hunk was already undone in this round"), for a
hunk not in the round's diff (`--since` takes it from the since view), and for a renamed,
binary, symlink, submodule, too-large or truncated file ("undo is not available for a …
file"). It runs from the repository top (`git rev-parse --show-toplevel`, since the round's
paths are top-relative and a workbench may be a subfolder) and refuses a path whose parent
directory under the top is a symlink. Then the work-tree file must still be the round tree's
blob (`hash-object`; a deleted file still absent) — else "the file changed since this
round's snapshot — refresh first" —, `git apply --check -R` must pass — else "this hunk no
longer applies to the file" —, and `git apply -R --whitespace=nowarn` takes the one-hunk
patch back (never `--index`/`--cached`; no ref moves). `apply` and `hash-object` blank the
folder's filter drivers (REVIEW-05). The revert is recorded in `review_reverts`. The
Desktop disables Undo with a reason ("Round already sent", "Undo is off while the agent is
working" — the session dot is working or Agents working —, "Undo is off while another
action runs"), refuses before calling the CLI, shows Go's refusal text, then reloads the
reverts and refreshes the round; undone hunks are listed in an **Undone** group.

**AI overview (`internal/reviewai`, `workbench review overview`).** On round open (and on a
refresh that changed the tree) the Desktop runs `review overview --round R` (330 s
timeout; the CLI bounds one model call at 5 minutes, `reviewAIBudget`). Input: the review
context items (the linked targets' text, intent and plan task, `reviewContextItems`), the
session's agent notes, the lens ids, and the round's diff from base to tree. Caps live only
in `internal/reviewai/limits.go`: at most 300 diff lines per file and 6,000 in all; a file
past either cap, binary or collapsed is listed as `<path> (+a −d) — not shown`, and once the
overall cap is spent every later file is only listed. The call is strong tier
(`workbench.review_overview`, prompt `review.overview` v1, tunable in Settings → Prompts).
The reply is validated, never trusted: malformed JSON, an array root or an empty `summary`
fails the call; coverage entries with an unknown status (`done|partial|not_found`), risk
entries on an unknown path or level (`low|medium|high`), unknown paths in `where`,
`out_of_scope` and chapters, and unknown lens ids are dropped one by one; a chapter left
with no path disappears; caps of 50 coverage, 200 risk, 30 chapters, 2,000 runes of
summary and 500 runes per field. A good result is cached in `review_overviews` under
`(project_id, tree_sha, base_sha, intent_hash)` — `intent_hash` is sha256 hex of the JSON
of the context items plus the session's notes (row ids out), so a new note re-runs it — and
a cached answer comes back with `overview_cached`. Failures are never cached: the envelope
says "AI overview unavailable: …", the Desktop shows the reason with **Retry**, and the
review stays usable on mechanical (or agent) chapters. The Meaning phase shows the summary,
"Does it cover the intent?", "Outside the intent" and a risk line; the file list carries a
compact overview and per-file risk badges.

**Chapter sources and lenses per chapter (`ReviewChapters.resolve`, `lenses(for:all:)`).**
First non-empty source wins: the agent's chapters (`annotate_changes`), then the AI's, then
Plan 2's mechanical split. A chapter keeps only paths in the diff and not taken by an
earlier chapter (core chapters first, tests first inside); files no chosen chapter names go
into mechanical chapters appended after. Keys are `agent:<n>` / `ai:<n>` (1-based index in
the source list); mechanical keys are unchanged. Mechanical and agent chapters show every
lens; an AI chapter shows the lenses it marks plus `house_rules` and every non-built-in lens
(the owner's own rules never hide). An overview arriving after the owner already ticked
checks in the shown chapters does not swap them: a banner offers **Use AI chapters**.
Reopening a round on AI chapters (a saved `ai:` chapter, or checks on `ai:` keys) applies
the AI chapters again and lands on the saved chapter.

**Intent items from coverage (`ReviewWrapUp.intentItems(_:coverage:)`).** With an overview
that has coverage entries, Wrap-up's intent checklist is one item per coverage entry (key
`cov:` + the first 16 hex of sha256 of the item text; the item carries the AI's status as
`aiStatus`); without one it stays one item per linked target (`target:<id>`).

**The agent's tools (DEV-06: eighteen workbench tools; skill pack v11).**
- `annotate_changes` (`internal/tools/workbench_review_annotate.go`): `notes` (≤ 40: path,
  `start_line`, `end_line`, a 1–800 rune note — why, not what), `chapters` (≤ 20: title ≤ 120
  runes, 1–200 paths, `core`, `why` ≤ 400 runes) and a `reason`. It needs the calling
  `terminal_sessions` row of workbench N (`WATCHTOWER_TERMINAL_SESSION_ID`), snapshots the
  session's folder, checks that every note's file is a text file of the current changes and
  its lines exist, stores each note with its quote, and replaces the session's earlier notes
  and chapters. The Desktop places a note on the selected file by its stored lines on the
  same tree, else by its quote (`ReviewNotePlacement`), shows it as a zone in the diff, and
  lists all notes in **The agent's walkthrough** (a lost one says "no longer in the file").
- `reply_review_comment` (`workbench_review_reply.go`): `comment_id`, a 1–2,000 rune
  `reply`, `resolved` and a `reason`. Only a `sent` (or already resolved) comment of a sent
  or delivered round of the workbench; the reply (and, with `resolved: true`, the resolution)
  also goes to its open `carried`/`outdated` copy in the same session, in one transaction.
  The Desktop shows `Agent: <reply>` under a comment and lists agent-resolved comments under
  **Resolved by the agent** with **Reopen** (REVIEW-03); `ReviewQueries.reopen` refuses a
  comment of an unrelated round and throws on a round that is not open.
- Both are `AccessWrite` workbench-surface tools, applied directly and audited (DirectApply).
- `get_review` lists the round's reverts ("Undone by the owner (reverted in the work tree — do
  not redo without asking)") with path, hunk header and patch; the delivery line is unchanged
  (PROJ-12).
- Pack v11's "Review rounds": before handing work back, read `.watchtower/review.md` and check
  the changes against it, then call `annotate_changes` once (chapters for more than ~400
  changed lines); when a round arrives, answer every comment with `reply_review_comment` and
  do not redo undone hunks without asking.

**Find repeats (`workbench review lessons propose|accept|dismiss`).** Header **Find Repeats…**
opens a sheet. Input: the owner's comments of the workbench's newest 20 sent or delivered
rounds, `sent` or `resolved`, never carried copies (a remark carried across rounds is one
remark), minus comments a decided lesson already cites; fewer than two calls no model.
Strong tier (`workbench.review_lessons`, prompt `review.lessons` v1). Validation: a lesson
needs at least two distinct source ids from the input, an unknown lens becomes
`house_rules`, the text is one line of 1–300 runes, at most 20. Each propose replaces the
workbench's `proposed` lessons (decided ones stay). **Accept** writes `- <rule>` under the
lens's heading in the workbench folder's `.watchtower/review.md` (`reviewdiff.AppendLessonRule`,
the file's only writer: real `.watchtower` directory, regular `review.md` read under the
Plan 2 rules, 64 KB cap, atomic rename, a rule already present writes nothing) and marks the
lesson `accepted`; a refusal writes nothing and leaves it `proposed`. Accept refuses under an
agent marker (REVIEW-01). **Dismiss** marks it `dismissed`. The new rule shows up in the
`house_rules` (or its lens's) checklist on the next context read.

**Quick mode** also shows the agent's notes, the risk badges, per-hunk Undo and the
Resolved by the agent / Undone groups (controller ruling). Active review time stays scoped
to the key window (owner ruling, ask #221).

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
- Intent items are the linked targets or the overview's coverage entries; there is no free-form intent.
- A repository with a local `filter.lfs.*` is snapshotted with raw content (filters are
  blanked, REVIEW-05), so LFS files show their pointer or raw bytes.
- No PR source (the `source` column accepts `pr`).
- Keep is implicit: a hunk not undone is kept; there is no explicit Keep mark.
- Undo is not LFS-aware: filters are blanked (REVIEW-05), so an LFS file is checked and
  patched on its raw content, as it was snapshotted. Renamed, binary, symlink, submodule,
  too-large and truncated files cannot be undone.
- One notes set per session: each `annotate_changes` call replaces the session's notes and
  chapters, whatever round they were written for.
- The walkthrough's line numbers for notes in files other than the selected one are the
  stored ones; they are not re-placed against the current tree.
- A workbench bound to a subfolder of a repository snapshots only that subfolder's
  uncommitted changes.
- The overview cache key does not include the lens file: editing `.watchtower/review.md`
  does not re-run the overview until the tree changes.
