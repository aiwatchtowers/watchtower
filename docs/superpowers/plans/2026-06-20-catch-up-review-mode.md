# Catch-Up v2 — Review Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the v1 bulk-clear Catch-Up with a persisted, streaming, one-theme-at-a-time review experience whose per-theme feedback trains all pipelines.

**Architecture:** On-demand pipeline does `gather → outline (one cheap AI call → theme skeletons) → fan-out expand (one AI call per theme, bounded concurrency, written to DB incrementally)`. Themes/sessions/feedback persist in SQLite; the SwiftUI app reads them via GRDB `ValueObservation` (live stream) and drives a two-panel master-detail review UX. Comment feedback runs an agentic interpreter that (a) regenerates the theme's catch-up layer and (b) derives targeted learned-rules addressed to the originating pipeline.

**Tech Stack:** Go 1.25, `database/sql` + goose migrations (`modernc.org/sqlite`), cobra CLI, `digest.Generator` AI interface; SwiftUI macOS 14+, GRDB.swift, XCTest.

**Design spec:** `docs/superpowers/specs/2026-06-20-catch-up-review-mode-design.md`

## Global Constraints

- Go module `watchtower`; Go 1.25; SQLite via `modernc.org/sqlite` through `database/sql`.
- Migrations are **goose** files in `internal/db/migrations/` (latest is `00002_target_due_inbox.sql`); add `00003_catchup_review.sql`. The matching DDL must ALSO be mirrored into `internal/db/schema.sql` (its embedded copy is what Swift `TestDatabase` loads). CHECK-constraint changes use the table-recreate pattern from `00002`.
- AI calls go through `digest.Generator.Generate(ctx, systemPrompt, userMessage, "") (string, *Usage, string, error)`; pick model tier with `digest.WithSource(ctx, "<source>")`; split a single prompt string with `digest.SplitPromptAtData(prompt)`. Parse JSON manually (tolerate markdown fences, as the existing `parseAIOutput` does).
- Per-area gather caps + max-age live in `cfg.Catchup` (`config.CatchupCaps{Digests,Tracks,Inbox,Briefings}`, `cfg.Catchup.MaxAgeDays`) — reuse, do not duplicate.
- All GitHub-facing text and user-visible copy in **English**.
- Swift ViewModels are `@MainActor @Observable final class`; Views bind via `@Bindable`; DB access via `dbPool: DatabasePool`; never block the main actor on a subprocess (use the `runCLI`/`runCLIBlocking` detached pattern that drains stdout+stderr concurrently).
- TDD: write the failing test first, watch it fail, implement minimally, watch it pass, commit. Go tests use a `mockGenerator`; never call a real AI binary in tests.
- Behavioral reversal vs v1 (bulk mark-read removed; ephemeral→persisted) is intentional and approved. If any guard test in `docs/inventory/` asserts old behavior, STOP and ask the owner (catch-up is currently NOT in inventory).

---

## File Structure

**Go (create):**
- `internal/db/migrations/00003_catchup_review.sql` — schema delta.
- `internal/catchup/store.go` — session/theme DB access (new tables).
- `internal/catchup/learn.go` — learning interpreter (feedback → rules).
- (rewrite) `internal/catchup/types.go`, `pipeline.go`, `prompt.go`.
- (rewrite) `cmd/catchup.go` — `run`/`regen`/`feedback`/`ack` subcommands.

**Go (modify):**
- `internal/db/schema.sql` — mirror the migration DDL.
- `internal/db/inbox_learned_rules.go` — add `Pipeline` field + pipeline-scoped upsert/list.
- `internal/db/feedback.go` — nothing structural; `AddFeedback` already supports arbitrary `entity_type` once the CHECK allows `catchup_theme`.

