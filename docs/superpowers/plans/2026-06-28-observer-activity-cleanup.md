# Observer / Activity Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop auto-seeding noisy default observers on targets, give observer creation an AI wizard (single free-text field → AI-crafted scoped instruction + generated name), and move the Activity timeline off the Details screen into the Activity tab.

**Architecture:** Go backend owns observer persistence + the AI calls (invoked as CLI subprocesses). The Desktop SwiftUI app reads the shared SQLite DB via GRDB and shells out to the `watchtower` CLI for AI work. We remove the Go auto-seed chokepoint, add a new `observer.compose` AI prompt + pipeline method + CLI command, add a one-time cleanup migration, then rewire the Desktop sheet and target detail view.

**Tech Stack:** Go 1.25, `modernc.org/sqlite`, goose migrations, cobra CLI; SwiftUI (Swift 5.10, macOS 14+), GRDB.swift.

## Global Constraints

- Migrations are **goose** files `internal/db/migrations/0000N_<name>.sql` with `-- +goose Up` / `-- +goose Down`, auto-applied on `db.Open`. Next number is **00006**.
- Do NOT bump `CurrentSchemaFormat` (it is the migration-engine version, not the schema version). This migration changes no table shape, so `schema.sql` is untouched.
- New AI prompts must register in ALL of: `Defaults`, `AllIDs`, `DefaultVersions`, `Descriptions` (internal/prompts/defaults.go) plus the ID const in `internal/prompts/store.go`. Lightweight tasks route via `ModelForSource` (both `internal/digest/models.go` and `internal/codex/models.go`).
- AI prompts must work on BOTH providers (claude + codex) — they only receive system+user strings, so keep output a plain JSON object with no provider-specific assumptions.
- Go: run `gofmt`, `go vet`, `go build ./...`, `go test ./...` clean. Swift: `cd WatchtowerDesktop && swift build` then `swift test` clean.
- Observer entity model is polymorphic (`entity_type`/`entity_id`) but v1 only supports `entity_type='target'`.

---

## File Structure

- `internal/observers/pipeline.go` — remove auto-seed; add `Compose`.
- `internal/observers/prompt.go` — fix the empty-instruction fallback; add `buildComposePrompt` + `parseComposeOutput` + `ComposeResult`.
- `internal/observers/pipeline_test.go` — rewrite tests to create observers explicitly; add `Compose` tests.
- `cmd/observers.go` — `create` requires `--instruction`; add `compose` subcommand.
- `internal/prompts/store.go` + `internal/prompts/defaults.go` — register `observer.compose`.
- `internal/digest/models.go` + `internal/codex/models.go` — route `observer.compose` to the lightweight tier.
- `internal/db/migrations/00006_drop_default_observers.sql` — one-time cleanup.
- `internal/db/migrations_cleanup_test.go` — migration test.
- `WatchtowerDesktop/Sources/Services/ObserverComposeService.swift` — new CLI bridge.
- `WatchtowerDesktop/Tests/ObserverComposeServiceTests.swift` — decode tests.
- `WatchtowerDesktop/Sources/ViewModels/ObserverTimelineViewModel.swift` — add `compose(input:)`.
- `WatchtowerDesktop/Sources/Views/Targets/ObserverManagementSheet.swift` — AI wizard.
- `WatchtowerDesktop/Sources/Views/Targets/ObserverTimelineView.swift` — observer-aware empty state.
- `WatchtowerDesktop/Sources/Views/Targets/TargetDetailView.swift` — move timeline to Activity tab, metadata to Details.

---

## Task 1: Go — remove observer auto-seeding

Removing the `DefaultObserverName`/`DefaultObserverInstruction` constants breaks three call sites (`pipeline.go`, `prompt.go`, `cmd/observers.go`), so all are fixed together to keep the build green. Tests are rewritten to create observers explicitly since auto-seed is gone.

**Files:**
- Modify: `internal/observers/pipeline.go`
- Modify: `internal/observers/prompt.go:33-38`
- Modify: `cmd/observers.go:183-190`
- Test: `internal/observers/pipeline_test.go`

**Interfaces:**
- Consumes: existing `db.DB` observer methods (`GetObserversForEntity`, `GetEnabledObservers`, `CreateObserver`, `CountObserversForEntity`).
- Produces: `Pipeline.Run(ctx) (int, error)` and `Pipeline.RunForTarget(ctx, targetID) ([]db.ObserverEvent, error)` that NO LONGER create observers. `DefaultObserverName`/`DefaultObserverInstruction` no longer exist.

- [ ] **Step 1: Rewrite the pipeline tests to create observers explicitly**

Replace the whole body of `internal/observers/pipeline_test.go` from `func TestRunSeedsDefaultObserverAndPersistsEvents` through the end of `TestRunActivityPresentButNoEventsAdvancesWatermark` with the four tests below (keep the imports and the `mockGen` + `newTarget` helpers at the top unchanged). Add a small helper to create an observer:

