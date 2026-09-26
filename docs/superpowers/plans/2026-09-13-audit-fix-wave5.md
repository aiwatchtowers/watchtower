# Audit fix wave 5 — the rest with decisions

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to
> implement this plan task-by-task. One fresh implementer per task, one reviewer per task, the
> controller triages. Steps are described per task; the verification report named in each task is
> the `file:line` source of truth.

**Branch:** `fix/audit-wave5` off `main` @ `f730f8ab` (wave 4 merged, wave-4 verdicts recorded).
**Worktree:** `/Users/user/PhpstormProjects/watchtower/.claude/worktrees/audit-wave5`.
**Source:** `docs/audit/2026-09-13-feature-audit/README.md` — the "Wave 5 — the rest with decisions"
line plus the three "Fix in wave 5" verdicts in "Wave 4 — left open, and the owner's verdicts":

> **Wave 5 — the rest with decisions**: reaction-commands FastForward; recap prompt bump; calendar
> cleanup guard; `TargetBriefCenter` queue; TGT-BRIEF-01 wording; briefing `SetPromptStore`; chat
> `--` before prompt; Desktop `slack://` raw ids; duplicate logs + rotation.
>
> Next-step cap is leaf-only — **Fix in wave 5**: narrow the bump to fire only when the computed
> progress actually changes. `weaken`'s unconditional step — **Fix in wave 5**. The daily rollup's
> own missing failure budget — **Fix in wave 5**, alongside a real attempt budget for that pipeline.

**Goal:** land the twelve owner-decided items that waves 1–4 left, each as a small, guarded,
independently reviewable commit — nine Go, three Swift, one docs.

**Architecture:** no new subsystem. Every item extends an existing mechanism along a precedent the
report names: the FEAT-03 hook table, the `last_briefing.txt` attempt-marker family, the
`MeetingRecorderCenter` FIFO shape, `internal/ai/slack_link.go`'s account resolver, the
`StdinThreshold` split the batch generators already have, the wave-4 `confirm` dedupe.

**Tech stack:** Go 1.25 (`database/sql` + modernc sqlite, cobra, goose), SwiftUI/GRDB macOS app,
XCTest.

**Out of scope, by name:** the Inbox brainstorming (decision 3), no-Slack identity (decision 15),
wave 3's Jira carry-overs (`jira_slack_links` history backfill, time-floored key-set reload, stale
`jira_user_map` re-resolve, Desktop two-site "Sync now"), `targets.extract`/`targets.link`
wire-or-deregister (M-2, surfaced as an owner item in the PR body), the three chat prompt templates
that hand the model account #1's team id (task 11 flags them), `RunWeeklyTrends` dead code.

## Verification reports (authoritative — read the one for your task)

A read-only verification pass ran before this plan was written. Where a report contradicts the
audit text, **the report wins** — four of five slices came back wider or differently shaped:

- `.superpowers/sdd/2026-09-13-audit-fix-wave5/verify-reaction.md` — task 1
- `.superpowers/sdd/2026-09-13-audit-fix-wave5/verify-meetings.md` — tasks 2, 3 (Item A, Item B)
- `.superpowers/sdd/2026-09-13-audit-fix-wave5/verify-daemon.md` — tasks 4, 5, 6 (Items A, B, C)
- `.superpowers/sdd/2026-09-13-audit-fix-wave5/verify-targets-memory.md` — tasks 7, 8 (Items A, B)
- `.superpowers/sdd/2026-09-13-audit-fix-wave5/verify-desktop.md` — tasks 9, 10, 11, 12, 13
  (Items B, A, C, D)

## Global Constraints

1. **English only** in every file that lands in the repo: code, comments, tests, commit messages,
   docs.
2. **One commit per task. The commit, not the report, is the deliverable.** A task is not done until
   `git log` shows it. Commit only the files you touched, by path — never `git add -A`, never a
   working-tree-wide git command, never `git stash`.
3. **Inner-loop testing only** while iterating: Go `go test ./internal/<pkg>` (never `-count=1`
   reflexively); Swift `make test-swift FILTER=<TestClass>` (never an unfiltered `swift test`, never
   delete `WatchtowerDesktop/.build`). The full gate runs once at the end, from the controller.
4. **Never run the `watchtower` binary. Never open the owner's live workspace database under
   `~/.local/share/watchtower/` or `~/Library/Application Support/Watchtower/`, not even read-only.
   Never read or write the owner's real `config.yaml`.** Tests use temp databases and temp dirs.
5. **No guard-test weakening.** A test named `Test<Module>NN_` is a behavioural guard. Do not relax
   its assertions, rename it, or split it into weaker pieces. If a change appears to require that,
   stop and report a blocker. The two tests this plan names for rewriting (task 10) are not guards
   and the plan says exactly what must survive the rewrite.
6. **Every guard must be mutation-checked.** After writing a test that pins a fix, neuter the fix in
   a scratch copy **outside the repo** (`/private/tmp/claude-501/.../scratchpad`), re-run the test,
   confirm it fails, then restore **from the scratch copy** and verify byte-identity with `diff -q`.
   Never restore with `git checkout --` — that restores the committed state and discards your own
   working rewrite.
