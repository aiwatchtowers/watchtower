# Watchman — the owner's twin, phase 1: learn and backtest (2026-11-16, board #1823)

Spec: `docs/superpowers/specs/2026-11-16-watchman-design.md` (approved, ask #1385). Plan: `docs/superpowers/plans/2026-11-16-watchman-phase-1.md`. Phase 1 is spec §12 item 1 with §8, §9, §11 and §11a: Watchman learns how the owner decides on a workbench and measures, on his own past decisions, how often a twin would have chosen the same. **It never acts**: no ask is answered, no permission decided, no review written, no session typed into (WATCHMAN-06). Phase 2 (acting at night, the journal, corrections) is planned only when the backtest says go.

## What it is

A leaf package `internal/watchman` reads the owner's own decisions in a workbench into a precedent index, builds per-category rule profiles and a learned sleep window, and runs a backtest: the newest decisions of each category are hidden, the twin decides them from what came before, and the answers are compared with what the owner really chose. Everything is per workbench and off until the owner presses **Start Learning** (Desktop) or runs `watchman learn --start`.

Fixed categories: `design`, `scope`, `ux_text`, `tests`, `review_code`, `review_doc`, `permission`, `finish`.

## Tables (migrations 00194, 00195)

- `watchman_workbenches` — one row per workbench Watchman is on for: `enabled_at`, `estimated_decisions` (taken at start, the progress denominator), `unlabelled` (decisions seen but not placed), `learned_through` (set when every source reports done on its backfill).
- `watchman_precedents` — one decision: `source` (`ask`/`review`/`spec`/`permission`/`turn`/`git`), `source_key` (UNIQUE with `workbench_id` and `source`: a commit hash or PR number repeats across repositories; an upsert never moves a row to another workbench), `category`, `situation`, `choice`, `owner_words`, `decided_at`, `weight`; `watchman_fts` (FTS5, porter) over situation/choice/words, kept by triggers.
- `watchman_cursors` — per workbench and source the opaque cursor `hi|lo` (each mark `decided_at,id[,sub]`): new rows past `hi` first, then the backfill older than `lo`, newest first.
- `watchman_profile` — per workbench a text per category plus the key `sleep_window`; `pinned`, `version`.
- `watchman_backtests` / `watchman_backtest_rows` — a run (`running`/`done`/`failed`, `verdict` `''`/`go`/`stop`, `cost_usd`, `progress`) and its per-category rows (`total`, `agree`, `wrong_high`, `cost_usd`, `baseline`, `status` `strong`/`weak`/`not_measured`).
- `watchman_skipped_keys` (00195) — decisions a source offered that got no category, keyed by `(workbench_id, source, source_key)` (cascading with the workbench), so a lookback does not offer them again.

Situation and owner words are redacted (`Redact`: known secret shapes, bearer tokens, token-looking words become `[secret]`) and clipped to 2048 runes (`SituationLimit`, `Clip`) before storage. "2 KB" means 2048 runes: a size bound, not a wire limit.

## Sources (closed list, WATCHMAN-03)

`DBSources()` + `TurnSource` + `GitSource`, all workbench-only (no Slack, mail, calendar or meetings):

| Source | Reads | Category |
|---|---|---|
| `ask` | answered owner asks; a review ask is a `review_doc` decision (verdict, comments as words); a question or check ask is left for the labeller; dismissed, open, withdrawn and automation-made asks are left out | labelled / `review_doc` |
| `review` | comments of a sent diff-review round, each round's outcome, an undone hunk (weight 2), a decided review lesson | `review_code` |
| `spec` | the owner's marks on spec review findings (ok, comment, not useful) | `review_doc` |
| `permission` | prompts the owner allowed or denied (pending, expired and answered-on-Mac are left out) | `permission` |
| `turn` | the owner's own lines in the workbench's agent sessions, with the agent text just before as the situation; sessions an automation started are left out; needs Agent analytics on the workbench | labelled |
| `git` | the owner's commits (authored by the folder's `user.email`, any author when none is set, and no agent trailer; the sleep window uses the same rule) that rewrite paths an agent commit changed in the 7 days before (`rewrote`), and the workbench's merged PRs (`merged`) | `tests` / `finish` |

A row a source cannot read (corrupt JSON, no `decided_at`) is skipped, logged by id and counted (`SkipCounter`); the cursor moves past it. The `git` and `turn` cursors set their `lo` mark to `end` once the backfill has drained, so a done source reads only what is new.

## Learning

`watchman.Learn` walks each source from its cursor in batches of 50. Precedents with no category go to the labeller (`NewLLMLabeler`, prompt `watchman.label`, light tier, up to 20 per call, a JSON array Go validates; a decision with no valid category is counted as `unlabelled`, its key marked skipped, nothing stored). One transaction writes a batch, its skipped keys, the unlabelled counter and the new cursor, so an interrupted pass resumes without duplicates. A budget is checked before each `Next` (a pass can overrun by one batch). `Estimate` (no model call) gives `decisions`, `need_labels` and `tokens` (~350 per labelled item, 12 owner turns assumed per session) for the owner to see before he starts.