```go
func newObserver(t *testing.T, d *db.DB, targetID int) {
	t.Helper()
	if _, err := d.CreateObserver(db.Observer{
		EntityType: "target", EntityID: targetID,
		Name: "Billing watcher", Instruction: "Watch billing migration progress.", Enabled: true,
	}); err != nil {
		t.Fatal(err)
	}
}

func TestRunNoObserversCreatesNothing(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Ship the billing migration")

	gen := &mockGen{resp: `{"events":[]}`}
	p := New(d, gen, log.Default())

	n, err := p.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Fatalf("expected 0 events with no observers, got %d", n)
	}
	if gen.calls != 0 {
		t.Fatalf("AI must not be called when no observers exist, got %d calls", gen.calls)
	}
	if cnt, _ := d.CountObserversForEntity("target", tid); cnt != 0 {
		t.Fatalf("Run must not auto-create observers, got %d", cnt)
	}
}

func TestRunPersistsEventsForExistingObserver(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Ship the billing migration")
	newObserver(t, d, tid)

	if _, err := d.Exec(`INSERT INTO digests (channel_id, period_from, period_to, type, summary)
		VALUES ('C1', 0, 0, 'channel', 'Billing plan B agreed in #eng')`); err != nil {
		t.Fatal(err)
	}

	gen := &mockGen{resp: `{"events":[
		{"summary":"Billing decision finalized in #eng","source_type":"digest","source_id":"5",
		 "source_refs":["https://x"],"decision":{"text":"go with plan B","by":"@ann","importance":"high"},
		 "proposed_action":{"type":"update_status","reason":"decided","status":"in_progress"}}]}`}
	p := New(d, gen, log.Default())

	n, err := p.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("expected 1 event, got %d", n)
	}
	events, _ := d.GetObserverEventsForEntity("target", tid, 50)
	if len(events) != 1 || events[0].ActionStatus != "pending" {
		t.Fatalf("event not persisted with pending action: %+v", events)
	}
	if events[0].Decision == "" || events[0].ProposedAction == "" {
		t.Fatalf("decision/proposed_action lost: %+v", events[0])
	}
}

func TestRunDegenerateNoEventsAdvancesWatermarkCleanly(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Quiet target")
	newObserver(t, d, tid)
	gen := &mockGen{resp: `{"events":[]}`}
	p := New(d, gen, log.Default())

	n, err := p.Run(context.Background())
	if err != nil {
		t.Fatalf("degenerate run must not error: %v", err)
	}
	if n != 0 {
		t.Fatalf("expected 0 events, got %d", n)
	}
	obs, _ := d.GetObserversForEntity("target", tid)
	if len(obs) != 1 || obs[0].LastRunAt == "" {
		t.Fatalf("watermark must advance even with no events: %+v", obs)
	}
	if events, _ := d.GetObserverEventsForEntity("target", tid, 50); len(events) != 0 {
		t.Fatalf("no events should be inserted, got %d", len(events))
	}
}

func TestRunForTargetReturnsNewEvents(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Force target")
	newObserver(t, d, tid)
	if _, err := d.Exec(`INSERT INTO digests (channel_id, period_from, period_to, type, summary)
		VALUES ('C1', 0, 0, 'channel', 'manual run activity')`); err != nil {
		t.Fatal(err)
	}
	gen := &mockGen{resp: `{"events":[{"summary":"manual run event","source_type":"track"}]}`}
	p := New(d, gen, log.Default())

	events, err := p.RunForTarget(context.Background(), tid)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 || events[0].Summary != "manual run event" {
		t.Fatalf("unexpected: %+v", events)
	}
}

func TestRunForTargetNoObserversReturnsEmpty(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "No observers here")
	gen := &mockGen{resp: `{"events":[]}`}
	p := New(d, gen, log.Default())

	events, err := p.RunForTarget(context.Background(), tid)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 0 {
		t.Fatalf("expected no events, got %+v", events)
	}
	if cnt, _ := d.CountObserversForEntity("target", tid); cnt != 0 {
		t.Fatalf("RunForTarget must not auto-create observers, got %d", cnt)
	}
}
```

- [ ] **Step 2: Run the tests to verify they fail (compile error / auto-seed)**

Run: `go test ./internal/observers/ -run 'TestRunNoObserversCreatesNothing|TestRunForTargetNoObserversReturnsEmpty' -v`
Expected: FAIL — either a build error (old tests still reference removed names) or the new tests fail because `Run`/`RunForTarget` still auto-seed an observer.

- [ ] **Step 3: Remove auto-seeding from `pipeline.go`**

In `internal/observers/pipeline.go`:

Delete the constant block (lines ~18-23):

```go
const (
	DefaultObserverName        = "Activity watcher"
	DefaultObserverInstruction = "Track anything across all sources that affects the progress, status, blockers, or decisions of this goal. Surface relevant updates and flag when the status or next step should change."
)
```

In `Run`, delete the seeding preamble so the method starts straight at fetching enabled observers:

```go
func (p *Pipeline) Run(ctx context.Context) (int, error) {
	enabled, err := p.db.GetEnabledObservers()
	if err != nil {
		return 0, err
	}
```

In `RunForTarget`, delete the `ensureDefaultForTarget` call so it begins by loading existing observers:

```go
func (p *Pipeline) RunForTarget(ctx context.Context, targetID int) ([]db.ObserverEvent, error) {
	obs, err := p.db.GetObserversForEntity("target", targetID)
	if err != nil {
		return nil, err
	}
```

