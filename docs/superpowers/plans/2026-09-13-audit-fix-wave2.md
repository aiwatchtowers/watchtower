# Audit fix — wave 2: partial failure ≠ success

**Branch:** `fix/audit-wave2` (off `main` @ a578d3dc, wave 1 merged)
**Source:** `docs/audit/2026-09-13-feature-audit/` — root cause 2, owner decisions 8, 10, 11.
**Scope line from the audit README:** *"Wave 2 — partial failure ≠ success: per-channel digest
watermark; tracks all-failed; ideas floors/prefs/empty rows; Catch-Up reap + CLI stderr; feed recap
NOT NULL; Gmail transient-loss."*

Every task in this wave fixes the same defect shape: **a pipeline that loses material, then reports
success and advances a watermark past what it lost.** Nothing here adds a feature.

Two verification reports were produced against this exact HEAD before the plan was written and are
the authoritative anchors for each task (they carry current `file:line`, the offending code, the
failure scenario, the existing tests, and the contract analysis):

- `.superpowers/sdd/2026-09-13-audit-fix-wave2/verify-core.md` — tasks 1–4
- `.superpowers/sdd/2026-09-13-audit-fix-wave2/verify-ideas.md` — tasks 5–8

All nine findings were re-verified as **STILL BROKEN at HEAD** (one — the CLI stderr item — was
re-scoped; see task 8).

---

## Global Constraints

These bind every task. A reviewer checks them as well as the task text.

1. **English only** in the repository — code, comments, commit messages, test names, docs.
2. **One commit per task.** Conventional-commit subject, body explaining the failure the change
   removes. Never `git add -A` and never a working-tree-wide git command: this is a shared worktree
   checkout, stage only the files the task names.
3. **Inner-loop testing only.** `go test ./internal/<pkg>` (add `-run` to narrow); Swift
   `make test-swift FILTER=<TestClass>`; `make lint-diff`. Never a bare `go test ./...`, never an
   unfiltered `swift test`, never `-count=1` reflexively. The full gate runs once, at the end, from
   the controller.
4. **Never touch the owner's live data.** Do not run the `watchtower` binary at all. Do not open
   `~/.local/share/watchtower/` in any mode, not even read-only. Tests use temp databases.
5. **No guard-test weakening.** A test named `Test<Module>NN_…` pins a numbered inventory contract.
   It may be *extended in place*; it may never be renamed out of the convention, split into weaker
   assertions, or deleted. Where a fix changes behaviour a guard incidentally depended on (task 5),
   re-express the assertion so it pins the *same* contract more strictly, keep the test name, and
   record the change in that module's `docs/inventory/*.md` changelog.
6. **No new config keys**, no new migrations. Every task in this wave was verified to need neither.
   If you believe your task needs one, stop and report instead of adding it.
7. **Sentrux complexity gate.** CI counts complex functions and fails when the count rises. If your
   change pushes a function past roughly cyclomatic 13, split it into named helpers in the same
   commit. Never re-baseline the gate.
8. **`docs/inventory/` contracts are load-bearing.** Read the file for any module you touch before
   you touch it. A change that would weaken a numbered contract stops and reports; a change that
   *strengthens* one is allowed and must be recorded in that file's changelog with today's date.

---

## Task 1 — Per-channel Slack digest watermark

**Decision 10.** Read `verify-core.md` → "Finding 1" for the anchors; it is the full specification
for this task, including the three loss paths and the exact call chain.

Today one run-level `sinceUnix` drives every channel. A channel that failed, was capped out, or was
deferred has its messages skipped forever, because the next cycle's window starts after them.

**What to build.** The per-channel high-water mark already exists and is already stamped truthfully:
`digests.period_to` is written as `max(message ts actually digested)` per row, and
`db.GetLatestDigest(channelID, "channel")` already reads it once per channel per cycle. No column,
no migration.

- Candidate discovery compares each channel's newest message ts against **that channel's own** latest
  `digests.period_to` (a new query in `internal/db/digests.go`, one JOIN/GROUP BY) instead of one
  global `since`.