**Swift (create):**
- `WatchtowerDesktop/Sources/Models/CatchUpModels.swift` — `CatchUpSession`, `CatchUpTheme` (FetchableRecord, JSON `refs`).
- `WatchtowerDesktop/Sources/Database/Queries/CatchUpQueries.swift` — fetch/observe/ack.
- (rewrite) `WatchtowerDesktop/Sources/ViewModels/CatchUpViewModel.swift`.
- (rewrite) `WatchtowerDesktop/Sources/Views/CatchUp/CatchUpView.swift` + new `CatchUpThemeRow.swift`, `CatchUpReviewPane.swift`.

**Swift (modify):**
- `WatchtowerDesktop/Sources/ViewModels/SidebarCountsViewModel.swift` — badge = pending themes of active session, fallback to unread sum.
- `WatchtowerDesktop/Tests/Helpers/TestDatabase.swift` — ensure the embedded `schema` has the new tables (auto if mirrored into schema.sql + copied).

---

## PHASE 1 — Go backend

### Task 1: DB migration + schema mirror

**Files:**
- Create: `internal/db/migrations/00003_catchup_review.sql`
- Modify: `internal/db/schema.sql`
- Test: `internal/db/catchup_store_test.go` (created in Task 2 exercises the schema; Task 1's test is a migration smoke test in `internal/db/migrations_test.go` if one exists, else fold into Task 2).

**Interfaces:**
- Produces tables `catchup_sessions`, `catchup_themes`; column `inbox_learned_rules.pipeline TEXT NOT NULL DEFAULT 'inbox'`; `feedback.entity_type` CHECK gains `'catchup_theme'`.

- [ ] **Step 1: Write the migration**

`internal/db/migrations/00003_catchup_review.sql`:
```sql
-- +goose Up
PRAGMA defer_foreign_keys = ON;

CREATE TABLE IF NOT EXISTS catchup_sessions (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at     TEXT NOT NULL,
    status         TEXT NOT NULL CHECK(status IN ('building','active','done','failed')),
    oldest_unread  TEXT NOT NULL DEFAULT '',
    total_themes   INTEGER NOT NULL DEFAULT 0,
    reviewed_count INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS catchup_themes (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id       INTEGER NOT NULL REFERENCES catchup_sessions(id) ON DELETE CASCADE,
    order_idx        INTEGER NOT NULL DEFAULT 0,
    title            TEXT NOT NULL DEFAULT '',
    narrative        TEXT NOT NULL DEFAULT '',
    priority         TEXT NOT NULL DEFAULT 'medium' CHECK(priority IN ('high','medium','low')),
    needs_you        INTEGER NOT NULL DEFAULT 0,
    suggested_action TEXT NOT NULL DEFAULT '',
    refs             TEXT NOT NULL DEFAULT '[]',
    gen_state        TEXT NOT NULL DEFAULT 'skeleton' CHECK(gen_state IN ('skeleton','expanding','ready','failed')),
    review_state     TEXT NOT NULL DEFAULT 'pending' CHECK(review_state IN ('pending','reviewed','snoozed')),
    snooze_until     TEXT NOT NULL DEFAULT '',
    task_id          INTEGER NOT NULL DEFAULT 0,
    created_at       TEXT NOT NULL,
    updated_at       TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_catchup_themes_session ON catchup_themes(session_id, order_idx);

ALTER TABLE inbox_learned_rules ADD COLUMN pipeline TEXT NOT NULL DEFAULT 'inbox';

-- Expand feedback.entity_type CHECK to include 'catchup_theme' (table recreate).
CREATE TABLE feedback_new (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_type TEXT NOT NULL CHECK(entity_type IN ('digest','track','decision','user_analysis','briefing','target','inbox','catchup_theme')),
    entity_id   TEXT NOT NULL,
    rating      INTEGER NOT NULL CHECK(rating IN (-1, 1)),
    comment     TEXT NOT NULL DEFAULT '',
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
INSERT INTO feedback_new SELECT id, entity_type, entity_id, rating, comment, created_at FROM feedback;
DROP TABLE feedback;
ALTER TABLE feedback_new RENAME TO feedback;
CREATE INDEX IF NOT EXISTS idx_feedback_entity ON feedback(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_feedback_rating ON feedback(entity_type, rating);

-- +goose Down
PRAGMA defer_foreign_keys = ON;
DROP TABLE IF EXISTS catchup_themes;
DROP TABLE IF EXISTS catchup_sessions;
ALTER TABLE inbox_learned_rules DROP COLUMN pipeline;

CREATE TABLE feedback_old (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_type TEXT NOT NULL CHECK(entity_type IN ('digest','track','decision','user_analysis','briefing','target','inbox')),
    entity_id   TEXT NOT NULL,
    rating      INTEGER NOT NULL CHECK(rating IN (-1, 1)),
    comment     TEXT NOT NULL DEFAULT '',
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
INSERT INTO feedback_old SELECT id, entity_type, entity_id, rating, comment, created_at FROM feedback WHERE entity_type <> 'catchup_theme';
DROP TABLE feedback;
ALTER TABLE feedback_old RENAME TO feedback;
CREATE INDEX IF NOT EXISTS idx_feedback_entity ON feedback(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_feedback_rating ON feedback(entity_type, rating);
```

- [ ] **Step 2: Mirror the same DDL into `internal/db/schema.sql`** — add the two CREATE TABLEs + index, add `pipeline` column to the `inbox_learned_rules` CREATE, and add `'catchup_theme'` to the `feedback` CHECK list. (schema.sql is the canonical full schema; keep it in sync.)

- [ ] **Step 3: Verify migration applies** — `go test ./internal/db/ -run TestMigrat -v` if such a test exists; otherwise `go build ./...` then run the Task 2 store test which opens a fresh DB (goose Up runs on `db.Open`).

- [ ] **Step 4: Commit** — `git add internal/db/migrations/00003_catchup_review.sql internal/db/schema.sql && git commit -m "feat(catchup): schema for review sessions, themes, rule pipelines"`

### Task 2: catch-up store (sessions + themes DB access)

**Files:**
- Create: `internal/catchup/store.go`
- Test: `internal/catchup/store_test.go`

**Interfaces:**
- Consumes: `*db.DB` (has `.DB *sql.DB`, `.Exec`, `.Query`, `.QueryRow`).
- Produces (all methods on `*Store` wrapping `*db.DB`, or free funcs on `*db.DB` in package db — choose `*db.DB` methods in a new file `internal/db/catchup_store.go` to match existing style; the agent should follow the existing `internal/db/catchup.go` convention of methods on `*DB`). Final chosen signatures:
  - `func (db *DB) CreateCatchupSession(oldestUnread string) (int64, error)` — inserts status='building'.
  - `func (db *DB) SetCatchupSessionStatus(id int64, status string) error`
  - `func (db *DB) SetCatchupSessionTotals(id int64, totalThemes int) error`
  - `func (db *DB) IncrementReviewed(sessionID int64) error`
  - `func (db *DB) GetActiveCatchupSession() (*CatchupSession, error)` — newest non-done/non-failed, else nil.
  - `func (db *DB) InsertCatchupTheme(t CatchupTheme) (int64, error)` — skeleton insert.
  - `func (db *DB) UpdateCatchupThemeExpansion(id int64, narrative, priority string, needsYou bool, suggestedAction, genState string) error`
  - `func (db *DB) GetCatchupTheme(id int64) (*CatchupTheme, error)`
  - `func (db *DB) ListCatchupThemes(sessionID int64) ([]CatchupTheme, error)`
  - `func (db *DB) SetCatchupThemeReview(id int64, reviewState, snoozeUntil string) error`
  - `func (db *DB) SetCatchupThemeTask(id int64, taskID int64) error`
  - `func (db *DB) CloseOpenCatchupSessions() error` — mark any building/active → done (called before a new run).
- Model structs (in `internal/db/catchup_store.go`):
  ```go
  type CatchupSession struct { ID int64; CreatedAt, Status, OldestUnread string; TotalThemes, ReviewedCount int }
  type CatchupRef struct { Area string `json:"area"`; ID int `json:"id"`; Label string `json:"label"` }
  type CatchupTheme struct {
      ID, SessionID int64
      OrderIdx int
      Title, Narrative, Priority string
      NeedsYou bool
      SuggestedAction, RefsJSON, GenState, ReviewState, SnoozeUntil string
      TaskID int64
      CreatedAt, UpdatedAt string
  }
  ```

- [ ] **Step 1: Write failing test** `internal/db/catchup_store_test.go`: open a fresh `db.Open(":memory:")` (recall `SetMaxOpenConns(1)` is handled in db.Open for memory), create a session, insert a skeleton theme, update its expansion, list themes, assert fields round-trip; assert `GetActiveCatchupSession` returns it; assert `CloseOpenCatchupSessions` flips status to 'done' and then `GetActiveCatchupSession` returns nil.

- [ ] **Step 2: Run → FAIL** (`go test ./internal/db/ -run TestCatchupStore -v`).

- [ ] **Step 3: Implement** `internal/db/catchup_store.go` with the structs + methods above (mirror the SQL style of `internal/db/inbox_learned_rules.go`; timestamps via `time.Now().UTC().Format(time.RFC3339)`).

- [ ] **Step 4: Run → PASS.**

- [ ] **Step 5: Commit** — `git commit -am "feat(catchup): session/theme DB store"`

### Task 3: learned-rules pipeline scoping

**Files:**
- Modify: `internal/db/inbox_learned_rules.go`
- Test: `internal/db/inbox_learned_rules_test.go` (extend)

**Interfaces:**
- `InboxLearnedRule` gains `Pipeline string`.
- `UpsertLearnedRule`/`UpsertLearnedRuleImplicit` persist `Pipeline` (default `"inbox"` when empty, to keep existing callers working).
- New: `func (db *DB) ListLearnedRulesByPipeline(pipeline string, limit int) ([]InboxLearnedRule, error)` — for non-inbox pipelines to inject their own rules.
- `ListLearnedRulesByScope` selects and scans `pipeline` too.

- [ ] **Step 1: Failing test** — upsert a rule with `Pipeline:"digest"`, assert `ListLearnedRulesByPipeline("digest", 10)` returns it and `ListLearnedRulesByPipeline("inbox", 10)` does not; assert an existing-style upsert with empty Pipeline stores `"inbox"`.
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** — add column to SELECT/INSERT lists, default empty→"inbox", add the new list func. The UNIQUE constraint stays `(rule_type, scope_key)`; `pipeline` rides along (a scope_key is conceptually owned by one pipeline). If two pipelines could share a scope_key, prefix scope keys per pipeline at the caller (e.g. `digest:channel:Cxxx`) rather than widening the UNIQUE — document this in a comment.
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** — `git commit -am "feat(catchup): pipeline-scoped learned rules"`

### Task 4: pipeline types + gather + outline (skeletons)

**Files:**
- Rewrite: `internal/catchup/types.go`, `internal/catchup/prompt.go`, `internal/catchup/pipeline.go`
- Test: `internal/catchup/pipeline_test.go` (rewrite)

**Interfaces:**
- `Pipeline{ db *db.DB; cfg *config.Config; gen digest.Generator; logger *log.Logger }`, `New(db, cfg, gen, logger)`.
- `func (p *Pipeline) Run(ctx context.Context) (int64, error)` — returns the new session ID. Flow: `CloseOpenCatchupSessions` → gather → if zero unread return (0, nil) with no session → `CreateCatchupSession` → outline → insert skeleton themes → `SetCatchupSessionTotals` → status `active` after expand (Task 5 wires expand into Run). For Task 4, expand is a stub that marks themes ready with the outline data so the test is meaningful; Task 5 replaces the stub.
- Outline AI source tag: `digest.WithSource(ctx, "catchup.outline")`.
- Reuse `db.GetUnreadDigests/Tracks/InboxItems/Briefings(cap, maxAge)` and the existing `oneLine`, targets line helper.
- Outline AI returns `{"themes":[{"title","priority","refs":[{area,id,label}]}]}`; persisted as skeleton rows (`gen_state='skeleton'`), `order_idx` by AI order.

- [ ] **Step 1: Failing test** with a `mockGenerator` whose `Generate` returns canned outline JSON: assert `Run` creates a session, inserts N skeleton themes with correct titles/refs/order, sets totals; and that zero-unread returns `(0,nil)` and creates NO session (mock asserts Generate NOT called).
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** types (drop v1 `Story/Section/Counts/aiOutput`; add outline parse structs), `prompt.go` (`catchup.outline` system prompt: cluster into non-overlapping themes, only provided ids, rank by importance; `buildOutlineUserMessage(items..., targetsLine)`), and `pipeline.go` Run with the stubbed expand.
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** — `git commit -am "feat(catchup): gather + outline producing theme skeletons"`

### Task 5: fan-out expand + RegenTheme

**Files:**
- Modify: `internal/catchup/pipeline.go`, `internal/catchup/prompt.go`
- Test: `internal/catchup/pipeline_test.go` (extend)

**Interfaces:**
- `func (p *Pipeline) expand(ctx context.Context, sessionID int64, themes []db.CatchupTheme) ` — bounded-concurrency fan-out (errgroup or a semaphore channel sized `cfg.AI.Workers` default `config.DefaultAIWorkers`). Each goroutine: set `gen_state='expanding'`, call `gen.Generate(digest.WithSource(ctx,"catchup.expand"), sys, user, "")` with the theme's source records, parse `{narrative,priority,needs_you,suggested_action}`, `UpdateCatchupThemeExpansion(... 'ready')`. On per-theme error: `gen_state='failed'`, log, continue (never fail the whole run). After all: session status `active`.
- `func (p *Pipeline) RegenTheme(ctx context.Context, themeID int64, comment string) error` — reload theme, re-run the single expand call with `comment` appended to the user message ("OPERATOR CORRECTION: ..."), overwrite the row, keep `review_state`.
- Expand source records: reload the referenced items' snippets by re-gathering (cheap: the refs carry area+id; fetch titles/snippets from the per-area tables, or pass through the outline's labels). Simplest correct approach: store enough in `refs` (area,id,label) and re-query snippets via a new `db.GetUnreadByRefs` helper, OR (preferred, less code) keep a per-session in-memory map from the gather in Run and, for RegenTheme, re-gather. Choose: add `func (db *DB) FetchItemSnippet(area string, id int) (title, snippet string, err error)` and build the expand message from refs. Implement that helper here.