Delete the now-unused functions `seedDefaultObservers()` and `ensureDefaultForTarget()` entirely. Keep `isActiveStatus` only if still referenced; after these deletions it is unused, so **delete `isActiveStatus` too**.

- [ ] **Step 4: Fix the empty-instruction fallback in `prompt.go`**

In `internal/observers/prompt.go`, replace the fallback that referenced the deleted constant (lines ~34-37):

```go
	instr := strings.TrimSpace(o.Instruction)
	if instr == "" {
		instr = "Track updates relevant to this target."
	}
	b.WriteString(instr + "\n\n")
```

- [ ] **Step 5: Make `observers create` require an instruction in `cmd/observers.go`**

Replace the name/instruction defaulting in `runObserversCreate` (lines ~183-190) with:

```go
	name := observerFlagName
	if name == "" {
		name = "Observer"
	}
	instr := strings.TrimSpace(observerFlagInstruction)
	if instr == "" {
		return fmt.Errorf("--instruction is required")
	}
```

(`strings` is not yet imported in `cmd/observers.go` — add `"strings"` to its import block.)

- [ ] **Step 6: Build and run the package tests**

Run: `gofmt -w internal/observers/ cmd/observers.go && go build ./... && go test ./internal/observers/ ./cmd/ -v`
Expected: PASS for all observers tests; build succeeds with no unused-symbol errors.

- [ ] **Step 7: Commit**

```bash
git add internal/observers/pipeline.go internal/observers/prompt.go internal/observers/pipeline_test.go cmd/observers.go
git commit -m "feat(observers): stop auto-seeding default observers"
```

---

## Task 2: Go — cleanup migration for already-seeded default observers

**Files:**
- Create: `internal/db/migrations/00006_drop_default_observers.sql`
- Create: `internal/db/migrations_cleanup_test.go`

**Interfaces:**
- Consumes: goose engine wired in `internal/db/migrations.go` (`goose.UpTo`, `goose.Up`, `migrationsFS` base FS set in `init()`).
- Produces: a migration that deletes observers whose `name` AND `instruction` exactly match the removed defaults (their `observer_events` cascade-delete via FK).

- [ ] **Step 1: Write the failing migration test**

Create `internal/db/migrations_cleanup_test.go`:

```go
package db

import (
	"database/sql"
	"testing"

	"github.com/pressly/goose/v3"
	_ "modernc.org/sqlite"
)

// Drives goose to v5 (observers table exists, before cleanup), seeds a
// default-looking observer + a custom one with events, then applies 00006 and
// asserts only the default observer (and its events) was removed.
func TestMigration00006DropsDefaultObservers(t *testing.T) {
	raw, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()
	raw.SetMaxOpenConns(1)
	if _, err := raw.Exec("PRAGMA foreign_keys=ON"); err != nil {
		t.Fatal(err)
	}

	if err := goose.UpTo(raw, "migrations", 5); err != nil {
		t.Fatalf("migrate to v5: %v", err)
	}

	const defName = "Activity watcher"
	const defInstr = "Track anything across all sources that affects the progress, status, blockers, or decisions of this goal. Surface relevant updates and flag when the status or next step should change."

	res, err := raw.Exec(`INSERT INTO observers (entity_type, entity_id, name, instruction, enabled)
		VALUES ('target', 1, ?, ?, 1)`, defName, defInstr)
	if err != nil {
		t.Fatal(err)
	}
	defID, _ := res.LastInsertId()
	if _, err := raw.Exec(`INSERT INTO observer_events (observer_id, entity_type, entity_id, summary)
		VALUES (?, 'target', 1, 'stale auto event')`, defID); err != nil {
		t.Fatal(err)
	}

	res, err = raw.Exec(`INSERT INTO observers (entity_type, entity_id, name, instruction, enabled)
		VALUES ('target', 1, 'Custom watcher', 'Watch only the billing refund decision.', 1)`)
	if err != nil {
		t.Fatal(err)
	}
	customID, _ := res.LastInsertId()
	if _, err := raw.Exec(`INSERT INTO observer_events (observer_id, entity_type, entity_id, summary)
		VALUES (?, 'target', 1, 'real event')`, customID); err != nil {
		t.Fatal(err)
	}

	if err := goose.Up(raw, "migrations"); err != nil {
		t.Fatalf("apply 00006: %v", err)
	}

	var obsCount int
	if err := raw.QueryRow(`SELECT COUNT(*) FROM observers`).Scan(&obsCount); err != nil {
		t.Fatal(err)
	}
	if obsCount != 1 {
		t.Fatalf("expected only the custom observer to remain, got %d", obsCount)
	}
	var remainingID int64
	if err := raw.QueryRow(`SELECT id FROM observers`).Scan(&remainingID); err != nil {
		t.Fatal(err)
	}
	if remainingID != customID {
		t.Fatalf("wrong observer survived: got id %d, want %d", remainingID, customID)
	}
	var evtCount int
	if err := raw.QueryRow(`SELECT COUNT(*) FROM observer_events`).Scan(&evtCount); err != nil {
		t.Fatal(err)
	}
	if evtCount != 1 {
		t.Fatalf("default observer's events must cascade-delete; got %d events", evtCount)
	}
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `go test ./internal/db/ -run TestMigration00006DropsDefaultObservers -v`
Expected: FAIL — `apply 00006` errors (migration file does not exist yet) OR both observers remain.

- [ ] **Step 3: Write the migration**

Create `internal/db/migrations/00006_drop_default_observers.sql`:

```sql
-- +goose Up
-- One-time cleanup: earlier builds auto-seeded a generic default observer on
-- every active target. That observer's broad instruction flooded the activity
-- timeline with loosely-related events. Auto-seeding has been removed; delete
-- the untouched auto-seeded observers (matched on the exact old default name +
-- instruction) so existing targets stop surfacing noise. Their observer_events
-- cascade-delete via the foreign key. Observers the user edited or created keep
-- a different name/instruction and are left intact.
DELETE FROM observers
WHERE name = 'Activity watcher'
  AND instruction = 'Track anything across all sources that affects the progress, status, blockers, or decisions of this goal. Surface relevant updates and flag when the status or next step should change.';