- `sinceUnix` moves from a run-level scalar to a per-`batchEntry` field; `buildBatchEntry` already
  loads per channel. `processSingleEntry`, `processBatchEntry` and `persistBatchResults` read
  `entry.since`.
- A channel with no digest at all keeps the existing first-run `initial_history_days` lookback.
- The FEAT-03 fast-forward floor (`workspace.digest_fastforward_ts`) stays **global** and is applied
  as `max(channelSince, fastForwardTS)`. `TestLastDigestTime_FastForwardOverridesOldDigests` must
  keep passing in its per-channel form.
- The batch prompt renders one block per channel already, so mixed per-channel windows are a
  rendering change, not a contract change.

**Ruling (controller): `SinceOverride` keeps overriding every channel uniformly.** It is the operator
escape hatch behind `digest --since`; a per-channel window must not weaken it.

**Ruling (controller): no max-lookback clamp in this wave.** A channel dormant for six weeks will now
come back with a six-week window — that is the point of the fix, and the existing per-channel message
caps already bound the prompt. A clamp would re-introduce the very drop this task removes; if the
owner wants one later it is decision 7's shape, raised separately.

**Tests.** The `runChannelDigestsForWindow` suite and the seeded-window tests in
`internal/digest/pipeline_test.go` must keep passing. Add a guard: two channels, one whose digest
succeeded and one whose digest failed in the previous cycle, then assert the failed channel's next
window still starts before its undigested messages while the succeeded channel's does not.

**Contracts.** None numbered. Do not edit any `docs/inventory/` file for this task.

---

## Task 2 — `tracks.RunForWindow` must error when every batch failed

**Decision 10.** Read `verify-core.md` → "Finding 2".

`runTrackBatches` swallows per-batch errors; `RunForWindow` returns `(0, nil)`, which stamps the
pipeline run `status='done'`, which is exactly what both tracks watermarks read
(`GetLatestPipelineRunPeriodTo` / `GetLatestPipelineRunStartedAt` filter on `status='done'`). A
provider outage therefore erases a whole window of digests from track extraction, silently.

**What to build.** Give `runTrackBatches` the digest pipeline's aggregator shape — count successes,
count failures, keep the last error (three named returns or a small struct; no new exported type).
Then in `RunForWindow`:

- `succeeded == 0 && failed > 0` → return a wrapped error naming the count and the last error,
  mirroring `internal/digest/pipeline.go`'s existing all-failed arm in shape.
- `succeeded > 0` → return `(totalStored, nil)` **unchanged**. Partial success stays success; reword
  the `//nolint:nilerr` comment to say so explicitly.

**Ruling (controller): a `ctx.Err()` break returns the wrapped context error**, not an all-failed
error. Shutdown is not a batch failure — but it must not stamp `done` over an unfinished window
either, and an `error` status freezing the watermark is the honest outcome.

**Callers.** The daemon phase needs no change (it already threads the error into
`pipeline_runs`). `watchtower tracks generate` will now exit non-zero on an all-failed run instead of
printing "Found 0 tracks" — intended, and called out in the PR body.

**Tests.** There is no existing coverage of `RunForWindow` at all. Add a guard: seeded digests plus a
generator stub that always errors → `Run` returns an error; and a second case where one batch of two
succeeds → nil.

**Contracts.** `docs/inventory/tracks.md` TRACKS-06 is *strengthened*, not changed. No contract edit.

---

## Task 3 — Gmail sync must freeze its watermark at the first loss

**Root cause 2.** Read `verify-core.md` → "Finding 3".

Messages are processed oldest-first. A transient `GetMessage` failure (or a transient upsert failure)
`continue`s, later messages still advance `maxSeen`, and the watermark is written past the gap — the
skipped message is then permanently excluded by the next cycle's `after:` query and by the explicit
already-seen filter. It never reaches `gmail_messages`, the inbox detector, ideas stage-1, or memory.

**What to build.** The repo already solves exactly this in `internal/imap/sync.go` — port those three
lines:

1. `stalled := false` beside `maxSeen`.
2. Set it in the `GetMessage` error branch **and** the upsert error branch.
3. Guard the advance with `if !stalled && …`.

