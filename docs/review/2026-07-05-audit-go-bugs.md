# Server-side (Go) bugs — audit 2026-07-05

The audit covers the entire Watchtower Go backend: the sync orchestrator (Slack/Jira/Calendar), the DB layer and migrations, the AI pipelines (digest, tracks, inbox, briefing, dayplan, people), CLI commands, and the claude/codex provider integration. Method: several independent search agents (by subsystem) generated candidates, after which each finding went through independent adversarial verification with execution-path tracing through the code; refuted findings were removed from the report. Result: 8 High, 23 Medium, 23 Low, 0 Critical.

## High

### Migration 00002 silently wipes the entire inbox_feedback table via a DROP TABLE cascade

- **Where:** `internal/db/migrations/00002_target_due_inbox.sql:48`
- **Verification status:** ✅ confirmed

Expanding the `trigger_type` enum recreates `inbox_items` via the classic DROP/RENAME "dance". But `db.Open` enables `PRAGMA foreign_keys=ON` on the single pooled connection before goose even runs, and `inbox_feedback` is declared with `inbox_item_id ... REFERENCES inbox_items(id) ON DELETE CASCADE`. In SQLite, `DROP TABLE` performs an implicit `DELETE FROM`, which triggers FK actions, and `PRAGMA defer_foreign_keys=ON` only defers VIOLATION checks, not CASCADE actions. As a result, `DROP TABLE inbox_items` cascades and deletes all `inbox_feedback` rows. Any user upgrading a legacy (pre-goose) database with accumulated 👍/👎 feedback loses their entire inbox-learning history the moment 00002 is applied. Reproduced empirically on the project's driver (modernc.org/sqlite): after the exact statement sequence, the `inbox_feedback` count drops 2 → 0, while `inbox_items` survives. The down migration has the identical defect; there are no tests for `inbox_feedback` surviving this migration. The comment in the migration itself ("reference survives the DROP/RENAME dance") is wrong: only the schema reference survives — the rows are deleted.

```sql
PRAGMA defer_foreign_keys = ON;
...
INSERT INTO inbox_items_new SELECT * FROM inbox_items;
DROP TABLE inbox_items;
ALTER TABLE inbox_items_new RENAME TO inbox_items;
-- repro: sqlite3 with foreign_keys=ON → 'feedback rows after dance:|0'
```

- **Recommendation:** Use the canonical table-recreation idiom from the SQLite docs: temporarily turn `PRAGMA foreign_keys=OFF` off before the transaction (instead of `defer_foreign_keys`), do the DROP/RENAME, then `PRAGMA foreign_key_check` and turn it back `ON`. Fix both Up and Down; add a regression test that seeds rows into `inbox_feedback` before 00002 and checks they survive.

### The search_last_date watermark advances to "today" even on an early pagination abort — missed messages are lost forever

- **Where:** `internal/sync/search_sync.go:181`
- **Verification status:** ✅ confirmed

`syncViaSearch` paginates `search.messages` in ascending timestamp order (page 1 is the oldest messages). On any non-fatal error mid-pagination (`RateLimitedError` after 3 `doRequest` retries, `missing_scope`, `access_denied`, etc.) the loop `break`s and falls through to an unconditional `SetSearchLastDate(today)` — even if it stopped on page 1 of 50. The next incremental sync requests `after: today-2d`, so every message on the unfetched pages older than `today-2d` will never be fetched again. Since search-sync is the DEFAULT path, including the first run, hitting a rate limit early in the initial 30–60-day window sync silently and irrecoverably loses weeks of history. Contrast: the `conversations.history` path deliberately does NOT advance `LastSyncedTS` until every page has been drained (message_sync.go:325-330); the search path has no equivalent guard. Context cancellation correctly returns before the watermark write — only the non-fatal break is affected.

```go
if isNonFatalError(err) {
    o.logger.Printf("search sync: non-fatal error on page %d, stopping early: %v", page, err)
    break
}
...
// Advance the watermark to today.
today := time.Now().Format("2006-01-02")
if err := o.db.SetSearchLastDate(today); err != nil {
```

- **Recommendation:** Introduce a `completed` flag and only advance `search_last_date` after a full pass through all pages; on an early break, either leave the watermark alone entirely or set it to the date of the last message actually processed. Additionally, surface the partial-sync fact upward (log + LastSyncResult) so the failure doesn't look like a success.

### Token without the search:read scope: after the first sync, every incremental cycle silently syncs zero messages while reporting success

- **Where:** `internal/sync/orchestrator.go:167`
- **Verification status:** ✅ confirmed

When `search.messages` returns `missing_scope` (non-fatal), `syncViaSearch` breaks on page 1 and returns `nil` — so the explicit fallback branch `if isNonFatalError(err) { ... return o.runFullSync }` (orchestrator.go:156-159) is unreachable for Slack search errors: `syncViaSearch` never returns them. The only remaining fallback is the `DiscoveryChannels==0` check, which switches to a full sync ONLY when the DB is empty (zero channels). Scenario for a token without `search:read` (e.g. a bot token): first daemon cycle → DB empty → falls back to full sync, which populates channels; every subsequent cycle → search fails non-fatally → 0 messages → `stats.ChannelCount > 0` → fallback doesn't fire → `finishSync()` calls `TouchSyncedAt()`, and Desktop shows a fresh, successful sync. Data goes permanently stale with zero error visibility (the daemon phase `phaseSlackSync` gets `err=nil`). The test `TestRunSearchSyncFallsBackOnNonFatalError` only covers the empty-DB case and masks the problem. On top of that, the watermark still advances to "today" every cycle regardless (search_sync.go:181).

```go
snap := o.progress.Snapshot()
if snap.DiscoveryChannels == 0 {
    stats, err := o.db.GetStats()
    if err != nil || stats.ChannelCount == 0 {
        o.logger.Println("search found 0 channels, falling back to full sync")
        return o.runFullSync(ctx, opts)
    }
}
```

- **Recommendation:** `syncViaSearch` should return a typed error (or flag) for Slack-level non-fatal search failures, so the fallback branch in `runSearchSync` actually fires and switches to a full sync regardless of whether the DB is already populated. Add a test with pre-populated channels and `missing_scope`.

### Inbox deduplication merges unrelated items of different trigger types, silently "resolving" pending mentions and DMs

- **Where:** `internal/db/inbox.go:328`
- **Verification status:** ✅ confirmed

`DeduplicateThreadInboxItems` (Phase 0 of every inbox `Run` and `RunFastDetection`) groups pending items only by `(channel_id, thread_ts)`, without regard to `trigger_type`. All non-threaded items have `thread_ts=''`. A `decision_made` watchtower item stores the digest's real Slack `channel_id` with `thread_ts=''` (watchtower_detector.go:127), so when a user has a pending non-threaded `mention`/`dm` in channel C and a `decision_made` item is later created for that same channel, the next dedup cycle keeps only `MAX(id)` (the decision) and flips the pending mention to `status='resolved', resolved_reason='Merged duplicate'` — the actionable mention disappears from the feed without any user action. Two different important decisions in the same channel get merged into one the same way, and a `calendar_invite` + `calendar_time_change` pair for one event collapses too. There are no tests for `DeduplicateThreadInboxItems`.

```sql
UPDATE inbox_items SET status = 'resolved', resolved_reason = 'Merged duplicate'
  WHERE status = 'pending'
  AND id NOT IN (SELECT MAX(id) FROM inbox_items WHERE status = 'pending' GROUP BY channel_id, thread_ts)
  AND EXISTS (SELECT 1 FROM inbox_items i2 WHERE i2.channel_id = inbox_items.channel_id AND i2.thread_ts = inbox_items.thread_ts ...)
```

- **Recommendation:** Add `trigger_type` to the GROUP BY/EXISTS (and probably exclude non-threaded items with `thread_ts=''` from dedup entirely — dedup only real threads). Cover with a test for the "mention + decision_made in the same channel" scenario.

### Day-plan renders calendar events in UTC while validation and "now" are local: AI timeblocks get discarded for every non-UTC user

- **Where:** `internal/dayplan/prompt.go:213`
- **Verification status:** ✅ confirmed

`shortTime` formats an event's start/end via `t.UTC().Format("15:04")`, so for a UTC+3 user (this project's user) a 10:00–11:00 local meeting is shown to the AI as "07:00–08:00". Meanwhile `NowLocal` and working hours in the prompt are local, and the AI-returned times are parsed via `time.ParseInLocation(..., time.Local)` (merge.go:57). The AI avoids the phantom 07:00–08:00 slot and freely places a block at 10:00 local time — which the overlap check in `aiToTimeblock` (merge.go:75, comparing absolute times against the correctly-UTC-parsed event) then discards as "timeblock overlaps calendar event". Every meeting is shifted in the prompt by the UTC offset, so plans systematically lose blocks around real meetings and plan nothing around phantom ones. Cf. `formatCalendarEvent` in briefing (briefing/pipeline.go:552), which correctly calls `.Local()`.

```go
func shortTime(iso string) string {
	for _, layout := range []string{time.RFC3339, "2006-01-02T15:04:05Z", "2006-01-02T15:04:05"} {
		if t, err := time.Parse(layout, iso); err == nil {
			return t.UTC().Format("15:04")
		}
	}
```

- **Recommendation:** Replace `t.UTC()` with `t.Local()` in `shortTime` so the prompt, validation, and "now" all live in the same timezone (following the briefing pattern). Add a test with a non-UTC location that checks a block at the time of a real meeting gets discarded, while one outside it gets accepted.

