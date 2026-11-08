# Reviewing a big branch — technical spec (board #1025)

**Date:** 2026-11-07 · **Business spec:** `2026-11-07-big-branch-review-design.md` (the owner's; its Decisions bind this file)
**Contracts:** `docs/inventory/review.md` REVIEW-01..05 · **Feature note:** `docs/features/diff-reviewer.md`

This file holds decisions and contracts only. What the business spec says is not repeated.

## 1. Shape

```
                 (instant, no AI)                                (AI, streamed)
round / session ─► reviewmap.Build ─► Map{chapters, danger, noise} ─► pack into batches ─► batch calls (parallel)
                                                                                         └► summary call (only when > 1 batch)
                                                                    ─► review_overview_parts (per chapter) + review_overviews (assembled)
```

- New leaf package `internal/reviewmap`: lane attribution, noise, danger, chapters. It is pure
  except for git reads, which go through `reviewdiff.Repo`'s hardened runner (REVIEW-05; no new
  `exec.Command("git", …)`).
- `internal/reviewai` gains the batch and summary calls; the one-call path is the 1-batch case
  of the same code, not a second path.
- Go builds the chapters for everyone (Desktop, agent, finish gate). Swift's
  `ReviewChapters.mechanical` is removed — no Go↔Swift dual path.

## 2. The map (`internal/reviewmap`)

### 2.1 Lanes (attribution)