The two *deliberate* skips (noise labels, already-seen) must **not** set the flag — they are correct
non-storage, and freezing on them would stall the watermark forever.

**Ruling (controller): `Sync` keeps returning `nil` on per-message failures.** The freeze is the fix.
An error return would flow into a phase that has already stamped the account `ok` via
`recordAuthResult` and risks flipping `google_accounts.status` on a transient 5xx — that is a
different, worse failure.

**Tests.** Port `internal/imap/sync_test.go`'s
`TestSyncStopsWatermarkAtFirstFailureButStillStoresLaterMessages`. The Gmail suite already fakes the
API with an `httptest` mux, so returning 500 for the middle message's handler is enough; no new seam.

**Contracts.** None. INBOX-09 is the precedent being applied, not edited.

---

## Task 4 — A NULL-`event_id` recap must not block the whole feed

Read `verify-core.md` → "Finding 4". Note that the audit's stated *cause* was wrong; the verification
report corrects it, and the correction matters for the test you write.

`PublishRecapFeedItems` selects `meeting_recaps.event_id` into `feed_items.source_id`, which is
`NOT NULL`. Since migration 00056 made `event_id` nullable with `ON DELETE SET NULL`, calendar
stale-cleanup produces NULL rows; SQLite aborts the **entire** `INSERT … SELECT`, so *no* recap is
published — including every perfectly event-linked one. The condition is permanent: one NULL row
poisons every future cycle. The Dashboard timeline has shown no recap since 2026-08-21.

**Ruling (controller): implement Option A** — add `AND r.event_id IS NOT NULL` to the `WHERE`.
Event-linked recaps flow again immediately, existing `feed_items` identities are preserved, no Swift
change, no migration. Option B (keying the feed item by the recap's own id) is a feed-identity change
that interacts with DASH-05 and strands existing rows; it is raised in the PR as an owner call
alongside decision 14, **not** implemented here.

**Tests.** Seed one NULL-`event_id` recap alongside an event-linked one and assert the event-linked
one still reaches `feed_items`. This is the class `internal/feed/publish_test.go` does not cover:
its DASH-06 test simulates failure by dropping the table, which is why this bug stayed invisible.

**Contracts.** `docs/inventory/dashboard.md` DASH-06 is not violated (it is why the failure was
contained). Read the file; do not edit it.

---

## Task 5 — Ideas stage-1: floors advance only over rendered rows, and empty windows write no row

**Decision 8, two halves of one change — both live in the same two renderers, so they ship as one
commit.** Read `verify-ideas.md` → findings 1 and 3.

**Half A — floor honesty (IDEA-01).** Both stage-1 digesters compute their new floor over *every
loaded* row and advance to it, while the renderer silently stops at the prompt-char budget. Jira is
the worse case: the floor is computed before rendering, and the renderer can stop after a fraction of
the issues. Everything dropped by the budget is never mined.

Have each renderer report the **last unit it actually rendered**; derive both the floor and the
digest's `period_to` from that, with an explicit, tested path for "zero rows rendered" (the floor
must not move at all). Stage 2 (`consolidate.go`) is already honest and needs no change.

**Half B — no empty rows.** When validation leaves a window with no topics, skip the
`stream_digests` insert entirely; the floor still advances (the window genuinely had nothing worth
recording) and the skip is logged.

**Ruling (controller): accept the backfill coverage-skip cost.** `db.HasStreamDigestCovering` uses row
existence as a coverage marker, so a re-backfill of an empty window will now re-run one stage-1 call.
That is cost, never correctness — and for Gmail the marker is already documented as decorative.

**Guard tests — re-express, do not delete.** `TestIdeas02_EmailHallucinatedRefDropped` and
`TestIdeas02_JiraHallucinatedRefDropped` both assert a row exists carrying `"[]"`. Under half B no row
is written. Keep both names and their IDEA-02 prefix and re-express each to pin the contract *more*
strictly: the invented ref never reaches the database at all (now: zero rows), and the floor still
advanced. Record the re-expression in `docs/inventory/ideas.md`'s changelog.