7. **Ask what a *plausible wrong implementation* does to this test, not just what a deleted line
   does.** Waves 3 and 4 shipped twelve guards between them that passed with their fix removed, every
   one the same shape: an assertion on a **count** the mutation happened not to change, or a
   **fixture too small to tell "one" from "all"**. Each task below names its own count/one-element
   trap; build the fixture that can fail.
8. **No migrations in this wave.** Every report confirmed none is needed (task 1 reuses the `skipped`
   ledger status; task 7 changes an UPDATE predicate; task 6 uses a marker file). If you find you
   need one, stop and report — do not create `00070`.
9. **No new config keys** (the programme rule since wave 4). Thresholds are code constants next to
   the existing ones. A cobra CLI flag is not a config key; this wave adds none anyway.
10. **`docs/inventory/` contracts are load-bearing.** Inventory edits this plan authorises ship in the
    same commit as their code: task 1 extends FEAT-03 (`features.md`) and adds a line to REACT-03
    (`reaction-commands.md`); task 10 adds a `targets.md` changelog entry; task 13 amends
    TGT-BRIEF-01's mechanism paragraph (docs-only, the owner's decision 12). Any *other* contract
    interaction is a blocker: stop and report.
11. **Sentrux complexity gate:** CI fails when the complex-function count rises. `gocyclo` threshold
    sits between CC 13 and 19. Split functions rather than re-baselining. Each task names the
    functions already near the gate.
12. **Dual paths (Go ↔ Swift) move together** and the Swift side names the Go file in a doc comment
    (the `SlackAccountID.swift` ↔ `internal/slack/namespace.go` precedent). This wave declares two:
    task 11 (`SlackDeepLink`/`SlackLinkResolver` ↔ `internal/slack/permalink.go` +
    `internal/ai/slack_link.go`) and task 5/12 (the log file names ↔ `LogsSettings.swift`).
13. **Concurrency in the shared worktree:** Go tasks in one batch run in parallel and own disjoint
    files (listed per task). Touch only your task's files. If `git commit` fails on `index.lock`,
    wait a few seconds and retry — never delete the lock. Swift tasks run **sequentially** (SwiftPM
    holds a build lock on `.build`).
14. Work only inside the worktree. Scratch files live outside the repo.

---

## Go batch 1 (parallel: tasks 1, 2, 3 — disjoint files)

### Task 1 — Reaction commands: seed the ledger on enable, cap dispatch per cycle (decision 6)

**Report:** `verify-reaction.md` (all sections). **Files:** `internal/features/fastforward.go`,
`internal/features/fastforward_test.go`, `internal/reactioncmd/pipeline.go` (+ a new
`internal/reactioncmd/seed.go` for the seed), `internal/reactioncmd/pipeline_test.go` (+ new test
file), `cmd/features.go`, `cmd/memory.go` (the second `FastForward` caller — zero-value deps),
`cmd/reaction_commands.go` (reuse `reactionCommandsAccountsFn`), `docs/inventory/features.md`,
`docs/inventory/reaction-commands.md`.

Still broken exactly as audited: no `"reaction-commands"` case in `FastForward`, and
`processAccount` dispatches every unseen candidate with one light-tier compose call each. The blast
radius is real, not theoretical — `Registry.Propose` applies an `execute`-trust tool inline, so every
historical 💡 creates an idea. `reactions.list` has no time filter; the ledger is the only mechanism.

> **Ruling (controller) — Shape A1.** The seed runs **at enable time**, inside the FEAT-03 hook,
> through a `deps` seam widened onto `FastForward` (report §4, A1) so the hook table stays the single
> dispatch point its doc comment claims. `cmd/features.go` populates the seam from
> `reactionCommandsAccountsFn`; `cmd/memory.go` passes a zero value. The seed logic itself lives in
> `internal/reactioncmd` (`SeedLedger`), which owns the `ReactionLister` seam. Rejected: the lazy
> first-run seed (swallows the owner's genuine first reaction and needs a persisted marker, i.e. a
> migration). Cost if wrong: enabling needs Slack reachable — that is FEAT-03's fail-closed rule and
> exactly what we want; say it in the PR body.

> **Ruling — seed every owner reaction, not only dictionary matches** (report §4 option ii). The
> decision text says "current reactions", and the wider seed closes the un-hooked replay a later
> dictionary edit would otherwise reopen. The ledger key includes `emoji`, so non-dictionary rows are
> inert.

> **Ruling — seeded rows use the existing `skipped` status** with a detail string naming the seed
> (`"seeded on enable (pre-existing reaction)"`). No migration. Rejected: a `seeded` status (a full
> CHECK-recreation migration for a value only the `list` CLI prints).

> **Ruling — the cap is per `Run`, shared across accounts, constant `maxDispatchPerRun = 25`**
> (100/day at the 6 h throttle; `watchtower reaction-commands poll` remains the manual drain). It
> counts **AI compose calls**, never ledger rows — `dispatch` returns `skipped` before `compose` for
> an unmapped tool, and those cost nothing. Overflow stays unrecorded ⇒ unseen ⇒ next poll (existing
> transient semantics). Report "dispatched N, deferred M (cap K)" as a log line in `Run`; leave the
> `(int, error)` signature alone.

