# Core Slack pipelines — feature-state audit

Repo `/Users/user/PhpstormProjects/watchtower`, branch `feature/agent-actions` @ 37179540. Read-only; no builds, no binary runs, no tests executed. All paths below are relative to the repo root unless absolute.

Scope: Slack sync (`internal/sync`, `internal/slack`, `cmd/sync.go`), daemon phase order/gates (`internal/daemon/daemon.go`), digests (`internal/digest`), tracks + custom tracks (`internal/tracks`, `internal/customtracks`, `docs/inventory/tracks.md`), people cards (`internal/guide`), feed (`internal/feed`), Desktop surfaces (Digests / Tracks / People / Home / Search / Statistics / Usage), `internal/guide` + `last_guide.txt`, `digest.language` propagation.

Method note: the Slack-sync section was traced by a delegated read-only sub-auditor (its report is folded in verbatim where cited); I independently re-verified the two headline claims (search window math `internal/sync/search_sync.go:36-68`; reactions phase + HTTP client `internal/sync/orchestrator.go:358-400`, `internal/slack/client.go:19-24`). Everything else I traced myself.

---

## 1. Feature status table

| Feature | Gate key + default | Entry points (daemon / CLI / Desktop) | Reachable from UI? | Verdict | Why (one line) |
|---|---|---|---|---|---|
| Slack incremental sync (search path) | one `Orchestrator` per enabled `slack_accounts` row (`cmd/sync.go:552-579`); `sync.initial_history_days` default **2** (`internal/config/defaults.go:16`) | `phaseSlackSync` every cycle (`daemon.go:412`); `watchtower sync` | Status bar / Home banner read `workspace.synced_at` | **BROKEN** (data loss class) | With the default 2-day history the search window is a fixed sliding `after:<now-2d>` — the `search_last_date` watermark never widens it, so any daemon downtime ≥2 calendar days permanently loses messages (`search_sync.go:36-68`). |
| Slack sync — reactions phase | none (unconditional inside `Run`) | `syncInboxReactions` both sync paths (`orchestrator.go:219,266`) | n/a | **WORKS DIFFERENTLY / known symptom still real** | One `reactions.get` per unique pending inbox message, every cycle, no cap; Slack HTTP client has **no timeout** (`internal/slack/client.go:21`, `slack.New` default `http.Client{}`); a stalled socket blocks the whole daemon cycle before any pipeline. |
| Slack full sync (`--full` / fallback) | `SyncOptions.Full`, `--channels` | CLI, or automatic fallback when search page 1 fails | n/a | WORKS (with one Medium) | Per-channel cursor/`last_synced_ts` discipline is sound (`message_sync.go:337-390`); a fatal inline-thread error stalls that channel without recording the error (`message_sync.go:317-335`). |
| Daemon phase order + gates | per-phase config gates, `last_*.txt` markers | `runSync` (`daemon.go:311-369`) | n/a | WORKS (gates consistent) | Every phase gates on its own key before nil-checks/throttles; compound `Digest.Enabled` gates on tracks/people/custom-tracks are deliberate and documented in code. No inconsistent gate found. |
| Channel digests | `digest.enabled` (default true, `defaults.go:20`) | `phaseChannelDigests` every cycle (`daemon.go:608`); `watchtower digest`; Desktop Digests tab (`Navigation.swift:220`) | Yes | **WORKS DIFFERENTLY** | The digest watermark is **global** (MAX `period_to` across all channels, `pipeline.go:1627-1634`), so channels skipped by the 25-batch budget cap ("deferred", `pipeline.go:709-727`), the 30-min cooldown (`pipeline.go:646-672`) or a failed AI batch (`pipeline.go:893-897`) lose that window's messages from digests forever. |
| Daily rollup | `digest.enabled` | `phaseTracksAndRollups` → `RunRollups` every cycle (`daemon.go:783-787`) | Yes (Digests tab, type "daily") | **WORKS DIFFERENTLY** (cost) | Regenerated on **every 15-min cycle** with a strong-tier call (`digest.daily` → `TierStrong`, `models.go:17-24`) as soon as ≥2 channel digests exist for today UTC (`pipeline.go:993-1004`), upserting the same row; `read_at` is never reset, so content silently changes after being read. |
| Weekly rollup | — | `RunWeeklyTrends` has **no callers** (`pipeline.go:1066`; grep: only its definition) | Desktop has a "Weekly" label/colour (`DigestListView.swift:884,893`) that can never render | **UNREACHABLE** | Documented in `docs/daemon-pipeline.md:315-317` as Stage 10c, never wired. |
| Tier routing / StdinThreshold | `ai.models.light/strong` | `TierForSource` (`internal/digest/models.go:17`) | n/a | WORKS (one inconsistency) | Single source→tier table, generators read `SourceFromContext`; stdin hand-off shared by claude/codex (`generator.go:87,96`, `codex/generator.go:108`). Inconsistency: `digest.channel` (single high-activity channel) → strong, `digest.channel_batch` → light — a channel's digest quality depends on its batch shape, not its importance. |
| Tracks (auto) | `tracks.enabled` (default true) AND `digest.enabled` (`daemon.go:752`) | `phaseTracksAndRollups`; `watchtower tracks generate`; Desktop Tracks (root sidebar item) | Yes | **WORKS DIFFERENTLY** | Watermark = `started_at` of latest `status='done'` run (`tracks/pipeline.go:175-188`, `db/pipeline_runs.go:200-214`); `RunForWindow` returns `nil` even when every AI batch failed (`pipeline.go:326`, `runTrackBatches` `:600-605`) → the run lands `done` and those digests are never re-mined for tracks. Inventory preamble "one AI call per Run()" (`tracks.md:28`) is stale — it batches. |
| Custom tracks | same compound gate (`daemon.go:1118`) | `phaseCustomTrackScan` every cycle; `watchtower tracks create/watch/scan/events`; Desktop `CustomTrackManagementSheet` (`TracksListView.swift:31`, `TargetDetailView.swift:200`) + timeline in `TrackDetailView.swift:153` | Yes | WORKS | Per-track `last_run_at` watermark, cap-aware advance, insert-failure freeze, dedup by summary (`customtracks/pipeline.go:130-243`). Failure → retried next cycle (AI cost, not data loss). |
| People cards | `people.enabled` (default true) AND `digest.enabled` (`daemon.go:797`); 24 h throttle + `last_people.txt` | `phasePeopleCards`; `watchtower people generate`; Desktop People (`Navigation.swift:222`) | Yes | WORKS | 7-day rolling window keyed by exact `(period_from, period_to)` (`guide/pipeline.go:153-177`, `db/people_cards.go:113-116`); once per calendar day in practice; AI failure falls back to `insufficient_data` cards rather than losing the window. |
| `internal/guide` / `last_guide.txt` | — | `watchtower guide` is a deprecated alias of `people` (`cmd/guide.go:10-13`) | n/a | DOCUMENTED LIMITATION (stale file) | `last_guide.txt` is referenced by nothing in the tree (grep); the marker was renamed to `last_people.txt` in 108edbb8 (2026-03-29). The live file dated 2026-03-20 is an orphan — the pipeline is alive under the new name. |
| Feed (`feed_items`) | not gated (Core; `daemon.go:1069-1077`) | `phaseFeed` every cycle; `watchtower feed publish` | **No** — only consumer is `DashboardView` inside `InboxFeedView`, which nothing instantiates (`InboxFeedView.swift:45`; `Navigation.swift:203-204` routes `.inbox` to `ActionStripView`) | **UNREACHABLE** (consumer) | Publisher runs and writes every cycle; `DashboardViewModel` + `FeedViewModel` still `startObserving()` at launch (`AppState.swift:665-672`) for a view no navigation reaches. Physical removal is a documented deferred follow-up (CLAUDE.md Wave 2 §10). |
| Desktop Home (`WorkspaceOverviewView`, `ActivityFeed`, `SyncStatusBanner`, `StatsCard`) | — | none — `WorkspaceOverviewView(` is never constructed outside its own file (grep exit 1) | **No** | **UNREACHABLE** | Dead view family; `SyncStatusBanner` logic only survives via `StatusBarView`. |
| Desktop Search | — | `.search` in `toolItems` (`SidebarDestination.swift:92`) | Yes | **BROKEN** (deep links) | FTS query is fine (`SearchQueries.swift:26-32`), but "open in Slack" builds `slack://channel?team=…&id=<"1:C…">` with the namespaced id (`SearchViewModel.swift:24-27`) — see High-2. |
| Desktop Statistics / Usage | — | `.statistics` in INSIGHTS section, `.usage` in tools (`SidebarSection.swift:26`, `SidebarDestination.swift:92`) | Yes | WORKS (Statistics deep link also affected by High-2, `ChannelStatsViewModel.swift:180-183`) | Reads `channel_stats`/`pipeline_runs`. |
| Desktop Tracks / Digests / People deep links | — | `TracksViewModel.swift:285-295`, `DigestViewModel.swift:569-580`, `InboxViewModel.swift:359-363`, `WhoToPingView.swift:114-116` | Yes | **BROKEN** | Same namespaced-id bug as Search (High-2). |
| `digest.language` propagation | `digest.language` (default "Russian", `defaults.go:22`) | `prompts.Directive(cfg.Digest.Language)` | n/a | WORKS (two gaps) | Reaches digest/tracks/people/custom-tracks/inbox triage+compose+card/ideas/briefing/day-plan/meeting/memory/catch-up/targets/reaction-cmd (grep of `prompts.Directive` — 40+ call sites). Not applied to `inbox.style_sample` and `inbox.situation_learn` (`internal/inbox/style_sample.go`, `situation_learn`), and to `customtrack.shortlist` by design (ids-only output, `customtracks/pipeline.go:261-263`). |
| Dead config knobs | `digest.tracks_interval` (alias of `digest.action_items_interval`, `config.go:71,438,441`), `tracks.min_messages` (`config.go:155`) | accepted by `config set` (`cmd/config.go:224`) | n/a | UNREACHABLE (knob) | Nothing outside `internal/config` reads `TracksInterval` or `Tracks.MinMessages` (grep). |

