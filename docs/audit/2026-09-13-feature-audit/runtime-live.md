# Runtime audit — the owner's live install (`whitebit` workspace)

Audited 2026-09-12 (read-only). Sources: `~/.config/watchtower/config.yaml`, `~/.local/share/watchtower/whitebit/{watchtower.db,daemon.log,daemon.log.1,sessions.log,memory/,last_*.txt,*.lock}`, process table, `~/Library/Application Support/Watchtower/bin/watchtower version`. DB opened only via `sqlite3 -readonly "file:...?mode=ro"` (WAL read worked; the live daemon holds the write side).

## Environment snapshot

| Item | Observed |
|---|---|
| Running binary | `~/Library/Application Support/Watchtower/bin/watchtower` = `v0.9.0-122-g37179540-dirty`, commit **37179540 = repo HEAD**, built 2026-09-11T15:29Z, SHA256 identical to `build/Watchtower.app/Contents/MacOS/watchtower`. Daemon pid 35808 started 2026-09-11 20:52 local, **120 min CPU in 20 h**. |
| Schema | `goose_db_version` top = **64** (applied 2026-09-09), highest file `internal/db/migrations/00064_reminders.sql` → in sync. |
| Config gates (live) | `digest.enabled`, `calendar`, `gmail`, `jira`, `ideas`, `day_plan`, `memory.enabled` + `memory.semantic.enabled`, `memory.surfaces.{briefing,chat,disputes,reflection}` = true; `memory.sources.actions: false`; **not present → defaults**: `reaction_commands.enabled` (false, `internal/config/defaults.go:50`), `inbox.situations.enabled` (false, `defaults.go:35`), `streams.enabled` (true), `tracks/people/briefing/inbox.enabled` (true). `digest.model: claude-sonnet-4-6` (retired seeded default, ignored). `workspaces.whitebit.slack_token` is `""` (legacy blanking worked). `jira.features.*` 11 keys all false (nothing reads them). |
| Accounts | google #1 `…@ec319.com` ok, #3 `…@whitebit.com` ok (gmail synced to 2026-09-12 12:35Z / 04:41Z); slack #1 WhiteBIT ok, `current_user_id=1:U0118BRJH54`, `search_last_date=2026-09-12`; **jira #1 `status=revoked`** (`refresh_token is invalid`), enabled=1, `jira_issues` newest 2026-04-24, `jira_token_1.json` mtime Apr 25 → **Jira dead ~4.5 months**. |
| Locks | `digest.lock`/`sync.lock`/`memory.lock` are 0-byte `flock(LOCK_EX|LOCK_NB)` files (`cmd/sync.go:268-281`, `internal/digest/pipeline.go:262-279`, `internal/memory/vault.go:258-272`). The lock is the kernel flock, not the file's existence — a stale file from March cannot block anything. `ideas_backfill.lock` (pid+timestamp, 2 h freshness) is not present. |
| Dead markers | `last_action_items.txt` (2026-03-24) and `last_guide.txt` (2026-03-20): zero references in Go code → orphan files of retired phases (`observers` pipeline last ran 2026-07-04, `tasks`/`jira-boards` CLI-only since April). Harmless. |
| Logs | `daemon.log` and `watchtower.log` are **different inodes with identical size** (130,767,350 B) — not a hardlink but a double write: the detached child's stderr is redirected to `daemon.log` (`cmd/sync.go:212-213`) and the same process also logs through `io.MultiWriter(watchtower.log, os.Stderr)` (`cmd/sync.go:300-302`). Rotation at 20 MB happens only at open (`cmd/sync.go:117-123, 129-145`), so 4 files ≈ 910 MB. **No token leaks** (`xoxb-`/`xoxp-`/`Bearer `/`access_token`/`ya29.` = 0 hits; `refresh_token` 72 hits are all the literal Jira error text `"refresh_token is invalid"`). 478 k lines carry e-mail addresses (PII) — the memory quarantine spam below. |

## Feature / phase status table