- [ ] **Step 1: Failing test** — mock returns outline (2 themes) then expand JSON per theme; assert after `Run` both themes are `gen_state='ready'` with narrative/priority/needs_you set and session `active`. Second test: one expand call errors → that theme `failed`, the other `ready`, session still `active`. Third: `RegenTheme` with a comment overwrites narrative (mock returns a different narrative when the user message contains "OPERATOR CORRECTION").
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** expand + RegenTheme + `FetchItemSnippet` + the `catchup.expand` prompt (`buildExpandUserMessage(theme, sources, comment)`).
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** — `git commit -am "feat(catchup): per-theme expand fan-out + targeted regen"`

### Task 6: learning interpreter + preferences injection

**Files:**
- Create: `internal/catchup/learn.go`
- Modify: `internal/inbox/user_preferences.go` (generalize), `internal/catchup/prompt.go`
- Test: `internal/catchup/learn_test.go`

**Interfaces:**
- `func (p *Pipeline) SubmitThemeFeedback(ctx context.Context, themeID int64, rating int, comment string) error`:
  1. `db.AddFeedback(db.Feedback{EntityType:"catchup_theme", EntityID:fmt.Sprint(themeID), Rating:rating, Comment:comment})` — always.
  2. If `comment == ""` → return (bare like/dislike = signal only, no rule).
  3. Else run the learning interpreter: `gen.Generate(digest.WithSource(ctx,"catchup.learn"), sys, user, "")` where the user message includes the theme (title, narrative, refs with their areas) + the operator's comment + rating. The model returns `{"rules":[{"pipeline","rule_type","scope_key","weight","reason"}],"regenerate":bool}`.
  4. For each returned rule: `db.UpsertLearnedRule(db.InboxLearnedRule{Pipeline:..., RuleType:..., ScopeKey:..., Weight:..., Source:"explicit_feedback", EvidenceCount:1})`.
  5. If `regenerate` → `p.RegenTheme(ctx, themeID, comment)`.