Verdict counts: WORKS 7 · WORKS DIFFERENTLY 4 · BROKEN 3 · UNREACHABLE 5 · LIMITATION 1.

---

## 2. Findings

### Critical

**C-1. Slack search sync loses every message older than 2 days of downtime — the watermark is dead weight at the default config.**
- `internal/sync/search_sync.go:36-68`; `internal/config/defaults.go:16` (`DefaultInitialHistDays = 2`); `docs/daemon-pipeline.md:87-101` (intended: "back 2 days from the watermark, progressive catch-up").
- Intended: `search_last_date` per account is the resume point; the sync should cover the gap since the last completed run.
- Actual: `earliest = now - initial_history_days` (line 48) is applied as a hard floor; `candidate = lastDate - 2d` (line 58) is always ≤ `earliest` when `days == 2`, so `searchAfter == earliest` on every cycle regardless of the watermark. On completion the watermark jumps to today (`search_sync.go:203-207`). The `days = 30` fallback at line 38 is unreachable because config always supplies 2.
- Scenario: laptop closed Friday 18:00, opened Monday 09:00 (`sync_on_wake` fires). Query is `after:<Saturday>`; Saturday's messages never reach the DB; digests, tracks, inbox triage, memory episodes and catch-up for that day are all built without them. `watchtower sync --full` re-fetches the same 2-day window unless `--days` is passed. This is the mechanism behind the memory note "пропуск 03–15.08 не возвращён".
- Contract: no numbered contract, but it undercuts INBOX-09's watermark honesty and every downstream pipeline's "coverage" claims. **Needs owner decision** on the intended semantics (widen the window from the watermark vs. keep the sliding window and document it).