Input: repo, `base` (the round's merge-base), `head` = the round's `head_sha`. Migration
00179 adds `review_rounds.head_sha TEXT NOT NULL DEFAULT ''`, set by `review start` and
Refresh from `git rev-parse HEAD` of the session folder at snapshot time (a read; the
session form takes it the same way); a branch-tip round (#1012, `source = 'pr'`) stores the
tip commit it read, and a move of an open round (`RepointReviewRound`) rewrites it with the
tree. A round with an empty `head_sha` (made before this
release) gets no lanes (`lanes_partial = true`) — never the folder's HEAD of today, which
may be another history. Uncommitted files of the snapshot have no commit. Walk:

- `git rev-list --first-parent --parents <tip> ^<excl>…` from `head`, excluding `base`.
- A merge whose second parent is an ancestor of the default branch tip is a **base sync**:
  skipped.
- Any other merge is a **lane merge**: its lane name is parsed from the subject — `Merge pull
  request #N from <owner>/<branch>`, `Merge (remote-tracking )?branch '(origin/)?<b>'( into
  '?<t>'?)?`, `Merge (origin/)?<b>[: ]`; the lane is named by the source.
  `Merge tag …`, `Merge commit …`, `Merge branches …` and anything else unparsed → `lane:?`.
  An octopus merge walks its second parent only and sets `lanes_partial` (v1). Each commit
  counts once in the
  whole attribution (a global seen set; the first lane that reaches it in walk order keeps
  it), so a lane merged into two places is not double-counted.
- Lane titles come from a `TitleSource` that can fail: on error the attribution is partial and
  no tag is validated against the (empty) title maps — a Jira key stays only when it is in the
  branch name, `#N` is not a tag. Recurse into the second parent with `excl = [first parent, base]`.
- **A fast-forwarded reverse merge:** a merge M on lane L whose parsed source is L and whose
  `into` target T is another lane (T merged L into itself, then L fast-forwarded to M): the
  commits reachable from M^1 and not from M^2 or `base` are lane T (walked as a lane, tip
  M^1, `excl = [M^2, base]`, nested merges included), and L's own walk continues from M^2.
  The walk therefore runs segment by segment (one first-parent walk per segment).
- A lane is an **integration lane** when its own first-parent walk contains lane merges (the
  top branch always is). A direct commit on an integration lane is labelled by its subject's
  tag, first match wins: Jira-style key `[A-Z][A-Z0-9]{1,9}-\d+` (validated against
  `jira_issues` when the key's project is synced, else kept only if it also appears in the
  branch name), board ref `#\d{2,6}` (kept only if it is a target id of this workbench), plan
  tag `\(([A-Z]{1,2}\d+[a-z]?)\b`, conventional-commit scope `^\w+\(([^)]+)\)!?:`. Untagged →
  the lane itself. A direct commit on a non-integration lane belongs to that lane.
- Per-commit file lists come from `git log --first-parent --no-renames --name-only
  --format=…` over each walk (one git call per walk, not per commit).
- A file's **lane** is the lane with the most commits touching it; ties go to the later one.
  Its other lanes are kept as `also` labels.
- Files changed in the snapshot but in no commit (uncommitted work, or a branch whose history
  could not be read) have no lane.
- Bounds: at most 2,000 first-parent commits and 200 lanes across the whole attribution; past
  them the remaining files have no lane (no error) and `map.lanes_partial = true`. The whole map has a 20 s budget; on timeout every file falls
  back to the package grouping and `map.lanes_partial = true`.

**Lane titles.** In order: a board target of this workbench whose `branch` equals the lane's
branch name (new `db.TargetsByBranches(projectID, []string)`; open or closed, newest first);
a Jira key found in the branch name (`GetJiraIssuesByKeysMap`, title = summary); a board
ref `#N` tag (the target's text); else the branch name or tag as is. The lane also carries the
target id / Jira key when found, so the summary call can read their intent.

### 2.2 Noise ("Can skip")

A file is noise when any holds: today's `collapsedReason` (lock and generated), a path segment
`testdata`, `Fixtures`, `fixtures`, `__snapshots__`, `golden`; suffix `.snap`, `.pbxproj`,
`.xcodeproj/…`; a binary file; or a repository pattern (§2.4 `## Can skip`). The Watchtower
repo lists `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`,
`internal/db/testdata/schema_golden*` and the Kit's generated proto in its own file, not in
code. Noise is never sent to a model; it forms one chapter, key `collapsed` (today's key,
kept), title **Can skip**, with file count and changed lines.

### 2.3 Danger signals

Per file, from the path, status and diff lines only (no AI, no build). Levels: `breaking`,
`significant`, `normal`.

| Signal id | Rule | Level |
|---|---|---|
| `migration_edited` | modified or deleted file under a `migrations/` directory | breaking |
| `api_removed` | a removed line declares an exported Go func/method/type/const/var (`^-\s*(func( \([^)]*\))? [A-Z]\w*\|type [A-Z]\w*\|(const\|var) [A-Z]\w*)`) or a Swift `public`/`package`/`open` declaration, and no added line in the same file declares the same name | breaking |
| `test_deleted` | a deleted file the test heuristic (§2.5) marks as a test | breaking |
| `migration_added` | added file under `migrations/` | significant |
| `dependency` | base name in `go.mod`, `package.json`, `Package.swift`, `composer.json`, `Cargo.toml`, `pyproject.toml`, `requirements*.txt`, `Gemfile`, `build.gradle*`, `pom.xml` | significant |
| `ci` | under `.github/workflows/`, `.gitlab-ci.yml`, `.circleci/`, `Jenkinsfile`, `Dockerfile*`, `helm`/`charts` dirs | significant |
| `security_path` | a path segment or base name containing `auth`, `token`, `secret`, `credential`, `permission`, `policy`, `crypto`, `keychain`, `oauth` (case-insensitive) | significant |
| `file_deleted` | any other deleted non-noise file | significant |
| `repo:<level>` | a repository pattern (§2.4) | its level |

A file's level is the highest of its signals; a chapter's is the highest of its files'. The
map keeps every signal per file (`signals: [id…]`) for badges.

### 2.4 Repository patterns: `.watchtower/review-map.md`

Read from the **workbench folder** under the lens-file rules (lstat, no symlink,
`O_NOFOLLOW|O_NONBLOCK`, fstat re-check, ≤ 65,536 bytes; a refusal = no patterns + a note in
the map). Format: headings `## Breaking`, `## Significant`, `## Can skip`; under each, lines
`- <glob>` (`path.Match` per segment plus `**` for any depth). Anything else is a note line,
like the lens parser. It is a separate file because every `## ` heading of `review.md` is a
lens. This repo gets one in the same PR: `docs/inventory/**` and `**/*guard*_test.go`-style
guard tests and `internal/prompts/defaults.go` as breaking; `internal/db/schema.sql`,
`internal/tools/**`, `cmd/**` flags as significant; the noise files of §2.2.

### 2.5 Chapters

Order of building (each later step gets only the files no earlier step took):

1. The agent's chapters (`review_notes` kind `chapter`, today's first source), keys
   `agent:<n>` exactly as `ReviewChapters.resolve` makes them today: `n` is the 1-based index
   over all agent chapter specs, empty ones included (so numbers may have gaps), and core
   chapters are moved first after numbering. A Go↔Swift golden fixture pins it before the
   Swift code is deleted.
2. Noise → `collapsed`.
3. Lane chapters: files grouped by lane; a lane over 400 changed lines is split by directory
   with today's Swift algorithm ported as is (test files go with their subject; a directory
   over 400 lines splits into parts). Keys `lane:<lane>` and `lane:<lane>/<dir>[#N]`.
4. The rest by directory → `dir:<dir>[#N]` — the exact keys Swift makes today, so saved
   `review_checks` and `review_rounds.chapter_key` on package chapters keep matching.

`ai:` chapters no longer exist (the model describes the map's chapters; it does not invent
its own). A saved `ai:` key no longer matches: the round opens on the first chapter. Accepted.

**Order (the reading order):** by level (`breaking`, `significant`, `normal`), then agent
chapters before the others, then by changed lines descending; `collapsed` last. `core` is
true for `breaking` chapters and for agent chapters marked core.

**Test heuristic** (ported from Swift `isTest`, exported as `reviewmap.IsTest`): a `Tests`,
`tests`, `__tests__` dir; base name ending `_test`, `Tests`, `Test`, `.test`, `.spec`; prefix
`test_`.

### 2.6 Map output

`workbench review map (--round R | --session S) --workbench W --json` — instant, no AI, no
writes. Envelope `ok`, `map`:

```
map: { chapters: [{key, title, level, core, paths, changed_lines, lane?, target_id?, jira_key?,
                   signals_summary: {id: count}}],
       files:    [{path, chapter, level, signals, lane?, also?}],
       lanes_partial, diff_truncated, notes }
```

Pinned keys (Go test + a Swift fixture `review-map.json` decoded by WatchtowerCore).

## 3. The AI overview

### 3.1 Packing

- Batch input budget `MaxBatchLines = 2500` diff lines (was one call of 6,000). Chapters in
  reading order are packed greedily (first fit, keeping order) into batches; `collapsed` is
  never packed.
- A chapter over the budget gets a batch of its own and is cut inside: its files in
  descending level, then path; each file shows at most `MaxOverviewFileLines = 300` lines
  (the first 300 of its hunks, then `(+N lines not shown)`) — a file is no longer dropped
  whole for being long.
- 1 batch → one call, prompt `review.overview` v3, which returns the chapter descriptions
  **and** `summary`, `coverage`, `out_of_scope` (today's one call, same cost for a small PR).
- \> 1 batch → each batch with prompt `review.chapters` v1 (chapter descriptions only, no
  intent in its input), then one `review.summary` v1 call that sees: the intent items, the
  map (chapter titles, levels, paths, signals), and every chapter description — no diff. It
  returns `summary`, `coverage`, `out_of_scope`.
- Whenever every packable chapter fits one batch, the one full call is made even if some
  chapters have part rows (a small PR is never judged from descriptions alone); its chapter
  descriptions are written as parts too.

**Intent items.** The session's items as today (numbered first), then one item per lane
ticket found in §2.1 (a board target or a Jira issue; title + intent / summary), each with a
`source`: `session` or `lane`. Coverage entries carry the item's `source`. The owner sees
coverage of every item; the finish gate (§4) checks only `source: session` items, so its
strictness does not change. A round with no session has only lane items (it had none).
`IntentHash` (the `review_overviews` key) covers the session items only, byte-identical to
today's hash: lane items go to the model and into the assembled JSON but are not part of the
key, so a lane ticket whose title or summary changes later does not hide the cached overview
from the finish gate (which needs no map). The map lists every lane the attribution found
(`lanes: [{name, title, target_id?, jira_key?}]`), and lane intent items come from that list,
not from the chapters, so a lane whose files all went into an agent chapter keeps its item.

Chapter description (both prompts): `{key, what (≤ 600 runes), risks: [{path, level, why}]}`
with risk `level` in today's `low|medium|high` (the map's `breaking|significant|normal` is a
separate key on the chapter, never mixed); unknown keys/paths dropped entry by entry as
`ParseOverview` does today. Chapters no longer carry `lenses`: since #958 no screen shows a
per-chapter lens list (`ReviewChapters.lenses(for:)` has no caller) — it is deleted.

### 3.2 Budgets (by size)

| Item | Value |
|---|---|
| Parallel batch calls | `min(batches, 4)` |
| One batch call | `90 s + 60 s × ceil(lines / 1000)` of the batch's shown diff lines |
| Summary call | 2 min |
| One run | `waves × max(call budget) + summary`, `waves = ceil(batches / parallel)`, capped at 45 min |
| Desktop wait | no total timeout on the streamed form; the run prints `{"event":"tick"}` every 30 s while it lives, and the Desktop fails it when no line arrives for 5 min (a stuck process, never a slow call) |

Chapters not reached before the run's ceiling get `state: "not_started"`; `--continue`
describes only chapters without a part row.

The strong tier as today; purposes `review.overview`, `review.chapters`, `review.summary` in
the LLM usage ledger.

**Summary always runs** at the end of a run with ≥ 1 described chapter (multi-batch) — it
never waits for every chapter. Chapters with no part row (failed or not reached) go into its
input as `key, title, paths, signals, "not described"`; its reply's `not_covered: [key]`
lists them (validated against the input) and the prompt rule caps an intent item whose
evidence lies only in such chapters at `partial`. The assembled overview is written to
`review_overviews` with `incomplete` = those keys; a later chapter retry rewrites it
(summary re-run). With zero described chapters no summary is made and nothing is assembled.

### 3.3 Cache

- New table `review_overview_parts` (migration 00179, with `review_rounds.head_sha`): `project_id` (FK cascade), `part_hash`,
  `json`, `model`, `created_at`; PK `(project_id, part_hash)`. 30-day pruning on write.
- `part_hash` = sha256 of: chapter key, for each file in it `(path, old blob, new blob)`, the
  agent's line notes on those files, the prompt id + version. No intent and no other notes:
  a Refresh, an intent edit or a note elsewhere leaves a chapter whose files and own notes did
  not change on its row. (A new agent *chapter* note re-cuts the chapters around it; those
  get new keys and are redone — accepted.)
- Batches are made only of chapters without a part row. A batch's reply is written as one row
  per chapter.
- The assembled overview is written to `review_overviews` under today's key
  `(project, tree, base, intent_hash)` whenever a summary exists (§3.2), with `incomplete`
  naming the chapters it could not see. No summary → nothing written there.

### 3.4 Overview JSON (additive)

Today's keys stay (`summary`, `coverage`, `out_of_scope`, `risk`, `chapters`). `chapters` now
lists the map's chapters with `key`, `title`, `level`, `paths`, `core`, `what`; `risk` is the
union of the chapters' risks. New keys: `incomplete: [chapter key]` (always present, empty
when complete). Swift's `ReviewOverview` decodes the new keys as optional.