- Generalize `buildUserPreferencesBlock`: extract a `BuildPreferencesBlock(database *db.DB, pipeline string, scopeKeys []string) (string, error)` in `internal/inbox` (or move to a shared spot — keep in inbox to avoid churn, export it). Inbox's existing call becomes `BuildPreferencesBlock(db, "inbox", scopes)`. Catch-up's outline/expand prompts call it with the relevant pipeline(s). NOTE: keep the existing private `buildUserPreferencesBlock` working for inbox callers; add the exported general one and have the private delegate, to avoid breaking inbox tests.

- [ ] **Step 1: Failing test** `learn_test.go`: mock interpreter returns one rule `{pipeline:"digest",rule_type:"source_mute",scope_key:"digest:channel:Crandom",weight:-1.0}` + `regenerate:false`; call `SubmitThemeFeedback(themeID, -1, "this channel is noise")`; assert a `feedback` row exists AND `ListLearnedRulesByPipeline("digest",10)` contains the rule with `source='explicit_feedback'`. Second test: empty comment → feedback row written, NO rule, NO Generate call.
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** `learn.go`, the `catchup.learn` prompt, and the preferences generalization.
- [ ] **Step 4: Run → PASS** (and `go test ./internal/inbox/...` still green).
- [ ] **Step 5: Commit** — `git commit -am "feat(catchup): feedback learning interpreter + pipeline preference injection"`