> **Ruling — contracts.** Extend FEAT-03's entry (sixth hook, same fail-closed ordering; add the new
> test to its guard list) and add one sentence to REACT-03 saying seeded rows are ordinary ledger rows.
> Do **not** mint REACT-06 — "enabling never replays history" is FEAT-03's principle applied here.

A missing token file for an account is a log-and-skip in `reactionCommandsAccountsFn` today; the seed
must **not** count that account as seeded — a skipped account with an empty ledger would replay on the
first poll. Fail the hook (and therefore the enable) if any enabled account could not be seeded.

`TestFastForward_NoHookIsNil` breaks on contact: add `reaction-commands` to its `hookIDs` set (the
honest edit, matching the other five). Do not relax the loop.

Complexity: `processAccount` and `extractOwnerReactions` are both CC 10 — put the cap loop in a
helper and the seed extractor in its own function; do not grow either.

Tests (report §7, G1–G4): the seed fixture holds **≥4 reactions across ≥2 channels and ≥3 emoji**,
including an `execute`-trust dictionary emoji (`bulb`) and a non-dictionary one (`+1`); assert zero
generator calls, zero `agent_actions` **and** zero `ideas` rows, and the ledger's **exact key set**
(`ElementsMatch` over `(channel_id, message_ts, emoji)`, never a count). Then one new reaction after
the seed → exactly one dispatch. The cap fixture holds `cap+2` dictionary reactions **plus one free
`skipped` candidate** (unregistered tool): first run → `gen.calls == cap`; second run drains the rest
with no duplicate `agent_actions`; and a **two-account** variant asserting the total is `cap`, not
`2×cap`. A fixture with one or two reactions, or a `_Idempotent`-style check of only the second poll,
is the trap.

### Task 2 — Recap/notes prompts: speaker-label attribution, version bump (decision 13)

**Report:** `verify-meetings.md` Item A. **Files:** `internal/prompts/defaults.go` (templates +
`DefaultVersions`), `internal/meeting/transcript_recap.go`, `internal/meeting/transcript_notes.go`,
`internal/prompts/*_test.go` + a new meeting-prompt guard test. **Not** the Swift string at
`MeetingChatViewModel.swift:331` — that rides task 12.

Wider than the audit: **five** sites, not three (`defaultMeetingRecap`, `defaultMeetingNotes`,
`transcript_recap.go:47`, `transcript_notes.go:46`, and the Swift meeting-chat header). One set of
defaults serves both providers. Versions today: `meeting.recap` **v2**, `meeting.notes` **v1**; the
auto-upgrade skips `customized` rows, so bump to **v3 / v2** or the fix ships dead.

The guidance **must be conditional** — `meeting.recap` is shared with the paste flow (arbitrary user
text, no labels) and diarization is a toggle. Use `meeting.chapters`' existing label sentence as the
wording precedent and leave that prompt unchanged.

> **Ruling (controller) — render `[Я]` semantically.** The output language is `cfg.Digest.Language`
> via `prompts.Directive` (default Russian), independent of the transcript, so the literal `Я` would
> land inside English notes as a stray Cyrillic token. Tell the model: a `[Я]` prefix marks the
> recording owner; refer to them in the output language's natural terms (third person, "the meeting
> owner" / «владелец встречи»), never print the bare token as a name; `[Speaker N]` and person-name
> prefixes attribute as written; when lines carry no prefix, do not invent attribution. In
> `meeting.notes` this must sit **consistently with the existing "no first person" rule** — the owner
> becomes third person, which satisfies both.

Keep the `%s` verb count of each template unchanged.

Tests: no test pins the stale string today, so a forgotten bump would be invisible. The guard loops
over **both** prompt ids and asserts: version floor (`DefaultVersions[id] >= 3` / `>= 2`), absence of
"speakers are not labeled", presence of both the labeled and the unlabeled clause; plus a rendered
user-message check for a labeled transcript **and** an unlabeled paste string (the one-element trap
is a labeled-only fixture). Assert on the version *values*, not that "something changed".

### Task 3 — Calendar stale-cleanup spares events with a transcript or recap (decision 14)

**Report:** `verify-meetings.md` Item B. **Files:** `internal/db/calendar.go`
(`DeleteStaleCalendarEvents` + doc comment), `internal/db/calendar_test.go`, and one syncer-level test
in `internal/calendar/sync_test.go`. **Not** `MeetingTranscriptQueries.swift` — the `has_recap`
badge one-liner rides task 12.

Narrower than the audit: migration `00056` already preserved recap *content*; what still breaks is
the event **association** (regenerated recap/notes/chapters fall back to the ad-hoc placeholder,
attendee pools empty, the list badge goes false). **There is only one delete branch** — the SQL is
`synced_at < ?` ("not re-stamped this cycle"), so aged-out and removed-upstream share it; one guard
covers both, and a recorded-then-cancelled meeting now persists locally.

> **Ruling (controller):** accept that persistence — decision 14 as written. No backfill for rows
> already detached (their events are gone; nothing to re-attach). No `history_days`-relative split.

Fix shape (report §B.5): two index-backed `NOT EXISTS` clauses on the one statement, both callers
(`internal/calendar/sync.go`, `internal/caldav/sync.go`) inherit it with zero signature change. Update
the function's doc comment to say what it spares and why. No Swift deletes calendar events — no dual
path.