### All-day events are not excluded from day-plan overlap validation — one all-day event kills every AI timeblock

- **Where:** `internal/dayplan/merge.go:69`
- **Verification status:** ✅ confirmed

The calendar client stores all-day events as StartTime=UTC midnight of the day, EndTime=UTC midnight of the next day with `IsAllDay=true` (calendar/client.go:271-286), and `GetCalendarEventsForDate` returns them. Neither the overlap loop in `aiToTimeblock`, nor `DetectConflicts` (conflicts.go:41), nor `syncCalendarItems` (calendar_sync.go:42) checks `ev.IsAllDay`. With any all-day event on the calendar (a birthday, OOO, holiday — a very common case), `timesOverlap(start, end, 00:00Z, 24:00Z)` is true for every timeblock within working hours: `buildItems` discards ALL AI timeblocks ("overlaps calendar event"), `DetectConflicts` flags every remaining block as conflicting, and `syncCalendarItems` inserts the all-day event as a fake 1440-minute timeblock. Contrast: `PrepareForNext` in meeting explicitly skips `ev.IsAllDay` (meeting/pipeline.go:115), and briefing labels them "All day" — dayplan is the outlier here.

```go
for _, ev := range events {
	evStart := parseEventTime(ev.StartTime)
	evEnd := parseEventTime(ev.EndTime)
	if evStart.IsZero() || evEnd.IsZero() { continue }
	if timesOverlap(start, end, evStart, evEnd) {
		return nil, fmt.Sprintf("timeblock %q overlaps calendar event %q", ai.Title, ev.Title)
	}
}  // no ev.IsAllDay check
```

- **Recommendation:** Add `if ev.IsAllDay { continue }` in all three places (aiToTimeblock, DetectConflicts, syncCalendarItems) — following the pattern in meeting/pipeline.go:115. Test: one all-day event plus a regular meeting, verify blocks are discarded only because of the meeting.

### Incremental Jira sync compares a UTC watermark against JQL interpreted in the user's timezone — updates are permanently missed for profiles west of UTC

- **Where:** `internal/jira/sync.go:107`
- **Verification status:** ✅ confirmed

`Sync()` stores the watermark in UTC (`time.Now().UTC().Format(RFC3339)`) and builds the incremental JQL as `updated >= "2006-01-02 15:04"` with no timezone. Jira interprets a timezone-less JQL datetime in the Jira user's profile timezone, not UTC. For a profile west of UTC (e.g. UTC-5), "12:00" means 17:00 UTC — the effective window starts hours LATER than the real watermark. An issue updated at 13:00 UTC is missed by the current cycle, and since the watermark then advances to "now," the effective start of every subsequent query is even later — the update will never be fetched until the issue is edited again. For timezones east of UTC, the window merely shifts earlier (a harmless re-fetch). Net effect: `jira_issues` silently goes stale for any Jira profile west of UTC; the two-minute overlap does not cover a multi-hour offset.

```go
t = t.Add(-2 * time.Minute)
jql = fmt.Sprintf("project = %s AND updated >= \"%s\" ORDER BY updated ASC",
    projectKey, t.Format("2006-01-02 15:04"))
```

- **Recommendation:** Look up the account's timezone via `/rest/api/3/myself` and convert the watermark to it before formatting the JQL (or use the timezone-independent relative syntax `updated >= -Nm`). Add a test pinning the JQL format.

### SyncBoard advances the project watermark after syncing only unresolved issues — closed ones are never backfilled, contradicting its own documentation

- **Where:** `internal/jira/sync.go:190`
- **Verification status:** ✅ confirmed

`SyncBoard` (invoked by `jira sync --board`, which Desktop runs when a board is selected — JiraBoardSyncManager.swift:62) syncs via the JQL `statusCategory != Done`, then calls `UpdateJiraSyncState(projectKey, now, n)`. The doc comment claims "Terminal/closed issues are picked up by the daemon's regular Sync() cycle," but the regular `Sync()` is incremental from this watermark (`updated >= now-2min`), so historical Done issues — updated in the past — will never be fetched. `InitialLoad()`, which would perform a full backlog fetch, has zero callers anywhere in the repo. Every board connected via Desktop (the primary onboarding path) is permanently missing closed-issue history — breaking epic progress, release dashboards, and any velocity query counting done work.

```go
jql := fmt.Sprintf("project = %s AND statusCategory != Done ORDER BY updated ASC", board.ProjectKey)
...
now := time.Now().UTC().Format(time.RFC3339)
_ = s.db.UpdateJiraSyncState(board.ProjectKey, now, n)
```

- **Recommendation:** Either don't write the watermark from `SyncBoard` at all (leaving the first full `Sync()` to the daemon — which does a full fetch when there's no state), or call `InitialLoad()` when a board is first connected. At minimum, fix the doc comment and add a test that "after SyncBoard, the daemon picks up historical Done issues."

## Medium

### `targets --status done|dismissed` always returns an empty list: the done/dismissed exclusion is AND'd with the status filter

- **Where:** `cmd/targets.go:342`
- **Verification status:** ✅ confirmed

The `--status` flag's help text explicitly lists `done` and `dismissed` as valid values, but `runTargetsList` only sets `IncludeDone` from `--all`. In `db.GetTargets`, when `IncludeDone=false` the query gets both `status NOT IN ('done','dismissed')` AND `status = ?`, which for `--status done|dismissed` is a contradiction: the query matches nothing. A user running `watchtower targets --status done` always sees "No targets found." regardless of the data, until they figure out they need to add `--all`. (The verifier downgraded severity to medium: a real, reachable bug on a documented flag, but with no data loss and a workaround.)

```go
f := db.TargetFilter{
    Status:      targetsFlagStatus,
    ...
    IncludeDone: targetsFlagAll,
}
// db/targets.go: if !f.IncludeDone { conditions = append(conditions, "status NOT IN ('done','dismissed')") }
// if f.Status != "" { conditions = append(conditions, "status = ?") }
```

- **Recommendation:** In `runTargetsList`, set `IncludeDone=true` whenever `--status` is explicitly `done` or `dismissed` (or, in `GetTargets`, skip the exclusion when `f.Status` is set). Add a test for `--status done`.

### UnsnoozeExpiredInboxItems compares a date-only string against the full ISO datetime written by Desktop — short snoozes last until the next UTC day

- **Where:** `internal/db/inbox.go:246`
- **Verification status:** ✅ confirmed

The daemon's unsnooze uses `today := time.Now().UTC().Format("2006-01-02")` and `WHERE ... snooze_until <= ?`. But the macOS app writes `snooze_until` as a full ISO-8601 datetime: `.oneHour → iso8601String(now+1h)`, e.g. `"2026-07-05T14:23:11Z"` (InboxFeedView.swift:295 via InboxQueries.snooze). Lexicographically, `"2026-07-05T14:23:11Z" > "2026-07-05"` all day long, so an item snoozed for 1 hour in the Desktop UI stays hidden until the daemon's first run on the NEXT UTC day. There's no Swift-side unsnooze — this Go query is the only mechanism. The neighboring `UnsnoozeExpiredTargets` (targets.go:338) correctly uses minute resolution `2006-01-02T15:04` — inbox is the outlier here.