-- +goose Down
-- Irreversible: deleted rows cannot be resurrected. No-op.
SELECT 1;
```

- [ ] **Step 4: Run the migration test to verify it passes**

Run: `go test ./internal/db/ -run TestMigration00006DropsDefaultObservers -v`
Expected: PASS.

- [ ] **Step 5: Run the full db package tests (golden snapshots unaffected — no shape change)**

Run: `go test ./internal/db/`
Expected: PASS. If `TestSchemaGolden` fails, the migration accidentally changed a table shape — re-check the SQL (it must be DELETE only).

- [ ] **Step 6: Commit**

```bash
git add internal/db/migrations/00006_drop_default_observers.sql internal/db/migrations_cleanup_test.go
git commit -m "feat(observers): cleanup migration to drop auto-seeded default observers"
```

---

## Task 3: Go — register the `observer.compose` AI prompt

**Files:**
- Modify: `internal/prompts/store.go:40` (ID const block)
- Modify: `internal/prompts/defaults.go` (`Defaults`, `AllIDs`, `DefaultVersions`, `Descriptions`, new template const)
- Modify: `internal/digest/models.go:12`
- Modify: `internal/codex/models.go:15`

**Interfaces:**
- Produces: prompt ID `prompts.ObserverCompose = "observer.compose"`, retrievable via `Store.Get` / `prompts.DefaultFor`, routed to the lightweight model tier.

- [ ] **Step 1: Add the ID constant**

In `internal/prompts/store.go`, add to the const block after `ObserverRun`:

```go
	ObserverRun          = "observer.run"
	ObserverCompose      = "observer.compose"
```

- [ ] **Step 2: Register in the four maps + add the template in `defaults.go`**

Add to `Defaults` (after `ObserverRun: defaultObserverRun,`):

```go
	ObserverRun:          defaultObserverRun,
	ObserverCompose:      defaultObserverCompose,
```

Add to `AllIDs` (after `ObserverRun,`):

```go
	ObserverRun,
	ObserverCompose,
```

Add to `DefaultVersions` (after the `ObserverRun: 1,` line):

```go
	ObserverRun:        1, // v1: cross-source event timeline for an observed entity
	ObserverCompose:    1, // v1: draft observer name+instruction from a free-text request
```

Add to `Descriptions` (after the `ObserverRun:` entry):

```go
	ObserverRun:          "Observer run — produce timeline events for an observed entity from recent cross-source activity",
	ObserverCompose:      "Observer compose — draft a scoped observer name + watch instruction from a free-text user request",
```

Add the template constant at the end of `defaults.go`:

```go
const defaultObserverCompose = `You design a WATCH INSTRUCTION for an "observer" attached to a single goal or task (a "target") the operator owns. An observer scans recent cross-source activity (Slack digests, action-item tracks, inbox/Jira/calendar items) and surfaces ONLY updates relevant to its instruction.

You are given the TARGET and the operator's free-text USER REQUEST describing what they want watched. Produce:
- "name": a short label (at most 4 words) for what this observer watches.
- "instruction": a precise watch instruction scoped TIGHTLY to this target. Name the concrete topics, people, decisions, or blockers to watch for, and explicitly exclude unrelated chatter. Another AI reads this instruction as its relevance filter, so be specific and unambiguous. Write it in the operator's language.

Return ONLY a JSON object (no markdown fences, no prose) with exactly this shape:
{"name": "...", "instruction": "..."}`
```

- [ ] **Step 3: Route `observer.compose` to the lightweight tier**

In `internal/digest/models.go`, add `"observer.compose"` to the lightweight case:

```go
	case SourceLight, "inbox.prioritize", "digest.period", "digest.channel_batch", "people.batch", "catchup.peel", "observer.compose":
		return ModelHaiku
```

In `internal/codex/models.go`, mirror it:

```go
	case digest.SourceLight, "inbox.prioritize", "digest.period", "digest.channel_batch", "people.batch", "catchup.peel", "observer.compose":
		return ModelLightweight
