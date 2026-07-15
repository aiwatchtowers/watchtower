# Functional Inconsistencies and Contradictions — Audit 2026-07-05

This report covers the "functional inconsistencies and contradictions" dimension: behavioral divergence between duplicate paths (Go CLI/daemon vs Swift Desktop), violations of contracts locked in `docs/inventory/`, and configuration keys that are declared/documented but never consumed by the code. Method: several search agents (finders) independently gathered candidates, after which each candidate went through separate adversarial verification tracing both paths through the code; only confirmed findings are listed below (refuted ones were removed). Total: 0 critical, 0 high, 7 medium, 5 low.

## Medium

### Desktop target status change does not recompute progress (neither its own nor the parent's), unlike Go `UpdateTargetStatus`

- **Where:** `WatchtowerDesktop/Sources/Database/Queries/TargetQueries.swift:217`
- **Verification status:** ✅ confirmed

The Go function `UpdateTargetStatus` does three things: writes the status, recomputes the leaf target's own `progress` via `statusToProgress` (`done → 1.0`, etc.), and walks up the parent chain via `RecomputeParentProgress` (averaging children). The Swift version `TargetQueries.updateStatus` only replicates the status write and the INBOX-02 cascade (`target_due` in inbox), but never touches the `progress` column of either the target itself or its ancestors; no other Swift code recomputes progress (Desktop has neither an `AVG(progress)` query nor an equivalent of `statusToProgress`). Since `RecomputeParentProgress` is only invoked from Go paths, a user managing targets from Desktop (the primary UI — the status toggle in `TargetDetailView`, the context menu in `TargetsListView`) gets a permanently stale progress ring: marking a leaf target as `done` leaves `progress` at its old value (e.g. 0%), and the parent's progress bar never reflects children completed through Desktop. The same gap exists for Desktop-snooze (`TargetQueries.snooze`) versus CLI-snooze, which goes through `UpdateTarget` with recomputation.

```go
// internal/db/targets.go:274-305
progress := statusToProgress(newStatus)
_, _ = db.Exec(`UPDATE targets SET progress = ? WHERE id = ? AND
    NOT EXISTS (SELECT 1 FROM targets c WHERE c.parent_id = targets.id AND c.status != 'dismissed')`,
    progress, id)
...
if parentID.Valid {
    if rerr := db.RecomputeParentProgress(parentID.Int64); rerr != nil { ... }
}
```

- **Recommendation:** In `TargetQueries.updateStatus` (and `snooze`), after writing the status, perform the same recomputation: update the leaf target's `progress` via the status mapping and walk up `parent_id`, averaging children's `progress` — or move the logic into shared SQL and call it from both paths. It's worth adding a guard test in `TargetQueriesStatusCascadeTests` that pins down the ring recomputation.

### Go's "track read" cascade marks related digests as read but leaves their decisions unread; Swift's cascade clears both

- **Where:** `internal/db/tracks.go:287`
- **Verification status:** ✅ confirmed

