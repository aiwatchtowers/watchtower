# Secretary Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the per-message inbox feed with a secretary-ranked feed of **situations** (clusters of signals matched to the user's active targets/tracks plus important out-of-goal themes), with inline context packets and one-click create-target/create-track.

**Architecture:** A situation composer (`inbox.compose`, strong tier, one batch call per cycle) sits on top of the merged two-stage engine: it clusters uncomposed signals + new track events + changed targets into `situations` rows (merging into open ones — never duplicating), and a per-situation card stage (`inbox.situation_card`) builds the context packet. Per-message cards (`runCards`/`inbox.card`) are retired. Desktop's Inbox tab becomes Dashboard (default screen): one ranked feed, inline expansion, explicit create actions.

**Tech Stack:** Go 1.25, goose migrations, modernc.org/sqlite, `digest.Generator` multi-provider AI (claude/codex CLI), SwiftUI + GRDB (macOS 14+).

**Spec:** `docs/superpowers/specs/2026-07-06-secretary-dashboard-design.md`

## Global Constraints

- Branch: `feature/secretary-dashboard` (already cut from post-PR#26 main).
- Signal-layer contracts (`docs/inventory/inbox-pulse.md`) keep their guard tests untouched; the only permitted doc change is the INBOX-01 observable rewording defined in the spec. Any other guard change → stop and ask.
- New AI calls on BOTH providers via source tags: `inbox.compose` and `inbox.situation_card` are STRONG tier — absent from both `ModelForSource` switches, asserted strong in both `models_test.go` tables. Never hardcode a model.
- Migrations: goose `internal/db/migrations/00011_*.sql` with Up/Down; mirror into `internal/db/schema.sql`; regenerate golden (`go test ./internal/db/ -run TestSchemaGolden -update`); add new tables to `TestAllTablesExist`; never bump `CurrentSchemaFormat`.
- Verify commands expose real exit codes: `> /tmp/log 2>&1; echo "exit=$?"` — never pipe through tail/head.
- Swift verification runs on the tree as-is; if the user's uncommitted WIP breaks the build, use the temp-worktree pattern (`git worktree add <scratch> HEAD`), never stash user files without restoring.
- UI copy English. Commit messages/docs English.
- DASH contracts (spec): DASH-01 merge-not-duplicate; DASH-02 AI failure never touches existing situations/ranks/cards; DASH-03 conversion records links both ways.
- Config: `dashboard.stale_after_days` (default 7), `dashboard.max_compose_signals` (default 200).
- Go tests reuse `internal/inbox` helpers (`newTestDB`, `seedWorkspaceAndUser`, `seqGenerator`); Swift tests use `TestDatabase.createDatabaseManager()` + `cleanup(path:)`.

---

### Task 1: Migration 00011 — situations schema + Go models/accessors

**Files:**
- Create: `internal/db/migrations/00011_situations.sql`
- Create: `internal/db/situations.go`
- Modify: `internal/db/schema.sql`, `internal/db/models.go`, `internal/db/db_test.go` (TestAllTablesExist), `internal/db/inbox.go` (composed_at in column consts + scanner), `internal/db/workspace.go` (compose watermark accessors)
- Modify: `internal/db/testdata/schema_v73.golden` (regenerated)
- Test: `internal/db/situations_test.go`

**Interfaces:**
- Consumes: workspace scalar-accessor pattern (`GetInboxLastProcessedTS`/`SetInboxLastProcessedTS`, internal/db/inbox.go:386/:396).
- Produces:

```go
type Situation struct {
	ID              int
	Title           string
	Kind            string // external|target_update|track_update|mixed
	Status          string // open|done|dismissed|converted|stale|snoozed
	SnoozeUntil     string
	Priority        string // high|medium|low
	Rank            float64
	AIReason        string
	Summary         string
	WhyMatters      string
	Chronology      string
	CardStatus      string // none|ready|failed
	CardGeneratedAt string
	TargetID        *int
	TrackID         *int
	ConvertedTargetID *int
	ConvertedTrackID  *int
	LastSignalAt    string
	ResolvedReason  string
	CreatedAt       string
	UpdatedAt       string
}
func (db *DB) CreateSituation(s Situation) (int64, error)
func (db *DB) GetSituation(id int) (Situation, error)
func (db *DB) ListOpenSituations() ([]Situation, error) // status='open', ORDER BY rank DESC, updated_at DESC
func (db *DB) AddSituationSignals(situationID int, inboxItemIDs []int) error // INSERT OR IGNORE + bumps last_signal_at/updated_at
func (db *DB) ListSituationSignals(situationID int) ([]InboxItem, error) // join situation_signals→inbox_items
func (db *DB) GetComposeLastRunTS() (float64, error)
func (db *DB) SetComposeLastRunTS(ts float64) error
```
- `InboxItem` gains `ComposedAt string` (nullable column, scan like `read_at`).

- [ ] **Step 1: Write failing tests**

`internal/db/situations_test.go` (reuse this package's `openTestDB(t)` and fixture helpers):

```go
func TestSituationRoundTripAndSignals(t *testing.T) {
	d := openTestDB(t)
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "1.1", "U2", "sig one")
	insertMessage(t, d, "C1", "2.1", "U2", "sig two")
	sig1 := mustCreateInboxItem(t, d, InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "stream"})
	sig2 := mustCreateInboxItem(t, d, InboxItem{ChannelID: "C1", MessageTS: "2.1", SenderUserID: "U2", TriggerType: "mention"})

	id, err := d.CreateSituation(Situation{Title: "release X blocked", Kind: "external", Priority: "high", Rank: 0.9, AIReason: "prod impact"})
	require.NoError(t, err)
	s, err := d.GetSituation(int(id))
	require.NoError(t, err)
	require.Equal(t, "open", s.Status, "status must default open")
	require.Equal(t, "none", s.CardStatus)

	require.NoError(t, d.AddSituationSignals(int(id), []int{int(sig1), int(sig2)}))
	require.NoError(t, d.AddSituationSignals(int(id), []int{int(sig1)})) // idempotent
	members, err := d.ListSituationSignals(int(id))
	require.NoError(t, err)
	require.Len(t, members, 2)

	open, err := d.ListOpenSituations()
	require.NoError(t, err)
	require.Len(t, open, 1)
}

func TestComposeWatermarkRoundTrip(t *testing.T) {
	d := openTestDB(t)
	seedWorkspace(t, d) // use this file's actual workspace fixture helper
	ts, err := d.GetComposeLastRunTS()
	require.NoError(t, err)
	require.Equal(t, 0.0, ts)
	require.NoError(t, d.SetComposeLastRunTS(123.5))
	ts, _ = d.GetComposeLastRunTS()
	require.Equal(t, 123.5, ts)
}

func TestInboxItemComposedAtRoundTrip(t *testing.T) {
	// create item → ComposedAt empty; UPDATE via MarkSignalsComposed comes in Task 3,
	// here only assert the column scans (create + Get → ComposedAt == "").
}
```

- [ ] **Step 2: Run to verify failure**

Run: `go test ./internal/db/ -run 'TestSituation|TestComposeWatermark|TestInboxItemComposedAt' > /tmp/wt-d1.log 2>&1; echo "exit=$?"` → exit=1.

- [ ] **Step 3: Write migration 00011**

```sql
-- +goose Up
CREATE TABLE IF NOT EXISTS situations (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    title           TEXT NOT NULL,
    kind            TEXT NOT NULL DEFAULT 'external' CHECK(kind IN ('external','target_update','track_update','mixed')),
    status          TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','done','dismissed','converted','stale','snoozed')),
    snooze_until    TEXT NOT NULL DEFAULT '',
    priority        TEXT NOT NULL DEFAULT 'medium' CHECK(priority IN ('high','medium','low')),
    rank            REAL NOT NULL DEFAULT 0,
    ai_reason       TEXT NOT NULL DEFAULT '',
    summary         TEXT NOT NULL DEFAULT '',
    why_matters     TEXT NOT NULL DEFAULT '',
    chronology      TEXT NOT NULL DEFAULT '',
    card_status     TEXT NOT NULL DEFAULT 'none' CHECK(card_status IN ('none','ready','failed')),
    card_generated_at TEXT,
    target_id       INTEGER,
    track_id        INTEGER,
    converted_target_id INTEGER,
    converted_track_id  INTEGER,
    last_signal_at  TEXT NOT NULL DEFAULT '',
    resolved_reason TEXT NOT NULL DEFAULT '',
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_situations_status_rank ON situations(status, rank DESC);
CREATE INDEX IF NOT EXISTS idx_situations_updated ON situations(updated_at DESC);

CREATE TABLE IF NOT EXISTS situation_signals (
    situation_id   INTEGER NOT NULL REFERENCES situations(id) ON DELETE CASCADE,
    inbox_item_id  INTEGER NOT NULL REFERENCES inbox_items(id) ON DELETE CASCADE,
    UNIQUE(situation_id, inbox_item_id)
);
CREATE INDEX IF NOT EXISTS idx_situation_signals_item ON situation_signals(inbox_item_id);

ALTER TABLE inbox_items ADD COLUMN composed_at TEXT;
ALTER TABLE workspace ADD COLUMN compose_last_run_ts REAL NOT NULL DEFAULT 0;

-- +goose Down
DROP TABLE IF EXISTS situation_signals;
DROP TABLE IF EXISTS situations;
ALTER TABLE inbox_items DROP COLUMN composed_at;
ALTER TABLE workspace DROP COLUMN compose_last_run_ts;
```

- [ ] **Step 4: Mirror + implement Go layer**

- schema.sql: append both CREATE TABLEs + indexes verbatim; add `composed_at` to inbox_items and `compose_last_run_ts REAL NOT NULL DEFAULT 0` to workspace.
- `internal/db/models.go`: add `Situation` struct (above) + `ComposedAt string` on InboxItem.
- `internal/db/inbox.go`: add `composed_at` to `inboxSelectCols`/`inboxItemColumns` + scan (nullable-string pattern like `read_at`).
- `internal/db/situations.go`: implement the six functions. `CreateSituation` follows `CreateInboxItem`'s shape (explicit column INSERT, defaults for empty Status/Priority/Kind/CardStatus). `AddSituationSignals`: one tx — `INSERT OR IGNORE INTO situation_signals`, then `UPDATE situations SET last_signal_at = strftime(...), updated_at = strftime(...) WHERE id = ?`. `ListSituationSignals`: `SELECT `+inboxSelectCols+` FROM inbox_items JOIN situation_signals ss ON ss.inbox_item_id = inbox_items.id WHERE ss.situation_id = ? ORDER BY inbox_items.ts... ` — order by `message_ts` ASC (chronology). Watermark accessors clone `GetInboxLastProcessedTS`/`SetInboxLastProcessedTS` (inbox.go:386/:396) for `compose_last_run_ts`.
- `internal/db/db_test.go::TestAllTablesExist`: add `"situations", "situation_signals"`.

- [ ] **Step 5: Golden + verify + commit**

Run: `go test ./internal/db/ -run TestSchemaGolden -update > /tmp/wt-d1.log 2>&1; echo "exit=$?"` then `go test ./internal/db/ > /tmp/wt-d1.log 2>&1; echo "exit=$?"` → exit=0.

```bash
git add internal/db/ && git commit -m "feat(db): situations schema — tables, compose watermark, composed_at marker"
```

---

### Task 2: Register `inbox.compose` + `inbox.situation_card` prompts (strong tier)

**Files:**
- Modify: `internal/prompts/store.go`, `internal/prompts/defaults.go`
- Modify: `internal/digest/models_test.go`, `internal/codex/models_test.go` (strong-tier assertion rows ONLY — no switch changes)
- Test: same files

**Interfaces:**
- Produces: `prompts.InboxCompose = "inbox.compose"`, `prompts.InboxSituationCard = "inbox.situation_card"`, registered in all four maps (`Defaults`, `AllIDs`, `DefaultVersions`=1, `Descriptions`). Both STRONG tier: NOT added to either `ModelForSource` switch; test rows assert `ModelSonnet` / `ModelDefault`.
- Compose template: **4 `%s` slots** — language directive, secretary brief, open-situations block, new-material block. Situation-card template: **3 `%s` slots** — language directive, secretary brief, situation block.

- [ ] **Step 1: Failing routing-test rows**

Add to `internal/digest/models_test.go::TestModelForSource` sonnet list: `"inbox.compose"`, `"inbox.situation_card"`. Mirror in `internal/codex/models_test.go`: `{"inbox.compose", ModelDefault}`, `{"inbox.situation_card", ModelDefault}`. Run: `go test ./internal/digest/ ./internal/codex/ -run TestModelForSource > /tmp/wt-d2.log 2>&1; echo "exit=$?"` — these pass already (default routing); the real RED is the prompts package: add a temporary reference or simply verify registration via the prompts tests after Step 2. Treat Step 2's `go build` failure on missing consts as RED.

- [ ] **Step 2: Register prompts**

`internal/prompts/store.go`:
```go
	InboxCompose      = "inbox.compose"
	InboxSituationCard = "inbox.situation_card"
```

`internal/prompts/defaults.go` — add to the four maps + template consts:

```go
const defaultInboxCompose = `%s

You are the user's chief-of-staff secretary maintaining their work dashboard.
The dashboard shows SITUATIONS: clusters of related signals around one theme.
Your job every cycle: fold new material into the dashboard so the user stays
on top of everything — matched to their goals (their active targets and
tracks, listed in the brief) AND anything important outside those goals.
Nothing important may slip by; routine noise must not surface.

%s

=== OPEN SITUATIONS (current dashboard state) ===
%s

Fold the new material below into the dashboard:
- "merge": a new signal/event continues an existing open situation → add it
  there. NEVER create a duplicate situation for a theme already open.
- "create": a genuinely new theme worth the user's attention. kind:
  "external" (not tied to their work items), "target_update" /
  "track_update" (activity on an active target/track — set target_id or
  track_id), "mixed".
- "rerank": an open situation became more/less urgent.
- Signals not worth the dashboard: simply do not reference them.
- priority: high|medium|low. rank: 0.0-1.0 relative urgency for feed order.
- reason: ONE sentence, user's point of view, in the user's language.

%s

Return ONLY a JSON object (no markdown fences):
{"ops":[
 {"op":"create","title":"...","kind":"external","priority":"high","rank":0.9,"reason":"...","signals":["sig:12","evt:3","tgt:7"],"target_id":null,"track_id":null},
 {"op":"merge","situation_id":4,"signals":["sig:15"],"rerank":0.7,"reason":"..."},
 {"op":"rerank","situation_id":2,"rank":0.3,"reason":"..."}
]}`

const defaultInboxSituationCard = `%s

You are the user's chief-of-staff secretary preparing the context packet for
one situation on their work dashboard.

%s

Using the situation and its member signals below, produce:
- summary: 2-4 sentences — what is happening, CURRENT STATE FIRST.
- why_matters: 1-2 sentences judged against the brief (which of the user's
  goals it touches, or why it matters even outside them).
- chronology: one line per member signal, oldest first, format
  "<who> — <one-line essence>". No timestamps, no markdown.

%s

Return ONLY a JSON object (no markdown fences):
{"summary":"...","why_matters":"...","chronology":"..."}`
```

Descriptions: "Dashboard: fold new signals into situations" / "Dashboard: context packet for one situation".

- [ ] **Step 3: Verify + commit**

Run: `go build ./... && go test ./internal/prompts/ ./internal/digest/ ./internal/codex/ > /tmp/wt-d2.log 2>&1; echo "exit=$?"` → exit=0.

```bash
git add internal/prompts/ internal/digest/models_test.go internal/codex/models_test.go
git commit -m "feat(prompts): register inbox.compose and inbox.situation_card (strong tier)"
```

---

### Task 3: DB layer — compose inputs, situation mutations, lifecycle queries

**Files:**
- Modify: `internal/db/situations.go`, `internal/db/track_events.go`, `internal/db/targets.go`
- Test: `internal/db/situations_test.go`

**Interfaces:**
- Consumes: Task 1 tables; `TrackEvent` (track_events.go:12), `Target`/`GetTargets` (targets.go:187 — active excludes done/dismissed), `hardMuteScopes` logic lives in inbox pkg (mute filtering happens in Task 4, NOT here).
- Produces:

```go
// compose inputs
func (db *DB) ListUncomposedSignals(limit int) ([]InboxItem, error)       // status='pending' AND composed_at IS NULL, ORDER BY created_at ASC, LIMIT
func (db *DB) MarkSignalsComposed(ids []int) error                        // composed_at = now (single UPDATE ... IN)
func (db *DB) ListTrackEventsSince(ts string) ([]TrackEvent, error)       // created_at > ts (ISO8601 string compare), joined to non-dismissed tracks, ORDER BY created_at ASC
func (db *DB) ListTargetsUpdatedSince(ts string) ([]Target, error)        // active targets (todo|in_progress|blocked|snoozed) with updated_at > ts
// situation mutations
func (db *DB) UpdateSituationRank(id int, rank float64, priority, reason string) error
func (db *DB) SetSituationCard(id int, summary, whyMatters, chronology string) error   // card_status='ready', card_generated_at=now
func (db *DB) MarkSituationCardFailed(id int) error
func (db *DB) ResetSituationCard(id int) error                              // card_status='none' (called on merge)
func (db *DB) ListSituationsNeedingCards() ([]DashboardSituation, error)     // status='open' AND card_status IN ('none','failed')  [Go type is DashboardSituation — db.Situation was already taken]
// lifecycle
func (db *DB) SetSituationStatus(id int, status, reason string) error
func (db *DB) SnoozeSituation(id int, until string) error                   // status='snoozed' + snooze_until
func (db *DB) UnsnoozeExpiredSituations() (int, error)                      // snoozed && snooze_until <= now → open
func (db *DB) MarkStaleSituations(threshold time.Duration) (int, error)     // open && last_signal_at < now-threshold && last_signal_at != '' → stale
func (db *DB) AutoCloseResolvedSituations() (int, error)                    // open situations with >=1 member signal and zero pending member signals → done, resolved_reason='signals_resolved'
func (db *DB) MarkSituationConverted(id int, targetID, trackID int) error   // status='converted' + converted_target_id/converted_track_id (0 → NULL)
```

- [ ] **Step 1: Write failing tests**

Table of focused tests in `internal/db/situations_test.go` (reuse fixtures; each 5-15 lines):

```go
func TestListUncomposedSignals_OrderCapAndMark(t *testing.T) {
	// 3 pending signals; limit 2 → oldest two returned; MarkSignalsComposed on them;
	// second call returns only the third.
}
func TestListTrackEventsSince_OnlyNewAndNonDismissed(t *testing.T) {
	// two tracks (one dismissed); events before/after ts → only after-ts event of live track.
	// Fixture note: InsertTrackEvent defaults created_at=now — insert the "old" event via
	// raw SQL with an explicit created_at in the past.
}
func TestListTargetsUpdatedSince_ActiveOnly(t *testing.T) {
	// targets: active updated after ts (returned), done updated after ts (excluded),
	// active updated before ts (excluded). Use raw UPDATE to backdate updated_at.
}
func TestSituationCardLifecycle(t *testing.T) {
	// create → needs card; SetSituationCard → ready, not in needing list;
	// ResetSituationCard → none, back in list; MarkSituationCardFailed → failed, in list.
}
func TestSituationLifecycle_SnoozeStaleAutoclose(t *testing.T) {
	// snooze → status snoozed; UnsnoozeExpiredSituations with past until → open.
	// MarkStaleSituations: open situation with last_signal_at 8 days ago → stale (threshold 7d);
	// fresh one stays open; one with last_signal_at='' stays open.
	// AutoCloseResolvedSituations: situation A (all member signals resolved) → done +
	// resolved_reason='signals_resolved'; situation B (one pending member) stays open;
	// situation C (no members) stays open.
}
func TestMarkSituationConverted(t *testing.T) {
	// converted with targetID → status converted, converted_target_id set, converted_track_id NULL.
}
```

- [ ] **Step 2: RED**

Run: `go test ./internal/db/ -run 'TestListUncomposed|TestListTrackEventsSince|TestListTargetsUpdatedSince|TestSituationCardLifecycle|TestSituationLifecycle|TestMarkSituationConverted' > /tmp/wt-d3.log 2>&1; echo "exit=$?"` → exit=1.

- [ ] **Step 3: Implement**

All straightforward UPDATE/SELECT statements following the file's existing style (`strftime('%Y-%m-%dT%H:%M:%SZ','now')` for timestamps, error wrapping like neighbors). `AutoCloseResolvedSituations` SQL:

```sql
UPDATE situations SET status='done', resolved_reason='signals_resolved',
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
WHERE status='open'
  AND EXISTS (SELECT 1 FROM situation_signals ss WHERE ss.situation_id = situations.id)
  AND NOT EXISTS (
      SELECT 1 FROM situation_signals ss
      JOIN inbox_items i ON i.id = ss.inbox_item_id
      WHERE ss.situation_id = situations.id AND i.status = 'pending')
```

`MarkStaleSituations`: compare `last_signal_at` (ISO8601) against `time.Now().Add(-threshold).UTC().Format("2006-01-02T15:04:05Z")`, skip empty. `ListTrackEventsSince` joins `tracks` and filters `tracks.status != 'dismissed'` (check the actual tracks status/dismissed column — the tracks table uses `status` with a dismissed value or `dismissed_at`; verify in schema.sql:282 and match).

- [ ] **Step 4: GREEN + commit**

Run: `go test ./internal/db/ > /tmp/wt-d3.log 2>&1; echo "exit=$?"` → exit=0.

```bash
git add internal/db/ && git commit -m "feat(db): compose inputs, situation mutations and lifecycle queries"
```

---

### Task 4: Composer stage (`internal/inbox/compose.go`) + config

**Files:**
- Create: `internal/inbox/compose.go`
- Modify: `internal/config/config.go`, `internal/config/defaults.go` (DashboardConfig)
- Test: `internal/inbox/compose_test.go`

**Interfaces:**
- Consumes: Task 1/3 DB functions; `buildSecretaryBrief` (brief.go); `p.getPrompt(prompts.InboxCompose)`; `prompts.Directive`; `prompts.ExtractJSONObject` (returns `(string, error)`); `digest.WithSource(ctx, "inbox.compose")`; `p.accumulateUsage`; mute filtering via the existing `loadMuteScopes` (triage.go — reuse, do not duplicate).
- Produces:

```go
type composeOp struct {
	Op          string   `json:"op"`       // create|merge|rerank
	SituationID int      `json:"situation_id"`
	Title       string   `json:"title"`
	Kind        string   `json:"kind"`
	Priority    string   `json:"priority"`
	Rank        float64  `json:"rank"`
	Rerank      float64  `json:"rerank"`
	Reason      string   `json:"reason"`
	Signals     []string `json:"signals"` // "sig:<inbox_item_id>" | "evt:<track_event_id>" | "tgt:<target_id>"
	TargetID    *int     `json:"target_id"`
	TrackID     *int     `json:"track_id"`
}
func (p *Pipeline) runCompose(ctx context.Context, currentUserID string) (created, merged int, err error)
```

Behavior contract:
- Config: new `DashboardConfig{ StaleAfterDays int; MaxComposeSignals int }` (`dashboard.stale_after_days`=7, `dashboard.max_compose_signals`=200), registered next to InboxConfig (config.go:152-166 area + defaults.go + viper registration mirroring `inbox.*`).
- Input assembly: `ListUncomposedSignals(cfg.Dashboard.MaxComposeSignals)` minus hard-muted (loadMuteScopes on sender:/channel:); `ListTrackEventsSince(composeWatermarkISO)`; `ListTargetsUpdatedSince(composeWatermarkISO)`; `ListOpenSituations()` (+ their member titles via one `ListSituationSignals` per open situation, capped: only id/title/kind/reason + last 3 member snippets in the block). If ALL inputs are empty → return (0,0,nil) without an AI call.
- Watermark: read `GetComposeLastRunTS` at start (convert to ISO for the string-compare queries via `time.Unix`); on SUCCESS: `MarkSignalsComposed(all signal ids sent — including muted-skipped ones)` and `SetComposeLastRunTS(now.Unix())`. On ANY failure (AI error, parse error, DB apply error): mark/advance NOTHING — signals stay uncomposed, events re-read next cycle (idempotency; merging is naturally idempotent because `AddSituationSignals` is INSERT OR IGNORE and duplicate `create` for the same theme is what DASH-01 merging prevents — acceptable at-least-once).
- Applying ops: `create` → `CreateSituation` (kind/priority validated, invalid → external/medium; rank clamped 0..1) + `AddSituationSignals` for `sig:` members (evt:/tgt: members carry no signal link — they only justified the situation; target_id/track_id from the op); `merge` → `AddSituationSignals` + `ResetSituationCard` + optional `UpdateSituationRank` when `rerank`>0 or reason present; `rerank` → `UpdateSituationRank`. Hallucinated situation ids / signal keys are skipped. A `merge` into a non-open situation is skipped.
- DASH-02: any error path leaves existing situations untouched (parse before any DB write; the apply loop per-op failures log and continue, but AI/parse failure aborts before writes).
- Deterministic pre-step (before the AI call): `AutoCloseResolvedSituations()` — spec's auto-close, no AI needed.

- [ ] **Step 1: Write failing tests**

`internal/inbox/compose_test.go` (reuse `newTestDB`, `seedWorkspaceAndUser`, `seqGenerator`; add a `newComposePipeline` helper mirroring `newTriagePipeline` with Dashboard config set):

```go
func TestCompose_CreatesSituationFromSignals(t *testing.T) {
	// 2 pending signals; generator returns one create op with both sig keys;
	// assert: 1 open situation, title/kind/priority/rank/reason persisted,
	// 2 member signals, both signals composed_at set, watermark advanced.
}
func TestDash01_MergeIntoOpenSituation(t *testing.T) {
	// existing open situation with 1 member; new signal; generator returns merge op;
	// assert: still exactly 1 situation, 2 members, card_status reset to 'none',
	// no duplicate situation created.
}
func TestDash02_AIFailureTouchesNothing(t *testing.T) {
	// open situation + pending signal; generator errors;
	// assert: err != nil, situation unchanged (rank/status/card), signal composed_at still NULL,
	// compose watermark unchanged.
}
func TestDash02_InvalidJSONTouchesNothing(t *testing.T) { /* same with "not json" */ }
func TestCompose_EmptyInputSkipsAI(t *testing.T) {
	// nothing pending/no events → (0,0,nil) and gen.calls == 0.
}
func TestCompose_HallucinatedKeysSkipped(t *testing.T) {
	// create op referencing sig:9999 → situation created with 0 members... decide: create op whose
	// ALL signals are hallucinated still creates the situation (evt/tgt-justified ones are legal);
	// assert no error and no signal links.
}
func TestCompose_AutoClosePreStep(t *testing.T) {
	// open situation whose only member signal is resolved → after runCompose (empty AI input),
	// situation is done/signals_resolved without any AI call.
}
func TestCompose_MutedSignalsExcludedButMarked(t *testing.T) {
	// signal in hard-muted channel; generator receives no candidates (gen.calls==0 if nothing else),
	// but composed_at IS set on the muted signal after the pass (empty-input path must still mark muted ones).
}
```

(Last test pins a subtle rule: muted signals are marked composed WITHOUT an AI call so they don't pile up forever. Implement: mute-filter first; if remaining input empty → mark muted ones + return.)

- [ ] **Step 2: RED**

Run: `go test ./internal/inbox/ -run 'TestCompose|TestDash0' > /tmp/wt-d4.log 2>&1; echo "exit=$?"` → exit=1.

- [ ] **Step 3: Implement compose.go + config**

Structure (~200 lines): `runCompose` = auto-close pre-step → gather inputs → mute filter → empty-check → build blocks (open-situations block: `id=4 [external] title :: reason :: recent: s1; s2`; new-material block: `sig:<id> [trigger_type] from=<sender> channel=<ch> :: snippet`, `evt:<id> [track:<track title>] :: summary`, `tgt:<id> [target:<status>] :: text`) → `fmt.Sprintf(tmpl, directive, brief, openBlock, newBlock)` → Generate with WithSource → ExtractJSONObject + Unmarshal into `struct{ Ops []composeOp }` → apply loop → mark composed + advance watermark.

- [ ] **Step 4: GREEN + commit**

Run: `go test ./internal/inbox/ ./internal/config/ > /tmp/wt-d4.log 2>&1; echo "exit=$?"` → exit=0; `go build ./... && go vet ./internal/inbox/ ./internal/config/` clean.

```bash
git add internal/inbox/compose.go internal/inbox/compose_test.go internal/config/
git commit -m "feat(inbox): situation composer — clusters signals and work updates into situations"
```

---

### Task 5: Situation-card stage (`internal/inbox/situation_card.go`)

**Files:**
- Create: `internal/inbox/situation_card.go`
- Test: `internal/inbox/situation_card_test.go`

**Interfaces:**
- Consumes: `ListSituationsNeedingCards`, `SetSituationCard`, `MarkSituationCardFailed`, `ListSituationSignals` (Task 1/3); `prompts.InboxSituationCard`; `buildSecretaryBrief`; `digest.WithSource(ctx, "inbox.situation_card")`; `p.accumulateUsage`.
- Produces: `func (p *Pipeline) runSituationCards(ctx context.Context, currentUserID string) (int, error)` — mirrors the merged runCards contract exactly: nil generator or empty list → (0,nil); per-situation AI/parse failure (or empty `summary`) → `MarkSituationCardFailed` + continue; `SetSituationCard` persist failure → return error; listing failure → return error.

Situation block for the prompt: title, kind, reason, target/track name when linked, then member signals oldest-first (`from=<sender> channel=<ch> :: snippet`, cap 20 members, note "…and N more" beyond).

- [ ] **Step 1: Write failing tests** (mirror card_test.go shapes)

```go
func TestRunSituationCards_GeneratesAndPersists(t *testing.T)      // ready + fields persisted
func TestDash02_CardFailureMarksFailedAndContinues(t *testing.T)   // 2 situations, first errors → failed+continue, n==1, err==nil
func TestRunSituationCards_EmptySummaryMarksFailed(t *testing.T)
func TestRunSituationCards_NilGeneratorSkips(t *testing.T)
```

- [ ] **Step 2: RED** — `go test ./internal/inbox/ -run 'TestRunSituationCards|TestDash02_Card' > /tmp/wt-d5.log 2>&1; echo "exit=$?"` → exit=1.

- [ ] **Step 3: Implement** (clone card.go's loop shape with the new prompt/fields).

- [ ] **Step 4: GREEN + commit**

```bash
git add internal/inbox/situation_card.go internal/inbox/situation_card_test.go
git commit -m "feat(inbox): situation cards — context packet per situation"
```

---

### Task 6: Pipeline rewire — compose phases in, per-item cards out

**Files:**
- Modify: `internal/inbox/pipeline.go` (Run :314-393 — insert phases; delete runCards call), `internal/inbox/card.go` + `card_test.go` (DELETE files), `internal/prompts/store.go`/`defaults.go` (deregister `InboxCard`), `internal/digest/models_test.go` + `internal/codex/models_test.go` (drop inbox.card rows)
- Create: `internal/db/migrations/00012_deregister_inbox_card.sql` (`DELETE FROM prompts WHERE id = 'inbox.card';` Up; no-op Down comment `-- prompt re-seeds from defaults on downgrade builds`)
- Test: `internal/inbox/pipeline_test.go`, `internal/inbox/e2e_test.go`

**Interfaces:**
- New Run phase order (totalSteps stays 7): dedup → detect → triage → learn → auto-resolve → **compose** (`runCompose`) → **situation cards** (`runSituationCards`, only when generator != nil per its own guard) → archive/unsnooze (now ALSO `UnsnoozeExpiredSituations` + `MarkStaleSituations(cfg.Dashboard.StaleAfterDays)`) → watermark (unchanged). Compose/situation-card failures are logged, do NOT affect the inbox watermark decision, and do NOT fail Run (feed stability is DASH-02's own contract; the inbox watermark contract INBOX-09 stays keyed to detect/triage only).
- `runCards`, `cardResult`, `inbox.card` registration and its routing-test rows are deleted. `inbox_items` card columns stay (dormant). RunFastDetection untouched.
- E2E guard: `TestDash_E2E_SignalToSituation` — message → Run with a seqGenerator scripted for triage(action)→compose(create)→situation card → assert open situation with ready card exists and feed-able via `ListOpenSituations`.

- [ ] **Step 1: Adapt tests first**

Delete card_test.go with card.go (its contracts moved to situation_card_test.go in Task 5). Update any pipeline/e2e test whose seqGenerator response sequence assumed the runCards call slot (they now need compose+situation-card responses or `{"ops":[]}` no-ops — grep seqGenerator usages in pipeline_test.go/e2e_test.go and re-script). Add `TestDash_E2E_SignalToSituation`. RED: `go test ./internal/inbox/ > /tmp/wt-d6.log 2>&1; echo "exit=$?"` → exit=1.

- [ ] **Step 2: Implement rewire + deregistration + migration 00012**

- [ ] **Step 3: Verify**

`go build ./... && go vet ./... > /tmp/wt-d6.log 2>&1; echo "exit=$?"` → exit=0. `go test ./internal/inbox/ ./internal/db/ ./internal/prompts/ ./internal/digest/ ./internal/codex/ ./cmd/... > /tmp/wt-d6.log 2>&1; echo "exit=$?"` → exit=0. Golden regen for 00012 if the prompts DELETE affects it (it does not touch schema — confirm golden unchanged). Grep: `grep -rn "runCards\|inbox.card\b\|InboxCard\b" internal/ cmd/ --include="*.go"` → only migration 00012 + InboxSituationCard hits.

- [ ] **Step 4: Commit**

```bash
git add -A internal/ && git commit -m "feat(inbox): compose + situation-card phases replace per-item cards"
```

---

### Task 7: CLI — `watchtower situations`

**Files:**
- Create: `cmd/situations.go`
- Test: `cmd/situations_test.go`

**Interfaces:**
- Consumes: `ListOpenSituations`, `GetSituation`, `ListSituationSignals`.
- Produces: `watchtower situations` (table: id, priority, kind, title, reason — ranked) and `watchtower situations show <id>` (title, kind, status, why_matters, summary, chronology, member signals with permalinks). Follow the cobra registration pattern of `cmd/inbox.go` (root registration in init, db open via the file's existing helper — copy the shape of the smallest neighboring command file).

- [ ] **Step 1: Failing test** — follow `cmd/` test conventions (find how cmd tests build a test DB + capture output; mirror the closest existing list-command test, e.g. the inbox list test): seed 2 situations (ranks 0.9/0.2), run the command function, assert output order and content; `show` with unknown id → error.
- [ ] **Step 2: RED** → implement → GREEN: `go test ./cmd/ -run TestSituations > /tmp/wt-d7.log 2>&1; echo "exit=$?"` → exit=0.
- [ ] **Step 3: Commit** — `git add cmd/ && git commit -m "feat(cli): watchtower situations list/show"`

---

### Task 8: Desktop — model, TestDatabase mirror, queries

**Files:**
- Create: `WatchtowerDesktop/Sources/Models/Situation.swift`
- Create: `WatchtowerDesktop/Sources/Database/Queries/SituationQueries.swift`
- Modify: `WatchtowerDesktop/Tests/Helpers/TestDatabase.swift` (situations + situation_signals DDL from schema.sql verbatim; inbox_items gains composed_at; workspace gains compose_last_run_ts; add insertSituation/linkSituationSignal fixture helpers)
- Test: `WatchtowerDesktop/Tests/SituationQueriesTests.swift`, `WatchtowerDesktop/Tests/SituationTests.swift`

**Interfaces:**
- Produces:

```swift
struct Situation: FetchableRecord, Identifiable, Equatable {
    let id: Int
    let title: String
    let kindRaw: String        // enum Kind: external, targetUpdate = "target_update", trackUpdate = "track_update", mixed
    let statusRaw: String      // enum Status: open, done, dismissed, converted, stale, snoozed
    let priority: String
    let rank: Double
    let aiReason: String
    let summary: String
    let whyMatters: String
    let chronology: String
    let cardStatusRaw: String  // CardStatus none/ready/failed (same enum pattern as InboxItem)
    let targetID: Int?
    let trackID: Int?
    let convertedTargetID: Int?
    let convertedTrackID: Int?
    let lastSignalAt: String
    let snoozeUntil: String
    let createdAt: Date?
    let updatedAt: Date?
    var hasCard: Bool { cardStatus == .ready }
}

enum SituationQueries {
    static func fetchFeed(_ db: Database, limit: Int, offset: Int) throws -> [Situation] // status='open', ORDER BY rank DESC, updated_at DESC
    static func fetchByID(_ db: Database, id: Int) throws -> Situation?
    static func openCount(_ db: Database) throws -> Int
    static func memberSignals(_ db: Database, situationID: Int) throws -> [InboxItem]   // join, message_ts ASC
    static func done(_ db: Database, id: Int) throws
    static func dismiss(_ db: Database, id: Int) throws
    static func snooze(_ db: Database, id: Int, until: String) throws
    static func markConverted(_ db: Database, id: Int, targetID: Int?, trackID: Int?) throws
    static func recordFeedback(_ db: Database, situationID: Int, rating: Int) throws
    // rating -1: upsert source_mute rules (weight -1.0, source 'user_rule') for each DISTINCT
    // "channel:<id>" scope of member signals — mirror InboxFeedbackQueries.upsertRule shape.
    // rating +1: no rule (audit-free v1, matches gradual-learning contract INBOX-04).
}
```

All writes bump `updated_at` via strftime pattern; `done`/`dismiss` set `resolved_reason` 'user_done'/'user_dismissed'.

- [ ] **Step 1: TestDatabase mirror first** (copy DDL from internal/db/schema.sql verbatim — the known drift trap).
- [ ] **Step 2: Failing tests** — feed order (rank desc), memberSignals order, done/dismiss/snooze status flips, markConverted links, recordFeedback(-1) creates channel mute rules for member scopes (assert via existing learned-rules fixtures), model column mapping incl. kind/status enums fallback.
- [ ] **Step 3: RED via build/test** (temp-worktree pattern if the tree is dirty) → implement → GREEN: `cd WatchtowerDesktop && swift build && swift test` exit=0.
- [ ] **Step 4: Commit** — `git add WatchtowerDesktop/ && git commit -m "feat(desktop): situation model and queries"`

---

### Task 9: Desktop — DashboardViewModel + DashboardView (feed replaces inbox feed)

**Files:**
- Create: `WatchtowerDesktop/Sources/ViewModels/DashboardViewModel.swift`
- Create: `WatchtowerDesktop/Sources/Views/Dashboard/DashboardView.swift`, `WatchtowerDesktop/Sources/Views/Dashboard/SituationCardView.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Inbox/InboxFeedView.swift` (tab container: `.feed` branch renders DashboardView content; tab title "Dashboard"), `WatchtowerDesktop/Sources/App/SidebarDestination.swift` (title "Inbox"→"Dashboard", icon "tray"→"square.grid.2x2"), `WatchtowerDesktop/Sources/App/AppState.swift:7` (`selectedDestination = .inbox` — keep the case name, it now renders the dashboard), `WatchtowerDesktop/Sources/ViewModels/SidebarCountsViewModel.swift` (+situations open count, observe situations table), `WatchtowerDesktop/Sources/Views/Sidebar/SidebarView.swift` (badge = open situations count)
- Test: `WatchtowerDesktop/Tests/DashboardViewModelTests.swift`, update `SidebarCountsViewModelTests.swift`

**Interfaces:**
- Consumes: Task 8 model/queries; existing patterns: `@MainActor @Observable` VM with ValueObservation + 30s poll (InboxViewModel.swift:50-107), single-open expansion (`expandedItemID` pattern), `SnoozeOption` enum + date math (lift `InboxFeedView.snoozeItem` :307-324 into a shared helper `SnoozeDates.swift` in Sources/Services — InboxFeedView and DashboardView both use it).
- Produces: `DashboardViewModel` (props: `situations: [Situation]`, `openCount: Int`, pagination `pageSize=50`/`loadMore()`, name caches reused via the same queries as InboxViewModel; actions `done/dismiss/snooze/feedback/loadMemberSignals(situationID) -> [InboxItem]`); `DashboardView` (ranked feed; compact row: title + kind badge + one-line whyMatters-or-aiReason; expand inline → SituationCardView); `SituationCardView` (summary, why-it-matters, chronology text, expandable member-signal originals — reuse the conversation-render idiom from InboxCardView :362; "Preparing context…" placeholder when !hasCard, "Context unavailable — will retry" on failed — same idiom as merged card UI; action row placeholder: Done/Dismiss/Snooze/👍👎 wired; Create-buttons land in Task 10).
- Kind badge: external → gray "signal", target_update → colored "Target: <name?>" (name lookup via targetID → TargetQueries.fetchByID if cheap; else just "Target"), track_update → "Track", mixed → "Mixed".
- Sidebar: `.inbox` destination badge count switches to open-situations count; `SidebarCountsViewModel` observation list gains `"situations"`.

- [ ] **Step 1: Failing VM tests** — feed loads ranked; done/dismiss/snooze flip status and reload; loadMemberSignals returns joined items; sidebar count = open situations.
- [ ] **Step 2: RED → implement → GREEN** (`swift build && swift test` exit=0; temp-worktree if dirty).
- [ ] **Step 3: Commit** — `git add WatchtowerDesktop/ && git commit -m "feat(desktop): dashboard — secretary-ranked situation feed replaces inbox feed"`

---

### Task 10: Desktop — create target / create track from a situation

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/TargetPrefillBuilder.swift` (+fromSituation), `WatchtowerDesktop/Sources/Views/Dashboard/SituationCardView.swift` + `DashboardView.swift` (action buttons + sheets), `WatchtowerDesktop/Sources/ViewModels/DashboardViewModel.swift` (markConverted)
- Test: `WatchtowerDesktop/Tests/TargetPrefillBuilderTests.swift` (+fromSituation case), `WatchtowerDesktop/Tests/DashboardViewModelTests.swift` (+conversion)

**Interfaces:**
- Consumes: `CreateTargetSheet(prefill:onCreated:)` (CreateTargetSheet.swift:7/:11, onCreated fires with new target id); `CustomTrackManagementSheet(linkedTargetID:onCreated:)` (CustomTrackManagementSheet.swift:11 — onCreated yields `TrackDraft`, NOT an id); `SituationQueries.markConverted` (Task 8).
- Produces:
  - `TargetPrefillBuilder.fromSituation(_ s: Situation, db: DatabaseManager) async throws -> TargetPrefill` — text from title, intent from summary (fallback aiReason). Source identity: `sourceType: "inbox"`, `sourceID: "situation:<id>"`. (Rationale, decided at plan time: the targets `source_type` CHECK has no 'situation' value and expanding a CHECK requires the table-recreation dance — not worth it; the dashboard is the inbox's successor, so the `inbox` source family is semantically correct and the prefixed sourceID keeps the linkage exact.) Secondary links: `slack:<channel>:<ts>` for up to 3 member signals.
  - Create target flow: button → fromSituation → CreateTargetSheet; onCreated → `markConverted(id, targetID: newID, trackID: nil)` + reload. DASH-03.
  - Create track flow: button → `CustomTrackManagementSheet(linkedTargetID: nil, onCreated: draft → ...)`. TrackDraft has no id: after onCreated, resolve the new track by fetching the newest `origin='custom'` track (`TrackQueries` — check for a fetch-latest-custom; if absent add `fetchLatestCustom(_ db:)` to TrackQueries) and `markConverted(id, targetID: nil, trackID: thatID)`. If resolution fails, situation stays open (log only) — conversion is best-effort for tracks in v1; note this in the code comment.
- [ ] **Step 1: Failing tests** — fromSituation prefill fields incl. sourceID format + secondary links; conversion marks status converted + link ids.
- [ ] **Step 2: RED → implement → GREEN** (`swift build && swift test` exit=0).
- [ ] **Step 3: Commit** — `git add WatchtowerDesktop/ && git commit -m "feat(desktop): create target/track from a situation with conversion links"`

---

### Task 11: Docs — dashboard inventory, inbox-pulse note, app guide, CLAUDE.md

**Files:**
- Create: `docs/inventory/dashboard.md`
- Modify: `docs/inventory/inbox-pulse.md` (INBOX-01 observable rewording per spec + changelog line), `docs/inventory/README.md` (module mapping row), `docs/app-guide.md` (Inbox section → Dashboard), `CLAUDE.md` (feature note)

**Interfaces:** guard names must grep to real tests (internal/inventory test enforces):
- DASH-01 → `internal/inbox/compose_test.go::TestDash01_MergeIntoOpenSituation`
- DASH-02 → `compose_test.go::TestDash02_AIFailureTouchesNothing`, `::TestDash02_InvalidJSONTouchesNothing`, `situation_card_test.go::TestDash02_CardFailureMarksFailedAndContinues`
- DASH-03 → `WatchtowerDesktop/Tests/DashboardViewModelTests.swift` conversion test (verify the exact test name you wrote in Task 10) + `internal/db/situations_test.go::TestMarkSituationConverted`

- [ ] **Step 1:** Write dashboard.md (format of inbox-pulse.md: Status/Observable/Why locked/Test guards/Locked since 2026-07-06); INBOX-01 rewording (guards unchanged — only the Observable paragraph); app-guide Dashboard section (feed, kind badges, context packet, create actions, snooze options, Learned/Profile tabs unchanged); CLAUDE.md: add compose/situation_card to the Inbox Pulse note.
- [ ] **Step 2:** Verify `go test ./internal/inventory/ > /tmp/wt-d11.log 2>&1; echo "exit=$?"` → exit=0 (guard resolution) and full `go test ./... ` → exit=0.
- [ ] **Step 3:** Commit — `git add docs/ CLAUDE.md && git commit -m "docs: secretary dashboard — contracts, app guide, developer notes"`

---

### Final verification (before PR)

- [ ] `go build ./... && go vet ./... > /tmp/wt-dfinal.log 2>&1; echo "exit=$?"` → exit=0
- [ ] `go test ./... > /tmp/wt-dfinal.log 2>&1; echo "exit=$?"` → exit=0
- [ ] Clean-worktree verification (CI mirror — local dirty tree masks failures, proven last cycle): `git worktree add <scratch>/ci-mirror HEAD` → full go suite + `swift build && swift test` there → remove worktree.
- [ ] Sentrux: `sentrux check . && sentrux gate .` in the clean worktree (complex-function count vs baseline — extract helpers if the composer pushed something over).
- [ ] Whole-branch review (opus) → fix wave → PR to main (English description), CI babysit incl. the known dual-run + install-flake patterns.
