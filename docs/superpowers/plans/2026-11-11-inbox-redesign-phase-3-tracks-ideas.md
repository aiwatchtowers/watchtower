# Inbox redesign — Phase 3: Track my threads and Idea finder — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Track my threads counts and lists only threads with news and stops quiet ones with one confirmed press; Idea finder hands out a fixed daily batch one card at a time and clears ideas older than 30 days with one confirmed press.

**Architecture:** One "with news" rule with a Go twin (`internal/tracks`) and a Swift twin (`TrackNewsRule`, WatchtowerCore) over one shared fixture; the Go twin drives a new two-step `tracks dismiss --quiet-days … --dry-run` / `--ids …` CLI (the only bulk track write, TRACKS-07). The daily idea batch is a pure selector plus a UserDefaults store (`IdeaDailyBatch`), the bulk idea drop a GRDB write (`IdeaQueries.dropMany`, IDEA-04). `ActionStripViewModel` exposes both; the folder path's reading pane draws two new panes for the `.legacyTracks` / `.legacyIdeas` entries instead of opening today's legacy lists, which stay reachable (All Threads, Backlog · N).

**Tech Stack:** Go 1.26 (cobra, `database/sql` over the in-repo SQLCipher driver), Swift 5.10 language mode / SwiftUI macOS 14, GRDB, XCTest + ViewInspector.

**Order with other phases:** the spec calls phases 1, 3 and 4 independent in what they change; this plan still *consumes* phase 1's components (the common brief's shared interfaces: bulk press button, row content, pane header), so the phase-3 PR merges after phase 1. Tasks 1–7 touch no phase-1 file and may start before phase 1 merges; Tasks 8–11 start on a branch that has phase 1. Phase 3 does not depend on phases 2, 4 or 5.

