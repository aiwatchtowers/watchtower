# Agent coach — weekly proposals to improve the owner's agent setup (2026-10-26, board #1120, Plan 1: the loop)

Spec: `docs/superpowers/specs/2026-10-26-agent-coach-design.md`. Plan 1 ships the loop and the CLI; the Analytics screen redesign, Home's card and the miner fold are Plan 2. COACH-01 in `docs/inventory/coach.md`.

Once a week the daemon reads what already exists (the owner's marks on spec review findings, first-round code review comments, the owner's lines to agents and chats, Analytics hints), asks the strong-tier model for concrete edits to the owner's own setup, validates them in Go and stores them as proposals. **Nothing is applied without the owner's Accept.** An accepted edit is measured for 14 days and gets a verdict.

## Tables (migration 00162)

- `coach_proposals` — one proposed edit: `fingerprint` (UNIQUE, from the destination and the change, so a declined or superseded edit never returns), `kind` (`add`/`cut`/`replace`), `destination`, `workbench_id` (NULL = global), `prompt_id`, `title`, `why`, `metric`, the whole `before_text`/`after_text`, `evidence` (JSON `[{kind,ref}]`, at most 12), `sources` (distinct sources, recomputed in Go), `status` (`open`/`accepted`/`declined`/`superseded`/`rolled_back`), `reverts_id` (a cut of an earlier no-effect edit), `baseline`/`baseline_n`, `verdict` (`works`/`no_effect`/`too_little_data`), `verdict_value`, timestamps.
- `prompt_additions` — owner-approved lines added to a Watchtower prompt (`prompt_id`, `text`, `proposal_id`).
- `spec_reviews.findings` — findings counted in the stored result when the review finished (`-1` = rows from before the migration, not counted); a re-run replaces `result`, so the first round's number is kept here.
- `spec_review_marks.state` gains `not_useful` (see the amended `docs/features/spec-review.md`).

## Metrics (`internal/coach.Measure`)

Over `[since, until)`, per workbench or (id 0) over every workbench with analytics on; numerators and denominators are summed, then divided once. A value with a zero denominator is `known: false`.

| Key | Definition | Per |
|---|---|---|
| `corrections` | interrupts + rejected calls | task (a leaf target, `agentreport` tasks attribution) |
| `task_hours` | agent hours | task |
| `task_cost_usd` | agent cost | task |
| `owner_loop` | owner time / active time | sessions |
| `spec_findings` | findings of the first review round of a spec | first-round spec review |
| `review_comments` | non-carried comments of a diff review's first round | first-round review |

Sessions starting at or after `until` are left out. With workbench 0 the agent metrics cover the analytics-on workbenches only, the two review counts every workbench.

## Signals, gates, proposals