### Task 7: CLI subcommands

**Files:**
- Rewrite: `cmd/catchup.go`
- Test: `cmd/catchup_test.go` (rewrite)

**Interfaces:**
- `watchtower catchup run [--json]` — `CloseOpenCatchupSessions` is inside `Run`; build a pooled generator (`cliPooledGenerator`) so expand fan-out is bounded; print progress or, with `--json`, the final `ListCatchupThemes(sessionID)` as JSON.
- `watchtower catchup regen <theme-id> --comment "..."` → `RegenTheme`.
- `watchtower catchup feedback <theme-id> --rating up|down [--comment "..."]` → `SubmitThemeFeedback` (map up→+1, down→-1).
- `watchtower catchup ack <theme-id>` → cascade mark-read over the theme's refs (digests/tracks/inbox/briefings) using existing `MarkTrackRead`, `MarkInboxRead`, `MarkBriefingRead`, and a digest mark-read; set `review_state='reviewed'`; `IncrementReviewed`. Implement `func (p *Pipeline) Acknowledge(themeID int64) error` in the catchup package so the cascade is testable without cobra.
- Drop the v1 deprecated `--since/--watched-only/--channel` shims (already deprecated; safe to remove now).

- [ ] **Step 1: Failing test** — `cmd/catchup_test.go` exercising `Acknowledge` cascade via the pipeline (a theme with refs to one digest + one inbox item → after `Acknowledge`, those rows are read, others untouched, theme `reviewed`, session `reviewed_count` incremented). Keep cobra wiring thin; test the pipeline method, not the cobra command.
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** `Acknowledge` (pipeline) + rewrite `cmd/catchup.go` with the four subcommands.
- [ ] **Step 4: Run → PASS**; then `gofmt -l`, `go vet ./...`, `go build ./...`.
- [ ] **Step 5: Commit** — `git commit -am "feat(catchup): CLI run/regen/feedback/ack subcommands"`