### 3.5 Streamed form

`workbench review overview … --json --stream` prints JSON lines, the last one is the usual
envelope:

```
{"event":"map", "map":{…}}                                  (first, before any model call)
{"event":"waiting","by":"desktop|agent|cli"}               (another run holds the lock, §3.7)
{"event":"tick"}                                            (every 30 s while the run lives)
{"event":"chapter","key":K,"state":"cached|ok|failed","what":…,"risks":[…],"error":{class,text}?}
{"event":"summary","state":"ok|failed", …}
{"ok":true,"overview":{…},"incomplete":[…]}                 (last)
```

Chapter states in events: `cached|ok|failed|not_started`.

**Map failure on the Desktop.** If `review map` fails (exit ≠ 0, bad JSON, or no answer in
60 s), `ReviewChangesModel` shows the diff's file list without chapters and the banner
"Chapters could not be built — Retry" (Retry re-runs `review map`); the overview is not
started without a map. The Go side logs the error class only.

Without `--stream` the command behaves as today (one envelope). `--chapter K` (repeatable) redoes only
those chapters (ignoring their part rows) and then the summary; `--summary` redoes only the summary from the cached
parts (refused with `missing_parts` when a part is missing); `--cached-only` keeps its meaning (assembled
overview only).

### 3.6 Errors

