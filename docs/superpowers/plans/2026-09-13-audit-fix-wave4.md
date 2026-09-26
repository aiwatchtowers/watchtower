# Audit fix wave 4 — strong-tier cost (owner decision 9)

**Branch:** `fix/audit-wave4` off `main` @ `c1ae9b71` (wave 3 merged).
**Source:** `docs/audit/2026-09-13-feature-audit/README.md`, owner decision 9:

> Strong-tier cost (H14–H16, tier holes). All four treated as bugs: daily rollup once per day plus
> on new channel digests, `read_at` reset on content change; day plan / briefing / next-step get an
> attempt marker + backoff (max 3/day); memory rewrite/reflect/map get a "done today" memo and
> evidence dedupe in `confirm`; `TierForSource` holes closed (learn calls → light). **No new config keys.**

The theme: the daemon re-derives the same content on the strongest model every 15-minute cycle, and
retries failures with no budget. Nothing here changes what the pipelines produce — only how often
they are allowed to produce it.

## Verification reports (authoritative — read the one for your task)

A verification pass ran before this plan was written. Each task brief points at its report; the
report, not this plan and not the audit, is the source of `file:line` truth:

- `.superpowers/sdd/2026-09-13-audit-fix-wave4/verify-rollup.md`
- `.superpowers/sdd/2026-09-13-audit-fix-wave4/verify-backoff.md`
- `.superpowers/sdd/2026-09-13-audit-fix-wave4/verify-memory.md`
- `.superpowers/sdd/2026-09-13-audit-fix-wave4/verify-tiers.md`

Where a report contradicts the audit text, **the report wins** — three of the four slices came back
wider or differently shaped than the audit stated.

## Global Constraints

1. **English only** in every file that lands in the repo: code, comments, tests, commit messages,
   docs.
2. **One commit per task.** The commit, not the report, is the deliverable. A task is not done until
   `git log` shows it.
3. **Inner-loop testing only** while iterating: `go test ./internal/<pkg>` (never add `-count=1`
   reflexively). The full gate runs once at the end, from the controller.
4. **Never run the `watchtower` binary. Never open the owner's live workspace database under
   `~/.local/share/watchtower/`, not even read-only. Never read or write the owner's real
   `config.yaml`.** Tests use temp databases and temp vaults.
5. **No guard-test weakening.** A test named `Test<Module>NN_` is a behavioural guard. Do not relax
   its assertions, rename it, or split it into weaker pieces. If a change appears to require that,
   stop and report it as a blocker.
6. **Every guard must be mutation-checked.** After writing a test that pins a fix, neuter the fix in
   a scratch copy **outside the repo**, re-run the test, confirm it fails, then restore **from the
   scratch copy** and verify byte-identity with `diff -q`. Never restore with `git checkout --` —
   that restores the committed state and silently discards your own working rewrite.
7. **Ask what a *plausible wrong implementation* does to this test, not just what a deleted line
   does.** Wave 3 shipped seven guards that passed with their fix removed, every one the same shape:
   an assertion on a **count** the mutation happened not to change, or a **fixture too small to tell
   "one" from "all"**. A one-element fixture and a count assertion are the two shapes that hide
   everything.
8. **Migrations only where this plan names one.** Two are named: `00068` (task 3) and `00069`
   (task 4). Numbers `00068`/`00069` were confirmed free across every local and remote branch. A
   migration also means: mirror into `internal/db/schema.sql`, add new tables to `TestAllTablesExist`,
   and regenerate the golden (`go test ./internal/db/ -run TestSchemaGolden -update`). Do not bump
   `CurrentSchemaFormat`.
9. **No new config keys** (decision 9, verbatim). Thresholds are code constants next to the
   existing ones. Schema columns and tables are permitted; config keys are not.
10. **`docs/inventory/` contracts are load-bearing.** Task 4 amends MEM-02's exclusion sentence —
    that is an extension along an existing precedent, and it ships with its code and changelog in
    one atomic commit (inventory protocol). Any *other* contract interaction is a blocker: stop and
    report.
11. **Sentrux complexity gate:** the CI fails when the complex-function count rises. Split functions
    rather than re-baselining. `gocyclo` threshold sits between CC 13 and 19.
12. Work only inside the worktree `/Users/user/PhpstormProjects/watchtower/.claude/worktrees/audit-wave4`.
    Never `git add -A`, never run working-tree-wide git commands, never touch another agent's commits
    or the stash. Scratch files live outside the repo.

## Tasks

### Task 1 — Daily rollup: regenerate only on new material, and reset `read_at` when it changes

**Report:** `verify-rollup.md`.

Today `runDailyRollupForDate` runs on every daemon cycle, gated only by "≥2 channel digests exist for
today", and re-derives the same daily digest on the strong tier — up to 96 strong-tier calls a day
for one row. The report also corrects the audit on the second half: `read_at` does **not** flip every
cycle; it is **never** reset at all, so once the owner has read the daily digest it stays read
however much the content is rewritten underneath them.