Rows are daemon phases in `runSync` order (`internal/daemon/daemon.go:311-369`). "Last done" from `pipeline_runs` (`source='daemon'`) or the log where the phase has no run row.

| Phase / feature | Gate key (default) | Entry point | Reachable in UI? | Verdict | Why (live evidence) |
|---|---|---|---|---|---|
| Slack sync | orchestrators non-empty (slack #1 ok) | `phaseSlackSync` daemon.go:412 | Digests/Inbox/Chat | **WORKS DIFFERENTLY** | Messages fresh (`MAX(messages.ts_unix)`=2026-09-12 15:05), but each cycle takes **~52 min**: ~2 000 `reactions.get` calls (tier-3 rate limit) for pending-but-archived inbox items — see F-3. Poll interval 15 m is nominal only; real cycle 70–85 min. `emoji sync failed: missing_scope` every cycle (cosmetic). |
| Google Calendar sync | `calendar.enabled` (true) | `phaseCalendarSync` :439 | Calendar tab | WORKS | `calendar: N events synced` each cycle; `calendar_events` newest 2026-09-12 12:01Z. |
| CalDAV / IMAP | accounts (0 rows) | :454 / :485 | — | DARK (no accounts) | `calendar_accounts`=0, `email_accounts`=0. |
| Gmail sync | `gmail.enabled` (true) | `phaseGmailSync` :470 | Digests (streams) | WORKS | Both accounts syncing; `gmail_last_internal_date` within hours. |
| Jira sync | `jira.enabled` (true) + syncer | `phaseJiraSync` :517 | Jira tab, Settings | **BROKEN (auth)** | `jira auth revoked` every cycle since ≤2026-04-26; status `revoked` correctly written (:545-550). Downstream starved: `jira_comments`=0, no `stream_digests(source='jira')`, no `ideas.digest_jira`, memory `memory_jira_last_extracted_ts=0`. |
| Fast inbox detect | `inbox.enabled` (true) | `phaseFastInbox` :593 | Inbox items (only via legacy `InboxFeedView`, see strip row) | WORKS | `inbox fast: +N new` each cycle; `inbox_last_processed_ts`=2026-09-12 14:04Z vs newest message 15:05 (one cycle behind, expected). |
| Slack channel digests | `digest.enabled` (true) | `phaseChannelDigests` :608 → `digest.Pipeline.RunChannelDigestsOnly` | Digests tab | **BROKEN** | Every batch: `44 channels, 13 results from AI, 0 saved` + `batch result for unknown channel CNSQLBQYNE, skipping` — bare vs namespaced channel-id mismatch (F-1). Saved channel digests: 1 258 in Jul → **32 in Aug, 9 in Sep**; daily rollups stopped 2026-08-16. 1.24 M output tokens burned in 72 h for 4 saved digests. |
| Unsnooze / due targets | db non-nil | `phaseUnsnooze` :638 | Targets | WORKS | No errors; nothing due. |
| Transcript audio cleanup | `transcripts.audio_retention_days` (30) | :663 | — | WORKS | `removed N orphaned recording(s)` ×5, `processed 1 expired`. |
| Custom tracks scan | `tracks.enabled && digest.enabled` | `phaseCustomTrackScan` :1117 | Tracks tab | WORKS | 38 done / 0 err in 72 h, 7 events; 2 custom tracks `last_run_at`=2026-09-12. |
| Auto tracks + rollups | `tracks.enabled && digest.enabled` | `phaseTracksAndRollups` :751 | Tracks tab, Digests | WORKS DIFFERENTLY | Runs clean (39/39) but `tracks: no digests found` most cycles — starved by the digest failure (F-1). 985 auto tracks, newest update 2026-09-10. |
| People cards | `people.enabled && digest.enabled` | `phasePeopleCards` :796 | People tab | WORKS (costly) | Daily; 443 cards/day, 371 k output tokens per run; `people_cards` = 15 317 rows. Inputs (`people_signals`) come from digests, so cards are increasingly re-derived from stale signals. |
| Inbox full pipeline (triage/learner/auto-resolve/archive) | `inbox.enabled` | `phaseInbox` :827 → `inbox.Pipeline.Run` | Inbox items | WORKS | 38 done / 1 err (claude session limit) in 72 h; 90 items, 284 k tokens. |
| Situations compose + cards | **`inbox.situations.enabled` (false)** | `internal/inbox/pipeline.go:288` | Dashboard (`InboxFeedView`) is **no longer in navigation** | DARK (by Wave-2 design) | `compose_last_run_ts`=2026-09-09 10:16Z = the day migration 00064/new binary landed; log shows `situations +0/~0, 0 cards` every cycle. 586 situations frozen (79 open, 434 stale). |
| Stream digests (Gmail/Jira stage 1) | `streams.enabled` (true) | `phaseStreamDigests` :951 | Digests tab | WORKS (Gmail only) | 7 done / 1 err (session limit); 94 rows, all `source='gmail'`, newest 2026-09-12 02:42Z. Jira half dead (auth). |
| Ideas consolidate | `ideas.enabled` (true), 6 h | `phaseIdeas` :880 | Ideas tab, Decisions ledger | WORKS | 8 done / 0 err; `ideas: proposed 8`; floors honest: `ideas_digest_floor`=30 668 = `MAX(digest_topics.id)`, stream 94 = max, transcript 79 = max. 348 active decisions, 8 proposed ideas. |
| Reaction commands | **`reaction_commands.enabled` (false)** | `phaseReactionCommands` :1004 | Inbox strip | DARK | Zero `pipeline_runs` rows ever; `reaction_commands`=0; dictionary seeded (6 rows) and `tool_trust` seeded (4 rows) by 00063/00064 but nothing polls. |
| Memory consolidation | `memory.enabled` (true) | `phaseMemory` :1038 → `memory.Pipeline.Run` | Chat MEMORY block, briefing journal, MCP `memory_*` | **BROKEN since 2026-08-03** | Fails every cycle (344 identical errors, 0 successes since 2026-08-01T19:51Z) with `UNIQUE constraint failed: memory_aliases.alias`; each attempt costs ~24 min and ~44 k log lines; the vault has ballooned to **46 529 entity files / 182 MB + 553 MB .git** (F-2). `memory_last_extracted_ts`=2026-08-01 22:27Z vs newest message 2026-09-12 → 6 weeks of Slack never extracted. All semantic-tier + surface work downstream of `Run` never executes. |
| Next-step suggestions | `targets.next_step.enabled` (true) | `phaseNextStep` :1093 | Targets | WORKS | 38/38 done, 0 items (6 todo targets already have suggestions). |
| Daily briefing | `briefing.enabled` (true), hour 8 | `phaseBriefing` :1136 | Briefing tab | WORKS | id=143 generated 2026-09-12 06:26Z; `last_briefing.txt` fresh. Its *Memory revisions* journal (`memory.surfaces.briefing`) has had nothing to show since Aug 1 (memory frozen). |
| Day plan + conflicts | `day_plan.enabled` (true), hour 8 | `runDayPlanPhase` :1366 | Day Plan tab | WORKS | plan for 2026-09-12 generated 06:26Z; 122 plans. |
| Feed publish | not gated (Core) | `phaseFeed` :1077 → `feed.Pipeline.Publish` | Dashboard timeline | **WORKS DIFFERENTLY** | `feed error: meeting_recap: NOT NULL constraint failed: feed_items.source_id` every cycle; no `meeting_recap` feed item since 2026-08-21 (F-4). Other four sources publish. |
| Inbox action strip (Desktop) | — | `ActionStripView` ← `AgentActionQueries.fetchStrip` | Inbox tab | WORKS DIFFERENTLY (empty by construction) | Strip = non-terminal `agent_actions` ∪ due `reminders`. Live: `agent_actions`=1 row (`create_jira_issue`, `failed`, 2026-09-05, Jira revoked), `reminders`=0. So the Inbox tab shows **one un-retryable failed card and nothing else**, while 67 unarchived actionable pending inbox items exist that no longer have a screen. |
| Catch-Up | CLI `catchup run` from Desktop | `internal/catchup/pipeline.go:90-145` | Catch-Up tab | **BROKEN (observed)** | All 3 `catchup_recaps` rows are `status='building'`, error empty, 0 tokens, created 2026-09-11 19:09:59/19:10:10/19:10:21Z (three attempts ~11 s apart) — the CLI died before `finish`/`failRun` (F-5). The owner has never seen a finished recap. |
| Meeting transcripts / chapters / notes | Desktop + CLI | `pipeline_runs` `meeting_*` | Recordings tab | WORKS | 77 transcripts, newest 2026-09-11; chapters/notes runs clean. |
| Agent actions (chat) | `--tools chat` | `internal/tools` registry | Main/target chat | WORKS (1 sample) | One proposal recorded and correctly landed `failed` with the Jira error in `error`. |

Verdict counts: WORKS 13 · WORKS DIFFERENTLY 5 · BROKEN 5 (digests, memory, Jira-auth, feed recap, catch-up) · DARK 4 (situations, reaction commands, CalDAV/IMAP, plus memory gmail/calendar sources by default).

## Findings

### Critical

**F-1. Slack channel digests are almost never saved — batch results are keyed by bare channel id, the pipeline looks them up by namespaced id.**
- Code: `internal/digest/pipeline.go:931-943` (`persistBatchResults` builds `entryMap[batch[i].channelID]` with the namespaced `"1:C…"` id and does `entryMap[r.ChannelID]` on the model's answer); the batch prompt shows the id as `--- #name (1:C…) ---` (`pipeline.go:1567`) but its JSON example says `"channel_id": "C123ABC"` (`internal/digest/prompt.go:78`), so the model returns the bare form.
- Intended: CLAUDE.md "Slack Multi-Account": "every downstream query treating these as opaque unique strings keeps working"; the house rule "internally namespaced, raw toward the model/text" (`docs/inventory`, memory note) says any comparison between a stored id and model-authored text must check both forms.
- Live: every batch in 20 h of log: `digest: batch: 44 channels, 13 results from AI, 0 saved` + `batch result for unknown channel <bare id>, skipping` (≈20 distinct channels per cycle). `digests(type='channel')` per month: Jul 1 258 → Aug 32 → Sep 9; the few saves are batches where the model happened to echo `1:C…`. Daily rollups (`RunDailyRollup` needs ≥2 channel digests/day, `pipeline.go:1002`) stopped 2026-08-16.
- Failure scenario: because nothing is saved, `derivedLastDigestTime()` (`pipeline.go:1626-1632`) keeps returning the last saved `period_to` (2026-09-11 13:23 for the whole day), so **the same ever-growing window is re-sent to the model every cycle** — 37 runs / 1.24 M output tokens in 72 h for 4 digests — and `#alerts-nginx hit message limit` warnings show the window already overflows. Tracks (`tracks: no digests found`), people signals, ideas stage-1 (`digest_topics`), memory compare-mode and the Digests tab are all starved. **Owner-visible since ~2026-08-03 (migration 00048 date).**

**F-2. Memory pipeline has failed on every cycle since 2026-08-03 and is filling the vault with duplicate entities (46 529 files, +~119 per cycle).**
- Code: `internal/memory/seed.go:97-101` — idempotency = `LookupMemoryAlias(c.aliases[0])` where `aliases[0]` is `users.id`, now `"1:U…"` after 00048, while entities seeded before the migration carry the bare `"U…"` alias (live: `memory_aliases` has 188 bare `U*` aliases vs 55 `1:U*`; `U0118BRJH54 → ent_01KXKD1FQK…`). Lookup misses → a new node with aliases `["1:U…", email]` is written and **committed to the vault** (`v.WriteNodes`, `seed.go:126`) *before* the index upsert (`seed.go:132+`) fails on the second alias (`UNIQUE memory_aliases.alias` for the e-mail already on the old node) → `Run` returns the error. Next cycle `Reconcile` (`internal/memory/index.go:236-239`) finds the orphan file, cannot index it, quarantines it (one log line each: `index.go:147`) and the seeder repeats.
- Intended: MEM-02 (index derived from files), MEM-04 (watermark freeze on failure — honoured, which is exactly why extraction has been frozen 6 weeks); CLAUDE.md multi-account §"Documented v1 identity-scoping decisions" item 4 acknowledges a *belief-subject* mismatch for bare aliases but not this seeder loop.
- Live: `pipeline_runs(pipeline='memory')`: last `done` 2026-08-01T19:51Z, **344 consecutive errors**, avg duration 1 461 s; vault `git log` = 1 112 commits, every recent one `memory(seed): 119 entities`; `entities/` 46 529 files (indexed 1 879), `.git` 553 MB; 439 975 of 462 838 lines in the current `daemon.log` are quarantine spam; `memory_last_extracted_ts`=1785577644 (2026-08-01) vs messages through 2026-09-12. Every downstream surface the owner enabled (`memory.surfaces.chat/briefing/disputes/reflection`, `memory.semantic`) has had no new input since Aug 1 — the Discuss MEMORY block and the briefing "Memory revisions" journal are silently stale.
- Failure scenario: each daemon cycle spends ~24 min re-reading 46 k files, appends 119 more junk files and a git commit, and logs 44 k lines (≈6.5 MB/h). Left alone, the vault and log grow without bound; `watchtower memory reindex` would rebuild the index but cannot un-commit the duplicates. **Needs owner decision** on the recovery path (vault history rewrite vs. tombstoning 44 k duplicate entities) — MEM-02/MEM-07 adjacent.

### High

**F-3. Slack sync spends ~50 of every ~70 min on `reactions.get` for inbox items that are already auto-archived.**
- Code: `internal/sync/orchestrator.go:363` loads `GetInboxItems(db.InboxFilter{Status: "pending"})`; `internal/db/inbox.go:165-192` has **no `archived_at IS NULL` predicate** (the inbox package's own queries at `inbox.go:698, 702, 825-851` all add it). Auto-archive sets `archived_at` but leaves `status='pending'`, so the reactions phase iterates every archived item forever.
- Live: `synced reactions for 531/1997 pending inbox messages`; `inbox_items`: 2 014 ambient + 508 actionable rows are `pending` **and archived** (oldest 2026-04-02); `sync complete: 2 150 API calls (tier3: 2 079)` per cycle; phase 2 search takes 2 min, the rest of the 52 min is this loop (memory note `project_sync_stuck_reactions_phase` documents the same symptom).
- Failure scenario: with `sync.poll_interval: 15m` the owner expects quarter-hourly freshness; actual cadence is 70–85 min (11 cycles in 20 h), the ticker's dropped ticks make the daemon run back-to-back with no idle, and every AI phase downstream runs at most ~17×/day. Adding `AND archived_at IS NULL` to that one query would cut ~75 % of Slack API calls per cycle.

**F-4. Feed never publishes meeting recaps — ad-hoc recaps have `event_id NULL`, `feed_items.source_id` is NOT NULL.**
- Code: `internal/db/feed.go:124-131` inserts `SELECT 'meeting_recap', r.event_id, …` for every `meeting_recaps` row after the cutoff; one NULL row fails the whole `INSERT … SELECT`.
- Intended: CLAUDE.md Meeting Transcriber — ad-hoc recaps land in `meeting_transcripts.summary_json`, event-linked in `meeting_recaps` with `event_id`; DASH-06 (feed best-effort). The live table nevertheless has 36 of 50 `meeting_recaps` rows with `event_id IS NULL` (all have `transcript_id`).
- Live: `feed error: meeting_recap: … NOT NULL constraint failed: feed_items.source_id (1299)` on all 11 cycles; last `meeting_recap` feed item 2026-08-21. Failure scenario: every recap recorded since 21 Aug, event-linked or not, is missing from the Dashboard timeline, and will stay missing until the query filters/coalesces the key.

**F-5. Catch-Up has never produced a recap for the owner — all three attempts are stranded in `building`.**
- Code: `internal/catchup/pipeline.go:95-99` inserts the `building` row first; only `finish`/`failRun` (:255-275) move it to `ready`/`failed`, and both require the process to survive. `CatchUpViewModel.swift:205` spawns `catchup run --json`; nothing in Go or Swift reaps a `building` row whose process died.
- Live: rows 1–3 created 2026-09-11 19:09:59Z, 19:10:10Z, 19:10:21Z — 10–11 s apart, `error=''`, `model=''`, tokens 0 — i.e. each CLI died within seconds, before the AI call (during `runTopUp`/`gather`). A daemon-held `digest.lock` would only make the top-up's channel-digest rerun log-and-skip (`internal/digest/pipeline.go:354-358`), not crash, so contention is not the explanation; the actual crash cause is not recoverable from the logs available to me (see gaps).
- Failure scenario: the Catch-Up pane polls a `building` row that will never transition (CATCHUP contracts assume every row ends `ready|failed`), so the owner sees a perpetual "building" or an empty list. **Needs owner decision**: stale-`building` reaping policy (CATCHUP-adjacent).

**F-6. Jira account revoked since April; every Jira-dependent feature has silently produced nothing for 4.5 months.**
- Code path is behaving as designed (`daemon.go:545-550` writes `revoked`; Settings shows Re-login). Listed because the *consequences* are broad and invisible: `jira_issues` frozen at 2026-04-24, `jira_comments`=0 (so INBOX-02 Jira-comment triggers never fire), `stream_digests` has no `jira` rows, `ideas.digest_jira` never ran, `agent_actions#1` (`create_jira_issue`) failed on it, the `ticket` reaction mapping would fail the same way, `memory_jira_last_extracted_ts=0`. One re-login fixes all of it; until then the audit of those features cannot distinguish "broken" from "no input".

### Medium

**F-7. Situations pipeline muted by default → the owner lost the only screen that showed pending inbox items.** `inbox.situations.enabled` absent → false (`defaults.go:35`, checked at `internal/inbox/pipeline.go:288`); `compose_last_run_ts` stopped 2026-09-09. Triage still runs and produces 67 unarchived actionable `pending` items (11 mentions, 10 DMs, 3 thread replies, 116 e-mails…) but `InboxFeedView` is unreachable (CLAUDE.md Wave 2) and `ActionStripView` shows only `agent_actions`/`reminders` — live: one failed Jira card. Documented as deliberate (STRIP-01), but the owner would perceive "Inbox shows nothing" — **needs owner decision** whether this is the intended steady state.

**F-8. Daemon logging volume and duplication.** Two identical 130 MB logs (`cmd/sync.go:212-213` vs `:300-302`), rotation only at open (`:117-145`); the daemon appends ~6.5 MB/h while F-2 persists. 478 k log lines carry personal e-mail addresses.

**F-9. Digest cost amplification.** Consequence of F-1 worth its own number for the owner's bill: `pipeline_runs(digests)` Aug+Sep = 350 runs, 41 saved digests, 8.2 M output tokens (vs Jul 854 runs / 1 258 digests / 6.2 M).

### Low

- `warning: emoji sync failed: fetching emojis: missing_scope` every cycle — token lacks `emoji:read`; cosmetic.
- `warning: failed to get read cursor for 1:C0…: channel_not_found` ×2 channels per cycle (left/archived channels still in `channels`).
- Retired prompt rows remain in `prompts` (`guide.*`, `observer.*`, `tracks.create/extract/update`, `meeting.extract_topics`) — harmless.
- `last_action_items.txt`, `last_guide.txt` orphan marker files.
- `pipeline_runs` has 7 `ask` + 6 `memory(cli)` rows stuck `running` from Jul (killed CLIs) — cosmetic, but any "currently running" UI would lie.

## Watermarks vs data (item 2)

| Watermark | Value | Should track | Gap |
|---|---|---|---|
| `workspace.inbox_last_processed_ts` | 1789220269 (2026-09-12 14:04Z) | `MAX(messages.ts_unix)` 2026-09-12 15:05Z | ≤1 cycle — healthy |
| `workspace.compose_last_run_ts` | 2026-09-09 10:16Z | — | frozen by `inbox.situations.enabled=false` (F-7) |
| `workspace.memory_last_extracted_ts` | 1785577644 (2026-08-01 22:27Z) | messages | **6 weeks stalled** (F-2) |
| `workspace.memory_last_ingested_situation_id` | 1 | `MAX(situations.id)`=586 | never advanced past 1 — situations ingest never committed (F-2 aborts `Run` before the watermark write; MEM-04) |
| `workspace.memory_chat_turn_floor` / `_last_interaction_id` / `_last_situation_feedback_id` | 199 / 0 / 15 | — | `actions` source off (dark), others frozen with F-2 |
| `workspace.memory_calendar_last_extracted_ts` | 2026-05-08 | — | `memory.sources.calendar` default off (dark) |
| `google_accounts.memory_gmail_last_extracted_ts` | 0 / 0 | — | `memory.sources.gmail` default off (dark) |
| `jira_accounts.memory_jira_last_extracted_ts` | 0 | — | dark + F-6 |
| `workspace.ideas_digest_floor` / `_stream_digest_floor` / `_transcript_floor` | 30668 / 94 / 79 | `MAX(digest_topics.id)`=30668, `MAX(stream_digests.id)`=94, `MAX(meeting_transcripts.id)`=79 | exact — IDEA-01 holds |
| `google_accounts.ideas_email_floor` | 2026-09-11 / 2026-09-11 | gmail rows | fresh |
| `jira_accounts.ideas_jira_floor` | 2026-08-09 | — | no new Jira rows to consume (F-6) |
| `workspace.digest_fastforward_ts` | 0 | — | unused (feature never re-enabled) |
| digest window (`derivedLastDigestTime`) | last saved `period_to` | messages | re-sent every cycle (F-1) |
| `slack_accounts.search_last_date` | 2026-09-12 | — | healthy |
| `google_accounts.gmail_last_internal_date` | 2026-09-12 12:35Z / 04:41Z | — | healthy |

## Output freshness (item 3)

| Table | Rows | Newest | Note |
|---|---|---|---|
| `digests` channel / daily | 5 217 / 92 | 2026-09-11 12:30Z / 2026-08-16 | F-1 |
| `situations` | 586 (79 open, 434 stale, 73 done) | 2026-09-09 | muted (F-7) |
| `inbox_items` | actionable pending 575 (67 unarchived) / resolved 2 510; ambient pending 2 270 / resolved 2 279 | 2026-09-12 15:57Z | triage alive |
| `agent_actions` | 1 (`failed`) | 2026-09-05 | F-6 |
| `reminders` / `reaction_commands` | 0 / 0 | — | reaction commands dark |
| `ideas` | decision active 348; idea active 1, proposed 8 | 2026-09-11 20:31Z | alive |
| `stream_digests` | 94 (all gmail) | 2026-09-12 02:42Z | Jira half dead |
| `catchup_recaps` | 3, all `building` | 2026-09-11 | F-5 |
| `briefings` | 136 | 2026-09-12 06:26Z | alive |
| `day_plans` | 122 | plan_date 2026-09-12 | alive |
| `meeting_transcripts` / `meeting_recaps` | 77 / 50 (36 without event) | 2026-09-11 | alive; F-4 |
| `memory_nodes` | entity 1 879, episode 516 active/419 closed/203 tombstone, belief 33, rollup 60 | episodes/beliefs 2026-08-01 | frozen (F-2) |
| `people_cards` | 15 317 | 2026-09-11 20:20Z | alive, heavy |
| `tracks` | 985 auto + 2 custom | 2026-09-12 | alive but starved |
| `feed_items` | situation 583, briefing 53, day_plan 53, meeting 44, meeting_recap 33 (last 2026-08-21) | 2026-09-12 | F-4 |
| `targets` | todo 6, done 18, dismissed 26 | 2026-08-25 | — |

## Prompt rows (item 5)

50 rows in `prompts`, **`customized = 0` for every row**, and every id that still exists in `internal/prompts/defaults.go:103+` (`DefaultVersions`) has `prompts.version` equal to the code version (briefing.daily 7, day_plan.generate 4, meeting.prep 5, digest.channel 5, digest.channel_batch 4, inbox.compose 4, inbox.situation_card 2, inbox.triage 2, ideas.consolidate 4, memory.* 2/3, reactioncmd.command 1, catchup.compose 1, dictation.clean 1 …). Auto-upgrade (`internal/prompts/store.go:108-116`) is working; no stale customised prompt is holding back a version bump. Persona-merge wording bumps all landed.

## Needs owner decision

1. **F-2 recovery** — the vault now holds ~44 600 duplicate entity files committed to git history. Options: (a) rewrite/reset vault history to the last good commit (2026-08-01 `memory(map)`) and re-run seeding with namespaced-aware aliasing; (b) keep history, tombstone duplicates, `memory reindex`. MEM-02/MEM-07 adjacent; also decide whether pre-migration bare `U…`/`C…` aliases get a one-off `1:` backfill (the 00054 precedent) or the seeder learns both forms.
2. **F-1 fix shape** — normalise `r.ChannelID` with `slack.Namespace(accountID, …)`/both-forms lookup in `persistBatchResults`, or change the prompt example to the namespaced form; and whether the ~6 weeks of undigested Slack (since ~2026-08-03) should be backfilled or fast-forwarded (FEAT-03 spirit).
3. **F-7** — is "Inbox tab = strip only" (currently one dead Jira card) the intended owner experience while `inbox.situations.enabled` is false and reaction commands are off, or should `inbox_items` get a surface again / the situations gate be flipped on for this install?
4. **F-5** — reaping policy for `catchup_recaps` stuck in `building` (mark failed after N minutes? only from the CLI?). CATCHUP-adjacent.
5. **F-3** — confirm `GetInboxItems` should exclude archived rows globally (other callers: `internal/inbox` triage/auto-resolve paths use their own SQL, so the blast radius is the reactions sync and any Desktop/CLI listing through this helper).
6. **Log hygiene** — drop the duplicate `watchtower.log` write for the detached daemon, and add in-process rotation (currently documented as "unbounded by design", `cmd/sync.go:119-122`).
7. Whether to auto-disable (`features disable`) or at least badge the Jira-dependent features while `jira_accounts.status='revoked'` — today they burn nothing but also tell the owner nothing.

## What I could not verify

- **Why the three `catchup run` processes died** (F-5): the CLI logs to its own stderr, which the Desktop captures and does not persist; `sessions.log` has no `catchup.compose` entries after July. A crash/panic in `gather`/`runTopUp` on this DB is the leading hypothesis but unproven — reproducing would require running the CLI against the live DB, which the brief forbids.
- The exact first day F-1 started: `daemon.log.1` begins 2026-09-09; I dated it from the monthly `digests` counts and migration 00048's landing (`slack_token_1.json` mtime 2026-08-03 09:57), not from a log line.
- Whether the Desktop currently *renders* anything for the 36 ad-hoc recaps elsewhere (Recordings tab reads `summary_json` directly, so probably yes) — F-4 concerns the Dashboard feed only.
- Wall-clock split of the memory phase (reconcile vs seed): inferred from log timestamps (`inbox` finish → `memory error` ≈ 12–24 min), not instrumented.
- People-cards quality regression from stale `people_signals` — the cards are generated, whether they are now content-free I did not read (private data).
- I did not run any `go test`.