Tests: `TestDeleteStaleCalendarEvents` is a one-element trap. The guard fixture holds **four stale
events** — unreferenced / transcript-only / recap-only / both — plus a foreign-calendar row, asserted
**per id** (which survive, which went). The recap-only cell is the one that catches the likeliest
wrong implementation (a single `NOT EXISTS` over transcripts), because the paste flow creates recaps
with no transcript. Add one syncer-level test proving the guard reaches the daemon path. The four
existing stale-delete tests stay green unmodified.

## Go batch 2 (parallel: tasks 4, 5, 6 — disjoint files)

### Task 4 — Prompt store wiring for briefing, digest, tracks, guide + a wiring property scan

**Report:** `verify-daemon.md` Item A. **Files:** `cmd/sync.go` (new `wirePromptStores` helper or
equivalent — do not grow `runSync`), `cmd/briefing.go`, `cmd/digest.go`, `cmd/tracks.go`,
`cmd/people.go`, `cmd/catchup.go` (the `digest.New`/`tracks.New` sites there), a new
`cmd/prompt_store_scan_test.go`, `internal/briefing/pipeline_test.go`.

Wider than the audit: `SetPromptStore` exists on briefing, digest, tracks and guide and **none** of
the four is ever wired in `cmd/` (census in the report's table; `git log -S` shows briefing never
was). Roughly nine Settings prompt rows are decorative today, not just `briefing.daily`.

> **Ruling (controller) — wire all four.** The same two-line house shape
> (`x.SetPromptStore(prompts.New(database, nil))`) at every construction site the report enumerates.
> Settings → Prompts offers these rows as live; leaving them dead is the lie. Owner-visible
> consequence for the PR body: an install that already tuned `digest.*`/`tracks.*`/`people.*`/
> `briefing.daily` sees those pipelines change on the next cycle — for the first time, which is the
> point. The pre-existing `%s`-count hazard for a customized template is inherited, not introduced;
> one sentence in the PR body.

> **Ruling — `targets.extract`/`targets.link` (M-2) do not ride this task.** `targets.New` has no
> setter; wire-vs-deregister is a different-sized job and an owner call. Name it in the PR body.

Guard, two-sided (report §A "Guard test design"): (1) behavioural, in `internal/briefing` — customize
`briefing.daily` in a temp store with a **sentinel that appears nowhere in the default** and exactly
the template's `%s` count, run with the capturing generator, assert the sentinel reached the system
prompt **and** the stored row's `prompt_version` equals the store's returned version (never a
hardcoded 7) — both assertions in **one** test, since either alone passes a half-fix; (2) the wiring
invariant, a `go/parser` scan over `cmd/` (the `internal/digest/tier_scan_test.go` precedent, with a
coverage floor on files walked and construction sites found): every call to a `New(...)` of a package
that defines `SetPromptStore` must be followed by a `SetPromptStore` call on the result in the same
function. A fifth pipeline added tomorrow without wiring must fail this test the day it is written.

### Task 5 — Daemon logs: one stream, rotation while running

**Report:** `verify-daemon.md` Item B. **Files:** `cmd/sync.go` (the `MultiWriter` branch, extracted
into a pure `logWriterFor(logFile, verbose, detached)` helper), new `cmd/logfile.go` (`rotatingFile`),
new `cmd/logfile_test.go`, `cmd/sync_helpers_test.go`, `docs/daemon-pipeline.md` (data-paths row),
the comment at `internal/jira/sync.go:222`. **Not** `LogsSettings.swift` — the tab relabel rides
task 12 (constraint 12: same PR, cross-referenced in both commit messages).

The two halves are **one fix**: the detached child's `os.Stderr` *is* `daemon.log`, and `runSync`
adds stderr to the logger's `MultiWriter` whenever detached, so every line lands twice; and
`daemon.log` **cannot** be rotated by the daemon at all (an inherited fd keeps appending to the
renamed inode). Stopping the logger from feeding it is the precondition for bounding it.

- **B1:** the `MultiWriter` only under `--verbose` (report's recommended form; `--verbose --detach`
  duplicating is the operator asking for it). `daemon.log` keeps its role as the crash channel
  (panics + the parent's rotation note) with its open-time rotation.
- **B2:** a `rotatingFile` writer around the file the child opens itself (`watchtower.log`): mutex,
  per-`Write` byte counter **seeded from the file's size at open**, cap as a struct field (tests
  inject a small one), reusing `rotateLogIfOversized` verbatim; close → rotate → reopen → counter 0.
  No `internal/daemon` seam, no per-cycle hook (a single long sync cycle would defeat one).

Wave 1's H7 fix already cut the dominant `reactions.get` line — urgency is lower; correctness is
unchanged.

Complexity: `runSync` is already long — B2 goes in the new file, B1 is net −1 condition.

Tests (report §B "Guard test design"): rotation while open must write **several sub-cap chunks** that
cross the cap cumulatively and then assert **a subsequent write lands in the live path** (the only
assertion that catches "renamed but the logger kept the old inode"); a pre-existing over-cap file
rotates on the first write (counter seeded, not zero); `logWriterFor(false, true)` returns the bare
file and `(true, _)` a `MultiWriter`; and one assertion that the writer `runSync` constructs wraps
`syncLogFilePath(cfg)` — the single most likely wrong fix is wrapping the file named "daemon".

