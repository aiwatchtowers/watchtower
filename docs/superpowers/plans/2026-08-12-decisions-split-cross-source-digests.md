# Decisions Split + Cross-Source Digests Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Narrow the Ideas registry to ideas/proposals (decisions born `active`, no review), move decisions into a cross-source deduplicated ledger under Digests → Decisions, make the Digests tab a cross-source feed (Slack + Gmail/Jira stream digests + meeting recaps), and decouple stage-1 stream-digest generation + Jira comment sync from `ideas.enabled`.

**Architecture:** Spec: `docs/superpowers/specs/2026-08-12-decisions-split-cross-source-digests-design.md`. The consolidator keeps doing decision dedup (IDEA-05) — only the birth status and the UI home change. Stage 1 gets its own daemon phase behind a new `streams` config block. Swift: Ideas tab drops decisions; the Digests tab's Decisions segment reads `ideas WHERE kind='decision'`; a new union feed adds `stream_digests` + meeting recaps next to Slack digests.

**Tech Stack:** Go 1.25 (goose migrations, modernc sqlite), SwiftUI + GRDB.

## Global Constraints

- Everything committed to the repo is English (docs, comments, commit messages).
- IDEA-01..05 guard tests: assertions must NOT be weakened, renamed, or split (`docs/inventory/ideas.md`).
- Dual-path pairs change together: Go `CountIdeasForReview` ↔ Swift `IdeaQueries.countForReview`/`fetchForReview`.
- New migration number is `00053` (current highest: `00052_transcripts_fts.sql`). Mirror schema changes into `internal/db/schema.sql` and regenerate the golden: `go test ./internal/db/ -run TestSchemaGolden -update`.
- Go verification: `go build ./... && go vet ./...`, targeted `go test ./internal/... ./cmd/...` packages per task.
- Swift verification: `cd WatchtowerDesktop && swift build` then `swift test --filter <TestClass>`; capture the real exit code (never pipe through `tail`/`head`).
- Commit after every task (small commits, imperative messages, `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` trailer).
- Timestamps written by SQL must match the ISO format Go writes to `ideas.updated_at` (check an existing row / `CreateIdeaTx` before writing the migration).

---

### Task 1: Migration 00053 — status flip + read markers