**Contract text.** IDEA-01's stage-1 clause currently describes the behaviour this task removes.
Reword it to state that a stage-1 floor advances only past material actually rendered into the
prompt. This is a strengthening; add a dated changelog entry naming this wave.

---

## Task 6 — The ideas preference block must exclude decisions

**Decision 8.** Read `verify-ideas.md` → finding 2.

The query feeding the consolidator's owner-preference block selects on rating and status with **no
`kind` filter**. Since the 2026-08-12 decisions split, mined decisions are born `active` — so every
decision the assistant ever recorded floods the LIKED/APPROVED list and teaches the miner the owner
approves of everything.

**What to build.** Add `kind != 'decision'` to the query. Keep the existing call sites' signatures.

**Ruling (controller): the `status = 'active'` LIKED arm stays.** Once decisions are excluded, an
active idea or note reached that state either through an explicit Approve or by the owner authoring
it manually — both are the explicit endorsement decision 8 asks for. Do not narrow further.

**Tests.** A unit test in the ideas package that seeds one approved idea, one active decision and one
rejected idea, and asserts the decision appears in neither the liked nor the disliked list.

**Contracts.** None numbered.

---

## Task 7 — Reap Catch-Up recaps stuck in `building`

**Decision 11.** Read `verify-ideas.md` → finding 4.

A recap row is inserted `building` and only leaves that state through `finish` or `failRun` — both of
which require the process to survive. A killed daemon, a crashed CLI or a machine sleep leaves the row
`building` forever, and the Desktop renders a permanent "Building the recap…" spinner with no Retry.

**What to build.** One `UPDATE` marking rows `failed` where `status='building'` and `created_at` is
older than 30 minutes, called at the top of `Pipeline.Run` **before** the new row is inserted. The
schema already permits `failed` — no migration. Once reaped, the existing Desktop error + Retry path
handles the row for free.

**Tests.** Seed a 31-minute-old `building` row and a 5-minute-old one; assert exactly the stale one
flips to `failed` and that a fresh run's own row is untouched.

**Contracts.** CATCHUP-01..04 are unweakened. `docs/inventory/catchup.md` needs a narrative sentence
and a dated changelog entry only.

---

## Task 8 — Desktop: a CLI call's stderr must reach the log

**Decision 11, re-scoped.** Read `verify-ideas.md` → finding 5 first: the audit's framing was wrong
and the correct target is different from what the decision text implies.

`CLIRunner` does **not** swallow stderr on failure — it already throws `nonZeroExit(code:stderr:)`.
Two real gaps remain:

1. **Exit-0 stderr is dropped.** A CLI call that succeeds while writing a warning to stderr loses it.
   The repo's own Swift conventions already require logging it (`docs/review/review-rules.md` — read
   the "Swift / Desktop conventions" section before writing any Swift).
2. **Catch-Up does not use the shared runner at all.** `CatchUpViewModel` has its own `Process`
   wrapper, which is precisely the path that produced the audit's evidence. A fix confined to
   `CLIRunner.swift` would miss it.

**What to build.** A tagged `print` (house style — this repo does not use OSLog) of non-empty stderr:
in the shared runner on the exit-0 path and before the throw, and mirrored in Catch-Up's own wrapper.
Do not refactor Catch-Up onto the shared runner in this task — that is a larger change than decision
11 asked for; log in place and note the duplication in the PR.

**Tests.** `make test-swift FILTER=<TestClass>` for whatever suite covers the runner. If the logging
is not observable from a test, say so in the report rather than inventing a seam for it.

**Contracts.** None.

---

## Out of scope for this wave

Named here so no task drifts into them: `jira.features.*` round-trip, key-detector wiring,
strong-tier cost knobs, reaction-commands FastForward seed, recap/notes prompt bump, calendar
stale-cleanup guard (decision 14), `TargetBriefCenter` queue, TGT-BRIEF-01 wording, briefing
`SetPromptStore`, Desktop `slack://` raw ids, duplicate logs + rotation. Inbox shape (decision 3) and
no-Slack identity (decision 15) stay parked on the owner.