```

- [ ] **Step 4: Build and run prompt + model tests**

Run: `gofmt -w internal/prompts/ internal/digest/models.go internal/codex/models.go && go build ./... && go test ./internal/prompts/ ./internal/digest/ ./internal/codex/`
Expected: PASS — `TestGetAllPromptIDs`, `TestDefaultFor_AllKnownKeysHaveDefaults`, and the `len(Defaults)` assertion all stay green because the new ID is present in every map.

- [ ] **Step 5: Commit**

```bash
git add internal/prompts/store.go internal/prompts/defaults.go internal/digest/models.go internal/codex/models.go
git commit -m "feat(observers): register observer.compose prompt (lightweight tier)"
```

---

## Task 4: Go — `Compose` pipeline method + parser

**Files:**
- Modify: `internal/observers/pipeline.go` (add `Compose`, `composeSystemPrompt`)
- Modify: `internal/observers/prompt.go` (add `ComposeResult`, `buildComposePrompt`, `parseComposeOutput`)
- Test: `internal/observers/pipeline_test.go` (add compose tests)

**Interfaces:**
- Consumes: `db.GetTargetByID`, `digest.Generator.Generate`, `prompts.ObserverCompose`, `prompts.DefaultFor`.
- Produces: `Pipeline.Compose(ctx context.Context, targetID int, input string) (ComposeResult, error)` and `ComposeResult{ Name string; Instruction string }` (JSON tags `name`, `instruction`).

- [ ] **Step 1: Write the failing tests**

Append to `internal/observers/pipeline_test.go`:

```go
func TestComposeParsesNameAndInstruction(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Ship billing migration")

	gen := &mockGen{resp: "```json\n{\"name\":\"Billing refund\",\"instruction\":\"Watch only the HashBank refund decision and its owner.\"}\n```"}
	p := New(d, gen, log.Default())

	res, err := p.Compose(context.Background(), tid, "the refund commission thing with HashBank")
	if err != nil {
		t.Fatal(err)
	}
	if res.Name != "Billing refund" {
		t.Fatalf("name = %q", res.Name)
	}
	if res.Instruction == "" {
		t.Fatalf("instruction empty")
	}
	if gen.calls != 1 {
		t.Fatalf("expected 1 AI call, got %d", gen.calls)
	}
}

func TestComposeEmptyInstructionErrors(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Ship billing migration")
	gen := &mockGen{resp: `{"name":"X","instruction":""}`}
	p := New(d, gen, log.Default())

	if _, err := p.Compose(context.Background(), tid, "watch stuff"); err == nil {
		t.Fatalf("expected error for empty instruction")
	}
}

func TestComposeDefaultsBlankName(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Ship billing migration")
	gen := &mockGen{resp: `{"name":"","instruction":"Watch the refund decision."}`}
	p := New(d, gen, log.Default())

	res, err := p.Compose(context.Background(), tid, "watch stuff")
	if err != nil {
		t.Fatal(err)
	}
	if res.Name != "Observer" {
		t.Fatalf("blank name should default to Observer, got %q", res.Name)
	}
}
```

- [ ] **Step 2: Run to verify failure**

Run: `go test ./internal/observers/ -run TestCompose -v`
Expected: FAIL — `p.Compose` undefined.

- [ ] **Step 3: Add `ComposeResult` + helpers in `prompt.go`**

Append to `internal/observers/prompt.go`:

```go
// ComposeResult is the AI-drafted observer name + watch instruction.
type ComposeResult struct {
	Name        string `json:"name"`
	Instruction string `json:"instruction"`
}

// buildComposePrompt renders the target context + the operator's free-text
// request into the user message for the observer.compose prompt.
func buildComposePrompt(target *db.Target, input string) string {
	var b strings.Builder
	b.WriteString("TARGET:\n")
	fmt.Fprintf(&b, "- text: %s\n", target.Text)
	if target.Intent != "" {
		fmt.Fprintf(&b, "- why: %s\n", target.Intent)
	}
	b.WriteString("\nUSER REQUEST (what to watch for):\n")
	b.WriteString(strings.TrimSpace(input) + "\n")
	return b.String()
}

// parseComposeOutput extracts the {name, instruction} object from a raw AI
// response, tolerating markdown fences and surrounding prose. A blank name
// defaults to "Observer"; a blank instruction is an error.
func parseComposeOutput(raw string) (ComposeResult, error) {
	s := strings.TrimSpace(raw)
	s = strings.TrimPrefix(s, "```json")
	s = strings.TrimPrefix(s, "```")
	s = strings.TrimSuffix(s, "```")
	start := strings.Index(s, "{")
	end := strings.LastIndex(s, "}")
	if start < 0 || end < start {
		return ComposeResult{}, fmt.Errorf("no JSON object found")
	}
	var r ComposeResult
	if err := json.Unmarshal([]byte(s[start:end+1]), &r); err != nil {
		return ComposeResult{}, err
	}
	r.Name = strings.TrimSpace(r.Name)
	r.Instruction = strings.TrimSpace(r.Instruction)
	if r.Instruction == "" {
		return ComposeResult{}, fmt.Errorf("compose returned empty instruction")
	}
	if r.Name == "" {
		r.Name = "Observer"
	}
	return r, nil
}
```

- [ ] **Step 4: Add `Compose` + `composeSystemPrompt` in `pipeline.go`**

Append to `internal/observers/pipeline.go`:

```go
// Compose drafts an observer name + watch instruction for a target from the
// operator's free-text request. It does not persist anything — the caller
// decides whether to create the observer.
func (p *Pipeline) Compose(ctx context.Context, targetID int, input string) (ComposeResult, error) {
	target, err := p.db.GetTargetByID(targetID)
	if err != nil {
		return ComposeResult{}, fmt.Errorf("loading target %d: %w", targetID, err)
	}
	user := buildComposePrompt(target, input)
	ctx2 := digest.WithSource(ctx, "observer.compose")
	raw, _, _, err := p.gen.Generate(ctx2, p.composeSystemPrompt(), user, "")
	if err != nil {
		return ComposeResult{}, fmt.Errorf("observer compose AI call: %w", err)
	}
	return parseComposeOutput(raw)
}