### High

**H-1. Reactions phase: "sync stuck on reactions" is still real — no HTTP timeout, no cap, blocks every pipeline.**
- `internal/slack/client.go:19-24` (`slack.New(token)` without `OptionHTTPClient`; vendored default `http.Client{}` has `Timeout: 0`); `internal/sync/orchestrator.go:358-433` (one `reactions.get` per unique pending `(channel, ts)`, `GetInboxItems{Status:"pending"}` with no limit, no "fetched recently" skip); `internal/daemon/daemon.go:312,419` (root ctx passed straight through, no deadline); `internal/slack/ratelimit.go:39` (40 req/min global limiter).
- Compare: Jira/Gmail/Calendar clients all set 30 s (`internal/jira/client.go:37`, `internal/gmail/client.go:37`, `internal/calendar/client.go:35`).
- Scenario: 200 pending inbox items ⇒ ≥5 min of Tier-3 calls per account per cycle, serialized before `phaseFastInbox`/digests (`daemon.go:312-333`). One stalled TCP connection (post-wake/VPN change) inside `GetReactionsContext` blocks `runSync` indefinitely: the ticker's next tick is dropped, the Desktop shows "Last sync: N hours ago" while the search phase already committed fresh messages. 429 handling itself is bounded (3 retries, `client.go:59-82`) — that part works.
- Contract: none. Fix is mechanical (client timeout + per-phase deadline + item cap); listed under owner decision only for the cap semantics.

