# Silent-failures sweep — daemon, wiring, pipeline `Run` entries, AI generators, Desktop daemon lifecycle

Repo `/Users/user/PhpstormProjects/watchtower`, branch `feature/agent-actions`, HEAD 37179540. Read-only audit; every claim cites `file:line`. Scope per brief: `internal/daemon/`, `cmd/sync.go` wiring, the top-level error handling of each `Pipeline.Run`, the AI generator layer, and (lightly) the Desktop daemon/CLI wrappers. Two forked sub-auditors traced memory/ideas/reactioncmd and tracks/briefing/dayplan/catchup/guide/customtracks/targets/meeting/digest; their findings were cross-checked at the cited lines before inclusion.

Owner's live config (from the common brief): digest/calendar/gmail/jira/ideas/day_plan/memory(+semantic) enabled, `sync.poll_interval: 15m`, provider claude with `light: sonnet`/`strong: opus`. Keys absent fall to `internal/config/defaults.go`.

---

## 1. Feature status table

| Feature | Gate key + default | Entry points | Reachable from UI? | Verdict | Why |
|---|---|---|---|---|---|
| Daemon run loop | `sync.poll_interval` (15m), `sync.sync_on_wake` | `watchtower sync --daemon`, Desktop `DaemonManager.startDaemon` | yes (tray/status dot) | WORKS DIFFERENTLY | No timeout on any AI subprocess — one hung `claude` call freezes the whole cycle while the status dot stays green (F-04). No `recover` around phases — a pipeline panic kills the daemon (F-12). |
| Slack sync phase | orchestrators wired at start; `slack_accounts.enabled` | `phaseSlackSync` | yes (`last_sync.json`, Settings → Slack) | WORKS | Per-account fan-out, first error returned, pipelines still run (`daemon.go:412-432`). |
| Google Calendar / Gmail / CalDAV / IMAP sync | `calendar.enabled`/`gmail.enabled` (+ per-account flags) | `phase{Calendar,Gmail,CalDAV,Imap}Sync` | yes (Settings account status) | WORKS | Log-and-continue per account; auth state written by the syncers themselves (`daemon.go:439-494`). Minor: a token file that exists but fails to load leaves status untouched (F-19). |
| Jira sync | `jira.enabled`, `jira.sync_interval_mins` (15) | `phaseJiraSync` | yes | WORKS | Throttle stamped before the work (`daemon.go:528`) but in-memory and 15 min — Low (F-16). Revoked-grant surfacing is correct. |
| Channel digests | `digest.enabled` (true) | `phaseChannelDigests` → `RunChannelDigestsOnly` | yes (Digests tab) | **BROKEN (partial, silent)** | One global watermark = newest `period_to` of ANY channel; channels cut by the 25-batch cap, failed batches, or channels the model omitted lose that window forever, run reports `done` (F-01). |
| Daily / weekly rollups | `digest.enabled` | `phaseTracksAndRollups` → `RunRollups` | yes | WORKS DIFFERENTLY | Daily rollup regenerated every 15-min cycle with a strong-tier call, flipping unread (F-11). `RunWeeklyTrends` has no caller — weekly is UNREACHABLE (F-15). |
| Tracks (auto) | `tracks.enabled` && `digest.enabled` | `phaseTracksAndRollups` → `tracks.Run` | yes | WORKS DIFFERENTLY | All-batches-failed run returns `nil` → `pipeline_runs=done` → next run's `since` skips those digests permanently (F-03). |
| Custom tracks | `tracks.enabled` && `digest.enabled` | `phaseCustomTrackScan` | yes | WORKS | Per-track isolation; `SetTrackLastRun` only after success (`customtracks/pipeline.go:70-88,130-240`). |
| People cards | `people.enabled` && `digest.enabled`, 24 h throttle | `phasePeopleCards` | yes (People tab) | WORKS DIFFERENTLY | AI outage on a low-data batch writes `insufficient_data` cards that block the window for 24 h (F-10). |
| Inbox fast detection | `inbox.enabled` | `phaseFastInbox` → `RunFastDetection` | yes (Inbox tab strip / items) | WORKS | Never touches the watermark (`inbox/pipeline.go:508-519`). |
| Inbox full pipeline (detect+triage) | `inbox.enabled` | `phaseInbox` → `inbox.Run` | yes | WORKS DIFFERENTLY | INBOX-09 watermark math holds, but (a) no Slack account #1 ⇒ Run exits before any Gmail/Jira/Calendar detector runs, and the daemon's Google-email fallback is dead code (F-05); (b) a persistent detector error freezes the watermark forever while `pipeline_runs` shows `done` (F-07). |
| Situations compose / cards | `inbox.situations.enabled` (**false**) | inside `inbox.Run` | Dashboard view unreachable from nav (Wave 2) | DARK | `inbox/pipeline.go:288-290`; muted by design. |
| Stream digests (Gmail/Jira stage 1) | `streams.enabled` (true), `streams.interval_hours` (6) | `phaseStreamDigests` → `RunStreamDigests` | yes (Digests tab) | WORKS DIFFERENTLY | Floors advance past threads/issues the prompt-budget dropped — IDEA-01 drift (F-02). Throttle stamped on ctx-cancel too (F-09). |
| Ideas consolidator (stage 2) | `ideas.enabled` (true), 6 h | `phaseIdeas` → `ideas.Run` | yes (Ideas tab) | WORKS | Floors advance only inside the same tx as applied ops (`consolidate.go:624-629`); AI/parse failure returns before any write. Stage-1 drift above starves it. |
| Reaction commands | `reaction_commands.enabled` (**false**) | `phaseReactionCommands` | Settings → Slack dictionary only | DARK | Terminal `failed` ledger rows have no Desktop surface (F-17). |
| Memory consolidation | `memory.enabled` (true) | `phaseMemory` → `memory.Run` | Memory tab, briefing journal | WORKS | Watermark discipline holds (MEM-01/04); flock released by kernel. But a vault-open failure at wiring disables the phase with ONE startup log line and silent no-op every cycle after (F-08). |
| Next-step suggestions | `targets.next_step.enabled` | `phaseNextStep` | yes (target detail) | WORKS DIFFERENTLY | Only pipeline with an AI timeout; a target whose reply never parses is retried every cycle, `pipeline_runs` shows `done, 0` (F-14). |
| Daily briefing | `briefing.enabled`, `briefing.hour` (8) | `phaseBriefing` | yes | WORKS DIFFERENTLY | Retries a failing strong call every 15 min all day (F-14); empty `{}` reply persisted and dedups the day (F-12). |
| Day plan | `day_plan.enabled`, `day_plan.hour` (8) | `runDayPlanPhase` / `runDayPlanConflictPhase` | yes | WORKS | Row inserted only after a successful parse, so `existing == nil` retry works (`dayplan/pipeline.go:57-68,122-177`). |
| Catch-Up | on demand | CLI `catchup`, Desktop | yes | WORKS | `building → ready|failed` machine holds; all-refs-rejected recap becomes `ready` with an empty body (F-18, Low). |
| Feed publish | not gated (Core) | `phaseFeed` | yes | WORKS | Log-only, best-effort by contract (DASH-06). |
| Transcript audio cleanup / unsnooze / auto-mark-read | `transcripts.audio_retention_days` (30) | `phaseTranscriptAudioCleanup`, `phaseUnsnooze`, `autoMarkRead` | n/a | WORKS | Log-and-continue; remove-failure keeps `audio_path` for retry (`daemon.go:677-685`). |
| `pipeline_runs` tracking | — | `trackedPipelineRun` | Pipeline Progress window | WORKS DIFFERENTLY | `CreatePipelineRun`/`CompletePipelineRun` errors dropped (`daemon.go:392,401`); several phases record `done` on partial failure (F-01/03/07/14). |
| Claude generator (`digest.ClaudeGenerator`) | `ai.provider` | all daemon pipelines | — | WORKS | Non-zero exit, `is_error` on exit 0, empty result all surface as errors (`digest/generator.go:276-322`). No wall-clock timeout (F-04). |
| Codex generator | `ai.provider: codex` | same | — | WORKS | `parseJSONLOutput` surfaces `error` events and missing `agent_message` (`codex/generator.go:117-156`). No timeout. |
| Ollama generator | `ai.provider: ollama` | same | — | WORKS DIFFERENTLY | `http.Client{}` has no timeout; `finish_reason` not checked; returns `usage == nil` when the server omits usage → briefing dereferences it (F-12/F-21). |
| Chat client (`ai.Client.Query`) | — | Desktop chats, BoardAnalyzer | yes | WORKS DIFFERENTLY | Streaming path ignores the `result` event's `is_error`/`subtype`; `QuerySync` returns unparseable stdout as the answer (F-13). |
| Desktop daemon lifecycle | — | `DaemonManager` | tray/status dot | WORKS DIFFERENTLY | `restart()` ignores both exit codes; a slow stop + refused `--detach` leaves NO daemon running until next app launch (F-06). `CLIRunner` itself is sound. |