### Task 6 — Daily rollup: a persisted failure budget (wave-4 verdict)

**Report:** `verify-daemon.md` Item C. **Files:** `internal/daemon/daemon.go`,
`internal/daemon/daemon_backoff_test.go`, `docs/daemon-pipeline.md` (marker-file row).

Confirmed: any of the rollup's three failure returns happens before `storeDigest`, so
`dailyRollupNeeded` answers `true` again next cycle and the strong-tier `digest.daily` call relaunches
unbounded. The budget's home is `internal/daemon`, **not** `internal/digest`: the CLI `digest generate`
path must stay unbudgeted (the day-plan precedent), and the marker helpers
(`attemptMarker`/`loadAttemptMarker`/`saveAttemptMarker`) are already generic there. No hoisting, no
import cycle, no workspace column.

> **Ruling (controller) — third copy of the four-function block**, `rollup_attempts.txt`, the
> `day_plan_attempts.txt` shape, reusing `maxDailyAIAttempts`. Extracting a shared `attemptBudget`
> type would refactor two already-guarded pipelines in a wave about closing holes; copy now, note the
> third copy in the existing duplication comment. Not in this wave: extraction.

**Granularity — the one thing that is not a straight copy** (the wave-2 lesson): `RunDailyRollup`
generates for the **UTC** day; day-plan/briefing budget on the local date. Key this budget on
`time.Now().UTC().Format("2006-01-02")` or the budget's day and the artifact's day drift by hours.

"Attempt" = `RunRollups` returned non-nil; every benign outcome (feature off, lock held, `< 2`
channel digests, `!needed`) already returns nil. A DB read error consumes budget, as it does for
day-plan/briefing — say so in the commit message. Do **not** mirror the budget into
`RunWeeklyTrends` (dead code, zero callers). The rollup call is not wrapped in `trackedPipelineRun`;
the one-time "giving up for <date>" log line is therefore the owner's only signal — keep it.

Tests (report §C "Guard test design"): four `TestDaemon_RollupBackoff_*` tests copying the briefing
shape over a real `digest.Pipeline` + `erroringGenerator`: three failures exhaust (fourth cycle makes
zero calls); a **`< 2` digests** benign skip consumes nothing (this arm specifically — it is the one
an implementer gates *before*); resets next calendar day; survives a second `Daemon` over the same
marker file. Plus a clock-free assertion that the marker's date is the UTC date. Seed the two channel
digests on **distinct** channels — two rows on one channel collapse via `UpsertDigest` and turn every
budget test into a vacuous benign-skip test.

## Go batch 3 (parallel: tasks 7, 8, 9 — disjoint files)

### Task 7 — Next-step cap: a parent's `updated_at` moves only when its progress does (wave-4 verdict)

**Report:** `verify-targets-memory.md` Item A. **Files:** `internal/db/targets.go`
(`recomputeParentProgressOn` and the comment at `:192-207`), `internal/db/targets_test.go`,
`internal/targets/nextstep_test.go`, `CLAUDE.md` (the "Known limitation, left as-is" sentence in the
strong-tier section becomes a "fixed in wave 5" sentence).

Much narrower than the audit's rationale: all six call sites go through **one** function,
`recomputeParentProgressOn` (`RecomputeParentProgress` is a one-line wrapper), and the unconditional
bump is a single UPDATE. The walker writes **every ancestor** up the chain, so the guard must check
two levels. No Swift twin exists (zero matches for a parent-progress recompute in `WatchtowerDesktop/`).