**Spec:** `docs/superpowers/specs/2026-11-11-inbox-redesign-design.md` (owner-approved, ask #638) — sections "Track my threads (phase 3)", "Idea finder (phase 3)", "The list" rows for both entries, "Inventory" (IDEA-04 and TRACKS-07 notes). Mockup: `docs/design/mockups/inbox-redesign/inbox-redesign.html` (`threads` and `ideas` panes).

## Global Constraints

- **With news** = `has_updates = 1`, or never read (`read_at` NULL or `''`) and last event within 3 days (72 h, inclusive). Everything else is **quiet**. Last event = the later of `tracks.updated_at` and the newest `track_events.created_at`.
- **Quiet for stopping** = active (`dismissed_at = ''`), not with news, last event at or before now − 30 days (30 × 24 h, inclusive). A last event that does not parse is unknown: never news by time, never quiet.
- CLI: `watchtower tracks dismiss --quiet-days 30 --dry-run --json` → last stdout line `{"count":N,"ids":[…]}`; `watchtower tracks dismiss --ids 1,2,3 --json` → `{"dismissed":N,"skipped":N,"ids":[…]}`; on a write error exit 1 with `{"dismissed":N,"of":M,"error":"…"}` as the last stdout line. Track ids are JSON integers. `--ids` is refused under an agent marker (`refuseUnderAgent`); the dry run is a read and is allowed. `tracks dismiss <id>` is unchanged.
- The bulk track write sets `dismissed_at` only, on the listed ids still active (TRACKS-07 note); Restore stays per track (the Stopped fold).
- **Daily idea batch:** ideas awaiting a verdict (`Idea.awaitsVerdict`) created within the last 30 days (30 × 24 h), oldest `created_at` first (then id), `ideas.dailyBatch` per local day (default 13; a missing, non-integer or < 1 value = 13). Fixed per local day: `ideas.batch.date` (`yyyy-MM-dd`, local calendar) and `ideas.batch.ids` (`[Int]`, the current batch in hand-out order). **Next 13** takes a new batch the same day: it replaces `ideas.batch.ids` with the next candidates (the spec's "takes a new batch"), so "J of T judged" and Kept today always describe the current batch. An empty stored batch for today is re-picked on the next read.
- Verdicts: **Keep** → `active` (`IdeasViewModel.approve`), **Drop** → `rejected` (`IdeasViewModel.reject` — never `drop`), **Later** → `not_now` with no date (`IdeasViewModel.notNow(idea)`), **Make a Target…** → `IdeasViewModel.convertToTarget` then open the target. Keys K / D / L / T.
- **Clear Old Ideas…** sets `dropped` on ideas awaiting a verdict whose `created_at` is older than 30 days, through `IdeaQueries.dropMany(_:ids:)` — one GRDB transaction, only ids still awaiting a verdict, clearing `needs_review`/`review_reason` (IDEA-04 note).
- Every bulk press: dry run / read → confirmation naming the count → write exactly those ids → re-read; failure leaves rows as they were, shows the text with **Try Again**; never retried by itself (phase 1's `InboxBulkPressModel`/`InboxBulkPressButton`).
- Tracks and ideas never enter the root count or the sidebar badge (phase 1 owns the counts; nothing here changes them).
- Copy (exact): "Stop Tracking Quiet Ones…", "Stop Tracking N Threads" / "Stop Tracking 1 Thread", "Clear Old Ideas…", "Clear N Old Ideas" / "Clear 1 Old Idea", "Next 13" (the number = the batch size), "Backlog · N", "All Threads", "Kept today", "Keep", "Drop", "Later", "Make a Target…". Curly quotes and apostrophes as in the spec ("Today’s", “…”).
- Desktop: design-kit tokens only, `.kitRow`, no row dividers, one prominent action per screen (Keep on the idea pane), panels not pop-ups (the confirmation is phase 1's button); DesignShotCatalog `inbox-r-*` (light + dark) on `acme` / `example.com` fixtures; no live data in tests, fixtures, docs.
- Checks per task: inner loop only (`go test ./internal/<pkg> -run …`, `go test ./cmd -run …`, `make test-swift FILTER=…`, `make lint-diff`); the full gate runs once per phase by the controller.

## Review Focus

1. **The app stays open across midnight.** The first read after local midnight picks a new batch and the row's pill follows it; yesterday's leftovers are not "today’s batch". → Task 8 `testReadAfterMidnightPicksNewBatch`.
2. **The opened thread leaves the active list** (Stop watching on its card, a bulk stop, a stop on another surface). The pane goes back to the news list, never an empty pane or a stale card. → Task 8 `testOpenedNewsTrackClosesWhenTrackLeavesActiveList`.
3. **`--ids` with junk**: an already-stopped id, an unknown id, a duplicate, a non-number. Unknown/stopped are skipped and counted, duplicates count once, a non-number refuses the whole call with exit 2 and writes nothing. → Task 3 `TestTracksDismiss_IdsDismissesActiveAndSkipsTheRest`, `TestTracksDismiss_FlagValidation`.
4. **A track whose time does not parse** is never stopped in bulk (unknown ≠ old). → Task 1 fixture case `unparseable_time`, Task 3 dry-run test.
5. **A second key press while a verdict is still writing** (K K, K then D) writes one verdict; the next card is judged only by a press after it is shown. → Task 10 `testPressWhilePendingIsIgnored`.

---

## Phase 1 interfaces this phase consumes

Phase 1 (WatchtowerCore + Views) defines these; use them as named. If phase 1 landed a different case or parameter spelling, map 1:1 and note it in the PR — the semantics here are fixed.

- `InboxBulkPlan(ids: [String], count: Int)`, `InboxBulkResult.done(count:skipped:)` / `.partial(done:of:error:)` / `.failed(String)`, `@MainActor final class InboxBulkPressModel: ObservableObject` (`begin(plan:)`, `confirm(apply:)`, `cancel()`), view `InboxBulkPressButton(title:confirmTitle:model:)`.
- `InboxPaneHeader(tile:title:subtitle:actions:)`, the tile chosen by `InboxRowKind` (`.threads`, `.ideas`).
- `InboxRowContent { kind, title, preview, meta, time, pill: InboxRowPill?, isUnread }` and phase 1's row builder that maps an `InboxFolderEntry` to it; `InboxRowPill` with the news (accent) and neutral tones. Root section Running holds both entries (unchanged).

## File map

| File | Responsibility | Task |
|---|---|---|
| `internal/tracks/news.go`, `news_test.go`, `testdata/track_news.json` | Go news/quiet rule + shared fixture | 1 |
| `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/TrackNewsRule.swift`; `Tests/Core/TrackNewsRuleTests.swift` | Swift twin; last-event merge used by `TrackQueries` | 2 |
| `WatchtowerCore/Database/Queries/TrackQueries.swift`, `Services/Inbox/InboxCards.swift` | `fetchInboxCards` uses the twin, reads `latest_event_summary` | 2 |
| `internal/db/tracks.go`, `tracks_test.go`; `cmd/tracks.go`, `tracks_test.go`; `docs/inventory/tracks.md` | quiet inputs read, bulk dismiss, CLI flags, TRACKS-07 note | 3 |
| `WatchtowerCore/Services/Inbox/TracksBulkCLI.swift`; `Tests/Core/TracksBulkCLITests.swift` | Desktop wrapper over the two CLI calls | 4 |
| `WatchtowerCore/Services/Inbox/TrackThreadsSummary.swift`; `Tests/Core/TrackThreadsSummaryTests.swift` | news/quiet split, latest line, reason chip, row and pane copy | 5 |
| `WatchtowerCore/Services/Inbox/IdeaDailyBatch.swift`; `Tests/Core/IdeaDailyBatchTests.swift` | batch selector + store, `IdeaBatchState`, `IdeaBatchPress`, row and pane copy | 6 |
| `WatchtowerCore/Database/Queries/IdeaQueries.swift`, `IdeaBatchCardFacts.swift`; `Tests/Core/IdeaQueriesTests.swift`; `docs/inventory/ideas.md` | `fetchAwaitingVerdict`, `dropMany`, card facts read, IDEA-04 note | 7 |
| `WatchtowerCore/Services/Actions/ActionStripViewModel.swift`, `Services/Inbox/InboxFolderEntries.swift` (+ phase 1's row builder); `Tests/Core/ActionStripTracksIdeasTests.swift` | VM state, selection/routes, bulk presses, row rules | 8 |
| `WatchtowerDesktop/Sources/Views/Inbox/InboxTracksNewsPane.swift`; `Tests/InboxTracksNewsPaneTests.swift` | news list pane + back bar | 9 |
| `Views/Inbox/IdeaBatchPane.swift`, `ViewModels/IdeasViewModel+Batch.swift`; `Tests/IdeaBatchPaneTests.swift` | one-card pane, keys, verdict dispatch | 10 |
| `Views/Inbox/ActionStripView.swift`, `Tests/DesignShots/DesignShotCatalog.swift`, `DesignShotFixtures+InboxRedesignPhase3.swift`, guide pages, `docs/features/inbox-redesign.md`, `CLAUDE.md`, `docs/inventory/reaction-commands.md` | wiring, shots, docs | 11 |

---

### Task 1: Go "with news" rule and the shared fixture

**Depends on:** none

**Files:**
- Create: `internal/tracks/news.go`, `internal/tracks/news_test.go`, `internal/tracks/testdata/track_news.json`

**Interfaces:**
- Produces:
  - `const NewsWindow = 72 * time.Hour`; `const QuietDays = 30`
  - `type NewsInput struct { ReadAt string; HasUpdates bool; UpdatedAt string; NewestEventAt string }` (`ReadAt` "" = never read; `NewestEventAt` "" = no event)
  - `func LastEventAt(updatedAt, newestEventAt string) time.Time` — later of the two parsed (`time.RFC3339Nano`, which also takes no fraction); zero `time.Time` when neither parses.
  - `func HasNews(in NewsInput, now time.Time) bool`
  - `func IsQuiet(in NewsInput, now time.Time, quietDays int) bool`
  - Fixture `internal/tracks/testdata/track_news.json`: `{"note": "...", "quiet_days": 30, "cases": [{"name", "now", "read_at" (string|null), "has_updates", "updated_at", "newest_event_at" (string|null), "has_news", "quiet"}]}`; `null` read_at and `""` both mean never read.

- [ ] **Step 1: Write the fixture** with fixed `now` values (relative cases, no date bombs) and these named cases at least: `has_updates_old` (has_updates, read, event 60 d → news, not quiet), `never_read_2d` (news), `never_read_exactly_72h` (news), `never_read_72h_plus_1s` (not news; 3 d old → not quiet), `never_read_empty_string` (`read_at: ""`, event 1 d → news), `read_10d` (not news, not quiet), `read_exactly_30d` (quiet), `read_40d` (quiet), `never_read_40d` (quiet), `event_newer_than_updated` (updated 40 d, event 1 d, read → not quiet), `fractional_seconds` (`…:05.123Z`), `unparseable_time` (both garbage → not news, not quiet), `future_event_never_read` (event 1 h ahead → news, not quiet).
- [ ] **Step 2: Write the failing tests** — `TestTrackNews_Fixture` (every case: `HasNews` == `has_news`, `IsQuiet(…, fixture.quiet_days)` == `quiet`, failure names the case); `TestTrackNews_FixtureCoversBoundaries` (the fixture contains every case name listed in Step 1, so a later edit cannot drop a boundary); `TestLastEventAt_ZeroWhenNeitherParses`.
- [ ] **Step 3: Run** `go test ./internal/tracks -run 'TestTrackNews|TestLastEventAt'` — expect FAIL (undefined).
- [ ] **Step 4: Implement** `news.go` per the Global Constraints (news by time: `!last.IsZero() && !last.Before(now.Add(-NewsWindow))`; quiet: `!HasNews && !last.IsZero() && !last.After(now.Add(-quietDays*24h))`).
- [ ] **Step 5: Run** the same command — PASS; `make lint-diff` clean.
- [ ] **Step 6: Commit** `feat(tracks): with-news rule and shared fixture (#1076)`.

---

### Task 2: Swift twin `TrackNewsRule` and the track read

**Depends on:** Task 1 (fixture)

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/TrackNewsRule.swift`, `WatchtowerDesktop/Tests/Core/TrackNewsRuleTests.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/TrackQueries.swift` (`fetchInboxCards`), `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/InboxCards.swift` (`InboxTrackCard`)

**Interfaces:**
- Consumes: Task 1 fixture.
- Produces:
  - `package enum TrackNewsRule { static let newsWindow: TimeInterval = 72 * 3600; static let quietDays = 30; static func lastEventAt(updatedAt: String, newestEventAt: String?) -> Date; static func hasNews(track: InboxTrackCard, now: Date) -> Bool; static func isQuiet(track: InboxTrackCard, now: Date, days: Int = quietDays) -> Bool }` — `lastEventAt` returns `Date(timeIntervalSince1970: 0)` when neither parses (the existing sentinel), and the rule treats any `lastEventAt <= epoch` as unknown. Never read = `track.readAt == nil || track.readAt == ""`.
  - `InboxTrackCard.latestEventSummary: String` and `InboxTrackCard.newestRefHasAttachment: Bool` (init parameters with defaults `""` / `false`). The attachment flag is true when the track's newest item carries a `media_items` row: (a) Slack — the newest source ref: `parent_kind = 'slack'`, `slack_ts` = the ref's `ts`, `slack_channel_id` equal to the ref's `channel_id` or ending in `:<channel_id>` (namespaced ids); (b) mail — the newest `track_events` row whose `source_type` is a mail source: `parent_kind = 'gmail'` with `gmail_message_id = source_id`, or `parent_kind = 'imap'` with `parent_key = source_id`. Digest-built tracks only carry Slack refs; mail threads reach a track through a watch's events, so (b) is what gives a mail thread (the mockup's "Budget 2027 · mail") its chip. Step 0 of this task confirms the exact `source_type`/`source_id` values the watch scan writes for Gmail and IMAP items (`internal/customtracks`, `internal/automations/watch`) and pins them in a comment and the test. Read in the same `fetchInboxCards` read, active tracks only.

- [ ] **Step 1: Write the failing tests** in `TrackNewsRuleTests`: `testMatchesTheGoFixture` (loads `internal/tracks/testdata/track_news.json` via `#filePath` like `InboxRefStateParityTests`, builds an `InboxTrackCard` per case with `lastEventAt = TrackNewsRule.lastEventAt(...)`, asserts `hasNews`/`isQuiet` equal the case values, message names the case); `testFetchInboxCardsUsesTheSameLastEvent` (TestDatabase: a track updated 40 d ago with an event 1 d ago → card `lastEventAt` equals the event time; a track with garbage `updated_at` and no event → epoch); `testFetchInboxCardsReadsLatestEventSummary` (two events → the newer one's `summary`; no events → `""`); `testFetchInboxCardsFlagsAttachmentOnNewestRef` (an image `media_items` row on the newest ref, raw and namespaced channel id → true; on an older ref only → false); `testFetchInboxCardsFlagsAttachmentOnNewestMailEvent` (newest event from Gmail with a `media_items` image on that message id → true; same for IMAP; a Gmail event without media → false).
- [ ] **Step 2: Run** `make test-swift FILTER=TrackNewsRuleTests` — FAIL.
- [ ] **Step 3: Implement** `TrackNewsRule`; in `fetchInboxCards` add `(SELECT e.summary FROM track_events e WHERE e.track_id = t.id ORDER BY e.created_at DESC, e.id DESC LIMIT 1) AS latest_event_summary` and compute `lastEventAt` through `TrackNewsRule.lastEventAt`.
- [ ] **Step 4: Run** `make test-swift FILTER='TrackNewsRuleTests|InboxFeedQueriesTests'` — PASS (TRACKS-07 guard `testTrackCardsCountUnreadEventsAndExcludeDismissed` unchanged and green); `make lint-diff`.
- [ ] **Step 5: Commit** `feat(inbox): Swift twin of the track news rule (#1076)`.

---

### Task 3: `tracks dismiss --quiet-days / --ids` and the TRACKS-07 note

**Depends on:** Task 1

**Files:**
- Modify: `internal/db/tracks.go`, `internal/db/tracks_test.go`, `cmd/tracks.go`, `cmd/tracks_test.go`, `docs/inventory/tracks.md`
- Test (maybe new): `internal/customtracks/bound_test.go` (`TestDue_DismissedBoundTrackIsNeverScanned`)

**Interfaces:**
- Consumes: `tracks.NewsInput`, `tracks.IsQuiet`, `tracks.QuietDays`.
- Produces:
  - `type TrackNewsRow struct { ID int; ReadAt string; HasUpdates bool; UpdatedAt string; NewestEventAt string }` and `func (db *DB) ListActiveTrackNewsInputs() ([]TrackNewsRow, error)` — active tracks only, `COALESCE(read_at,'')`, `COALESCE((SELECT MAX(created_at) FROM track_events e WHERE e.track_id = t.id),'')`, ordered by id.
  - `func (db *DB) DismissActiveTracks(ids []int) (dismissed []int, err error)` — one transaction; ids de-duplicated in order; per id `UPDATE tracks SET dismissed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ? AND dismissed_at = ''`; `dismissed` = ids with one row changed; on error nothing is committed.
  - `func QuietTrackIDs(rows []db.TrackNewsRow, now time.Time, days int) []int` in `internal/tracks/news.go`.
  - `tracks dismiss` flags: `--quiet-days int`, `--dry-run`, `--ids string`, `--json`; `Args: cobra.RangeArgs(0, 1)`; Use line `dismiss (<id> | --quiet-days N --dry-run | --ids ID,…)`.

- [ ] **Step 1: Write the failing DB tests** — `TestListActiveTrackNewsInputs` (dismissed excluded, NULL read_at → "", newest event picked); `TestTracks07_BulkDismissSetsDismissedAtOnly` (an active auto track, an active custom track with `enabled = 1` and an `automation_id`, an already-dismissed track: after `DismissActiveTracks([a, c, a, d, 9999])` → returned `[a, c]`; every column of `a` and `c` except `dismissed_at` equals its before-image (full row compare, `read_at`, `has_updates`, `enabled`, `automation_id` included); `d` keeps its original `dismissed_at`; no `track_states` row added); `TestDismissActiveTracks_ErrorCommitsNothing` (a test-only `BEFORE UPDATE ON tracks WHEN NEW.id = <second> BEGIN SELECT RAISE(ABORT,'boom'); END` trigger → error, first id still active).
- [ ] **Step 2: Write the failing CLI tests** in `cmd/tracks_test.go`:
  - `TestTracksDismiss_QuietDryRunListsOnlyQuietActive` — seed (relative to `time.Now()`): has_updates old, never-read 2 d, read 40 d, read 10 d, dismissed 40 d, custom read 40 d, garbage `updated_at`; `--quiet-days 30 --dry-run --json` → last line decodes to exactly the keys `count`, `ids`; ids = the two 40 d active tracks (the garbage one absent); no `dismissed_at` changed.
  - `TestTracksDismiss_IdsDismissesActiveAndSkipsTheRest` — `--ids a,b,a,<dismissed>,9999 --json` → keys exactly `dismissed`, `skipped`, `ids`; `{"dismissed":2,"skipped":2,"ids":[a,b]}`.
  - `TestTracksDismiss_WriteErrorPrintsPartialEnvelope` — the abort trigger → exit code 1, last stdout line keys exactly `dismissed`, `of`, `error`, `dismissed` 0, `of` 2, `error` non-empty.
  - `TestTracksDismiss_BulkRefusedUnderAgentMarkers` — for each `agentEnvMarkers` entry: `--ids` fails with the `refuseUnderAgent` text and writes nothing; `--quiet-days 30 --dry-run --json` succeeds.
  - `TestTracksDismiss_FlagValidation` — table, each exit code 2 (`usageError`) and nothing written: no id and no flag; `<id>` with `--ids`; `--quiet-days 30` without `--dry-run`; `--dry-run` alone; `--quiet-days 0 --dry-run`; `--ids ""`; `--ids 1,x`; `--ids 0`.
  - `TestTracksDismiss_SingleIDUnchanged` — `tracks dismiss <id>` prints `Track #<id> dismissed` as today.
  - `internal/customtracks`: `TestDue_DismissedBoundTrackIsNeverScanned` (a bound, enabled custom track after `DismissActiveTracks` → `Due` false, so its still-enabled watch recipe's slot run makes no scan and no model call; existing gate in `watchslot.go`). Keep if an equivalent test already exists — then cite it instead.
- [ ] **Step 3: Run** `go test ./internal/db -run 'TestTracks07|TestListActiveTrackNews|TestDismissActiveTracks'`, `go test ./internal/customtracks -run TestDue` and `go test ./cmd -run TestTracksDismiss` — FAIL.
- [ ] **Step 4: Implement** the reads/writes, `QuietTrackIDs`, and the flag branches in `runTracksDismiss` (validation first, then `refuseUnderAgent("stop tracking threads in bulk")` for `--ids`; without `--json` print `N quiet tracks: 1, 2` / `Dismissed N tracks (S skipped)`; on a write error with `--json` print the envelope with `logredact.Full(err)` and return `&exitCodeError{code: 1, err: err}`).
- [ ] **Step 5: Amend `docs/inventory/tracks.md`** — under TRACKS-07's Observable add the paragraph below; add both new guards to its Test guards; add a Changelog line dated 2026-11-11 naming the note and "no guard relaxed":
  > **Bulk Stop Tracking (2026-11-11, Inbox redesign phase 3, approved with the spec in ask #638):** `watchtower tracks dismiss --ids …` — the Inbox's **Stop Tracking Quiet Ones…**, after `--quiet-days 30 --dry-run` named the ids and the owner confirmed their count — sets `dismissed_at` on each listed track that is still active and writes nothing else (no `read_at`, `has_updates`, `enabled` or recipe change). It is refused under an agent marker. `dismissed_at` stays the only negative state; Restore stays per track (the Stopped fold).
  Guards: `internal/db/tracks_test.go::TestTracks07_BulkDismissSetsDismissedAtOnly`, `cmd/tracks_test.go::TestTracksDismiss_BulkRefusedUnderAgentMarkers`.
- [ ] **Step 6: Run** both commands — PASS; `go test ./internal/tracks`; `make lint-diff`.
- [ ] **Step 7: Commit** (code + guards + inventory in one commit) `feat(tracks): bulk stop of quiet tracks via tracks dismiss (#1076)`.

---

### Task 4: `TracksBulkCLI` (Desktop wrapper)

**Depends on:** none (contract pinned in Global Constraints)

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/TracksBulkCLI.swift`, `WatchtowerDesktop/Tests/Core/TracksBulkCLITests.swift`

**Interfaces:**
- Consumes: `CLIRunnerProtocol.capture(args:timeout:)`, `InboxFoldersCLI.lastLine(_:)`, phase 1's `InboxBulkPlan` / `InboxBulkResult`.
- Produces:
  - `package enum TracksBulkCLIError: Error, Equatable, LocalizedError { case cliUnavailable, refused(String), unexpectedAnswer }` (texts: "The watchtower CLI isn't available", the message, "Unexpected answer from watchtower").
  - `package struct TracksBulkCLI { init(runner: (any CLIRunnerProtocol)?); static let timeout: TimeInterval = 60; static let timeoutMessage = "watchtower took too long to answer"; static func dryRunArgs(quietDays: Int) -> [String]; static func dismissArgs(ids: [String]) -> [String]; func planQuiet(days: Int) async throws -> InboxBulkPlan; func dismiss(ids: [String]) async -> InboxBulkResult }`

- [ ] **Step 1: Write the failing tests** (`FakeCLIRunner`): `testArgs` (`["tracks","dismiss","--quiet-days","30","--dry-run","--json"]`, `["tracks","dismiss","--ids","4,9","--json"]`); `testPlanDecodesIntegerIDsAsStrings` (`{"count":2,"ids":[4,9]}` → `InboxBulkPlan(ids: ["4","9"], count: 2)`); `testPlanNonZeroExitThrowsLastStderrLine`; `testPlanWithoutPinnedKeysIsUnexpected`; `testNoRunnerIsUnavailable`; `testDismissDone` (`{"dismissed":3,"skipped":1,"ids":[…]}` → `.done(count: 3, skipped: 1)`); `testDismissPartial` (exit 1, stdout `{"dismissed":2,"of":5,"error":"disk full"}` → `.partial(done: 2, of: 5, error: "disk full")`); `testDismissNothingWrittenIsFailed` (same with `dismissed` 0 → `.failed("disk full")`); `testDismissRefusalIsFailedWithStderr` (exit 1, no JSON → `.failed(<last stderr line>)`); `testDismissTimeoutIsUnknownOutcome` (the runner throws `CLIRunnerError.nonZeroExit(code: -1, …)` → `.failed(TracksBulkCLI.timeoutMessage)`); `testPlanTimeoutThrowsRefusedWithTimeoutMessage`.
- [ ] **Step 2: Run** `make test-swift FILTER=TracksBulkCLITests` — FAIL.
- [ ] **Step 3: Implement** (decode the last non-empty stdout line; the dismiss path never throws).
- [ ] **Step 4: Run** — PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(inbox): TracksBulkCLI wrapper (#1076)`.

---

### Task 5: `TrackThreadsSummary` — split, lines, chips, copy

**Depends on:** Task 2

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/TrackThreadsSummary.swift`, `WatchtowerDesktop/Tests/Core/TrackThreadsSummaryTests.swift`

**Interfaces:**
- Consumes: `TrackNewsRule`, `InboxTrackCard` (with `latestEventSummary`), `Track.decodedSourceRefs`.
- Produces:
  - `package enum TrackNewsReason: Equatable { case replyToYou, decision, mention, attachment; var label: String }` — labels "reply to you", "decision", "mention", "attachment" (the spec's four).
  - `package struct TrackThreadsSummary: Equatable { let news: [InboxTrackCard]; let quietCount: Int; let quietOverLimitCount: Int; static let visibleNewsLimit = 5; static func build(tracks: [InboxTrackCard], now: Date) -> TrackThreadsSummary; static func latestLine(_ card: InboxTrackCard) -> String; static func reason(_ card: InboxTrackCard) -> TrackNewsReason?; static func newCountText(_ card: InboxTrackCard) -> String?; var rowPreview: String; var rowMeta: String; var pillCount: Int?; var isUnread: Bool; var paneSubtitle: String; var quietNote: String?; var showsStopQuiet: Bool }`
  - Rules: `news` sorted by `lastEventAt` desc, then track id desc; `quietCount` = active − news; `quietOverLimitCount` = `isQuiet` count. `latestLine` = `latestEventSummary` if non-empty, else the newest source ref (max `ts`) as `<author>: “<text>”`, else the first non-empty line of `track.context`, else "". `reason`: `.replyToYou` when `ballOn` non-empty and equals `assigneeUserID`; else `.decision` when `category` is `decision` or `decision_needed` or `decisionSummary` non-empty; else `.mention` when the newest source ref's text contains `<@<raw assignee id>` (the part of `assigneeUserID` after its last `:`, Slack's mention markup, also `<@U…|name>`); else `.attachment` when `newestRefHasAttachment`; else nil. Precedence = that order. `newCountText` = "N new" when `newEventCount > 0`, else nil.
  - Copy: `rowPreview` = the first two `news` as `<track.text>: <latestLine>` (or `track.text` alone when the line is empty) joined by "\n"; no news and active > 0 → "Nothing new in N threads" ("1 thread"); no active → "". `rowMeta` = "N quiet threads folded" ("1 quiet thread folded"), "" at 0. `pillCount` = news count, nil at 0. `isUnread` = news non-empty. `paneSubtitle` = "N threads with news for you · M quiet · scanned after every sync" (the mockup's line). `quietNote` = "N threads have nothing new for you. M of them have been quiet for over 30 days." (second sentence only when M > 0; nil when N = 0; singular forms "1 thread has" / "1 of them has"). `showsStopQuiet` = M > 0.

- [ ] **Step 1: Write the failing tests** — `testSplitsNewsAndQuietWithTheRule`, `testNewsNewestFirst`, `testLatestLinePrefersEventThenSourceRefThenContext`, `testReasonReplyToYouBeatsDecision`, `testReasonDecisionBeatsMention`, `testReasonMentionFromSlackMarkup` (namespaced assignee, `<@U1>` and `<@U1|name>`; another user's mention → not mention), `testReasonAttachmentFromFlag`, `testReasonNilWithoutSignal`, `testRowCopyWithNews` (two lines, pill = count, meta), `testRowCopyWithoutNews` ("Nothing new in 3 threads", no pill, not unread), `testSingularCopy` (1 thread / 1 quiet thread folded / "1 thread has…"), `testQuietNoteAndButtonOnlyWithOldQuiet`.
- [ ] **Step 2: Run** `make test-swift FILTER=TrackThreadsSummaryTests` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(inbox): Track my threads summary and copy (#1076)`.

---

### Task 6: `IdeaDailyBatch` — selector, store, state, presses, copy

**Depends on:** none

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/IdeaDailyBatch.swift`, `WatchtowerDesktop/Tests/Core/IdeaDailyBatchTests.swift`

**Interfaces:**
- Consumes: `Idea` (`awaitsVerdict`, `createdAt`, `status`, `updatedAt`), `AutomationDates.parse`, phase 1's `InboxToday.startOfToday(now:calendar:)` (until phase 1 merges, Task 6's lane uses `calendar.startOfDay(for:)` behind the same call and switches when it lands).
- Produces:
  - `package struct IdeaBatchState: Equatable, Sendable { var batchIDs: [Int]; var remaining: [Idea]; var keptToday: [Idea]; var backlogCount: Int; var olderCount: Int; var nextAvailable: Int; var size: Int; var judgedCount: Int { get } }` — `remaining` = batch ideas still awaiting a verdict, batch order; `keptToday` = ideas now `active` (kinds that await a verdict) whose `updatedAt` is at or after local midnight (phase 1's `InboxToday.startOfToday`), newest first — the whole day, so Next never empties it; `backlogCount` = awaiting verdict and not in `remaining`; `olderCount` = awaiting verdict and older than 30 days; `nextAvailable` = min(size, candidates count); `judgedCount` = `batchIDs.count − remaining.count`.
  - `package struct IdeaDailyBatch { static let sizeKey = "ideas.dailyBatch"; static let dateKey = "ideas.batch.date"; static let idsKey = "ideas.batch.ids"; static let defaultSize = 13; static let windowDays = 30; init(defaults: UserDefaults); var size: Int { get }; static func candidates(_ ideas: [Idea], now: Date) -> [Idea]; static func isOld(_ idea: Idea, now: Date) -> Bool; static func state(ideas: [Idea], batchIDs: [Int], now: Date, size: Int, calendar: Calendar) -> IdeaBatchState; func today(ideas: [Idea], now: Date, calendar: Calendar) -> IdeaBatchState; func next(ideas: [Idea], now: Date, calendar: Calendar) -> IdeaBatchState }` — `today` stores a new batch (first `size` candidates) when the stored date is not today's local date, the ids are missing/not `[Int]`, or the stored batch is empty; otherwise only reads. `next` replaces the stored ids with the first `size` candidates now (the old batch's judged ideas are no longer candidates; its unjudged leftovers come first again by age) and keeps today's date. An unparseable `created_at` is neither a candidate nor old.
  - `package enum IdeaBatchPress: CaseIterable, Equatable { case keep, drop, later, makeTarget; init?(key: Character); var key: Character; var title: String }` — keys `k`/`d`/`l`/`t` (either case), titles "Keep", "Drop", "Later", "Make a Target…".
  - Copy on `IdeaBatchState`: `rowPreview`, `rowMeta`, `pillCount: Int?`, `isUnread`, `paneSubtitle`, `nextTitle` ("Next N", N = `size`). Remaining > 0 → preview "Today’s N ideas to judge. Top one: “<title>”." ("Today’s 1 idea to judge…"), pill N, unread; batch handed out and none left → "Today’s batch done · N in the backlog", no pill, meta = older part only; nothing handed out and no candidate → "Nothing to judge from the last 30 days". `rowMeta` otherwise = "N in the backlog" (N > 0) and "M older than 30 days" (M > 0) joined " · ". `paneSubtitle` = "Today’s batch · J of T judged · N more in the backlog".

- [ ] **Step 1: Write the failing tests** (`UserDefaults(suiteName:)` per test, removed in tearDown): `testCandidatesOldestFirstWithinThirtyDays` (incl. a 31-day-old and a decision that is not chat-born, both excluded); `testFirstReadOfDayStoresBatch` (date key = local `yyyy-MM-dd`, ids = first 13); `testLaterReadKeepsStoredIDsAndDropsJudged` (a judged idea leaves `remaining`, a newer candidate does not join); `testNewDayRepicks`; `testEmptyStoredBatchIsRepicked`; `testCorruptStoredIDsRepick` (a string in `ideas.batch.ids`); `testSizeFromDefaults` (unset, 0, −3, "x" → 13; 5 → 5); `testNextReplacesTheBatch` (after judging 13, Next stores 13 new ids; `judgedCount` back to 0; ideas kept from the first batch still in `keptToday`); `testStoredIDOfDeletedIdeaIsJudged` (id not in the feed → counted judged, not remaining); `testKeptTodaySpansBatchesAndExcludesYesterday` (kept before and after Next both listed; one kept yesterday absent); `testBacklogAndOlderCounts`; `testRowCopy` (three states + singular); `testPaneSubtitle`; `testPressKeys` (`k`, `K`, `t` → cases; `x` → nil).
- [ ] **Step 2: Run** `make test-swift FILTER=IdeaDailyBatchTests` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(inbox): daily idea batch (#1076)`.

---

### Task 7: `IdeaQueries.dropMany`, awaiting read, card facts, IDEA-04 note

**Depends on:** none

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/IdeaQueries.swift`, `WatchtowerDesktop/Tests/Core/IdeaQueriesTests.swift`, `docs/inventory/ideas.md`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/IdeaBatchCardFacts.swift`

**Interfaces:**
- Produces:
  - `package static func fetchAwaitingVerdict(_ db: Database) throws -> [Idea]` — `(status = 'proposed' OR needs_review = 1) AND reviewKindCond AND status != 'merged'`, `created_at, id` ascending.
  - `package static func dropMany(_ db: Database, ids: [Int]) throws -> Int` — inside the caller's one `dbPool.write`; chunks of 500 ids; `UPDATE ideas SET status = 'dropped', needs_review = 0, review_reason = '', updated_at = strftime(…) WHERE id IN (…) AND (status = 'proposed' OR needs_review = 1) AND reviewKindCond`; returns rows changed.
  - `package struct IdeaBatchCardFacts: Equatable { let quote: String; let sourceLabel: String; static func read(_ db: Database, ideaID: Int) throws -> IdeaBatchCardFacts }` — quote = the two newest mentions (by `said_at, id`) as `<author>: “<quote>”` joined " · ", each quote cut at 200 characters with "…"; sourceLabel = the newest mention's `IdeaMention.Source.label`, "" without mentions.

- [ ] **Step 1: Write the failing tests** — `testIdeas04_DropManyClearsNeedsReviewAndTouchesOnlyAwaiting` (a proposed idea, a `rejected` flagged one, an `active` one, a mined decision, a `not_now` unflagged one: `dropMany` of all five returns 2; the two are `dropped` with `needs_review = 0`, `review_reason = ''`; the other three rows are byte-identical); `testDropManyEmptyIsZero`; `testDropManyOverChunkSize` (1 200 proposed ideas → 1 200); `testFetchAwaitingVerdictOldestFirst`; `testCardFactsQuoteAndSource` (three mentions → newest two, newest first; a 300-char quote cut to 200 + "…"; no mentions → empty facts).
- [ ] **Step 2: Run** `make test-swift FILTER=IdeaQueriesTests` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Amend `docs/inventory/ideas.md`** — add to IDEA-04 (after the clearability paragraph), add the guard to its Test guards, add a 2026-11-11 Changelog line ("no guard relaxed"):
  > **Clear Old Ideas (2026-11-11, Inbox redesign phase 3, approved with the spec in ask #638):** one owner press applies `dropped` to every idea awaiting a verdict whose `created_at` is older than 30 days, after a confirmation naming the count — `IdeaQueries.dropMany(_:ids:)`, one GRDB transaction over the ids the confirmation read, touching only those still awaiting a verdict and clearing `needs_review`/`review_reason` like every owner action. It is one owner action applied to many ideas: owner-only, never automatic or scheduled. A dropped idea resurfaces under this contract like any other.
  Guard: `WatchtowerDesktop/Tests/Core/IdeaQueriesTests.swift::testIdeas04_DropManyClearsNeedsReviewAndTouchesOnlyAwaiting`.
- [ ] **Step 5: Run** `make test-swift FILTER=IdeaQueriesTests` — PASS (existing `testIdeas04_*` green); `make lint-diff`.
- [ ] **Step 6: Commit** (code + guard + inventory) `feat(ideas): drop old ideas in bulk (#1076)`.

---

### Task 8: `ActionStripViewModel` — panes, routes, batch, bulk presses, row rules

**Depends on:** Tasks 4, 5, 6, 7 (and phase 1)

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Actions/ActionStripViewModel.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/InboxFolderEntries.swift` (`Inputs`, and phase 1's row builder cases `.legacyTracks` / `.legacyIdeas`)
- Create: `WatchtowerDesktop/Tests/Core/ActionStripTracksIdeasTests.swift`
- Modify (expectations only): phase 1's row-builder tests for the two entries.

**Interfaces:**
- Consumes: Tasks 4–7; phase 1's `InboxBulkPressModel`, `InboxRowContent`, `InboxRowPill`.
- Produces (on `ActionStripViewModel`):
  - `package let quietTracksPress: InboxBulkPressModel`, `package let oldIdeasPress: InboxBulkPressModel`
  - `package var trackSummary: TrackThreadsSummary` (from `feed.tracks`, `clock()`)
  - `package private(set) var ideaBatch: IdeaBatchState` — set in `refresh()` through `IdeaDailyBatch(defaults:).today(ideas: feed.ideas, now: clock(), calendar: .current)`
  - `package func takeNextIdeaBatch()`
  - `package private(set) var openedNewsTrackID: Int?`, `package var openedNewsTrack: InboxTrackCard?` (nil when not in `feed.tracks`), `package func openNewsTrack(_ id: Int)`, `package func closeNewsTrack()` — reset by `selectFolder`, `selectEntry`, `open(folder:select:)`; cleared by `refresh()` when the track left `feed.tracks`.
  - `package func planQuietTracks() async throws -> InboxBulkPlan`, `package func stopTrackingQuiet(_ ids: [String]) async -> InboxBulkResult` (always `await refresh()` before returning). On any `.failed` from the CLI (a timeout, a lost answer — the transaction may have committed before the child was killed) it reconciles with one GRDB read of the planned ids' `dismissed_at`: n > 0 now stopped → `.partial(done: n, of: ids.count, error: <the CLI text>)`, n = 0 → the `.failed` as is. So the owner never sees "failed" for threads that did stop.
  - `package func planOldIdeas() async throws -> InboxBulkPlan` (one read: `fetchAwaitingVerdict` filtered by `IdeaDailyBatch.isOld`), `package func clearOldIdeas(_ ids: [String]) async -> InboxBulkResult` (`dbPool.write { dropMany }` → `.done(count:, skipped: ids.count − count)`; error → `.failed(error.localizedDescription)`; then `refresh()`)
  - `InboxFolderEntries.Inputs.ideaBatch: IdeaBatchState?` (default nil = `IdeaDailyBatch.state` over the first `defaultSize` candidates, nothing stored)
  - Stored `findCLI` so the bulk runner is `cliRunner ?? findCLI()` (reuse phase 2's property if it already exists).
- Behaviour changes: `showEntry` — `.legacyTracks` and `.legacyIdeas` select the entry and open no legacy list (`legacyList` stays nil; `.legacyMessages` unchanged); `showLegacy(.tracks)` / `showLegacy(.ideas)` (route `.legacy`) select the root entry without opening the list; card routes (`.track(id)`, `.idea(id)`) unchanged. Row builder: `.legacyTracks` takes preview/meta/isUnread from `trackSummary` and pill `pillCount` with the news tone; `.legacyIdeas` from `ideaBatch` with the neutral tone. The refresh still writes nothing to the database (STRIP-02; the batch store is UserDefaults).

- [ ] **Step 1: Write the failing tests** (TestDatabase, `FakeCLIRunner`, a per-test defaults suite, a mutable clock box):
  - `testSelectingTrackMyThreadsShowsPaneWithoutLegacyList` / `testSelectingIdeaFinderShowsPaneWithoutLegacyList` — `selectEntry("tracks")` → `entrySelection == "tracks"`, `legacyList == nil`, no `read_at` written.
  - `testRouteToLegacyTracksSelectsEntry` — `open(folder: nil, select: .legacy(.tracks))` → root, entry "tracks", `legacyList == nil`.
  - `testOpenedNewsTrackClosesWhenTrackLeavesActiveList` — open a news track, dismiss it in the DB, `refresh()` → `openedNewsTrackID == nil`.
  - `testFirstReadOfDayStoresBatchAndLaterReadsKeepIt`, `testReadAfterMidnightPicksNewBatch` (clock 23:59 local → refresh; clock next day 00:01 → refresh → new date key and new ids).
  - `testStopTrackingQuietRunsDryRunThenExactIDs` — runner records `[dryRunArgs(quietDays: 30), dismissArgs(ids: <plan ids>)]` in that order; result `.done`; one extra read happened.
  - `testStopTrackingQuietFailureReportsCLIText` — runner exits 1 with the envelope `dismissed` 0 → `.failed(<error>)`; tracks unchanged.
  - `testStopTrackingQuietTimeoutAfterCommitReportsWhatStopped` — the fake runner dismisses the ids in the DB, then throws the timeout → `.partial(done: 2, of: 2, error: TracksBulkCLI.timeoutMessage)`; with nothing written → `.failed(TracksBulkCLI.timeoutMessage)`.
  - `testClearOldIdeasSkipsIdeasJudgedMeanwhile` — plan 3 old ideas; approve one directly; confirm → `.done(count: 2, skipped: 1)`.
  - `testRowsUseNewsAndBatchRules` — root rows for both entries carry `TrackThreadsSummary` / `IdeaBatchState` preview, meta and pill counts.
  - Existing `ActionStripAutomationOutputTests::testRefreshIsAPureRead` stays green unchanged.
- [ ] **Step 2: Run** `make test-swift FILTER=ActionStripTracksIdeasTests` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `make test-swift FILTER='ActionStripTracksIdeasTests|ActionStripAutomationOutputTests|InboxFolderEntries'` plus phase 1's row-builder test class — PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(inbox): view model for thread news and the idea batch (#1076)`.

---

### Task 9: `InboxTracksNewsPane`

**Depends on:** Task 5 (and phase 1)

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Inbox/InboxTracksNewsPane.swift`, `WatchtowerDesktop/Tests/InboxTracksNewsPaneTests.swift`

**Interfaces:**
- Consumes: `TrackThreadsSummary`, `TrackNewsReason`, `InboxPaneHeader`, `InboxBulkPressButton`, `InboxBulkPressModel`.
- Produces:
  - `struct InboxTracksNewsPane: View { init(summary: TrackThreadsSummary, quietPress: InboxBulkPressModel, onPlanQuiet: @escaping () async throws -> InboxBulkPlan, onStopQuiet: @escaping ([String]) async throws -> InboxBulkResult, onOpenThread: @escaping (Int) -> Void, onAllThreads: @escaping () -> Void) }` — in one readable column: header (tile `.threads`, "Track my threads", `summary.paneSubtitle`, action **All Threads**); "With news for you · N" heading; one `.kitRow` button per visible news track (title `track.text`, `latestLine` secondary, `newCountText` trailing, reason `Chip`); "N more with news" fold (local `@State`) past `visibleNewsLimit`; the `quietNote` with `InboxBulkPressButton(title: "Stop Tracking Quiet Ones…", confirmTitle: …)` only when `showsStopQuiet`.
  - `struct InboxTrackBackBar: View { init(onBack: @escaping () -> Void) }` — `Label("Track my threads", systemImage: "chevron.left")`, `.kitQuiet`, help "Back to Track my threads".

- [ ] **Step 1: Write the failing ViewInspector tests** — `testListsVisibleNewsAndFoldsTheRest` (7 news → 5 rows + "2 more with news"); `testRowShowsLatestLineCountAndChip`; `testQuietNoteButtonOnlyWithOldQuiet`; `testConfirmTitlePluralises` ("Stop Tracking 1 Thread", "Stop Tracking 4 Threads"); `testOpeningARowCallsOnOpenThreadWithItsID`; `testNoNewsShowsQuietNoteOnly`.
- [ ] **Step 2: Run** `make test-swift FILTER=InboxTracksNewsPaneTests` — FAIL.
- [ ] **Step 3: Implement** (tokens only; row actions never resize rows).
- [ ] **Step 4: Run** — PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(inbox): Track my threads news pane (#1076)`.

---

### Task 10: `IdeaBatchPane` and the verdict dispatch

**Depends on:** Tasks 6, 7 (and phase 1)

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Inbox/IdeaBatchPane.swift`, `WatchtowerDesktop/Sources/ViewModels/IdeasViewModel+Batch.swift`, `WatchtowerDesktop/Tests/IdeaBatchPaneTests.swift`

**Interfaces:**
- Consumes: `IdeaBatchState`, `IdeaBatchPress`, `IdeaBatchCardFacts`, `InboxPaneHeader`, `IdeasViewModel` (`approve`, `reject`, `notNow`, `convertToTarget`, `pendingWrites`, `errorMessage`), `InboxIdeaPane.writeKey(_:)`.
- Produces:
  - `extension IdeasViewModel { func press(_ press: IdeaBatchPress, on idea: Idea) async -> Int? }` — keep → `approve`, drop → `reject`, later → `notNow(idea)`, makeTarget → `convertToTarget` (returns the target id); run under `pendingWrites.run(InboxIdeaPane.writeKey(idea.id))`; a press while that key is pending does nothing and returns nil.
  - `struct IdeaBatchPane: View { init(state: IdeaBatchState, isWriting: Bool, errorMessage: String?, loadFacts: @escaping (Int) async -> IdeaBatchCardFacts?, onPress: @escaping (IdeaBatchPress, Idea) -> Void, onNext: @escaping () -> Void, onBacklog: @escaping () -> Void, onDismissError: @escaping () -> Void) }` — header (tile `.ideas`, "Idea finder", `paneSubtitle`, action "Backlog · N"); progress (`judgedCount` of `batchIDs.count`); the first `remaining` idea as one card (chip "<kind> · from <sourceLabel>, <age>", title, essence, quote) with **Keep** (`.kitPrimary`), **Drop**, **Later**, **Make a Target…** (`.kitQuiet`); the key hint line; "Kept today" rows; with nothing remaining: "Today’s batch done" and `nextTitle` when `nextAvailable > 0`, else "Nothing left to judge from the last 30 days". Keys via `.onKeyPress` on the focused pane through `IdeaBatchPress(key:)`, ignored with ⌘/⌃/⌥ held and while `isWriting`. Facts loaded with `.task(id: idea.id)`; the error shows in `WriteErrorBanner`.

- [ ] **Step 1: Write the failing tests** — dispatch (TestDatabase + `IdeasViewModel`): `testKeepWritesActive`, `testDropWritesRejectedNotDropped`, `testLaterWritesNotNowWithoutDate`, `testEachPressClearsNeedsReview`, `testPressWhilePendingIsIgnored` (two concurrent presses on one idea → one write, the second returns nil); view (ViewInspector): `testShowsFirstRemainingWithFourButtonsKeepProminent`, `testBatchDoneShowsNextWithSize` ("Next 13"; "Next 5" with size 5), `testNothingLeftHidesNext`, `testBacklogButtonTitle`, `testKeptTodayListsKeptIdeas` (from `keptToday`).
- [ ] **Step 2: Run** `make test-swift FILTER=IdeaBatchPaneTests` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `make test-swift FILTER='IdeaBatchPaneTests|IdeasViewModelTests'` — PASS (IDEA-04 guard `testIdeas04_ResurfacedRejectedIdeaLeavesReviewQueueViaActivate` green); `make lint-diff`.
- [ ] **Step 5: Commit** `feat(inbox): Idea finder one-card pane (#1076)`.

---

### Task 11: Wiring, Clear Old Ideas in the Backlog header, shots, docs

**Depends on:** Tasks 8, 9, 10

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Inbox/ActionStripView.swift` (`readingPane(_:)` cases, `legacyHeader(_:)` for `.ideas`, the `ideaFacts` loader through `appState.databaseManager`), `WatchtowerDesktop/Tests/DesignShots/DesignShotCatalog.swift`
- Create: `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+InboxRedesignPhase3.swift`, `WatchtowerDesktop/Tests/InboxTracksIdeasWiringTests.swift`
- Modify docs: `docs/guide/features/inbox.md`, `docs/guide/features/tracks.md`, `docs/guide/features/ideas-and-decisions.md`, `docs/features/inbox-redesign.md` (phase 3 section), `CLAUDE.md` (append to the inbox-redesign Feature Notes line: `TrackNewsRule` + `track_news.json`, `tracks dismiss --quiet-days/--ids`, `IdeaDailyBatch`, `IdeaQueries.dropMany`), `docs/inventory/reaction-commands.md` (changelog line: the root's Track my threads and Idea finder entries open panes over their producers' own rows instead of lists; STRIP-01/02 text and guards unchanged)

**Interfaces:**
- Consumes: Tasks 8–10.
- Behaviour: `.legacyTracks?` → `InboxTracksNewsPane` over `vm.trackSummary`, or, when `vm.openedNewsTrack` is set, `InboxTrackBackBar` above `InboxTrackPane` (Done → `vm.markTrackDone`, Stop watching → `vm.stopWatching`, Restore → `vm.restoreTrack`; `InboxCardPlaceholder` when `tracks`/`trackControls` are nil); **All Threads** → `vm.openLegacy(.tracks)`. (All Threads is not in the mockup; it is kept because the spec keeps Restore per track in the Stopped fold, which lives only in that list once the news pane replaces it.) `.legacyIdeas?` → `IdeaBatchPane` over `vm.ideaBatch` (`onPress` → `ideas.press`, then `vm.refresh()`, and a returned target id → `onGoToTarget`; Next → `vm.takeNextIdeaBatch()`; Backlog → `vm.openLegacy(.ideas)`). The `.ideas` legacy header adds `InboxBulkPressButton(title: "Clear Old Ideas…", confirmTitle: …, model: vm.oldIdeasPress)` when `vm.ideaBatch.olderCount > 0`.

- [ ] **Step 1: Write the failing wiring tests** — `testTracksEntryDrawsNewsPane`, `testOpenedThreadDrawsBackBarAndTrackPane`, `testIdeasEntryDrawsBatchPane`, `testBacklogHeaderShowsClearOldIdeasOnlyWithOldIdeas`.
- [ ] **Step 2: Run** `make test-swift FILTER=InboxTracksIdeasWiringTests` — FAIL; implement the wiring; run — PASS.
- [ ] **Step 3: Add shots** (acme / example.com, colleague placeholders, fixed clock): `inbox-r-threads` (6 news, 2 folded, quiet note with the button), `inbox-r-threads-detail` (back bar over a track card), `inbox-r-ideas` (3 of 13 judged, card, Kept today), `inbox-r-ideas-done` (batch done + Next 13), `inbox-r-ideas-backlog` (legacy ideas list with Clear Old Ideas…). Run `make desktop-shots DESKTOP_SHOTS=<scratch dir>` and look at light and dark. Three elements have no screen in the agreed mockup — the back bar over a thread (`inbox-r-threads-detail`), **All Threads** in the news pane header (`inbox-r-threads`) and **Clear Old Ideas…** in the Backlog header (`inbox-r-ideas-backlog`); they follow the mockup's existing pieces (the `kbtn quiet` header action, the `.bulk` note row) and the PR description lists these three shots under "not in the mockup — owner look" so the owner signs off on them before the phase merges into the feature branch.
- [ ] **Step 4: Docs** per `docs/guide/WRITING.md`: inbox page (the two entries' rows and panes), tracks page ("with news", Stop Tracking Quiet Ones…, All Threads, Restore in Stopped), ideas page (daily batch of 13, Keep / Drop / Later / Make a Target…, keys, Next 13, Backlog, Clear Old Ideas…, Dropped vs Later, Activate). Feature note phase 3 section: the rule and its twins, CLI contract, batch keys, presses, and v1 limits (a bulk-stopped custom track keeps its watch recipe enabled — per the approved TRACKS-07 note the bulk write is `dismissed_at` only; the slot's `Due` gate skips a dismissed track, so the recipe runs no scan and no model call, and Restore resumes it; the batch is per Mac in UserDefaults, like `inbox.folder` — each Mac has its own database, and the phone is out of scope).
- [ ] **Step 5: Run** `make test-swift FILTER='InboxTracksIdeasWiringTests|InboxReadingPaneTests'`, `go test ./docs/guide`, `make lint-diff` — PASS.
- [ ] **Step 6: Commit** `feat(inbox): wire thread news and idea batch panes, shots and docs (#1076)`.

---

## Dependency graph

T1 → T2, T3; T2 → T5; T4, T6, T7 independent; T5 → T9; T6, T7 → T10; T4, T5, T6, T7 → T8; T8, T9, T10 → T11. Parallel lanes: {T1→T3}, {T2→T5→T9}, {T4}, {T6, T7→T10} — each in its own worktree; T8 and T11 run after the merge.

## Self-review notes

- Spec coverage: news rule + twins + fixture (T1, T2), news list pane + push + back (T8, T9, T11), quiet note + CLI (T3, T4, T8, T9), TRACKS-07 note (T3), daily batch + Next (T6, T8, T10), one-card pane + keys (T10), Backlog · N (T10, T11), Clear Old Ideas + dropMany + IDEA-04 note (T7, T8, T11), row/pill rules (T5, T6, T8), shots and guide (T11).
- Plan calls (owner may overturn): track ids are JSON integers in the tracks CLI; `--quiet-days` requires `--dry-run` (the write is always `--ids`); reason chips: mention from Slack mention markup in the newest source ref, attachment from a `media_items` row on it; "All Threads" header action keeps the Stopped fold (Restore) reachable; Next replaces the batch; Later uses today's `notNow` (status `not_now`, no date); the inventory notes cite the spec's approval (ask #638).