// composeSystemPrompt loads the registered observer.compose template from the
// DB, falling back to the built-in default.
func (p *Pipeline) composeSystemPrompt() string {
	if row, err := p.db.GetPrompt(prompts.ObserverCompose); err == nil && row != nil && row.Template != "" {
		return row.Template
	}
	return prompts.DefaultFor(prompts.ObserverCompose)
}
```

- [ ] **Step 5: Run the compose tests to verify pass**

Run: `gofmt -w internal/observers/ && go build ./... && go test ./internal/observers/ -run TestCompose -v`
Expected: PASS for all three compose tests.

- [ ] **Step 6: Commit**

```bash
git add internal/observers/pipeline.go internal/observers/prompt.go internal/observers/pipeline_test.go
git commit -m "feat(observers): add Compose pipeline method for the AI wizard"
```

---

## Task 5: Go — `watchtower observers compose` CLI command

**Files:**
- Modify: `cmd/observers.go`

**Interfaces:**
- Consumes: `observers.Pipeline.Compose`, `cliGenerator`, `applyProviderOverride`, `openObserverDB`, `parseEntity`.
- Produces: CLI `watchtower observers compose --entity target:<id> --input "<text>"` printing `ComposeResult` JSON (`{"name":..., "instruction":...}`) to stdout.

- [ ] **Step 1: Add the flag var, command, and registration**

In `cmd/observers.go`, add to the `var (...)` flag block:

```go
	observerFlagInput       string
```

Add the command definition near the other `observers*Cmd` vars:

```go
var observersComposeCmd = &cobra.Command{
	Use:   "compose",
	Short: "Draft an observer name + watch instruction from a free-text request (AI)",
	RunE:  runObserversCompose,
}
```

In `init()`, register flags and the subcommand:

```go
	observersComposeCmd.Flags().StringVar(&observerFlagEntity, "entity", "", "entity to attach to, e.g. target:42")
	observersComposeCmd.Flags().StringVar(&observerFlagInput, "input", "", "free-text description of what to watch")

	observersCmd.AddCommand(observersListCmd, observersShowCmd, observersCreateCmd,
		observersEditCmd, observersDeleteCmd, observersRunCmd, observersComposeCmd)
```

(Replace the existing `observersCmd.AddCommand(...)` call with the line above that appends `observersComposeCmd`.)

- [ ] **Step 2: Add the run function**

Add to `cmd/observers.go` (it uses `context`, `time`, `json`, `strings` — all imported after Task 1 added `strings`):

```go
func runObserversCompose(cmd *cobra.Command, args []string) error {
	database, cfg, err := openObserverDB()
	if err != nil {
		return err
	}
	defer database.Close()
	_, id, err := parseEntity(observerFlagEntity)
	if err != nil {
		return err
	}
	if strings.TrimSpace(observerFlagInput) == "" {
		return fmt.Errorf("--input is required")
	}
	applyProviderOverride(cfg)
	gen := cliGenerator(cfg)
	pipe := observers.New(database, gen, nil)
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()
	res, err := pipe.Compose(ctx, id, observerFlagInput)
	if err != nil {
		return fmt.Errorf("compose failed: %w", err)
	}
	enc := json.NewEncoder(cmd.OutOrStdout())
	enc.SetIndent("", "  ")
	return enc.Encode(res)
}
```

- [ ] **Step 3: Build and verify the command is wired**

Run: `gofmt -w cmd/observers.go && go build ./... && go run . observers compose --help`
Expected: build succeeds; help shows `--entity` and `--input` flags.

- [ ] **Step 4: Commit**

```bash
git add cmd/observers.go
git commit -m "feat(observers): add 'observers compose' CLI command"
```

---

## Task 6: Desktop — `ObserverComposeService` CLI bridge

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/ObserverComposeService.swift`
- Test: `WatchtowerDesktop/Tests/ObserverComposeServiceTests.swift`

**Interfaces:**
- Consumes: `CLIRunnerProtocol` (`func run(args: [String]) async throws -> Data`), same protocol `TargetObserveService` uses.
- Produces: `struct ObserverDraft: Decodable { let name: String; let instruction: String }` and `ObserverComposeService.compose(targetID: Int, input: String) async throws -> ObserverDraft`.

- [ ] **Step 1: Write the failing test**

Create `WatchtowerDesktop/Tests/ObserverComposeServiceTests.swift`. Mirror the existing mock-runner pattern used by other service tests in this folder (a `CLIRunnerProtocol` stub returning canned `Data`):

