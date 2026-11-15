# Slack Full — Own-Scope Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A synced Slack account keeps only the user's own scope (DMs, group DMs, mentions of the user, channels the user is a member of): DMs and mentions every cycle (15 min), member channels hourly, the history backfill over the same scope, and public channels the user is not in stop entering the local copy.

**Architecture:** The forward sync stops running one blanket `search.messages after:D` per cycle. Each cycle refreshes the account's membership with `users.conversations`, runs a `search.messages` query for mentions of the user (the existing search watermark, window and first-sync logic), then fetches conversations through a small seam, `conversationFetcher`, whose v1 implementation is per-conversation `conversations.history` with `oldest=` (spec §2 option 2). A pure lane planner decides which conversations are due in this cycle (fast lane: DMs and group DMs; slow lane: member channels, due after 60 min), stalest first under a per-cycle call budget. Every save path (mention search, the deletion sweep, backfill, `sync --channels`) passes an own-scope filter, so nothing outside the scope is written, whichever path brings it. The Slack client counts 429s per cycle: the second one ends the cycle, holds the backfill chunk and leaves every watermark where it was. Own scope is a per-orchestrator mode (`ScopeOwn` / `ScopeAll`): the public build syncs own scope, the corp build keeps today's blanket search (Owner decision 1), so today's code path and its guard tests stay live.

**Tech Stack:** Go 1.26, `slack-go/slack` plus the client's raw `postAPI`, `database/sql` on the in-repo SQLCipher driver, `testing/synctest` for every timing test.

**Spec:** `docs/superpowers/specs/2026-11-14-slack-full-and-live-design.md` — §2 (the scope of this plan), D3, D12, §7 rows "Sync", §8, §9 row "Full syncs only the own scope, two speeds" and "Mentions of the user arrive even from channels they are not in", §10. The screens spec (`2026-11-15-slack-full-live-screens-design.md`) only for the guide wording (S6 edits the same guide page; see Task 8).

**Spike gate.** Spike T1 (live Slack, waiting for a configuration token) has to answer three things: (1) does `search.messages` OR repeated `in:` (option 1), and how many channels fit in one query; (2) can a search query be limited to DMs and group DMs; (3) is the Tier-3 quota for `conversations.history` really shared per workspace × app, or counted per user token. The plan is split on that line:

- **Tasks 1–4 can be built now.** They add the client calls, membership, the save filter (dormant until a scope is set) and the lane planner behind the `conversationFetcher` seam. The running cycle does not change.
- **Task 5 (switching the forward cycle) and everything after it wait for the spike's verdict.** The Capacity section below shows that option 2 alone cannot carry hundreds of people per workspace if the quota is shared. If the spike confirms option 1, the controller first adds a `searchInFetcher` task (groups of member channels per `in:` query, plugged in at `Orchestrator.fetcher`; `planLanes` and the filter stay as they are) and only then runs Task 5. If the quota turns out to be per token, Task 5 can run on option 2 as written.
- Also for the spike: confirm the mention query syntax (`<@U…>`) on a real workspace. The tests here only pin the query we send.

## Capacity (option 2, Tier 3)