Error classes: `timeout`, `provider`, `parse`, `cancelled`, `too_large` (the diff cap),
`busy` (another run held the lock past `LockWaitCap`, §3.7). Text
for the owner, one sentence, no repetition of the provider's words:
`timeout` → "The overview of “<title>” did not finish in <N> min." (N = its budget, rounded up) ; `provider` → "The AI
provider failed on “<title>”." ; `parse` → "The AI answer for “<title>” could not be read." ;
summary failures the same with "the summary". The provider's own text goes to stderr and the
envelope's `detail` (the Desktop shows it behind a disclosure), never into the log file:
logs carry the class, the chapter's index and counts only (FILES-01).

### 3.7 One run at a time

- Every model-calling form (the full run, `--continue`, `--chapter`, `--summary`, with
  `--round` or `--session`) holds an exclusive lock for its whole run:
  `fsutil.LockFile` on `<workspace>/locks/review-overview-<project>-<sha256(real path of
  the snapshot folder)[:16]>.lock` (the workspace, never the repository — REVIEW-01 is
  untouched). The key is the folder, not the tree: the agent's and the Desktop's snapshots
  of a branch being edited differ, yet share most part rows. The kernel drops the lock with
  its holder; `--cached-only` and `review map` take none.
- The holder writes `{"by":"desktop|agent|cli","started_at":…}` into the lock file
  (`--caller desktop` from the Desktop; `agent` when the agent marker is set; `cli` otherwise).
