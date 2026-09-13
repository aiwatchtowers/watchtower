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
- **Wave 4 — strong-tier cost**: decision 9.
- **Wave 5 — the rest with decisions**: reaction-commands FastForward; recap prompt bump; calendar cleanup guard; `TargetBriefCenter` queue; TGT-BRIEF-01 wording; briefing `SetPromptStore`; chat `--` before prompt; Desktop `slack://` raw ids; duplicate logs + rotation.
- **Not a fix wave**: Inbox brainstorming (decision 3); no-Slack identity (decision 15).

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
