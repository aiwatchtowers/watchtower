# Feature-state audit — 2026-09-13

Whole-product audit answering the owner's question "many features don't seem to work, or not the way they were designed". Eleven independent read-only auditors (nine code domains, one live-workspace runtime audit, one silent-failure sweep) ran against `feature/agent-actions` @ `37179540` (equivalent to `main` @ `4cc3bade` after PR #152) and the owner's live `whitebit` workspace (read-only SQLite + daemon logs).

Result: **6 Critical, 28 High, 26 Medium, ~40 Low.** Two of the most expensive pipelines (Slack channel digests and Memory consolidation) had been silently dead since 2026-08-03; the Jira account had been `revoked` since April; the Inbox tab showed one failed card while 67 actionable items had no screen; the daemon cycle took 70–85 minutes instead of 15.

## Domain reports

| File | Domain | Verdicts |
|---|---|---|
| `core-pipelines.md` | Slack sync, digests, tracks, people, feed | 7 works · 4 differently · 3 broken · 5 unreachable |
| `inbox-strip-catchup.md` | Inbox, situations, reaction commands, strip, reminders, Catch-Up | 4 · 5 · 1 · 2 dark · 4 unreachable |
| `targets-dayplan-briefing.md` | Targets, Day Plan, Briefing | 10 · 5 · 0 · 2 dark |
| `meetings-transcription.md` | Calendar, transcriber stack, dictation | 27 · 2 · 0 · 3 dark |
| `memory.md` | Memory vault, all phases | all phases frozen since 2026-08-01 |
| `ideas-streams-mail.md` | Ideas registry, stream digests, Gmail/IMAP/Jira comments | 12 · 3 · 2 |
| `multi-account-jira.md` | Google/Slack/Jira multi-account, Jira feature flags | 7 · 3 · 3 · 3 dark |
| `agent-ai-mcp.md` | Providers, prompts, tool registry, MCP, skills | 17 · 5 · 3 · 3 unreachable |
| `desktop-shell-gates.md` | Tray/daemon lifecycle, onboarding, **full gate matrix** (appendices A–C) | 8 · 6 · 0 · 5 unreachable |
| `runtime-live.md` | Live workspace: phase health, watermarks vs data, output freshness | 13 · 5 · 5 broken · 4 dark |
| `silent-failures.md` | Cross-cutting swallowed-error sweep | 1 Critical · 5 High |

Finding ids used in this directory and in the fix-wave plans: `C1–C6` (Critical), `H1–H28` (High) as numbered in the synthesis; domain reports carry their own local ids (e.g. runtime `F-1`, memory `C1`).

## Six root causes

1. **Migration 00048 (Slack id namespacing, live since 2026-08-03) broke five consumers**: digest `persistBatchResults` lookup (model returns bare `C…`, code keys on `1:C…` → `0 saved` every cycle), memory `seedPeople` idempotency on `aliases[0]` (crash every cycle, 46k duplicate entity files), legacy person aliases unreachable to namespaced lookups, every Desktop `slack://` deep link, `jira_issues.assignee_slack_id` never rewritten.
2. **Partial failure reported as success**: global digest watermark, `tracks.Run` returns nil on all-failed batches, ideas stage-1 floors advance past budget-dropped rows, search-sync window fixed at `initial_history_days`, Gmail transient-loss.
3. **Wave 2 hollowed the Inbox**: `InboxFeedView` (Dashboard/Learned/Profile/feedback) unreachable; `inbox.situations.enabled` default false while the spec said "pending owner review"; triage/learner/feed still burn AI for dead UI.
4. **Jira**: `jira.features.*` can never be true (write uses lowercased struct field names, read expects snake_case); account revoked since April; key detector is dead code so `jira_slack_links` was never written.
5. **No timeouts, no backoff, strong tier burned idle**: no wall-clock timeout on daemon AI subprocesses; ~2000 `reactions.get` on *archived* pending items per cycle; daily rollup / day plan / briefing / memory "weekly" steps re-run on the strong tier every 15 minutes.
6. **`DaemonManager.restart()` ignores exit codes** and can leave the system with no daemon; 17 call sites, and the only path by which a newly connected source starts syncing.