**H-2. Every Desktop `slack://` deep link carries the namespaced channel id (`"1:C0123…"`) — "Open in Slack" is broken since migration 00048.**
- Builders: `WatchtowerDesktop/Sources/ViewModels/SearchViewModel.swift:24-27`, `TracksViewModel.swift:285-295`, `DigestViewModel.swift:569-580`, `ChannelStatsViewModel.swift:180-183`, `InboxViewModel.swift:359-363`, `DashboardViewModel.swift:336`, `WorkspaceOverviewViewModel.swift:42-44`, `Views/Components/WhoToPingView.swift:114-116` (user id). None calls `SlackAccountID.raw` (`WatchtowerCore/Utilities/SlackAccountID.swift:20-22`); the only Desktop users of `raw`/`split` are `ChannelStatsQueries.swift` (mention patterns) and `CatchUpViewModel.swift` (grep).
- Data source is namespaced: `SearchQueries.swift:26-32` selects `m.channel_id` (namespaced by 00048); `tracks.channel_ids` was backfilled by 00054; `digests.channel_id` likewise.
- Intended: the Slack multi-account design (`docs/superpowers/specs/2026-07-31-slack-multi-account-design.md:184-188`) says every renderer of a "cross-account-ambiguous value (permalink callers…)" must resolve the account and strip the prefix; the Go chat renderer does (`internal/ai/response_renderer.go` per CLAUDE.md). The Desktop VMs were classified "pure DB read paths, no change needed" and missed.
- Secondary: `team=` is taken from the frozen `workspace.id` snapshot of account #1 (`SearchViewModel.swift:19-21`), so even after stripping, a second account's links point at the wrong team.
- Scenario: owner clicks "#backend" on a track or a search hit → Slack opens with "channel not found" (id `1:C0123ABC`). Every Slack link from Search, Tracks, Digests, Statistics, Inbox items and Who-to-ping is affected.

**H-3. Channel-digest watermark is global; "deferred" and "cooldown-skipped" channels lose their messages from digests permanently.**
- `internal/digest/pipeline.go:1610-1634` (`lastDigestTime` = latest `period_to` over all channel digests), `:443-452` (`since` for every channel = that global value), `:709-727` (budget cap keeps 25 heaviest batches, logs "N channels deferred"), `:646-672` (cooldown drops a channel digested <30 min ago with `< digest.min_messages` visible), `:893-897` (a failed batch call drops all its channels), `db/digests.go:362-363` (`ChannelsWithNewMessages` is `ts_unix > since`).
- Intended (`docs/daemon-pipeline.md:185`, MAP phase): every channel's new messages are digested; "deferred" implies "next cycle".
- Actual: as soon as any other channel is digested this cycle, `since` advances to ≈ now, and the skipped channel's messages fall below the next window. There is no per-channel watermark and no re-queue.
- Scenario: a workspace with >25 batches of activity after a weekend: the lightest ~channels are "deferred" every cycle while busy channels keep pushing the watermark forward — those channels never get a digest for that window, and their topics never reach tracks, people cards, ideas or catch-up. Trickle channels (5–9 msgs / 15 min) hit the cooldown branch the same way. Also: a message inserted by sync with `ts` older than the current watermark (late Slack search indexing, the reason the search overlap exists) is never digested.
- Contract: none numbered; it silently violates the "the count must mean something" trust property the tracks inventory leans on (`docs/inventory/tracks.md:30-40`).