## Profiles and the sleep window

Weekly per workbench (`phaseWatchmanProfile`): for each category with at least 5 precedents, one strong-tier call (`watchman.profile`) over the newest 60 returns at most 20 rule lines of at most 300 runes (`BuildProfiles`); a pinned entry is never replaced. The sleep window (`SleepWindow`, `UpdateSleepWindow`, key `sleep_window`, text `HH:MM-HH:MM`) is the median start and end of the longest gap between the owner's actions in each night (20:00 to 12:00 local) of the last 28 days, from his agent-log activity and own commits; fewer than 7 days with activity give no window. Wall-clock times, so DST neither shifts nor stretches a gap.

## Decide core (dry run)

`watchman.Decide(ctx, d, gen, store, Item)` retrieves up to 8 precedents decided strictly before `DecidedBefore` and not in `Exclude` (FTS), asks the strong tier (`watchman.decide`) and validates: the choice must be one of the options when there are options (`ErrChoiceNotOffered`), `precedent_ids` only ids that were retrieved, `confidence` low/medium/high, `importance` low/high. The item and the precedents go to the model as one JSON object between `<data>` and `</data>` (`json.Marshal` escapes `<` and `>`, so no text closes the fence). `Decide` never writes and never reads `watchman_profile`; the caller passes the profile and the owner's instructions (`LiveContext` for a live item).

## Backtest

`watchman.Backtest` (Task 8): per category the newest `HiddenPerCategory` = 30 precedents are hidden; the profile is rebuilt for the run from the 60 precedents before the category's oldest hidden decision and only `owner_instructions` older than that cutoff are passed (a stored or pinned profile is never used: it may postdate the decisions); each hidden item is decided with `DecidedBefore` = its own time and the hidden ids excluded. Only decisions whose situation does not give the answer away are hidden: a review round's outcome, an undone hunk and the git items (rewrites and merges) are **not measured** in phase 1 (they stay retrievable as precedents), so `review_code` is measured on the owner's review comments only. Scoring is **no worse than the owner** (asks #1422, #1423; migration 00196): the strong-tier judge (`watchman.judge` v3, `Judge.Grade(JudgeInput{Situation, Owner, Twin, Questions})`) grades each twin decision `same`, `acceptable` (a different but reasonable path) or `bad` (the owner would have had to undo it). A fixed-option item (asks with one single-choice question, review ask verdicts, permission allow/deny, review lessons) whose choice matches exactly is `same` with no judge call; a different option, a free answer and an ask answered with "Other" go to the judge (an empty choice leaves its `Choice:` line out; the twin's side carries its confidence). An ask with several questions is graded per question, each one scored decision (`total` grows by the number of questions); a grade the judge leaves out is `bad` but never counts toward `wrong_high`, an extra one is ignored; a reply with no grades at all is unreadable (retried once, then the run fails). An unusable twin reply (`ErrBadReply`) is `bad` with no judge call. Row columns: `agree` (= same), `acceptable`, `bad`, `wrong_high` (**bad while the twin's confidence was high**; the column kept its name), the base rate `baseline` (the share of the hidden decisions that always giving the owner's most common choice would get right; option-scored items only) and `rec_baseline` (the share of the scored decisions where the owner picked an option the agent marked recommended; per question; a decision with no recommended option is a miss) — both informational. A category row is `strong` when `bad/total <= 5 %` and `wrong_high = 0` (agreement does not gate), `weak` otherwise, and `not_measured` with fewer than 30 hidden precedents (no model call). Verdict `go` = at least 3 strong categories including `permission`, `design` or `scope`, else `stop`. `Backtest` takes `<workspace>/watchman.lock` itself (`ErrBusy` when held), closes a leftover `running` row as `interrupted` after taking the lock, writes progress after each item (`"<category>, <i> of <n> · <k> of 8 categories done"`) and on any error marks the run `failed` keeping the partial rows. Only a learned workbench (`learned_through` set) is backtested: half-learned history would measure the wrong thing.

## Daemon and CLI

