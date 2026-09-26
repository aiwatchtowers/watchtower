# Reaction Commands Wave 2 + Inbox Action Strip — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Widen the reaction-command vocabulary (four new agent-actions tools + a reminders entity) and turn the Inbox tab into a flat gesture-gated action strip, muting the situations pipeline behind a narrow config gate.

**Architecture:** Four new registry tools mirror `create_target`'s shape (`internal/tools/`). `remind_me` writes a new `reminders` table; `brief_context` echoes a composer-produced summary into its own action row. The Desktop Inbox tab is repointed from `InboxFeedView` (situations Dashboard) to a new `ActionStripView` that unions `agent_actions` (all surfaces, non-terminal) + due `reminders`, reusing `AgentActionCardView`. Situations `compose`+`situation_card` stages early-return behind `inbox.situations.enabled` (default false); triage/detectors/`inbox_items` keep running for Catch-Up/Memory. Settings → Slack gains a dictionary editor.

**Tech Stack:** Go 1.25 (`database/sql`, `modernc.org/sqlite`, cobra, goose migrations), SwiftUI + GRDB (macOS 14+), the agent-actions registry (`internal/tools/`), reaction pipeline (`internal/reactioncmd/`).

**Spec:** `docs/superpowers/specs/2026-09-06-reaction-commands-wave2-inbox-action-strip-design.md`

## Global Constraints

- Repo work happens in the worktree `.claude/worktrees/reaction-commands-wave2` on branch `feature/reaction-commands-wave2` (off `feature/agent-actions`). Do NOT branch off `main` — Wave 1 + the registry live only in `feature/agent-actions`.
- Repo content is English only (code, comments, commits, docs). Chat may be Russian; the repo never is.
- Inner-loop tests only: `go test ./internal/<pkg>`; Swift `make test-swift FILTER=<Class>` (prefer `Tests/Core` for Models/Queries — no ML link). Never `-count=1`. Never delete `WatchtowerDesktop/.build`.
- New tables: mirror into `internal/db/schema.sql`, add to `TestAllTablesExist`, regenerate golden (`go test ./internal/db/ -run TestSchemaGolden -update`).
- Migration numbers are sequential; next free is **00064** (re-number if the base branch lands one first).
- Trust seeds use `INSERT OR IGNORE` so an owner's prior choice is never overwritten. `create_jira_issue` is `External` → always `ask` regardless of any seed (AGENT-03).
- `inbox.situations.enabled` default **false** (SIT-A resolved: mute now). Un-acted chat proposals DO appear in the strip (STRIP-A resolved: yes). Bare `:later:` → next morning ~09:00 local (owner call 3 resolved).
- Contracts are load-bearing: read `docs/inventory/agent-actions.md` (AGENT-01..06), `docs/inventory/inbox-pulse.md`, `docs/inventory/dashboard.md` before touching those modules. New numbers only for new principles.

---

### Task 1: Migration 00064 — `reminders` table + dictionary/trust seeds

**Files:**
- Create: `internal/db/migrations/00064_reminders.sql`
- Modify: `internal/db/schema.sql` (mirror the new table + seeds near the reaction tables, ~line 1603)
- Modify: `internal/db/db_test.go:171-189` (add `"reminders"` to `expectedTables`)
- Modify: `internal/db/testdata/schema_v73.golden` (regenerated, not hand-edited)

**Interfaces:**
- Produces: table `reminders(id, account_id, message_ref, note, remind_at, status, created_at, done_at)`; dictionary rows for `:track:`/`:idea:`/`:later:`/`:brief:`; `tool_trust` rows for the four new tools.

- [ ] **Step 1: Write the migration**

```sql
-- +goose Up
-- Reminders: the owner's ":later:" reaction (remind_me tool) parks a message to
-- resurface in the inbox action strip at remind_at. A reminder is inert until
-- due; "due" is derived at read time (status='pending' AND remind_at <= now),
-- so no daemon phase flips it. Read-only Slack: nothing is posted back (REMIND-02).
CREATE TABLE IF NOT EXISTS reminders (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id  INTEGER NOT NULL DEFAULT 0,
    message_ref TEXT    NOT NULL DEFAULT '',   -- "<channel_id>@<message_ts>" from the reaction binding
    note        TEXT    NOT NULL DEFAULT '',
    remind_at   TEXT    NOT NULL,
    status      TEXT    NOT NULL DEFAULT 'pending'
                CHECK(status IN ('pending','done','dismissed')),
    created_at  TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    done_at     TEXT    NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_reminders_due ON reminders(status, remind_at);

-- Wave 2 dictionary breadth (feature still ships OFF; owner edits later).
INSERT OR IGNORE INTO reaction_command_map (emoji, kind, tool) VALUES
    ('eyes',             'builtin_tool', 'create_track'),
    ('bulb',             'builtin_tool', 'create_idea'),
    ('alarm_clock',      'builtin_tool', 'remind_me'),
    ('pushpin',          'builtin_tool', 'brief_context');

-- Default trust per the design §7 table. INSERT OR IGNORE: never overwrite an
-- owner's prior choice. create_jira_issue stays External-forced-ask elsewhere.
INSERT OR IGNORE INTO tool_trust (tool, trust) VALUES
    ('create_track',   'ask'),
    ('create_idea',    'execute'),
    ('remind_me',      'execute'),
    ('brief_context',  'execute');

-- +goose Down
DROP INDEX IF EXISTS idx_reminders_due;
DROP TABLE IF EXISTS reminders;
DELETE FROM reaction_command_map WHERE emoji IN ('eyes','bulb','alarm_clock','pushpin');
DELETE FROM tool_trust WHERE tool IN ('create_track','create_idea','remind_me','brief_context');
```

- [ ] **Step 2: Mirror into `schema.sql`** — copy the `CREATE TABLE reminders` + index block next to the reaction tables (~line 1603). Do NOT copy the seed `INSERT`s (schema.sql is structure only).

- [ ] **Step 3: Add `"reminders"` to `expectedTables`** in `internal/db/db_test.go` (alphabetical-ish, next to the reaction entries at line 188).

- [ ] **Step 4: Run the table-existence test — expect PASS once the migration applies**

Run: `go test ./internal/db/ -run TestAllTablesExist -v > /tmp/t1.log 2>&1; echo "exit=$?"`
Expected: `exit=0`, PASS (migration auto-applies on `db.Open`).

- [ ] **Step 5: Regenerate the golden snapshot**

Run: `go test ./internal/db/ -run TestSchemaGolden -update > /tmp/t1g.log 2>&1; echo "exit=$?"` then `go test ./internal/db/ -run TestSchemaGolden; echo "exit=$?"`
Expected: both `exit=0`. Inspect `git diff internal/db/testdata/schema_v73.golden` shows only the `reminders` table added.

- [ ] **Step 6: Commit**

```bash
git add internal/db/migrations/00064_reminders.sql internal/db/schema.sql internal/db/db_test.go internal/db/testdata/schema_v73.golden
git commit -m "feat(reactions): migration 00064 — reminders table + wave 2 dictionary/trust seeds"
```

---

### Task 2: `reminders` DB CRUD

**Files:**
- Create: `internal/db/reminders.go`
- Test: `internal/db/reminders_test.go`