```swift
import XCTest
@testable import WatchtowerDesktop

final class ObserverComposeServiceTests: XCTestCase {
    private struct StubRunner: CLIRunnerProtocol {
        let output: Data
        func run(args: [String]) async throws -> Data { output }
    }

    func testDecodesNameAndInstruction() async throws {
        let json = #"{"name":"Billing refund","instruction":"Watch the HashBank refund decision."}"#
        let svc = ObserverComposeService(runner: StubRunner(output: Data(json.utf8)))
        let draft = try await svc.compose(targetID: 42, input: "refund thing")
        XCTAssertEqual(draft.name, "Billing refund")
        XCTAssertEqual(draft.instruction, "Watch the HashBank refund decision.")
    }

    func testThrowsOnEmptyOutput() async {
        let svc = ObserverComposeService(runner: StubRunner(output: Data()))
        do {
            _ = try await svc.compose(targetID: 1, input: "x")
            XCTFail("expected decode error")
        } catch {
            // expected
        }
    }
}
```

> If `CLIRunnerProtocol` in this repo declares `run` differently (verify in `WatchtowerDesktop/Sources/Services/`), match the real signature in the stub. The verified signature is `func run(args: [String]) async throws -> Data`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd WatchtowerDesktop && swift test --filter ObserverComposeServiceTests`
Expected: FAIL — `ObserverComposeService` / `ObserverDraft` not found.

- [ ] **Step 3: Implement the service**

Create `WatchtowerDesktop/Sources/Services/ObserverComposeService.swift`:

```swift
import Foundation

/// AI-drafted observer name + watch instruction returned by
/// `watchtower observers compose`.
struct ObserverDraft: Decodable {
    let name: String
    let instruction: String
}

/// Bridges the Desktop app to `watchtower observers compose`, which turns a
/// free-text "what to watch" request into a scoped observer name + instruction.
/// See `cmd/observers.go` `runObserversCompose` for the Go side.
struct ObserverComposeService {
    let runner: CLIRunnerProtocol

    func compose(targetID: Int, input: String) async throws -> ObserverDraft {
        let args = ["observers", "compose", "--entity", "target:\(targetID)", "--input", input]
        let data = try await runner.run(args: args)
        return try JSONDecoder().decode(ObserverDraft.self, from: data)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd WatchtowerDesktop && swift test --filter ObserverComposeServiceTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Services/ObserverComposeService.swift WatchtowerDesktop/Tests/ObserverComposeServiceTests.swift
git commit -m "feat(desktop): ObserverComposeService bridge to observers compose CLI"
```

---

## Task 7: Desktop — AI wizard in `ObserverManagementSheet`

**Files:**
- Modify: `WatchtowerDesktop/Sources/ViewModels/ObserverTimelineViewModel.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Targets/ObserverManagementSheet.swift`

**Interfaces:**
- Consumes: `ObserverComposeService`, `ProcessCLIRunner.makeDefault()`, existing `ObserverTimelineViewModel.createObserver(name:instruction:)`.
- Produces: `ObserverTimelineViewModel.compose(input: String) async -> ObserverDraft?` (nil on failure, sets `errorMessage`).

- [ ] **Step 1: Add `compose` to the view model**

In `WatchtowerDesktop/Sources/ViewModels/ObserverTimelineViewModel.swift`, add after `createObserver`:

```swift
    /// Drafts a scoped observer (name + instruction) from a free-text request
    /// via the CLI. Returns nil and sets `errorMessage` on failure.
    func compose(input: String) async -> ObserverDraft? {
        guard let runner = ProcessCLIRunner.makeDefault() else {
            errorMessage = "watchtower CLI not found in PATH"
            return nil
        }
        do {
            return try await ObserverComposeService(runner: runner).compose(targetID: target.id, input: input)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
```

- [ ] **Step 2: Replace the add-observer form with the AI wizard**

In `WatchtowerDesktop/Sources/Views/Targets/ObserverManagementSheet.swift`, replace the `@State private var newName` / `@State private var newInstruction` declarations and the "Add observer" block in `body` with a wizard. Full new file body for `ObserverManagementSheet` (keep `ObserverEditRow` below unchanged):

```swift
struct ObserverManagementSheet: View {
    @State var viewModel: ObserverTimelineViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var request = ""
    @State private var draftName = ""
    @State private var draftInstruction = ""
    @State private var hasDraft = false
    @State private var isGenerating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Observers").font(.title3).bold()

            List {
                ForEach(viewModel.observers) { observer in
                    ObserverEditRow(observer: observer, viewModel: viewModel)
                }
            }
            .frame(minHeight: 160)

            Divider()
            Text("Add observer").font(.headline)
            Text("Describe what to watch for — AI turns it into a focused instruction and names it.")
                .font(.caption).foregroundColor(.secondary)
            TextField("e.g. the HashBank refund decision and who owns it", text: $request, axis: .vertical)
                .lineLimit(2...4)
                .disabled(isGenerating)
            HStack {
                if let err = viewModel.errorMessage {
                    Text(err).font(.caption).foregroundColor(.red).lineLimit(2)
                }
                Spacer()
                Button {
                    Task { await generate() }
                } label: {
                    if isGenerating {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Generating…") }
                    } else {
                        Label("Generate with AI", systemImage: "sparkles")
                    }
                }
                .disabled(isGenerating || request.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if hasDraft {
                draftPreview
            }

            Divider()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding()
        .frame(width: 460)
    }

    private var draftPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Review").font(.subheadline).foregroundColor(.secondary)
            TextField("Name", text: $draftName)
            TextField("Instruction", text: $draftInstruction, axis: .vertical).lineLimit(2...5)
            HStack {
                Spacer()
                Button("Add observer") {
                    viewModel.createObserver(name: draftName, instruction: draftInstruction)
                    resetDraft()
                }
                .disabled(draftInstruction.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func generate() async {
        isGenerating = true
        viewModel.errorMessage = nil
        defer { isGenerating = false }
        if let draft = await viewModel.compose(input: request) {
            draftName = draft.name
            draftInstruction = draft.instruction
            hasDraft = true
        }
    }

    private func resetDraft() {
        request = ""
        draftName = ""
        draftInstruction = ""
        hasDraft = false
    }
}
```

- [ ] **Step 3: Build the app**

Run: `cd WatchtowerDesktop && swift build`
Expected: build succeeds.

- [ ] **Step 4: Run the Desktop test suite (no regressions)**

Run: `cd WatchtowerDesktop && swift test`
Expected: PASS (including `ObserverComposeServiceTests`).

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/ViewModels/ObserverTimelineViewModel.swift WatchtowerDesktop/Sources/Views/Targets/ObserverManagementSheet.swift
git commit -m "feat(desktop): AI wizard for observer creation (single field, AI-named)"
```

---

## Task 8: Desktop — move Activity timeline to the Activity tab

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Targets/TargetDetailView.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Targets/ObserverTimelineView.swift`

**Interfaces:**
- Consumes: existing `observerVM` lifecycle in `TargetDetailView`, `ObserverTimelineViewModel.observers`.
- Produces: `detailsTab` no longer shows the timeline (shows a compact About block instead); `activityTab` shows only the timeline; `ObserverTimelineView` shows an observer-aware empty state.

- [ ] **Step 1: Remove the timeline from `detailsTab` and add an About block**

In `TargetDetailView.swift`, in `detailsTab` (currently ~lines 253-272), delete the observer block:

```swift
            if let observerVM {
                ObserverTimelineView(viewModel: observerVM)
                    .id(target.id)
            }
```

and insert `aboutSection` just before `footerActions`:

```swift
            notesSection
            jiraIssueSection
            assistantInlineInput
            aboutSection
            footerActions
```

- [ ] **Step 2: Add the `aboutSection` view**

Add this computed property to `TargetDetailView` (near `notesSection`):

```swift
    // MARK: - About (metadata moved off the old Activity tab)

    @ViewBuilder
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About").font(.headline)
            if !target.sourceType.isEmpty && target.sourceType != "manual" {
                aboutRow("Source", "\(target.sourceType.capitalized) \(target.sourceID)")
            }
            aboutRow("Created", relativeOrDate(target.createdDate))
            aboutRow("Updated", relativeOrDate(target.updatedDate))
            let tags = target.decodedTags
            if !tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.blue.opacity(0.1), in: Capsule())
                    }
                }
            }
        }
    }

