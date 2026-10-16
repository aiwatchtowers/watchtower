# Workbench diff reviewer — guided review of an agent's work (v1: sessions)

**Date:** 2026-10-16 · **Board:** #328 · **Owner decisions:** asks #169, #171, #173, #175
**Status:** design approved in chat/asks; Plans 1–2 are implemented (Plan 2: `docs/superpowers/plans/2026-10-16-diff-reviewer-p2-deep.md`); Plan 3 pending.

## 1. Goal

The owner reviews what a workbench agent changed **inside Watchtower**, guided by
established review practice rather than a bare diff, and the review goes back to
the live session as one turn. The reviewer is not "a diff with comments": it walks
the owner from *what was asked* to *what was done* to *the lines*, in reviewable
chapters, with role checklists, and learns from repeated comments.

Two directions exist (owner, ask #169): **what the agents did** (v1, this spec)
and **what the owner reviews on GitHub** (PRs, a later spec). The data model is
shaped for both from day one (`source` column), nothing else of the PR side is
built now.

### Practices adopted (ask #173)

| Practice | Source | Where it lives here |
|---|---|---|
| Meaning before lines | Google eng-practices, "Navigating a CL" | Deep mode's three phases (§5) |
| Check against intent | requirements traceability | intent card, coverage, out-of-scope (§5.1, §5.3) |
| Role checklists | perspective-based reading; SmartBear/Cisco study | per-chapter lenses (§5.2, §6) |
| Pace and chapters | SmartBear/Cisco (≤ ~400 LOC, ≤ ~60 min per sitting) | chapters, progress, break hint (§5.2, §5.4) |
| Learning loop | our own review-lessons → review-rules | "Find repeats" → `.watchtower/review.md` (§7) |
| Author annotations | SmartBear/Cisco | agent notes and reading order (§8.1) |

Also kept from ask #169: rounds "since last review", Keep/Undo per hunk, agent
notes with reading order, AI overview with per-file risk.

**Not in v1 (owner's choice):** Conventional Comments labels and a formal verdict,
mechanical red-flag detectors, a formal agent self-review step. A review ends with
**Send**.

## 2. Scope

**In:** the Changes pane in a workbench; Go diff engine and snapshots; review rounds;
Quick and Deep modes; comments anchored to lines and carried across rounds;
Keep/Undo per hunk; agent annotations and two new MCP tools; AI overview;
role checklists (built-in + per-folder file); pace; learning loop; delivery to the
session; inventory entries.

**Out:** GitHub PRs (later spec), syntax-aware diffing, moved-code detection,
review on the phone (the round and its comments are in the DB, so a later mobile
slice can read them), multi-reviewer workflows.

## 3. Architecture overview

```
Desktop (Swift)                         Go (watchtower CLI / MCP)
───────────────                         ─────────────────────────
Changes pane ──run──► workbench review start  → snapshot tree T, round row
             ──run──► workbench review diff    → files, hunks (JSON)
             ──run──► workbench review file    → both sides of one file
             ──run──► workbench review overview→ AI overview (cached)
             ──run──► workbench review revert-hunk
             ──run──► workbench review send    → round closed, delivery line
             ──run──► workbench review lessons → proposed rules
Comment drafts, viewed, checks: Swift writes (GRDB)
Delivery line → TerminalCenter (PROJ-12 path)
                                         MCP: annotate_changes, get_review,
                                              reply_review_comment
```

Git lives in Go (house rule): a new package `internal/reviewdiff` on top of
`internal/gitbin` and `internal/workbenchgit`'s folder resolution. The Desktop
never runs git. All CLI calls are `--json` envelopes (`{"ok": …}`) like the
other `workbench git` commands.

## 4. Diff engine (Go, `internal/reviewdiff`)

### 4.1 Folder

The review runs in the folder the session's agent works in: the session's
`agent_cwd` resolved through `workbenchgit.ResolveFolder` (the worktree root),
else the workbench folder. A folder that is not a git work tree returns an
envelope error; the pane shows it.

### 4.2 Snapshot of "now"

A snapshot is a git **tree object**, made without touching the owner's index or
any ref (ask #171, option A):

1. `GIT_INDEX_FILE=<tmp>` (a file in a private temp dir, removed after),
2. `git read-tree HEAD` (empty tree when there is no commit yet),
3. `git add -A` — includes untracked, non-ignored files,
4. `git write-tree` → `T`.

Every call goes through `gitbin.ReadArgsIn` (no fsmonitor, no hooks, no
`log.showSignature`). `add`, `diff-tree -p` and `cat-file` read file content, so
they join `gitbin`'s `contentReads` set: `ReadArgsIn` then blanks every filter
driver and git-lfs extension the folder's config names, fresh per call, and
refuses the read (`ErrFilterGuard`) when it cannot. The owner's global and system
config stay in force, as for every other read. Consequence accepted (same as
security review #155): in a repository with a repository-local `filter.lfs.*`,
an LFS file is snapshotted as its raw work-tree content.

`write-tree` writes objects into the repository's object store. No ref points at
them, so `git gc` may eventually prune an old snapshot (after `gc.pruneExpire`,
two weeks by default). This is detected, never silent: see §4.5.

### 4.3 Base

`merge-base HEAD <default branch>` with the default branch found the way
`workbenchcheck` finds it (`origin/HEAD`, else `origin/main`/`origin/master`,
else local `main`/`master`). No base found → the diff is against the empty tree
and the pane says so.

### 4.4 Diff output

`diff-tree -p -M --no-color <from> <to>` with `from` = base (full view) or the
previous sent round's tree (since-last-review view). The envelope:

- `files[]`: `path`, `old_path`, `status` (added/modified/deleted/renamed),
  `additions`, `deletions`, `binary`, `collapsed_reason` (`lockfile`,
  `generated` — by name patterns and a `linguist-generated` attribute read from
  the tree, `too_large`), `hunks[]`.
- `hunks[]`: `hunk_id` = sha256 of path + header + body (stable for the same
  content), old/new start and length, the lines.
- Caps: a file over 1 MB or a diff over 5,000 changed lines per file is
  `too_large` (header only, "open in Files"); the envelope carries `truncated`
  when the whole diff exceeds 50,000 lines. Exact numbers are tunables in one
  place.

`workbench review file --tree T --path P [--from B]` returns both sides of one
file for Monaco (`git cat-file` on the two trees), same caps.

### 4.5 Lost snapshot

A since-last-review request whose previous tree no longer exists
(`cat-file -e` fails) returns the full diff with `previous_tree_lost: true`; the
pane shows a banner "round K's snapshot is gone — showing all changes". Comments
of that round still show (their quoted text is stored, §6).

### 4.6 Undo a hunk

`workbench review revert-hunk --round R --hunk H`:

1. rebuild the hunk's patch from the round's `from → T` diff;
2. refuse unless the file in the work tree still equals `T`'s version of it
   (`hash-object` vs the tree entry) — the agent or the owner changed it since;
3. `git apply --check -R` on the work tree (never `--index`), then `git apply -R`;
4. record the revert on the round (`review_reverts`).

The Desktop offers Undo only while the session's agent is not `working`
(PROJ-11 state) — the agent's own edits and an Undo never race. A hunk that is
already committed reverts as an uncommitted change on top. Every revert is
listed in the round's delivery (§9).

## 5. The review flow

A **round** opens when the owner presses **Review Changes** (session row menu,
the target panel via session↔target links, the workbench header): Go takes `T`,
inserts the round (`status='open'`, `mode`). Comments anchor to what the owner
sees. If the work tree changes while the round is open (the pane re-snapshots on
focus and on the session's Stop state), a banner offers **Refresh**: a new `T`
for the same round, comments re-anchored (§6.2). **Send** closes the round
(`status='sent'`). One open round per session at a time.

### 5.1 Deep mode — Phase 1: Meaning

- **Intent card** (`workbench review context`): the session's linked targets
  (`terminal_session_targets`) — text and intent; for an intent of the form
  `<plan path> — Task N`, that task's section read from the plan file; the spec
  path the plan header names. Read-only, nothing guessed: a missing file or task
  is shown as missing.
- **AI overview** (§7.1): what was done, **intent coverage** (each intent item →
  where it is done, or "not found"), files **outside the intent**, risk per file,
  size and an estimate (~400 changed lines per hour).
- **Agent notes** (§8.1) as the author's walkthrough.
- **Design comments**: comments not tied to a line (`path` NULL) about the
  approach as a whole.

### 5.2 Deep mode — Phase 2: Chapters

- The diff is split into **chapters** of at most ~400 changed lines. Source of
  the split, first found wins: the agent's chapters (`annotate_changes`), the AI
  overview's chapters, a mechanical fallback (group by directory, a test file
  next to the file it tests, split a group over the cap).
- Order: chapters marked core first; inside a chapter, tests first.
- Each chapter shows its **role checklist** (§6): the lenses the overview marked
  relevant (all lenses in the mechanical fallback). An item is ticked, or turned
  into a comment carrying that lens.
- Keep/Undo per hunk lives here.
- Progress: a chapter is done when every file in it is marked Viewed.

### 5.3 Deep mode — Phase 3: Wrap-up

- Each intent item from the coverage list gets **done / not done / partial**
  from the owner; not done and partial become comments to the agent (lens
  `intent`).
- A summary of the round's comments by chapter, then **Send**.

### 5.4 Pace

Progress bar over changed lines and chapters; **active time** only (the pane is
key and the owner interacted in the last 2 minutes); after ~60 active minutes a
non-blocking hint suggests a break. Mode, phase, current chapter, checks and
active seconds are stored on the round, so a review resumes where it stopped.

### 5.5 Quick mode

The intent card and the overview with risk (collapsed to one block), the reading
order, the diff. No checklists, no phases, no pace hints. The owner can switch a
round from Quick to Deep at any time (and back); nothing is lost.

## 6. Comments, viewed, checklists

### 6.1 Anchor

A comment stores `path`, `side` (`old`/`new`), `start_line`, `end_line`, the
quoted lines (`quote`), the tree it was written against, `lens` (optional),
`body`, `status` (`draft` → `sent` → `resolved` | `outdated`), `carried_from`
(the comment it continues in a later round), `agent_reply`, `agent_reply_at`.

### 6.2 Carry-over

On Refresh and in the next round, an unresolved comment is re-anchored by its
quote against the new version of the file — the same rules as the AI Chat's
artifact comments (exact match first, then the nearest fuzzy match within the
file; no match → `outdated`, still listed with its quote). One implementation in
WatchtowerCore, shared, not copied.

### 6.3 Viewed

`review_viewed(round_id, path, content_sha)`: a file stays Viewed while its
content is unchanged — a new round keeps the mark for files the agent did not
touch again (GitHub behaviour).

### 6.4 Checklists and lenses

Five built-in lenses, each with 3–6 questions, embedded in Go
(`internal/reviewdiff/lenses.md`): **Correctness**, **Tests**, **Security**,
**Simplicity**, **House rules** (empty by default). A workbench adds to them with
`.watchtower/review.md` in its folder:

```markdown
## Tests
- Does every new branch of behaviour have a test that fails without it?
## House rules
- Git runs only in Go; the Desktop never shells out to git.
```

A `##` heading names a lens (a built-in one is extended, a new one is added);
each `- ` bullet is a question. The file is read through the same lstat-only,
no-symlink rules as other folder reads, capped at 64 KB; an unparseable line is
skipped and reported in the envelope. Checks are stored per round, chapter, lens
and item key (hash of the question text).

## 7. AI

### 7.1 Overview

One call per (tree `T`, base, intent hash), started automatically when a round
opens (ask #175), cached in `review_overviews`; a Refresh with an unchanged tree
reuses it. Prompt `review.overview` through the provider registry (works on the
claude and codex backends; tier chosen in the plan via `add-ai-prompt` —
expected the strong tier, source tag `workbench.review_overview`). Input: the
intent card, the agent's notes, the diff capped per file and overall (big files
summarised by name and size). Output JSON, validated: `summary`, `coverage[]`
(`item`, `status` done/partial/not_found, `where[]` paths), `out_of_scope[]`,
`risk[]` (`path`, `level` low/medium/high, `why`), `chapters[]` (`title`,
`paths[]`, `core`, `lenses[]`). Invalid output or a failed call → the pane works
without it (mechanical chapters, no risk badges) and says why; it never blocks
the review.

### 7.2 Find repeats (learning loop)

**Find repeats** (button in the workbench's Changes pane): one call over the
sent comments of the workbench's last 20 rounds; it groups similar comments and
proposes a rule per group (`lens`, `text`, source comment ids). Proposals land in
`review_lessons` (`proposed`). **Accept** appends the bullet under its lens
heading in `.watchtower/review.md` (creates the file if missing) — the only
Watchtower write into the folder in this feature, and only on the owner's click;
**Dismiss** keeps it from being proposed again for the same comments. The skill
pack tells the agent to read `.watchtower/review.md` before handing work back, so
an accepted rule reaches the next session.

## 8. The agent's side

### 8.1 `annotate_changes` (workbench MCP, write tool)

`{notes: [{path, start_line, end_line, note}], chapters?: [{title, paths[], core,
why}], reason}`. Go snapshots `T` at call time and stores the notes and chapters
against it (`review_notes`); lines are new-side lines of `T`. Notes carry over to
later trees by quote like comments. Applies immediately (workbench tools have no
approval step).

### 8.2 `get_review` (read tool)

`{round_id}` → the round's comments (id, path, lines, quote, lens, body, carried
from), intent items marked not done/partial, reverted hunks, the folder and tree.
Reading marks the round delivered.

### 8.3 `reply_review_comment` (write tool)

`{comment_id, reply, resolved, reason}` — the reply shows in the comment's thread;
`resolved: true` marks it resolved (the owner can reopen).

### 8.4 Skill pack v9

The workbench skill gains a **Review** section: annotate non-obvious changes and
propose chapters before handing work back; read `.watchtower/review.md` and check
the work against it; on a `Review round #N sent` line call `get_review`, answer
every comment with `reply_review_comment`, fix, and say which comments are done.
Pack marker `v8 → v9` (PROJ-04 install rules unchanged).

## 9. Delivery to the session

Send stores everything first, then types one fixed line into the session:
`Review round #<id> sent (<n> comments) — read it with get_review <id> using the
watchtower-workbench skill.` — through **PROJ-12's delivery path** (the same
paste-then-Return gates as an answered ask: hooks reported this run, no
permission prompt, no half-typed owner text; otherwise the line waits, exactly as
an ask answer does). The comments themselves never go through the terminal; the
agent reads them with `get_review`. This replaces the earlier idea of pasting the
whole batch: it reuses an approved delivery contract and keeps owner and agent
text out of the TTY.

**Owner approval needed (inventory):** PROJ-12 covers ask answers; this extends
its scope to the review line (same gates, a second fixed line). The amendment is
part of this spec's review.

A session that is not running: the round is stored as sent; the brief of the
session's next run lists it (`Review round #N waiting`), like an answered ask.

## 10. Data (one migration, next free number)

| Table | Columns (main) | Writer |
|---|---|---|
| `review_rounds` | `id`, `project_id`, `session_id` NULL, `source` CHECK IN ('session','pr'), `folder_root`, `base_sha`, `tree_sha`, `prev_round_id`, `status` CHECK IN ('open','sent','delivered'), `mode` CHECK IN ('quick','deep'), `phase`, `chapter_key`, `active_seconds`, `created_at`, `sent_at`, `delivered_at` | Go (status, trees); Swift (mode, phase, chapter, seconds) |
| `review_comments` | §6.1 | Swift (drafts, owner edits); Go (send → sent, agent reply, resolve) |
| `review_viewed` | `round_id`, `path`, `content_sha` | Swift |
| `review_checks` | `round_id`, `chapter_key`, `lens`, `item_key`, `state` | Swift |
| `review_reverts` | `round_id`, `hunk_id`, `path`, `at` | Go |
| `review_notes` | `project_id`, `session_id`, `tree_sha`, `kind` ('note','chapter'), path/lines/quote/text, `ord` | Go |
| `review_overviews` | `tree_sha`, `base_sha`, `intent_hash`, `json`, `model`, `created_at` | Go |
| `review_lessons` | `project_id`, `lens`, `text`, `source_comment_ids` JSON, `status` ('proposed','accepted','dismissed') | Go (propose); Swift→CLI (accept writes the file in Go) |

FKs cascade from `projects`; session links `ON DELETE SET NULL` (a deleted
session keeps its rounds readable — PROJ-02 "delete leaves nothing" is about the
workbench; deleting a workbench removes all of it). Mirrored into `schema.sql`,
`TestAllTablesExist`, the golden snapshot and the Swift test schema.

## 11. Desktop

- **Changes pane** (`WorkbenchChangesView`), a sibling of Terminal and Files in
  the workbench page, per session (and "the folder" when opened from the header).
- Left: phase strip (Deep), intent card, overview, chapter list with files, risk
  badges, Viewed boxes, comment counts; view switch **All / Since round K**.
- Right: Monaco's built-in diff editor (already in the bundle,
  `CodeEditorWeb`), side-by-side or inline; a line selection opens a comment view
  zone; agent notes as read-only zones; Keep/Undo on each hunk header. Same CSP
  and bridge rules as the code viewer (`wt.*` calls, security review #159).
- Pure logic in WatchtowerCore with tests in `Tests/Core`: chapter fallback,
  progress and active time, re-anchoring (shared with artifact comments),
  delivery-line composition. `.watchtower/review.md` is parsed in Go only.
- Sidebar badge: none new (a sent round is the agent's turn, not the owner's).

## 12. Errors and edge cases

- Not a repository, no base, git missing → envelope error, pane shows it, no
  partial state written.
- Huge diff → caps (§4.4), `truncated` banner.
- Lost snapshot → §4.5.
- Undo refused (file changed, `--check` fails, agent working) → the hunk shows why;
  nothing written.
- Overview failure → §7.1, the review proceeds.
- `.watchtower/review.md` symlinked, oversized or unreadable → built-in lenses
  only, a note in the pane.
- Two Desktop windows on one round → last write wins on owner-side fields;
  `send` is a guarded `UPDATE … WHERE status='open'` (zero rows = already sent,
  nothing typed).

## 13. Inventory (new module file `docs/inventory/review.md`)

- **REVIEW-01** — a review never writes a ref, the owner's index or a work-tree
  file, except an owner-pressed Undo (§4.6) and an owner-accepted lesson (§7.2).
- **REVIEW-02** — Undo applies only after the file matches the round's tree and
  `apply --check -R` passes, and never while the agent is working.
- **REVIEW-03** — a comment is never silently lost across rounds: it re-anchors
  or becomes `outdated` with its quote.
- **REVIEW-04** — a round's delivery is stored before anything is typed and goes
  only through PROJ-12's gates (PROJ-12 amended to name the review line).
- **REVIEW-05** — every git call of the reviewer runs with the background-read
  hardening; none runs a filter driver, hook or fsmonitor from the folder.

## 14. Testing

- Go: `internal/reviewdiff` against real temp repositories — snapshot with
  untracked files, base detection, rename, binary, caps, lost tree, revert-hunk
  refusals and success, `.watchtower/review.md` parsing, a malicious
  `.git/config`/`.gitattributes` that must not execute (REVIEW-05 guard).
- Go: MCP tools and `get_review` delivery marks; the overview prompt's JSON
  validation with fixtures (no live model).
- Swift Core: chapter fallback, progress/active time, re-anchoring, delivery line
  (dual path with Go, pinned by a testdata file like `asks.DeliveryLine`).
- Manual: the editor bridge check script extended for the diff editor.

## 15. Phasing (for the plan)

1. **Engine and data** — `internal/reviewdiff`, CLI, migration, inventory skeleton.
2. **Pane, Quick mode, comments, rounds, delivery** — usable end to end.
3. **Deep mode** — phases, chapters, lenses and `.watchtower/review.md`, pace.
4. **Agent side and AI** — `annotate_changes`, `reply_review_comment`, overview,
   skill pack v9.
5. **Undo and learning loop** — revert-hunk, Find repeats.

Phases 1–2 ship a working reviewer; 3–5 add the method on top.