**Interfaces:**
- Consumes: `*DB` (Task 1's table).
- Produces:
  - `type Reminder struct { ID int64; AccountID int64; MessageRef string; Note string; RemindAt string; Status string; CreatedAt string; DoneAt string }`
  - `func (db *DB) InsertReminder(r Reminder) (int64, error)`
  - `func (db *DB) ListDueReminders(nowUTC string) ([]Reminder, error)` — `status='pending' AND remind_at <= ?`, `ORDER BY remind_at ASC`
  - `func (db *DB) MarkReminderDone(id int64) error`
  - `func (db *DB) SnoozeReminder(id int64, until string) error` — bumps `remind_at`, keeps `status='pending'`

- [ ] **Step 1: Write the failing test** (`internal/db/reminders_test.go`) — mirror `internal/db/reaction_commands_test.go`'s `openTestDB` helper:

```go
func TestReminders_InsertListDueSnoozeDone(t *testing.T) {
	d := openTestDB(t)
	past := "2000-01-01T00:00:00Z"
	future := "2999-01-01T00:00:00Z"
	id, err := d.InsertReminder(Reminder{MessageRef: "C1@123.45", Note: "ping the vendor", RemindAt: past})
	if err != nil || id == 0 {
		t.Fatalf("insert: id=%d err=%v", id, err)
	}
	if _, err := d.InsertReminder(Reminder{MessageRef: "C2@9.9", Note: "later one", RemindAt: future}); err != nil {
		t.Fatalf("insert2: %v", err)
	}
	due, err := d.ListDueReminders("2100-01-01T00:00:00Z")
	if err != nil {
		t.Fatalf("list due: %v", err)
	}
	if len(due) != 1 || due[0].ID != id {
		t.Fatalf("want 1 due (the past one), got %d: %+v", len(due), due)
	}
	if err := d.SnoozeReminder(id, future); err != nil {
		t.Fatalf("snooze: %v", err)
	}
	if due, _ := d.ListDueReminders("2100-01-01T00:00:00Z"); len(due) != 0 {
		t.Fatalf("snoozed reminder should not be due, got %d", len(due))
	}
	if err := d.MarkReminderDone(id); err != nil {
		t.Fatalf("done: %v", err)
	}
	if due, _ := d.ListDueReminders("3000-01-01T00:00:00Z"); len(due) != 1 {
		t.Fatalf("only the future non-done one is due now, got %d", len(due))
	}
}
```

(If `openTestDB` is unexported and package-local, reuse it directly — same package `db`.)

- [ ] **Step 2: Run — expect FAIL** (`Reminder` undefined)

Run: `go test ./internal/db/ -run TestReminders_ -v > /tmp/t2.log 2>&1; echo "exit=$?"` → non-zero, "undefined: Reminder".

- [ ] **Step 3: Implement `internal/db/reminders.go`** (mirror `reaction_commands.go` style — methods on `*DB`, wrapped errors, `defer rows.Close()`, `return out, rows.Err()`):

```go
package db

import "fmt"

// Reminder is one parked message the owner asked to resurface (remind_me tool).
type Reminder struct {
	ID         int64
	AccountID  int64
	MessageRef string
	Note       string
	RemindAt   string
	Status     string
	CreatedAt  string
	DoneAt     string
}

func (db *DB) InsertReminder(r Reminder) (int64, error) {
	res, err := db.Exec(`INSERT INTO reminders (account_id, message_ref, note, remind_at)
		VALUES (?, ?, ?, ?)`, r.AccountID, r.MessageRef, r.Note, r.RemindAt)
	if err != nil {
		return 0, fmt.Errorf("inserting reminder: %w", err)
	}
	return res.LastInsertId()
}

func (db *DB) ListDueReminders(nowUTC string) ([]Reminder, error) {
	rows, err := db.Query(`SELECT id, account_id, message_ref, note, remind_at, status, created_at, done_at
		FROM reminders WHERE status = 'pending' AND remind_at <= ? ORDER BY remind_at ASC`, nowUTC)
	if err != nil {
		return nil, fmt.Errorf("listing due reminders: %w", err)
	}
	defer rows.Close()
	var out []Reminder
	for rows.Next() {
		var r Reminder
		if err := rows.Scan(&r.ID, &r.AccountID, &r.MessageRef, &r.Note, &r.RemindAt, &r.Status, &r.CreatedAt, &r.DoneAt); err != nil {
			return nil, fmt.Errorf("scanning reminder: %w", err)
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func (db *DB) MarkReminderDone(id int64) error {
	_, err := db.Exec(`UPDATE reminders SET status='done', done_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id=?`, id)
	if err != nil {
		return fmt.Errorf("marking reminder done: %w", err)
	}
	return nil
}

func (db *DB) SnoozeReminder(id int64, until string) error {
	_, err := db.Exec(`UPDATE reminders SET remind_at=?, status='pending' WHERE id=?`, until, id)
	if err != nil {
		return fmt.Errorf("snoozing reminder: %w", err)
	}
	return nil
}
```

- [ ] **Step 4: Run — expect PASS**

Run: `go test ./internal/db/ -run TestReminders_ -v > /tmp/t2.log 2>&1; echo "exit=$?"` → `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add internal/db/reminders.go internal/db/reminders_test.go
git commit -m "feat(reactions): reminders DB CRUD (insert/list-due/snooze/done)"
```

---

### Task 3: `create_track` tool

**Files:**
- Create: `internal/tools/tracks.go`
- Test: `internal/tools/tracks_test.go`
- Modify: `cmd/actions_registry.go:30-41` (add `tools.NewCreateTrack()` to the register slice)

**Interfaces:**
- Consumes: `db.CreateCustomTrack(t db.Track) (int64, error)` (`internal/db/custom_tracks.go:8` — owner/manual path: `origin='custom'`, `enabled=1`); the `Tool`/`Call` types (`internal/tools/registry.go`).
- Produces: `func NewCreateTrack() *tools.Tool` (Access write, no External, Surfaces unset).

- [ ] **Step 1: Write the failing test** (mirror `internal/tools/targets_test.go`'s Validate/Execute tests):

```go
func TestCreateTrack_ExecuteCreatesCustomTrack(t *testing.T) {
	d := db.OpenTestDB(t) // use whatever helper targets_test.go uses
	tool := NewCreateTrack()
	args := json.RawMessage(`{"text":"Watch the billing migration","context":"rollout risk","reason":"owner asked to track"}`)
	if err := tool.Validate(context.Background(), d, args); err != nil {
		t.Fatalf("validate: %v", err)
	}
	res, err := tool.Execute(context.Background(), d, Call{ActionID: 7, Args: args})
	if err != nil {
		t.Fatalf("execute: %v", err)
	}
	m := res.(map[string]any)
	if m["track_id"] == nil {
		t.Fatalf("expected track_id, got %v", m)
	}
}
```

(Check `targets_test.go` for the exact test-DB helper name and copy it.)

- [ ] **Step 2: Run — expect FAIL** (`NewCreateTrack` undefined).

Run: `go test ./internal/tools/ -run TestCreateTrack_ -v > /tmp/t3.log 2>&1; echo "exit=$?"` → non-zero.

- [ ] **Step 3: Implement `internal/tools/tracks.go`** (mirror `targets.go` — `jsonschema.For[…]`, `decodeStrict`, `AccessWrite`):

```go
package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"github.com/google/jsonschema-go/jsonschema" // match targets.go's import path
	"watchtower/internal/db"
)

type createTrackArgs struct {
	Text    string `json:"text" jsonschema:"the track title / what to watch, at most 200 characters"`
	Context string `json:"context,omitempty" jsonschema:"why it matters / what to watch for"`
	Reason  string `json:"reason" jsonschema:"one sentence: why you propose this, shown to the owner"`
}

// NewCreateTrack builds the create_track tool (a narrative watch-track). Owner
// manual-create path: origin='custom', enabled=1 via db.CreateCustomTrack.
func NewCreateTrack() *Tool {
	schema, _ := jsonschema.For[createTrackArgs](nil)
	return &Tool{
		Name:        "create_track",
		Description: "Create a narrative track to watch a topic over time.",
		InputSchema: schema,
		Access:      AccessWrite,
		Validate: func(ctx context.Context, d *db.DB, args json.RawMessage) error {
			var a createTrackArgs
			if err := decodeStrict(args, &a); err != nil {
				return err
			}
			if strings.TrimSpace(a.Text) == "" {
				return &ValidationError{Msg: "text is required"}
			}
			if len(a.Text) > 200 {
				return &ValidationError{Msg: "text must be at most 200 characters"}
			}
			return nil
		},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a createTrackArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, err
			}
			id, err := d.CreateCustomTrack(db.Track{
				Text:    strings.TrimSpace(a.Text),
				Context: strings.TrimSpace(a.Context),
			})
			if err != nil {
				return nil, fmt.Errorf("creating track: %w", err)
			}
			_ = strconv.Itoa // drop if unused
			return map[string]any{"track_id": id}, nil
		},
	}
}
```

> NOTE for implementer: open `internal/tools/targets.go` and match its EXACT `jsonschema` import path, `decodeStrict` signature, and `ValidationError` construction — copy those verbatim rather than the illustrative forms above. Confirm `db.Track` field names (`Text`, `Context`) against `internal/db/models.go:166` and `CreateCustomTrack`'s expectations.

- [ ] **Step 4: Register in `cmd/actions_registry.go`** — add to the slice in `buildToolRegistry`:

```go
	for _, t := range []*tools.Tool{
		tools.NewCreateTarget(),
		tools.NewCreateJiraIssue(jiraClientFactory(cfg)),
		tools.NewCreateTrack(),   // <-- add
	} {
```

- [ ] **Step 5: Run — expect PASS**, and build the cmd package:

Run: `go test ./internal/tools/ -run TestCreateTrack_ -v > /tmp/t3.log 2>&1; echo "exit=$?"; go build ./cmd/... > /tmp/t3b.log 2>&1; echo "build=$?"`
Expected: both zero.

- [ ] **Step 6: Commit**

```bash
git add internal/tools/tracks.go internal/tools/tracks_test.go cmd/actions_registry.go
git commit -m "feat(reactions): create_track tool + registry wiring"
```

---

### Task 4: `create_idea` tool + `db.CreateManualIdea` helper

**Files:**
- Create: `internal/tools/ideas.go`
- Test: `internal/tools/ideas_test.go`
- Modify: `internal/db/ideas.go` (add a non-Tx owner-create helper)
- Modify: `cmd/actions_registry.go` (register `tools.NewCreateIdea()`)

**Interfaces:**
- Consumes: `db.CreateIdeaTx(tx, Idea) (int64, error)` + `db.InsertIdeaMentionTx(tx, IdeaMention) error` (`internal/db/ideas.go:76,100`); `Idea`/`IdeaMention` structs.
- Produces:
  - `func (db *DB) CreateManualIdea(kind, title, essence string) (int64, error)` — one tx: idea (`Status:"active"`, `Source:"owner"`, `LastMentionAt=now`) + a `source='owner'` mention. Mirrors Swift `IdeaQueries.createManual`.
  - `func NewCreateIdea() *tools.Tool` (Access write).

- [ ] **Step 1: Write the failing test for the DB helper** (`internal/db/ideas_test.go` — append):

```go
func TestCreateManualIdea_ActiveOwner(t *testing.T) {
	d := openTestDB(t)
	id, err := d.CreateManualIdea("idea", "Ship the strip", "inbox as an action queue")
	if err != nil || id == 0 {
		t.Fatalf("create: id=%d err=%v", id, err)
	}
	got, err := d.GetIdea(id) // use the existing getter; adapt name if different
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if got.Status != "active" || got.Source != "owner" {
		t.Fatalf("want active/owner, got %s/%s", got.Status, got.Source)
	}
}
```

- [ ] **Step 2: Run — expect FAIL** (`CreateManualIdea` undefined).

Run: `go test ./internal/db/ -run TestCreateManualIdea_ -v > /tmp/t4.log 2>&1; echo "exit=$?"` → non-zero.

- [ ] **Step 3: Implement `db.CreateManualIdea`** in `internal/db/ideas.go` (wrap the existing Tx helpers):

```go
// CreateManualIdea inserts an owner-authored idea/note (status='active',
// source='owner') plus its owner mention, in one transaction. The Go twin of
// Swift IdeaQueries.createManual.
func (db *DB) CreateManualIdea(kind, title, essence string) (int64, error) {
	now := nowUTC() // use the package's existing timestamp helper; match ideas.go
	tx, err := db.Begin()
	if err != nil {
		return 0, fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback()
	id, err := db.CreateIdeaTx(tx, Idea{
		Kind: kind, Title: title, Essence: essence,
		Status: "active", Source: "owner", LastMentionAt: now,
	})
	if err != nil {
		return 0, err
	}
	if err := db.InsertIdeaMentionTx(tx, IdeaMention{IdeaID: id, Source: "owner", Quote: essence, SaidAt: now}); err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("commit: %w", err)
	}
	return id, nil
}
```

> NOTE: verify `Idea`/`IdeaMention` field names + the timestamp helper against `internal/db/ideas.go:14,100`. `CreateIdeaTx` defaults `Status`/`Source` only when empty, so passing them explicitly wins.

- [ ] **Step 4: Run the DB test — expect PASS**, then write the tool.

Run: `go test ./internal/db/ -run TestCreateManualIdea_ -v > /tmp/t4.log 2>&1; echo "exit=$?"` → zero.

- [ ] **Step 5: Implement `internal/tools/ideas.go`** (mirror `tracks.go`; light-tier is a compose concern, not the tool's):

```go
type createIdeaArgs struct {
	Title   string `json:"title,omitempty" jsonschema:"a short idea title"`
	Essence string `json:"essence" jsonschema:"the idea in one or two sentences"`
	Reason  string `json:"reason" jsonschema:"one sentence for the owner"`
}

func NewCreateIdea() *Tool {
	schema, _ := jsonschema.For[createIdeaArgs](nil)
	return &Tool{
		Name:        "create_idea",
		Description: "Capture an idea in the ideas registry.",
		InputSchema: schema,
		Access:      AccessWrite,
		Validate: func(ctx context.Context, d *db.DB, args json.RawMessage) error {
			var a createIdeaArgs
			if err := decodeStrict(args, &a); err != nil {
				return err
			}
			if strings.TrimSpace(a.Essence) == "" {
				return &ValidationError{Msg: "essence is required"}
			}
			return nil
		},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a createIdeaArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, err
			}
			id, err := d.CreateManualIdea("idea", strings.TrimSpace(a.Title), strings.TrimSpace(a.Essence))
			if err != nil {
				return nil, fmt.Errorf("creating idea: %w", err)
			}
			return map[string]any{"idea_id": id}, nil
		},
	}
}
```

- [ ] **Step 6: Register** `tools.NewCreateIdea()` in `cmd/actions_registry.go`'s slice.

- [ ] **Step 7: Write + run the tool test** (`internal/tools/ideas_test.go`, mirror `TestCreateTrack_ExecuteCreatesCustomTrack`, assert `idea_id` present). Then:

Run: `go test ./internal/tools/ -run TestCreateIdea_ -v > /tmp/t4t.log 2>&1; echo "exit=$?"; go build ./cmd/... > /tmp/t4b.log 2>&1; echo "build=$?"` → both zero.

- [ ] **Step 8: Commit**

```bash
git add internal/tools/ideas.go internal/tools/ideas_test.go internal/db/ideas.go internal/db/ideas_test.go cmd/actions_registry.go
git commit -m "feat(reactions): create_idea tool + db.CreateManualIdea owner path"
```

---

### Task 5: `brief_context` + `remind_me` tools; thread the reaction ref into the binding

**Files:**
- Create: `internal/tools/brief.go`, `internal/tools/remind.go`
- Test: `internal/tools/brief_test.go`, `internal/tools/remind_test.go`
- Modify: `internal/reactioncmd/pipeline.go:167` (set `Binding.ContextID`)
- Modify: `cmd/actions_registry.go` (register both)

**Interfaces:**
- Consumes: `db.InsertReminder(Reminder) (int64, error)` (Task 2); `Call.Binding.ContextID` (the reacted message ref).
- Produces: `func NewBriefContext() *tools.Tool`, `func NewRemindMe() *tools.Tool`.

**Design notes:**
- `brief_context` needs no AI generator — the reaction composer produces the `summary` field (see Task 6's argGuide). Execute just echoes it into the result so the strip card can render it. No side effect beyond its own `agent_actions` row (§5.4).
- `remind_me` reads the message ref from `Call.Binding.ContextID` (REACT-02 provenance, threaded in this task), plus a composer-supplied `remind_at` + `note`.

- [ ] **Step 1: Thread the ref into the reaction binding** — `internal/reactioncmd/pipeline.go`, change the dispatch binding (currently line 167):

```go
	binding := tools.Binding{
		Surface:     "reaction",
		ContextType: "reaction",
		ContextID:   c.ChannelID + "@" + c.MessageTS, // REACT-02: real message ref for reminders/brief
	}
```

- [ ] **Step 2: Write the failing tests**

`internal/tools/remind_test.go`:

```go
func TestRemindMe_ExecuteInsertsReminderWithRef(t *testing.T) {
	d := db.OpenTestDB(t)
	tool := NewRemindMe()
	args := json.RawMessage(`{"remind_at":"2999-01-01T09:00:00Z","note":"follow up","reason":"owner asked"}`)
	if err := tool.Validate(context.Background(), d, args); err != nil {
		t.Fatalf("validate: %v", err)
	}
	res, err := tool.Execute(context.Background(), d, Call{ActionID: 3, Args: args,
		Binding: Binding{Surface: "reaction", ContextType: "reaction", ContextID: "C9@123.45"}})
	if err != nil {
		t.Fatalf("execute: %v", err)
	}
	if res.(map[string]any)["reminder_id"] == nil {
		t.Fatalf("expected reminder_id, got %v", res)
	}
	due, _ := d.ListDueReminders("3000-01-01T00:00:00Z")
	if len(due) != 1 || due[0].MessageRef != "C9@123.45" {
		t.Fatalf("reminder should carry the reacted ref, got %+v", due)
	}
}
```

`internal/tools/brief_test.go`:

```go
func TestBriefContext_ExecuteEchoesSummary(t *testing.T) {
	d := db.OpenTestDB(t)
	tool := NewBriefContext()
	args := json.RawMessage(`{"summary":"Vendor wants a call Friday.","reason":"owner asked for a brief"}`)
	if err := tool.Validate(context.Background(), d, args); err != nil {
		t.Fatalf("validate: %v", err)
	}
	res, err := tool.Execute(context.Background(), d, Call{ActionID: 1, Args: args})
	if err != nil {
		t.Fatalf("execute: %v", err)
	}
	if res.(map[string]any)["summary"] != "Vendor wants a call Friday." {
		t.Fatalf("summary not echoed: %v", res)
	}
}
```

- [ ] **Step 3: Run — expect FAIL** (undefined constructors).

Run: `go test ./internal/tools/ -run 'TestRemindMe_|TestBriefContext_' -v > /tmp/t5.log 2>&1; echo "exit=$?"` → non-zero.

- [ ] **Step 4: Implement `internal/tools/remind.go`**:

```go
type remindMeArgs struct {
	RemindAt string `json:"remind_at" jsonschema:"ISO-8601 UTC time to resurface this, e.g. 2026-09-07T09:00:00Z"`
	Note     string `json:"note,omitempty" jsonschema:"a short note about what to follow up on"`
	Reason   string `json:"reason" jsonschema:"one sentence for the owner"`
}

func NewRemindMe() *Tool {
	schema, _ := jsonschema.For[remindMeArgs](nil)
	return &Tool{
		Name:        "remind_me",
		Description: "Park a message to resurface in the inbox at a chosen time.",
		InputSchema: schema,
		Access:      AccessWrite,
		Validate: func(ctx context.Context, d *db.DB, args json.RawMessage) error {
			var a remindMeArgs
			if err := decodeStrict(args, &a); err != nil {
				return err
			}
			if strings.TrimSpace(a.RemindAt) == "" {
				return &ValidationError{Msg: "remind_at is required"}
			}
			return nil
		},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a remindMeArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, err
			}
			id, err := d.InsertReminder(db.Reminder{
				MessageRef: call.Binding.ContextID,
				Note:       strings.TrimSpace(a.Note),
				RemindAt:   strings.TrimSpace(a.RemindAt),
			})
			if err != nil {
				return nil, fmt.Errorf("creating reminder: %w", err)
			}
			return map[string]any{"reminder_id": id}, nil
		},
	}
}
```

- [ ] **Step 5: Implement `internal/tools/brief.go`**:

```go
type briefContextArgs struct {
	Summary string `json:"summary" jsonschema:"a concise summary of the message and its thread"`
	Reason  string `json:"reason" jsonschema:"one sentence for the owner"`
}

func NewBriefContext() *Tool {
	schema, _ := jsonschema.For[briefContextArgs](nil)
	return &Tool{
		Name:        "brief_context",
		Description: "Summarise the reacted message and its thread into a card (no side effects).",
		InputSchema: schema,
		Access:      AccessWrite, // registry write tool (records an action row); no external effect
		Validate: func(ctx context.Context, d *db.DB, args json.RawMessage) error {
			var a briefContextArgs
			if err := decodeStrict(args, &a); err != nil {
				return err
			}
			if strings.TrimSpace(a.Summary) == "" {
				return &ValidationError{Msg: "summary is required"}
			}
			return nil
		},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a briefContextArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, err
			}
			return map[string]any{"summary": a.Summary}, nil
		},
	}
}
```

- [ ] **Step 6: Register both** in `cmd/actions_registry.go`'s slice (`tools.NewRemindMe()`, `tools.NewBriefContext()`).

- [ ] **Step 7: Run — expect PASS** + build cmd + build reactioncmd:

Run: `go test ./internal/tools/ -run 'TestRemindMe_|TestBriefContext_' -v > /tmp/t5.log 2>&1; echo "tools=$?"; go build ./cmd/... ./internal/reactioncmd/... > /tmp/t5b.log 2>&1; echo "build=$?"` → both zero.

- [ ] **Step 8: Commit**

```bash
git add internal/tools/brief.go internal/tools/remind.go internal/tools/brief_test.go internal/tools/remind_test.go internal/reactioncmd/pipeline.go cmd/actions_registry.go
git commit -m "feat(reactions): remind_me + brief_context tools; thread reacted ref into binding"
```

---

### Task 6: reactioncmd `argGuide` branches for the four new tools

**Files:**
- Modify: `internal/reactioncmd/prompt.go:11-29` (add four `case` branches)
- Test: `internal/reactioncmd/prompt_test.go` (append)

**Interfaces:**
- Consumes: the composer's `argGuide(tool string) string`.
- Produces: tool-specific arg guidance so a reaction composes valid args (esp. `remind_me`'s `remind_at` and `brief_context`'s `summary`).

- [ ] **Step 1: Write the failing test**:

```go
func TestArgGuide_Wave2Tools(t *testing.T) {
	for _, tool := range []string{"create_track", "create_idea", "remind_me", "brief_context"} {
		g := argGuide(tool)
		if g == "" || g == argGuide("some_unknown_tool") {
			t.Fatalf("%s should have a specific guide, got default/empty", tool)
		}
	}
	if !strings.Contains(argGuide("remind_me"), "remind_at") {
		t.Fatal("remind_me guide must mention remind_at")
	}
	if !strings.Contains(argGuide("brief_context"), "summary") {
		t.Fatal("brief_context guide must mention summary")
	}
}
```

- [ ] **Step 2: Run — expect FAIL**.

Run: `go test ./internal/reactioncmd/ -run TestArgGuide_Wave2Tools -v > /tmp/t6.log 2>&1; echo "exit=$?"` → non-zero.

- [ ] **Step 3: Add the branches** inside `argGuide`'s switch (before `default:`):

```go
	case "create_track":
		return `Arguments:
- "text" (required): what to watch, at most 200 characters.
- "context" (optional): why it matters / what to watch for.
- "reason" (required): one sentence for the owner.`
	case "create_idea":
		return `Arguments:
- "title" (optional): a short idea title.
- "essence" (required): the idea in one or two sentences.
- "reason" (required): one sentence for the owner.`
	case "remind_me":
		return `Arguments:
- "remind_at" (required): ISO-8601 UTC time to resurface this. If the message implies no explicit time, use tomorrow at 09:00 local converted to UTC.
- "note" (optional): a short note on what to follow up on.
- "reason" (required): one sentence for the owner.`
	case "brief_context":
		return `Arguments:
- "summary" (required): a concise summary of the message and any thread context you were given.
- "reason" (required): one sentence for the owner.`
```

- [ ] **Step 4: Run — expect PASS**.

Run: `go test ./internal/reactioncmd/ -run TestArgGuide_Wave2Tools -v > /tmp/t6.log 2>&1; echo "exit=$?"` → zero.

- [ ] **Step 5: Commit**

```bash
git add internal/reactioncmd/prompt.go internal/reactioncmd/prompt_test.go
git commit -m "feat(reactions): argGuide branches for wave 2 tools"
```

---

### Task 7: Mute situations behind `inbox.situations.enabled`

**Files:**
- Modify: `internal/config/config.go` (add `InboxSituationsConfig` + field + `SetDefault`)
- Modify: `internal/config/defaults.go` (add `DefaultInboxSituationsEnabled = false`)
- Modify: `internal/inbox/pipeline.go:427-438` (gate `runComposePhase` + `runSituationCards`)
- Modify: `internal/features/registry.go` (add a `SubToggle` on `secretary-inbox` for the new key)
- Test: `internal/inbox/pipeline_test.go` (a gate test) + `internal/config` default test if the package has one

**Interfaces:**
- Consumes: `cfg.Inbox.Situations.Enabled`.
- Produces: when false, compose + situation cards are skipped (zero AI); triage/detectors/`inbox_items` untouched.

- [ ] **Step 1: Add the config type + wiring** in `internal/config/config.go`:

```go
// InboxSituationsConfig gates the situations compose + situation-card stages
// (the expensive AI clustering) independently of the rest of the inbox.
type InboxSituationsConfig struct {
	Enabled bool `mapstructure:"enabled"`
}
```

Add to `InboxConfig`: `Situations InboxSituationsConfig \`mapstructure:"situations"\``. Add default: `v.SetDefault("inbox.situations.enabled", DefaultInboxSituationsEnabled)` in the `inbox.*` group (~line 441).

- [ ] **Step 2: Add the constant** in `internal/config/defaults.go` inbox group: `DefaultInboxSituationsEnabled = false`.

- [ ] **Step 3: Write the failing gate test** in `internal/inbox/pipeline_test.go` — use a fake/counting generator (mirror an existing inbox test's generator double) and assert that with the gate off, `runComposePhase` performs no AI call. If the suite has no such double, assert the narrower behavior: `runComposePhase` returns `(0,0)` immediately when gated. Skeleton (adapt to the package's existing test harness):

```go
func TestInbox_SituationsGateOff_SkipsCompose(t *testing.T) {
	p := newTestPipeline(t) // existing helper
	p.cfg.Inbox.Situations.Enabled = false
	created, merged := p.runComposePhase(context.Background(), "U1")
	if created != 0 || merged != 0 {
		t.Fatalf("gated compose must be a no-op, got %d/%d", created, merged)
	}
	// and situation cards:
	cards, err := p.runSituationCards(context.Background(), "U1")
	if err != nil || cards != 0 {
		t.Fatalf("gated cards must be a no-op, got %d err=%v", cards, err)
	}
}
```

- [ ] **Step 4: Run — expect FAIL** (gate not yet added; compose may try to run).

Run: `go test ./internal/inbox/ -run TestInbox_SituationsGateOff -v > /tmp/t7.log 2>&1; echo "exit=$?"`.

- [ ] **Step 5: Add the gate** at the top of `runComposePhase` and `runSituationCards` in `internal/inbox/pipeline.go`:

```go
func (p *Pipeline) runComposePhase(ctx context.Context, currentUserID string) (int, int) {
	if p.cfg == nil || !p.cfg.Inbox.Situations.Enabled {
		return 0, 0
	}
	// ...existing body...
}

func (p *Pipeline) runSituationCards(ctx context.Context, currentUserID string) (int, error) {
	if p.cfg == nil || !p.cfg.Inbox.Situations.Enabled {
		return 0, nil
	}
	// ...existing body...
}
```

This keeps the call sites at pipeline.go:436-437 unchanged (they already tolerate zero returns; the summary log at 454-456 stays correct). Triage/detectors/auto-resolve/unsnooze are untouched → Catch-Up's `ListCatchupInbox` and Memory keep their inputs.

- [ ] **Step 6: Surface the key in the Feature Manager** — add to the `secretary-inbox` entry in `internal/features/registry.go`:

```go
		SubToggles: []SubToggle{{
			Key:         "inbox.situations.enabled",
			Title:       "Cluster into situations",
			Description: "Run the AI that groups inbox activity into Dashboard situations. Off = the inbox shows the action strip only.",
		}},
```

- [ ] **Step 7: Run — expect PASS** + build:

Run: `go test ./internal/inbox/ -run TestInbox_SituationsGateOff -v > /tmp/t7.log 2>&1; echo "inbox=$?"; go build ./... > /tmp/t7b.log 2>&1; echo "build=$?"; go test ./internal/config/ ./internal/features/ > /tmp/t7c.log 2>&1; echo "cfgfeat=$?"` → all zero.

- [ ] **Step 8: Commit**

```bash
git add internal/config/config.go internal/config/defaults.go internal/inbox/pipeline.go internal/features/registry.go internal/inbox/pipeline_test.go
git commit -m "feat(inbox): mute situations behind inbox.situations.enabled (default off)"
```

---

### Task 8: Desktop — `ReminderQueries` + `AgentActionQueries.fetchStrip` (Core, no ML link)

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Models/Reminder.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ReminderQueries.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/AgentActionQueries.swift` (add `fetchStrip`)
- Test: `WatchtowerDesktop/Tests/Core/ReminderQueriesTests.swift`, extend `WatchtowerDesktop/Tests/Core/AgentActionQueriesTests.swift`

**Interfaces:**
- Produces:
  - `package struct Reminder: FetchableRecord, Identifiable, Sendable { id, accountID, messageRef, note, remindAt, status, createdAt, doneAt }` + `init(row:)`.
  - `ReminderQueries.fetchDue(_ db: Database, nowUTC: String) throws -> [Reminder]`
  - `AgentActionQueries.fetchStrip(_ db: Database) throws -> [AgentAction]` — non-conversation-scoped: `WHERE status IN ('pending','approved','failed','executing') ORDER BY created_at DESC, id DESC` (STRIP-A: all surfaces, not just reaction).

- [ ] **Step 1: Write the failing tests** (`Tests/Core/ReminderQueriesTests.swift`, mirror `AgentActionQueriesTests`'s in-memory GRDB setup):

```swift
import XCTest
import GRDB
@testable import WatchtowerCore

final class ReminderQueriesTests: XCTestCase {
    func testFetchDueReturnsOnlyPendingPast() throws {
        let dbq = try makeInMemoryDB() // reuse the Core test helper that runs schema.sql
        try dbq.write { db in
            try db.execute(sql: "INSERT INTO reminders (message_ref, note, remind_at, status) VALUES ('C1@1','a','2000-01-01T00:00:00Z','pending')")
            try db.execute(sql: "INSERT INTO reminders (message_ref, note, remind_at, status) VALUES ('C2@2','b','2999-01-01T00:00:00Z','pending')")
            try db.execute(sql: "INSERT INTO reminders (message_ref, note, remind_at, status) VALUES ('C3@3','c','2000-01-01T00:00:00Z','done')")
        }
        let due = try dbq.read { try ReminderQueries.fetchDue($0, nowUTC: "2100-01-01T00:00:00Z") }
        XCTAssertEqual(due.map(\.messageRef), ["C1@1"])
    }
}
```

Extend `AgentActionQueriesTests` with `testFetchStripReturnsNonTerminalAcrossConversations` (insert rows with different `conversation_id` + statuses; assert only non-terminal returned, ordered newest-first).

- [ ] **Step 2: Run — expect FAIL**.

Run: `make test-swift FILTER=ReminderQueriesTests > /tmp/t8.log 2>&1; echo "exit=$?"` (check the log tail for real XCTest result per the honest-exit rule).

- [ ] **Step 3: Implement `Reminder.swift`** (mirror `AgentAction.swift`'s `init(row:)` snake_case mapping) and `ReminderQueries.swift`:

```swift
package enum ReminderQueries {
    package static func fetchDue(_ db: Database, nowUTC: String) throws -> [Reminder] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, account_id, message_ref, note, remind_at, status, created_at, done_at
            FROM reminders WHERE status = 'pending' AND remind_at <= ? ORDER BY remind_at ASC
            """, arguments: [nowUTC])
        return rows.map(Reminder.init(row:))
    }
}
```

Add `fetchStrip` to `AgentActionQueries.swift`:

```swift
    package static func fetchStrip(_ db: Database) throws -> [AgentAction] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM agent_actions
            WHERE status IN ('pending','approved','failed','executing')
            ORDER BY created_at DESC, id DESC
            """)
        return rows.map(AgentAction.init(row:))
    }
```

- [ ] **Step 4: Run — expect PASS**.

Run: `make test-swift FILTER=ReminderQueriesTests > /tmp/t8.log 2>&1; echo "r=$?"; make test-swift FILTER=AgentActionQueriesTests > /tmp/t8b.log 2>&1; echo "a=$?"` → verify PASS in both logs (not just exit code — honest-exit rule).

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/WatchtowerCore/Models/Reminder.swift WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ReminderQueries.swift WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/AgentActionQueries.swift WatchtowerDesktop/Tests/Core/ReminderQueriesTests.swift WatchtowerDesktop/Tests/Core/AgentActionQueriesTests.swift
git commit -m "feat(desktop): ReminderQueries + AgentActionQueries.fetchStrip (Core)"
```

---

### Task 9: Desktop — `ActionStripViewModel` on AppState

**Files:**
- Create: `WatchtowerDesktop/Sources/ViewModels/ActionStripViewModel.swift`
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift` (own it as `private(set) var actionStripViewModel` + `initActionStrip(dbPool:)`, wired where sibling VMs are inited)
- Test: `WatchtowerDesktop/Tests/Core/ActionStripViewModelTests.swift` if the VM can live in Core; otherwise `Tests/ActionStripViewModelTests.swift`

**Interfaces:**
- Consumes: `AgentActionQueries.fetchStrip`, `ReminderQueries.fetchDue`, `AgentActionFeed` (for approve/reject/retry mutation — reuse its CLI-backed mutators), a `CLIRunnerProtocol` for reminder done/snooze.
- Produces: `@MainActor @Observable final class ActionStripViewModel` exposing `actionRows: [AgentAction]`, `reminderRows: [Reminder]`, `refresh()`, `approve/reject/retry(id:)`, `markReminderDone(id:)`, `snoozeReminder(id:until:)`.

**Design:** follow the `SlackAccountsViewModel` house pattern (AppState-owned, `refresh()` on appear / after CLI calls, not live GRDB observation — cross-process daemon writes don't fire `ValueObservation`). Reuse `AgentActionFeed`'s existing `approve/reject/retry` CLI plumbing rather than re-implementing (compose it, or call its mutators). Reminder done/snooze can write GRDB directly (Swift-owned, no daemon contention) — the feedback dual-path precedent — via a small `ReminderQueries.markDone`/`snooze` mutator pair (add them alongside `fetchDue`).

- [ ] **Step 1: Add reminder mutators to `ReminderQueries`** (Task 8's file) + a Core test:

```swift
    package static func markDone(_ db: Database, id: Int64) throws {
        try db.execute(sql: "UPDATE reminders SET status='done', done_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id=?", arguments: [id])
    }
    package static func snooze(_ db: Database, id: Int64, until: String) throws {
        try db.execute(sql: "UPDATE reminders SET remind_at=?, status='pending' WHERE id=?", arguments: [until, id])
    }
```

Test `testMarkDoneRemovesFromDue` + `testSnoozeBumpsRemindAt` in `ReminderQueriesTests`. Run FAIL→implement→PASS.

- [ ] **Step 2: Write the failing VM test** — assert `refresh()` populates `actionRows` + `reminderRows` from a seeded pool, and `markReminderDone` drops the reminder on next refresh. Use an in-memory `DatabasePool` + a stub `CLIRunnerProtocol` (mirror `AgentActionFeedTests`'s stubs).

- [ ] **Step 3: Run — expect FAIL**.

Run: `make test-swift FILTER=ActionStripViewModelTests > /tmp/t9.log 2>&1; echo "exit=$?"`.

- [ ] **Step 4: Implement the VM** (mirror `SlackAccountsViewModel` header + `AgentActionFeed` mutator usage). Key body:

```swift
@MainActor
@Observable
final class ActionStripViewModel {
    private(set) var actionRows: [AgentAction] = []
    private(set) var reminderRows: [Reminder] = []
    var lastError: String?

    private let dbPool: DatabasePool
    let actionFeed: AgentActionFeed  // reuse its approve/reject/retry CLI plumbing

    init(dbPool: DatabasePool, cliRunner: CLIRunnerProtocol? = nil) {
        self.dbPool = dbPool
        self.actionFeed = AgentActionFeed(dbPool: dbPool, cliRunner: cliRunner)
    }

    func refresh() {
        do {
            let now = ISO8601UTC.now() // use the app's existing UTC formatter
            (actionRows, reminderRows) = try dbPool.read { db in
                (try AgentActionQueries.fetchStrip(db), try ReminderQueries.fetchDue(db, nowUTC: now))
            }
        } catch { lastError = String(describing: error) }
    }

    func markReminderDone(_ id: Int64) {
        do { try dbPool.write { try ReminderQueries.markDone($0, id: id) }; refresh() }
        catch { lastError = String(describing: error) }
    }
    func snoozeReminder(_ id: Int64, until: String) {
        do { try dbPool.write { try ReminderQueries.snooze($0, id: id, until: until) }; refresh() }
        catch { lastError = String(describing: error) }
    }
    func approve(_ id: Int64) async { await actionFeed.approve(id); refresh() }
    func reject(_ id: Int64) async { await actionFeed.reject(id); refresh() }
    func retry(_ id: Int64) async { await actionFeed.retry(id); refresh() }
}
```

> NOTE: `AgentActionFeed.approve/reject/retry` already `refresh()` their own `rows`; the extra `refresh()` here re-reads the strip union. Confirm `ISO8601UTC`/timestamp helper name in the codebase; reuse it, don't invent one.

- [ ] **Step 5: Own it on AppState** — add `private(set) var actionStripViewModel: ActionStripViewModel?` and `func initActionStrip(dbPool:)` (mirror `initSlackAccounts`), called from the same bootstrap site the sibling VMs use.

- [ ] **Step 6: Run — expect PASS** + build the app target:

Run: `make test-swift FILTER=ActionStripViewModelTests > /tmp/t9.log 2>&1; echo "vm=$?"` (verify PASS in log). Build check happens in Task 11.

- [ ] **Step 7: Commit**

```bash
git add WatchtowerDesktop/Sources/ViewModels/ActionStripViewModel.swift WatchtowerDesktop/Sources/App/AppState.swift WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ReminderQueries.swift WatchtowerDesktop/Tests/Core/ReminderQueriesTests.swift WatchtowerDesktop/Tests/Core/ActionStripViewModelTests.swift
git commit -m "feat(desktop): ActionStripViewModel on AppState (actions + due reminders)"
```

---

### Task 10: Desktop — `ActionStripView` + repoint the Inbox tab

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Inbox/ActionStripView.swift`
- Modify: `WatchtowerDesktop/Sources/App/Navigation.swift:203-204` (`.inbox` → `ActionStripView()`)

**Interfaces:**
- Consumes: `appState.actionStripViewModel`, `AgentActionCardView`, `Reminder`.
- Produces: the Inbox tab's new content.

- [ ] **Step 1: Implement `ActionStripView`** — a flat `List`/`ScrollView` reading `appState.actionStripViewModel`, `.task { vm.refresh() }` on appear. Each `AgentAction` renders via `AgentActionCardView(action:inFlight:onApprove:onReject:onRetry:)` wired to `vm.approve/reject/retry`. Each due `Reminder` renders a small card (note + message-ref link + Done / Snooze 1h buttons calling `vm.markReminderDone` / `vm.snoozeReminder`). Empty state when both lists empty: "Nothing waiting on you." Match an existing master/list view's styling (e.g. `IdeasView`).

```swift
struct ActionStripView: View {
    @Environment(AppState.self) private var appState
    var body: some View {
        Group {
            if let vm = appState.actionStripViewModel {
                if vm.actionRows.isEmpty && vm.reminderRows.isEmpty {
                    ContentUnavailableView("Nothing waiting on you", systemImage: "tray")
                } else {
                    List {
                        if !vm.reminderRows.isEmpty {
                            Section("Reminders") {
                                ForEach(vm.reminderRows) { r in ReminderRow(reminder: r, vm: vm) }
                            }
                        }
                        if !vm.actionRows.isEmpty {
                            Section("Proposals") {
                                ForEach(vm.actionRows) { a in
                                    AgentActionCardView(
                                        action: a,
                                        inFlight: vm.actionFeed.inFlight.contains(a.id),
                                        onApprove: { Task { await vm.approve(a.id) } },
                                        onReject: { Task { await vm.reject(a.id) } },
                                        onRetry: { Task { await vm.retry(a.id) } })
                                }
                            }
                        }
                    }
                }
            } else { ProgressView() }
        }
        .task { appState.actionStripViewModel?.refresh() }
        .navigationTitle("Inbox")
    }
}
```

(Add a small `ReminderRow` subview in the same file. `Snooze` computes `until` = now + 1h in UTC using the app's formatter.)

- [ ] **Step 2: Repoint the Inbox tab** — `Navigation.swift` line 204: change `InboxFeedView()` to `ActionStripView()`. Leave `InboxFeedView` and the situations Dashboard code in place (not deleted — the demolition follow-up removes them).

- [ ] **Step 3: Build the whole app target** (first full Swift compile of the new surface):

Run: `cd WatchtowerDesktop && swift build 2>&1 | tail -20; echo "build=$?"`
Expected: `build=0`. (This links ML; expect a slower compile. Do not delete `.build`.)

- [ ] **Step 4: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Inbox/ActionStripView.swift WatchtowerDesktop/Sources/App/Navigation.swift
git commit -m "feat(desktop): Inbox tab renders the action strip (repoint from situations Dashboard)"
```

---

### Task 11: Desktop — reaction dictionary editor in Settings → Slack

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ReactionDictionaryQueries.swift` + `Models/ReactionCommandMapping.swift`
- Create: `WatchtowerDesktop/Sources/ViewModels/ReactionDictionaryViewModel.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Settings/SlackConnectionDetail.swift` (add `reactionDictionarySection` to the `Form`)
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift` (own the VM, mirror `initSlackAccounts`)
- Test: `WatchtowerDesktop/Tests/Core/ReactionDictionaryQueriesTests.swift`

**Interfaces:**
- Produces:
  - `ReactionCommandMapping` model (`emoji, kind, tool, enabled`) + `init(row:)`.
  - `ReactionDictionaryQueries.fetchAll(_:)`, `.setEnabled(_:emoji:enabled:)`, `.upsert(_:emoji:tool:)`, `.delete(_:emoji:)` (direct GRDB writes on `reaction_command_map` — small owner-edited table, Swift-owned, the feedback dual-path precedent).
  - `ReactionDictionaryViewModel` (AppState-owned, `refresh()` after edits) exposing `mappings: [ReactionCommandMapping]` + `trustFor(tool:)` read from `tool_trust`.

- [ ] **Step 1: Write the failing Queries test** (`Tests/Core/ReactionDictionaryQueriesTests.swift`): seed `reaction_command_map`, assert `fetchAll` returns the seeded rows, `setEnabled` flips `enabled`, `delete` removes a row. Run FAIL.

Run: `make test-swift FILTER=ReactionDictionaryQueriesTests > /tmp/t11.log 2>&1; echo "exit=$?"`.

- [ ] **Step 2: Implement the model + Queries** (mirror `SlackAccountQueries` / `AgentActionQueries` shape). Run PASS.

- [ ] **Step 3: Implement the VM** (mirror `SlackAccountsViewModel`), own it on AppState (`initReactionDictionary(dbPool:)`).

- [ ] **Step 4: Add `reactionDictionarySection`** to `SlackConnectionDetail.swift`'s `Form` (after `slackAccountsSection`): a `Section("Reaction commands")` listing each mapping as a row — emoji short-name, mapped tool, an enable `Toggle`, the tool's trust as a caption (`vm.trustFor(tool:)`), a delete affordance, and an "Add mapping" control (emoji short-name + tool picker over the four registered tools). All edits call the VM, which writes GRDB + `refresh()`.

- [ ] **Step 5: Build the app target**:

Run: `cd WatchtowerDesktop && swift build 2>&1 | tail -20; echo "build=$?"` → zero.

- [ ] **Step 6: Commit**

```bash
git add WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ReactionDictionaryQueries.swift WatchtowerDesktop/Sources/WatchtowerCore/Models/ReactionCommandMapping.swift WatchtowerDesktop/Sources/ViewModels/ReactionDictionaryViewModel.swift WatchtowerDesktop/Sources/Views/Settings/SlackConnectionDetail.swift WatchtowerDesktop/Sources/App/AppState.swift WatchtowerDesktop/Tests/Core/ReactionDictionaryQueriesTests.swift
git commit -m "feat(desktop): reaction dictionary editor in Settings → Slack"
```

---

### Task 12: Inventory contracts + changelog + app guide

**Files:**
- Create: `docs/inventory/reaction-commands.md` additions OR extend the existing reaction inventory — add STRIP-01..03, REMIND-01..02 (check `docs/inventory/README.md` for the right file; reaction commands may already have an entry from Wave 1).
- Modify: `CLAUDE.md` (append a Wave 2 changelog entry to the Agent Actions / Reaction Commands section)
- Modify: `docs/app-guide.md` (the Inbox tab is now the action strip; add reaction dictionary editor)

**Interfaces:** documentation only; no code.

- [ ] **Step 1: Add the contracts** (STRIP-01 gesture-gated, STRIP-02 view-not-store, STRIP-03 decisions-through-registry, REMIND-01 inert-until-due, REMIND-02 read-only-Slack) to the inventory, following the existing entry format (numbered, load-bearing, one principle each). Do NOT duplicate REACT-01..05.

- [ ] **Step 2: Append the CLAUDE.md changelog entry** — a concise paragraph: Wave 2 tools, the reminders entity, the inbox action strip, the `inbox.situations.enabled` mute, the dictionary editor; note the situations demolition is a deferred follow-up. Reference the spec + this plan.

- [ ] **Step 3: Update `docs/app-guide.md`** — the Inbox tab now shows the action strip (gesture-gated proposals + due reminders); Settings → Slack has a reaction dictionary editor. (Per the App Guide Maintenance rule.)

- [ ] **Step 4: Commit**

```bash
git add docs/inventory/ CLAUDE.md docs/app-guide.md
git commit -m "docs(reactions): STRIP/REMIND contracts, wave 2 changelog, app guide"
```

---

### Task 13: Final gate + PR

**Files:** none (verification + PR).

- [ ] **Step 1: Full Go gate**

Run: `go build ./... > /tmp/gate_build.log 2>&1; echo "build=$?"; go test ./... > /tmp/gate_go.log 2>&1; echo "go=$?"`
Expected: both zero. If any package fails, fix before proceeding (do not pipe through `tail` for the verdict — read the exit code).

- [ ] **Step 2: Lint the diff**

Run: `make lint-diff > /tmp/gate_lint.log 2>&1; echo "lint=$?"` → zero (no new issues vs origin/main… note base is `feature/agent-actions`; if `lint-diff` targets origin/main, review flagged items for relevance).

- [ ] **Step 3: Swift gate** — filtered Core suites already ran per task; now the touched non-Core suites + a build:

Run: `make test-swift FILTER=ActionStripViewModelTests > /tmp/gate_sw1.log 2>&1; echo "$?"; cd WatchtowerDesktop && swift build 2>&1 | tail -5; echo "swiftbuild=$?"`
(Full unfiltered `swift test` is the CI gate; run it only if time permits — it re-links the ML stack.)

- [ ] **Step 4: Local review** — run the `local-review` skill over the branch diff before opening the PR (per the project's pre-PR quality gate). Triage every finding (accept/reject/defer), fix accepted ones, loop until reviewers converge.

- [ ] **Step 5: Push + open the PR against `feature/agent-actions`** (NOT main — the registry isn't in main yet):

```bash
git push -u origin feature/reaction-commands-wave2
gh pr create --base feature/agent-actions --head feature/reaction-commands-wave2 \
  --title "Reaction Commands Wave 2 + inbox action strip" \
  --body "$(cat <<'EOF'
Implements docs/superpowers/specs/2026-09-06-reaction-commands-wave2-inbox-action-strip-design.md.

## What
- 4 new agent-actions tools: create_track, create_idea, remind_me (+ reminders table), brief_context; seeded into the reaction dictionary (migration 00064).
- Inbox tab → flat action strip (agent_actions across surfaces + due reminders), reusing AgentActionCardView.
- Situations compose+cards muted behind inbox.situations.enabled (default off); triage/detectors/inbox_items untouched (Catch-Up/Memory keep their inputs).
- Settings → Slack: reaction dictionary editor.

## Owner calls (resolved)
- STRIP-A: chat proposals appear in the strip (yes).
- SIT-A: situations muted now (default off).
- remind_me bare :later: → next morning 09:00 local.

## Deferred (follow-up spec)
Physical removal of the situations pipeline + its consumers (memory/MCP/Catch-Up); custom agent handlers (Wave 3, runtime B); Jira gesture.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 6: Report the PR URL to the owner. Do NOT merge** (merge only on explicit owner OK).

---

## Self-Review

**Spec coverage:**
- §3 four tools → Tasks 3,4,5. Reminders entity → Tasks 1,2,5. Action strip → Tasks 8,9,10. Mute situations → Task 7. Dictionary breadth + editor → Tasks 1,11. Trust §7 → Task 1 seeds. Contracts → Task 12. ✓
- §4.1 STRIP-A (chat proposals included) → `fetchStrip` has no surface filter (Task 8). ✓
- §5.3 reminders/derived-due → Tasks 1,2,8 (no daemon phase — documented deviation, read-time due). ✓
- §5.4 brief_context echoes summary, no side effect → Task 5. ✓
- §6 narrow gate, triage untouched → Task 7. ✓
- REACT-02 provenance for reminders → Task 5 threads `Binding.ContextID`. ✓

**Deviations from spec (intentional, documented here):**
1. No `phaseReminders` daemon phase — due-ness is derived at read time (`status='pending' AND remind_at <= now`), simpler and behavior-equivalent. The spec's REMIND-01 ("inert until due") holds by the query, not a flip.
2. Reminders table drops a hard `account_id` requirement (defaults 0) — the message ref is an opaque `channel@ts` string from the binding; per-account scoping is not needed for v1 surfacing.

**Placeholder scan:** the Go/Swift snippets carry explicit "match the existing import path / helper name" NOTES where a signature must be confirmed against a named file:line — these are verification instructions, not placeholders. No "TBD"/"add error handling"/vague steps remain.

**Type consistency:** `Reminder`/`ReminderQueries.fetchDue(_:nowUTC:)`/`markDone`/`snooze` used consistently across Tasks 2 (Go), 8, 9 (Swift). `fetchStrip` defined in Task 8, consumed in Task 9. `ActionStripViewModel.approve/reject/retry/markReminderDone/snoozeReminder` defined in Task 9, consumed in Task 10. Tool constructor names `NewCreateTrack/NewCreateIdea/NewRemindMe/NewBriefContext` consistent across Tasks 3–5 and their registration in `cmd/actions_registry.go`.