    private func aboutRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(value).font(.callout)
            Spacer(minLength: 0)
        }
    }

    private func relativeOrDate(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
```

- [ ] **Step 3: Replace `activityTab` with the timeline only**

In `TargetDetailView.swift`, replace the entire `activityTab` computed property (currently ~lines 1178-1241) with:

```swift
    // MARK: - Activity Tab (observer timeline)

    @ViewBuilder
    private var activityTab: some View {
        if let observerVM {
            ObserverTimelineView(viewModel: observerVM)
                .id(target.id)
        } else {
            Text("Loading…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
```

- [ ] **Step 4: Make the timeline empty state observer-aware**

In `ObserverTimelineView.swift`, replace the empty-state branch in `body`:

```swift
            if viewModel.events.isEmpty {
                if viewModel.observers.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No observers yet — add one to watch this goal.")
                            .font(.caption).foregroundColor(.secondary)
                        Button {
                            showingManage = true
                        } label: {
                            Label("Add observer", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                    }
                } else {
                    Text("No activity yet. Observers will surface relevant updates as they happen.")
                        .font(.caption).foregroundColor(.secondary)
                }
            } else {
```

(Leave the `else { ForEach(...) }` branch that follows unchanged.)

- [ ] **Step 5: Build and test**

Run: `cd WatchtowerDesktop && swift build && swift test`
Expected: build succeeds; full suite PASS.

- [ ] **Step 6: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Targets/TargetDetailView.swift WatchtowerDesktop/Sources/Views/Targets/ObserverTimelineView.swift
git commit -m "feat(desktop): move observer timeline to Activity tab; metadata to Details"
```

---

## Final verification

- [ ] **Step 1: Full Go build + test**

Run: `gofmt -l . && go vet ./... && go build ./... && go test ./...`
Expected: gofmt prints nothing; vet/build/test all clean.

- [ ] **Step 2: Full Desktop build + test**

Run: `cd WatchtowerDesktop && swift build && swift test`
Expected: clean build; all tests pass.

- [ ] **Step 3: Manual smoke (optional, requires a real workspace DB)**

- Open a target with no observers → Details shows About block, no timeline; Activity tab shows "No observers yet" + Add button.
- Add observer via wizard: type a request → Generate with AI → review name/instruction → Add → observer appears in the manage list.
- Confirm no new targets get an auto-seeded "Activity watcher" observer.
```