Both halves, per decision 9:

- Gate regeneration on new material: skip unless no daily row exists for the date yet, or some
  channel digest for that day is newer than the existing daily row. Use the query the report names;
  do not invent a watermark and do not add a config key.
- Reset `read_at` on a genuine regeneration, and **only** there. Thread the behaviour through the
  daily call site; do not change `UpsertDigest`'s SQL for every caller, do not touch the channel or
  weekly paths, `AutoMarkReadFromSlack`, Catch-Up's acknowledge (CATCHUP-01 already excludes
  daily/weekly — the report verified this), or Swift's `DigestQueries.markRead`.

Tests: the cadence gate is the thing to pin. A fixture with **one** channel digest, or an assertion
that counts calls without distinguishing "regenerated once" from "regenerated every cycle", is
exactly the shape constraint 7 names. Pin: first cycle generates; an immediately following cycle with
no new channel digest does **not** call the generator; a cycle after a *newer* channel digest does,
and nulls `read_at`; a regeneration that produces the same content still counts as a regeneration
(say what you chose and why in the report).

### Task 2 — Day plan and briefing: persisted attempt marker, max 3 real failures per day

**Report:** `verify-backoff.md` §1, §2, §4, §5.

A failed day-plan generation is retried every 15-minute tick until midnight (~64 wasted strong-tier
calls/day); the briefing phase has the same shape. Day plan today persists **no** attempt state at
all — only an in-memory field that a daemon restart clears.

Implement the marker-file shape the report recommends (`<name>.txt` under `Config.WorkspaceDir()`,
the `last_briefing.txt` / `last_people.txt` / `last_ideas.txt` family), storing the date **and** the
attempt count, loaded at daemon start and written after every real attempt. No migration, no config
key. Day boundary: **local** time for both, matching `sameCalendarDay` and `plan_date` as they are
used today.

The nuance the audit missed and the report found: `RunForDate` has three return shapes — no current
user, no data yet, and a real failure — and today they are indistinguishable to the phase. **Only a
real failure may consume budget.** A no-user or no-data skip costs nothing and must stay retryable,
otherwise this fix silently disables the briefing on installs that are merely waiting for data.

Budget exhaustion must be visible: the owner has to be able to tell "not generated yet" from "gave
up for today". Put it where the report says.

Tests: pin that three real failures consume the budget and the fourth cycle launches nothing; that a
benign skip does **not**; that the budget resets on the next calendar day; and that the count
survives a simulated daemon restart (this is the one the in-memory field fails). A fixture that
fails once and asserts a count is not a guard.

### Task 3 — Next-step: per-target attempt budget (migration `00068`)

**Report:** `verify-backoff.md` §3, §4, §5.

Wider than the audit stated: the worst case is **100** strong-tier calls per cycle, not 50 —
`ActiveSnapshotLimit` defaults to 100 and the 50 is only an internal fallback. Nothing marks an
attempt, so a target whose reply never parses is retried every cycle forever, and `pipeline_runs`
records `done, 0` either way.

This one is per-row state, so it takes a migration (`00068`): two columns on `targets` —
`next_step_attempts` and `next_step_attempted_at` (UTC ISO8601, matching the column family already on
that row; **UTC here, not local** — every other timestamp on `targets` is UTC and a local boundary
would disagree with the `updated_at` comparison across UTC midnight).

Use the eligibility predicate and the reset rule the report gives, including the ruling below.

> **Ruling (controller):** a target edited since its last failed attempt gets a **fresh budget**.
> It is a genuinely new input, not a retry of the same failure. Cost if wrong: an owner who edits a
> target repeatedly while the model keeps failing on it pays up to 3 calls per edit instead of 3 per
> day; visible, bounded, and undone by deleting one clause.

Do not use a global counter here. Per the report, a global budget would let one bad target silence
next-step generation for every other target that day.

Tests: the distinguishing fixture needs **more than one target** — a 3-failures-then-stop assertion
with a single target cannot tell a per-target budget from a global one, which is precisely the wave-3
failure shape. Pin: per-target isolation (target A exhausted, target B still runs), the UTC day
rollover, the fresh-edit reset, and that a *successful* generation does not leave a budget behind
that blocks the next legitimate refresh.

### Task 4 — Memory rewrite/reflect/map: a "done today" memo (migration `00069`)

**Report:** `verify-memory.md` §1, §2, §3, §5, §6.

All three confirmed, and one is wider: `dueForRewrite` is stateless and the selection is
`ORDER BY id`, so it is provably the **same first ten pages** on every cycle of their slot day —
and entities past position 10 are never rewritten at all. The memo fixes both. Say plainly in the
commit message that on a large vault the daily Opus count can *rise* (starvation ends), and that the
saving is the repeats, not the total.

- **Rewrite:** stamp per node, on **attempt**.
- **Reflect:** stamp on **attempt**, not success — the git log cannot serve as the memo, because a
  dispute-only or zero-observation run writes no commit at all.