Fix: add `AND progress != ?` to the existing UPDATE (atomic inside `PromoteSubItemToChild`'s
transaction, no extra round trip). The column is `REAL` with no rounding on the write path; the one
theoretical float drift falls on the safe side (an extra bump = today's behaviour). Keep the ancestor
walk as it is — it also repairs drift left by the Swift `updateProgress`. Fix the misleading
"five call sites" comment in the same commit. The only behavioural reader that changes is
`ListTargetsUpdatedSince` → `internal/inbox/compose.go` (dark by default).

Tests: a parent with today's three attempts spent, then a child edit that leaves the average
**unchanged** → parent still ineligible; a child edit that **changes** the average → parent eligible
again; and the same pair one level up (grandparent). The trap: a fixture whose "unchanged" edit
happens to move the average by float noise, or a single-level tree that cannot tell "bumped the
parent" from "bumped the chain".

### Task 8 — `weaken`: no-op when every cited evidence line is already stored (wave-4 verdict)

**Report:** `verify-targets-memory.md` Item B. **Files:** `internal/memory/beliefs.go`,
`internal/memory/beliefs_test.go`, `docs/inventory/memory.md` changelog line, the `CLAUDE.md`
sentence "Scoped to `confirm` only … `weaken` … is a flagged follow-up".

The wave-4 dedupe machinery is already shared by every op; only the early return at
`beliefs.go:341` is keyed on `opConfirm`. Widen it to `opConfirm || opWeaken`, keeping
`applied=false, mathRejected=false`. `opWeaken` touches only `Confidence` (no `Status`, no
`Stability`), so unlike `confirm` there is no status side effect to document. **MEM-06 is
bit-identical for a stronger reason than for `confirm`:** the retire/flip path reads evidence rank/age
and `Stability`, never `Confidence`, so accumulated weakens feed no flip. MEM-07 untouched; MEM-08
extended along the reviewed precedent.

Report-only, record in the PR body, do **not** widen: `shake` has the same unconditional shape and
worse (writes `Status = shaken` on zero new data); `retire` writes status/History/commit from stored
evidence alone.

Tests, mirroring the wave-4 confirm tests: a `weaken` citing only already-stored evidence → confidence
unchanged, no `## Evidence` line appended, `applied=false`, no `memory(beliefs)` commit; partly-new
evidence → applied once, only the new line appended. **Item-specific trap:** `weaken` mints `against`
lines where `confirm` mints `for` — the stored line in the no-op fixture must be `Support: false`; a
one-to-one copy of the confirm fixture passes for the wrong reason.

### Task 9 — Chat clients: leading-dash and oversize messages go through stdin (Go half of the argv fix)

**Report:** `verify-desktop.md` Item B, branch (c). **Files:** `internal/ai/client.go` (a small
helper next to `buildArgs`, not inline branches — `buildArgs` is ~70 lines already),
`internal/ai/client_test.go`, `internal/codex/client.go` (both call sites, `:88` and `:204`),
`internal/codex/client_test.go`, `cmd/ai_test.go` (the cobra parse guard for task 12's argv order).

Three layers, not two: the Swift builder (task 12), `internal/ai/client.go:139` (`-p userMessage`
inline, no stdin path, unlike `internal/digest/generator.go:93-111`), and — missed by the audit —
`internal/codex/client.go:60` (trailing positional, no stdin path, unlike
`internal/codex/generator.go:108-112`). The chat path is the one place neither protection exists on
either provider.

> **Ruling (controller) — (a)+(c).** This task is (c): give both chat clients the `StdinThreshold`
> split their generator siblings have **plus an unconditional stdin route when the message begins
> with `-`** (a threshold alone does nothing for a 20-byte `-v …`). Claude: bare `-p` + `cmd.Stdin`;
> codex: trailing `"-"` + `cmd.Stdin`, exactly as the generator does. Cover `Query` and `QuerySync`
> and both codex sites, with the stdin writer wired on each `exec.Cmd`. Rejected: `--prompt-file`
> (temp-file lifetime, both/neither validation, a new dual path — for a hazard (a)+(c) already
> closes).

Also write the **cobra parse guard** in `cmd/ai_test.go` for task 12's ordering: build the real
`aiQueryCmd` tree, `SetArgs` in the order the Swift builder will emit (flags, `--`, prompt), assert
the prompt reaches `RunE` **verbatim** for both `"-v looks wrong"` and `"--verbose please"`, and that
`--system-prompt` still lands in its variable — the assertion that catches "`--` before the flags"
(which fails as `accepts 1 arg(s), received 3`). Assert parsed values, never error strings.

Tests for (c): copy the generator-test shape — a `-`-leading message well under 32 KiB reaches stdin
and the argv carries no copy of it; the exact-threshold boundary case so the two routes cannot both
fire; and a plain short message still travels inline. The trap: asserting only "does not error".

## Swift batch (sequential: task 12, then 10, then 11)

Run the Swift tasks one at a time (SwiftPM build lock). Verification is `make test-swift
FILTER=<TestClass>`; Core-level types and tests go in `WatchtowerCore` / `Tests/Core`. Read
`docs/review/review-rules.md` "Swift / Desktop conventions" first.

### Task 12 — Desktop small batch: argv `--`, meeting-chat header, Crash Log tab, `has_recap` badge

**Reports:** `verify-desktop.md` Item B (argv), `verify-meetings.md` A.5 (Swift site 5) and B.9 (badge),
`verify-daemon.md` Item B (tab). **Files:**
`WatchtowerDesktop/Sources/WatchtowerCore/Services/WatchtowerAIService.swift`,
`WatchtowerDesktop/Tests/Core/WatchtowerAIServiceTests.swift`,
`WatchtowerDesktop/Sources/ViewModels/MeetingChatViewModel.swift:331`,
`WatchtowerDesktop/Sources/Views/Settings/LogsSettings.swift`,
`WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/MeetingTranscriptQueries.swift:71-72` (+
its test). Four independent one-to-three-line edits, one commit each is acceptable if you prefer;
one commit for the batch is also fine — say which in the report.

1. **argv (a):** `buildArgs` emits `["ai", "query"]`, then every flag, then `["--", prompt]` —
   **unconditionally**, not only when the prompt starts with a dash (an unconditional separator has no
   second path to get wrong). All six existing `buildArgs` tests assert whole-array equality and must
   be updated; add `testBuildArgsPassesALeadingDashPromptAfterASeparator` asserting the **whole
   array** with flags before `--` (an `args.contains("--")` assertion passes the broken ordering).
   Task 9's cobra test is the Go side of this dual path — the two orderings must match.
2. **Meeting chat header:** replace the "speakers are not labeled" claim with the conditional wording
   task 2 shipped (labels, when present, attribute; `[Я]` is the recording owner).
3. **Logs tab:** the "Daemon Log" tab becomes **"Crash Log"** with a one-line caption (panics and the
   launch-time rotation note only; everything else is in the Sync Log). Reference task 5's commit.
4. **`has_recap` badge:** `EXISTS (… r.event_id = t.event_id OR r.transcript_id = t.id)` — today two
   NULLs never match, so a recap the detail view renders shows "no recap" in the list. Guard: a
   transcript with `event_id NULL` and a recap linked by `transcript_id` → `has_recap == true`; an
   unrelated recap → false.

### Task 10 — `TargetBriefCenter`: a FIFO queue instead of a single slot (decision 16)

**Report:** `verify-desktop.md` Item A. **Files:**
`WatchtowerDesktop/Sources/Services/TargetBriefCenter.swift`, `Views/Targets/TargetsListView.swift`
(`:64-70`), `Views/Targets/TargetDetailView.swift` (`:126-131`, `:147-160`, `:249`, `:290`, `:360-361`),
`Views/Targets/CreateTargetSheet.swift` (`:294-302`), `Tests/TargetBriefCenterTests.swift`,
`docs/inventory/targets.md` (changelog entry — see below).

Still broken exactly as described: `startBrief` and `markFailed` both `cancelStream()` the running
brief. VM lifetime is already safe (`TargetAssistantCenter` never evicts a working container), so only
the cancellation must go — but the scalar `Phase` is read by **five** view sites that break under a
queue and need a per-target accessor. `adoptVM(for:)` has zero production callers (10 test callers):
reshape it over the job list, do not delete it.

Shape (report §A "FIFO shape"): `struct BriefJob { let id = UUID(); let targetID: Int; let text:
String; var vm: TargetChatViewModel?; var phase }`, `briefs: [BriefJob]` oldest first,
`activeBriefID`, a drain that builds the VM **at start time** (not enqueue time), sends, clears the
slot on completion and drains again. Keep `phase` as the head projection (the precedent) **and** add
`phase(for targetID:) -> Phase`; move the five view sites onto it. `markFailed(targetID:)` /
`dismissFailure(targetID:)` take the target and never touch another target's job.

> **Ruling (controller) — failures are per target and stay visible until dismissed** (the precedent).
> `testStartBriefClearsPriorFailure`'s semantics change accordingly: starting B no longer clears A's
> failure. **No Retry affordance** — a failed brief is recovered by re-asking in the chat (spec §7);
> a new surface the decision did not ask for. No queue cap (one keystroke per job; the precedent has
> none) — one sentence in the doc comment, not a mechanism.

Contracts: **TGT-BRIEF-02 strengthened** (a superseded brief today shows *no* visible error; the
queue closes that). **TGT-BRIEF-01 axis 2 unaffected** — a brief that starts 40 s later is still
one-shot, still originates in the owner's own Enter, is not scheduled and is not a re-run; record that
reading as a `targets.md` changelog line in this commit, not a contract edit.

`testNewBriefCancelsTheSupersededStream` **pins the bug — rewrite, do not delete**: its "a cancelled
run writes nothing" assertions (no auto-applied `add_sub_item`, no cards, no duplicate persist, no
`system` message) stay valid and move to the explicit-cancel path (the only cancel the spec
sanctions). `testBriefSurvivesWithNoViewAndReleasesToIdle` (the house navigate-away test) must
survive unchanged.

Guard (report §A "Guard test design"): **two targets, two distinct mocks** (a shared mock's
accumulated prompts cannot tell "A then B" from "B twice"); A's mock streams a complete execute-mode
action then blocks on a **test-controlled signal**; start A, start B; while A streams assert
`vmA.isStreaming`, `mockB.prompts.isEmpty`, `phase(for: A) == .briefing`, `phase(for: B) ==
.queued`; release A; assert A's execute action **was applied**, A persisted once, no `.failed`; then
B sent exactly once and persisted. Separate tests: a failing A lands `.failed` **and** B still
completes; `markFailed(targetID: other)` does not cancel the running brief. A `briefs.count == 2`
assertion is the count trap; a one-target fixture cannot see B start early.

### Task 11 — Desktop Slack links: one builder, per-account team id (audit H-2)

**Report:** `verify-desktop.md` Item C. **Files:** new
`WatchtowerCore/Utilities/SlackDeepLink.swift` (+ `SlackLinkResolver`),
`WatchtowerCore/Models/SlackAccount.swift` (`teamID`),
`WatchtowerCore/Database/Queries/SlackAccountQueries.swift` (`fetchTeamIDs`), new
`Tests/Core/SlackDeepLinkTests.swift`, and the **fourteen** call sites in the report's two tables
(`DigestViewModel` ×2, `SearchViewModel`, `ChannelStatsViewModel`, `WorkspaceOverviewViewModel`,
`DashboardViewModel`, `TracksViewModel` ×2, `InboxViewModel`, `WhoToPingView` (user link),
`TargetDetailView:1687,1689` (archives/app_redirect, **unstripped**), `IdeaDetailPane:318` (delete its
private `rawSlackChannelID`), `CatchUpViewModel:455`), their existing tests, and `CLAUDE.md`'s Slack
multi-account v1 identity-scoping list (Desktop link rendering joins the "resolves the account" side).

Still broken and the audit's list is incomplete: every builder interpolates the namespaced id
verbatim and reads `team=` from the frozen `workspace.id`; the archives family has the same bug with
a different scheme; there are three independent stripping implementations today. Blocker to clear
first: `SlackAccount` does not decode `team_id` although the column exists.

> **Ruling (controller):** the archives/app_redirect family is **in scope** (same one-line call-site
> change; leaving it guarantees the next audit re-finds it). The three chat **prompt templates**
> (`ChatViewModel:512-546`, `TargetChatViewModel:1139-1149`, `TrackChatView:407-417`) that hand the
> model account #1's team are **out of scope** — a prompt-design question; flag them in the PR body.

Shape (report §C "Proposed shape"): `enum SlackDeepLink { channel(teamID:rawChannelID:messageTS:),
user(teamID:rawUserID:), archives(rawChannelID:messageTS:) }` mirroring
`internal/slack/permalink.go`, and `struct SlackLinkResolver { teamIDByAccount: [Int: String];
fallbackTeamID: String; resolve(_ id:) -> (teamID, rawID) }` mirroring `internal/ai/slack_link.go`'s
ladder exactly: not namespaced ⇒ `(fallback, id)`; unknown account ⇒ `(fallback, rawID)`; account with
empty `team_id` ⇒ `(fallback, rawID)`; else `(acct.teamID, rawID)`. Declare the dual path in the doc
comment naming both Go files. Each VM replaces `workspaceTeamID: String?` with a resolver loaded in
the same read block that already fetches `workspace`. Route **all fourteen** sites — a half-routed
fix leaves the bug on the untouched surfaces with no test saying so.

Tests: every existing link test uses a **bare** fixture (`"C001"`) — the suite is green only because
nothing is namespaced. The Core guard uses **two accounts with different team ids** (1 → `T001`,
2 → `T999`) and five id forms: `"1:C0123"` → `id=C0123&team=T001`; `"2:C0456"` → `team=T999` (the
row a single-account fixture cannot see — it catches "strips but keeps account #1's team" and
"strips only `1:`"); bare `"C0123"` → fallback team; `"3:C0789"` (no account) → fallback + stripped;
account with `team_id = ''` → fallback; and a non-numeric-prefix `"C:0123"` passing through
untouched (pins that the builder uses `SlackAccountID.split`, not its own `split(":")`). Assert both
query parameters **by value**; a non-nil URL passes everything. Per-VM, one `"2:"` fixture each for
`DashboardViewModel`, `TracksViewModel`, `DigestViewModel`; `IdeaDetailPaneMentionURLTests` keeps
asserting the same outputs after the duplicate stripper is deleted.

## Docs

### Task 13 — Documentation (docs-only)

**Report:** `verify-desktop.md` Item D for the inventory amendment.

> **Ruling (controller) — decision 12 reading (a).** The four Wave-2 tools became reaction-only in
> `d7cfc1a9` (PR #152 review) and the owner knew it when deciding ("main already fixed … wave-2 tools
> `Surfaces: ["reaction"]`" is in the wave-1 notes). "Leave as is" means the code as main has it.
> Nothing in TGT-BRIEF-01..03 or AGENT-01..06 contradicts it; the gap is an omission.

- `docs/inventory/targets.md:33` — append the report's additive sentence to the axis-3 mechanism
  paragraph (registry `Surfaces` as the second enforcement mechanism, naming the seven tools' surfaces
  and the pin test) plus a changelog line dated this wave cross-referencing
  `reaction-commands.md`'s 2026-09-12 entry. No new contract number.
- `docs/audit/2026-09-13-feature-audit/README.md` — mark wave 5 shipped; list what it deliberately
  did **not** decide: `targets.extract`/`targets.link` wire-or-deregister; `shake`/`retire`'s
  unconditional shapes; the three chat prompt templates with account #1's team; the third copy of the
  attempt-budget block vs extraction; wave 3's Jira carry-overs.
- `CLAUDE.md` — feature notes touched by tasks 1, 4, 5, 6, 8, 10, 11 (reaction FastForward + cap,
  prompt store wiring, log stream/rotation, rollup budget, weaken dedupe, brief queue, Desktop link
  resolver). Tasks 7 and 8 edit their own sentences in their commits; this task only reconciles.
- `docs/daemon-pipeline.md` — confirm tasks 5 and 6 added their rows; add anything missed.
- Update the stale memory-side note only if a repo doc repeats it (the `reference_claude_cli_argv…`
  note is the controller's, not the repo's).

No code changes in this task.

---

## Review protocol (controller)

Per task: implementer (opus for tasks 1, 4, 5, 10, 11; sonnet for 2, 3, 6, 7, 8, 9, 12, 13) → the
implementer's report names every guard and its mutation result → a fresh reviewer (opus) re-runs a
sample of the mutations itself and asks what a plausible wrong implementation does to each guard →
controller triages (accept / reject with reason / defer) → fix round if needed. Final: `local-review`
on the whole branch (debate-review panel), then the full gate (`make test`, `make test-swift`,
`make lint-all`, `sentrux gate`), then PR → panel → merge into main when green (owner authorisation
from wave 1 applies to later waves).