- Signals (28-day window, newest first, at most 400, each cut to 600 runes): `ask:<id>#<key>` (a comment mark = a real problem, a **Not useful** mark = noise; other marks and no mark are skipped), `round:<id>#c<id>` (first-round review comments), `s<id>`/`c<id>` (owner lines of a session or chat, the instruction miner's input), `hint:<id>@wb<id>` (an Analytics hint with an action). Owner asks and the time agents wait for the owner are not read directly: they reach the coach only through the Analytics hints (H4: "waiting for you" over 30 % of active time).
- Gates: at least 3 distinct sources per proposal (a hint counts as one source); at most 3 open proposals; no model call without a free slot or three sources; one open proposal per destination text (an Accept of one would supersede the other).
- Validation (`coach.Validate`) in Go: evidence refs must exist, counts are recomputed, the destination must be allowed, `find` must match the current text once (whole lines), the result must fit the destination's budget (`instructions.MaxRunes` 1000 for owner texts; `prompts.MaxAdditionRunes` 600 and 300 per line for additions; `~/.claude/CLAUDE.md` current length + 400 runes, never past 4000). Owner text goes to the model on stdin only and never to a log (FILES-01).
- Prompt `coach.propose` v2 (strong tier, both providers); titles in `digest.language`. It sees the earlier proposals as OPEN, DECLINED, ACCEPTED, ROLLED BACK and NO EFFECT groups and is told never to repeat the first four in other words; its allow-rule list is the Go table word for word (`TestCoachPrompt_AllowTableMatchesGo`).

## Destinations

In v1: the global and per-workbench session instructions and target procedure, the chat text (`owner_instructions`, `projects.session_instructions`/`target_procedure`), prompt additions, `~/.claude/settings.json` `permissions.allow`, `~/.claude/CLAUDE.md`. **Never** a repository file (`CLAUDE.md`, `.watchtower/*`, `.claude/skills/`, a project `.claude/settings.json`).

**Prompt additions.** A coach edit never changes a template or sets `customized`: `prompts.Store` appends the prompt's additions as one `=== OWNER PREFERENCES (approved by the owner) ===` block at resolve time, so shipped prompt upgrades keep reaching the owner. An addition is one line, no `%` and no `{{`/`}}`. Prompts a built-in automation owns are skipped.

**Allow rules** use the coach's own exact-match table (`SafeAllowRule`): `Bash(<verb>:*)` for `cat`, `ls`, `grep`, `head`, `tail` and the exact toolchain commands `go test`/`build`/`vet`, `swift test`/`build`, `cargo test`, `npm test`, `pytest`; nothing else (no `sed`, `find`, `rg`, `make`, `npm run`, no arguments). The list may only grow through Accept, and a proposal must add at least one rule it does not have. Residual risk, accepted by the owner: a build/test rule runs project code by design, so `go test -exec`, `go build -toolexec` and `-vettool` reach any program without a prompt; every rule needs Accept, and unprompted rules apply anywhere on the machine.

**`~/.claude/CLAUDE.md`** is read only as a regular, UTF-8 file up to 256 KB (a symlink, special file, larger or non-text file is never targeted and gets no cut), edited as an exact-text replace through an atomic write that re-reads the file just before the rename.

## Accept, decline, rollback, verdicts

- **Accept** (`coach.Applier`): the destination must still hold the proposal's `before_text` (else the proposal is `superseded`, `ErrStale`); an owner text is written by compare-and-set; the baseline of the proposal's metric over the previous 14 days is stored; if the status write fails the destination is put back. "Edit then accept" passes the owner's whole text, checked by the same rules.
- **Decline** is for good (the fingerprint stays).
- **Rollback** restores the before-state when the destination still holds the accepted edit; otherwise it returns a diff and `ErrChangedSince` until `--force`. A prompt loses only the additions this proposal made; the allow list loses only this proposal's rules (it is not a byte restore: Claude Code writes the file too).
- **Verdict** (`coach.Judge`, 14 days after Accept, retried to 42 days): under 5 sessions or no baseline/value is `too_little_data`; a value at least 10 % below the baseline is `works`; anything else is `no_effect`. A baseline `<= 0` is `too_little_data`. A `no_effect` edit gets one mechanical cut proposal (no model call) when a slot is free, except for allow rules (use Rollback). The screen wording is "since this edit", never "because".

## Daemon and CLI

`phaseCoach` runs after the history backfill: once 7 days have passed since `<workspace>/last_coach.txt` (no catch-up of missed weeks), it takes the coach lock, folds the old instruction suggestions in (below), judges, then collects and proposes. There is no plan-limit gate (ask #655); no `agentlog.db` handle skips judging; the stamp is written only when proposing ran to completion (a model call skipped for want of slots or sources counts): a collect or model error writes `<workspace>/last_coach_failed.txt` instead and is retried a day later (not every cycle; a later success removes it), a cancelled cycle writes neither and the next cycle runs again, and a judging error alone does not hold the week. Logs carry counts only.

`watchtower coach status|proposals|accept|decline|rollback|run`, each with `--json` (a failure prints `{"ok":false,"error":…,"code":…}` and exits non-zero; `code` is `stale`, `changed_since`, `state_changed`, `busy` or `failed`; with `--json` the object is also written as one JSON line on stderr (Execute() prints the error as prose after it; a reader takes the last line that decodes as a JSON object), rollback adds `diff`). Pinned keys: `status [--days N]` (1..90, default 14; the previous period is the same length) — `ok`, `period{since,until}`, `metrics{corrections,task_hours,task_cost_usd,owner_loop,spec_findings,review_comments}` each `{value,n,known,previous}`, `open`, `last_run`; `proposals --status open|accepted|declined|all` — `ok`, `proposals[]` with `id`, `title`, `why`, `destination`, `workbench_id`, `prompt_id`, `kind`, `metric`, `before`, `after`, `evidence[{kind,ref}]`, `sources`, `status`, `created_at`, `decided_at`, `baseline`, `verdict`, `verdict_value`, `verdict_at`, `reverts_id`, `budget` (rune budget of the destination, `0` = none; `coach.BudgetOf`, the number `Validate` uses); `accept|decline|rollback` — `ok`, `id`, `status`; `run [--dry-run]` (holds `<workspace>/coach.lock` — `fsutil.TryLockFile` — while it judges and proposes; the daemon's weekly pass takes the same lock and logs `coach: busy, skipped`) — `ok`, `dry_run`, `judged`, `cuts`, `written`, `skipped`, `proposals`, `judge_error` (`""` unless judging failed; proposing goes on, as in the daemon). Keys are only added. A refusal under an agent prints the same failure object with `--json`. `accept --stdin` reads the owner's edited text and refuses an empty one (it never falls back to the proposed text). The human output of `proposals` and `run` shows each proposal's change: the removed lines with `-`, the added ones with `+`. `accept`, `decline`, `rollback` and `run` are refused under an AI agent's markers (AGENT-07's `refuseUnderAgent`, first) and otherwise run only after the owner confirms them in the running Desktop (`confirmWithOwner`, ask #659; the window shows the proposal, its change and an edited accept's text; `run` says what the pass does; `run --dry-run` writes nothing and needs no confirmation, only the marker refusal). The CLI does not meter its model usage.

## The instruction miner folds in (Plan 2, ask #722)

The daily `phaseInstructionSuggestions` and its stamp are gone; the coach already reads the same owner lines (`s<id>`/`c<id>` signals). `coach.ImportSuggestions(db, digest.language, now)` is a one-shot fold, run under the coach lock right before judging, in `phaseCoach` and in `coach run` (not `--dry-run`): in one short transaction (no model call) the open `instruction_suggestions` rows with `moved_to IS NULL`, newest `last_seen_at` first, fill the free slots (3 − open proposals) as open `add` proposals to the same text (`field` → destination, `workbench_id` → workbench, after = before + the line through the same `applyEdit`/`ValidateAfter` as the model's proposals, title = the text cut to 80 runes, `why` "You said this in N sessions" / "Ты говорил это в N сессиях", metric `owner_loop`, evidence `[{kind:"suggestion", ref:"sg:<id>"}]`, `sources` = `session_count`). A row whose destination already has an open proposal (accepting one would supersede the other), that fails validation, or whose fingerprint is known, is retired. Every open row gets `moved_to` (migration 00163): its proposal id, or `-1` (retired; its owner lines stay coach signals). Nothing writes new suggestions, so after its first run the fold is a no-op and old suggestions never crowd later weeks. A moved row is decided only through the coach: `instructions suggestion add|dismiss` refuse it (`db.ErrSuggestionMoved`, "moved to the coach (proposal #N)") and `instructions show` no longer lists it. Suggestions the owner added or dismissed keep blocking their texts: the Proposer drops a proposal one of whose added lines equals (trimmed, case-folded) such a text.

## Desktop

Spec review findings screen: **Not useful** beside **Fine as is** and **Comment** (`SpecReviewMarkState.notUseful`); shown as "Not useful" with Undo; never sent to the author (`SpecReviewAnswer` skips it); it is the coach's noise signal. The phone writes no marks.

## v1 limits

- The verdict is judged on the whole metric over the scope, not a narrower measure of the edit (correlation, not causation).
- No cut for allow rules; the owner uses Rollback of the original.
- `settings.json` top-level and `permissions` keys are re-sorted when written; a rolled-back prompt addition returns without its `proposal_id`; two concurrent rollbacks can duplicate restored lines; a small race remains between the re-read and the rename.
- `~/.claude/CLAUDE.md` has a hard ceiling of 4000 runes (`claudeMDMaxRunes`, ask #659): an edit may grow the file by at most 400 runes and never past 4000; a file already at or over 4000 may only keep its size or shrink, so there the coach can only cut. The owner's own edits are not limited.
- `~/.claude/CLAUDE.md` is written by atomic rename: hard links, extended attributes and ACLs on it are not kept. Rolling back an edit that created the file leaves an empty file (a created and an existing empty file cannot be told apart).
- The ask level, personal methodology overrides and disabling skills are out of v1.
- There is no Analytics screen, Home card or Settings → Prompts view of additions yet (Plan 2, Desktop tasks); until then proposals are read through the CLI.
- A model proposal cites evidence only from the collected signals, so the `suggestion` evidence kind appears only on folded proposals.
- `coach run` does not meter usage and `coach` never moves agentlog rows: a CLI-only install before the daemon's move measures an empty agentlog.
- Allow-rule table contents and risk: above. A baseline needs analytics on for the workbench.