Counts: WORKS 12 · WORKS DIFFERENTLY 12 · BROKEN 1 · DARK 2 · UNREACHABLE 1 (weekly trends, folded into the rollups row) · LIMITATION 0.

---

## 2. Findings

### Critical

**F-01 — Channel digests: one global watermark; any channel whose batch is capped, fails, or is omitted by the model loses that window forever, and the run reports `done`.**
- `internal/digest/pipeline.go:444-452` — `since = lastDigestTime()` → `derivedLastDigestTime()` (`:1626-1631`) = `period_to` of the newest **channel digest of any channel** (`GetDigests` ordered `period_to DESC`, `internal/db/digests.go:115`). No per-channel digest state exists; `storeDigest` (`:1296-1341`) writes only the `digests` row.
- Per-channel failures do not hold the watermark back: an AI/parse error on a batch is `agg.recordError` + continue (`:893-897`), a channel the model left out of its batch reply is simply "not saved" (`persistBatchResults` `:934-980`), and `planChannelBatches` drops everything past `DefaultMaxBatchesPerRun = 25` (`:709-726`, `internal/config/defaults.go:60`) with the log word "deferred" although nothing re-queues them. The run returns `err == nil` unless **every** channel failed (`:788-791`), so `pipeline_runs` = `done` (`daemon.go:615-632`).
- **Intended:** CLAUDE.md "Digest pipeline" and every downstream contract (TRACKS-*, IDEA-01, CATCHUP-*) treat channel digests as incremental coverage of each channel's traffic.
- **Scenario:** first daemon start after onboarding, 30-day `initial_history_days`, 40 active channels → 30+ batches; 25 run, the 15 lowest-activity channels are "deferred". The surviving digests set `period_to ≈ now`, so next cycle `since ≈ now` and those channels' 30 days are never digested — and tracks, people cards, ideas stage 2 and Catch-Up all sit downstream of `digests`, so those channels are dark in every derived surface with no error anywhere. The same happens on any cycle where one batch hits a `claude` CLI error: that batch's window is skipped, not retried. This matches the owner's "many features don't work" symptom directly.
- Contract: not numbered, but it is the substrate of TRACKS-*/IDEA-01/CATCHUP-*. **Needs owner decision** (per-channel `since` from the channel's own latest digest is the obvious fix; alternatively freeze the global watermark when any batch failed or was capped).

### High

**F-02 — Ideas stage-1 floors advance past Gmail threads / Jira issues the prompt budget excluded (IDEA-01 drift).**
- Gmail: `internal/ideas/email_digest.go:248` lists up to 500 messages past the floor; `renderEmailBlock` (`:174-176`) `break`s on the first thread that does not fit `ideas.max_prompt_chars` (60000, `internal/config/defaults.go:42`) and excludes it from block AND tag set; `runEmailDigestAccount` then computes `maxTS` over **all** listed messages (`:285-293`) and writes `SetIdeasEmailFloor(acct.ID, maxTS)` (`:307`).
- Jira: identical — `renderJiraBlock` drops budget-excluded issues (`jira_digest.go:212`), `maxUpdated` spans all 300 listed issues (`:180-186`), `SetIdeasJiraFloor` (`:254`).
- **Intended:** `docs/inventory/ideas.md:21,25` — "floors advance only past the rows actually included"; CLAUDE.md `ideas.max_prompt_chars` says the same.
- **Scenario:** `streams.enabled` default on, busy Gmail: a 6 h window brings 500 messages across ~120 threads; at ~1.3 KB/thread the block holds ~45. Threads 46–120 are never digested — the floor jumps past them, the `stream_digests` row's `period_to = maxTS` claims coverage, so backfill's coverage-skip also treats the window as done. Silent permanent loss, no log line.
- Contract **IDEA-01** → **needs owner decision**.

**F-03 — Tracks: every batch may fail and the run still stamps a `done` watermark, permanently skipping those digests.**
- `internal/tracks/pipeline.go:326` `return totalStored, nil //nolint:nilerr` after `runTrackBatches` logged per-batch errors (`:601-604`). `phaseTracksAndRollups` records `pipeline_runs.status='done'` (`daemon.go:753-772`); next cycle `lastTracksStartedAt()` (`tracks/pipeline.go:175-190`, `internal/db/pipeline_runs.go:200-205` filters `status='done'`) only reads digests created after that failed run's `started_at`.
- **Scenario:** the `claude` CLI returns a rate-limit envelope for the 10 minutes a tracks run takes → 0 tracks, `pipeline_runs` green, digests created in that window are never fed to track extraction again. Owner sees "tracks stopped appearing for a day" with no red status. Undercuts TRACKS-06 from the undercount side.

**F-04 — No wall-clock timeout on any daemon AI subprocess; a hung `claude`/`codex` process freezes the whole cycle, holds `sync.lock`, and the status dot stays green.**
- `internal/digest/generator.go:226-276` (`exec.CommandContext` + `cmd.Output()`, ctx = daemon ctx cancelled only on shutdown), `internal/codex/generator.go:43-66`, `internal/ollama/generator.go:34,61` (`http.Client{}` no timeout). The only pipeline that bounds its call is targets (`internal/targets/pipeline.go:63`). grep over digest/inbox/memory/ideas/tracks/dayplan/briefing/reactioncmd/guide/customtracks: zero `WithTimeout`.
- `runSync` is strictly sequential (`daemon.go:311-369`); the process holds the `sync.lock` flock for its lifetime (`cmd/sync.go:272-280`), and a fresh ideas backfill-lock heartbeat keeps ticking (`internal/ideas/lock.go:58-87`) so even the CLI `ideas mine` is refused.
- **Scenario:** the `claude` CLI stalls on a network/auth hang inside `phaseChannelDigests` → no digests, no tracks, no inbox triage, no memory, no briefing, for hours or days; `daemon.log` shows nothing new; `isDaemonRunning` (`DaemonManager.swift:170-192`) says running because the pid is alive; `watchtower sync` says "another sync is already running". This is the same failure class as the known "sync stuck on reactions phase" incident (no HTTP timeout), one layer up.

**F-05 — Inbox `Run` exits before any detector when `slack_accounts` row #1 is absent; the daemon's Google-email fallback is dead code.**
- `internal/inbox/pipeline.go:381-388` — `resolveCurrentUserID()` → `p.currentUserID` or `db.GetCurrentUserID()` (`internal/db/workspace.go:44-54`, `SELECT current_user_id FROM slack_accounts WHERE id = 1`, `""` on no row) → `"" ⇒ "inbox: no current user set, skipping"`, `return 0,0,nil`. Same in `RunFastDetection` (`:496-501`).
- `daemon.applyInboxCurrentUser` (`daemon.go:1169-1197`) falls back to a Google account's email "so the Gmail/Calendar detectors can match", but calls `SetCurrentUser("", email)` (`inbox/pipeline.go:175-178`) — the id stays empty, so `Run` still bails; the email is never used.
- **Intended:** CLAUDE.md multi-account notes document `GetCurrentUserID` pinned to account #1 for *identity* purposes; nothing documents "no Slack ⇒ no inbox at all, Gmail/Jira/Calendar mentions included". `cmd/sync.go:243-244` explicitly promises the daemon runs Calendar/Gmail/Jira without Slack.
- **Scenario:** a Gmail+Jira-only install (or one whose Slack account #1 was never created) never gets a single inbox item, `pipeline_runs` shows `inbox done 0` every cycle, and the only trace is a log line. **Needs owner decision** (documented-identity decision vs. an unintended hard dependency).

**F-06 — `DaemonManager.restart()` ignores both exit codes; a slow stop followed by a refused `--detach` leaves NO daemon running until the next app launch.**
- `WatchtowerDesktop/Sources/WatchtowerCore/Services/DaemonManager.swift:112-124` — `_ = try await runProcess(["sync","stop"])`, then `_ = try await runProcess(["sync","--daemon","--detach"])`; only spawn failures are logged, non-zero exits are dropped and `isRunning`/`errorMessage` are not updated.
- `cmd/sync.go:147-176` — `sync stop` returns an error after 10 s if the pid is still alive; the daemon dies later anyway (SIGTERM delivered, but it is mid-AI-call: `cmd.Cancel` SIGINT + 5 s `WaitDelay` per subprocess, `digest/generator.go:237-240`). `cmd/sync.go:178-186` — `--detach` refuses with "daemon already running (PID N)" while the old pid is alive.
- 17 call sites: every account connect/remove (`GoogleAccountsViewModel.swift:119,179,231`, `SlackAccountsViewModel.swift:185`, `JiraAccountsViewModel.swift:192`, `EmailAccountsViewModel.swift:91,138,195`, `CalendarAccountsViewModel.swift:79,121,162`, `GoogleAuthService.swift:77`, `GoogleConnectFlow.swift:194`), every feature toggle (`FeaturesSettings.swift:61`, `FeatureSplashView.swift:379`). No respawn while the app runs — `ensureDaemonRunning` runs once at launch (`AppState.swift:603-612`).
- **Scenario:** owner connects Gmail while the daemon is inside a long `opus` digest batch → stop times out → `--detach` refused → old daemon exits ~5 s later → nothing syncs, nothing runs, until the app is relaunched. The tray dot turns grey (`StatusBarView.swift:17-19`), which is the only signal — and the owner just saw "connected" succeed. Because syncers are wired only at startup (`cmd/sync.go:527-539`), this is also the only path by which a newly connected source ever starts syncing.

### Medium

**F-07 — Inbox: a persistent detector error freezes the watermark forever while `pipeline_runs` shows `done`.**
- `internal/inbox/pipeline.go:401,449-453,464-468` — `detectErr` freezes the watermark (INBOX-09, correct) but is returned to the caller only when `triageErr` is also non-nil; `phaseInbox` (`daemon.go:836-851`) therefore records `done`. Triage still runs each cycle over the same frozen window (capped by `MaxTriageMessages`), re-triaging the oldest chunk forever while newer messages are never reached.
- **Scenario:** a schema drift or a bad `channel_id` predicate makes one detector query fail on every cycle → inbox silently stops advancing; Pipeline Progress shows green. INBOX-09 itself is honoured; the silent part is the status.

**F-08 — Memory phase silently no-ops for the daemon's lifetime after a vault-open failure.**
- `cmd/memory.go:165-175` — `OpenVault` failure logs once and leaves `memoryPipe` nil; `phaseMemory` (`daemon.go:1043-1045`) returns silently on nil every cycle (while the *disabled* branch logs every cycle, `:1039-1041`). No `pipeline_runs` row, no status surface.
- **Scenario:** a corrupt `.git` in `~/…/memory` (or a permissions change) → memory, briefing journal, disputes, reflection all stop; the only evidence is one line at the top of a 20 MB `daemon.log`.

**F-09 — `phaseIdeas` / `phaseStreamDigests` persist the throttle stamp on a context-cancelled run.**
- `daemon.go:914-930` and `:984-992` set `lastIdeas`/`lastStreams = now` and write `last_ideas.txt`/`last_streams.txt` whenever `Run` returned, including `ctx.Err()` at shutdown; `loadLastIdeas`/`loadLastStreams` (`:1241-1276`) restore it at next start. `phaseReactionCommands` (`:1027`) does the same in memory only.
- **Scenario:** quit the app while stage-1 is mid-run → restart → both phases wait up to 6 h even though nothing was consumed. The comment at `:923-928` justifies "advance on error", but shutdown is not an error.

**F-10 — People cards: an AI outage writes `insufficient_data` cards that then block the window for 24 h.**
- `internal/guide/pipeline.go:259-270` — low-data batch error → `createInsufficientCard` for every user in the batch; `:339-350` full-data batch error → per-user fallback. `RunForWindow` returns `nil`, so `phasePeopleCards` stamps `lastPeople` (`daemon.go:816-817`) and `GetPeopleCardsForWindow` (`guide/pipeline.go:169-177`) skips the window on any retry.
- **Scenario:** one 429 during the nightly run → half the People tab shows "insufficient data" for a day, `pipeline_runs` green.

**F-11 — Daily rollup regenerated with a strong-tier call on every 15-min cycle, resetting its unread state.**
- `internal/digest/pipeline.go:981-985` targets today; `runDailyRollupForDate` (`:988-1060`) has no "already exists" guard and calls `storeDigest` each time; the previous row is deleted only by `DeduplicateDailyDigests` at the start of the *next* channel-digest run (`:367`, `internal/db/digests.go:290-295`).
- **Scenario:** ~96 `opus` calls/day for one daily digest; the Digests tab's daily entry flips unread every cycle. Confirm intent ("living rollup") with the owner; the cost is real either way.

**F-12 — Briefing: empty `{}` reply persisted as today's briefing; nil `usage` dereference; no `recover` in `trackedPipelineRun`.**
- `internal/briefing/pipeline.go:641-659` accepts `{}`; `UpsertBriefing` (`:255`) then `GetBriefing` (`:132-139`) dedups the rest of the day. `:248` reads `usage.Model` without the nil check applied at `:228` — `ollama.Generator` returns `usage == nil` when the server omits usage (`ollama/generator.go:86-94`) → panic. `trackedPipelineRun` (`daemon.go:387-402`) has no `recover`, so any pipeline panic exits the daemon; `defer RemovePID` runs, the Desktop dot turns grey, nothing respawns until relaunch.
- Owner's install (claude) is safe from the panic; the `{}` case applies to all providers.

**F-13 — Chat client: streaming path ignores the `result` event's `is_error`; sync path returns unparseable stdout as the answer.**
- `internal/ai/client.go:236-290` — `result` events are only mined for `session_id` (`:248-250`), `extractText` skips them (`:369-371`); a `result` with `is_error:true, subtype:error_max_turns|rate_limit` and exit 0 (documented possible at `digest/generator.go:314-317`) ends the stream with no text and no error. On exit 1 `classifyError` (`:409-432`) sees an empty stderr (the message lives in the stdout envelope) → "claude CLI failed with exit code 1". `QuerySync` (`:319-323`) returns raw stdout as text on parse failure (`//nolint:nilerr`) — used by `BoardAnalyzer` via `newAIClient` (`cmd/sync.go:659-660`).
- **Scenario:** rate-limited chat turn → empty assistant bubble, no error; a board analysis gets a CLI banner stored as its "analysis".

**F-14 — Briefing / next-step retry a failing strong-tier call every cycle with no backoff or surfaced status.**
- Briefing: `daemon.go:1144-1151` stamps `lastBriefing` only on `id > 0` → gather + `briefing.daily` each 15 min until success (correct semantics, unbounded cost). Next-step: `internal/targets/nextstep.go:139-141` logs per target; `GetTargetsNeedingNextStep` (`internal/db/targets.go:167-168`) keys on `next_step_at < updated_at`, nothing marks an attempt → up to 50 strong calls per cycle for targets whose reply never parses; `pipeline_runs` reads `done, 0`.

**F-17 — Reaction commands: terminal `failed`/`skipped` ledger rows have no surface (feature DARK).**
- `internal/reactioncmd/pipeline.go:149-161,180` record `failed`/`skipped`; REACT-03 makes them permanent. No `agent_actions` row is created on these paths, and nothing under `WatchtowerDesktop/Sources` reads `reaction_commands`; only `watchtower reaction-commands list` shows them. Once enabled, a prose (non-JSON) compose reply burns the reaction forever with nothing visible. Transient compose/Propose errors correctly stay retriable (`:125-127,182-183,208-210`).

### Low

**F-15 — `RunWeeklyTrends` is UNREACHABLE.** `internal/digest/pipeline.go:1066` has no caller in `cmd/` or `internal/`; `RunRollups` (`:419-438`) runs only the daily rollup. Weekly digests promised by the digest reference never appear.

**F-16 — `phaseJiraSync` stamps `lastJira` before the work** (`daemon.go:528`); a failed pass suppresses retry for `jira.sync_interval_mins` (15). In-memory only; reset on restart.

**F-18 — Catch-Up recap whose refs are all rejected becomes `ready` with an empty body** (`internal/catchup/pipeline.go:138-140`); `RefsRejected` lives only in the result struct, not in `coverage_json`. Rows stranded in `building` by a killed process have no sweeper in this file (not verified elsewhere).

**F-19 — `wireGoogleSyncers`: a token file that exists but fails to `Load()` is skipped with a log line only** (`cmd/sync.go:698-702`), unlike the missing-file branch that writes `status='error'` (`:687-696`). Settings keeps showing "ok" for an account the daemon never syncs.

**F-20 — `trackedPipelineRun` drops `CreatePipelineRun`/`CompletePipelineRun` errors** (`daemon.go:392,401`) — Pipeline Progress can silently show nothing for a phase that ran. `FormatActiveTracksForPrompt` error swallowed (`:775`).

**F-21 — Ollama generator: no HTTP timeout, `finish_reason` (truncation) unchecked** (`internal/ollama/generator.go:34,72-84`); a truncated JSON is passed downstream and fails at the parser (surfaced there), so Low.

**F-22 — Reaction commands: `Propose` succeeded but ledger insert failed → duplicate proposal next poll** (`internal/reactioncmd/pipeline.go:128-130,172`). Transient-DB only.

**F-23 — Ideas backfill lock survives a crash for 2 h** (`internal/ideas/lock.go:58-87`, GB7-documented); the skip log line is throttled to once per 10 min (`daemon.go:896-903`). A hung AI call (F-04) keeps the heartbeat fresh indefinitely.

**F-24 — `phaseMemory` logs "memory: disabled, skipping" every cycle** (`daemon.go:1039-1041`) — log noise that drowns real lines; cosmetic.

---

## 3. Verified WORKS (traced, holds)

- **Inbox watermark (INBOX-09):** `decideWatermark` (`inbox/pipeline.go:346-363`) freezes on detector error, advances to `MaxProcessedTS` on triage error/cap, clamped never-backwards (`:473-479`). Compose/cards never touch it (`:287-301,437-441`).
- **Memory:** Slack watermark moves only after a batch commits (`memory/pipeline.go:796-801,832-842,1002-1027`); generator error, `parseExtract` failure, zero-ref/cross-channel episodes (`:1069-1076`) freeze it; Gmail per account (`gmail_extract.go:278-309,378-381`); Jira/Calendar mechanical ingest freezes on build/commit error (`jira_ingest.go:133-145`, `calendar_ingest.go:104-108`); flock released by the kernel on death, `defer unlock()` (`vault.go:258-274`, `pipeline.go:214`); `pipeline_runs` completed with the fatal error (`:669-672`).
- **Ideas consolidator:** floors advance only inside the same tx as applied ops (`consolidate.go:624-629`); AI error / no JSON / missing `ops` return before any write (`:142-159`); stage-1 AI failures return before `InsertStreamDigest` and floor writes (`email_digest.go:262-278`, `jira_digest.go:202-218`); per-account isolation (`email_digest.go:202-213`, `pipeline.go:135-144`).
- **Reaction commands:** one account's `reactions.list` failure does not abort the others (`reactioncmd/pipeline.go:79-89`).
- **Custom tracks, day plan, catch-up status machine, meeting recap** — see table rows; each returns before persisting on AI/parse failure.
- **Tracks parse path** (`tracks/pipeline.go:954-968`) treats generator/parse errors as errors — the silent part is only the `nil` at `:326`.
- **Digest all-failed case** (`digest/pipeline.go:788-791`) returns an error and writes no row, so the watermark cannot move in that one case.
- **`ClaudeGenerator.Generate`** surfaces non-zero exit with the envelope message, `is_error` on exit 0, and empty results (`digest/generator.go:276-322`).
- **Wiring fan-out** (`cmd/sync.go:552-811`): one account's missing token records its own status and never blocks the others; zero accounts is a clean no-op per source.
- **Desktop `ProcessCLIRunner`** (`CLIRunner.swift:53-108`): non-zero exit throws with stderr, stdout/stderr drained concurrently, cancellation terminates the child.
- **`runSync` ctx handling** (`daemon.go:322-328`): a cancelled ctx skips pipelines; a sync error does not.

---

## 4. Needs owner decision

1. **F-01** — per-channel digest watermark vs. freezing the global one on any capped/failed batch. Substrate for TRACKS-*/IDEA-01/CATCHUP-*.
2. **F-02** — IDEA-01: floor must follow the max ts among *rendered* threads/issues, or loop until the window is consumed.
3. **F-05** — is "no Slack account #1 ⇒ no inbox detection at all (Gmail/Jira/Calendar included)" the intended single-owner decision, or an unintended hard dependency? If intended, document it and delete the dead email fallback in `daemon.applyInboxCurrentUser`.
4. **F-11** — is the daily rollup meant to be regenerated every cycle?
5. **F-04** — a per-call AI timeout (e.g. 10–15 min) is a behaviour change for legitimately long strong-tier calls; pick the bound.
6. **F-06** — should `restart()` surface failure (errorMessage / retry `--detach` after the old pid exits) or should the daemon reload account wiring without a restart?

## 5. What I could not verify

- Live behaviour of the `claude` CLI on rate-limit / network stall (whether it ever hangs without exiting) — F-04 is a code-shape finding; the class is confirmed by the known reactions-phase incident, not by reproducing a hang here.
- Whether Catch-Up rows stranded in `building` are swept anywhere outside `internal/catchup/pipeline.go`.
- Whether the Desktop Pipeline Progress window distinguishes `done, 0 items` from "did nothing" (Swift side not traced beyond `DaemonManager`/`CLIRunner`).
- The runtime auditor owns the live DB/config; I did not confirm how many channels the owner's install actually has past the 25-batch cap.
- Digest fast-forward floor (`GetDigestFastForwardTS`, `digest/pipeline.go:1615-1623`) interaction with F-01 after a `features enable` — read but not traced end-to-end.