```go
today := time.Now().UTC().Format("2006-01-02")
... WHERE status = 'snoozed' AND snooze_until != '' AND snooze_until <= ?`, today)
// Desktop writes: until = iso8601String(cal.date(byAdding: .hour, value: 1, to: now) ?? now)
```

- **Recommendation:** Compare against the full timestamp (`time.Now().UTC().Format(time.RFC3339)` or at least minute resolution `2006-01-02T15:04`, as in targets) — date-only values still compare correctly with `<=` against a full timestamp.

### A tracks run with 100% failed AI batches still reports success, advancing the incremental watermark and permanently skipping those digests

- **Where:** `internal/tracks/pipeline.go:314`
- **Verification status:** ✅ confirmed

`runTrackBatches` only logs per-batch AI errors (line 576), and `RunForWindow` always returns a nil error. If ALL batches fail (e.g. a transient claude CLI outage / rate limit after the digest phase already ate the quota), `tracks.Run` returns `(0, 0, nil)`, the daemon records the run with status='done' (daemon.go:287), and `GetLatestPipelineRunStartedAt/PeriodTo` (which filter on status='done') advance the tracks watermark. The next incremental run only picks up digests created after the failed run's started_at — every digest topic from the failed window is never scanned for tracks again: a silent, permanent extraction gap. Contrast: the digest pipeline deliberately returns an error when `gen==0 && errs>0` (digest/pipeline.go:781-783) precisely to avoid this.

```go
return totalStored, nil //nolint:nilerr // partial results returned; per-batch errors logged above
// runTrackBatches: p.logger.Printf("tracks: error in batch %d/%d: %v", …) — error never propagated
```

- **Recommendation:** Mirror the digest pipeline's guard: if 0 tracks were stored and there were batch errors, return an error from `RunForWindow` so the daemon records the run as failed and the watermark doesn't advance.

### The codex generator reads the pipeline source from the wrong context key — ModelForSource routing is dead

- **Where:** `internal/codex/generator.go:38`
- **Verification status:** ✅ confirmed

All pipelines tag AI calls via `digest.WithSource(ctx, source)`, which stores the label under the unexported type `digest.sessionSourceKey{}` (digest/pooled.go:69-74). `CodexGenerator.Generate` declares its OWN `type sessionSourceKey struct{}` in the codex package and does `ctx.Value(sessionSourceKey{})` with it. Context keys are compared by dynamic-type identity; `codex.sessionSourceKey` and `digest.sessionSourceKey` are different types, so the lookup ALWAYS returns nil. Consequence: for every codex-provider user, `ModelForSource` is never invoked — light sources (`digest.SourceLight`, "inbox.prioritize", "digest.channel_batch", "people.batch", etc.) are never routed to gpt-5.4-mini; every pipeline call goes to the default model, contrary to the contract in pooled.go and the project docs. models_test.go only tests `ModelForSource` as a pure function, so the broken wiring isn't covered.

```go
// codex/generator.go:20,38
type sessionSourceKey struct{}
...
if s, ok := ctx.Value(sessionSourceKey{}).(string); ok && s != "" {
    model = ModelForSource(s)
}
// digest/pooled.go:69-73 (the actual key used by all callers)
type sessionSourceKey struct{}
func WithSource(ctx context.Context, source string) context.Context {
    return context.WithValue(ctx, sessionSourceKey{}, source)
}
```

- **Recommendation:** Export a `SourceFromContext(ctx) (string, bool)` function from the digest package and use it in the codex generator (removing the local duplicate type). Add an integration test: `digest.WithSource` → `CodexGenerator` selects the mini model.

### Store.Seed silently overwrites user-customized prompts when the built-in default's version is bumped

- **Where:** `internal/prompts/store.go:90`
- **Verification status:** ✅ confirmed

The auto-upgrade branch's comment promises to update only "if ... the user hasn't customized the template," but the code checks nothing beyond `existing.Version < defaultVer` — there's no template comparison. `db.UpdatePrompt` increments the version by +1 from the current one. Scenario: a prompt is seeded with DefaultVersions=3; the user customizes it via `prompts tune`/Update → v4; a release bumps DefaultVersions to 5 (actual values in defaults.go go up to 5, e.g. BriefingDaily); on the next Seed (every startup) 4 < 5 — the tuned template is silently replaced by the built-in default. The guard test `TestSeedIdempotentWithExisting` only covers the case where the custom version is already higher than the default, so the destructive path is untested. The old text survives only in `prompt_history` (recoverable via Rollback), but the loss happens silently.

```go
// Auto-upgrade: if the default version is higher and the user hasn't
// customized the template (i.e., it still matches a previous default),
// update it to the new default.
if existing.Version < defaultVer {
    if err := s.db.UpsertPrompt(db.Prompt{
        ID:       id,
        Template: tmpl,
        Version:  defaultVer,
    }); err != nil { ...
```

- **Recommendation:** Implement what the comment promises: upgrade only if the DB's current template matches some past default (store/compare default hashes), or introduce a `customized` flag set by UpdatePrompt/Tune. Add a test for "tuned prompt + bumped default → not overwritten."

### Archived stale inbox items stay status='pending' and leak into GetInboxItems, GetInboxCounts, and the daily briefing

- **Where:** `internal/db/inbox.go:700`
- **Verification status:** ✅ confirmed

`ArchiveStaleActionable` sets `archived_at/archive_reason='stale'` while deliberately leaving `status='pending'`. However `GetInboxItems` (the `watchtower inbox` CLI list), `GetInboxCounts` (pending/unread counters), and `GetInboxItemsForBriefing` (`WHERE status = 'pending' ... LIMIT 20`, injected into the daily briefing prompt) all filter only by status and never exclude `archived_at IS NOT NULL`. As a result, items archived by the pipeline as stale keep showing in the CLI, permanently inflate the pending count, and indefinitely occupy the 20-item inbox budget in the briefing — contrary to the archive lifecycle (actionable items should disappear once stale after 14 days). The newer feed queries (`ListActionableOpen`, `ListInboxFeed`, `ListInboxPinned`, `GetUnreadInboxItems`) all correctly add `archived_at IS NULL` — these three queries missed the pattern.

```sql
-- ArchiveStaleActionable:
UPDATE inbox_items SET archived_at=?, archive_reason='stale' ... WHERE ... status='pending' ...
-- vs GetInboxItemsForBriefing:
FROM inbox_items WHERE status = 'pending' ORDER BY ... LIMIT 20  -- no archived_at filter
```

- **Recommendation:** Add `AND archived_at IS NULL` to the three lagging queries (GetInboxItems, GetInboxCounts, GetInboxItemsForBriefing) and cover with a test for "archived-stale doesn't appear in briefing/counts."

### Level-2 topic dedup (the TRACKS-01 layer) is structurally dead: the pipeline stores source_refs as {ts,...}, but dedup expects {digest_id, topic_id}

- **Where:** `internal/tracks/pipeline.go:475`
- **Verification status:** ✅ confirmed

`buildRelevanceSignals` parses a track's source_refs expecting `{"digest_id":N,"topic_id":N}`, and only marks a topic as processed when both are > 0. But the extract prompt instructs the AI to emit source_refs as `{ts, channel_id, thread_ts, author, text}` (prompts/defaults.go:826,856), and `filterValidSourceRefs` (line 1703) re-marshals through a struct with only those fields, dropping any digest_id/topic_id. So every track this pipeline creates has ts-shaped refs, `processedTopics` is always empty, the "tracks: deduped %d topics already linked" branch never fires, and the TRACKS-01 layer documented in docs/inventory/tracks.md ("topics already linked to a track are stripped from the prompt") never engages. In overlap mode, already-linked topics get fed back to the AI every single run — wasted tokens, relying solely on fingerprint/Jaccard dedup, whose merges flip has_updates and resurface already-read tracks. The guard test `TestTopicDedupBySourceRefs` passes only because it manually seeds the legacy `{digest_id,topic_id}` shape (pipeline_test.go:1025), which production never writes.

```go
var refs []struct {
	DigestID int `json:"digest_id"`
	TopicID  int `json:"topic_id"`
}
…
if ref.DigestID > 0 && ref.TopicID > 0 {  // never true: filterValidSourceRefs only preserves {ts, channel_id, thread_ts, author, text}
```

- **Recommendation:** Align the source_refs shape between layers: either write digest_id/topic_id into refs when the track is saved (extending filterValidSourceRefs), or rewrite level-2 dedup to use (channel_id, ts) keys, which are actually present in the data. Rebuild the guard test on data the pipeline itself produces.

### Per-channel digest failures and "deferred" channels from the budget cap permanently lose their message window due to a global watermark

- **Where:** `internal/digest/pipeline.go:1575`
- **Verification status:** ✅ confirmed

`lastDigestTime()` takes the `period_to` of the single most recent channel digest across ALL channels as the global `sinceUnix` for the next run. When one channel's AI call fails (dispatchChannelBatches suffers partial failures, lines 779-784) or a channel's batch gets dropped by the budget cap maxBatches (line 715 logs "channels deferred," implying later processing), the successful channels still save digests with `period_to ≈ now`, so the next run's window starts AFTER the failed/deferred channel's undigested messages. Those messages are never re-selected (`GetMessagesByTimeRange` uses the new global since) — permanent per-channel digest gaps; the word "deferred" in the log is effectively a lie: nothing ever re-reviews them.

```go
digests, err := p.db.GetDigests(db.DigestFilter{Type: "channel", Limit: 1})
if err == nil && len(digests) > 0 { … return digests[0].PeriodTo }
// global watermark; cf. line 715: "budget cap: keeping %d of %d batches (%d channels deferred)"
```

- **Recommendation:** Switch to a per-channel watermark (the `period_to` of that specific channel's last digest) when selecting the message window — keep the global one only as a lower bound for discovery. Then failed/deferred channels automatically catch up on the next run.

### Channel digests that cross UTC midnight are excluded from all daily rollups

- **Where:** `internal/digest/pipeline.go:980`
- **Verification status:** ✅ confirmed

`runDailyRollupForDate` selects channel digests with the filter `{FromUnix: dayStart, ToUnix: dayEnd}`, which `GetDigests` translates into `period_from >= dayStart AND period_to <= dayEnd` (db/digests.go:104,108) — i.e. only digests that lie ENTIRELY inside the day. A digest whose window crosses UTC midnight (a normal case after a laptop sleeps overnight: yesterday's last digest at 23:00 UTC, the daemon's next cycle this morning creates one digest spanning "yesterday evening → this morning") fails today's rollup's `period_from >= dayStart`, while yesterday's rollup was already generated before that digest existed (and wouldn't have passed `period_to <= dayEnd` anyway). This content never makes it into any daily rollup — and thus never into weekly/briefing aggregation either.

```go
channelDigests, err := p.db.GetDigests(db.DigestFilter{Type: "channel", FromUnix: fromUnix, ToUnix: toUnix})
// GetDigests: "period_from >= ?" AND "period_to <= ?"
```

- **Recommendation:** Use a window-overlap criterion instead of strict containment: `period_to > dayStart AND period_from < dayEnd` (with protection against double-counting, e.g. attributing the digest to the day its `period_to` falls in). Alternatively, cut channel-digest windows at midnight during generation.

### The @mention signal in scoreChannel never matches key_messages (which only contains "bare" timestamps) — mention-only channels get skipped

- **Where:** `internal/tracks/pipeline.go:1438`
- **Verification status:** ✅ confirmed

`scoreChannel` checks `strings.Contains(t.KeyMessages, "<@"+userID+">")`. But digest's `storeDigest` saves `digest_topics.key_messages` through `filterValidTimestamps` (digest/pipeline.go:1336,1893), which keeps only strings matching `^\d{10}\.\d{6}$` — key_messages physically cannot contain `<@U…>`. Situations are prose with plain user IDs ("U123456"), not `<@…>` syntax. The documented relevance signal "+2: user @mentioned in key_messages or situations" (docs/inventory/tracks.md, TRACKS-02) is effectively dead. A channel where the user was directly @mentioned, but with no existing tracks, stars, reports/peers, or action_items, scores 0 and gets skipped before any AI call is made — tracks for direct mentions are silently never created. TestScoreChannel passes only because it manually feeds unfiltered KeyMessages, which production can never store.

```go
mentionTag := "<@" + userID + ">"
for _, t := range topics {
	if strings.Contains(t.KeyMessages, mentionTag) || strings.Contains(t.Situations, mentionTag) {
		// KeyMessages == JSON array of "1234567890.123456" only
```

- **Recommendation:** Derive the mention signal from real data: search for `"user_id":"<userID>"` in Situations (the participants JSON), or join messages by key_messages timestamps and search their text for `<@userID>`. Update the guard test to production-shaped data.

### calendar_time_change detection is dead code: synced_at gets updated on every sync, so updatedAt > syncedAt is never true

- **Where:** `internal/inbox/calendar_detector.go:95`
- **Verification status:** ✅ confirmed

The detector's `calendar_time_change` branch fires when `e.updatedAt > e.syncedAt` ("Event was modified after it was first synced"). But `UpsertCalendarEvent(s)` uses `INSERT OR REPLACE` and sets `synced_at = strftime('now')` on EVERY sync (db/calendar.go:85-90,109-113): synced_at is always the time of the last sync, which is always no earlier than Google's updated_at recorded during that same sync. The comparison is practically never true (barring clock skew), so a rescheduled meeting the user already accepted never produces a `calendar_time_change` inbox item — the trigger type exists in the schema, the classifier ('actionable'), and auto-resolve, but is unreachable in production. The only test for this branch seeds rows via a raw INSERT that bypasses the upsert, creating a state that's impossible in production.

```go
case e.updatedAt > e.syncedAt:
	// Event was modified after it was first synced — treat as a time/detail change.
	trig = "calendar_time_change"
// but upsert: INSERT OR REPLACE ... VALUES (..., strftime('%Y-%m-%dT%H:%M:%SZ','now'), ?) — synced_at reset every sync
```

- **Recommendation:** Store the previous updated_at in the table (e.g. `first_synced_at` or `prev_updated_at`, preserved in the ON CONFLICT update) and detect a change by comparing the new updated_at against the stored one, not against the sync's own timestamp. Rewrite the test to go through the real upsert path.

### A new Slack message can overwrite an unrelated pending item of a different trigger type via FindPendingInboxByThread

- **Where:** `internal/inbox/pipeline.go:508`
- **Verification status:** ✅ confirmed

`detectSlackTriggers` looks up an existing pending item only by `(channel_id, thread_ts)` — `FindPendingInboxByThread` (db/inbox.go:81) doesn't filter by trigger_type or Slack origin. A pending `decision_made` item shares `(channel_id=C, thread_ts='')` with any non-threaded Slack candidate in channel C. When a new top-level mention/DM arrives in C, the code takes the update path: `UpdateInboxItemSnippet` overwrites the decision item's message_ts, sender_user_id, snippet, raw_text, and permalink with the mention's content, while the row keeps trigger_type='decision_made' and item_class='ambient'. The actionable mention never gets its own item (created isn't incremented, and the NOT EXISTS dedup now matches the overwritten message_ts) — the @mention silently degrades into a mislabeled ambient decision card.

```go
existingID, _ := p.db.FindPendingInboxByThread(c.ChannelID, c.ThreadTS)
if existingID > 0 {
	if err := p.db.UpdateInboxItemSnippet(existingID, c.MessageTS, c.SenderUserID, snippet, itemCtx, c.Text, c.Permalink); ...
// query: WHERE channel_id = ? AND thread_ts = ? AND status = 'pending' — no trigger_type filter
```

- **Recommendation:** Add a trigger_type filter (or at least Slack types mention/dm/thread_reply) to `FindPendingInboxByThread`, and don't apply this lookup to non-threaded candidates (`thread_ts=''`). Same root cause as the dedup bug above — fix consistently.

### DetectJira lexicographically compares raw Jira timestamps (offset format) against a UTC-'Z' watermark — items can be lost permanently

- **Where:** `internal/inbox/jira_detector.go:44`
- **Verification status:** ✅ confirmed

`jira_issues.updated_at` stores `f.Updated` verbatim from the Jira API (jira/sync.go:536) — ISO8601 with milliseconds and a numeric offset, e.g. `2026-07-05T16:00:00.000-0400` (the `-0700` layout in briefing/jira.go confirms the format). The detector filters via a string comparison `updated_at > ?` against a sinceISO formatted as UTC RFC3339 (`2026-07-05T19:00:00Z`). A lexicographic comparison of offset strings against UTC strings isn't chronological: for a Jira instance with a negative offset, an issue updated at 20:00Z is stored as `...T16:00:00.000-0400` and sorts BELOW the watermark `...T19:00:00Z` — a freshly-updated issue gets skipped, and since the inbox watermark only moves forward, it will never be picked up. `autoResolveJira` has the same mixed-format comparison (pipeline.go:895-897): auto-resolve fires either early or never depending on the offset's sign.

```go
sinceISO := sinceTS.UTC().Format(time.RFC3339)
rows, err := database.Query(`SELECT key, summary, updated_at FROM jira_issues
    WHERE assignee_account_id = ? AND updated_at > ? AND is_deleted = 0`, currentUserID, sinceISO)
// sync stores: UpdatedAt: f.Updated (raw Jira '...+0300'/'-0400' format)
```

- **Recommendation:** Normalize `updated_at` to UTC RFC3339 when writing it in jira/sync.go (parsing the layout `2006-01-02T15:04:05.000-0700`), or parse and compare timestamps in Go instead of via a string SQL comparison. Audit all other places comparing Jira timestamps against 'Z'-format strings.

### Reactions on messages older than the watermark are never detected — the reaction trigger only works for ~30 minutes

- **Where:** `internal/db/inbox.go:525`
- **Verification status:** ✅ confirmed

`FindReactionRequests` filters on `m.ts_unix > sinceTS` — the MESSAGE's timestamp, not when the reaction was added (the reactions table has no timestamp column: only `PRIMARY KEY(channel_id, message_ts, user_id, emoji)`). In steady state the inbox watermark sits at ~now-30min, so once a message is ~30+ minutes old, any subsequent ❓/👀/‼️ reaction on it can no longer produce an inbox item. Since people typically react minutes-to-hours after a message is posted, "reaction request" detection is effectively dead outside a narrow window right after posting — a `:question:` on yesterday's message never surfaces. Existing tests only exercise `sinceTS=0`.

```sql
FROM messages m
JOIN reactions r ON r.channel_id = m.channel_id AND r.message_ts = m.ts
WHERE m.user_id = ? AND r.user_id != ? AND r.emoji IN (...) AND m.ts_unix > ?
-- reactions schema: PRIMARY KEY (channel_id, message_ts, user_id, emoji) — no reaction timestamp
```

- **Recommendation:** Add a `synced_at`/`first_seen_at` column to the reactions table (migration) and filter on that; as an interim measure, widen the message-age window to several days, relying on the existing NOT EXISTS dedup against duplicates.

### "Today's events" in briefing/day-plan use a UTC day window for a local date — early-morning events go missing

- **Where:** `internal/db/calendar.go:159`
- **Verification status:** ✅ confirmed

`GetCalendarEventsForDate` builds the window as `date+'T00:00:00Z' .. date+'T23:59:59Z'` (UTC), while every caller passes a LOCAL date: briefing's `gatherCalendar` uses `time.Now().Local().Format("2006-01-02")` (briefing/pipeline.go:535), dayplan's `Run/gatherCalendarEvents/DetectConflicts` use `time.Now().Format`-based dates. Event times are stored normalized to UTC. For this project's user (UTC+3), a meeting today at 01:00–02:00 local time is stored ending at 23:00Z of the PREVIOUS UTC day, so `end_time >= 'todayT00:00:00Z'` fails — the event is missing from the briefing's calendar section and from the day plan (no timeblock, no conflict detection); conversely, events from 00:00–03:00 local tomorrow leak into today's plan.

```go
func (db *DB) GetCalendarEventsForDate(date string) ([]CalendarEvent, error) {
	from := date + "T00:00:00Z"
	to := date + "T23:59:59Z"
	return db.GetCalendarEvents(CalendarEventFilter{FromTime: from, ToTime: to})
} // callers pass local dates: today := time.Now().Local().Format("2006-01-02")
```

- **Recommendation:** Build the window bounds from the local date: `time.ParseInLocation("2006-01-02", date, time.Local)`, then convert the local day's start/end to UTC RFC3339 for comparison. Add a test with a non-UTC zone and an event at 01:00 local time.

### limitedWriter in ai.Client violates the io.Writer contract — >64KB of stderr from claude turns a successful request into an error

- **Where:** `internal/ai/client.go:327`
- **Verification status:** ✅ confirmed

Once a single Write crosses the 64KB cap, `limitedWriter` truncates `p` and returns `n < len(p)` with `err == nil`. `os/exec` copies a non-`*os.File` Stderr via `io.Copy` in a goroutine; `io.Copy` turns a short write with a nil error into `io.ErrShortWrite`, and `cmd.Wait()`/`cmd.Output()` return that copy error even on exit 0 with valid stdout. Reproduced with a standalone program that's an exact copy of limitedWriter: the child writes 100KB to stderr in two bursts plus "OK" to stdout → `out="OK" err=short write`. Consequence: any claude invocation emitting >64KB of stderr (verbose MCP/npx logging) in chunks not aligned to 32K boundaries makes `QuerySync` throw away a valid response with a "claude CLI error: short write" error, and `Query` reports an error after a completed stream (the REPL prints an error instead of the answer). The limitedWriter in the codex package (codex/generator.go:150-165) has already been fixed for exactly this — it returns the full original length; the copy in ai is the stale, buggy variant.

```go
func (lw *limitedWriter) Write(p []byte) (int, error) {
    remaining := lw.limit - lw.written
    if remaining <= 0 {
        return len(p), nil // silently discard
    }
    if len(p) > remaining {
        p = p[:remaining]
    }
    n, err := lw.w.Write(p)
    lw.written += n
    return n, err   // n < len(p) with nil err -> io.ErrShortWrite from exec's io.Copy
}
```

- **Recommendation:** Port the fixed variant from codex: after a truncated write, return the full original length `len(p)` (when the underlying Write's error is nil). Ideally, extract limitedWriter into a shared package so the copies can't drift apart.

### ai.Client.Query can hang forever in cmd.Wait() after a scanner error — the child is blocked writing into an undrained stdout pipe

- **Where:** `internal/ai/client.go:228`
- **Verification status:** ✅ confirmed

The scanner caps lines at 1MB (line 194). claude's stream-json output with `--verbose` emits each event as a single JSON line, including tool results — an MCP `read_query` dumping a large table can easily exceed 1MB, at which point `scanner.Scan()` stops with `bufio.ErrTooLong`. The code then calls `_ = cmd.Wait()` without draining stdout first. Wait blocks until the child exits, but the child is blocked writing the rest of the oversized line (and subsequent events) into the ~64KB-full OS pipe buffer and never exits. `cmd.WaitDelay` doesn't save this: it only bounds the wait after the Context is canceled or Cancel is called — neither happened. Result: the producer goroutine hangs forever, textCh/errCh/sidCh never get closed, the REPL (`runAIQuery` ranging over textCh) hangs until Ctrl+C, and a zombie claude process lives on the whole time. There's no fix pattern (drain/close the pipe before Wait) present anywhere.

```go
if err := scanner.Err(); err != nil {
    _ = cmd.Wait()   // child may still be writing >64KB into the pipe; Wait blocks forever
    errCh <- fmt.Errorf("reading claude output: %w", err)
    return
}
```

- **Recommendation:** Before `cmd.Wait()` on every early exit, drain the pipe (`go io.Copy(io.Discard, stdout)`) or kill the process (`cmd.Process.Kill()` / cancel a per-command context) — either guarantees Wait returns. Also consider raising the scanner limit or switching to `bufio.Reader.ReadBytes`.

### codex.Client.Query has the same undrained-stdout deadlock on the error-event and scanner-error paths

- **Where:** `internal/codex/client.go:132`
- **Verification status:** ✅ confirmed

On a JSONL `error` event (line 131-135) and on a scanner error (line 149-153, e.g. a single agent_message line >1MB), the goroutine calls `_ = cmd.Wait()` with stdout undrained. If the codex process still has more than the pipe buffer (~64KB) left to write — trailing events after the error, or the remainder of an oversized line — it blocks on write and never exits, and Wait hangs forever (WaitDelay only applies after ctx is canceled). textCh/errCh/sidCh never get closed, and the caller's `for range textCh` (cmd/ai.go:102) hangs permanently (only Ctrl+C saves it); a zombie codex process is left behind. Additionally, on these early exits the deferred `os.RemoveAll(tmpDir)` for the MCP config (line 77) doesn't run while the goroutine is hung — leaking a temp directory for as long as the hang lasts.

```go
if event.Error != nil {
    _ = cmd.Wait()   // stdout undrained; child blocked writing -> Wait never returns
    errCh <- fmt.Errorf("codex error: %s", event.Error.Message)
    return
}
```

- **Recommendation:** Same fix as for ai.Client: drain stdout (`io.Copy(io.Discard, ...)`) or kill the process before Wait on every early exit. Fix both clients in one PR — the defect is a mirror image.

### `watchtower jira boards` zeroes out issue_count on every board and writes the literal string "now" into synced_at

- **Where:** `cmd/jira.go:448`
- **Verification status:** ✅ confirmed

`runJiraBoards` builds a `db.JiraBoard` with `IssueCount` left at zero and `SyncedAt` set to the literal string "now" (not a timestamp), after which the ON CONFLICT branch of `UpsertJiraBoard` overwrites `issue_count=excluded.issue_count` and `synced_at=excluded.synced_at`. Every run of `jira boards` (also used by Desktop's board pickers: "Refresh Boards" runs this command) resets issue_count to 0 on every board — the very table printed by that same command right afterward shows Issues=0 for boards with thousands of synced issues — and corrupts synced_at with a non-timestamp until the next sync calls `UpdateJiraBoardIssueCount`.

```go
dbBoard := db.JiraBoard{
    ID:         b.ID,
    Name:       b.Name,
    ProjectKey: b.Location.ProjectKey,
    BoardType:  b.Type,
    SyncedAt:   "now",
}
_ = database.UpsertJiraBoard(dbBoard)
// db: ON CONFLICT ... SET issue_count=excluded.issue_count, synced_at=excluded.synced_at
```

- **Recommendation:** Exclude `issue_count` and `synced_at` from the ON CONFLICT SET list in `UpsertJiraBoard` (board metadata — yes, sync counters — no), and populate `SyncedAt` with `time.Now().UTC().Format(time.RFC3339)`. Test: upserting an existing board doesn't reset issue_count.

### `targets update --status done|dismissed` bypasses the INBOX-02 target_due cascade — the reminder item stays pending

- **Where:** `cmd/targets.go:799`
- **Verification status:** ✅ confirmed

docs/inventory/inbox-pulse.md (INBOX-02, extended 2026-05-01) pins the contract: closing a target (status → done/dismissed) auto-resolves its `target_due` inbox item. The cascade lives only in `db.UpdateTargetStatus` (targets.go:286-294). `runTargetsUpdate` changes the status via `db.UpdateTarget` — a plain UPDATE with no inbox cascade. A user closing a reminder target via `watchtower targets update N --status done` leaves the pending `target_due` item behind and has to close the same thing twice — exactly what the locked contract forbids. (The verifier clarified: the Swift path `TargetQueries.updateStatus` does perform the cascade; the defect is confined to the Go CLI update path.)

```go
if cmd.Flags().Changed("status") {
    target.Status = targetsFlagStatus
}
...
if err := database.UpdateTarget(*target); err != nil { ... }
// db.UpdateTarget has no `UPDATE inbox_items ... trigger_type = 'target_due'` cascade; only UpdateTargetStatus does
```

- **Recommendation:** In `runTargetsUpdate`, when `--status` changes, call `UpdateTargetStatus` (or factor the cascade into a shared helper called by both paths). Extend the INBOX-02 guard test to cover the update path.

### The extract pipeline doesn't validate the AI-returned level/priority against the DB's CHECK enums — one bad value rolls back the whole confirmed batch

- **Where:** `internal/targets/extractor.go:199`
- **Verification status:** ✅ confirmed

`parseExtractResponse` carefully validates relations, external_ref prefixes, parent IDs, and limits, but copies `item.Level` and `item.Priority` without validation. The targets table has `CHECK(level IN ('quarter','month','week','day','custom'))` and `CHECK(priority IN ('high','medium','low'))`. If the AI returns, say, level="sprint" or priority="urgent" for one of ten extracted items, `Store.CreateBatch` performs all inserts in a single transaction and rolls back the entire batch on a CHECK violation — the user interactively confirms 10 targets and gets zero created, along with a raw SQLite constraint error. Empty values are defaulted in `insertTargetTx`, but non-empty invalid ones are never sanitized anywhere.

```go
pt := ProposedTarget{
    Text:        item.Text,
    Intent:      item.Intent,
    Level:       item.Level,      // unvalidated
    ...
    Priority:    item.Priority,   // unvalidated
// store.go: level defaults only when ""; INSERT hits CHECK(level IN (...)) inside one tx for the whole batch
```

- **Recommendation:** In `parseExtractResponse`, normalize the values: an invalid level → "custom" (or ""), an invalid priority → "medium", with a log line — following the existing defensive sanitization already applied to other fields. Test: a batch with one invalid value still creates the rest of the targets.

### A target can be made its own parent — no self/cycle check in `targets link --parent` or in AI suggest-links validation

- **Where:** `cmd/targets.go:607`
- **Verification status:** ✅ confirmed

`runTargetsLink` sets `target.ParentID` from `--parent` without checking it against the target's own ID (or for cycles): `watchtower targets link 5 --parent 5` succeeds — the FK `REFERENCES targets(id)` is satisfied by the row itself. The AI path has the same hole: `parseLinkResponse` (targets/linker.go:83) validates parent_id against a snapshot set, but the snapshot from `GetTargets` includes the target being linked itself (`buildLinkPrompt` only hides it from the prompt text), so an AI-suggested parent_id equal to the target's own ID passes validation and gets applied. A self-parented row breaks hierarchy traversal: in Desktop, `rootEntries` treats such a target as neither a root nor anyone's child — it silently vanishes from the list, and `RecomputeParentProgress` counts the target in its own average.

```go
if targetsFlagLinkParent > 0 {
    target, err := database.GetTargetByID(id)
    ...
    target.ParentID = sql.NullInt64{Int64: int64(targetsFlagLinkParent), Valid: true}
    if err := database.UpdateTarget(*target); err != nil { ... }
// linker.go: if resp.ParentID != nil && snapshotIDs[*resp.ParentID] { ... }  — snapshot includes the target itself
```

- **Recommendation:** In both paths, reject `parentID == id` and walk the ancestor chain to catch cycles (hierarchy depth is small). In the linker, exclude the target's own ID from the snapshot set, not just from the prompt text.

### Auto-closing the browser after OAuth login races the process's own exit, and when it does fire, it triggers a macOS TCC Automation prompt

- **Where:** `internal/auth/oauth.go:284`
- **Verification status:** ✅ confirmed

After a successful callback, `Login` starts `go func() { time.Sleep(2 * time.Second); getCloseBrowserFunc()() }()` and returns. The CLI command saves the config and exits normally faster than 2 seconds (the deferred server.Close only sleeps 500ms), so the goroutine dies along with the process — the "auto-close browser window" feature silently never runs. In cases where the process does live ≥2s, `closeBrowserWindow` runs `osascript` with `tell application "System Events"`, which requires Apple Events/Automation TCC permission and pops a macOS consent dialog attributed to the responsible process. Critically, the Desktop app itself spawns `watchtower auth login` (OnboardingView.swift:1244, SettingsView.swift:695), so up the responsibility chain the prompt gets attributed to Watchtower.app — which the project's own rule ("no TCC prompts from Watchtower" = P0) forbids. The path is defective in both outcomes: dead in the typical case, prompt-generating in the rest.

```go
go func() {
    time.Sleep(2 * time.Second)
    getCloseBrowserFunc()()
}()
... script := ` tell application "System Events" ... ` ; cmd := exec.Command("osascript", "-e", script)
```

- **Recommendation:** Remove the osascript auto-close entirely: replace the callback page with a self-contained HTML page using `window.close()`/a "you can close this tab" message — this requires no TCC and doesn't depend on the process's lifetime. Do not "fix" this by waiting for the goroutine — that would only make the TCC prompt deterministic.

## Low

### A closed wake channel races ctx.Done() at shutdown — spurious syncs overwrite last_sync.json with a "context canceled" error

- **Where:** `internal/daemon/daemon.go:188`
- **Verification status:** ✅ confirmed

The `WatchWake` goroutine does `defer close(ch)` (wake.go:14) on ctx cancellation. In `Daemon.Run`'s select loop, a closed channel is permanently ready, so at shutdown the select randomly picks between `<-ctx.Done()` and `<-d.wakeChannel()`. With roughly 50% odds per iteration, the daemon logs "wake event detected, syncing" and calls runSync with an already-canceled context: orchestrator.Run fails with context.Canceled, and phaseSlackSync unconditionally writes last_sync.json with Error: "context canceled" (daemon.go:297-301). Roughly every other graceful shutdown makes `watchtower status` and Desktop show the last sync as failed, even though nothing actually broke. Self-heals on the next sync.

```go
case <-d.wakeChannel():
    d.logger.Println("wake event detected, syncing")
    d.runSync(ctx)
// wake.go:
go func() {
    defer close(ch)
```

- **Recommendation:** In the wake case, use the two-value receive `w, ok := <-...` and exit the loop when `ok == false`; additionally check `ctx.Err() != nil` before runSync at the start of each branch.

### The target_links UNIQUE constraint doesn't dedupe external-ref links (NULL target_target_id) — duplicates accumulate

- **Where:** `internal/db/target_links.go:26`
- **Verification status:** ✅ confirmed

`UNIQUE(source_target_id, target_target_id, external_ref, relation)` is the only protection against duplicates, but external-only links are inserted with `target_target_id = NULL`, and SQLite treats NULLs as distinct in UNIQUE indexes. `CreateTargetLink` does a bare INSERT with no conflict handling, so every repeat run of the AI link-suggester (or a repeated user action) proposing the same external ref (jira:ABC-1, relation=related) inserts yet another identical row — the UI shows duplicated links. The migration 00007 comment even documents that such duplicates have already been seen "in the wild"; that cleanup was a one-time data repair, and the insert path is still leaky.

```go
res, err := db.Exec(`INSERT INTO target_links (source_target_id, target_target_id, external_ref, relation, confidence, created_by) VALUES (?, ?, ?, ?, ?, ?)`, ...)
// schema: UNIQUE(source_target_id, target_target_id, external_ref, relation) with target_target_id NULL → never conflicts
```

- **Recommendation:** Add a partial unique index `CREATE UNIQUE INDEX ... ON target_links(source_target_id, external_ref, relation) WHERE target_target_id IS NULL` (migration) and/or check for existence before INSERT in `CreateTargetLink`.

### The weekly trends digest is never generated: RunWeeklyTrends has no production caller

- **Where:** `internal/digest/pipeline.go:1053`
- **Verification status:** ✅ confirmed

`RunWeeklyTrends` is only called from tests. The daemon phase `phaseTracksAndRollups`'s comment says "runs daily/weekly rollups," but `RunRollups` only calls `RunDailyRollup` (pipeline.go:423); there are no callers in cmd/ either. Digests of type 'weekly' never exist; `watchtower trends` always goes through a degraded fallback path, and the documented three-tier digest pipeline (channel/daily/weekly) has silently lost its weekly tier.

```go
func (p *Pipeline) RunWeeklyTrends(ctx context.Context) error {
// grep: only callers are pipeline_test.go; daemon RunRollups calls only RunDailyRollup
```

- **Recommendation:** Call `RunWeeklyTrends` from `RunRollups` (e.g. once a week, based on the last weekly digest, analogous to the daily logic), or deliberately remove the weekly tier and update the docs/CLI.

### autoResolveSlack matches trigger_type 'reaction_request', but the detector/schema use 'reaction' — reaction items are never auto-resolved

- **Where:** `internal/inbox/pipeline.go:837`
- **Verification status:** ✅ confirmed

`FindReactionRequests` sets `c.TriggerType = "reaction"` (db/inbox.go:545), and the schema's CHECK constraint only allows 'reaction'. The switch in autoResolveSlack whitelists "reaction_request" — a value that can never exist in the DB (the only occurrence of that string in the codebase). Result: when someone reacts ❓ to the user's message and the user then replies in the thread, the item doesn't get auto-resolved by the rule pass — contrary to INBOX-02; the item sits until the 7-day ambient archive.

```go
switch item.TriggerType {
case "mention", "dm", "thread_reply", "reaction_request":
default:
	continue
}
// but detector: c.TriggerType = "reaction"; schema CHECK: ('mention','dm','thread_reply','reaction', ...)
```

- **Recommendation:** Replace "reaction_request" with "reaction" in the switch; centralize trigger-type constants in one place instead of string literals, so mismatches like this get caught by the compiler.

### SessionPool.Acquire returns (nil, nil) to waiters when the pool is closed out from under them

- **Where:** `internal/sessions/pool.go:45`
- **Verification status:** ✅ confirmed

Acquire checks `p.closed`, unlocks, then blocks on `w := <-p.workers`. If `Close()` runs while goroutines are blocked there (all slots busy), `close(p.workers)` wakes every receiver with the zero value: Acquire returns w=nil, err=nil, violating its own contract ("Returns error if pool is closed"). `PooledGenerator.Generate` only checks err, so every previously-blocked caller proceeds to inner.Generate with a nil Worker simultaneously. With the current callers, Close always happens after the pipeline finishes, so the scenario is latent — but it's a one-line time bomb for the future.

```go
select {
case w := <-p.workers:   // closed channel yields nil Worker, no error
    return w, nil
case <-ctx.Done():
    return nil, fmt.Errorf("acquire timeout: %w", ctx.Err())
}
```

- **Recommendation:** Use the two-value form `w, ok := <-p.workers` and return a "pool closed" error when `!ok`. Add a blocked-then-closed test.

### The streaming Query and QuerySync/Generate in codex make contradictory assumptions about agent_message events — one of the two corrupts the output

- **Where:** `internal/codex/client.go:138`
- **Verification status:** ⚠️ could not be conclusively verified (verdict 'uncertain')

Query streams the text of EVERY item.*-lifecycle event with agent_message (no filter on event.Type), and its test encodes delta semantics: item.started "Hello " + item.updated "world" + item.completed "!" concatenate into "Hello world!". But `parseJSONLOutput`, used by QuerySync and CodexGenerator.Generate, keeps ONLY the last item.completed with replace semantics. Both consume the same `codex exec --json` stream, so they can't both be right. The verifier noted: the Swift design and the project's design doc treat item.completed as the FULL turn text (replace), which makes the completed-only parser correct; the realistic defect is that streaming Query could duplicate output if codex emits pre-completion events, but it couldn't be confirmed whether codex actually emits those in exec --json.

```go
// client.go Query — no event.Type filter:
if event.Item != nil && event.Item.Type == "agent_message" && event.Item.MessageText() != "" {
    textCh <- event.Item.MessageText()
// generator.go parseJSONLOutput — completed-only, last-wins:
if event.Type == "item.completed" && event.Item != nil && event.Item.Type == "agent_message" {
    lastContent = event.Item.MessageText()
```

- **Recommendation:** Bring the streaming path in line with completed-only semantics (filter on `event.Type == "item.completed"`), matching parseJSONLOutput and the Swift design; fix the exec_test.go test that encodes the delta model.

### The REPL never recovers from a dead Claude session — a stale sessionID fails every subsequent request

- **Where:** `internal/repl/repl.go:204`
- **Verification status:** ✅ confirmed

`runAIQuery` remembers `r.sessionID` after the first successful response and always resumes it thereafter, and once sessionID is non-empty, it also skips rebuilding the system prompt (line 158-165). If the claude CLI can no longer resume the session (session files cleared/expired, cache cleared, CLI updated), the subprocess exits non-zero, the error is printed — but r.sessionID isn't touched, so the next question resumes the same dead session with an empty system prompt and fails the same way. There's no path/slash command to clear sessionID — the REPL is permanently broken for AI queries until the process restarts. Important: the guard test repl_test.go:1099 deliberately pins that transient sessionID errors must NOT reset it — a correct fix needs to distinguish a resume failure from a transient error.

```go
if err := <-errCh; err != nil {
    fmt.Println(errorStyle.Render("Error: " + err.Error()))
    return    // r.sessionID (and the empty systemPrompt choice) unchanged -> every retry fails
}
```

- **Recommendation:** Detect specifically a resume failure (by claude's `--resume` exit code/stderr text) and in that case reset sessionID with an automatic clean-slate retry; leave transient errors as-is (keep the guard test). Additionally, add a `/reset` slash command as a manual escape hatch.

### Jira sync errors are never persisted: LastError/LastErrorAt are set on the struct, but UpdateJiraSyncState only writes last_synced_at and issues_synced

- **Where:** `internal/jira/sync.go:124`
- **Verification status:** ✅ confirmed

When a project sync fails, Sync() sets syncState.LastError and syncState.LastErrorAt, then calls `db.UpdateJiraSyncState(projectKey, lastSyncedAt, issuesSynced)` — a function that only touches project_key, last_synced_at, and issues_synced. No code path anywhere in the repo writes the last_error/last_error_at columns, even though GetJiraSyncState(s) reads them (and so does the Swift JiraSyncState model). Any status surface relying on these columns shows a permanently empty error state; repeated sync failures are invisible outside the daemon log.

```go
syncState.LastError = err.Error()
syncState.LastErrorAt = time.Now().UTC().Format(time.RFC3339)
_ = s.db.UpdateJiraSyncState(syncState.ProjectKey, syncState.LastSyncedAt, syncState.IssuesSynced)
// db: INSERT INTO jira_sync_state (project_key, last_synced_at, issues_synced) ... — error fields dropped
```

- **Recommendation:** Extend the `UpdateJiraSyncState` signature (or add `UpdateJiraSyncError`) to write last_error/last_error_at; clear them on a successful sync.

### `targets snooze` accepts any unvalidated string as a date — a malformed value leaves the target snoozed forever

- **Where:** `cmd/targets.go:763`
- **Verification status:** ✅ confirmed

`runTargetsSnooze` stores args[1] verbatim into snooze_until with no format validation. `UnsnoozeExpiredTargets` wakes targets via the lexicographic comparison `snooze_until <= '2006-01-02T15:04'`. A user who types `watchtower targets snooze 5 tomorrow` gets a success message ("snoozed until tomorrow"), but "tomorrow" > "2026-..." lexicographically — the daemon will never wake the target, and it silently vanishes from every active list forever. Conversely, formats like "07/10/2026" sort LOW and wake up on the very next cycle. The neighboring inbox snooze validates via parseDuration — an inconsistency.

```go
snoozeDate := args[1]
...
target.Status = "snoozed"
target.SnoozeUntil = snoozeDate
// db: WHERE status = 'snoozed' AND snooze_until != '' AND snooze_until <= ?  (string compare vs "2006-01-02T15:04")
```

- **Recommendation:** Validate/parse the input (`time.Parse("2006-01-02", ...)` plus duration support like inbox has) and fail with a clear error on an invalid format, normalizing the stored value to a canonical shape.

### Events from a deselected calendar are never cleaned up and keep surfacing in the CLI/briefings/AI context

- **Where:** `internal/calendar/sync.go:142`
- **Verification status:** ✅ confirmed

Sync's stale-event cleanup only runs over the currently SELECTED calendarIDs. After a calendar is deselected (`calendar select <id>`), it's no longer fetched AND no longer cleaned up — every previously synced event stays in calendar_events indefinitely with its old synced_at. `GetCalendarEvents` doesn't join is_selected, so `watchtower calendar`, briefing's gatherCalendar, and the AI context builder keep showing events from the disabled calendar (until each one ages out of the requested time window — it practically self-heals within ~2 days, but the rows in the DB remain forever).

```go
for _, calID := range calendarIDs {
    if n, err := s.db.DeleteStaleCalendarEvents(calID, syncedAt); err != nil {
// calendarIDs = selected calendars only; deselected calendar's rows never touched
```

- **Recommendation:** Delete a calendar's events immediately on deselect (in `calendar select`), or additionally have Sync clean up events for all is_selected=0 calendars.

### syncChannel's pagination isn't guarded against HasMore=true with an empty NextCursor — an infinite loop on a single page

- **Where:** `internal/sync/message_sync.go:346`
- **Verification status:** ✅ confirmed

The `conversations.history` loop only ends via `done := !resp.HasMore` or an empty response. If Slack returns has_more=true with an empty response_metadata.next_cursor (historically observed at boundaries with deleted messages), `cursor = resp.NextCursor` resets cursor to "" and the loop repeats the identical request forever (blocking the worker, burning ~40 req/min of the global rate budget, re-upserting the same page) until the daemon's context is canceled. The code itself guards against this in the replies path — `GetConversationReplies` breaks on `!hasMore || nextCursor == ""` (client.go:288) — but the history caller doesn't.

```go
done := !resp.HasMore
...
if done {
    o.logger.Printf("channel %s: done (%d messages)", ...)
    break
}
cursor = resp.NextCursor
// vs client.go:288 (replies): if !hasMore || nextCursor == "" { break }
```

- **Recommendation:** Add the same guard as in replies: `if !resp.HasMore || resp.NextCursor == "" { break }` (plus, optionally, an upper iteration cap as a safety net).

### SearchUsersByName ignores is_bot_override — inconsistent with GetUsers

- **Where:** `internal/db/users.go:82`
- **Verification status:** ✅ confirmed

`GetUsers(ExcludeBots)` filters via `COALESCE(is_bot_override, is_bot) = 0`, respecting the manual-override column (an operator can mark a Slack "bot" as human via SetBotOverride). `SearchUsersByName` filters on the bare `is_bot = 0`, so a user with is_bot_override=0, is_bot=1 never shows up in name search (MCP people lookup), even though they're visible in the regular people list.

```sql
WHERE is_bot = 0 AND is_deleted = 0  -- SearchUsersByName
-- vs "COALESCE(is_bot_override, is_bot) = 0" -- GetUsers
```

- **Recommendation:** Replace the condition with `COALESCE(is_bot_override, is_bot) = 0`, as in GetUsers and channel_stats.

### FindPendingInboxByThread swallows every query error, producing duplicate inbox items on transient failures

- **Where:** `internal/db/inbox.go:88`
- **Verification status:** ✅ confirmed

Any QueryRow error (not just ErrNoRows) is converted into (0, nil) — "not found." On a transient error (SQLITE_BUSY despite busy_timeout, an I/O error), the inbox pipeline concludes there's no pending item for the thread and creates a new one — duplicates per thread, later cleaned up by the (itself buggy, see High) DeduplicateThreadInboxItems repair pass. Real errors need to be distinguished from sql.ErrNoRows.

```go
err := db.QueryRow(`SELECT id FROM inbox_items WHERE channel_id = ? AND thread_ts = ? AND status = 'pending' ...`).Scan(&id)
if err != nil {
    return 0, nil //nolint:nilerr // not found is not an error
}
```

- **Recommendation:** `if errors.Is(err, sql.ErrNoRows) { return 0, nil }; return 0, err` — and handle the error at the call site (skip the candidate for this cycle instead of creating a duplicate).

### storeDigest writes the string "null" instead of "[]" for empty topics/decisions/action_items/situations, breaking downstream != "[]" checks

- **Where:** `internal/digest/pipeline.go:1290`
- **Verification status:** ✅ confirmed

When result.Topics is empty (the AI returned `"topics": []` — realistic for quiet channels/days), allTopicTitles/allDecisions/allActionItems/allSituations stay nil slices, and `json.Marshal(nil-slice)` produces "null". The digests row ends up with topics="null", decisions="null", etc. Downstream guards check `d.Decisions != "" && d.Decisions != "[]"` (lines 1009, 1083), so the literal text "Decisions: null" gets injected into the daily-rollup and weekly-trends prompts, and any consumer that distinguishes empty vs. populated by "[]" misclassifies these rows.

```go
topics, _ := json.Marshal(allTopicTitles)      // nil []string → "null"
decisions, _ := json.Marshal(allDecisions)     // nil []Decision → "null"
// later: if d.Decisions != "" && d.Decisions != "[]" { fmt.Fprintf(&sb, "Decisions: %s\n", …) }
```

- **Recommendation:** Initialize the slices as `make([]T, 0)` before aggregation (or add "null" to the downstream guards). The first option is cleaner — then the DB always has "[]".

### The digest's prompt_version travels through the pipeline but is never persisted — it's always 0 in the digests table

- **Where:** `internal/digest/pipeline.go:1315`
- **Verification status:** ✅ confirmed

storeDigest populates db.Digest.PromptVersion from the prompt store's version, but the INSERT/UPDATE column list of `UpsertDigest` (db/digests.go:16-31) doesn't include prompt_version, and GetDigests doesn't select it. The schema column `prompt_version INTEGER NOT NULL DEFAULT 0` stays 0 for every digest — prompt-version provenance for digests is silently broken (tracks/people cards do persist theirs).

```go
PromptVersion:  promptVersion,
// db.UpsertDigest: INSERT INTO digests (channel_id, type, period_from, period_to, summary, topics,
//   decisions, action_items, people_signals, situations, running_summary, message_count, model,
//   input_tokens, output_tokens, cost_usd) — no prompt_version
```

- **Recommendation:** Add prompt_version to the INSERT/UPDATE column list in UpsertDigest and to the SELECT in GetDigests; fix the test that notes "prompt_version may not be scanned."

### Per-step tracks token stats are always 0: LastStepInputTokens/LastStepOutputTokens are zeroed and never updated from usage

- **Where:** `internal/tracks/pipeline.go:569`
- **Verification status:** ✅ confirmed

runTrackBatches zeroes LastStepInputTokens/LastStepOutputTokens before each batch, but generateBatchTracks only adds usage to the running atomic totals (lines 933-937) — nothing ever writes the LastStep* fields. cmd/tracks.go:647-648 reads them inside OnProgress to record per-step stats, so every tracks step gets logged with 0 tokens even though the usage data is available. Neighboring pipelines (digest, inbox, guide) populate these fields — tracks is the outlier.

```go
p.LastStepInputTokens = 0
p.LastStepOutputTokens = 0
… stepStart := time.Now()
n, err := p.generateBatchTracks(…)  // usage goes only to p.totalInputTokens.Add(…); LastStep tokens never set
```

- **Recommendation:** In generateBatchTracks (or right after it returns in runTrackBatches), assign the LastStep* fields from that call's usage — following the pattern in digest/pipeline.go:840-841.

### Byte-based UTF-8 truncation when building prompts cuts multi-byte runes (Cyrillic), producing invalid UTF-8

- **Where:** `internal/tracks/pipeline.go:1103`
- **Verification status:** ✅ confirmed

formatExistingTracks truncates context via `c[:120]` (a byte index), even though the package's own `truncate()` helper correctly cuts by rune. Same pattern elsewhere: digest's formatMessages (digest/pipeline.go:1602-1604), tracks' enrichKeyMessages (line 1161, `text[:200]`), guide's formatRawMessages (guide/pipeline.go:847). This workspace is Russian-language (2-byte runes), so truncation regularly lands mid-rune, embedding an invalid UTF-8 byte in the prompt (json.Marshal in enrichKeyMessages substitutes U+FFFD). Cosmetic corruption of prompt content at every truncation boundary.

```go
c := sanitize(track.Context)
if len(c) > 120 {
	c = c[:120] + "..."
}  // vs func truncate(s string, maxLen int) { runes := []rune(s); … } three screens below
```

- **Recommendation:** Replace the byte slices with a rune-safe truncate in all four places (it already exists in tracks — extract it into a shared util or duplicate it).

### The briefing pipeline dereferences usage.Model after a nil guard on usage

- **Where:** `internal/briefing/pipeline.go:245`
- **Verification status:** ✅ confirmed

RunForDate guards `if usage != nil` when reading token counts (lines 225-229), acknowledging that the digest.Generator interface can return a nil *Usage with a nil error — but then unconditionally reads usage.Model when building db.Briefing. Any Generator implementation returning `(response, nil, "", nil)` — which the interface allows and which test mocks do — crashes the daemon's briefing phase with a nil pointer. The in-repo generators currently always return a non-nil usage on success, so the defect is latent; the other pipelines (inbox, dayplan) do handle nil.

```go
var inTok, outTok, totalAPI int
if usage != nil { inTok = usage.InputTokens; ... }
...
briefing := db.Briefing{ ... Model: usage.Model,  // no nil guard
```

- **Recommendation:** Move `model := ""` under the same `if usage != nil` block and use that variable in the struct.

### "Never show me this" silently becomes a no-op when the rule upsert fails

- **Where:** `internal/inbox/feedback.go:30`
- **Verification status:** ✅ confirmed

The never_show branch in SubmitFeedback uses `if err := database.UpsertLearnedRule(...); err == nil && len(logger) > 0 ...` — the error result only decides whether to LOG success, and is otherwise discarded; the function returns nil either way. If the upsert fails (SQLITE_BUSY from a concurrently-writing daemon, a CHECK violation), the user's explicit one-click hard mute (the INBOX-04 escape hatch) is silently lost: the feedback row exists, but the mute rule never materialized — the sender keeps getting pinned/prioritized, and the failure never surfaces anywhere.

```go
if err := database.UpsertLearnedRule(db.InboxLearnedRule{RuleType: "source_mute",
    ScopeKey: "sender:" + item.SenderUserID, Weight: -1.0, Source: "user_rule",
    EvidenceCount: 1}); err == nil && len(logger) > 0 && logger[0] != nil {
	logger[0].Printf(...)
}
// err != nil path: swallowed, SubmitFeedback returns nil
```

- **Recommendation:** Propagate the UpsertLearnedRule error out of SubmitFeedback (as the earlier writes in the same function already do), so the caller can surface the failure and the user can retry.

### Ctrl+C on an idle REPL cancels the context, but the loop stays blocked in scanner.Scan until Enter is pressed

- **Where:** `internal/repl/repl.go:104`
- **Verification status:** ✅ confirmed

The idle branch of the signal goroutine calls cancel() and returns, but the main loop is blocked inside scanner.Scan() on stdin (repl.go:127). The Go runtime restarts the read after EINTR, and the ctx.Done() check only happens at the start of the next iteration — which requires the read to finish first. Pressing Ctrl+C while idle (the documented way to quit: "Ctrl+C to quit") prints a newline and outwardly does nothing; the process only exits after an additional Enter (or Ctrl+D). Worse, once the goroutine has returned, further Ctrl+C presses are swallowed by signal.Notify with its unread, capacity-1 channel — there's no way to force a second Ctrl+C to exit.

```go
} else {
    fmt.Println()
    cancel() // cancel the REPL context so defers run properly
    return   // loop is still blocked in scanner.Scan(os.Stdin); exits only after next Enter/EOF
}
```

- **Recommendation:** In the idle branch, after cancel(), call `signal.Stop(sigCh)` and exit the process explicitly (`os.Exit(0)` after tidy defers), or read stdin in a separate goroutine over a line channel so the select can react to ctx.Done().

### Jira sync batch-upsert failures are only logged, but the watermark advances anyway — failed pages are silently lost

- **Where:** `internal/jira/sync.go:330`
- **Verification status:** ✅ confirmed

In syncWithJQL's writer loop, an `UpsertJiraIssueBatch` error (e.g. SQLITE_BUSY while Desktop is holding the shared DB) is only logged and the loop continues; `written` still counts the failed issues, and syncWithJQL doesn't return an error. Sync() then advances last_synced_at to now, so the issues from the failed batch (an all-or-nothing transaction rolls back the whole page) won't be re-fetched until they're updated in Jira again — a silent, unrecoverable gap in the local mirror.

```go
if err := s.db.UpsertJiraIssueBatch(dbIssues, dbLinks); err != nil {
    s.logger.Printf("batch upsert error: %v", err)
}
written += len(dbIssues)
// caller: total += n; _ = s.db.UpdateJiraSyncState(projectKey, now, issuesSynced)
```

- **Recommendation:** Propagate the batch error upward (or collect into a multierror) and, when present, don't advance the watermark for that project — analogous to the search-sync watermark fix.

### jira login writes the site name into jira.user_display_name — status shows the site instead of the user

- **Where:** `cmd/jira.go:302`
- **Verification status:** ✅ confirmed

runJiraLogin persists `v.Set("jira.user_display_name", site.Name)`, where site is the selected CloudResource (the Jira site, e.g. "mycompany"), not the authenticated user. runJiraStatus prints `User: %s` from cfg.Jira.UserDisplayName, so `watchtower jira status` (and Desktop Settings, which reads the same key) shows the site name as the user's display name.

```go
v.Set("jira.site_url", site.URL)
v.Set("jira.user_display_name", site.Name)
// runJiraStatus: fmt.Fprintf(out, "User: %s\n", cfg.Jira.UserDisplayName)
```

- **Recommendation:** After login, query `/rest/api/3/myself` and store the user's actual displayName; keep the site name under a separate key (e.g. jira.site_name) if it's still needed.

### truncate() in cmd/jira.go cuts by bytes — invalid UTF-8 for multi-byte names

- **Where:** `cmd/jira.go:1438`
- **Verification status:** ✅ confirmed

truncate() slices by byte offset (`s[:maxLen-3]`). Jira display names and board names in Cyrillic (this workspace's data is partly Russian/Ukrainian) are 2+ bytes per rune, so the `jira users` and `jira boards` tables can cut mid-rune and print a replacement/garbled character at the truncation point. Cf. internal/targets/resolver.go, where the same purpose is correctly implemented via truncateRunes.

```go
func truncate(s string, maxLen int) string {
    if len(s) <= maxLen {
        return s
    }
    ...
    return s[:maxLen-3] + "..."
}
```

- **Recommendation:** Replace with a rune-safe version (a `[]rune` slice, like truncateRunes in targets/resolver.go), ideally as a shared helper.
</content>