**No cheap change signal exists for a user token.** `users.conversations` and `conversations.list` return channel objects without the newest message. Their `updated` field tracks channel settings, not messages. `conversations.info` returns `last_read`, and `latest` only for some conversation types; it is also a Tier-3 call per channel, so it costs as much as the history call it would save. `client.counts`/`users.counts` are undocumented, so they are not allowed (Slack's terms). The Events API and Socket Mode need either an app-level token handed to every member or a public endpoint, which D5/D13 rule out. The only cheap narrowing is search (option 1). So option 2 does not know which channels changed, whatever the spec's "member channels that changed" suggests. It polls every conversation on its lane schedule, and a channel with no news still costs one `conversations.history` call.

Assumptions: Tier 3 ≈ 50 calls/min = 3,000/h for each method, per workspace × app (spec §2; to be confirmed by the spike). Quotas are counted per method, so `conversations.history`, `conversations.replies`, `users.conversations` and `search.messages` (Tier 2, ≈ 1,200/h) each have their own budget. The binding one is `conversations.history`. "People" means Watchtower users in one workspace sharing its app.

| Profile (per person) | Schedule | `conversations.history` calls/h | People per workspace before 429s |
|---|---|---|---|
| Typical: 20 hot DMs, 100 cold DMs, 30 active + 20 quiet channels | strict D12: every DM each 15 min, every channel hourly | 120×4 + 50 = 530 | ≈ 5 |
| same | proposed lanes (decisions 3, 4): hot DMs 15 min, cold DMs 60 min, active channels 60 min, quiet 6 h | 80 + 100 + 30 + 3 ≈ 213 | ≈ 14 |
| same | proposed, with cold DMs every 6 h as well | 80 + 17 + 30 + 3 ≈ 130 | ≈ 23 |
| Light: 10 hot DMs, 30 cold DMs, 15 active + 5 quiet channels | proposed lanes | 40 + 30 + 15 + 1 ≈ 86 | ≈ 35 |
| Today: blanket `search.messages` (spec §2: 1,000-person workspace, 20k public messages/day) | 15-min cycle | ≈ 12 `search.messages` calls/h (Tier 2) | ≈ 100 (≈ 130 at a 60-min cycle) |
| Option 1 (estimate, depends on the spike): mentions + one DM query + member channels in `in:` groups of 10, hourly | 15/60 min | ≈ 4 + 4 + 5 + own volume/100 ≈ 15 `search.messages` calls/h | ≈ 80 on search; the methods' quotas add up when DMs stay on history |

Busy channels that need more than one history page, and `conversations.replies` calls (their own quota), come on top. `users.conversations` costs about 4 calls/h per person on its own quota and never binds.

**Conclusion.** With a shared workspace quota, option 2 alone carries about 5–35 people per workspace, not hundreds. That is why Task 5 waits for the spike. Option 2 is still the right shape if the quota turns out to be per token (one person's ≈ 213/h is far below 3,000/h), and it remains the fallback for what search cannot narrow.

**Budget.** Each cycle's call budget is derived from the quota rather than fixed: `laneCallBudget = tier3HourlyQuota / targetPeoplePerWorkspace / cyclesPerHour`, with `tier3HourlyQuota = 3000` and `cyclesPerHour = time.Hour / poll_interval`. `targetPeoplePerWorkspace` is Owner decision 6; the default of 25 gives 30 calls per 15-minute cycle (120/h). **What the budget does to D12:** the fast lane goes first. Whenever a person's due work is larger than the budget, the slow lane's rotation stretches. For the typical profile at 30 calls per cycle, the 20 hot DMs keep 15 minutes, and the remaining 10 calls per cycle (40/h) serve 100 cold DMs + 50 channels, so each one comes around about every 3.75 h instead of hourly. D12 then holds only for hot DMs and mentions. The planner logs each cycle's deferred count, so the stretch shows up in the log.

## Global Constraints

- Own scope = DMs, group DMs, mentions of the user (a `search.messages` query, so a mention in a channel the user is not in still arrives), channels the user is a member of (D3). Public channels the user is not a member of leave the local copy.
- Two speeds (D12): DMs, group DMs and the mention query every cycle (`sync.poll_interval`, default 15 min); member channels every 60 minutes (`memberChannelEvery = time.Hour`, due when ≥ `memberChannelEvery − poll_interval/2` since the last fetch, so cycle drift never skips an hour). Cold DMs hourly and quiet channels every 6 h are proposed deviations (Owner decisions 3, 4). Under the per-cycle budget (decision 6) the slow lane stretches whenever due work exceeds it (Capacity).
- `users.conversations` refreshed once a cycle (spec §2 option 2); it is Tier 3, like `conversations.history`.
- The history backfill covers the own scope only and keeps one chunk per cycle (BACKFILL pacing unchanged).
- `Retry-After` holds every Slack call of the account (existing `RateLimiter.HandleRateLimit` backoff, one client per account in the daemon); the second 429 inside a cycle ends the cycle early.
- Own scope applies where `sync.ScopeForBuild` says `ScopeOwn` (public build); the corp build keeps `ScopeAll` (Owner decision 1).
- A left channel stops syncing; its data stays (§7). Already-synced data of non-member public channels stays (Owner decision 2, recommended default).
- No new migration is planned (membership lives in `channels.is_member`, per-conversation watermarks in `sync_state`). If an implementer finds one necessary, stop and ask the controller; then follow the `add-migration` skill.
- No guard test is weakened or edited. Existing guards keep running against `ScopeAll` (corp build, `NewOrchestrator`'s default); own scope adds guard twins listed under "Contract extensions needing owner approval", and tasks that add them do not start before that approval.
- Tests never wait on wall-clock time: the orchestrator's injected `now`, `testing/synctest` for the limiter and the client (fake `http.RoundTripper` inside the bubble, no sockets). No test spawns a process.
- Fixtures use fake ids (`T000`, `U0OWNER`, `C0MEMBER`, `C0OTHER`, `D0DM`); any that trips the leak-check's Slack-id pattern carries `leak-check:allow`.
- Inner loop per task: `go test ./internal/<pkg>` for each touched package, `make lint-diff`. The full gate (`make test`, `make lint-all`, `go test ./cmd/...`) runs once at the end by the controller.

## Review Focus

1. **A membership listing that comes back empty or cut short** (Slack hiccup, a page fails): no channel may lose `is_member`, nothing is purged, the lanes skip this cycle — pinned in Task 2 (`TestReplaceSlackMembership_RefusesEmpty`) and Task 5 (`TestOwnScope_MembershipRefreshFailsSkipsLanes`).
2. **A user in 300 channels / 400 DMs**: the cycle stays inside its call budget, every conversation is reached within a bounded number of cycles, stalest first, and a restart does not reset the rotation into a burst beyond the budget — pinned in Task 4 (`TestPlanLanes_BudgetRotatesStalestFirst`, `TestPlanLanes_RestartStaysInBudget`).
3. **A reply in a two-day-old thread of a member channel**: `conversations.history oldest=watermark` does not return it; the re-read window and `latest_reply` must — pinned in Task 4 (`TestHistoryFetcher_ReplyToRecentThread`).
4. **The deletion sweep and the old blanket listings still bring non-member public messages**: the save filter drops them, while the sweep's diff still judges stored rows correctly — pinned in Task 3 (`TestScopeFilter_SweepSavesNothingOutOfScope`).
5. **A first sync whose mention search is rate-limited while lanes already saved messages**: the account must still get its history backfill on the next cycle — pinned in Task 5 (`TestOwnScope_FirstSyncWaitsForMentionSearch`).

---

## Owner decisions needed (recommended option first)

1. **Which accounts get own scope.** (a, recommended) The public build: own-app (Full) accounts and accounts still on the retired shared app. The corp build's baked app keeps today's blanket search until the owner decides otherwise, because the parent spec §5.4 says nothing changes for corp on day one. The code tells them apart by build, the same rule the screens spec §1.1 uses for `shared_app` ("corp build never"): `sync.ScopeForBuild(wire.FlavorOf(cmd.BuildFlavor))` returns `ScopeAll` for `wire.FlavorCorp` and `ScopeOwn` otherwise. `wire.FlavorOf` is already on main (`internal/hub/wire/payloads.go`), so there is no dependency on plan B's `client_id` column; inside the public build every account syncs own scope, whatever its client id. (b) Own scope only for accounts whose `full` fact is true, which needs plan B's `client_id` first. (c) Every account, corp included.
2. **Already-synced data of non-member public channels.** (a, recommended) Keep it and stop syncing new messages. This matches §7 "a left channel … its data stays"; `is_member` turns 0, so `channel_in_scope` is false and the chat reaches the channel through Live. (b) Purge it. That is a new deletion path that would need its own contract (PURGE/SRCDEL) and a spec change.
3. **Quiet DMs — deviation from D12, needs owner approval.** D12 says every DM every 15 minutes, which costs 4 `conversations.history` calls per DM per hour (Capacity). (a, recommended) Hot DMs (a stored message within `hotWindow = 14 days`, or new in the membership listing) every cycle; cold DMs in the hourly lane. A first message in a DM silent for two weeks then arrives within an hour, not 15 minutes; a mention still arrives in 15. (b) D12 as written: every DM every cycle, still under the budget (decision 6).
4. **Quiet member channels — deviation from D12, needs owner approval.** (a, recommended) Channels with no stored message within `hotWindow` are due every `quietChannelEvery = 6 h` instead of hourly. (b) D12 as written: every member channel hourly.
5. **Replies in threads older than the re-read window.** `conversations.history` returns parents only. (a, recommended for v1) Each fetch re-reads the last `rereadWindow = 72 h` and calls `conversations.replies` only for parents whose `latest_reply` is newer than the newest stored reply; replies to older threads arrive only when they mention the user. Cost: no extra calls beyond the replies themselves. (b) The cheapest catch for older threads: keep "active threads" of member channels and DMs — parents older than 72 h whose newest stored reply is within `activeThreadWindow = 14 days` — and re-check each one in the slow lane (hourly) with `conversations.replies oldest=<newest stored reply>`, inside the same per-cycle budget, active threads last. Cost: one `conversations.replies` call per active thread per hour (its own Tier-3 quota). At about 20 active threads per person that is ≈ 20 calls/h, ≈ 150 people on that method alone, and it takes budget from the slow lane (the rotation in Capacity stretches further). Built as one more entry kind in `planLanes`, about half a task more.
6. **The per-cycle call budget.** `laneCallBudget = 3000 / targetPeoplePerWorkspace / cyclesPerHour` (Capacity). (a, recommended) `targetPeoplePerWorkspace = 25`, giving 30 calls per 15-minute cycle. D12 then holds only for hot DMs and mentions in the typical profile, and the slow lane stretches to about 3.75 h. (b) 10, giving 75 per cycle: D12 holds for the typical profile with the proposed lanes, but about 10 heavy users exhaust a workspace. (c) Set it after the spike measures the real quota.
7. **`watchtower sync --channels <public channel the user is not in>`.** (a, recommended) Refused with "not a member: own-scope sync stores only your channels". (b) Allowed as an explicit manual exception.
8. **Group mentions** (`@here`, `@channel`, user groups) do not count as "mentions of the user" (recommended; D3 says the user). Consequence: **`@channel`/`@here` messages from channels the user is not a member of stop arriving**. In member channels they still come through the lanes. The alternative grows the mention query by one OR per group and needs the spike to confirm that search matches them.
9. **The full-sync fallbacks of today's search path go (own scope only).** (a, recommended) Remove both. *`missing_scope` / any non-rate-limit failure of the search on page 1* today falls back to a full `conversations.list` + history of every channel. Under own scope, the mention lane is skipped with the gap note "mentions outside your channels not synced: <reason>", and the lanes still sync DMs and member channels; only mentions from non-member channels are lost until the token gets `search:read`. *"Zero channels found"* today also falls back to a full sync. Under own scope, the membership listing replaces discovery: the lanes fetch every member conversation, and an empty listing on a fresh account has nothing to fetch. (b) Keep a full-sync fallback limited to member channels for the `missing_scope` case. That duplicates the lanes and adds a second writer of `sync_state` in the same cycle. The corp build (`ScopeAll`) keeps both fallbacks unchanged.

10. **Deletions in the newest days (own scope).** The mention search does not list whole channels, so the search live diff cannot run under `ScopeOwn`. (a, recommended) Diff the re-read window of each conversation from its complete `conversations.history` listing through `sourcediff.Check` (Task 6). (b) Leave recent deletions to the rolling sweep, so a deleted message can stay visible for weeks.

## Contract extensions needing owner approval

With decision 1 (a), the corp build keeps today's path. Every existing guard test keeps running unchanged against `ScopeAll`, the default of `NewOrchestrator`, and stays a live guard for the corp build. The own-scope path adds twins. Tasks 5–7 do not start before the owner answers.

- **BACKFILL-01** (`docs/inventory/history-backfill.md`): adds the own-scope Slack first sync, "a completed own-scope first cycle: the mention search completed with no usable watermark on an account with no stored messages", next to "a completed search sync". The value is the same: local midnight of the day after the exclusive `after:` date. The guards `TestFirstSyncFrom_*` and `TestPhaseSlackSync_FirstSyncStartsBackfill` are untouched. New guard twins: `TestBACKFILL01_OwnScopeFirstSyncFrom`, `TestBACKFILL01_OwnScopeRateLimitedFirstRunIsNotAFirstSync`, `TestBACKFILL01_OwnScopeAccountWithMessagesIsNotAFirstSync` (Task 5).
- **SRCDEL-01 / SRCDEL-02** (`docs/inventory/source-deletions.md`): adds a Slack listing kind. Under own scope the live diff runs on per-conversation `conversations.history` listings (complete = every page read to `has_more=false`, no API error) through `sourcediff.Check(…, sourcediff.SlackFloors)`. The search-listing live diff stays for `ScopeAll`. `TestSRCDEL02_ReturningMessageHeals` and `TestLiveDiff_*` are untouched. New twins: `TestSRCDEL02_OwnScopeReturningMessageHeals` and the `TestHistoryDiff_*` set (Task 6).
- Task 8 updates the inventory text for both after the approval. Nothing else in `docs/inventory/` changes.

## Readers of `channels.is_member`

Under own scope `is_member` becomes Slack's real membership. Today it is polluted: `EnsureChannel` inserts `1` for every channel search ever returned. After the first membership refresh it flips to 0 for every non-member channel the old blanket search left behind, which can be hundreds of rows. Every reader below gets the true value. None needs a code change, and each one is pinned in Task 2:

| Reader | Effect of the flip to 0 |
|---|---|
| `internal/db/channel_stats.go` (`is_member` column; the leave recommendation at line 251 requires `s.IsMember`) | Non-member channels stop being offered "leave" — a fix: you cannot leave a channel you are not in |
| `WatchtowerDesktop/Sources/Database/Queries/ChannelStatsQueries.swift:33,135` (Swift mirror of the recommendations) | Same as Go |
| `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/StatsQueries.swift:46` (`COUNT(*) … is_member = 1`) | The Statistics channel count drops to the user's real channel count |
| `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ChatEntitySearch.swift:103` (`ORDER BY is_member DESC`) | Non-member channels sort below the user's own in chat mentions |
| `internal/tools/messages.go` (`channelInScope`), `internal/tools/slack_channels.go` (`is_member` in the tool output) | `channel_in_scope` turns false and the chat asks Live for those channels, as plan A intended |
| `internal/db/channels.go` (`GetChannels` member filter, `ChannelIDsWithoutLastRead` at line 309), `internal/sync/message_sync.go` (`buildChannelQueue`) | The first read-cursor pass and `sync --full` cover member channels only, which means fewer calls |
| `WatchtowerDesktop/Sources/WatchtowerCore/Models/Channel.swift`, `Models/ChannelStat.swift` | Decoding only |

## Writers of the same data (spec §8 rule)

| Data | Writers | Who wins a race |
|---|---|---|
| `messages` rows | forward lanes (Task 4), mention search and the sweep through `searchAndSave` (filtered, Task 3), backfill range fetch (Task 7), `watchtower slack backfill` and `sync --full/--channels` in another process | upserts of the same Slack content; SQLite serialises the write transactions; the last write is Slack's newer state. A tombstone and a restore follow SRCDEL-02: the next fetch that returns the message heals it |
| `channels.is_member` | membership refresh (`ReplaceSlackMembership`, Task 2, authoritative per account, complete listing only), `UpsertChannel` from `conversations.list` (full sync, per channel), `EnsureChannel` (insert only, membership-aware after Task 2) | the two Slack readers both carry Slack's answer at their time; the later write wins. `EnsureChannel` never changes an existing row's flag |
| `sync_state` (per conversation) | the forward lanes through the existing `syncChannel`, and `runFullSync` — same function, same daemon or a CLI process | `last_synced_ts` only moves after the last page; an interrupted fetch keeps the old value and the cursor, so the later complete fetch wins. The backfill never writes `sync_state` |
| `slack_accounts.search_last_date` | the mention lane only (today's writer, `syncViaSearch`) | single writer per process |
| lane stamps, backfill chunk progress | in memory on the `Orchestrator` (the `readStateSyncedAt` precedent) | one daemon; a restart starts both from empty |

---

### Task 1: Slack client — `users.conversations` and the per-cycle 429 cap

**Depends on:** none

**Files:**
- Modify: `internal/slack/client.go` (new method; `doRequest`)
- Modify: `internal/slack/ratelimit.go` (cycle counter)
- Test: `internal/slack/client_test.go`, `internal/slack/ratelimit_test.go`

**Interfaces:**
- Produces:
  - `func (c *Client) GetUserConversations(ctx context.Context) ([]slack.Channel, error)` — `users.conversations`, Tier 3, `types=public_channel,private_channel,mpim,im`, `exclude_archived=true`, `limit=200`, every page; on a failed page returns the pages read so far **and** the error (callers treat any error as "listing incomplete").
  - `var ErrCycleRateLimited = errors.New("slack: rate limited twice in one cycle")`
  - `func (c *Client) BeginCycle()` — turns the per-cycle cap on for this client (a client that never calls it keeps today's behaviour: `ScopeAll`, the CLI tools), resets the cycle's 429 count and un-trips the client.
  - `func (c *Client) CycleRateLimited() bool` — the second 429 of this cycle was seen.
  - Behaviour of `doRequest`: the first 429 of a cycle keeps today's backoff-and-retry. The second 429 returns `fmt.Errorf("%w: %w", ErrCycleRateLimited, rlErr)` without retrying, and every later call in the cycle returns `ErrCycleRateLimited` without reaching Slack (`rateLimiter.Wait` not entered). `errors.As(err, *slack.RateLimitedError)` still holds for the second-429 error so `isRateLimitError` keeps working.

- [ ] **Step 1: Write the failing tests** — in a `synctest.Test` bubble with a fake `RoundTripper` (the `ratelimit_test.go` pattern):
  - `TestGetUserConversations_AllPagesAndTypes`: two pages; asserts the request form carries `types=public_channel,private_channel,mpim,im`, `exclude_archived=true`, the cursor on page 2, and that both pages' channels come back.
  - `TestGetUserConversations_PageErrorReturnsPartialAndError`: page 2 answers `ok:false`; asserts page 1's channels and a non-nil error.
  - `TestDoRequest_SecondRateLimitEndsCycle`: 429 (`Retry-After: 30`), then 200, then 429; asserts the first call succeeds after the 30 s backoff (bubble time), the second call's error `errors.Is(ErrCycleRateLimited)` and `errors.As(*slack.RateLimitedError)`, a third call returns `ErrCycleRateLimited` with zero round trips, `CycleRateLimited()` is true, and after `BeginCycle()` a call reaches Slack again.
  - `TestDoRequest_NoCapWithoutBeginCycle`: three 429s on a client that never called `BeginCycle` behave as today (retried after backoff).
  - `TestDoRequest_RetryAfterHoldsEveryMethod`: a 429 on `search.messages` with `Retry-After: 20`; a concurrent `conversations.history` call is not sent before 20 s of bubble time.
- [ ] **Step 2: Run** `go test ./internal/slack -run 'TestGetUserConversations|TestDoRequest_'` — expected FAIL (undefined).
- [ ] **Step 3: Implement** the method (through `postAPI`, the `SearchMessages` precedent, or slack-go's `GetConversationsForUserContext` — either, as long as the form is as tested) and the cycle counter on `RateLimiter` (`cycle429 int`, `tripped bool`, under `mu`; `HandleRateLimit` increments it).
- [ ] **Step 4: Run** `go test ./internal/slack` — PASS; `make lint-diff` clean.
- [ ] **Step 5: Commit** `feat(slack): users.conversations and a per-cycle 429 cap (#1709)`.

### Task 2: Membership in the database

**Depends on:** none

**Files:**
- Create: `internal/db/slack_membership.go`, `internal/db/slack_membership_test.go`
- Modify: `internal/db/channels.go` (`EnsureChannel`) and every caller of it:
  - production: `internal/sync/search_sync.go:365`
  - tests (14 call sites, each passes `true`, which keeps today's meaning): `internal/db/messages_extra_test.go` (4), `internal/sync/deletions_sweep_test.go` (2), `internal/sync/deletions_test.go` (1), `internal/tools/taskcontext_test.go` (3), `internal/tools/taskcontext_linear_test.go` (1), `internal/daemon/daemon_test.go` (2), `internal/daemon/daemon_memory_test.go` (1). Before editing, re-run `grep -rn 'EnsureChannel(' --include='*.go' .`; a newer call site gets the same treatment
- Test (the `is_member` readers, see "Readers of `channels.is_member`"): `internal/db/channel_stats_test.go`, `WatchtowerDesktop/Tests/ChannelStatsTests.swift`, `WatchtowerDesktop/Tests/Core/QueryTests.swift`. There is no Desktop source change

**Interfaces:**
- Produces:
  - `type SlackMember struct { ID, Name, Type, DMUserID string }` — `ID` and `DMUserID` namespaced; `Type` one of `public|private|dm|group_dm`.
  - `var ErrEmptyMembership = errors.New("empty membership listing over stored members")`
  - `func (db *DB) ReplaceSlackMembership(accountID int64, members []SlackMember) (left int, err error)` — one write transaction: upserts each member's channel row with `is_member = 1` (name/type/dm_user_id refreshed, `topic`/`purpose`/`last_read`/`digest_considered_ts` untouched), sets `is_member = 0` on every other channel row of the account (prefix `<accountID>:`) and returns how many turned 0. An empty `members` while the account has at least one `is_member = 1` row returns `ErrEmptyMembership` and writes nothing. No row is ever deleted.
  - `func (db *DB) SlackConversationActivity(accountID int64) (map[string]time.Time, error)` — newest stored message time per namespaced channel id of the account (from `messages.ts_unix`), for the lane planner.
  - `EnsureChannel(id, name, chType, dmUserID string, isMember bool) error` — the insert uses `isMember`; on conflict the flag is left alone (as today).

- [ ] **Step 1: Write the failing tests**: `TestReplaceSlackMembership_SetsAndClears` (two accounts; account 1's listing clears its own left channel only, account 2 untouched, `left == 1`, the left channel's messages still there), `TestReplaceSlackMembership_RefusesEmpty` (`errors.Is(err, ErrEmptyMembership)`, every flag unchanged), `TestReplaceSlackMembership_FirstListingOnEmptyAccount` (empty listing on an account with no members is accepted), `TestEnsureChannel_InsertsMembershipFlag`, `TestSlackConversationActivity_PerChannelNewest`, `TestComputeRecommendations_NonMemberNeverLeave` (a quiet channel with `is_member = 0` after `ReplaceSlackMembership` gets no leave recommendation, a member one does), `TestReplaceSlackMembership_ChannelInScopeFlips` (`internal/tools`: `list_messages` on a channel that left the listing reports `channel_in_scope: false`). Swift pins of the same value (read-only, no source change): `ChannelStatsTests.testNonMemberGetsNoLeaveRecommendation`, `QueryTests.testChannelCountCountsMembersOnly`.
- [ ] **Step 2: Run** `go test ./internal/db -run 'TestReplaceSlackMembership|TestEnsureChannel_|TestSlackConversationActivity'` — FAIL.
- [ ] **Step 3: Implement**; the search save path passes `isMember` from the scope (Task 3 wires the real value; here pass `true` to keep behaviour).
- [ ] **Step 4: Run** `go test ./internal/db ./internal/sync ./internal/tools ./internal/daemon` and `make test-swift FILTER='ChannelStatsTests|QueryTests'` — PASS; `make lint-diff`, `make lint-swift`.
- [ ] **Step 5: Commit** `feat(db): Slack membership replace and conversation activity (#1709)`.

### Task 3: The own-scope filter on every save path

**Depends on:** Task 2

**Files:**
- Create: `internal/sync/ownscope.go`, `internal/sync/ownscope_test.go`
- Modify: `internal/sync/search_sync.go` (`searchAndSave`), `internal/sync/message_sync.go` (`buildChannelQueue` for `--channels`), `cmd/sync.go` (the refusal text for `--channels`, Owner decision 7)

**Interfaces:**
- Consumes: `db.EnsureChannel(…, isMember bool)` (Task 2).
- Produces:
  - `type ownScope struct { ownerRaw string; members map[string]string; known bool }` — `members` maps a raw channel id to its type; `known` is true only after a complete membership listing in this process.
  - `func (s ownScope) keep(m watchtowerslack.SearchMatch) bool` — keep when the match's channel is a DM or group DM, a private channel (search only returns private channels the user is in), a public channel in `members`, or the text contains `<@ownerRaw>`. With `known == false` a public match is kept only when it mentions the owner (fail closed).
  - `Orchestrator.scope ownScope` (field); `searchAndSave` drops every match `keep` refuses **before** `EnsureChannel`/`EnsureUser`/upsert/media, but still records it in a non-nil `listing` (the sweep's diff only judges channels with stored rows, so a broader listing stays correct). A kept public match from a non-member channel (a mention) is ensured with `isMember = false`.
  - `buildChannelQueue` with `opts.Channels` skips a public channel that is not a member and logs `"%s: not a member: own-scope sync stores only your channels"`; `cmd/sync.go` prints the same line.

- [ ] **Step 1: Write the failing tests**: `TestOwnScopeKeep` (table: DM, group DM, private, member public, non-member public, non-member public mentioning `<@U0OWNER>`, each with `known` true and false), `TestScopeFilter_SearchSavesOnlyOwnScope` (a search page with a member, a non-member and a mention-in-non-member match; asserts two rows stored, the non-member channel row absent, the mention's channel `is_member = 0`), `TestScopeFilter_SweepSavesNothingOutOfScope` (the sweep fixture of `deletions_sweep_test.go` with a non-member public match; asserts no row and no channel stored for it, and a stored member row missing from the listing is still tombstoned), `TestBuildChannelQueue_RefusesNonMemberChannelFilter`.
- [ ] **Step 2: Run** `go test ./internal/sync -run 'TestOwnScopeKeep|TestScopeFilter_|TestBuildChannelQueue_Refuses'` — FAIL.
- [ ] **Step 3: Implement.** Until Task 5 sets it, `o.scope` is the zero value; to keep today's tests green in between, `searchAndSave` applies the filter only when `o.scope.known || o.scope.ownerRaw != ""` (Task 5 replaces this guard with `o.mode == ScopeOwn`; leave a `// Task 5` comment).
- [ ] **Step 4: Run** `go test ./internal/sync ./cmd -run 'Sync'` — PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(sync): own-scope filter on every Slack save path (#1709)`.

### Task 4: Lanes and the conversation fetcher seam (option 2)

**Depends on:** Task 1, Task 2

**Files:**
- Create: `internal/sync/ownscope_lanes.go` (planner + seam + `historyFetcher`), `internal/sync/ownscope_lanes_test.go`
- Modify: `internal/sync/message_sync.go` (`syncChannel` gains the re-read window and `latest_reply` replies; `computeOldest` own-scope start)

**Interfaces:**
- Consumes: `Client.GetConversationHistory`, `Client.GetConversationReplies` (existing), `db.SlackConversationActivity` (Task 2).
- Produces:
  - Constants: `memberChannelEvery = time.Hour`, `quietChannelEvery = 6 * time.Hour`, `hotWindow = 14 * 24 * time.Hour`, `rereadWindow = 72 * time.Hour`, `tier3HourlyQuota = 3000`, `targetPeoplePerWorkspace = 25` (Owner decision 6). Owner decisions 3–6 may change these values and the cold/quiet rules; the planner is the only place they live.
  - `func laneCallBudget(pollInterval time.Duration) int` — `tier3HourlyQuota / targetPeoplePerWorkspace / max(1, int(time.Hour/pollInterval))`, at least 1 (30 at 15 min). It counts history and replies calls per cycle across both lanes; the fast lane goes first.
  - `type conversation struct { ID, Type string; LastActive time.Time }` (namespaced id).
  - `func planLanes(now time.Time, pollInterval time.Duration, convs []conversation, checkedAt map[string]time.Time) (due []conversation, deferred int)` — pure. Fast lane: hot DMs/group DMs (active within `hotWindow`, or never checked) every cycle. Slow lane: member channels and cold DMs, due when `now − checkedAt ≥ every − pollInterval/2` with `every = memberChannelEvery`, or `quietChannelEvery` for a channel quiet for `hotWindow`. Order: fast lane, then slow lane by oldest `checkedAt` (never checked first). Truncated to `laneCallBudget(pollInterval)` entries; returns the number deferred too (`due []conversation, deferred int`), which `runLanes` logs.
  - `type conversationFetcher interface { Forward(ctx context.Context, c conversation) (fetchResult, error); Range(ctx context.Context, c conversation, from, to time.Time) (int, error) }` and `type fetchResult struct { Saved int; Listing *historyListing; Calls int }` — `Listing` is non-nil only when the re-read window was read to `has_more=false` (Task 6 consumes it).
  - `type historyListing struct { channelID string; from, to time.Time; seen map[db.SlackMessageKey]struct{} }` — every message and reply key the fetch received in `[from, to)`; built here, diffed in Task 6.
  - `type historyFetcher struct{ o *Orchestrator }` — `Forward` runs `syncChannel` with `oldest = min(watermark, now − rereadWindow)`, and for each returned parent with `reply_count > 0` whose `latest_reply` is newer than the newest stored reply of that thread calls `conversations.replies` from that reply. `Range` reads `[from, to)` (`oldest`/`latest`, inclusive) and the replies of parents in it, writing **no** `sync_state`.
  - `Orchestrator.fetcher conversationFetcher` (default `historyFetcher`; the spike's option 1 replaces it here), `Orchestrator.laneCheckedAt map[string]time.Time` (stamped with `o.clock()` after a conversation's `Forward` succeeds).
  - `func (o *Orchestrator) runLanes(ctx context.Context) (complete bool, err error)` — plans with `planLanes`, calls `Forward` per due conversation; a non-fatal per-conversation error (`channel_not_found`, `not_in_channel`, `isNonFatalError`) is logged, recorded by `saveSyncError` and skipped; `ErrCycleRateLimited` or a cancelled ctx stops the loop and returns `complete = false`; `complete` is also false when the budget cut conversations that were due.
  - Only with Owner decision 5 (b): `planLanes` also takes the active threads (`[]activeThread{ChannelID, ThreadTS string; LastReply time.Time}` from a new `db.SlackActiveThreads(accountID, since time.Time)`). It plans them in the slow lane after the conversations and within the same budget; each one is fetched with `conversations.replies oldest=<LastReply>`. Test `TestPlanLanes_ActiveThreadsLastInBudget`. With 5 (a) none of this is built.
  - Own-scope initial `oldest` (no `sync_state`): local midnight of the date `now − initial_history_days` (the mention window's `D`), so a conversation first fetched in a later cycle never leaves a gap above the backfill's `upper`.

- [ ] **Step 1: Write the failing tests** (fake clock through `o.now`; HTTP through `newTestSetup`'s mux):
  - `TestPlanLanes_TwoSpeeds`: at t0 everything is due; at t0+15 min only hot DMs; at t0+52.5 min (60 − 15/2) member channels again; a quiet channel only at t0+6 h − 7.5 min; a cold DM with the member channels.
  - `TestLaneCallBudget`: 30 at 15 min, 120 at 60 min, 7 at 1 min.
  - `TestPlanLanes_BudgetRotatesStalestFirst`: 300 channels, 10 hot DMs, budget 30: each cycle plans the 10 DMs plus the 20 stalest channels (never-checked first), `deferred` reports the rest, and every channel is planned within 15 cycles.
  - `TestPlanLanes_RestartStaysInBudget`: an empty `checkedAt` (a restart) plans at most `laneCallBudget(pollInterval)`.
  - `TestHistoryFetcher_ForwardFromWatermark`: asserts the `oldest` sent is `min(last_synced_ts, now − 72 h)` and `sync_state.last_synced_ts` moves to the newest ts only after the last page.
  - `TestHistoryFetcher_ReplyToRecentThread`: a parent 2 days old with `latest_reply` newer than the stored replies → one `conversations.replies` call, the reply stored with its `thread_ts`; a parent whose `latest_reply` is already stored → no replies call.
  - `TestHistoryFetcher_RangeWritesNoSyncState`.
  - `TestOwnScope_CancelMidLaneResumes`: ctx cancelled after page 1 of a two-page conversation; `last_synced_ts` unchanged, cursor saved; the next `runLanes` resumes from the cursor and completes.
  - `TestOwnScope_LostChannelIsSkipped`: `conversations.history` answers `not_in_channel` for one channel; the others are fetched, `complete` stays true for them, the error lands in that channel's `sync_state.error`.
  - `TestOwnScope_InitialOldestMeetsBackfillUpper`: a conversation first fetched 40 min after the first cycle gets `oldest` ≤ local midnight of `D + 1`.
- [ ] **Step 2: Run** `go test ./internal/sync -run 'TestPlanLanes_|TestHistoryFetcher_|TestOwnScope_(CancelMidLane|LostChannel|InitialOldest)'` — FAIL.
- [ ] **Step 3: Implement** in `ownscope_lanes.go`; reuse `syncChannel`/`upsertMessagePage` (media, Jira keys and tombstone handling come with them).
- [ ] **Step 4: Run** `go test ./internal/sync` — PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(sync): own-scope lanes behind a conversation fetcher seam (#1709)`.

### Task 5: The forward cycle — membership, mentions, lanes, second 429

**Depends on:** Task 1, Task 3, Task 4; **the spike's verdict** (see Spike gate: if option 1 works, the `searchInFetcher` task the controller adds first); owner decisions 1, 3–6, 8, 9 and approval of the BACKFILL-01 extension

**Files:**
- Modify: `internal/sync/orchestrator.go` (`run` branches on the mode; new `runOwnScopeSync`; `runSearchSync` stays for `ScopeAll`; `Run` resets), `internal/sync/search_sync.go` (`syncViaSearch` takes the query and whether to diff), `cmd/sync.go` (daemon wiring sets the mode), `internal/repl/commands.go`, `cmd/slack_backfill.go` (same mode)
- Test: `internal/sync/ownscope_cycle_test.go`, `internal/sync/ownscope_backfill01_test.go` (the BACKFILL-01 twins), `cmd/sync_scope_test.go`. Existing tests (`search_backfill_test.go`, `search_sync_test.go`, `search_sync_ratelimit_test.go`, `orchestrator_test.go`, daemon tests) stay untouched and keep passing on `ScopeAll`

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces:
  - `type ScopeMode int` with `ScopeAll` (zero value, today's blanket search, `NewOrchestrator`'s default) and `ScopeOwn`; `func (o *Orchestrator) SetScopeMode(m ScopeMode)`; `func ScopeForBuild(flavor string) ScopeMode` — `ScopeAll` for `wire.FlavorCorp`, else `ScopeOwn` (Owner decision 1 (a)). `cmd/sync.go`, `internal/repl` and `cmd/slack_backfill.go` call `SetScopeMode(sync.ScopeForBuild(wire.FlavorOf(BuildFlavor)))` on every orchestrator they build. With decision 1 (b), the wiring picks per account once plan B's `full` fact exists.
  - Under `ScopeAll` nothing in this plan changes behaviour: no `BeginCycle` (no 429 cap), no save filter, no lanes, the search live diff and both full-sync fallbacks as today.
  - `func (o *Orchestrator) refreshMembership(ctx context.Context) error` — `GetUserConversations` → `db.ReplaceSlackMembership` → `o.scope`. Any listing error, or `ErrEmptyMembership`, leaves `o.scope` as it was (unknown on a fresh process) and returns the error.
  - The forward pipeline (`runOwnScopeSync`), in this order: `client.BeginCycle()`; `ensureWorkspace` + team check (unchanged); `refreshMembership`; the mention query `fmt.Sprintf("<@%s> after:%s", ownerRaw, searchAfter)` through today's `syncViaSearch` window, watermark, gap note and `FirstSyncFrom` logic, with `diffLiveWindow` removed from it; `runLanes` (skipped when membership is unknown); the sweep, read state, roster and reactions as today.
  - First sync: when `firstSync` was read true and the mention search did not complete, the cycle ends before `runLanes` (nothing saved, so the next cycle is still a first sync).
  - The mention lane is skipped with the gap note `"mentions outside your channels not synced: <reason>"` when `CurrentUserID` is empty or page 1 fails for a non-rate-limit reason (missing `search:read`); the lanes still run. Under `ScopeOwn` the "search failed → full sync" and "zero channels → full sync" fallbacks do not run (Owner decision 9 (a)).
  - `SearchIncomplete()` keeps its name and now means "this cycle left own-scope data unfetched": the mention search incomplete, `runLanes` returned `complete = false`, or the cycle ended on `ErrCycleRateLimited` (the daemon's INBOX-09 freeze keeps working unchanged).
  - `func (o *Orchestrator) RateLimitedOut() bool` — `slackClient.CycleRateLimited()`; when true `run` returns nil right after the failing step, skips `finishSync` (no `TouchSyncedAt`), and records the note `"slack sync: rate-limited twice; retrying next cycle"` (the `searchRateLimited` precedent, which this replaces).

- [ ] **Step 1: Write the failing tests** (`ownscope_cycle_test.go`, fake clock):
  - `TestOwnScope_MembershipChange`: cycle 1 member of `C0MEMBER`, `C0OTHER`; cycle 2 listing drops `C0OTHER`: no history call for it, `is_member = 0`, its stored messages still there.
  - `TestOwnScope_MentionOutsideMembership`: a mention match in non-member `C0OTHER` is stored; a plain match there (from the sweep fixture) is not.
  - `TestOwnScope_SecondRetryAfterEndsCycle` (synctest): 429 on `users.conversations`, then a 429 on the first history call; asserts no further Slack call in the cycle, `search_last_date` and every `sync_state` unchanged, `SearchIncomplete()` and `RateLimitedOut()` true, `slack_accounts` error carries the note, `TouchSyncedAt` not called; the next cycle runs normally.
  - `TestOwnScope_MembershipRefreshFailsSkipsLanes`: `users.conversations` fails on a fresh orchestrator; no history call, the mention lane still runs, `SearchIncomplete()` true.
  - `TestOwnScope_FirstSyncWaitsForMentionSearch`: fresh account, mention search rate-limited on page 1; no lane call, no message stored; the next cycle is still a first sync and `FirstSyncFrom()` is set after it completes.
  - `TestOwnScope_MentionLaneSkippedWithoutOwner`: empty `CurrentUserID` and `auth.test` failing; lanes run, the gap note is recorded.
  - `TestOwnScope_RestartRunsBothLanes`: a new `Orchestrator` over a DB with `sync_state` rows fetches member channels in its first cycle, within the budget.
  - `TestOwnScope_NoFullSyncFallback`: search answers `missing_scope`; no `conversations.list` call; DMs and member channels still fetched.
  - `TestScopeAll_Unchanged`: a `ScopeAll` orchestrator sends exactly today's calls (`after:D` blanket search, no `users.conversations`), and a second 429 does not end its cycle.
  - BACKFILL-01 twins: `TestBACKFILL01_OwnScopeFirstSyncFrom` (value = local midnight of `D + 1`, read from the mention query's `after:` token, in a UTC+9 zone), `TestBACKFILL01_OwnScopeRateLimitedFirstRunIsNotAFirstSync`, `TestBACKFILL01_OwnScopeAccountWithMessagesIsNotAFirstSync`.
  - `TestScopeForBuild` (`""`/`dev` → `ScopeOwn`, `corp` → `ScopeAll`) and `cmd/sync_scope_test.go::TestWireSlackOrchestrators_SetsScopeByBuild`.
- [ ] **Step 2: Run** `go test ./internal/sync -run 'TestOwnScope_'` — FAIL.
- [ ] **Step 3: Implement**; replace Task 3's temporary filter guard with `o.mode == ScopeOwn`.
- [ ] **Step 4: Run** `go test ./internal/sync ./internal/daemon ./internal/repl` and `go test ./cmd -run 'TestWireSlackOrchestrators|Sync'` — PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(sync): own-scope forward cycle — membership, mentions, two speeds (#1709)`.

### Task 6: Deletions from conversation listings

**Depends on:** Task 4, Task 5; approval of the SRCDEL extension above (Owner decision 10 (a); with (b) this task is dropped and the feature note says recent deletions wait for the sweep)

**Files:**
- Modify: `internal/sync/deletions.go` (the per-conversation diff next to `tombstoneMissing`), `internal/sync/ownscope_lanes.go` (call the diff after a complete `Forward`)
- Test: new `internal/sync/deletions_history_test.go`. `internal/sync/deletions_test.go` stays untouched (its search-listing guards keep covering `ScopeAll`)

**Interfaces:**
- Consumes: `fetchResult.Listing` and `historyListing` (Task 4).
- Produces: `func (o *Orchestrator) tombstoneMissingInConversation(l *historyListing) error` — judges the account's stored plain messages of that one conversation in `[now − rereadWindow, now − liveDiffLag)`, through `sourcediff.Check(len(stored), listed, len(missing), sourcediff.SlackFloors)`, then `db.TombstoneSlackMessages`. A conversation whose `Forward` failed, was cut by the budget, a cancel or `ErrCycleRateLimited` is never judged.

- [ ] **Step 1: Write the failing tests**: `TestHistoryDiff_TombstonesMissingRow`, `TestHistoryDiff_SkipsIncompleteListing` (page 2 fails → nothing tombstoned), `TestHistoryDiff_SkipsOverHalf`, `TestHistoryDiff_SkipsEmptyListing`, `TestHistoryDiff_OnlyItsConversation` (another channel's rows untouched), and the twin guard `TestSRCDEL02_OwnScopeReturningMessageHeals` (a `ScopeOwn` orchestrator: tombstoned in cycle 1, returned by history in cycle 2, healed).
- [ ] **Step 2: Run** `go test ./internal/sync -run 'TestHistoryDiff_|TestSRCDEL02_|TestLiveDiff_'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `go test ./internal/sync ./internal/sourcediff ./internal/db -run 'Tombstone|SRCDEL|Diff'`, then `go test ./internal/sync` — PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(sync): Slack live diff from conversation listings (#1709)`.

### Task 7: Backfill over the own scope

**Depends on:** Task 4, Task 5 (and so the spike gate)

**Files:**
- Modify: `internal/sync/search_sync.go` (`BackfillSearch`), `internal/daemon/history_backfill.go` (`slackSource.Fetch`), `internal/slackbackfill/run.go` (one `BeginCycle` per chunk under `ScopeOwn`), `cmd/slack_backfill.go` if it wires the client
- Test: `internal/sync/ownscope_backfill_test.go`, `internal/daemon/history_backfill_test.go`, `internal/slackbackfill/run_test.go`

**Interfaces:**
- Consumes: `conversationFetcher.Range`, `refreshMembership`, `RateLimitedOut` (Tasks 4, 5).
- Produces:
  - `BackfillSearch(ctx, from, to) (int, error)` keeps its name and signature (the `slackbackfill.Fetcher` interface and the inventory's module list stay valid); under `ScopeAll` it is today's blanket search, and under `ScopeOwn` it: refreshes membership when `o.scope` is unknown; runs the mention query `<@U> after:… before:…` (today's `slackSearchRange` widening) through the filtered `searchAndSave`; then `Range(from, to)` for each own-scope conversation not yet done for this chunk. Done conversations are kept in memory per chunk (`o.chunkDone map[[2]int64]map[string]bool`, keyed by `from`/`to` unix seconds, the entry dropped when the chunk completes). Any error, budget expiry, `ErrCycleRateLimited` or an incomplete search returns an error wrapping `ErrBackfillIncomplete` (→ `historybackfill.ErrHold`, no strike).
  - `slackSource.Fetch` returns a hold at once, without a Slack call, when `s.o.RateLimitedOut()` (the cycle's forward sync ended on the second 429).
  - Only conversations whose `LastActive` or membership makes them in scope today are backfilled; a conversation with no message in the chunk costs one call (the v1 price, noted in the feature note).

- [ ] **Step 1: Write the failing tests**: `TestOwnScopeBackfill_FetchesOnlyOwnScope` (a non-member channel gets no history call; the mention query carries `after:`/`before:`), `TestOwnScopeBackfill_ResumesHeldChunk` (chunk cut after 2 of 4 conversations by `ErrCycleRateLimited`; the error wraps `ErrBackfillIncomplete`; the retry fetches only the other 2), `TestOwnScopeBackfill_RestartRefetchesChunk` (a new orchestrator fetches all 4, rows equal, no duplicate), `TestOwnScopeBackfill_NoSyncStateWrites`, `TestSlackBackfillSource_HoldsAfterSecondRateLimit` (daemon), `TestSlackBackfillCLI_BeginsCyclePerChunk`, `TestBackfillSearch_ScopeAllUnchanged` (one blanket `after: before:` query, no `users.conversations`).
- [ ] **Step 2: Run** `go test ./internal/sync ./internal/daemon ./internal/slackbackfill -run 'OwnScopeBackfill|SlackBackfillSource|SlackBackfillCLI'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `go test ./internal/sync ./internal/slackbackfill ./internal/historybackfill` and `go test ./internal/daemon -run 'Backfill|FirstSync'` — PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(backfill): Slack history backfill over the own scope (#1709)`.

### Task 8: Guide, feature notes, inventory

**Depends on:** Task 5, Task 6, Task 7 (the text describes the merged behaviour); merge after the screens plan's S6 guide edit if that lands first, rebasing onto it

**Files:**
- Modify: `docs/guide/concepts/sources-and-accounts.md` (Slack row: "Your DMs and group DMs, mentions of you anywhere, and the channels you are a member of, plus your own reactions"; one `###` section "Public channels you are not in": they are no longer stored on this Mac, what was synced before stays, digests, Catch-Up, people cards and Knowledge no longer get them, the assistant reaches them through Live when your Claude or ChatGPT Slack connector is on; `<!-- learn: none -->` unless it teaches a step; it describes the public build — the corp build keeps syncing as before, so say once "Builds managed by your organization may sync more"), `docs/guide/concepts/how-watchtower-works.md` (the "Slack messages" row: "DMs, group DMs and mentions every cycle; your channels about hourly"), `docs/guide/concepts/history-backfill.md` (Slack backfill covers your DMs, mentions and channels only)
- Create: `docs/features/slack-own-scope.md` (architecture, the seam and the spike follow-up, lanes and constants, writers table, failure table, v1 limits: per-conversation Tier-3 cost and what it means for large workspaces, replies older than `rereadWindow`, quiet DMs, other processes do not share the account's limiter)
- Modify: `CLAUDE.md` (one line under Feature Notes), `docs/features/README.md` (one-paragraph summary), `docs/features/slack-multi-account.md`, `docs/features/history-backfill.md` (Slack fetch), `docs/features/source-deletions.md` (Slack live diff), `docs/inventory/history-backfill.md` (BACKFILL-01: the own-scope first sync added, the twin guards listed, changelog line), `docs/inventory/source-deletions.md` (SRCDEL-01/02: the history listing kind added, the twin guards listed, changelog line); the feature note also records the Capacity table and the decisions the owner took

- [ ] **Step 1:** Write the pages per `docs/guide/WRITING.md` (rule 6: check every number against the constants in `ownscope_lanes.go`). `sources-and-accounts.md` is close to the 8 KB cap: measure with the cards stripped; if it would pass 8192 bytes, put the section into `how-watchtower-works.md` instead and link it from the row.
- [ ] **Step 2: Run** `go test ./docs/guide/ ./internal/kb/ ./internal/chat/ ./internal/learn/` — PASS (regenerate the chat prompt golden only if a page title changed: `go test ./internal/chat -run TestBuildSystemPrompt_Golden -update`).
- [ ] **Step 3: Commit** `docs: own-scope Slack sync in the guide, notes and inventory (#1709)`.

## Promises → tasks → tests

| Promise (spec) | Task | Test |
|---|---|---|
| Full syncs only the own scope (D3) | 3, 5 | `TestScopeFilter_SearchSavesOnlyOwnScope`, `TestOwnScope_MembershipChange` |
| DMs and mentions every 15 min, member channels every 60 min (D12) | 4, 5 | `TestPlanLanes_TwoSpeeds`, `TestOwnScope_RestartRunsBothLanes` |
| Mentions arrive from channels the user is not in | 3, 5 | `TestOwnScope_MentionOutsideMembership` |
| `users.conversations` once a cycle; a left channel stops syncing, its data stays (§7) | 2, 5 | `TestOwnScope_MembershipChange`, `TestReplaceSlackMembership_SetsAndClears` |
| `Retry-After` holds every call of the account | 1 | `TestDoRequest_RetryAfterHoldsEveryMethod` |
| A second 429 ends the cycle (§7) | 1, 5, 7 | `TestDoRequest_SecondRateLimitEndsCycle`, `TestOwnScope_SecondRetryAfterEndsCycle`, `TestSlackBackfillSource_HoldsAfterSecondRateLimit` |
| Backfill over the own scope, one chunk per cycle | 7 | `TestOwnScopeBackfill_FetchesOnlyOwnScope`, `TestOwnScopeBackfill_ResumesHeldChunk` |
| Public non-member channels leave the local copy; the guide says so | 3, 8 | `TestScopeFilter_SweepSavesNothingOutOfScope`, `go test ./docs/guide` |
| The narrowing method can change after the spike without rework | 4 | the seam (`conversationFetcher`); no test of option 1 here |

Failure modes (owner rule): app or Mac closed mid-cycle — `TestOwnScope_CancelMidLaneResumes`; mid-way failure — `TestOwnScope_LostChannelIsSkipped`, `TestHistoryDiff_SkipsIncompleteListing`, `TestOwnScope_MembershipRefreshFailsSkipsLanes`; restart — `TestOwnScope_RestartRunsBothLanes`, `TestPlanLanes_RestartStaysInBudget`, `TestOwnScopeBackfill_RestartRefetchesChunk`.

## Phase gate (controller, once)

`make test`, `go test ./cmd/...`, `make lint-all`; then the local-review skill on the whole branch. No Swift or phone code changes in this plan, so `make test-swift` runs only as part of the pre-PR gate.
