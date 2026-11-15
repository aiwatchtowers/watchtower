# Slack Full — Adaptive Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every Slack account keeps today's sync of everything the user can see, made robust and economical: a retry chain that pushes through rate limits without losing fetched work, a self-balancing request rate, a cadence that adapts to 429s and data volume, mentions first, and a per-channel **Stop syncing** with suggestions of junk channels.

**Architecture:** The forward sync stays one blanket `search.messages after:D` per Slack run (`internal/sync/search_sync.go`). Four additions:
- The account's limiter (`internal/slack/ratelimit.go`) becomes adaptive: it halves its rate on a 429 and creeps back after successes (AIMD). `doRequest` keeps retrying 429s after their `Retry-After` until the run's fetch deadline.
- The search remembers its page position, so a run cut by the deadline, a sleep or a quit continues from that page.
- A small mention query runs first.
- The daemon decides per account whether a Slack run is due (adaptive cadence).

A new `channel_settings.sync_excluded` flag drops a channel's new messages at save time (mentions of the user excepted). Statistics' existing recommendations gain a **Stop syncing** suggestion. Slack inbox detection becomes ingestion-ordered (`messages.synced_at`), so a message stored after the Inbox watermark passed its timestamp is still detected.

**Tech Stack:** Go 1.26 (`golang.org/x/time/rate`, slack-go plus the client's raw `postAPI`, goose SQL migrations on the in-repo SQLCipher driver), SwiftUI + GRDB (Statistics), `testing/synctest` for every timing test.

**Spec:** `docs/superpowers/specs/2026-11-14-slack-full-and-live-design.md` — §2 as amended on this branch (D16, ask #1337, superseding D3 and D12), §7 "Sync" rows, §8 (`channel_settings.sync_excluded`, `messages.synced_at`), §9 rows for T4. Owner's words (ask #1337): keep the method as it is, add a retry chain and a self-balancing mechanism that packs as many requests as possible, make the cadence adaptive to data volume and 429s, sync everything with a "what I don't need" setting and suggestions not to sync junk, building on the groundwork already there; contracts BACKFILL-01, SRCDEL-01/02 and INBOX-09 extensions approved; decisions 2–10 accepted where still relevant.

**Groundwork this builds on.**
- `channel_settings` (`is_muted_for_llm`, `is_favorite`; `internal/db/channel_settings.go`).
- `db.ComputeRecommendations` (mute / leave / favorite, with value signals; `internal/db/channel_stats.go`) and its Swift mirror `ChannelStatsQueries.computeRecommendations`.
- The Statistics → Channels screen (`ChannelStatisticsView`, `ChannelStatsViewModel.applyRecommendation`: "leave" applies as mute).
- `watchtower channels` (`cmd/channels.go`).
- The limiter's account-wide `Retry-After` hold.
- The search watermark, the 2-day overlap and the catch-up cap.
- INBOX-09's freeze on `SearchIncomplete`.

## Global Constraints

- Every Slack account, same behaviour. There is no corp/public split (ask #1337: "corp will not exist").
- The search watermark (`search_last_date`) moves only when the whole window was read (today's rule). Resuming never skips a page.
- 429: wait `Retry-After` (+ jitter, today's `HandleRateLimit`), retry with no fixed count until the run's fetch deadline `slackFetchDeadline = 10 * time.Minute` (and never past the cycle's ctx). Every later call of that account waits for the same hold.
- AIMD rate per account client: start `aimdStart = 40/min` (today's rate), ceiling `aimdMax = 40/min`, floor `aimdMin = 4/min`. On each 429: rate × 0.5, not below the floor. After `aimdStepEvery = 20` consecutive successes: +2/min, not above the ceiling. Burst 3 and the concurrency gate stay as today.
- Largest allowed page sizes: `search.messages` `count=100` (Slack's maximum, as today), `conversations.history`/`conversations.replies` `limit=999`, `users.list` and `conversations.list` `limit=1000`.
- Priority: the mention query `<@U…> after:D` runs before the blanket query in every Slack run.
- Cadence per account: base = `sync.poll_interval` (default 15 min), next interval = base × 2^k, capped at `cadenceMax = 60 * time.Minute`. k increases by 1 after a run that saw a 429. A clean run halves the interval back toward base. A run that stopped at the deadline with pages left is due again next cycle. **Sync Now always runs Slack** (manual triggers are never gated, today's rule).
- Inbox: Slack detectors compare the watermark with `messages.synced_at`, stamped as `clock()` when `ts ≥ max(slack_accounts.first_cycle_at, runStart − 24 h)`, else `ts_unix`. Backfill writes `ts_unix`. A trigger fills any other insert.
- Migrations: two (Task 4 and Task 5), via the `add-migration` skill; next free numbers at implementation time (00189 when this plan was written); mirror into `schema.sql`, the golden and the Swift test schema.
- No guard test is weakened or edited. Existing tests keep passing as they are. A fixture that breaks means stop and ask.
- Tests never wait on wall-clock time: injected clocks and `testing/synctest` (fake `http.RoundTripper` inside the bubble, no sockets). No test spawns a process.
- Fixtures use fake ids (`T000`, `U0OWNER`, `C0JUNK`, `D0DM`); any that trips the leak-check carries `leak-check:allow`.
- Inner loop per task: `go test ./internal/<pkg>`, `make lint-diff`; Swift tasks `make test-swift FILTER=…` and `make lint-swift`. The controller runs the full gate once at the end.

## Capacity — how adaptive packing behaves as a workspace grows

Cost per person per hour ≈ R + V/100. R is Slack runs per hour (60 / cadence). V is the public messages per hour the blanket search sees in the workspace, the same for everyone. If the quota is shared per workspace × app, `search.messages` gives about 1,200 calls/h.

| People | Need at 15 min (V = 833/h, i.e. 20k/day) | What adaptation does |
|---|---|---|
| ≤ ~95 | 4 + 8.3 ≈ 12/h each, fits | Nothing: base cadence, no 429s |
| ~95–145 | above the quota at 15 min | 429s → AIMD halves the rates and cadences back off toward 60 min; 1 + 8.3 ≈ 9.3/h each fits up to ≈ 129 people at 60 min; mentions stay first, so the Inbox stays fresh while the blanket search lags |
| > ~145 | the volume term alone (8.3/h) exceeds the share | The blanket search cannot keep up. Each run resumes where the last one stopped, so nothing is lost, but the lag grows. Only mentions (≈ 1–2 calls/h) stay current |

The ceiling is ≈ 1,200 / (V/100), whatever the cadence. Excluding channels does not lower V, because the blanket search still returns their messages and they are dropped at save; it saves storage and AI work only. If the spike shows that `-in:#channel` works for a short list, excluded channels can also come out of the query, which lowers V (spike follow-up, not a task). If the quota turns out to be per user token, every row fits and adaptation only smooths out bursts.

## Review Focus

1. **A 429 storm in the middle of a 40-page window**: no page is fetched twice within a run, the run resumes from the page it stopped on, the watermark stays until the last page, and the Inbox freezes (INBOX-09) — Task 2 `TestSearchResume_ContinuesFromPage`, Task 1 `TestAdaptive_RetryChainPushesThrough`.
2. **A long `Retry-After` wait looks like a stall**: Sync Now's 60-second stall restart must not kill a fetch that is only waiting for a hold — Task 1 `TestHeartbeat_ReportsRateLimitWait` (the heartbeat moves while waiting).
3. **A message stored by a run that came 45 minutes late** (cadence backed off): it is detected — Task 4 `TestInbox_LateStoredMessageDetected`.
4. **Excluding a channel the user is mentioned in**: the mention still arrives in the Inbox; ordinary messages do not — Task 5 `TestSyncExcluded_MentionStillStored`.
5. **A first sync or a new account row**: no flood of old mentions into the Inbox — Task 4 `TestInbox_FirstSyncDoesNotFloodInbox`.

---

## Decisions made by the agent (for one owner ask)

1. **Keep ingestion-ordered inbox detection** (`messages.synced_at`; INBOX-09 extension already approved). Adaptive cadence skips Slack in some cycles while the shared Inbox watermark keeps moving, and resumed pages store messages after the watermark passed their timestamps. The alternative is to freeze the watermark whenever an account's Slack run is skipped. That needs no migration, but it holds detection for every source for up to 60 minutes and does not fix search's indexing lag, which already loses late-indexed messages today. Recommended: `synced_at`.
2. **Resume position and the learned rate live in memory** on the orchestrator and the client. A restart re-reads the window (idempotent upserts) and starts at 40/min, relearning from the first 429s. Recommended: in memory; persisting them needs another migration for little gain.
3. **Mentions in an excluded channel are still stored.** Recommended: yes (attention beats the exclusion). Alternative: exclusion drops everything.
4. **Data already stored in a channel the user excludes stays.** It stops being digested only if it is also muted, which the **Stop syncing** button does in the same write. Recommended: keep it and mute it; a purge would be a new deletion path.
5. **The Stop syncing suggestion rule**: a channel muted for AI for 30+ days with no message from the user and no mention of the user in that time, or one with ≥ 90% bot messages and no value signals. Recommended as written; it reuses the mute rule's inputs.
6. **The fetch deadline is 10 minutes per Slack run per account.** The rest of the cycle (pipelines) must not wait behind a rate-limited account.
7. **An excluded channel reads `channel_in_scope: false`** in the chat's `coverage`, so the chat uses Live for it (plan A's rule extended).

## Contract changes needing owner approval

- **INBOX-09** — approved (ask #1337): Slack detectors compare the watermark with `synced_at`. Its guards stay untouched: a trigger stamps every other insert with the insert time, so existing fixtures behave as before.
- **New, needs approval: SYNCEX-01 — Stop syncing is honoured on every save path.** A channel with `sync_excluded = 1` gets no new message rows from the forward search, the deletion sweep, the history backfill or `sync --full/--channels`, except messages mentioning the account's user. Guard `TestSYNCEX01_EveryPathHonoursExclusion` (Task 5). A new inventory file entry in Task 7.
- BACKFILL-01 and SRCDEL-01/02 — approved, but this plan no longer needs them (the blanket search, the first-sync rule and the live diff stay as they are).
- Spec: §2 is replaced by D16 (this branch); D3 and D12 are marked superseded.

## Writers of the same data

| Data | Writers | Who wins a race |
|---|---|---|
| `channel_settings.sync_excluded` | Desktop Statistics (toggle, applied suggestion), `watchtower channels exclude/include` | Last write wins; the sync reads the set once at the start of each run, so a change applies from the next run |
| `channel_settings.is_muted_for_llm` | as today, plus **Stop syncing** setting it in the same write | Last write wins |
| `messages` rows | forward search (filtered by exclusion), the sweep, backfill, `sync --full/--channels` | Upserts of Slack content; SQLite serialises them |
| `messages.synced_at` | the first insert only: the sync's `stampSyncedAt`; backfill `ts_unix`; the trigger for everyone else | Insert-only; never updated |
| `slack_accounts.first_cycle_at` | the orchestrator once (`WHERE first_cycle_at = ''`); the migration for existing rows | First write wins |
| `slack_accounts.search_last_date` | the forward search only, after a complete window | Single writer |
| resume position, AIMD rate, cadence level | in memory on the orchestrator/client/daemon | One daemon; a restart starts fresh |

---

### Task 1: Retry chain and the adaptive rate (client)

**Depends on:** none

**Files:**
- Modify: `internal/slack/ratelimit.go`, `internal/slack/client.go` (`doRequest`, page sizes in `GetUsers`, `GetChannels`, `GetConversationHistory`, `GetConversationReplies`)
- Modify: `internal/sync/heartbeat.go` (expose the hold), `internal/daemon/cycle.go` only if the stall check needs the new field
- Test: `internal/slack/ratelimit_test.go`, `internal/slack/client_test.go`, `internal/sync/heartbeat_test.go`, `internal/daemon/` (stall test)

**Interfaces:**
- Produces:
  - `func (rl *RateLimiter) Rate() float64` (calls per minute now); AIMD as in Global Constraints, applied in `HandleRateLimit` (decrease) and `Done` (success count, increase).
  - `func (c *Client) SetDeadline(t time.Time)` — `doRequest` retries a 429 after its hold for as long as the hold ends before `t` (zero = today's 3-retry cap). Past it, it returns `ErrFetchDeadline` wrapping the `*slack.RateLimitedError`, so `isRateLimitError` still holds.
  - `func (c *Client) HoldUntil() time.Time` — the current `Retry-After` hold (zero when none). The sync heartbeat reports it and `Snapshot` carries `RateLimitedUntil time.Time`; the daemon's stall check counts a run waiting on a hold as progressing.
- [ ] **Step 1: Write the failing tests** (`synctest`):
  - `TestAIMD_HalvesOnRateLimitAndRecovers`: 40 → 20 → 10 on two 429s; +2/min after each 20 successes; never below 4 nor above 40.
  - `TestAdaptive_RetryChainPushesThrough`: five 429s with `Retry-After: 30` then 200, deadline 10 min. One call succeeds after 150 s of bubble time; no error.
  - `TestAdaptive_DeadlineStopsChain`: holds summing past the deadline → `ErrFetchDeadline`, `errors.As(*slack.RateLimitedError)`.
  - `TestDoRequest_NoDeadlineKeepsThreeRetries` (today's behaviour without `SetDeadline`).
  - `TestPageSizes_Max`: the request forms carry `limit=999` / `limit=1000` / `count=100`.
  - `TestHeartbeat_ReportsRateLimitWait` and `internal/daemon::TestManualTrigger_DoesNotRestartWhileRateLimited`.
- [ ] **Step 2: Run** `go test ./internal/slack -run 'TestAIMD_|TestAdaptive_|TestDoRequest_No|TestPageSizes_'` — FAIL.
- [ ] **Step 3: Implement** (`rate.Limiter.SetLimit` for the AIMD changes).
- [ ] **Step 4: Run** `go test ./internal/slack ./internal/sync ./internal/daemon` — PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(slack): retry chain through rate limits and an AIMD request rate (#1709)`.

### Task 2: Resumable search and mentions first

**Depends on:** Task 1

**Files:**
- Modify: `internal/sync/search_sync.go` (`syncViaSearch`, `searchAndSave`), `internal/sync/orchestrator.go` (`Run`: `SetDeadline(runStart + slackFetchDeadline)`; the run's outcome)
- Test: `internal/sync/search_resume_test.go`; existing `search_sync_test.go`, `search_sync_ratelimit_test.go`, `search_backfill_test.go` untouched

**Interfaces:**
- Produces:
  - `type searchResume struct { query string; nextPage int }` on the orchestrator (`o.resume`). After a run stops on `ErrFetchDeadline`, a rate limit or a cancel with pages left, it holds the blanket query and the first page not fetched. The next run with the **same** query starts at that page and keeps the listing for the deletion diff only when every page of the window was read in this run (otherwise no diff, as today). A different query (the date moved) drops it.
  - The mention query `fmt.Sprintf("<@%s> after:%s", ownerRaw, after)` runs first through `searchAndSave(live=true, listing=nil)`. It is skipped when `CurrentUserID` is empty. It does not move the watermark, and its incompleteness alone does not freeze the Inbox: the blanket query covers the same messages.
  - `func (o *Orchestrator) RunOutcome() RunOutcome` with `type RunOutcome struct { RateLimited bool; ResumePending bool; Pages int; Messages int }`, read by the daemon's cadence (Task 3). `SearchIncomplete()` keeps its meaning (window not finished in this run), so INBOX-09 freezes as today.
- [ ] **Step 1: Write the failing tests**:
  - `TestSearchResume_ContinuesFromPage`: a 6-page window; run 1 stops after page 3 on `ErrFetchDeadline`; run 2 requests pages 4–6 only and then moves the watermark; `SearchIncomplete()` true after run 1 and false after run 2.
  - `TestSearchResume_DroppedWhenQueryChanges`.
  - `TestSearchResume_RestartReReads` (a new orchestrator starts at page 1).
  - `TestSearchResume_NoDiffOnResumedRun`: the deletion diff does not run on a window read across two runs.
  - `TestAdaptive_MentionQueryFirst`: the request order is mention query, then blanket; with the blanket rate-limited on page 1 the mention is stored.
- [ ] **Step 2: Run** `go test ./internal/sync -run 'TestSearchResume_|TestAdaptive_Mention'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `go test ./internal/sync` — PASS (existing tests untouched); `make lint-diff`.
- [ ] **Step 5: Commit** `feat(sync): resumable Slack search, mentions first (#1709)`.

### Task 3: Adaptive cadence

**Depends on:** Task 2, Task 4 (skipped Slack runs are safe for the Inbox only with ingestion order)

**Files:**
- Modify: `internal/daemon/daemon.go` (`phaseSlackSync`: due check per account), a new `internal/daemon/slack_cadence.go`
- Test: `internal/daemon/slack_cadence_test.go`

**Interfaces:**
- Consumes: `Orchestrator.RunOutcome()` (Task 2).
- Produces: `type slackCadence struct { level int; nextDue time.Time }` per account id on the daemon; `func (c *slackCadence) after(o RunOutcome, base time.Duration, now time.Time)`:
  - `RateLimited` → `level++`, capped where `base × 2^level ≥ cadenceMax`.
  - Clean → `level--`, not below 0.
  - `ResumePending` → `nextDue = now` (due next cycle).
  - Otherwise `nextDue = now + base × 2^level`, capped at `cadenceMax`.

  `func (c *slackCadence) due(now time.Time, manual bool) bool` is always true for a manual trigger or the first run after start. A skipped account writes nothing and does not count as a sync error. Its last `last_sync.json` entry stays. It does not freeze the Inbox (Task 4 makes that safe).
- [ ] **Step 1: Write the failing tests** (fake clock): `TestCadence_BacksOffOn429` (15 → 30 → 60 → 60), `TestCadence_RecoversWhenClean` (60 → 30 → 15), `TestCadence_ResumeIsDueNextCycle`, `TestCadence_ManualTriggerAlwaysRuns`, `TestCadence_RestartRunsAtOnce`, `TestPhaseSlackSync_SkippedAccountDoesNotFreezeInbox`.
- [ ] **Step 2: Run** `go test ./internal/daemon -run 'TestCadence_|TestPhaseSlackSync_Skipped'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `go test ./internal/daemon` — PASS (`TestInbox09_*` untouched); `make lint-diff`.
- [ ] **Step 5: Commit** `feat(daemon): Slack cadence adapts to 429s and data volume (#1709)`.

### Task 4: Ingestion-ordered Slack inbox detection

**Depends on:** none (merge before Tasks 2 and 5 or rebase: it touches `search_sync.go`/`message_sync.go` writers)

**Files:**
- Create: `internal/db/migrations/<next>_messages_synced_at.sql`. In this order:
  - `ALTER TABLE messages ADD COLUMN synced_at REAL NOT NULL DEFAULT 0;` then `UPDATE messages SET synced_at = ts_unix;`
  - `CREATE INDEX idx_messages_synced_at ON messages(synced_at);`
  - `ALTER TABLE slack_accounts ADD COLUMN first_cycle_at TEXT NOT NULL DEFAULT '';` then `UPDATE slack_accounts SET first_cycle_at = strftime('%Y-%m-%dT%H:%M:%SZ','now');`
  - The trigger:
    ```sql
    CREATE TRIGGER messages_synced_at_fill AFTER INSERT ON messages
    WHEN NEW.synced_at = 0
    BEGIN
      UPDATE messages SET synced_at = (julianday('now') - 2440587.5) * 86400.0 WHERE rowid = NEW.rowid;
    END;
    ```
  - The Down migration reverses it all.
  - Why it works: `julianday` works on both the Go driver's SQLite 3.53.4 and the GRDB fork. The upsert's `ON CONFLICT … DO UPDATE` branch fires UPDATE triggers only, and no writer uses `INSERT OR REPLACE INTO messages`, so an edit, tombstone or heal never moves `synced_at`.
- Modify: `internal/db/schema.sql`, the golden, `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`.
- Modify: `internal/db/messages.go` (`Message.SyncedAt`, insert only), `internal/db/inbox.go` (the four detectors: `m.synced_at > ?`), `internal/db/slack_accounts.go` (`SlackFirstCycleAt`, `SetSlackFirstCycleAtOnce`).
- Modify: `internal/sync/search_sync.go`, `message_sync.go` (`stampSyncedAt`), `BackfillSearch` (`ts_unix`).
- Test: `internal/db/inbox_ingest_test.go`, `internal/sync/synced_at_test.go`.

**Interfaces:**
- Produces: `func (o *Orchestrator) stampSyncedAt(tsUnix float64) float64` — returns `clock()` when `tsUnix ≥ max(A, runStart − 24h)`, else `tsUnix`. `A` is `first_cycle_at`, written once at the account's first run attempt; while that first run is in progress, `A` is its start.
- Why 24 h: a stored-late message waits at most `cadenceMax` (60 min) plus the runs a 429 storm stretches. During a storm the run is incomplete, so INBOX-09 freezes the watermark and even a `ts_unix` stamp stays above it.
- Writers: everything except the sync leaves `SyncedAt` 0 for the trigger. Desktop production code never writes `messages`; its test schema has the trigger.
- [ ] **Step 1: Write the failing tests**:
  - `TestInbox_LateStoredMessageDetected`: watermark at `runStart − 30 min`; a mention with `ts = runStart − 45 min` stored now is detected.
  - `TestInbox_FirstSyncDoesNotFloodInbox`.
  - `TestInbox_SharedToFullMoveDoesNotFloodInbox`: a new account row re-inserts the same messages under new namespaced keys, and they are older than its `first_cycle_at`.
  - `TestInbox_BackfilledMessageNotDetected`.
  - `TestMessagesSyncedAtTrigger_FillsZero`, `TestMessagesSyncedAtTrigger_ExplicitWins`, `TestMessagesSyncedAtTrigger_UpdateDoesNotBump`.
  - `TestStampSyncedAt` (table).
  - `TestFirstCycleAt_WrittenOnceAndKeptOnRetry`.
  - `TestMigration_MessagesSyncedAtFromTs`, `TestMigration_FirstCycleAtForExistingAccounts`.
- [ ] **Step 2: Run** `go test ./internal/db ./internal/sync -run 'TestInbox_|TestMessagesSyncedAtTrigger_|TestStampSyncedAt|TestFirstCycleAt_|TestMigration_'` — FAIL.
- [ ] **Step 3: Implement** with the `add-migration` skill; regenerate the golden and the Swift test schema (`go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`).
- [ ] **Step 4: Run** `go test ./internal/db ./internal/inbox ./internal/sync ./internal/daemon ./internal/digest ./internal/tools` and `make test-swift FILTER=TestDatabase` — PASS (`TestInbox09_*`, SRCDEL, SLACK-01 fixtures untouched); `make lint-diff`.
- [ ] **Step 5: Commit** `feat(inbox): Slack detection ordered by when a message was stored (#1709)`.

### Task 5: Stop syncing a channel (data, sync, CLI, chat coverage)

**Depends on:** Task 4 (migration order only)

**Files:**
- Create: `internal/db/migrations/<next>_channel_sync_excluded.sql` — `ALTER TABLE channel_settings ADD COLUMN sync_excluded INTEGER NOT NULL DEFAULT 0;` (+ Down); `schema.sql`, golden, Swift test schema.
- Modify:
  - `internal/db/channel_settings.go`: `SetSyncExcluded(channelID string, excluded bool) error` sets `is_muted_for_llm = 1` too when `excluded` is true; `SyncExcludedChannelIDs(accountID int64) (map[string]bool, error)`.
  - `internal/sync/search_sync.go`: `searchAndSave` drops a match from an excluded channel unless its text contains `<@ownerRaw>`, before `EnsureChannel`/upsert/media; the listing still records it.
  - `internal/sync/message_sync.go`: `buildChannelQueue` skips excluded channels.
  - `cmd/channels.go`: `watchtower channels exclude <name|id>` / `include`.
  - `internal/tools/messages.go`: `channelInScope` is false for an excluded channel.
- Test: `internal/db/channel_settings_test.go`, `internal/sync/sync_excluded_test.go`, `cmd/channels_test.go`, `internal/tools/messages_test.go`

**Interfaces:**
- Produces: `db.SetSyncExcluded`, `db.SyncExcludedChannelIDs`; `Orchestrator` reads the set once per run.
- [ ] **Step 1: Write the failing tests**:
  - `TestSYNCEX01_EveryPathHonoursExclusion` (guard): forward search, sweep, `BackfillSearch` and `--channels` each store nothing new for `C0JUNK`.
  - `TestSyncExcluded_MentionStillStored`.
  - `TestSyncExcluded_StoredDataStays`.
  - `TestSyncExcluded_IncludeResumes`.
  - `TestSetSyncExcluded_AlsoMutes`.
  - `TestChannelsExcludeCLI`.
  - `TestListMessages_ExcludedChannelNotInScope`.
- [ ] **Step 2: Run** `go test ./internal/db ./internal/sync ./internal/tools ./cmd -run 'SYNCEX01|SyncExcluded|SetSyncExcluded|ChannelsExclude|ExcludedChannel'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `go test ./internal/db ./internal/sync ./internal/tools` and `go test ./cmd -run Channels` — PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(sync): Stop syncing a channel (#1709)`.

### Task 6: Stop syncing suggestions and the Statistics screen

**Depends on:** Task 5

**Files:**
- Modify (Go): `internal/db/channel_stats.go` — `ComputeRecommendations` gains `Action: "exclude"` per agent decision 5. The `ChannelStatRow` input gains `IsSyncExcluded` and `MutedSince`. `MutedSince` is read from `channel_settings.updated_at` while muted; no new column.
- Modify (Swift, dual path):
  - `WatchtowerDesktop/Sources/Database/Queries/ChannelStatsQueries.swift`: the same rule, and `setSyncExcluded`, which writes both flags in one write.
  - `Models/ChannelStat.swift`, `WatchtowerCore/Models/ChannelRecommendation.swift` (`.exclude`).
  - `ViewModels/ChannelStatsViewModel.swift` (`toggleSyncExcluded`, `applyRecommendation` for `.exclude`, a **Not synced** filter).
  - `Views/Statistics/ChannelStatisticsView.swift` (a **Stop syncing** / **Sync again** button per row, the suggestion row's button), built from DesignKit components per `docs/design/desktop-style-guide.md`.
- Test: `internal/db/channel_stats_test.go`, shared cases `internal/db/testdata/channel_recommendation_cases.json` read by Go and by `WatchtowerDesktop/Tests/ChannelStatsTests.swift`

**Interfaces:**
- Consumes: `channel_settings.sync_excluded` (Task 5).
- Produces: recommendation action `"exclude"` with reason `"muted 30+ days, no messages or mentions from you"` or `"<n>% bot messages, no value signals"`. A channel already excluded gets no recommendation.
- [ ] **Step 1: Write the failing tests**: `TestComputeRecommendations_Exclude*` (from the shared JSON cases), `ChannelStatsTests.testExcludeRecommendationMatchesGo`, `testApplyExcludeWritesBothFlags`, `testNotSyncedFilter`.
- [ ] **Step 2: Run** `go test ./internal/db -run TestComputeRecommendations_` and `make test-swift FILTER=ChannelStatsTests` — FAIL.
- [ ] **Step 3: Implement**; look at the screen with `make desktop-shots DESKTOP_SHOTS=<dir>`.
- [ ] **Step 4: Run** the same and `make lint-swift`, `make lint-diff` — PASS.
- [ ] **Step 5: Commit** `feat(desktop): suggest channels to stop syncing (#1709)`.

### Task 7: Guide, feature note, inventory

**Depends on:** Task 1, Task 2, Task 3, Task 5, Task 6

**Files:**
- Modify the guide:
  - `docs/guide/features/statistics.md`: **Stop syncing**, what it keeps (mentions, already-stored data), the suggestion rule, one learn card `statistics-stop-syncing` (`since: next`). Mind the 8 KB cap.
  - `docs/guide/concepts/how-watchtower-works.md`: the "Slack messages" row says every 15 min by default, less often while Slack is rate-limiting, mentions first.
  - `docs/guide/troubleshooting/`: the Slack-sync-lagging page if one exists; otherwise a sentence in `how-watchtower-works.md`.
- Create: `docs/features/slack-adaptive-sync.md` (architecture, constants, capacity table, writers, failure modes, v1 limits: the in-memory resume and rate, exclusion not lowering search calls, the spike's `-in:` follow-up).
- Modify:
  - `CLAUDE.md` (Feature Notes line), `docs/features/README.md` (summary), `docs/features/slack-multi-account.md`.
  - `docs/inventory/inbox-pulse.md` (INBOX-09 `synced_at` extension + changelog).
  - A new SYNCEX-01 entry: `docs/inventory/channel-sync-exclusion.md` and its line in `docs/inventory/README.md`.
- [ ] **Step 1:** Write per `docs/guide/WRITING.md`, checking every number against the constants.
- [ ] **Step 2: Run** `go test ./docs/guide/ ./internal/kb/ ./internal/chat/ ./internal/learn/` — PASS.
- [ ] **Step 3: Commit** `docs: adaptive Slack sync and Stop syncing (#1709)`.

## Failure modes → tests

| Failure | Behaviour | Test |
|---|---|---|
| 429 storm mid-window | AIMD halves the rate; the retry chain waits and continues until the deadline; then resume next run; the watermark holds; the Inbox freezes | `TestAdaptive_RetryChainPushesThrough`, `TestAdaptive_DeadlineStopsChain`, `TestSearchResume_ContinuesFromPage` |
| Sleep or quit mid-pagination (ctx cancelled) | the resume position is kept (sleep) or lost (quit, so a re-read); nothing half-written | `TestSearchResume_ContinuesFromPage`, `TestSearchResume_RestartReReads` |
| Long `Retry-After` vs the Sync Now stall restart | the heartbeat shows the hold; no restart | `TestManualTrigger_DoesNotRestartWhileRateLimited` |
| Restart | cadence due at once, rate 40/min, resume lost (re-read) | `TestCadence_RestartRunsAtOnce`, `TestSearchResume_RestartReReads` |
| Skipped Slack run (cadence) | no error, no freeze; late-stored messages still detected | `TestPhaseSlackSync_SkippedAccountDoesNotFreezeInbox`, `TestInbox_LateStoredMessageDetected` |
| Exclusion toggled while a run is in flight | applies from the next run | `TestSyncExcluded_IncludeResumes` |

## Promises → tasks → tests

| Promise (ask #1337 / D16) | Task | Test |
|---|---|---|
| Retry chain pushes through limits, no lost work | 1, 2 | `TestAdaptive_RetryChainPushesThrough`, `TestSearchResume_*` |
| Self-balancing packing | 1, 2 | `TestAIMD_*`, `TestPageSizes_Max`, `TestAdaptive_MentionQueryFirst` |
| Cadence adapts to volume and 429s | 3 | `TestCadence_*` |
| "What I don't need" + suggestions, on the existing groundwork | 5, 6 | `TestSYNCEX01_*`, `TestComputeRecommendations_Exclude*`, `ChannelStatsTests` |
| Everything synced for every account | 2 | existing search tests untouched |
| The guide says all of this | 7 | `go test ./docs/guide` |

## Phase gate (controller, once)

`make test`, `go test ./cmd/...`, `make test-swift`, `make lint-all`; then the local-review skill on the whole branch.