Swift `TrackQueries.markRead` cascades to each related digest with BOTH `markDigestRead` and `markAllDecisionsRead` calls, so the Decisions feed counter (total − COUNT(decision_reads)) is zeroed out. Go `MarkTrackRead` cascades to related digests with a raw `UPDATE digests SET read_at = ...`, which bypasses `MarkDigestRead` and skips the `markDigestDecisionsRead` cascade. Result: reading a track through any Go path — CLI `watchtower tracks read <id>`, or `watchtower catchup ack` / leftover-noise cleanup, when a theme ref points at a track with `related_digest_ids` — marks digests as read (the user won't open them again), but their decisions remain permanently stuck in the unread Decisions counter. The same action in Desktop clears them. This is exactly the "half with decisions — the half that's easy to forget" failure mode that CATCHUP-01 (`docs/inventory/catchup.md`) pins down for digest refs, leaking through the track cascade only on the Go side.

```go
// internal/db/tracks.go:280-289
q := "UPDATE digests SET read_at = strftime(...) WHERE id IN (...) AND read_at IS NULL"
db.Exec(q, args...) // no insert into decision_reads
```
```swift
// TrackQueries.swift:112-115
try DigestQueries.markDigestRead(db, id: digestID)
try DigestQueries.markAllDecisionsRead(db, digestID: digestID)
```

- **Recommendation:** In `MarkTrackRead`, replace the raw `UPDATE digests` with a call to `MarkDigestRead` for each related digest (or add a `markDigestDecisionsRead` cascade alongside it), so decisions are cleared together with the digest. Extend `TestMarkTrackRead_CascadeDigests` to check for the appearance of `decision_reads` rows, not just `read_at`.

### CLI inbox counters and list include archived items; Desktop excludes them — surfaces diverge after auto-archiving of stale items

- **Where:** `internal/db/inbox.go:277`
- **Verification status:** ✅ confirmed

The pipeline archives actionable items that have sat in `pending` for more than 14 days, setting `archived_at` while keeping `status='pending'` (`archive_reason='stale'`), and ambient items after 7 days. Swift `fetchCounts` and the feed queries filter on `archived_at IS NULL`, which matches the Go feed/pinned queries. But Go `GetInboxCounts` (the `watchtower inbox` header) counts every `status='pending'` row without an `archived_at` filter, and `GetInboxItems` (the CLI list) never filters it either. After two weeks of normal operation, the CLI shows pending/unread counters and lists items that the Desktop badge and feed (and the Go feed/pinned queries themselves) no longer show — the operator sees two different inboxes depending on the surface. `GetInboxItemsForBriefing` shares the same omission, additionally mixing archived stale items into the daily briefing prompt.

```sql
-- Go GetInboxCounts (inbox.go:277-281): no archived_at predicate
SELECT COALESCE(SUM(CASE WHEN status='pending' THEN 1 ELSE 0 END),0),
       COALESCE(SUM(CASE WHEN status='pending' AND read_at IS NULL THEN 1 ELSE 0 END),0)
FROM inbox_items;
-- Swift fetchCounts (InboxQueries.swift:60)
SELECT COUNT(*) FROM inbox_items WHERE status='pending' AND archived_at IS NULL;
```

- **Recommendation:** Add `AND archived_at IS NULL` to `GetInboxCounts`, `GetInboxItems`, and `GetInboxItemsForBriefing`, bringing the CLI and the briefing prompt to the same criteria already used by the Desktop and the Go feed/pinned queries.

### The `digest.model` key is written by Desktop onboarding/settings and accepted by `config set`, but never read by any Go code — the digest model choice is silently ignored

- **Where:** `cmd/config.go:190`
- **Verification status:** ✅ confirmed

Desktop onboarding writes `digest.model` (mapping the Haiku/Sonnet/Opus preset the user picked), `SettingsView` lets it be edited, `ConfigService` round-trips it, and `cmd/config.go` lists it in `knownConfigKeys`, so `watchtower config set digest.model ...` passes without a warning. But the Go `DigestConfig` struct has no `Model` field, and nothing parses or reads the key: `cliGenerator` hardcodes `digest.ModelSonnet` as the fallback, and `ModelForSource` routes by source between hardcoded Haiku/Sonnet constants. A user who picked "Opus — best insights" (or "Haiku — low cost") during onboarding still gets Sonnet/Haiku routing; their price/quality choice has no effect anywhere. The asymmetry is stark: `ai.model` is actually read (`config.go:22 → newAIClient`), while `digest.model` is not.

```go
// cmd/config.go: "digest.model": true in knownConfigKeys
// internal/config/config.go:36-44: DigestConfig{Enabled, MinMessages, Language, Workers,
//   TracksInterval, BatchMaxChannels, BatchMaxMessages} — no Model field
// cmd/generator.go:27:
return digest.NewClaudeGenerator(digest.ModelSonnet, cfg.ClaudePath)
```

- **Recommendation:** Either add a `Model` field to `DigestConfig` and thread it through `cliGenerator`/`ModelForSource` (with Opus support), or, if the digest model is meant to be governed by the router by design, remove the key from onboarding/Settings/`knownConfigKeys` so the UI doesn't promise a setting that doesn't exist.

### `FindTracksByFingerprint` does not exclude dismissed tracks — new activity silently merges into a dismissed (invisible) track, contrary to TRACKS-07

- **Where:** `internal/db/tracks.go:419`
- **Verification status:** ✅ confirmed

TRACKS-07 (`docs/inventory/tracks.md`) states: a dismissed track "no longer participates in any cross-channel/dedup checks — after dismissal, the AI may re-open the same situation as a fresh track." Text-similarity dedup honors this (`findSimilarTrack` iterates `allActiveTracksRef` from `GetAllActiveTracks`, which filters on `dismissed_at = ''`), but the fingerprint path does not: `FindTracksByFingerprint` has no `dismissed_at` filter, so in `storeTrackItems` a new theme sharing a fingerprint entity (Jira key, CVE, MR id, user id) with a dismissed track gets routed into `UpdateTrackFromExtraction` against the dismissed row. `UpdateTrackFromExtraction` never resets `dismissed_at`, so fresh content gets written into a track excluded from every default list and the Desktop tab. Scenario: a user dismisses the "CEX-1234 incident" track; the ticket flares up again a week later; the pipeline folds all the new content into the dismissed row, and the user never sees it — no new track is created. The same gap exists on the existing_id path: `GetTrackAssignee` only checks ownership, not dismissal.

```go
// internal/db/tracks.go:419 — no dismissed_at filter
query := `SELECT ` + trackSelectCols + ` FROM tracks
    WHERE (fingerprint LIKE ? OR ...) AND assignee_user_id = ?`
// GetAllActiveTracks (tracks.go:173): ... FROM tracks WHERE dismissed_at = ''
```

- **Recommendation:** Add `AND dismissed_at = ''` to `FindTracksByFingerprint` (and to `GetTrackAssignee`), so fingerprint dedup, like text dedup, bypasses dismissed tracks. Add a guard test `TestTracks07_DismissedDoesNotBlockRediscovery`, which `docs/inventory/tracks.md` already flags as missing.

### Manual Desktop edits to a track (priority/ownership/sub-items) skip the `track_states` snapshot that TRACKS-06 marks Enforced for manual edits

- **Where:** `WatchtowerDesktop/Sources/Database/Queries/TrackQueries.swift:127`
- **Verification status:** ✅ confirmed

TRACKS-06 (`docs/inventory/tracks.md`, Status: Enforced) requires: "Every change to a narrative field — ... priority, ownership, ... sub_items ... — writes a snapshot of the prior state to `track_states` ... Both AI extraction and manual edits (`UpdateTrackPriority`, `UpdateTrackOwnership`, `UpdateTrackSubItems` ...) snapshot before the mutation." The Go side does this (`snapshotTrackState`). But Desktop performs the same manual edits with a direct write to the shared SQLite database — `TrackQueries.updatePriority`, `updateOwnership`, `updateSubItems` — via plain `UPDATE tracks` statements without an insert into `track_states` (the only Swift access to `track_states` is the read-only `TrackStateQueries`). A priority/ownership change made in the Desktop Tracks tab leaves no history row, so the History section can't answer "did the track always say this?" for Desktop edits; the same action does produce history via the CLI, but not via Desktop.

```swift
// TrackQueries.swift:127 — no write to track_states
try db.execute(sql: "UPDATE tracks SET priority = ? WHERE id = ?", ...)
```
```go
// internal/db/tracks.go — BEHAVIOR TRACKS-06: snapshot before manual edit
_ = db.snapshotTrackState(cur, proposed, "manual")
```

- **Recommendation:** Replicate the snapshot in Swift: before each `UPDATE tracks` in `updatePriority`/`updateOwnership`/`updateSubItems`, insert a `track_states` row with the prior state and `source='manual'`, mirroring `snapshotTrackState`. Wrap the read+snapshot+update in a single `dbPool.write` transaction.

### The daemon only wires up the inbox/briefing/day-plan/custom-track pipelines inside `if cfg.Digest.Enabled` — disabling digests silently disables four independently configurable features

- **Where:** `cmd/sync.go:274`
- **Verification status:** ✅ confirmed

In daemon mode (and in the one-shot `runPostSyncPipelines`), all AI pipelines are constructed inside a single `if cfg.Digest.Enabled { ... }` block: `SetInboxPipeline` is only called when digest.enabled AND inbox.enabled are both true, and likewise for briefings, day plans, next-step, and custom-track scans. The config documents these as independent toggles (inbox.enabled defaults to true, briefing.enabled true, day_plan.enabled true). A user who sets `digest.enabled: false` (for example, to cut AI cost while keeping the algorithmic DM/mention detection for inbox) silently loses inbox detection, daily briefings, day plans, and custom-track scan without any warning. The most material case is inbox: `daemon.go` skips `RunFastDetection` when `d.inboxPipe == nil`, and `inboxPipe` is only set inside the digest block, so the purely SQL-based DM/mention detection (Phase 0.7) dies even though it doesn't need an AI generator at all. The Desktop "digest enabled" toggle thereby functions as an undocumented master kill switch for four other tabs.

```go
// cmd/sync.go:274
if cfg.Digest.Enabled {
    ...
    if cfg.Briefing.Enabled { d.SetBriefingPipeline(...) }
    if cfg.Inbox.Enabled    { d.SetInboxPipeline(...)   }
    d.SetNextStepPipeline(...)
    d.SetCustomTracksPipeline(...)
    if cfg.DayPlan.Enabled  { d.SetDayPlanPipeline(...)  }
}
```

- **Recommendation:** Move the construction of independently-configurable pipelines out from under `if cfg.Digest.Enabled` (creating the AI generator lazily/once, on first consumer use). At a minimum, move the SQL-based inbox fast detection out, since it doesn't need AI, and add a warning log when an enabled feature fails to start because digests are disabled.

## Low

### The `never_show` learned-rule upsert diverges: Go resets `evidence_count` to 1, Swift increments it

- **Where:** `WatchtowerDesktop/Sources/Database/Queries/InboxFeedbackQueries.swift:69`
- **Verification status:** ✅ confirmed

Both "never show" paths (the escape hatch from INBOX-04) upsert a `source_mute` user_rule, but on conflict Go's `UpsertLearnedRule` sets `evidence_count = excluded.evidence_count`, and `SubmitFeedback` always passes `EvidenceCount:1` — meaning every Go-side never_show resets the counter to 1 — whereas Swift's `upsertRule` sets `evidence_count = evidence_count + 1`, accumulating it. `evidence_count` is user-visible on the Learned tab (INBOX-05: "learned from N dismissals"), so the same sequence of actions produces a different displayed model for the user depending on the surface, and a single CLI-side never_show wipes out the counter accumulated by Desktop. Go's `ON CONFLICT` also overwrites `pipeline`, whereas Swift preserves it — the same kind of drift. Note: today no consumer reads `evidence_count` for these user_rule mutes (the Learned view only shows scopeKey/weight/source, and the AI prompt uses scope/weight/source), so the harm is currently latent.

```go
// inbox_learned_rules.go:38-44 — ON CONFLICT ... evidence_count = excluded.evidence_count
// feedback.go:30-36 — EvidenceCount: 1
```
```swift
// InboxFeedbackQueries.swift:66-70 — ON CONFLICT ... evidence_count = evidence_count + 1
```

- **Recommendation:** Pick a single semantics for `evidence_count` on `source_mute` user_rule (accumulation is probably the right one) and bring both upserts in line with it; also reconcile the `pipeline` behavior in `ON CONFLICT`. Until a consumer appears this is just consistency cleanup, but it's best done before the Learned tab starts displaying the counter.

### Swift catch-up acknowledge decides `reviewed_count` idempotency from a stale snapshot passed in by the caller and aborts the whole ack on a mark-read error, unlike Go

- **Where:** `WatchtowerDesktop/Sources/Database/Queries/CatchUpQueries.swift:97`
- **Verification status:** ✅ confirmed

Two drifts from Go's `Pipeline.Acknowledge`. (1) Source of idempotency: Go re-reads the theme from the DB at ack time (`alreadyReviewed := theme.ReviewState == "reviewed"`), so a repeated ack always sees the persisted `reviewed` state. Swift reads `theme.isReviewed` from the `CatchUpTheme` value passed in by the view — a snapshot taken before the write. A double-click on "Done" (or an ack racing with a CLI-side `catchup ack`) fires two serialized `dbPool.write` blocks, both of which see the stale `isReviewed == false` and both increment `reviewed_count = reviewed_count + 1`, pushing the counter past `total_themes` — exactly the over-count that the CATCHUP-01 idempotency clause forbids (the guard test passes because it re-reads the theme between acks). (2) Error semantics: Go's cascade is explicitly best-effort — each `markAreaRead` error is logged and the loop continues, and the theme is still marked reviewed regardless. Swift `try`s each mark-read inside the write transaction, so the first failing ref throws out of `acknowledge`, rolls back the transaction, and the theme isn't acknowledged at all — one bad ref blocks the ack in Desktop, but not in the CLI.

```swift
// CatchUpQueries.swift:97 — stale parameter
let wasReviewed = theme.isReviewed
```
```go
// pipeline.go:444-459 — re-read from DB + best-effort cascade
theme, err := p.db.GetCatchupTheme(themeID)
alreadyReviewed := theme.ReviewState == "reviewed"
if err := p.markAreaRead(r.Area, r.ID); err != nil { p.logf(...) } // continue
```

- **Recommendation:** In Swift `acknowledge`, re-read the theme from the DB inside the transaction to check `isReviewed` (instead of the snapshot parameter), and isolate each mark-read error (log and continue, still flipping the theme to reviewed), bringing the behavior in line with Go's best-effort/idempotent CATCHUP-01 contract.

### `inbox.max_items_per_run` is defined, defaulted, and documented, but never consumed by the code — the declared per-run cap is not applied

- **Where:** `internal/config/config.go:55`
- **Verification status:** ✅ confirmed

`InboxConfig.MaxItemsPerRun` exists with a viper default of 100 and is documented in CLAUDE.md as "inbox.max_items_per_run (100)", but a repo-wide grep shows the only references are the struct tag and the `SetDefault` line; `internal/inbox/pipeline.go` never reads it. A user who sets `inbox.max_items_per_run: 10` to limit detection volume / AI-prioritize cost gets no behavior change; detection volume is bounded only by the lookback watermark. The only cap in the package is the hardcoded `MaxItemsPerAIBatch=50` (an AI batch size, not a per-run cap), and there's no `LIMIT` anywhere in the inbox package.

```go
// internal/config/config.go:55
MaxItemsPerRun int `mapstructure:"max_items_per_run"` // (default: 100)
// grep 'MaxItemsPerRun|max_items_per_run' → only config.go:55 and :204
```

- **Recommendation:** Either apply the cap in `internal/inbox/pipeline.go` (e.g. a `LIMIT`/truncation of the candidate set to `MaxItemsPerRun`), or remove the key from the config and CLAUDE.md so a non-existent setting isn't advertised.

### The `calendar.sync_days_ahead` default diverges across layers: the Go effective default is 7, the Go struct comment and Desktop fallback say 2, and Desktop-save silently writes 2

- **Where:** `internal/config/defaults.go:39`
- **Verification status:** ✅ confirmed

`DefaultCalendarSyncDaysAhead = 7` (used as the viper default, the fallback in `internal/calendar/sync.go:47`, and `cmd/calendar.go:109`), but the struct comment (`config.go:82`) says "default: 2", CLAUDE.md says 2, and Desktop's `ConfigService.swift` falls back to 2 when the key is absent. Since `ConfigService.save()` unconditionally writes `calendarDict["sync_days_ahead"] = calendarSyncDaysAhead`, a user whose config had no such key sees "2" in Settings and, upon saving any unrelated setting, silently shrinks the daemon's actual sync window from 7 to 2 days — upcoming-events and meeting-prep context loses days 3–7 without the user ever touching a calendar setting.

```
Go:    DefaultCalendarSyncDaysAhead = 7
Go:    SyncDaysAhead ... // days ahead to fetch (default: 2)   ← comment is wrong
Swift: calendarSyncDaysAhead = (calendar["sync_days_ahead"] as? Int) ?? 2
Swift: save(): calendarDict["sync_days_ahead"] = calendarSyncDaysAhead
```

- **Recommendation:** Converge all layers on a single default (most likely 7): fix the comment at `config.go:82` and CLAUDE.md, and change the Desktop fallback to 7. Even better — don't write the key in `save()` unless the user actually changed it, so the server-side default isn't silently overridden.

### The CLI `watchtower feedback` command rejects entity types (target, briefing, inbox, catchup_theme) that the DB CHECK allows and Desktop actively writes

- **Where:** `cmd/feedback.go:58`
- **Verification status:** ✅ confirmed

The `feedback` table's CHECK constraint (migration 00003) allows `entity_type IN ('digest','track','decision','user_analysis','briefing','target','inbox','catchup_theme')`, and Desktop writes `entityType "target"` (`TargetsViewModel.swift:440`, `TargetDetailView.swift:784`) and `"track"`/`"digest"`. The `validTypes` map in the CLI only accepts digest/track/decision/user_analysis, so `watchtower feedback bad target 12` fails with "invalid type," even though the same rating is written by Desktop and supported by the schema — the same action passes on one client and is rejected on the other.

```go
// cmd/feedback.go:58
validTypes := map[string]bool{"digest": true, "track": true, "decision": true, "user_analysis": true}
// vs CHECK(entity_type IN ('digest','track','decision','user_analysis','briefing','target','inbox','catchup_theme'))
```

- **Recommendation:** Extend `validTypes` in `cmd/feedback.go` to the full set allowed by the CHECK (`briefing`, `target`, `inbox`, `catchup_theme`), bringing the CLI to parity with the DB schema and Desktop.

### The `digest.action_items_interval` / `digest.tracks_interval` key is parsed, defaulted, aliased, and allow-listed, but never consumed

- **Where:** `internal/config/config.go:41`
- **Verification status:** ✅ confirmed

`DigestConfig.TracksInterval` is unmarshaled from `digest.action_items_interval`, gets a default of 1h, has an alias (`digest.tracks_interval`), and both entries are in `cmd/config.go`'s `knownConfigKeys`, so `config set` accepts them as recognized. Repo-wide, no code outside `internal/config` reads `TracksInterval` — the tracks pipeline runs every daemon cycle independently (gated by `lastTracksStartedAt()`, not by this config value). Setting the interval to any value changes nothing; the key is dead, but it's presented to users as a working setting.

```go
// internal/config/config.go:41
TracksInterval time.Duration `mapstructure:"action_items_interval"`
// grep 'TracksInterval' → only internal/config/{config.go,defaults.go}
```

- **Recommendation:** Either actually apply the interval in the tracks pipeline's gate logic, or remove the field, default, alias, and both `knownConfigKeys` entries, so `config set` doesn't pass off a dead key as a working one.