**Files:**
- Create: `internal/db/migrations/00053_decisions_split.sql`
- Modify: `internal/db/schema.sql` (ideas + stream_digests table definitions)
- Test: `internal/db/migrations_test.go` (or the package's existing migration-test file — follow the pattern of the 00050 tests)

**Interfaces:**
- Produces: `ideas.seen_at TEXT NULL` (ledger read marker), `stream_digests.read_at TEXT NULL` (feed read marker). All previously-`proposed` decisions become `active`.

- [ ] **Step 1: Write the failing test** — in the migrations test file, following the existing migration-test pattern (open a DB, run migrations, assert):

```go
func TestMigration00053_DecisionsSplit(t *testing.T) {
	database := openTestDB(t) // whatever helper the neighboring migration tests use
	// Seed: one proposed decision, one proposed idea (insert via SQL with the
	// same column set the 00050 tests use).
	_, err := database.Exec(`INSERT INTO ideas (kind, title, essence, status, source) VALUES
		('decision', 'D', 'd', 'proposed', 'mined'),
		('idea', 'I', 'i', 'proposed', 'mined')`)
	require.NoError(t, err)
	// Migration already ran on open in this codebase — if so, instead assert on a
	// pre-seeded fixture DB per the house pattern; otherwise re-run goose Up.
	var decisionStatus, ideaStatus string
	require.NoError(t, database.QueryRow(`SELECT status FROM ideas WHERE kind='decision'`).Scan(&decisionStatus))
	require.NoError(t, database.QueryRow(`SELECT status FROM ideas WHERE kind='idea'`).Scan(&ideaStatus))
	require.Equal(t, "proposed", ideaStatus) // untouched
	// seen_at / read_at columns exist:
	_, err = database.Exec(`SELECT seen_at FROM ideas LIMIT 1`)
	require.NoError(t, err)
	_, err = database.Exec(`SELECT read_at FROM stream_digests LIMIT 1`)
	require.NoError(t, err)
}
```

NOTE for implementer: migrations apply on `db.Open`, so inserting *after* open cannot test the flip directly. Use the house approach used by the enum-expansion migration tests (00002/00003 style): if they seed via an old-schema fixture, do the same; if no such harness exists, test the flip by asserting the migration SQL is idempotent + column presence, and cover the flip semantics in the Task 2 consolidate test instead. Do not invent a new migration-test harness.

- [ ] **Step 2: Run it, verify the relevant assertions fail** (`go test ./internal/db/ -run TestMigration00053 -v`)

- [ ] **Step 3: Write the migration**

```sql
-- +goose Up
UPDATE ideas SET status = 'active', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
 WHERE kind = 'decision' AND status = 'proposed';
ALTER TABLE ideas ADD COLUMN seen_at TEXT;
ALTER TABLE stream_digests ADD COLUMN read_at TEXT;

-- +goose Down
ALTER TABLE ideas DROP COLUMN seen_at;
ALTER TABLE stream_digests DROP COLUMN read_at;
-- The status flip is deliberately not reverted.
```

Match the `updated_at` format to what Go actually writes (verify first; adjust `strftime` if the codebase uses a different ISO shape). Mirror both columns into `internal/db/schema.sql`.

- [ ] **Step 4: Regenerate schema golden, run db tests** (`go test ./internal/db/ -run TestSchemaGolden -update && go test ./internal/db/`)

- [ ] **Step 5: Commit** (`git commit -m "feat(db): migration 00053 - flip proposed decisions to active, add seen_at/read_at markers"`)

### Task 2: Consolidator — mined decisions born `active`

**Files:**
- Modify: `internal/ideas/consolidate.go` (`applyNewIdeaOp`, around line 651-705)
- Test: `internal/ideas/consolidate_test.go` (existing test file for this package)

**Interfaces:**
- Consumes: `db.Idea{Kind, Title, Essence, Status}` → `CreateIdeaTx` (empty Status defaults to `proposed` in `internal/db/ideas.go:76-80` — leave that default alone).
- Produces: `new_decision` ops create rows with `status='active'`; `new_idea` ops still create `status='proposed'`.

- [ ] **Step 1: Write the failing test.** Find the existing test that drives `applyConsolidateOps`/`Consolidate` with a `new_decision` op (grep `new_decision` in `internal/ideas/*_test.go`); add/extend to assert status:

```go
// after a run that applied one new_idea and one new_decision:
var st string
require.NoError(t, database.QueryRow(`SELECT status FROM ideas WHERE kind='decision' AND title=?`, "Decision title").Scan(&st))
require.Equal(t, "active", st)
require.NoError(t, database.QueryRow(`SELECT status FROM ideas WHERE kind='idea' AND title=?`, "Idea title").Scan(&st))
require.Equal(t, "proposed", st)
```

- [ ] **Step 2: Run to verify it fails** (`go test ./internal/ideas/ -run <TestName> -v`) — decision status is `proposed`.

- [ ] **Step 3: Implement.** In `applyNewIdeaOp`, where the row is built (`db.Idea{Kind: kind, Title: op.Title, Essence: op.Essence}`):

```go
idea := db.Idea{Kind: kind, Title: op.Title, Essence: op.Essence}
if kind == "decision" {
	// Decisions are a journal, not a triage queue: the decision already
	// happened, so there is nothing to approve.
	idea.Status = "active"
}
```

- [ ] **Step 4: Run the package tests** (`go test ./internal/ideas/`) — all green, including the IDEA-01..05 guard tests untouched.

- [ ] **Step 5: Commit** (`feat(ideas): mined decisions are born active, not proposed`)

### Task 3: Go review-count excludes decisions

**Files:**
- Modify: `internal/db/ideas.go` (`CountIdeasForReview`, around line 777-782)
- Test: `internal/db/ideas_test.go` (wherever `CountIdeasForReview` is covered; add if uncovered)

**Interfaces:**
- Produces: `CountIdeasForReview` counts rows `WHERE (status='proposed' OR needs_review=1) AND kind != 'decision'`.

- [ ] **Step 1: Failing test** — seed one proposed idea, one decision with `needs_review=1`, assert count == 1.

```go
func TestCountIdeasForReview_ExcludesDecisions(t *testing.T) {
	database := openTestDB(t)
	mustExec(t, database, `INSERT INTO ideas (kind,title,essence,status,source) VALUES ('idea','I','i','proposed','mined')`)
	mustExec(t, database, `INSERT INTO ideas (kind,title,essence,status,source,needs_review) VALUES ('decision','D','d','active','mined',1)`)
	n, err := database.CountIdeasForReview()
	require.NoError(t, err)
	require.Equal(t, 1, n)
}
```

(Adapt helper names to the file's actual test helpers.)

- [ ] **Step 2: Run to verify it fails** (count == 2)
- [ ] **Step 3: Implement** — add `AND kind != 'decision'` to the WHERE clause.
- [ ] **Step 4: Run** `go test ./internal/db/`
- [ ] **Step 5: Commit** (`feat(db): review count excludes decisions`)

### Task 4: `streams` config block

**Files:**
- Modify: `internal/config/config.go` (new `StreamsConfig`, registered as `mapstructure:"streams"`; defaults near line 377-380), `internal/config/defaults.go`
- Test: `internal/config/config_test.go` (defaults test — follow how `ideas.*` defaults are asserted)

**Interfaces:**
- Produces: `cfg.Streams.Enabled bool` (default `true`), `cfg.Streams.IntervalHours int` (default `6`). Constants `DefaultStreamsEnabled = true`, `DefaultStreamsIntervalHours = 6`.

- [ ] **Step 1: Failing test** asserting `cfg.Streams.Enabled == true && cfg.Streams.IntervalHours == 6` on a default-loaded config.
- [ ] **Step 2: Run to verify it fails** (field doesn't exist → compile error counts as failing)
- [ ] **Step 3: Implement**

```go
// StreamsConfig controls the stage-1 Gmail/Jira stream pre-digests
// (generation only; the Ideas consolidator is gated by ideas.enabled).
type StreamsConfig struct {
	Enabled       bool `mapstructure:"enabled"`
	IntervalHours int  `mapstructure:"interval_hours"`
}
```

Register on `Config` (`mapstructure:"streams"`), set viper defaults alongside the ideas ones.

- [ ] **Step 4: Run** `go test ./internal/config/`
- [ ] **Step 5: Commit** (`feat(config): streams block for stage-1 stream digests`)

### Task 5: Pipeline split — `RunStreamDigests` vs `Run`

**Files:**
- Modify: `internal/ideas/pipeline.go` (`Run`, lines ~139-156)
- Test: `internal/ideas/pipeline_test.go` (or wherever `Run`'s gating is covered)

**Interfaces:**
- Consumes: existing `p.runEmailDigests(ctx, bound)` / `p.runJiraDigests(ctx, bound)` (unchanged).
- Produces: `func (p *Pipeline) RunStreamDigests(ctx context.Context) error` — runs email+jira stage 1 with zero bound, NOT gated on `Ideas.Enabled`. `Run(ctx)` keeps the `Ideas.Enabled` early-return and now runs ONLY consolidation (stage 2). `internal/ideas/backfill.go`'s `runStage1Passes` is untouched.

- [ ] **Step 1: Failing tests**: (a) `RunStreamDigests` runs the stage-1 passes even when `cfg.Ideas.Enabled == false`; (b) `Run` no longer invokes stage 1 (e.g. with a stub email generator that would error, `Run` succeeds/reaches consolidate). Follow the package's existing pipeline-test seams (stub generators).
- [ ] **Step 2: Run to verify failure**
- [ ] **Step 3: Implement**

```go
// RunStreamDigests runs the stage-1 Gmail/Jira pre-digest passes. It is
// deliberately not gated on ideas.enabled: the stream digests feed the
// Desktop Digests tab on their own (the consolidator is gated separately).
func (p *Pipeline) RunStreamDigests(ctx context.Context) error {
	if err := p.runEmailDigests(ctx, time.Time{}); err != nil {
		return err
	}
	return p.runJiraDigests(ctx, time.Time{})
}
```

Remove the two stage-1 calls from `Run` (keep its `Ideas.Enabled` gate and `runConsolidate`).

- [ ] **Step 4: Run** `go test ./internal/ideas/`
- [ ] **Step 5: Commit** (`feat(ideas): split RunStreamDigests out of Run`)

### Task 6: Daemon phase + wiring + comment-sync gate

**Files:**
- Modify: `internal/daemon/daemon.go` (new `phaseStreamDigests` before `phaseIdeas` in the cycle at ~line 337; new `lastStreams` persistence mirroring `lastIdeas`/`last_ideas.txt`), `cmd/ideas.go` (`wireIdeasPipeline` gate, lines 76-84), `cmd/sync.go` (comment-sync gate, lines 548-552)
- Test: `internal/daemon/daemon_test.go` (phase tests — follow `phaseIdeas` coverage), `cmd/sync_test.go` or wherever `SetCommentSyncLimit` wiring is covered

**Interfaces:**
- Consumes: `Pipeline.RunStreamDigests(ctx)` (Task 5), `cfg.Streams.*` (Task 4), `ideas.AcquireBackfillLock` freshness check (same skip rule `phaseIdeas` uses).
- Produces: daemon runs stage 1 every `streams.interval_hours` when `streams.enabled`, independent of `ideas.enabled`; Jira comment sync active when `streams.enabled`.

- [ ] **Step 1: Failing tests**: (a) daemon with `ideas.enabled=false, streams.enabled=true` and a wired pipeline runs `RunStreamDigests` (assert via `pipeline_runs` label `"stream-digests"` or a stub); (b) with a fresh backfill lock present the phase skips; (c) `wireIdeasPipeline` wires a pipeline when only `streams.enabled` is true; (d) comment-sync limit is set when `streams.enabled=true, ideas.enabled=false` and NOT set when both are false.
- [ ] **Step 2: Run to verify failure**
- [ ] **Step 3: Implement**
  - `phaseStreamDigests`: copy the `phaseIdeas` shape — nil-pipe guard, throttle on `cfg.Streams.IntervalHours` with its own `lastStreams` (+ `last_streams.txt` persistence exactly like `lastIdeas`/`last_ideas.txt`), backfill-lock skip with the same log throttle pattern, `trackedPipelineRun("stream-digests", ...)` calling `d.ideasPipe.RunStreamDigests(ctx)`, advance `lastStreams` even on error (the `lastIdeas` precedent). Gate on `cfg.Streams.Enabled`.
  - `wireIdeasPipeline`: `if !cfg.Ideas.Enabled && !cfg.Streams.Enabled { return }`.
  - `cmd/sync.go`: replace `if cfg.Ideas.Enabled` with `if cfg.Streams.Enabled` around `SetCommentSyncLimit(cfg.Ideas.MaxCommentIssuesPerSync)`; update the comment to say the stream digests (not the registry) own the comment feed.
- [ ] **Step 4: Run** `go test ./internal/daemon/ ./cmd/...` (note: full `./cmd` under `-race` has a pre-existing timeout — run without `-race`)
- [ ] **Step 5: Commit** (`feat(daemon): stream-digests phase decoupled from ideas.enabled; comment sync rides streams.enabled`)

### Task 7: Swift IdeaQueries — review predicates + ledger queries

**Files:**
- Modify: `WatchtowerDesktop/Sources/Database/Queries/IdeaQueries.swift`
- Test: `WatchtowerDesktop/Tests/IdeaQueriesTests.swift`

**Interfaces:**
- Produces (exact signatures for later tasks):
  - `fetchForReview` / `countForReview`: add `AND kind != 'decision'`.
  - `fetchList(...)`: when `kind == nil`, add `AND kind != 'decision'` (the Ideas tab never shows decisions; the ledger always passes `kind: "decision"` explicitly).
  - `static func fetchDecisionLedger(_ db: Database, limit: Int = 200) throws -> [Idea]` — `SELECT * FROM ideas WHERE kind='decision' ORDER BY COALESCE(last_mention_at, updated_at) DESC LIMIT ?`.
  - `static func markDecisionSeen(_ db: Database, id: Int) throws` — `UPDATE ideas SET seen_at = datetime('now') WHERE id = ?` (match the timestamp format used elsewhere in Swift writes).
  - `static func markAllDecisionsSeen(_ db: Database) throws` — same, `WHERE kind='decision' AND seen_at IS NULL`.
  - `static func unreadDecisionCount(_ db: Database) throws -> Int` — `WHERE kind='decision' AND (seen_at IS NULL OR needs_review = 1)`.
  - `Idea` model (`Sources/Models/Idea.swift`): add `seenAt: String?` (column `seen_at`) to `init(row:)`.

- [ ] **Step 1: Failing tests** in `IdeaQueriesTests` (extend the file's existing seeding helpers; TestDatabase schema must gain `seen_at` — update `Tests/.../TestDatabase.swift` or the schema fixture the tests use, the known schema-drift trap):
  - review queue/count exclude a `needs_review=1` decision;
  - `fetchList(kind: nil)` excludes decisions; `fetchList(kind: "decision")` returns them;
  - `fetchDecisionLedger` orders by `last_mention_at` fallback `updated_at`;
  - `markDecisionSeen` + `unreadDecisionCount` interplay, incl. `needs_review=1` keeping a seen row "unread".
- [ ] **Step 2: Run** `swift test --filter IdeaQueriesTests` — fails.
- [ ] **Step 3: Implement** the query changes above.
- [ ] **Step 4: Run** `swift test --filter IdeaQueriesTests` — green.
- [ ] **Step 5: Commit** (`feat(desktop): idea queries - decisions leave the review queue, ledger queries added`)

### Task 8: Ideas tab narrows to ideas & notes

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Ideas/IdeasView.swift` (kind filter :123-128, status filter :131-143, copy :119/:283), `IdeaCreateSheet.swift` (:48-52), `IdeaDetailPane.swift` (remove the `kind == .decision && status == .active` arm :467-473; keep glyph/badge maps — the ledger reuses them), `WatchtowerDesktop/Sources/ViewModels/IdeasViewModel.swift` (keep `supersede`/`reverse` — Task 10's ledger VM calls them via shared code or duplicates per house dual-path; simplest: they stay on IdeasViewModel unused by Ideas UI — move them in Task 10 if the ledger VM ends up separate)
- Test: `WatchtowerDesktop/Tests/IdeasViewModelTests.swift` (adjust expectations; no decision rows in review/registry fixtures)

**Interfaces:**
- Consumes: Task 7 queries.
- Produces: Ideas tab UI with kinds Idea/Note only; status filter without `superseded`/`reversed`; create sheet without Decision.

- [ ] **Step 1: Adjust/extend VM tests**: seed a decision row; assert it appears in neither `reviewItems` nor `registryItems` (with nil kind filter). Run — fails until Task 7's `fetchList` change is consumed correctly (if already green thanks to Task 7, that's fine — this is UI-layer verification).
- [ ] **Step 2: Implement the four view edits** (filter options, picker, create sheet, detail-pane arm removal, empty-state copy → "Ideas and proposals mined from Slack, meetings, email, and Jira will collect here for review."). For the create sheet, add `let allowedKinds: [Idea.Kind]` (default `[.idea, .note]`) and drive the kind Picker from it — Task 10 re-presents the same sheet with `allowedKinds: [.decision]` from the Decisions segment.
- [ ] **Step 3: Build + run** `swift build && swift test --filter IdeasViewModelTests`
- [ ] **Step 4: Commit** (`feat(desktop): ideas tab narrows to ideas and notes`)

### Task 9: StreamDigest model + queries

**Files:**
- Create: `WatchtowerDesktop/Sources/Models/StreamDigest.swift`, `WatchtowerDesktop/Sources/Database/Queries/StreamDigestQueries.swift`
- Test: Create `WatchtowerDesktop/Tests/StreamDigestQueriesTests.swift` (add `stream_digests` to the test schema — same file as Task 7's schema touch)

**Interfaces:**
- Produces:

```swift
struct StreamCandidate: Codable, Hashable {
    let text: String
    let author: String?
    let ref: String?
}
struct StreamTopic: Codable, Hashable {
    let title: String
    let summary: String?
    let ideas: [StreamCandidate]?
    let decisions: [StreamCandidate]?
}
struct StreamDigest: FetchableRecord, Decodable, Identifiable, Equatable {
    let id: Int
    let source: String        // "gmail" | "jira"
    let accountID: Int?       // account_id
    let scope: String
    let periodFrom: String    // period_from
    let periodTo: String      // period_to
    let topicsJSON: String    // topics_json (bare JSON array of StreamTopic)
    let createdAt: String     // created_at
    let readAt: String?       // read_at
    var isRead: Bool { readAt != nil }
    var parsedTopics: [StreamTopic] { /* decode topicsJSON, [] on failure */ }
}
enum StreamDigestQueries {
    static func fetchAll(_ db: Database, limit: Int = 200) throws -> [StreamDigest]  // ORDER BY created_at DESC
    static func markRead(_ db: Database, id: Int) throws                              // SET read_at = datetime('now') WHERE id = ? AND read_at IS NULL
    static func unreadCount(_ db: Database) throws -> Int
}
```

CodingKeys map snake_case columns (the `Digest.swift` precedent — raw-SQL fetch, no `databaseTableName`).

- [ ] **Step 1: Failing tests**: insert two rows (gmail with topics JSON incl. decisions, jira empty topics), assert fetch order, `parsedTopics` decode (and `[]` on malformed JSON), markRead idempotence, unreadCount.
- [ ] **Step 2: Run** `swift test --filter StreamDigestQueriesTests` — fails.
- [ ] **Step 3: Implement model + queries.**
- [ ] **Step 4: Run — green.**
- [ ] **Step 5: Commit** (`feat(desktop): StreamDigest model and queries`)

### Task 10: Decisions segment reads the ledger

**Files:**
- Modify: `WatchtowerDesktop/Sources/ViewModels/DigestViewModel.swift` (replace `decisionEntries` machinery: drop `buildDecisionEntries`/`allDecisionDigests`/`loadMoreDecisions`/decision_reads/importance-correction usage for this segment; add `ledgerDecisions: [Idea]`, `unreadDecisionCount` via `IdeaQueries.unreadDecisionCount`, `markDecisionSeen`, `markAllDecisionsSeen`, `supersede(id:by:)`, `reverse(id:)`, `setRating`), `Sources/Views/Digests/DecisionsListView.swift` (rows over `[Idea]`), `Sources/Views/Digests/DecisionDetailView.swift` (rewrite over `Idea` + mentions: essence, status badge active/superseded/reversed, Supersede/Reverse buttons, 👍/👎 + comment, mentions chronology with deep links — reuse the mention rendering from `Views/Ideas/`), `DigestListView.swift` (detail lookup by `Idea.id`; "+" button in the Decisions segment presenting `IdeaCreateSheet` pinned to kind `.decision` — pass an allowed-kinds parameter added in Task 8, default all minus decision for Ideas, decision-only here), `Sources/Database/Queries/CatchUpQueries.swift` (remove the `markAllDecisionsRead` cascade :78-84)
- Test: `WatchtowerDesktop/Tests/CatchUpQueriesTests.swift` (cascade removal), extend `Tests/IdeaQueriesTests.swift` or a new `DecisionLedgerTests.swift` for VM-level unread/seen/supersede flows

**Interfaces:**
- Consumes: Task 7 (`fetchDecisionLedger`, `markDecisionSeen`, `markAllDecisionsSeen`, `unreadDecisionCount`), Task 8 (`IdeaCreateSheet` kind restriction), `IdeaQueries.supersede`/`setStatus`/`setRating`/`fetchMentions`.
- Produces: Decisions segment fully ledger-backed; `decision_reads` + `decision_importance_corrections` no longer written by this segment (legacy queries stay in `DigestQueries` for the digest-detail legacy section only); segment label unread count = `unreadDecisionCount`.

- [ ] **Step 1: Failing tests**: CatchUp digest ack no longer inserts `decision_reads` rows; VM: load exposes ledger decisions sorted, mark-seen drops unread count, supersede sets `superseded_by_id` + status.
- [ ] **Step 2: Run — fails.**
- [ ] **Step 3: Implement** VM + the three views + CatchUpQueries removal. Keep `DecisionEntry`/`Decision` models only where the legacy `DigestDetailView` flat section still uses them; delete dead code that nothing references after the rewire (`DecisionCard.swift` if orphaned — check references first).
- [ ] **Step 4: Run** `swift build && swift test --filter 'CatchUpQueriesTests|DecisionLedger|DigestViewModel'`
- [ ] **Step 5: Commit** (`feat(desktop): decisions segment reads the consolidated ledger`)

### Task 11: Cross-source feed (Digests segment)

**Files:**
- Modify: `WatchtowerDesktop/Sources/ViewModels/DigestViewModel.swift` (feed assembly), `Sources/Views/Digests/DigestListView.swift` (feed list rendering + detail routing)
- Create: `Sources/Views/Digests/StreamDigestDetailView.swift`
- Test: `WatchtowerDesktop/Tests/DigestFeedTests.swift` (new, VM-level)

**Interfaces:**
- Consumes: Task 9 (`StreamDigestQueries.fetchAll`/`markRead`), `MeetingTranscriptQueries.fetchRecordingList` (existing; filter `hasRecap`), existing `DigestQueries.fetchAll`.
- Produces:

```swift
enum FeedEntry: Identifiable, Equatable {
    case slack(Digest)
    case stream(StreamDigest)
    case meeting(RecordingListItem)
    var id: String { /* "slack-\(id)" / "stream-\(id)" / "meeting-\(id)" */ }
    var date: Date { /* slack: created_at; stream: created_at; meeting: createdDate */ }
    var isRead: Bool { /* slack/stream: read markers; meeting: always true (no unread concept) */ }
}
// DigestViewModel:
var feedEntries: [FeedEntry]   // sorted date DESC; day grouping done in the view via Calendar
```

Detail routing: `.slack` → existing `DigestDetailView`; `.stream` → `StreamDigestDetailView` (renders `parsedTopics`: title, summary, ideas/decisions bullets; refs — `gmail:<acct>:<threadID>` → Gmail deep link the way existing Gmail links are built elsewhere in the app (grep for the existing Gmail permalink helper; if none exists for Desktop, render refs as plain monospace text — do NOT invent URL schemes), bare Jira keys → `<site_url>/browse/<KEY>` via `JiraConfigHelper.readSiteURL()`; marks `markRead` on appear); `.meeting` → render recap content via existing `MeetingRecap.Content`/`parsedSummary` path with a "Open recording" link that navigates to the Calendar recording (follow how existing cross-tab navigation sets `appState` selection; if no precedent fits, show detail inline without navigation).

The unread picker filters `.meeting` entries out of "Unread" (always-read). The segment label unread count = slack unread + stream unread (existing `unreadDigestCount` + `StreamDigestQueries.unreadCount`); the sidebar digests badge stays Slack-only (`DigestQueries.unreadDigestCount`) in v1.

- [ ] **Step 1: Failing VM tests**: seed one of each source; assert merged order, ids stable, meeting entries always read, stream markRead flows through.
- [ ] **Step 2: Run — fails.**
- [ ] **Step 3: Implement** feed assembly + views. Keep `DigestViewModel` view-local (house rule applies to async ops, browsing state is fine).
- [ ] **Step 4: Run** `swift build && swift test --filter DigestFeedTests`
- [ ] **Step 5: Commit** (`feat(desktop): cross-source digests feed (slack + streams + meetings)`)

### Task 12: DigestWatcher notifications from the ledger

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/DigestWatcher.swift` (:60-82 — replace the `digest.parsedDecisions` source with a max-id watermark over `ideas WHERE kind='decision'`)
- Test: `WatchtowerDesktop/Tests/DigestWatcherTests.swift`

**Interfaces:**
- Consumes: ledger rows (`Idea` with `kind == .decision`).
- Produces: `notifyDecisions` fires one notification per NEW ledger decision (id > watermark), title = idea title; watermark persisted the same way the watcher persists its digest watermark today (follow the existing mechanism in the file).

- [ ] **Step 1: Adjust tests**: new ledger decision → notification; re-run → no duplicate; digest with decisions JSON but no ledger row → no notification.
- [ ] **Step 2: Run — fails.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `swift test --filter DigestWatcherTests`
- [ ] **Step 5: Commit** (`feat(desktop): decision notifications ride the ledger`)

### Task 13: Docs

**Files:**
- Modify: `docs/inventory/ideas.md` (dated note: decisions born active, review queue is ideas-only by design; IDEA-01..05 unchanged), `docs/inventory/inbox-pulse.md` (rewrite the 2026-08-08 INBOX-02 coupling entry: comment sync now rides `streams.enabled`, default on), `CLAUDE.md` (Ideas & Decisions Registry section + a short entry for this change), `docs/app-guide.md` (Ideas tab scope, Digests feed, Decisions ledger — the app-guide maintenance rule)

- [ ] **Step 1: Write all four doc updates** (English, factual, dated 2026-08-12).
- [ ] **Step 2: Commit** (`docs: decisions split + cross-source digests`)

### Task 14: Full verification + PR

- [ ] **Step 1:** `go build ./... && go vet ./... && go test ./...` (full Go suite; `./cmd` without `-race`).
- [ ] **Step 2:** `cd WatchtowerDesktop && swift build && swift test` — capture real exit code to a log file, check `$?`.
- [ ] **Step 3:** Run the local-review skill (final PR review path) and triage findings.
- [ ] **Step 4:** Push branch, open PR to `main` titled "Decisions split + cross-source digests", body summarizing the spec, `🤖 Generated with [Claude Code](https://claude.com/claude-code)` footer.
- [ ] **Step 5:** Watch CI to green; merge (owner pre-approved merge after green).