### Task 8: Go phase verification gate

- [ ] `gofmt -l internal/catchup cmd internal/db internal/inbox` → empty.
- [ ] `go vet ./...` → clean.
- [ ] `go build ./...` → ok.
- [ ] `go test ./internal/catchup/... ./internal/db/... ./internal/inbox/... ./cmd/...` → green.
- [ ] If golangci-lint is configured, run it on the changed packages.

---

## PHASE 2 — Swift Desktop

### Task 9: Swift models + CatchUpQueries

**Files:**
- Create: `WatchtowerDesktop/Sources/Models/CatchUpModels.swift`
- Create: `WatchtowerDesktop/Sources/Database/Queries/CatchUpQueries.swift`
- Modify: `WatchtowerDesktop/Tests/Helpers/TestDatabase.swift` (ensure embedded schema has new tables — confirm it mirrors schema.sql)
- Test: `WatchtowerDesktop/Tests/CatchUpQueriesTests.swift`

**Interfaces:**
- `struct CatchUpSession: FetchableRecord, Identifiable` — id, createdAt, status, oldestUnread, totalThemes, reviewedCount.
- `struct CatchUpTheme: FetchableRecord, Identifiable` — fields mirroring the Go row; `refs: String` raw JSON with `var decodedRefs: [CatchUpRef]` (pattern from `Track.decodedSourceRefs`).
- `struct CatchUpRef: Codable, Identifiable` — area, id (decode key `id`), label.
- `enum CatchUpQueries`: `fetchActiveSession(_:) throws -> CatchUpSession?`, `fetchThemes(_:sessionID:) throws -> [CatchUpTheme]`, `observeActiveThemes() -> ValueObservation<...>` (tracks active session's themes), `acknowledge(_ db:, theme:) throws` (cascade mark-read over refs using `DigestQueries.markDigestRead`, `TrackQueries.markRead`, `InboxQueries.markRead`, `BriefingQueries.markRead`; set review_state='reviewed'; bump reviewed_count), `setReview(_ db:, id:, state:, snoozeUntil:) throws`, `setTask(_ db:, id:, taskID:) throws`.

- [ ] **Step 1: Failing test** — insert a session + theme with refs JSON via raw SQL into a `TestDatabase` pool; `fetchThemes` returns it with `decodedRefs` parsed; `acknowledge` marks a referenced inbox item read and flips review_state. (Add new-table DDL to the test schema if not already mirrored.)
- [ ] **Step 2: Run → FAIL** (`cd WatchtowerDesktop && swift test --filter CatchUpQueriesTests`).
- [ ] **Step 3: Implement** models + queries.
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** — `git commit -am "feat(catchup): Swift models + CatchUpQueries"`

### Task 10: CatchUpViewModel rewrite

**Files:**
- Rewrite: `WatchtowerDesktop/Sources/ViewModels/CatchUpViewModel.swift`
- Test: rewrite `WatchtowerDesktop/Tests/CatchUpViewModelTests.swift`

**Interfaces:**
- `@MainActor @Observable final class CatchUpViewModel`: `var session: CatchUpSession?`, `var themes: [CatchUpTheme] = []`, `var selected: CatchUpTheme?`, `var isLoading`, `var error`.
- `func startSession()` — runs `catchup run` via the detached `runCLI` pattern; then `startObserving()`.
- `func startObserving()` — GRDB `ValueObservation` on active session themes → updates `themes`; auto-selects first `pending` if `selected == nil`.
- `func acknowledge(_:)` (dbPool.write CatchUpQueries.acknowledge, advance to next pending), `func submitFeedback(_ theme:, rating:Int, comment:String)` (runs `catchup feedback` CLI), `func regenerate(_ theme:, comment:String)` (runs `catchup regen` CLI), `func createTask(_:)` (existing TargetQueries.create + setTask), `func snooze(_ theme:, until:Date)` (setReview snoozed).
- Reuse the `runCLI`/`runCLIBlocking` static helpers from v1 verbatim.

- [ ] **Step 1: Failing test** — seed pool with session+themes; construct VM; `startObserving()`; assert `themes` populates and `selected` becomes the first pending; `acknowledge(selected)` advances selection to next pending. (CLI-invoking methods are covered by asserting they build correct args; keep CLI calls behind a small seam if needed, else test only DB-driven methods.)
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** — `git commit -am "feat(catchup): review-mode ViewModel with live theme stream"`

### Task 11: Views (two-panel review UX)

**Files:**
- Rewrite: `WatchtowerDesktop/Sources/Views/CatchUp/CatchUpView.swift`
- Create: `WatchtowerDesktop/Sources/Views/CatchUp/CatchUpThemeRow.swift`, `CatchUpReviewPane.swift`

**Interfaces:** consumes `CatchUpViewModel`. Layout: `HSplitView` (or `NavigationSplitView`) — left list of `CatchUpThemeRow` (title, priority dot, badges: needs-you / reviewed / spinner when `genState != "ready"`; progress header "5 of 12 reviewed") bound to `vm.selected`; right `CatchUpReviewPane` (large title, priority/needs-you, narrative, Sources block navigating via refs, suggested_action, action bar: 👍/👎 + comment field + Regenerate + Create task + Snooze + Done). Empty state when no session/zero unread. Loading state while building.

- [ ] **Step 1:** Build the views (UI; no unit test — verified by `swift build` + the VM tests).
- [ ] **Step 2:** `cd WatchtowerDesktop && swift build` → ok.
- [ ] **Step 3: Commit** — `git commit -am "feat(catchup): two-panel streaming review UI"`

### Task 12: Sidebar badge + final verification

**Files:**
- Modify: `WatchtowerDesktop/Sources/ViewModels/SidebarCountsViewModel.swift`
- Test: extend `SidebarCountsViewModel` tests if present.

**Interfaces:** `catchUpTotalCount` becomes: count of `pending` themes in the active catch-up session; fallback to the existing `unreadDigestCount + updatedTrackCount + inboxPendingCount + unreadBriefingCount` when no active session. Add `catchup_sessions`/`catchup_themes` to the observed tables list so the badge updates live.

- [ ] **Step 1: Failing test** — with an active session of 3 pending themes, badge = 3; with no session, badge = unread sum.
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run → PASS;** then `cd WatchtowerDesktop && swift build && swift test`.
- [ ] **Step 5: Commit** — `git commit -am "feat(catchup): sidebar badge from active review session"`

---

## Self-Review notes (spec coverage)

- Spec §1 data model → Tasks 1,2. §2 pipeline (outline→fan-out, regen) → Tasks 4,5. §3 learning loop → Task 6 (bare-dislike-no-rule covered). §4 Desktop UX → Tasks 10,11. §5 CLI → Task 7. §6 edge cases (zero-unread, outline fail→session failed, per-theme fail, snapshot-by-ref ack, idempotent) → Tasks 4,5,7,9. §7 testing → every task is TDD. §9 inventory → Global Constraints note.
- Deviation from spec: table kept as `inbox_learned_rules` + `pipeline` column rather than renamed to `learned_rules` (smaller blast radius; same capability). Flagged in Task 3.
- `buildUserPreferencesBlock` generalized via an exported `BuildPreferencesBlock(db, pipeline, scopeKeys)` with the private inbox one delegating — keeps inbox tests green (Task 6).