- **Map:** gate on a fingerprint of the rendered prompt input (sha256), not on the vault git head.
  The write is already change-gated; the *call* is not, which is the cost.

Storage: the single `memory_step_state` table the report specifies, keyed `(step, node_id)`, **no
FK**, and **deliberately excluded from `DropMemoryIndex`** with a schema comment saying so in the
style of the existing `memory_engagement` comment.

> **Ruling (controller):** take the recommended table over the runner-up (two `workspace` columns
> plus a git-log-derived rewrite memo). One mechanism for three steps beats two mechanisms, and the
> exclusion has precedent — `memory_engagement` and `memory_entity_hints` already survive
> `DropMemoryIndex` by design. The cost: MEM-02's exclusion sentence gains one table name. That is
> an amendment along an existing line, not a weakening, and it ships in this task's commit together
> with the code and the changelog entry. It is called out in the PR body as an owner-visible item.
> If the owner dislikes it, the runner-up is a contained swap.

Contracts: the report's analysis says MEM-06, MEM-08, MEM-09, MEM-11 and MEM-15 are all preserved
(MEM-08 arguably strengthened). Re-check that claim yourself against `docs/inventory/memory.md`
before you commit; if any of them is *not* preserved, that is a blocker — stop and report.

Tests: a fixture with a single due entity cannot distinguish "stamped the one it did" from "stamped
all of them", and a fixture whose second cycle falls on a different slot day proves nothing about the
memo. Build fixtures that can fail.

### Task 5 — `confirm`: evidence dedupe, and the double-weighting it exposes

**Report:** `verify-memory.md` §4.

A belief confirmed from the same evidence ref on every cycle gains confidence and stability it never
earned — the live vault shows a belief confirmed 17× in a day from a single ref, which
`flipThreshold(stability)` then makes practically un-retirable. The report also found that duplicate
refs are **double-weighted in `combined`** for every op, which makes `retire` flips easier than the
math intends. Fix both here: the dedupe changes that arithmetic anyway, and shipping one without the
other leaves the belief math in a state neither design describes.

The dedupe key is the **full rendered evidence tuple, field-exact**, and the op is a no-op only when
**all** kept refs are already stored. It must not collapse: an op carrying partly-new evidence;
refs that merely share a prefix; the same ref in the opposite direction; malformed evidence (fail
open — never silently drop a ref you could not parse).

No side table: `## Evidence` already carries the refs.

Tests: this is the subtlest slice in the wave. For each "must not collapse" case above, write the
case that fails if the key is loosened. A single-ref fixture proves nothing.

### Task 6 — `TierForSource` holes

**Report:** `verify-tiers.md`.

The censuses came back much larger than the audit's sample: 23 tagged-but-unlisted sources (audit
named 3) and 8 untagged call sites logging `source:"unknown"` (audit named 7).

Decision 9's instruction is narrow and stays narrow:

- **Move to light:** the two true learn calls the report identifies. Nothing else.
- **Tag-only:** all 8 untagged call sites get a `digest.WithSource` tag. Their tier does **not**
  change; the point is that usage attribution stops reading `unknown`.
- **No change:** the remaining 21, which are deliberately strong (several say so in code comments,
  CLAUDE.md, or `models_test.go`). Decision 9 handles their cost through tasks 1–5, not through the
  tier table.

> **Ruling (controller):** `digest.channel` (strong) vs `digest.channel_batch` (light) is a real
> inconsistency, and it is **out of scope for this wave**. Decision 9 does not settle it, and it is a
> quality choice about high-activity channels, not a cost bug. Leave both as they are, change no test
> that pins `digest.channel` as the strong canary, and surface it in the PR body as an open owner
> question. Cost if wrong: the inconsistency lives one wave longer.

Guard: replace nothing with an enumerated list. Write the **property scan** the report designs — walk
every non-test Go file, find every AI generation call, assert it carries a tag and that the tag is in
the table. Wave 3's equivalent guard caught a fourth call site nobody had considered *because* it was
a property scan. A new untagged call site must fail this test the day it is written.

The report names a non-contract prose line in `docs/inventory/catchup.md` that becomes stale once
`catchup.learn` moves to light. Update it in this commit.

### Task 7 — Documentation

Update the docs that now describe the code wrongly:

- `CLAUDE.md` feature notes touched by tasks 1–6 (digest rollup cadence, daemon phases, memory
  semantic tier, tier routing).
- `docs/audit/2026-09-13-feature-audit/README.md`: mark wave 4 shipped, and record the two items
  this wave deliberately did **not** decide (`digest.channel` tier; anything a task escalated).
- `docs/daemon-pipeline.md` where it describes the rollup as running every cycle.

No code changes in this task.

## Out of scope (do not fix here)

- `RunWeeklyTrends` dead code and the Desktop "Weekly" label (audit L-1/F-15) — wave 5.
- `digest.channel` vs `digest.channel_batch` tier — owner sign-off, per the ruling in task 6.
- Anything from waves 1–3's backlog, the Inbox brainstorming (decision 3) or the no-Slack identity
  work (decision 15).