## Owner decisions (2026-09-13)

All sixteen were taken in the audit session. They are the design input for the fix waves; do not re-litigate them without the owner.

| # | Topic | Decision |
|---|---|---|
| 1 | Memory vault recovery (C2) | `git reset` the vault to the last good commit `memory(map)` 2026-08-01, reindex, reseed. Root fix is mandatory, not optional: seeder idempotency must consider **all** aliases, the index write must precede (or be atomic with) the git commit, and a guard test must pin "a pre-namespaced entity with an e-mail alias is neither duplicated nor aborts `Run`". One-off `1:` backfill of bare Slack ids in vault files and `memory_provenance` (the 00054 precedent). |
| 2 | Slack digests (C1) | Normalise the model's bare channel id in `persistBatchResults` (test both forms). **Fast-forward** the digest watermark to now; the six-week gap is not backfilled. |
| 3 | Inbox tab (H1, H2, H23) | **Parked.** Needs a separate brainstorming session — "what is Inbox, is it needed at all" — before anything is demolished or restored. Root fixes that do not depend on the answer proceed. |
| 4 | `jira.features.*` (C5) | yaml tags on the struct + viper round-trip test; seed role defaults via `SetDefault` so an absent key means the role default, not false; one-time config migration deletes the broken lowercase block (the `MigrateFeatureGates` precedent). |
| 5 | Jira key detector (H4) | **Wire it** in `cmd/sync.go` + a test; backfill-vs-forward-only decided at implementation. |
| 6 | Reaction commands enable (C6) | `FastForward` seeds the ledger with current reactions as seen/skipped, plus a per-cycle dispatch cap. Feature stays OFF until the owner flips it. |
| 7 | Slack search window (C4) | Window runs from `search_last_date`; `initial_history_days` applies to the first run only; a separate max-catch-up cap, with a log line and account status when the gap exceeds it. |
| 8 | Ideas (H10, H20, H21) | Stage-1 floors advance only over rendered rows (IDEA-01). Preference block excludes `kind='decision'`; LIKED means explicit approval or 👍 only. **Do not insert empty `stream_digests` rows** (the floor still advances). |
| 9 | Strong-tier cost (H14–H16, tier holes) | All four treated as bugs: daily rollup once per day plus on new channel digests, `read_at` reset on content change; day plan / briefing / next-step get an attempt marker + backoff (max 3/day); memory rewrite/reflect/map get a "done today" memo and evidence dedupe in `confirm`; `TierForSource` holes closed (learn calls → light). No new config keys. |
| 10 | Daemon reliability package (C3, H7, H8, H9, H11) | All five: AI subprocess timeout (~10 min) and a 30 s Slack `http.Client` timeout; `GetInboxItems` excludes archived rows; tracks `RunForWindow` returns an error on zero successful batches; **per-channel** digest watermark; `DaemonManager.restart()` checks exit codes, waits for pid death, surfaces the error. |
| 11 | Catch-Up stuck `building` (H13) | `Pipeline.Run` reaps `building` rows older than 30 min as failed at start; Desktop `CLIRunner` logs stderr of failed CLI calls (generic fix). |
| 12 | Wave-2 tools in target chat | **Leave as is**; update TGT-BRIEF-01 axis 3 so the contract matches the code. |
| 13 | Recap/notes prompts (H19) | Version bump with speaker-label attribution guidance. |
| 14 | Calendar stale-cleanup | Skip events referenced by `meeting_transcripts` or `meeting_recaps`. |
| 15 | No-Slack installs (H27) | The product must work without Slack: owner identity resolves from any connected account (Slack #1 → Google → Jira). Separate task after the Inbox brainstorming, not in wave 1. |
| 16 | `TargetBriefCenter` | Queue (the `MeetingRecorderCenter` pattern) instead of single-slot. |

Immediate owner action (no code): re-login the Jira account (`watchtower jira login --account 1`).

## Fix waves

Plans live under `docs/superpowers/plans/2026-09-13-audit-fix-wave*.md`.

- **Wave 1 — stop the bleeding** (data is being lost right now): digest id normalisation + fast-forward; memory seeder root fix + vault recovery; search-sync window; archived-items reactions + Slack/AI timeouts; `DaemonManager.restart()`.
- **Wave 2 — partial failure ≠ success**: per-channel digest watermark; tracks all-failed; ideas floors/prefs/empty rows; Catch-Up reap + CLI stderr; feed recap NOT NULL; Gmail transient-loss.
- **Wave 3 — Jira**: feature flags yaml/defaults/migration; key detector wiring; `assignee_slack_id` backfill; `jira_sync_state.last_error`.
- **Wave 4 — strong-tier cost** (decision 9): **shipped.** Daily rollup gated on new channel digests + `read_at` reset on regeneration; day-plan/briefing attempt budget (3/day, persisted, survives restart); next-step per-target attempt budget (migration 00068); memory rewrite/reflect/map "done today" memo (migration 00069) + `confirm` evidence dedupe; `TierForSource` holes closed (`catchup.learn`/`inbox.situation_learn` → light, 8 call sites tagged) plus a property-scan guard over every `Generate` call site. See "Wave 4 — left open" below for what this wave deliberately did not decide.
- **Wave 5 — the rest with decisions**: **shipped**, except two Desktop items deferred to wave 5b. Reaction-commands FastForward seed + dispatch cap (task 1, decision 6); recap/notes prompt version bump with conditional speaker attribution (task 2, decision 13); calendar stale-cleanup `NOT EXISTS` guard sparing recording-linked events (task 3, decision 14); `SetPromptStore` wired into briefing/digest/tracks/guide + the meeting-prep/extract-topics/day-plan factories, which also revived Slack-sourced idea mining (task 4); one daemon log stream with in-process rotation of `watchtower.log` (task 5); daily-rollup attempt budget (task 6); next-step parent-progress bump narrowed to real changes, closing a Wave 4 left-open item (task 7); `weaken` evidence dedupe widened alongside `confirm`, closing another Wave 4 left-open item (task 8); chat-client argv routed through stdin on a leading dash or size, on both providers (task 9); Desktop argv `--` separator + meeting-chat header wording + Crash Log tab + `has_recap` badge fix (task 12); TGT-BRIEF-01 axis-3 wording reconciled with the already-reaction-only Wave 2 tools (task 13, decision 12). **Deferred to wave 5b:** `TargetBriefCenter` queue (task 10, decision 16) and Desktop `slack://` raw ids (task 11, H-2) — see "Wave 5 — left open" below.
- **Not a fix wave**: Inbox brainstorming (decision 3); no-Slack identity (decision 15).

### Wave 4 — left open, and the owner's verdicts (2026-09-14)

Decision 9 covered the four cost sources named in its README line. It did **not** settle the six items below, so wave 4 left each of them explicitly open. **The owner ruled on all six on 2026-09-14**; none of them is an open question any more. Verdicts first, the original write-ups below them for the reasoning:

| Item | Verdict |
|---|---|
| `digest.channel` vs `digest.channel_batch` tier | **Accepted as-is.** The single-channel path is rare and the batch path (light) is the common case, so the inconsistency costs little. Revisit only if usage numbers say otherwise. |
| Rewrite/reflect stamp on attempt (seven-day cost) | **Accepted as-is.** This is the waste the wave exists to cut; two lines plus one test flip it back if pages start going stale. |
| Next-step cap is leaf-only (`RecomputeParentProgress` bumps a parent's `updated_at`) | **Fix in wave 5.** A cap that does not hold on non-leaf targets is a hole in something this wave just shipped; narrow the bump to fire only when the computed progress actually changes. |
| `weaken`'s unconditional step | **Fix in wave 5.** Same shape as the `confirm` bug, and the fix mirrors code that has already been reviewed. |
| Beliefs keeping stability accrued before the `confirm` fix | **Accepted as-is — do not rewind.** Rewriting belief frontmatter from `## History` risks more than the inflated numbers cost; hysteresis erodes them over time. |
| The daily rollup's own missing failure budget | **Fix in wave 5**, alongside a real attempt budget for that pipeline. |

Also settled on 2026-09-14: **decision 15 (no-Slack identity) is approved** as written and no longer waits on the Inbox brainstorming — nothing in it depends on that answer. **Decision D4 (`who_ping` / `write_back`) moved to the backlog** as `docs/backlog/2026-09-14-jira-who-ping-and-write-back-toggles-gate-nothing.md`. **Decision 3 (the Inbox) stays parked** pending its own session.

### Wave 5 — left open (2026-09-14)

Items wave 5 deliberately did not decide, or decided to defer, plus residues its own review rounds surfaced:

- **`TargetBriefCenter` FIFO queue (decision 16).** Verified still broken (`verify-desktop.md` Item A) but not implemented in this wave — **deferred to wave 5b**, a Swift-heavy change touching five view sites (`TargetsListView`, `TargetDetailView` ×4) and a rewrite (not deletion) of `testNewBriefCancelsTheSupersededStream`.
- **Desktop `slack://` raw ids (H-2, item C).** Confirmed still broken and wider than the original audit's list (all 9 `slack://` builders plus two unstripped `TargetDetailView` archives links and a private duplicate stripper in `IdeaDetailPane`) — **deferred to wave 5b**. Blocked on `Models/SlackAccount.swift` not decoding the `team_id` column that already exists (migration 00048).
- **`targets.extract`/`targets.link` wire-or-deregister (M-2).** Task 4's prompt-store wiring deliberately does not touch these two prompts: `targets.New` has no `SetPromptStore` seam at all, so the fix is wire-a-new-seam-or-deregister-the-prompt, a different-sized job than the wiring task did — still an open owner call.
- **`shake`/`retire`'s unconditional evidence-citation shapes.** Task 8 widened the wave-4 `confirm` dedupe to `weaken`; `shake` (a real active→shaken status transition from zero new evidence) and `retire` (already evidence-gated, never had the unconditional shape) are named but untouched, per owner decision 9's scoping.
- **The three chat prompt templates hand the model account #1's team id.** `ChatViewModel`/`TargetChatViewModel`/`TrackChatView` embed a single `team=` into their Slack-link-formatting instructions to the model — flagged, not fixed, in item C; a per-account rule for a model-authored string is a different shape of fix than the builder-side resolver wave 5b will add for the app's own links.
- **A third, independent copy of the attempt-budget block, not shared with wave 4's two.** Task 6 gave the daily rollup its own `rollupAttemptDate`/`rollupAttempts`/`rollup_attempts.txt` trio rather than extracting a shared helper from day-plan/briefing — a deliberate copy (per the plan's ruling) now sitting next to the next-step per-target budget (task 7) as a fourth near-identical block; consolidating them is a follow-up, not a defect.
- **Stray loggers still write to `daemon.log`.** Task 5's fix stops the daemon's own logger from duplicating into `daemon.log`, but several components (`internal/db/targets*.go`, `internal/ai/context_builder.go`, `cmd/tracks.go` via the stdlib default logger; `BoardAnalyzer`/`KeyDetector`, which `wireJiraSyncers` never wires a logger onto) still log to stderr, i.e. into the one file that cannot be rotated while the daemon runs. Filed as `docs/backlog/2026-09-14-stray-loggers-still-write-to-daemon-log.md`.
- **`watchtower logs -f` goes silent across an in-process rotation.** `cmd/logs.go`'s `followLog` opens `watchtower.log` once by path; task 5's new in-process rotation renames that inode out from under a running `-f`, so a long-lived follower stops seeing new lines after the first rotation. Reported, not fixed, per the controller (task 5's commit).
- **The two batch generators (`internal/digest`, `internal/codex/generator.go`) still route on size alone, no leading-dash guard.** Task 9 closed the leading-dash/size gap for both chat clients; the batch generators were already on the `StdinThreshold` size split and are out of scope for a chat-client fix. Holds today because `cmd/dictate.go` prefixes a fixed header and `internal/memory`'s `TestBuildExtractPromptsNeverStartWithDash` pins the memory prompts specifically — this is now the only unpaired spot of that class.
- **`reactions.list`'s sliding window.** Task 1's seed covers everything the poll can currently see, but removing a reaction slides Slack's own 2000-item window forward, which can surface an OLDER reaction the seed never recorded — a pre-existing property of the API, now bounded by the same `maxDispatchPerRun = 25` cap as any other backlog.
- **Wave 3's Jira carry-overs.** Decision D4 (`who_ping`/`write_back` toggles gating nothing) is the one wave-3-adjacent item resolved this cycle, moved to the backlog above rather than fixed in code; no other wave-3 item was reopened.

The original write-ups:

- **`digest.channel` (strong) vs `digest.channel_batch` (light)** — same prompt shape, same output schema, different tier depending only on which batching path a channel happened to take that cycle. Genuinely out of scope for decision 9 (its own wording is about frequency, not this inconsistency) — needs an owner call between promoting `digest.channel` to light (cheaper, but weakens the busiest channels' digest quality) and demoting `digest.channel_batch` to strong (consistent, but multiplies the common-case call volume). See `internal/digest/tier_scan_test.go`'s `allowedStrongSources` entry and the wave's own verification notes.
- **Memory rewrite/reflect stamp on attempt, not on success.** `dueForRewrite` and `dueForReflect` each fire on exactly one day in seven (`rewriteStaggerDays`/`reflectStaggerDays = 7`), per entity for rewrite and per workspace for reflect, so a page or workspace whose strong-tier step keeps failing waits a full week — not one day — for the next retry, instead of being re-tried every ~70-minute cycle until then. Put plainly: the cost of one transient failure is seven days, not one. This is deliberate — it is the cost this wave exists to cut, and a repeatedly-failing step retried every cycle was exactly the waste finding H2 named — but it is a two-line change plus one test to flip back to stamp-on-success if the owner would rather eat the retry cost than the wait.
- **The next-step fresh-edit escape hatch is keyed on raw `targets.updated_at`**, which `RecomputeParentProgress` bumps on a parent every time a child changes, whether or not the computed average actually moved. A parent with actively-churning children can therefore look "freshly edited" every cycle and exceed the 3/day next-step cap. Pre-existing property of the column (it already drove `next_step_at` staleness the same way); documented at the call site rather than fixed, since narrowing the semantics touches five call sites and is riskier than the hole it closes.
- **`weaken` has the same unconditional-step shape `confirm` had** before this wave's dedupe (`belief_math.go`: an unconditional `-0.1` per op regardless of whether the cited evidence is new). Decision 9 named only `confirm`; `weaken` is a follow-up, not silently included.
- **Beliefs that already accrued unearned stability from the pre-fix `confirm` bug keep it.** The fix stops new accrual; it does not rewind beliefs already sitting at inflated confidence/stability behind a single re-cited evidence line. Rewinding would mean rewriting belief frontmatter from `## History` — a separate, owner-visible decision, not made here.
- **The daily rollup itself still has no failure budget.** `runDailyRollupForDate` gates regeneration on a newer channel digest existing, but a failed AI call returns before `storeDigest` ever runs — the existing daily row's `created_at` never advances, so a persistently-failing `digest.daily` re-attempts every cycle for as long as a newer channel digest keeps qualifying it as "new since the last rollup." Deliberately out of scope for decision 9 (which gated on new-material, not failure retries); belongs to the next wave alongside a real attempt budget for this pipeline.

## Wave 1 operator steps

Run with the owner, on the owner's live workspace, after wave 1 is merged and the new binary is installed.
Everything below is previewable: run each `--dry-run` first and read its output before the real run.

1. **Stop the daemon** — `watchtower sync stop` (or Quit from the tray; the Desktop app respawns the daemon while it is open, so quit the app too). Nothing else may be writing the vault.
2. **Preview the vault reset** — `watchtower memory reset-to <sha of the "memory(map)" commit from 2026-08-01> --dry-run`.
   Find the sha with `git -C ~/.local/share/watchtower/<workspace>/memory log --oneline --before=2026-08-02`.
   The preview prints the current HEAD, the target, how many commits would be discarded and how many files would disappear (expect ~44 600). It refuses if another memory run holds the lock (naming the pid). Uncommitted worktree changes are *reported* by the preview, not refused — only the real run in step 3 refuses on them, so commit or remove whatever the preview lists before going on.
3. **Reset for real** — same command without `--dry-run`. It hard-resets the vault, rebuilds the SQLite index from the surviving files, and fast-forwards the memory extraction watermarks to now (the six-week backlog is deliberately **not** re-extracted). On a 553 MB `.git` with tens of thousands of files this is minutes, not seconds — go-git rewrites the index and walks the worktree twice (once for the dirty check, once for the reset). Let it finish.
   The vault's gitignored files (`.obsidian/`, `.DS_Store`, `*.tmp` — i.e. the owner's Obsidian configuration) are copied aside and restored around the reset, because go-git's hard reset would otherwise delete them; both runs report the count as "Ignored files preserved".
4. **Preview the Slack-id backfill** — `watchtower memory migrate-slack-ids --dry-run`. It prints the nodes to rewrite by type, the alias/provenance counts, **every** alias rewrite, and ten sample provenance rewrites. Read the alias list: a wrong entry there renames a page's identity, and it is the list to stop on if anything in it is not a Slack id. The command refuses outright if two or more Slack accounts are connected (including disabled/removed rows).
5. **Backfill for real** — same command without `--dry-run`. One `memory(migrate)` commit plus a reindex. Re-running it is safe and does nothing.
   **It must run AFTER the reset, never before**: it stages every rewritten node into one commit, and go-git walks the whole worktree per staged node, so against the pre-reset vault (tens of thousands of files) the cost is effectively unbounded. It logs its progress every 100 nodes scanned and again before the commit, which is the slow part.
   **If it is interrupted**, rewritten node files are already on disk with nothing committed. Do not start the daemon in that state: the next pipeline run would sweep them into a `memory(owner-edit)` commit (MEM-03), mis-attributing a machine migration to the owner. A re-run will **not** clean that up for you — its idempotency is over the files, and those files are already namespaced, so it would find nothing to do. It refuses instead, naming the uncommitted paths. Commit them in the vault by hand as a `memory(migrate)` commit (`git -C ~/.local/share/watchtower/<workspace>/memory add -A && git -C … commit -m "memory(migrate): slack ids → namespaced (interrupted run)"`) — or `git checkout` them away and re-run the command from a clean worktree. Either way, confirm the vault is clean before step 6: `git -C ~/.local/share/watchtower/<workspace>/memory status --short`.
   Note on the reindex both commands run: it drops and rebuilds the derived index, which also clears `memory_node_stats` (per-node access counters) and `memory_dispute_flags` — pre-existing MEM-02 behaviour, not something these commands added. Neither is rebuildable from the vault files; after a six-week rewind both are about to be re-earned anyway, so this is immaterial here. `memory_engagement` and the hint tables survive.
6. **Start the daemon** — `watchtower sync --daemon --detach` (or reopen the app, which starts it).
7. **Re-enable Slack digests** — `watchtower features enable slack-digests` (decision 2: the watermark is fast-forwarded, the six-week gap is not backfilled).