- `phaseWatchmanLearn` — every cycle, for each workbench Watchman is on for; DB sources, the turn source where Agent analytics is on (turned off later, that source stays empty) and the folder's git history; one shared 5-minute budget per cycle, cursors carry the rest. Logs carry ids and counts, never text; a shutdown mid-pass stops cleanly.
- `phaseWatchmanBacktest` — weekly, never in-process (about 240 strong-tier calls): for at most one due workbench per cycle it launches a detached child `watchtower watchman backtest --workbench N` (`cmd.LaunchWatchmanBacktest`, own session, no agent markers, output in `watchman-backtest.log`) and does not wait. A workbench is due when it is learned, its success stamp `last_watchman_backtest_<id>.txt` (written by any finished run, manual included) is a week old or missing, and its launch stamp `last_watchman_backtest_launched_<id>.txt` is older than 24 h (a failed or still-running child is retried a day later). Nothing launches while the lock is held.
- `phaseWatchmanProfile` — weekly: stamp files `last_watchman_profile.txt` (success) and `last_watchman_profile_failed.txt` (retry a day later), read each cycle, no catch-up, a cancelled cycle writes neither.
- `watchtower watchman learn --workbench N [--start] [--json]` — without `--start` the estimate (`ok`, `workbench`, `decisions`, `need_labels`, `tokens`); with `--start` (owner verb, refused under an agent) turns Watchman and Agent analytics on for the workbench, runs one pass of up to 5 minutes (`ok`, `workbench`, `written`, `by_source`, `incomplete`, `unlabelled`, `analytics_turned_on`; on failure `ok`, `workbench`, `error`, `watchman_on`, `analytics_on`, `analytics_turned_on`) and leaves the rest to the daemon.
- `watchtower watchman profile --workbench N [--json]` — `ok`, `workbench`, `profiles` (`key`, `text`, `pinned`, `version`, `updated_at`), `sleep_window`; `profile set --key K --text-file F` pins an entry, `profile unpin --key K` lets the weekly rebuild replace it.
- `watchtower watchman backtest --workbench N [--force] [--json]` (Task 8; owner verb, refused under an agent; refused until the workbench is learned unless `--force`; busy gives `{"ok":false,"error":"busy"}`) — `ok`, `workbench`, `backtest_id`, `status`, `verdict`, `cost_usd`, `categories` (`category`, `total`, `agree`, `acceptable`, `bad`, `wrong_high`, `cost_usd`, `baseline`, `rec_baseline`, `status`). The text output prints each category as `same / acceptable / bad (bad while sure) · recommended-pick %`, then the verdict and the estimated cost.
- `watchtower watchman status [--workbench N] [--json]` (Task 9) — every workbench with its estimate (null when counting the folder's commits ran past 3 s) or learning progress (`written`, `estimated`, `done`), precedent counts, per-source state, sleep window, the last backtest and the last finished one (categories with `acceptable`, `bad`, `baseline`, `rec_baseline`), and `running` (the lock is held); a `running` row with no lock is shown `interrupted`. Pinned keys are in the plan's Task 9 and `TestWatchmanStatus_JSONKeysPinned`.

Prompts (all on both providers, `digest.WithSource(ctx, "<id>")`): `watchman.label` (light), `watchman.profile` (strong), `watchman.decide` (strong), `watchman.judge` (strong since v3, ask #1423).

## Desktop (Task 10)

**Settings → Profile → Watchman**, after Instructions: `WatchmanCenter` over `watchman status --json`. States: not learned (the estimate and **Start Learning**), learning (the busy line `Learning… <written> of <estimated>`), never run, running (the progress line), failed or interrupted (the error, **Retry** and the last finished results), results (per category agreement, bad while sure, the base rate and strong / weak / not measured, and the note naming the bar: at most 5 % bad, none bad while sure). `WatchmanBacktestCategory` decodes `acceptable`, `bad` and `rec_baseline` (missing → 0); phase 1 shows no verdict and no new columns. The screen does not show the verdict or the cost in phase 1: they come in the CLI output of `watchman backtest`. A workbench whose estimate timed out says so instead of the estimate line. Phase 1 has **Run Backtest Now** and **Retry** only; Edit, Unpin and extra limits are absent until phase 2. The Swift decoding test reads a Go-written fixture (`internal/watchman/testdata/status.json`, a Go↔Swift dual path).

## Guards

`internal/watchman/guard_test.go`: `TestWATCHMAN03_SourcesAreOwnerOnly`, `TestWATCHMAN06_NoActingImports`. Contracts in `docs/inventory/watchman.md`.

## v1 limits

- The sleep window treats the night's 20:00 and 12:00 edges as actions and needs only 7 active days of 28, so it is biased toward the edges for a sparse owner.
- Agent commits are recognised by a `Co-Authored-By` trailer only; an agent that omits it makes its commit look like the owner's, and a merge an agent made may be counted as the owner's.
- A row committed behind a source's `hi` mark by an out-of-order writer is missed (the git source rescans 30 days behind `hi` and is exempt); a spec mark edited after the answer is not re-read.
- Handover asks (`finish_session`'s `handover_ask_id`) carry no mark in the database: they are learned as ordinary questions and the labeller may or may not file them under `finish`, so `finish` can be thin.
- The `unlabelled` counter is additive and can inflate when the CLI and the daemon overlap; it is a display figure only.