- **Only the streamed form waits** (`--stream`, the Desktop). Every other form that finds
  the lock held answers at once with class `busy`, exit 1, and "<Branch review|Another run>
  is describing this branch now; run this again when it finishes — what it describes is
  kept." It never waits, so neither a shell time limit nor an MCP call can hang on it.
  `finish_session` never runs the overview: it reads the cached one, as today (§4).
- A streamed run that finds the lock held does not call the model. It waits (`LockFile` with its own
  ctx: `LockWaitCap` = 50 min, above the 45-min run ceiling; the wait does not count into the
  run's ceiling, which starts when the lock is taken), and while waiting
  it re-reads its chapters' part rows every 5 s: with `--stream` it prints
  `{"event":"waiting","by":…}` once and every 60 s, and a `chapter` event (`cached`) for each
  part that appears. Once it holds the lock it re-reads the parts and calls the model only
  for chapters still without one — the first run's work is never redone (same `part_hash`
  ⇒ same row). A lock wait that hits `LockWaitCap` ends as class `busy` with
  "Another overview of this branch is still running." — the Desktop shows it on the progress
  card with Retry.
- An agent's run killed midway (its shell's time limit) leaves every finished chapter's part
  row; a re-run describes only the rest. The skill pack (version bump) and the
  missing-overview refusal tell the agent to run the command in the background when the
  branch is big (the map's shown lines > one batch).
- The Desktop starts at most one overview process per session. **Retry** of a chapter (or of
  the summary) while it runs sets that chapter `queued`; when the process ends, one
  follow-up run is started with every queued key (`--chapter` is repeatable; the summary is
  remade once after them). **Refresh** during its own run sends SIGTERM to that process (class
  `cancelled`, finished parts stay — each part row is its own short write) and starts on the
  new snapshot. While its process is only `waiting` for another holder (the agent's run),
  Refresh re-reads the map and file list, terminates its own waiting process and starts a
  new one, which waits again; the Desktop never signals another process. Leaving the screen does not stop it (the run is owned by
  `ReviewChangesModel`, §5).
- Part rows are written with `INSERT OR REPLACE` in their own short transaction; two
  processes writing one `part_hash` (only possible outside the lock: none today) would store
  identical content.

## 4. The finish gate

`checkOverviewGate` is unchanged in what it checks: every `source: session` intent item
`done` (lane items are the owner's view only, §3.1). It reads the
assembled overview as today (an `incomplete` one counts; its coverage already caps items
whose work it could not see); a missing one refuses with today's text plus "Re-run it; only
the missing chapters are redone."
The agent's form (`--session`) runs the same packing; `finish_session` itself never runs
the model and never waits (§3.7).

## 5. Desktop (phase 2)

- `ReviewChangesModel` reads `workbench review map` on open and on Refresh; chapters, levels
  and the file list's badges come from it. `ReviewChapters.resolve`/`mechanical`/`lenses(for:)` are removed;
  `done(_:isViewed:)` stays.
- The overview is run with `--stream`; the model holds per-chapter state
  (`pending|running|queued|waiting|ok|cached|failed(text)`); a failed chapter shows its line
  and **Retry** (`--chapter K`; during a run it is `queued`, §3.7). A `waiting` stream line
  shows "The agent is describing this branch — chapters appear as it finishes them" on the
  progress card. The Meaning phase shows the summary when it arrives; the chapter list
  fills in as lines arrive. The streaming state lives on `ReviewChangesModel`, which
  `WorkbenchesViewModel.reviewModels` already keeps per session across navigation; the
  running stream is owned by the model, not the view.
- Sections in the chapter list: **Breaking and significant**, **Other changes**, **Can skip**
  (folded). Badge per file from its signals. Counter "N chapters / M files left" (left =
  not Viewed, `collapsed` excluded). With one non-noise chapter the chapter list is hidden.
- A `diff_truncated` map shows a banner: "This branch is past the reviewer's size limit
  (50,000 changed lines); the files after it are not shown."
- Quick mode: the map always; the overview cached-only as today.

## 6. The reviewer (phase 3)

- An embedded chat surface `ReviewerSurface` (`ChatSurfaceSpec`), `readFolder` = the folder
  the round was snapshotted from (the session's worktree when it has one — see the open
  question on `--read-folder` below), `toolAccess` `.draftOnly` (no Watchtower tools;
  `--read-folder` refuses tools).
- One thread per branch: a table `review_reviewer_threads(project_id, branch, conversation_id,
  created_at)`, PK `(project_id, branch)`, Desktop writer (migration in phase 3). The branch
  is the round's `branch` column (#1012) when set, else the folder's checked-out branch; a detached HEAD keys by `session:<id>`. Two sessions on the same
  branch share the thread (same code). A renamed branch starts a new thread.
- `ai query --read-folder` is widened (owner, ask #560): besides a workbench's own folder it
  accepts a session worktree of that workbench recorded in `terminal_session_worktrees`
  (exact real path, resolved symlinks; for a workbench bound to a repository subfolder,
  that subfolder inside the worktree — the round's `folder_root`; anything else refused as
  today). The capability
  contract of spec 2026-10-02 §9.1 is amended in the same PR.
- **Send to author** on an answer makes a design comment in the open round of the Branch
  review the owner is looking at (that session's round; the owner's own write; the round's
  existing delivery path). With no open round it is disabled with "Start a round to send". Nothing reaches the author's session otherwise.
- The reviewer and the author's Workchat share today's agent chat panel (PanelSplit, same
  toolbar toggle), switched by a **Reviewer | Author** segmented control; the Workchat side
  stays as it is.

## 7. Contracts

- REVIEW-01 amended (owner): the overview also writes `review_overview_parts`; `start` and
  Refresh store `head_sha` on the round (a database row, read with `rev-parse`); `review map`
  writes nothing. No other contract changes. REVIEW-05: every new git call goes through the
  hardened runner; a guard test lists the new call sites.
- Migration 00179 mirrored in `schema.sql`, `TestAllTablesExist`, golden and the Swift test
  schema.
- Prompts: `review.overview` v3 (bump reason: chapter descriptions of given keys),
  `review.chapters` v1, `review.summary` v1 — through the `add-ai-prompt` skill (both
  providers).

## 8. Tests that must exist

- reviewmap: synthetic repo with an integration branch, two lanes, a nested integration lane,
  a base sync, a fast-forward `into` merge, tagged and untagged direct commits, a file touched
  by two lanes, uncommitted files → expected lanes, `also` labels, chapter keys and order.
- A single-author branch with no tags → `dir:` chapters identical to today's Swift output
  (golden shared with a Swift test before the Swift code is deleted).
- Danger: one case per signal row, including `api_removed` not firing on a rename-in-place
  (removed and re-added name) and firing on a real removal.
- Packing: 3-file diff → 1 batch, one call, summary inside; a synthetic 700-file branch with
  fixtures → no noise in any batch, ≤ 2,500 lines per batch, every non-noise chapter in
  exactly one batch.
- One batch failing (stub generator returns an error / hangs past its budget) → other
  chapters `ok`, `incomplete` lists the failed ones, the summary is made and the assembled row
  is written with `incomplete` (zero described chapters → nothing in `review_overviews`); `--chapter`
  redoes only it and then assembles.
- Cache: Refresh after editing one file redoes only its chapter; parts survive a new process.
- One run at a time: two processes on one folder with a stub generator that counts calls —
  the second waits, streams `waiting` and the first run's chapters as `cached`, and makes
  calls only for the rest (no `part_hash` called twice); the lock is released when the holder
  is killed; a holder that never releases with a shortened `LockWaitCap` → `busy` and the Desktop
  card text; a non-streamed run against a held lock returns `busy` at once (no wait); a run
  killed after two of four batches keeps two parts and a re-run calls only for the rest. Desktop: Retry during a run → `queued` → one follow-up `--chapter` run with all
  queued keys; Refresh during a run → the process is terminated and parts kept.
- Budgets: the §3.2 table for 1, 4 and 20 batches (pure function).
- FILES-01 canary over a failing chapter run (no title, path or provider text in the log).
- Stream golden: `review-overview-stream.jsonl` fixture decoded by WatchtowerCore.
- Map under 30 s on the synthetic 700-file branch (a benchmark, not a CI timing assert).

## 9. v1 limits

- Lane attribution reads commit subjects only, not bodies or trailers.
- Squash-merged lanes leave no lane merge; their tags (if any) are the only signal.
- `api_removed` is line-based and misses a removed exported name split over several lines.
- `api_removed` keys a declaration by its bare name: Swift `init`/`subscript` overloads share
  one key, Go methods of different receivers collide, `<<T` in a generic operator reads as
  `<`, and exported names inside grouped `const (`/`var (`/`type (` blocks and removed struct
  fields are not detected.
- A folder round's head branch (used for the `into` rule on the top lane and for Jira keys in
  the branch name) is the folder's branch at the time of the map, not stored with `head_sha`;
  a branch renamed after the round only changes those labels.
- With no default branch found (a trunk/develop-only repo), base syncs cannot be told from
  lanes: the map keeps the attribution, sets `lanes_partial` and says so in a note.
- Go compares paths byte for byte, Swift by canonical equivalence: a path not in NFC (for
  example committed from Linux) may fall into another `dir:x#N` part than the Swift builder
  put it in, and an agent chapter path written in another normalization is dropped.
- In `.watchtower/review-map.md` a glob without `/` matches a top-level file only (`**/` for
  any depth); a path matching both a danger section and **Can skip** takes the danger level.
- The summary of a multi-batch branch judges coverage from chapter descriptions, not the
  diff; it may say `partial` where a full read would say `done` (the agent can hand over).