**H-4. Daily rollup is regenerated with a strong-tier call on every 15-minute cycle.**
- `internal/daemon/daemon.go:783-787` (`RunRollups` every cycle, no throttle), `internal/digest/pipeline.go:981-1004` (only gate: ≥2 channel digests today UTC), `:1046` (`digest.daily`), `internal/digest/models.go:17-24` (`digest.daily` ∉ light list ⇒ strong = `opus` on the owner's config), `db/digests.go:15-31` (upsert by `(channel_id,type,period_from,period_to)`, resets `created_at`, leaves `read_at`), `db/channels.go:316-334` (auto-mark-read sets `read_at` once).
- Intended (`docs/daemon-pipeline.md:311-313`): "Aggregates all channel digests for the day" — no statement that it re-runs every cycle; stage list treats it as a rollup, not a live view.
- Actual: up to 96 strong-tier calls/day for one row; after `read_at` is set (by the owner or by `AutoMarkReadFromSlack`) the row's text keeps changing with no unread signal.
- Scenario: owner reads the daily digest at 10:00; by 18:00 it has been rewritten ~32 times; badge never flips; token spend on the strongest model is the largest single recurring cost in the daemon for an active workspace. **Needs owner decision**: live-updating daily (then it should at least be gated on "new channel digests since last rollup" and probably light tier) vs. once-per-day.

**H-5. Tracks watermark advances past digests whose extraction failed.**
- `internal/tracks/pipeline.go:580-610` (`runTrackBatches` logs per-batch errors and continues), `:326` (`RunForWindow` returns `nil` — "partial results returned"), `:264-265` (`Run` propagates that nil), `internal/daemon/daemon.go:753-772` (`trackedPipelineRun` ⇒ `CompletePipelineRun(..., errMsg="")` ⇒ `status='done'`), `db/pipeline_runs.go:62-66,200-214` (next run's `started_at` floor = latest `done` run), `:247-249` (`GetDigestsCreatedAfter(sinceISO)`).
- Also on `ctx` cancellation: `runTrackBatches` breaks at `:583-584`, still returns nil ⇒ `done` row.
- Intended: TRACKS-01/02 framing — digests are the input; a failed cycle should retry, not skip.
- Scenario: the AI CLI errors (rate limit, expired auth) for one cycle; every channel digest created in that window is permanently invisible to track extraction; the situation it described never becomes a track, and no error reaches `pipeline_runs`.
- Contract-adjacent: not a numbered TRACKS-NN contract, but drift from the inventory preamble's description of the pipeline (`docs/inventory/tracks.md:19-28`, which also still says "one AI call per Run()"). **Needs owner decision** only on the doc side; the code fix (return an error when `errCount>0 && stored==0`, the digest pipeline's own `dispatchChannelBatches` rule at `pipeline.go:791-793`) is mechanical.

### Medium

**M-1. AI generator calls have no deadline; a hung `claude`/`codex` subprocess freezes the daemon.**
- `internal/digest/generator.go:226-276` (`exec.CommandContext(ctx …)` with the daemon's root ctx; `cmd.Output()` blocks), same shape in `internal/codex/generator.go`; `internal/daemon/daemon.go:311-369` (synchronous `runSync`; a blocked phase blocks all later phases and drops ticker ticks).
- Scenario: one stuck CLI call in `phaseChannelDigests` (network stall on the API side) ⇒ no inbox, tracks, memory, briefing or day plan until the process is restarted; the Desktop keeps "daemon running".

**M-2. `synced_at` is written only after a fully clean run, so the UI shows "stale" over a fresh DB (and cumulative `last_sync.json`).**
- `internal/sync/orchestrator.go:257-259,441-461` (`TouchSyncedAt` only in `finishSync`, skipped when `users.list` fails); readers `WatchtowerDesktop/Sources/Views/StatusBarView.swift:85`, `Views/Home/SyncStatusBanner.swift:19-25`; `internal/sync/progress.go:79-85,165-169` (no reset; orchestrators reused across cycles `daemon.go:418-425`) ⇒ `last_sync.json` `started_at`/`duration`/`messages_fetched` are since daemon start (`result.go:36-54`). Self-heals next cycle; misleading meanwhile.

**M-3. Full-sync path: a fatal inline-thread error stalls a channel without recording it and cancels the pool.**
- `internal/sync/message_sync.go:317-335` (returns before `UpdateSyncState` at `:353`, no `saveSyncError`), `internal/sync/worker.go:60-63` (first fatal error cancels remaining channels). Only on `--full`, `--channels`, or the search→full fallback (tokens lacking `search:read` hit it every cycle, `orchestrator.go:231-234`).

**M-4. Reactions and deletions never propagate; edits only inside the 2-day window.**
- `db/reactions.go:15` (`INSERT OR IGNORE`, no delete path), `search_sync.go:170-171` (`IsEdited/IsDeleted=false` hardcoded), `db/messages.go:63` (edit picked up only when the message re-appears in the search window). A removed 👀 stays in `reactions` forever and keeps feeding reaction consumers.

**M-5. Feed publisher + two ViewModels do work for a view nothing can reach.**
- `daemon.go:1077-1088` publishes `feed_items` every cycle; `AppState.swift:665-672` starts DB observation on `DashboardViewModel` and `FeedViewModel`; the sole consumer `DashboardView` is mounted only by `InboxFeedView.swift:45`, which no navigation constructs (`Navigation.swift:203-204`). Documented as deferred removal (CLAUDE.md Wave 2 §10) — listed so the owner knows the Dashboard timeline they may remember is gone from the UI, not broken.

**M-6. Tier routing inconsistency inside the digest MAP phase.**
- `internal/digest/models.go:19` routes `digest.channel_batch` to light but leaves `digest.channel` (single-channel prompt used for >200-message channels, `pipeline.go:690-702,769-773`) on strong, and `digest.daily`/`digest.weekly` on strong while `digest.period` is light. Combined with H-4 this is where the strong-tier spend concentrates. Owner call whether high-activity channels deserve strong.

### Low

**L-1. Weekly rollup is dead code with a live UI label.** `RunWeeklyTrends` (`internal/digest/pipeline.go:1066`) has no callers; `DigestListView.swift:884,893` and `AutoMarkReadFromSlack` (`db/channels.go:322`) still handle `type='weekly'`; `docs/daemon-pipeline.md:315-317` documents it as running.

**L-2. Home view family is dead.** `WorkspaceOverviewView`/`ActivityFeed`/`StatsCard`/`WorkspaceOverviewViewModel` are never instantiated (grep). `SidebarDestination` has no `.home` case (`SidebarDestination.swift:3-24`).

**L-3. Dead config knobs.** `digest.tracks_interval`/`digest.action_items_interval` (`config.go:71,438,441`, `defaults.go:24`) and `tracks.min_messages` (`config.go:155`) are parsed, settable via `config set` (`cmd/config.go:224`) and read by nothing.

**L-4. `last_guide.txt` orphan.** No code references it; the marker became `last_people.txt` in 108edbb8 (2026-03-29). The 2026-03-20 file on the live install is stale, not evidence of a dead pipeline — people cards run under `phasePeopleCards` (`daemon.go:796-822`).

**L-5. Language directive gaps.** `inbox.style_sample` and `inbox.situation_learn` prompts carry no `prompts.Directive` (grep of `internal/inbox/`: only `compose.go:126`, `situation_card.go:52`, `triage.go:295`). Probably intentional for the style profile (it describes the owner's own languages) — flagging for completeness since the brief asked "does `digest.language` reach every prompt".

**L-6. Small sync-side account-scoping leaks (full-sync path only).** `GetIncompleteUserIDs` unscoped ⇒ `users.info` with the wrong account's token (`user_sync.go:18,46`, `db/users.go:147-158`); `GetStats().ChannelCount` fallback check unscoped (`orchestrator.go:241-248`); `custom_emojis` unnamespaced, last account wins (`orchestrator.go:642-651`).

**L-7. `tracks` pipeline_runs row every cycle even with zero digests** (`daemon.go:753`, `tracks/pipeline.go:285-289` returns before any AI call) — inflates the Usage tab's run list; cosmetic. Daemon log always prints `updated 0` because `Run` returns `(stored, 0, err)` (`pipeline.go:265`).

**L-8. Doc drift.** `docs/daemon-pipeline.md:99,103` describe a 200-page search cap and progressive watermark advance that do not exist in `search_sync.go`; `:143` says `users.info` for new users, but the search path runs a full `users.list` each cycle (`orchestrator.go:253-259`); `docs/inventory/tracks.md:28` "one AI call per Run()" vs batching at `tracks/pipeline.go:568-610`; `daemon.go:606-607` says channel digests "produce people_signals", but `storeDigest` always writes `PeopleSignals: "[]"` (`pipeline.go:1329`) and people cards read `digests.situations` (`db/people_cards.go:421-425`).

---

## 3. Inventory contract check (`docs/inventory/tracks.md`)

| Contract | Status in code | Note |
|---|---|---|
| TRACKS-01 one situation, one track | HOLDS (mechanism present: `existing_id` update, fingerprint `matchCustomTrack`/`findSimilarTrack` `pipeline.go:1587-1665`, `source_refs` dedup) | Not re-verified against prompt drift — out of scope for static reading. |
| TRACKS-02 silent channels stay silent | HOLDS (`scoreChannel` `pipeline.go:1457`, `filterEntriesByRelevance` `:520`) | — |
| TRACKS-03 watching lane narrow | HOLDS (`shouldDropTrack` `:1711`) | Still "Partial" per inventory (no unit test). |
| TRACKS-04 read once | HOLDS at DB layer; **note** `AutoMarkReadFromSlack` (`db/channels.go:349-353`) marks tracks read from Slack cursors — the inventory's "read = user opened the track" wording does not mention this path. Not a drift in code, a doc gap. |
| TRACKS-05 owner gate | HOLDS by inspection (`storeTrackItems`). | Still "Partial". |
| TRACKS-06 no narrowing | HOLDS (`track_states`, `UpdateTrackFromExtraction` merge). | — |
| TRACKS-07 dismiss final | HOLDS (`dismissed_at`, `GetAllActiveTracks`). Schema confirms no `done/resolved/archived` on `tracks` (`schema.sql:298-336`); custom tracks add `origin/instruction/enabled/last_run_at` (`:331-334`), not a status. | — |

No TRACKS-NN drift found in code. H-5 is contract-adjacent (input completeness) and flagged for owner.

---

## 4. Needs owner decision

1. **C-1 semantics** — should the search window widen from `search_last_date` (true catch-up, bounded by some max) or stay a fixed sliding `initial_history_days` window? Today the second is what runs, and it silently loses data on any ≥2-day gap. If the second is intended, onboarding/docs must say so and `--full --days N` becomes the documented recovery path.
2. **H-4 daily rollup cadence** — live-updating "today" digest (then: gate on new channel digests + reconsider tier + surface change) vs. once-per-day rollup.
3. **H-3 per-channel digest watermark** — accept "deferred = dropped" as a budget trade-off (document it) or introduce a per-channel `since`. Affects TRACKS-01/02 trust properties indirectly.
4. **H-5** — should a tracks run with ≥1 failed batch and 0 stored count be recorded as `error` (freezing the watermark, the digest pipeline's own rule)? Inventory preamble update either way.
5. **M-6** tier choice for `digest.channel` (high-activity single channels) and `digest.daily`.
6. **M-5 / L-1 / L-2 / L-3** — dead code removal wave (feed consumer, weekly rollup, Home views, two config knobs) is already a deferred spec item; confirm scope.
7. **H-1 cap semantics** — bound the reactions phase per cycle (N most recent pending items) and/or run it after pipelines instead of before.

---

## 5. What I could not verify

- Live DB state (pending inbox count driving H-1's duration; whether the owner's `sync.initial_history_days` is set higher than 2 — C-1 severity depends on it; how many channels actually hit the 25-batch cap in H-3). Brief forbids reading the live install from this role.
- Slack API behaviour offline: whether `search.messages` rejects `page > 100` (would make the uncapped loop at `search_sync.go:80-197` a permanent stall for >10k-message windows) and the exact exclusivity of `after:YYYY-MM-DD`.
- Whether Slack's `slack://channel?id=` might tolerate a `"1:"` prefix (assumed not — the id is opaque and must match a channel id).
- TRACKS-01 prompt-drift behaviour (needs a live run, not static reading).
- Tests were not executed; no `go test` runs were needed for the claims above.
