# Situation Discuss Chat + Communication Style Profile Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A collapsed "Discuss with secretary" chat in the situation review pane that drafts ready-to-send Slack replies in the owner's voice, backed by a persisted, editable communication-style profile generated from the owner's own messages.

**Architecture:** Go side adds `workspace.style_profile` (migration 00013), a style-distillation pipeline (`internal/inbox/style_sample.go`), and CLI `watchtower inbox style-sample`. Swift side adds an AppState-owned `SecretaryProfileViewModel` (brief + style editors, Generate button), `SituationChatViewModel` (a de-actioned mirror of `TargetChatViewModel` with a situation-specific system prompt), and `SituationDiscussSection` rendered at the bottom of `SituationReviewPane`.

**Tech Stack:** Go 1.25 (goose migrations, cobra, digest.Generator), SwiftUI macOS 14+ / GRDB (`chat_conversations` reuse, `AIServiceProtocol` streaming), XCTest + testify.

**Spec:** `docs/superpowers/specs/2026-07-07-situation-discuss-chat-design.md`

## Global Constraints

- Branch: `feature/secretary-dashboard`. All GitHub-facing text in English.
- Guard tests DASH-01..04 and INBOX-01..09 stay green and **unmodified**; never weaken/rename a `Test<Module>NN_` test (`docs/inventory/`).
- AI batch calls only via `digest.Generator` + `digest.WithSource(ctx, "inbox.style_sample")`; prompt is a package-private const (same decision as `inbox.situation_learn`); `internal/digest/models.go` NOT modified (strong tier intended). Desktop chat streaming uses the existing `AIServiceProtocol` — never shell out to a CLI for chat.
- **No Slack write access. No auto-draft: zero AI calls until the user sends a message or clicks Draft reply.**
- Only migration 00013 (two `ALTER TABLE workspace ADD COLUMN`); mirror into `internal/db/schema.sql`, regenerate the golden (`go test ./internal/db/ -run TestSchemaGolden -update`), and mirror into the Swift test schema `WatchtowerDesktop/Tests/Helpers/TestDatabase.swift` (known drift trap).
- AI failure or empty message sample must leave the stored `style_profile` untouched.
- Verification: explicit exit codes, output redirected to log files, never rely on piped/truncated output. Swift lint gate is `make lint-swift` (with baseline) from the repo root — plain `swiftlint` misleads.
- Known pre-existing clock flakes (only if exactly these fail, confirm with changes stashed): TargetModelTests.testIsDueToday/testIsOverdueYesterday, TargetQueryTests.testFetchCountsReturnsCorrectStructure.

---

### Task 1: Migration 00013 + workspace style accessors (Go + test-schema mirror)

**Files:**
- Create: `internal/db/migrations/00013_style_profile.sql`
- Modify: `internal/db/schema.sql` (workspace table block, after `secretary_profile`)
- Modify: `internal/db/workspace.go` (accessors, after `SetSecretaryProfile`)
- Modify: `WatchtowerDesktop/Tests/Helpers/TestDatabase.swift` (workspace DDL mirror)
- Test: `internal/db/workspace_test.go`

**Interfaces:**
- Produces: `func (db *DB) GetStyleProfile() (string, error)`, `func (db *DB) SetStyleProfile(text string) error` (also stamps `style_profile_updated_at`). Column names `style_profile`, `style_profile_updated_at` — Task 4's Swift queries read/write them by name.

- [ ] **Step 1: Write the failing test**

Append to `internal/db/workspace_test.go` (follow the file's existing secretary-profile test style — read it first; the helper that creates a test DB with a workspace row already exists there):

```go
func TestStyleProfileRoundTrip(t *testing.T) {
	d := testDBWithWorkspace(t) // reuse the file's existing helper; verify its exact name before writing

	s, err := d.GetStyleProfile()
	if err != nil {
		t.Fatal(err)
	}
	if s != "" {
		t.Errorf("fresh style_profile = %q, want empty", s)
	}

	if err := d.SetStyleProfile("terse, RU with team"); err != nil {
		t.Fatal(err)
	}
	s, err = d.GetStyleProfile()
	if err != nil {
		t.Fatal(err)
	}
	if s != "terse, RU with team" {
		t.Errorf("style_profile = %q", s)
	}

	var ts string
	if err := d.QueryRow(`SELECT style_profile_updated_at FROM workspace LIMIT 1`).Scan(&ts); err != nil {
		t.Fatal(err)
	}
	if ts == "" {
		t.Error("style_profile_updated_at not stamped by SetStyleProfile")
	}
}

func TestSetStyleProfileNoWorkspaceRowErrors(t *testing.T) {
	d := newEmptyTestDB(t) // a DB with NO workspace row; verify/reuse the file's existing empty-DB helper name
	if err := d.SetStyleProfile("x"); err == nil {
		t.Error("SetStyleProfile must error when no workspace row exists (mirrors SetSecretaryProfile)")
	}
}
```

Implementer note: `workspace_test.go` already tests `GetSecretaryProfile`/`SetSecretaryProfile` — copy its exact setup-helper names instead of the placeholders above, keeping assertions as written.

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/db/ -run 'TestStyleProfile|TestSetStyleProfile' > /tmp/t1-red.log 2>&1; echo "exit=$?"; cat /tmp/t1-red.log`
Expected: build FAIL — `GetStyleProfile` undefined.

- [ ] **Step 3: Implement**

`internal/db/migrations/00013_style_profile.sql`:

```sql
-- +goose Up
-- Communication style profile: an AI-distilled, user-editable description of
-- how the owner writes on Slack. Consumed by the situation Discuss chat when
-- drafting replies. Generated by `watchtower inbox style-sample`, edited in
-- the Desktop Profile tab.
ALTER TABLE workspace ADD COLUMN style_profile TEXT NOT NULL DEFAULT '';
ALTER TABLE workspace ADD COLUMN style_profile_updated_at TEXT NOT NULL DEFAULT '';

-- +goose Down
ALTER TABLE workspace DROP COLUMN style_profile_updated_at;
ALTER TABLE workspace DROP COLUMN style_profile;
```

`internal/db/schema.sql` — in the `workspace` table definition, directly after the `secretary_profile` line, add:

```sql
    style_profile TEXT NOT NULL DEFAULT '',  -- AI-distilled, user-editable communication style (see 00013)
    style_profile_updated_at TEXT NOT NULL DEFAULT '',
```

`internal/db/workspace.go` — after `SetSecretaryProfile`:

```go
// GetStyleProfile returns the stored communication style profile text.
func (db *DB) GetStyleProfile() (string, error) {
	var s string
	err := db.QueryRow(`SELECT style_profile FROM workspace LIMIT 1`).Scan(&s)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", nil
		}
		return "", fmt.Errorf("getting style_profile: %w", err)
	}
	return s, nil
}

// SetStyleProfile stores the communication style profile and stamps its
// generation/edit time.
func (db *DB) SetStyleProfile(text string) error {
	res, err := db.Exec(`UPDATE workspace SET style_profile = ?,
		style_profile_updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
		WHERE id = (SELECT id FROM workspace LIMIT 1)`, text)
	if err != nil {
		return fmt.Errorf("setting style_profile: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("setting style_profile: no workspace row exists")
	}
	return nil
}
```

(Match `GetSecretaryProfile`'s actual no-rows handling — read it first; if it doesn't use `errors.Is`, mirror whatever it does.)

`WatchtowerDesktop/Tests/Helpers/TestDatabase.swift` — find the `workspace` CREATE TABLE in the test schema and add the same two columns after `secretary_profile`.

- [ ] **Step 4: Regenerate golden + run tests**

```bash
go test ./internal/db/ -run TestSchemaGolden -update > /tmp/t1-golden.log 2>&1; echo "golden=$?"
go test ./internal/db/ > /tmp/t1-green.log 2>&1; echo "go=$?"
cd WatchtowerDesktop && swift build > /tmp/t1-swift.log 2>&1; echo "swift=$?"
```
Expected: all 0 (no new table → `TestAllTablesExist` untouched).

- [ ] **Step 5: Commit**

```bash
git add internal/db/migrations/00013_style_profile.sql internal/db/schema.sql internal/db/workspace.go internal/db/workspace_test.go internal/db/testdata/ WatchtowerDesktop/Tests/Helpers/TestDatabase.swift
git commit -m "feat(db): workspace style_profile columns with accessors"
```
(`internal/db/testdata/` is where the schema golden lives — include whatever file the `-update` run rewrote; check `git status`.)

---

### Task 2: Style-sample pipeline (Go)

**Files:**
- Create: `internal/inbox/style_sample.go`
- Create: `internal/db/style_sample.go` (message-sampling accessor)
- Test: `internal/inbox/style_sample_test.go`

**Interfaces:**
- Consumes: Task 1's `GetStyleProfile`/`SetStyleProfile`; `p.db.GetWorkspace()` (field `CurrentUserID` — verify the exact getter name in `internal/db/workspace.go:30` area); `p.db.GetLatestPeopleCard(userID string) (*PeopleCard, error)` (`internal/db/people_cards.go:125` — verify nil-vs-error semantics for "no card" before relying on it); `p.generator digest.Generator`, `p.logger`.
- Produces: `func (p *Pipeline) GenerateStyleProfile(ctx context.Context) error` (Task 3's CLI calls this); `func (db *DB) ListStyleSampleMessages(userID string, fetchCap int) ([]StyleSampleMessage, error)` with `type StyleSampleMessage struct { ChannelID, ChannelName, ChannelType, Text, TS string }`.

Behavior contract:
- No `current_user_id` → error, no AI call.
- Empty sample (no qualifying messages) → error `"not enough messages to sample a style profile"`, no AI call, stored profile untouched.
- AI error → wrapped error, stored profile untouched.
- Success → `SetStyleProfile(distilled text)`.
- Sampling: only the owner's messages, `is_deleted = 0`, `subtype = ''`, trimmed length ≥ 8; newest first; capped at 15 per channel and 150 total (in Go, after a 1000-row fetch).

- [ ] **Step 1: Write the failing tests**

`internal/inbox/style_sample_test.go` (reuses `newTestDB`, `testConfig`, `countingGen` — all already in package from earlier tasks; `seedWorkspaceAndUser(t, d, "U1")` exists in compose tests, verify its name):

```go
package inbox

import (
	"context"
	"log"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func seedOwnMessage(t *testing.T, d *dbpkgAlias, channelID, chanType, ts, text string) {
	t.Helper()
	// insertChannel/insertMessage helpers exist in this package's compose tests —
	// reuse them; insertChannel may need a type parameter (public/private/dm).
	// If insertChannel hardcodes 'public', extend it with a type argument here
	// (updating its existing call sites mechanically) or add insertChannelTyped.
	_ = channelID
	_ = chanType
	_ = ts
	_ = text
}

func TestStyleSample_HappyPathStoresProfile(t *testing.T) {
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "U1")
	insertChannelTyped(t, d, "C1", "public")
	insertChannelTyped(t, d, "D1", "dm")
	insertMessage(t, d, "C1", "100.1", "U1", "деплой откатил, смотрю логи")
	insertMessage(t, d, "D1", "101.1", "U1", "ок, завтра созвонимся по клауду")
	insertMessage(t, d, "C1", "102.1", "U2", "someone else's message — must be excluded")

	gen := &countingGen{response: "You write tersely, RU with the team."}
	p := New(d, testConfig(), gen, log.Default())

	require.NoError(t, p.GenerateStyleProfile(context.Background()))

	assert.Equal(t, 1, gen.calls)
	got, err := d.GetStyleProfile()
	require.NoError(t, err)
	assert.Equal(t, "You write tersely, RU with the team.", got)
}

func TestStyleSample_EmptySampleNoAICallProfileUntouched(t *testing.T) {
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "U1")
	require.NoError(t, d.SetStyleProfile("existing profile"))

	gen := &countingGen{}
	p := New(d, testConfig(), gen, log.Default())

	err := p.GenerateStyleProfile(context.Background())
	require.Error(t, err)
	assert.Contains(t, err.Error(), "not enough messages")
	assert.Equal(t, 0, gen.calls)
	got, _ := d.GetStyleProfile()
	assert.Equal(t, "existing profile", got, "empty sample must not touch the stored profile")
}

func TestStyleSample_AIErrorLeavesProfileUntouched(t *testing.T) {
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "U1")
	insertChannelTyped(t, d, "C1", "public")
	insertMessage(t, d, "C1", "100.1", "U1", "a message long enough to qualify")
	require.NoError(t, d.SetStyleProfile("existing profile"))

	gen := &erroringGen{} // implement locally: Generate returns an error
	p := New(d, testConfig(), gen, log.Default())

	require.Error(t, p.GenerateStyleProfile(context.Background()))
	got, _ := d.GetStyleProfile()
	assert.Equal(t, "existing profile", got)
}

func TestStyleSample_CapsPerChannelAndTotal(t *testing.T) {
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "U1")
	insertChannelTyped(t, d, "C1", "public")
	for i := 0; i < 40; i++ {
		insertMessage(t, d, "C1", fmt.Sprintf("%d.1", 100+i), "U1", fmt.Sprintf("message number %d long enough", i))
	}

	msgs, err := d.ListStyleSampleMessages("U1", 1000)
	require.NoError(t, err)
	capped := capStyleSample(msgs, 15, 150)
	assert.Len(t, capped, 15, "per-channel cap of 15 must hold")
}
```

Implementer notes: replace the `seedOwnMessage`/`dbpkgAlias` stub above — it exists only to show intent; use the package's real `insertChannel`/`insertMessage` helpers (see `compose_test.go`), extending channel insertion with a `type` parameter if needed. Add `fmt` to imports where used. Delete the stub entirely. `erroringGen` is 5 lines modeled on `countingGen`.

- [ ] **Step 2: Run to verify failure**

Run: `go test ./internal/inbox/ -run TestStyleSample > /tmp/t2-red.log 2>&1; echo "exit=$?"; cat /tmp/t2-red.log`
Expected: build FAIL — `GenerateStyleProfile`/`ListStyleSampleMessages`/`capStyleSample` undefined.

- [ ] **Step 3: Implement**

`internal/db/style_sample.go`:

```go
package db

import "fmt"

// StyleSampleMessage is one of the owner's own messages, sampled for the
// communication-style distillation.
type StyleSampleMessage struct {
	ChannelID   string
	ChannelName string
	ChannelType string // public | private | dm | group_dm
	Text        string
	TS          string
}

// ListStyleSampleMessages returns the owner's most recent qualifying messages
// (not deleted, no subtype, non-trivial length), newest first, up to fetchCap.
// Per-channel/total capping happens in the caller.
func (db *DB) ListStyleSampleMessages(userID string, fetchCap int) ([]StyleSampleMessage, error) {
	rows, err := db.Query(`
		SELECT m.channel_id, c.name, c.type, m.text, m.ts
		FROM messages m
		JOIN channels c ON c.id = m.channel_id
		WHERE m.user_id = ? AND m.is_deleted = 0 AND m.subtype = ''
		  AND LENGTH(TRIM(m.text)) >= 8
		ORDER BY m.ts_unix DESC
		LIMIT ?`, userID, fetchCap)
	if err != nil {
		return nil, fmt.Errorf("listing style sample messages: %w", err)
	}
	defer rows.Close()
	var out []StyleSampleMessage
	for rows.Next() {
		var m StyleSampleMessage
		if err := rows.Scan(&m.ChannelID, &m.ChannelName, &m.ChannelType, &m.Text, &m.TS); err != nil {
			return nil, fmt.Errorf("scanning style sample message: %w", err)
		}
		out = append(out, m)
	}
	return out, rows.Err()
}
```

`internal/inbox/style_sample.go`:

```go
package inbox

import (
	"context"
	"fmt"
	"strings"

	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// styleSampleSystemPrompt drives the communication-style distillation.
// Package-private const (same decision as situationLearnSystemPrompt) — not
// user-editable via the prompt store.
const styleSampleSystemPrompt = `You are analyzing how one person writes on Slack, to produce a "communication style profile" that another AI will later use to draft replies in this person's voice.

Below are samples of the person's OWN messages, grouped by audience (direct messages, private channels, public channels), plus an optional analyst's note about their communication style.

Distill a compact profile covering:
- Languages they use and when (e.g. Russian with the team, English with external partners).
- Tone and formality by audience: DMs vs channels, insiders vs external partners.
- Typical phrases, openers, sign-offs, punctuation and emoji habits, typical message length.
- Things they never do (e.g. corporate pleasantries, long intros, formal sign-offs).

Write the profile as plain text (markdown allowed), addressed in second person ("You write..."), at most ~400 words. Output ONLY the profile text — no preamble, no JSON, no code fences.`

// capStyleSample keeps at most perChannel messages per channel and total
// messages overall, preserving input (newest-first) order.
func capStyleSample(msgs []db.StyleSampleMessage, perChannel, total int) []db.StyleSampleMessage {
	perCount := map[string]int{}
	out := make([]db.StyleSampleMessage, 0, total)
	for _, m := range msgs {
		if len(out) >= total {
			break
		}
		if perCount[m.ChannelID] >= perChannel {
			continue
		}
		perCount[m.ChannelID]++
		out = append(out, m)
	}
	return out
}

// GenerateStyleProfile samples the owner's sent messages (plus their own
// People card, when present), distills a communication-style profile via one
// strong-tier AI call, and persists it to workspace.style_profile. An empty
// sample or AI failure leaves the stored profile untouched.
func (p *Pipeline) GenerateStyleProfile(ctx context.Context) error {
	ws, err := p.db.GetWorkspace()
	if err != nil {
		return fmt.Errorf("style sample: workspace: %w", err)
	}
	if ws.CurrentUserID == "" {
		return fmt.Errorf("style sample: no current user id — run a sync first")
	}

	raw, err := p.db.ListStyleSampleMessages(ws.CurrentUserID, 1000)
	if err != nil {
		return fmt.Errorf("style sample: %w", err)
	}
	sample := capStyleSample(raw, 15, 150)
	if len(sample) == 0 {
		return fmt.Errorf("style sample: not enough messages to sample a style profile")
	}

	analystNote := ""
	if card, cErr := p.db.GetLatestPeopleCard(ws.CurrentUserID); cErr == nil && card != nil {
		analystNote = strings.TrimSpace(card.CommunicationStyle)
	}

	user := buildStyleSampleUserMessage(sample, analystNote)
	out, _, _, err := p.generator.Generate(
		digest.WithSource(ctx, "inbox.style_sample"), styleSampleSystemPrompt, user, "")
	if err != nil {
		return fmt.Errorf("style sample: %w", err)
	}
	profile := strings.TrimSpace(out)
	if profile == "" {
		return fmt.Errorf("style sample: model returned an empty profile — stored profile left untouched")
	}
	if err := p.db.SetStyleProfile(profile); err != nil {
		return fmt.Errorf("style sample: %w", err)
	}
	p.logger.Printf("inbox: style profile regenerated from %d messages", len(sample))
	return nil
}

// buildStyleSampleUserMessage renders the sampled messages grouped by
// audience, plus the optional analyst's note from the owner's People card.
func buildStyleSampleUserMessage(sample []db.StyleSampleMessage, analystNote string) string {
	groups := map[string][]db.StyleSampleMessage{}
	for _, m := range sample {
		key := "PUBLIC CHANNELS"
		switch m.ChannelType {
		case "dm", "group_dm":
			key = "DIRECT MESSAGES"
		case "private":
			key = "PRIVATE CHANNELS"
		}
		groups[key] = append(groups[key], m)
	}
	var b strings.Builder
	for _, key := range []string{"DIRECT MESSAGES", "PRIVATE CHANNELS", "PUBLIC CHANNELS"} {
		msgs := groups[key]
		if len(msgs) == 0 {
			continue
		}
		fmt.Fprintf(&b, "=== %s ===\n", key)
		for _, m := range msgs {
			text := strings.Join(strings.Fields(m.Text), " ")
			if len(text) > 300 {
				text = text[:300]
			}
			fmt.Fprintf(&b, "- [#%s] %s\n", m.ChannelName, text)
		}
		b.WriteString("\n")
	}
	if analystNote != "" {
		fmt.Fprintf(&b, "=== ANALYST'S NOTE (from a prior AI analysis of this person) ===\n%s\n", analystNote)
	}
	return b.String()
}
```

Implementer notes: verify `GetWorkspace()`'s exact name/return in `internal/db/workspace.go` and `GetLatestPeopleCard`'s no-card semantics (`internal/db/people_cards.go:125`) — if it returns an error for "no rows", the `cErr == nil && card != nil` guard already copes; adapt only if the name differs. The 300-byte truncation may split a UTF-8 rune — acceptable for prompt sample text, do not add rune handling.

- [ ] **Step 4: Run to verify pass**

Run: `go test ./internal/inbox/ > /tmp/t2-green.log 2>&1; echo "exit=$?"` → 0. Also `go vet ./... && gofmt -l internal/`.

- [ ] **Step 5: Commit**

```bash
git add internal/inbox/style_sample.go internal/inbox/style_sample_test.go internal/db/style_sample.go
git commit -m "feat(inbox): communication style profile distilled from the owner's messages"
```
(Include any helper-signature change in `compose_test.go`/related test files if channel insertion gained a type parameter.)

---

### Task 3: CLI `watchtower inbox style-sample`

**Files:**
- Modify: `cmd/inbox.go`
- Test: `cmd/inbox_test.go`

**Interfaces:**
- Consumes: Task 2's `Pipeline.GenerateStyleProfile(ctx)`.
- Produces: CLI `watchtower inbox style-sample` (no args, no flags) — Task 4's Swift VM invokes exactly `["inbox", "style-sample"]`.

- [ ] **Step 1: Write the failing test**

Extend the existing registration test in `cmd/inbox_test.go` (the same tests that were extended for `feedback` — read them and mirror):

```go
// In TestInboxSubcommandsRegistered's expected-subcommand list, add "style-sample".
```

- [ ] **Step 2: Run to verify failure**

Run: `go test ./cmd/ -run TestInboxSubcommandsRegistered > /tmp/t3-red.log 2>&1; echo "exit=$?"`
Expected: FAIL — `style-sample` not registered.

- [ ] **Step 3: Implement**

In `cmd/inbox.go`, add next to `inboxFeedbackCmd`:

```go
var inboxStyleSampleCmd = &cobra.Command{
	Use:   "style-sample",
	Short: "Distill a communication style profile from your own Slack messages",
	Args:  cobra.NoArgs,
	RunE:  runInboxStyleSample,
}
```

Register it in `init()`'s `inboxCmd.AddCommand(...)` list. Add the runner (identical scaffolding to `runInboxFeedback` — config load, `applyProviderOverride(cfg)`, `ValidateWorkspace`, `db.Open`, `cliPooledGenerator`, `inbox.New`):

```go
func runInboxStyleSample(cmd *cobra.Command, _ []string) error {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	applyProviderOverride(cfg)
	if err := cfg.ValidateWorkspace(); err != nil {
		return fmt.Errorf("invalid config: %w", err)
	}

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	logger := log.New(cmd.ErrOrStderr(), "[inbox] ", log.LstdFlags)
	gen, closeGen := cliPooledGenerator(cfg, logger)
	defer closeGen()

	pipe := inbox.New(database, cfg, gen, logger)
	if err := pipe.GenerateStyleProfile(cmd.Context()); err != nil {
		return err
	}
	fmt.Fprintln(cmd.OutOrStdout(), "Style profile regenerated.")
	return nil
}
```

- [ ] **Step 4: Verify**

```bash
go build ./... && go test ./cmd/ > /tmp/t3-green.log 2>&1; echo "exit=$?"
go run . inbox style-sample --help
```
Expected: exit 0; help shows the subcommand.

- [ ] **Step 5: Commit**

```bash
git add cmd/inbox.go cmd/inbox_test.go
git commit -m "feat(cli): inbox style-sample subcommand"
```

---

### Task 4: SecretaryProfileViewModel (AppState-owned) + Profile tab style section

**Files:**
- Create: `WatchtowerDesktop/Sources/ViewModels/SecretaryProfileViewModel.swift`
- Modify: `WatchtowerDesktop/Sources/Database/Queries/SecretaryProfileQueries.swift` (style fetch/save)
- Modify: `WatchtowerDesktop/Sources/Views/Inbox/SecretaryProfileView.swift` (rewrite around the VM, add style section)
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift` (own the VM; init next to `initDashboard` at AppState.swift:212/338)
- Modify: `WatchtowerDesktop/Sources/Views/Inbox/InboxFeedView.swift` (pass the VM in the `.profile` tab)
- Test: `WatchtowerDesktop/Tests/SecretaryProfileViewModelTests.swift` (new)

**Interfaces:**
- Consumes: Task 1's columns via new queries; `CLIRunnerProtocol` + `FakeCLIRunner` (Tests/Helpers); Task 3's CLI arg shape `["inbox", "style-sample"]`; `ProcessCLIRunner.makeDefault()`.
- Produces: `@MainActor @Observable final class SecretaryProfileViewModel` with `briefText`, `styleText`, `styleUpdatedAt: String`, `isLoading`, `isSavingBrief`, `isSavingStyle`, `isGenerating`, `errorMessage`, `hasUnsavedStyleChanges: Bool { get }`, `canGenerate: Bool { get }`, `load()`, `saveBrief() async`, `saveStyle() async`, `generateStyle() async`. AppState gains `private(set) var secretaryProfileViewModel: SecretaryProfileViewModel?` + `func initSecretaryProfile(dbManager: DatabaseManager)` called wherever `initDashboard` is called.

- [ ] **Step 1: Extend queries**

In `SecretaryProfileQueries.swift` add (same shape as the existing pair):

```swift
    /// Empty strings when no workspace row exists yet.
    static func fetchStyle(_ db: Database) throws -> (text: String, updatedAt: String) {
        let row = try Row.fetchOne(db, sql: "SELECT style_profile, style_profile_updated_at FROM workspace LIMIT 1")
        return (row?["style_profile"] ?? "", row?["style_profile_updated_at"] ?? "")
    }

    /// UPDATE only — silent no-op without a workspace row (matches save(_:text:)).
    static func saveStyle(_ db: Database, text: String) throws {
        try db.execute(
            sql: "UPDATE workspace SET style_profile = ?, style_profile_updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')",
            arguments: [text]
        )
    }
```

- [ ] **Step 2: Write the failing VM tests**

`WatchtowerDesktop/Tests/SecretaryProfileViewModelTests.swift`:

```swift
import XCTest
import GRDB
@testable import WatchtowerDesktop

@MainActor
final class SecretaryProfileViewModelTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        } catch { XCTFail("setUp failed: \(error)") }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    private func insertWorkspace() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertWorkspace(db) // verify the helper's exact name/args in TestDatabase.swift
        }
    }

    func testLoadReadsBriefAndStyle() throws {
        try insertWorkspace()
        try dbManager.dbPool.write { db in
            try db.execute(sql: "UPDATE workspace SET secretary_profile = 'brief', style_profile = 'style'")
        }
        let vm = SecretaryProfileViewModel(dbManager: dbManager)
        vm.load()
        XCTAssertEqual(vm.briefText, "brief")
        XCTAssertEqual(vm.styleText, "style")
        XCTAssertFalse(vm.hasUnsavedStyleChanges)
    }

    func testSaveStylePersistsAndClearsUnsavedFlag() async throws {
        try insertWorkspace()
        let vm = SecretaryProfileViewModel(dbManager: dbManager)
        vm.load()
        vm.styleText = "edited style"
        XCTAssertTrue(vm.hasUnsavedStyleChanges)

        await vm.saveStyle()

        XCTAssertFalse(vm.hasUnsavedStyleChanges)
        let stored = try dbManager.dbPool.read { try SecretaryProfileQueries.fetchStyle($0).text }
        XCTAssertEqual(stored, "edited style")
    }

    func testGenerateStyleInvokesCLIAndReloads() async throws {
        try insertWorkspace()
        let runner = FakeCLIRunner(stdout: Data())
        let vm = SecretaryProfileViewModel(dbManager: dbManager, cliRunner: runner)
        vm.load()

        await vm.generateStyle()

        XCTAssertEqual(runner.invocations, [["inbox", "style-sample"]])
        XCTAssertFalse(vm.isGenerating)
        XCTAssertNil(vm.errorMessage)
    }

    func testGenerateStyleBlockedByUnsavedEdits() async throws {
        try insertWorkspace()
        let runner = FakeCLIRunner(stdout: Data())
        let vm = SecretaryProfileViewModel(dbManager: dbManager, cliRunner: runner)
        vm.load()
        vm.styleText = "unsaved edit"

        XCTAssertFalse(vm.canGenerate)
        await vm.generateStyle()

        XCTAssertTrue(runner.invocations.isEmpty, "generate must not run over unsaved edits")
    }

    func testGenerateStyleGuardsReentry() async throws {
        try insertWorkspace()
        let runner = FakeCLIRunner(stdout: Data())
        let vm = SecretaryProfileViewModel(dbManager: dbManager, cliRunner: runner)
        vm.load()
        vm.isGenerating = true

        await vm.generateStyle()

        XCTAssertTrue(runner.invocations.isEmpty)
        XCTAssertTrue(vm.isGenerating, "the guard must not clear the in-flight flag")
    }

    func testGenerateStyleSurfacesCLIFailure() async throws {
        try insertWorkspace()
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "not enough messages"))
        let vm = SecretaryProfileViewModel(dbManager: dbManager, cliRunner: runner)
        vm.load()

        await vm.generateStyle()

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertFalse(vm.isGenerating)
    }

    func testAppStateOwnsVMIdentityAcrossAccesses() throws {
        // Mirrors AppStateTests' dashboardViewModel identity check — navigation
        // must not recreate the VM (async ops survive navigation).
        let appState = AppState()
        appState.initSecretaryProfile(dbManager: dbManager)
        let first = appState.secretaryProfileViewModel
        let second = appState.secretaryProfileViewModel
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second)
    }
}
```

Implementer notes: verify `TestDatabase.insertWorkspace`'s real name/signature (grep TestDatabase.swift; there is an existing workspace-insertion helper used by DashboardViewModel slack-URL tests). Verify `AppState()` is constructible in tests the way `AppStateTests` does it — mirror that file's setup.

- [ ] **Step 3: Run to verify failure**

Run: `cd WatchtowerDesktop && swift test --filter SecretaryProfileViewModelTests > /tmp/t4-red.log 2>&1; echo "exit=$?"`
Expected: build FAIL — `SecretaryProfileViewModel` undefined.

- [ ] **Step 4: Implement the VM**

`WatchtowerDesktop/Sources/ViewModels/SecretaryProfileViewModel.swift`:

```swift
import Foundation
import GRDB

/// Drives the Inbox → Profile tab: the secretary brief editor plus the
/// communication style profile (editable text + on-demand regeneration via
/// `watchtower inbox style-sample`). Owned by AppState so an in-flight
/// generation survives tab/sidebar navigation.
@MainActor
@Observable
final class SecretaryProfileViewModel {
    var briefText = ""
    var styleText = ""
    private(set) var styleUpdatedAt = ""
    var isLoading = false
    var isSavingBrief = false
    var isSavingStyle = false
    var isGenerating = false
    var errorMessage: String?

    /// The style text as last loaded/saved — the baseline for unsaved-change detection.
    private var loadedStyleText = ""

    private let dbManager: DatabaseManager
    private let cliRunner: CLIRunnerProtocol?

    init(dbManager: DatabaseManager, cliRunner: CLIRunnerProtocol? = nil) {
        self.dbManager = dbManager
        self.cliRunner = cliRunner
    }

    var hasUnsavedStyleChanges: Bool { styleText != loadedStyleText }

    /// Generate overwrites the stored profile; refuse while the editor holds
    /// unsaved manual edits so they are never silently clobbered.
    var canGenerate: Bool { !isGenerating && !hasUnsavedStyleChanges }

    func load() {
        isLoading = true
        do {
            let (brief, style) = try dbManager.dbPool.read { db in
                (try SecretaryProfileQueries.fetch(db), try SecretaryProfileQueries.fetchStyle(db))
            }
            briefText = brief
            styleText = style.text
            loadedStyleText = style.text
            styleUpdatedAt = style.updatedAt
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load profile: \(error.localizedDescription)"
        }
        isLoading = false
    }

    func saveBrief() async {
        isSavingBrief = true
        defer { isSavingBrief = false }
        do {
            let text = briefText
            try await dbManager.dbPool.write { db in
                try SecretaryProfileQueries.save(db, text: text)
            }
            errorMessage = nil
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    func saveStyle() async {
        isSavingStyle = true
        defer { isSavingStyle = false }
        do {
            let text = styleText
            try await dbManager.dbPool.write { db in
                try SecretaryProfileQueries.saveStyle(db, text: text)
            }
            loadedStyleText = text
            errorMessage = nil
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    /// Runs `watchtower inbox style-sample` and reloads. Guarded against
    /// re-entry and against clobbering unsaved manual edits.
    func generateStyle() async {
        guard canGenerate else { return }
        isGenerating = true
        defer { isGenerating = false }
        guard let runner = cliRunner ?? ProcessCLIRunner.makeDefault() else {
            errorMessage = "watchtower CLI not found in PATH"
            return
        }
        do {
            _ = try await runner.run(args: ["inbox", "style-sample"])
            load()
        } catch {
            errorMessage = "Failed to generate style profile: \(error.localizedDescription)"
        }
    }
}
```

`AppState.swift` — next to `dashboardViewModel` (line ~47) add `private(set) var secretaryProfileViewModel: SecretaryProfileViewModel?`; next to `initDashboard` (line ~338) add:

```swift
    func initSecretaryProfile(dbManager: DatabaseManager) {
        guard secretaryProfileViewModel == nil else { return }
        secretaryProfileViewModel = SecretaryProfileViewModel(dbManager: dbManager)
    }
```

and call `initSecretaryProfile(dbManager: manager)` right after the existing `initDashboard(dbManager: manager)` call (line ~212). Mirror `initDashboard`'s actual guard/reset semantics — read it first; if it doesn't guard on nil, don't either.

- [ ] **Step 5: Rewrite `SecretaryProfileView` around the VM**

Replace the whole file body: the view takes `@Bindable var vm: SecretaryProfileViewModel`, keeps the existing brief editor (bound to `vm.briefText`, Save → `Task { await vm.saveBrief() }`) and adds below it a "Communication style" section:

```swift
import SwiftUI

// MARK: - SecretaryProfileView

/// Inbox → Profile tab: the secretary brief plus the communication style
/// profile. Both are workspace-level free text; the style profile can also be
/// regenerated from the owner's own messages via `watchtower inbox style-sample`.
struct SecretaryProfileView: View {
    @Bindable var vm: SecretaryProfileViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errorMessage = vm.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            if vm.isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        briefSection
                        styleSection
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { vm.load() }
    }

    private var briefSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Who you are")
                .font(.headline)
            Text("Tell the secretary who you are and what matters. It reads this before every scan.")
                .font(.caption)
                .foregroundStyle(.secondary)
            editor(text: $vm.briefText, minHeight: 160)
            HStack {
                Spacer()
                Button("Save") { Task { await vm.saveBrief() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.isSavingBrief || vm.isLoading)
            }
        }
    }

    private var styleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Communication style")
                .font(.headline)
            Text("How you write on Slack — used by Discuss to draft replies in your voice. Generate a starting point from your own messages, then edit freely.")
                .font(.caption)
                .foregroundStyle(.secondary)
            editor(text: $vm.styleText, minHeight: 200)
            HStack {
                Button {
                    Task { await vm.generateStyle() }
                } label: {
                    if vm.isGenerating {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Generating…")
                        }
                    } else {
                        Label("Generate from my messages", systemImage: "wand.and.stars")
                    }
                }
                .disabled(!vm.canGenerate)
                .help(vm.hasUnsavedStyleChanges
                      ? "Save or revert your edits first — generating would overwrite them"
                      : "Analyze your recent Slack messages and write a style profile")
                Spacer()
                Button("Save") { Task { await vm.saveStyle() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.isSavingStyle || vm.isLoading || !vm.hasUnsavedStyleChanges)
            }
        }
    }

    private func editor(text: Binding<String>, minHeight: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(minHeight: minHeight)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
    }
}
```

`InboxFeedView.swift` — in `profileContent`, replace the `SecretaryProfileView(db: dbPool)` construction with:

```swift
    @ViewBuilder
    private var profileContent: some View {
        if let vm = appState.secretaryProfileViewModel {
            SecretaryProfileView(vm: vm)
        } else {
            Text("Database unavailable")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
```

Note the "Saved" flash from the old view is dropped (the Save button's disabled state now communicates saved-ness for style; brief keeps it simple) — acceptable simplification; do not re-add timers to the VM.

- [ ] **Step 6: Verify + commit**

```bash
cd WatchtowerDesktop && swift test --filter SecretaryProfileViewModelTests > /tmp/t4-green.log 2>&1; echo "test=$?"
swift build > /tmp/t4-build.log 2>&1; echo "build=$?"
cd .. && make lint-swift > /tmp/t4-lint.log 2>&1; echo "lint=$?"
git add WatchtowerDesktop/Sources/ViewModels/SecretaryProfileViewModel.swift WatchtowerDesktop/Sources/Database/Queries/SecretaryProfileQueries.swift WatchtowerDesktop/Sources/Views/Inbox/SecretaryProfileView.swift WatchtowerDesktop/Sources/App/AppState.swift WatchtowerDesktop/Sources/Views/Inbox/InboxFeedView.swift WatchtowerDesktop/Tests/SecretaryProfileViewModelTests.swift
git commit -m "feat(desktop): communication style profile editor with on-demand generation"
```

---

### Task 5: SituationChatViewModel + system prompt builder (Swift)

**Files:**
- Create: `WatchtowerDesktop/Sources/ViewModels/SituationChatViewModel.swift`
- Test: `WatchtowerDesktop/Tests/SituationChatViewModelTests.swift`

**Interfaces:**
- Consumes: `ChatConversationQueries.fetchByContext(_:type:id:)` / `.create(_:title:contextType:contextID:)` / `.touch` / `.updateSessionID`; `ChatMessageQueries.fetchByConversation` / `.insert`; `AIServiceProtocol.stream(prompt:systemPrompt:sessionID:dbPath:model:)` (extension defaults cover provider/extraAllowedTools); `ChatModel.defaultModel(for:)`; `PeopleCardQueries.fetchByUser(_:userID:limit:)`; `SecretaryProfileQueries.fetch` / `.fetchStyle` (Task 4); `Situation`, `InboxItem`, `Workspace` (`currentUserID`); `MockClaudeService` (Tests/Helpers) for tests.
- Produces (Task 6's view consumes): `@MainActor @Observable final class SituationChatViewModel` with `messages: [ChatMessage]`, `isStreaming`, `inputText`, `errorMessage`, `send()`, `draftReply()`, `cancelStream()`; `static let draftRequestText = "Draft a reply I can send in this thread."`; `nonisolated static func buildSystemPrompt(situation: Situation, memberSignals: [InboxItem], dbPool: DatabasePool) -> String`; `static func persistedMessageCount(_ db: Database, situationID: Int) throws -> Int`.

Structure: a de-actioned mirror of `TargetChatViewModel` (no action cards, no action parsing, no model picker UI — `selectedModel` fixed to `ChatModel.defaultModel(for: provider)`). Same conversation load/create, message observation, streaming, persistence, session-id handling, cancel semantics. On resumed sessions, prepend the situation context block to the prompt (same rationale as `TargetChatViewModel.executeStream`'s resumed-turn carry).

- [ ] **Step 1: Write the failing tests**

`WatchtowerDesktop/Tests/SituationChatViewModelTests.swift`:

```swift
import XCTest
import GRDB
@testable import WatchtowerDesktop

@MainActor
final class SituationChatViewModelTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        } catch { XCTFail("setUp failed: \(error)") }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    private func makeSituation(title: String = "Cloudflare follow-up") throws -> Situation {
        let id = try dbManager.dbPool.write { db in
            try TestDatabase.insertSituation(db, title: title, whyMatters: "ball is on you", summary: "second follow-up", chronology: "day 1 ... day 13")
        }
        return try dbManager.dbPool.read { db in
            try Situation.fetchOne(db, sql: "SELECT * FROM situations WHERE id = ?", arguments: [id])!
        }
    }

    // MARK: - Conversation lifecycle

    func testCreatesConversationWithSituationContext() throws {
        let situation = try makeSituation()
        _ = SituationChatViewModel(situation: situation, memberSignals: [], dbManager: dbManager, aiService: MockClaudeService())

        let conv = try dbManager.dbPool.read { db in
            try ChatConversationQueries.fetchByContext(db, type: "situation", id: String(situation.id))
        }
        XCTAssertNotNil(conv)
        XCTAssertTrue(conv!.title.hasPrefix("Situation:"))
    }

    func testReopensExistingConversationWithHistory() throws {
        let situation = try makeSituation()
        let vm1 = SituationChatViewModel(situation: situation, memberSignals: [], dbManager: dbManager, aiService: MockClaudeService())
        _ = vm1 // conversation created
        let convID = try dbManager.dbPool.read { db in
            try ChatConversationQueries.fetchByContext(db, type: "situation", id: String(situation.id))!.id
        }
        try dbManager.dbPool.write { db in
            _ = try ChatMessageQueries.insert(db, conversationID: convID, role: "user", text: "earlier question")
        }

        let vm2 = SituationChatViewModel(situation: situation, memberSignals: [], dbManager: dbManager, aiService: MockClaudeService())

        XCTAssertEqual(vm2.messages.map(\.text), ["earlier question"])
    }

    // MARK: - Draft reply

    func testDraftReplySendsCannedMessageAndStreams() async throws {
        let situation = try makeSituation()
        let mock = MockClaudeService(events: [.text("Черновик ответа"), .done])
        let vm = SituationChatViewModel(situation: situation, memberSignals: [], dbManager: dbManager, aiService: mock)

        vm.draftReply()
        try await waitUntil { !vm.isStreaming }

        XCTAssertEqual(mock.prompts.first, SituationChatViewModel.draftRequestText)
        XCTAssertEqual(vm.messages.last?.text, "Черновик ответа")
        XCTAssertEqual(vm.messages.first?.text, SituationChatViewModel.draftRequestText)
    }

    func testStreamErrorSurfacesInline() async throws {
        let situation = try makeSituation()
        struct Boom: Error {}
        let vm = SituationChatViewModel(situation: situation, memberSignals: [], dbManager: dbManager, aiService: MockClaudeService(error: Boom()))

        vm.inputText = "hello"
        vm.send()
        try await waitUntil { !vm.isStreaming }

        XCTAssertNotNil(vm.errorMessage)
    }

    // MARK: - System prompt builder

    func testBuildSystemPromptIncludesCardAndSignals() throws {
        let situation = try makeSituation()
        let itemID = try dbManager.dbPool.write { db in
            try TestDatabase.insertInboxItem(db, channelID: "C1", messageTS: "1700000100.000000", snippet: "Since I didn't hear back from you")
        }
        let signals = try dbManager.dbPool.read { db in
            try InboxItem.fetchAll(db, sql: "SELECT * FROM inbox_items WHERE id = ?", arguments: [itemID])
        }

        let prompt = SituationChatViewModel.buildSystemPrompt(
            situation: situation, memberSignals: signals, dbPool: dbManager.dbPool)

        XCTAssertTrue(prompt.contains("Cloudflare follow-up"))
        XCTAssertTrue(prompt.contains("ball is on you"))
        XCTAssertTrue(prompt.contains("Since I didn't hear back from you"))
        XCTAssertTrue(prompt.contains("ready-to-send"))
    }

    func testBuildSystemPromptStyleBlockPresentAndAbsent() throws {
        let situation = try makeSituation()
        try dbManager.dbPool.write { db in
            try TestDatabase.insertWorkspace(db)
            try db.execute(sql: "UPDATE workspace SET style_profile = 'You write tersely.'")
        }
        let with = SituationChatViewModel.buildSystemPrompt(situation: situation, memberSignals: [], dbPool: dbManager.dbPool)
        XCTAssertTrue(with.contains("You write tersely."))

        try dbManager.dbPool.write { db in
            try db.execute(sql: "UPDATE workspace SET style_profile = ''")
        }
        let without = SituationChatViewModel.buildSystemPrompt(situation: situation, memberSignals: [], dbPool: dbManager.dbPool)
        XCTAssertFalse(without.contains("OWNER'S COMMUNICATION STYLE"))
        XCTAssertTrue(without.contains("mirror the owner's own messages"), "empty style must fall back to mirroring instruction")
    }

    func testBuildSystemPromptCounterpartyBriefFromPeopleCard() throws {
        let situation = try makeSituation()
        let itemID = try dbManager.dbPool.write { db -> Int64 in
            try TestDatabase.insertWorkspace(db)
            // Verify TestDatabase has a people-card insertion helper; if not, raw SQL insert
            // into people_cards with user_id='U9', communication_guide='be blunt with him'.
            try db.execute(sql: """
                INSERT INTO people_cards (user_id, period_from, period_to, communication_guide)
                VALUES ('U9', 1.0, 2.0, 'be blunt with him')
                """)
            return try TestDatabase.insertInboxItem(db, channelID: "C1", messageTS: "1700000100.000000", senderUserID: "U9", snippet: "ping")
        }
        let signals = try dbManager.dbPool.read { db in
            try InboxItem.fetchAll(db, sql: "SELECT * FROM inbox_items WHERE id = ?", arguments: [itemID])
        }

        let prompt = SituationChatViewModel.buildSystemPrompt(situation: situation, memberSignals: signals, dbPool: dbManager.dbPool)

        XCTAssertTrue(prompt.contains("be blunt with him"))
    }

    func testPersistedMessageCount() throws {
        let situation = try makeSituation()
        XCTAssertEqual(try dbManager.dbPool.read { try SituationChatViewModel.persistedMessageCount($0, situationID: situation.id) }, 0)

        let vm = SituationChatViewModel(situation: situation, memberSignals: [], dbManager: dbManager, aiService: MockClaudeService())
        _ = vm
        let convID = try dbManager.dbPool.read { db in
            try ChatConversationQueries.fetchByContext(db, type: "situation", id: String(situation.id))!.id
        }
        try dbManager.dbPool.write { db in
            _ = try ChatMessageQueries.insert(db, conversationID: convID, role: "user", text: "hi")
        }
        XCTAssertEqual(try dbManager.dbPool.read { try SituationChatViewModel.persistedMessageCount($0, situationID: situation.id) }, 1)
    }

    // MARK: - Helpers

    private func waitUntil(_ cond: @escaping () -> Bool) async throws {
        for _ in 0..<200 where !cond() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(cond(), "condition not met within 2s")
    }
}
```

Implementer notes: verify `TestDatabase.insertInboxItem`'s parameter labels (`senderUserID:` may differ — grep it) and whether `TestDatabase.insertWorkspace` exists (DashboardViewModel slack-URL tests insert a workspace — reuse whatever they use). Verify the people_cards test-schema DDL includes `communication_guide` (it mirrors schema.sql; if the INSERT fails on missing defaults, supply the NOT NULL columns explicitly). If an existing `waitUntil`-style polling helper exists in the test suite (grep TargetChatViewModelTests), reuse it instead of defining one.

- [ ] **Step 2: Run to verify failure**

Run: `cd WatchtowerDesktop && swift test --filter SituationChatViewModelTests > /tmp/t5-red.log 2>&1; echo "exit=$?"`
Expected: build FAIL — `SituationChatViewModel` undefined.

- [ ] **Step 3: Implement**

`WatchtowerDesktop/Sources/ViewModels/SituationChatViewModel.swift`. Mirror `TargetChatViewModel.swift`'s structure (read it side by side); the deltas are: no `actionCards`/parser/approve/reject, no model picker (fixed default model), `contextType "situation"`, the situation-specific prompt builder, and a `draftReply()` entry point. Full code:

```swift
import Foundation
import GRDB

// MARK: - SituationChatViewModel

/// Drives the "Discuss with secretary" chat inside the situation review pane.
/// A de-actioned mirror of `TargetChatViewModel`: persisted conversation per
/// situation (`chat_conversations.context_type = "situation"`), streaming via
/// `AIServiceProtocol`, no watchtower-action blocks. Its specialty is the
/// system prompt: situation context + member signals + the owner's secretary
/// brief, communication style profile, counterparty People-card briefs, and a
/// register sample of the owner's own messages in the situation's channels —
/// so a requested draft comes out in the owner's voice.
@MainActor
@Observable
final class SituationChatViewModel {
    var messages: [ChatMessage] = []
    var isStreaming = false
    var inputText = ""
    var errorMessage: String?

    static let draftRequestText = "Draft a reply I can send in this thread."

    private var conversationID: Int64?
    private var sessionID: String?
    private let aiService: any AIServiceProtocol
    private let dbManager: DatabaseManager
    private let situation: Situation
    private let memberSignals: [InboxItem]
    private let selectedModel: ChatModel
    private var streamTask: Task<Void, Never>?

    init(
        situation: Situation,
        memberSignals: [InboxItem],
        dbManager: DatabaseManager,
        aiService: (any AIServiceProtocol)? = nil,
        provider: AIProvider? = nil
    ) {
        self.situation = situation
        self.memberSignals = memberSignals
        self.dbManager = dbManager
        self.aiService = aiService ?? WatchtowerAIService()
        let resolvedProvider = provider
            ?? (ConfigService().aiProvider == "codex" ? .codex : .claude)
        self.selectedModel = ChatModel.defaultModel(for: resolvedProvider)

        loadOrCreateConversation()
    }

    /// Message count of the persisted conversation for a situation — cheap
    /// badge read for the collapsed Discuss header; 0 when no conversation.
    static func persistedMessageCount(_ db: Database, situationID: Int) throws -> Int {
        guard let conv = try ChatConversationQueries.fetchByContext(
            db, type: "situation", id: String(situationID)
        ) else { return 0 }
        return try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM chat_messages WHERE conversation_id = ?",
            arguments: [conv.id]
        ) ?? 0
    }

    private func loadOrCreateConversation() {
        do {
            if let existing = try dbManager.dbPool.read({ db in
                try ChatConversationQueries.fetchByContext(
                    db, type: "situation", id: String(situation.id)
                )
            }) {
                let records = try dbManager.dbPool.read { db in
                    try ChatMessageQueries.fetchByConversation(db, conversationID: existing.id)
                }
                conversationID = existing.id
                sessionID = existing.sessionID
                messages = records.map { $0.toChatMessage() }
                return
            }
            let conv = try dbManager.dbPool.write { db in
                try ChatConversationQueries.create(
                    db,
                    title: "Situation: \(String(situation.title.prefix(60)))",
                    contextType: "situation",
                    contextID: String(situation.id)
                )
            }
            conversationID = conv.id
            sessionID = conv.sessionID
            messages = []
        } catch {
            errorMessage = "Failed to load conversation: \(error.localizedDescription)"
        }
    }

    // MARK: - Sending

    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        inputText = ""
        sendUserMessage(text)
    }

    /// The "Draft reply" button: a canned request so the secretary produces a
    /// ready-to-send reply per the system prompt's draft contract.
    func draftReply() {
        guard !isStreaming else { return }
        sendUserMessage(Self.draftRequestText)
    }

    private func sendUserMessage(_ text: String) {
        streamTask?.cancel()
        messages.append(ChatMessage(
            id: UUID(), role: .user, text: text, timestamp: Date(), isStreaming: false
        ))
        if let convID = conversationID {
            persistMessage(conversationID: convID, role: "user", text: text)
        }
        messages.append(ChatMessage(
            id: UUID(), role: .assistant, text: "", timestamp: Date(), isStreaming: true
        ))

        isStreaming = true
        let currentSessionID = sessionID
        let capturedSituation = situation
        let capturedSignals = memberSignals
        let dbPool = dbManager.dbPool
        let dbPath = dbManager.dbPool.path
        let capturedService = aiService
        let capturedDBManager = dbManager
        let capturedConvID = conversationID
        let model = selectedModel.rawValue

        streamTask = Task { [weak self] in
            await self?.executeStream(
                text: text, currentSessionID: currentSessionID,
                situation: capturedSituation, memberSignals: capturedSignals,
                dbPool: dbPool, dbPath: dbPath, aiService: capturedService,
                dbManager: capturedDBManager, conversationID: capturedConvID,
                model: model
            )
        }
    }

    // MARK: - Stream execution

    private func executeStream(
        text: String,
        currentSessionID: String?,
        situation: Situation,
        memberSignals: [InboxItem],
        dbPool: DatabasePool,
        dbPath: String,
        aiService: any AIServiceProtocol,
        dbManager: DatabaseManager,
        conversationID: Int64?,
        model: String
    ) async {
        let systemPrompt: String? = currentSessionID == nil
            ? Self.buildSystemPrompt(situation: situation, memberSignals: memberSignals, dbPool: dbPool)
            : nil
        // Resumed sessions drop the system prompt (CLI --resume); carry the
        // situation context with the message so an expired session never loses
        // track of what is being discussed (same rationale as TargetChat).
        let effectivePrompt = currentSessionID == nil
            ? text
            : "\(Self.situationContextBlock(situation, memberSignals: memberSignals))\n\n\(text)"

        var fullText = ""
        do {
            let stream = aiService.stream(
                prompt: effectivePrompt,
                systemPrompt: systemPrompt,
                sessionID: currentSessionID,
                dbPath: dbPath,
                model: model
            )
            var sawTurnComplete = false
            for try await event in stream {
                switch event {
                case .text(let chunk):
                    if sawTurnComplete {
                        fullText = chunk
                        sawTurnComplete = false
                    } else {
                        fullText += chunk
                    }
                    updateLastMessage(fullText)
                case .turnComplete(let text):
                    fullText = text
                    sawTurnComplete = true
                    updateLastMessage(fullText)
                case .sessionID(let sid):
                    handleSessionID(sid)
                case .done:
                    break
                }
            }
            if !fullText.isEmpty, let convID = conversationID {
                Self.persistResponse(dbManager: dbManager, conversationID: convID, text: fullText)
            }
        } catch {
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }
        finishStream()
    }

    func cancelStream() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        if let idx = messages.indices.last, messages[idx].isStreaming {
            let partial = messages[idx].text
            if !partial.isEmpty, let convID = conversationID {
                persistMessage(conversationID: convID, role: "assistant", text: partial)
            }
            messages[idx].isStreaming = false
        }
    }

    // MARK: - Persistence / state helpers

    private func updateLastMessage(_ text: String) {
        if let idx = messages.indices.last {
            messages[idx].text = text
        }
    }

    private func finishStream() {
        for idx in messages.indices where messages[idx].isStreaming {
            messages[idx].isStreaming = false
        }
        isStreaming = false
    }

    private func handleSessionID(_ sid: String) {
        sessionID = sid
        guard let convID = conversationID else { return }
        do {
            try dbManager.dbPool.write { db in
                try ChatConversationQueries.updateSessionID(db, id: convID, sessionID: sid)
            }
        } catch {
            print("SituationChat: failed to persist session id: \(error)")
        }
    }

    private func persistMessage(conversationID: Int64, role: String, text: String) {
        do {
            try dbManager.dbPool.write { db in
                _ = try ChatMessageQueries.insert(db, conversationID: conversationID, role: role, text: text)
            }
        } catch {
            print("SituationChat: failed to persist \(role) message: \(error)")
        }
    }

    nonisolated private static func persistResponse(
        dbManager: DatabaseManager, conversationID: Int64, text: String
    ) {
        do {
            try dbManager.dbPool.write { db in
                try ChatMessageQueries.insert(db, conversationID: conversationID, role: "assistant", text: text)
                try ChatConversationQueries.touch(db, id: conversationID)
            }
        } catch {
            print("SituationChat: failed to persist assistant response: \(error)")
        }
    }

    // MARK: - System prompt

    /// The `=== SITUATION ===` block: card + member-signal originals. Also
    /// carried with the message on resumed sessions.
    nonisolated static func situationContextBlock(
        _ situation: Situation, memberSignals: [InboxItem]
    ) -> String {
        var b = """
        === SITUATION ===
        Title: \(situation.title)
        Kind: \(situation.kindRaw)  Priority: \(situation.priority)
        """
        if !situation.whyMatters.isEmpty { b += "\nWhy it matters: \(situation.whyMatters)" }
        if !situation.summary.isEmpty { b += "\nSummary: \(situation.summary)" }
        if !situation.chronology.isEmpty { b += "\nChronology:\n\(situation.chronology)" }
        if let targetID = situation.targetID { b += "\nLinked target id: \(targetID)" }
        if let trackID = situation.trackID { b += "\nLinked track id: \(trackID)" }
        b += "\n\n=== MEMBER SIGNALS (the underlying Slack messages, oldest first) ==="
        if memberSignals.isEmpty {
            b += "\n(none recorded)"
        }
        for item in memberSignals {
            b += "\n- [\(item.senderUserID) in \(item.channelID) at \(item.messageTS)] \(item.snippet)"
        }
        return b
    }

    nonisolated static func buildSystemPrompt(
        situation: Situation, memberSignals: [InboxItem], dbPool: DatabasePool
    ) -> String {
        let ws: Workspace? = try? dbPool.read { db in try WorkspaceQueries.fetchWorkspace(db) }
        let ownerID = ws?.currentUserID ?? ""

        let brief = (try? dbPool.read { db in try SecretaryProfileQueries.fetch(db) }) ?? ""
        let style = (try? dbPool.read { db in try SecretaryProfileQueries.fetchStyle(db).text }) ?? ""

        let styleBlock = style.isEmpty
            ? "No stored style profile — mirror the owner's own messages in the register sample below."
            : "=== OWNER'S COMMUNICATION STYLE ===\n\(style)"

        return """
        You are the user's AI secretary, discussing ONE situation from their work dashboard. \
        Help them think it through and, when asked (e.g. "Draft a reply..."), write the reply FOR them.

        DRAFT CONTRACT (strict): a requested draft must be ready-to-send Slack text in the OWNER'S voice — \
        same language the thread uses, same register the owner uses with these people. \
        No meta-commentary, no "here's a draft:", no signatures or pleasantries the owner wouldn't type. \
        Output the draft as a plain block the owner can copy verbatim; put any commentary AFTER the draft, clearly separated.

        \(situationContextBlock(situation, memberSignals: memberSignals))

        === WHO THE OWNER IS ===
        \(brief.isEmpty ? "(no brief provided)" : brief)

        \(styleBlock)

        \(counterpartyBlock(memberSignals: memberSignals, ownerID: ownerID, dbPool: dbPool))
        \(registerSampleBlock(memberSignals: memberSignals, ownerID: ownerID, dbPool: dbPool))
        === RESPONSE STYLE ===
        - Match the user's language in conversation.
        - Be concise; this is a working discussion, not a report.
        """
    }

    /// People-card briefs for each distinct non-owner sender among the member
    /// signals. Empty string when nothing is available.
    nonisolated private static func counterpartyBlock(
        memberSignals: [InboxItem], ownerID: String, dbPool: DatabasePool
    ) -> String {
        let senderIDs = Array(Set(memberSignals.map(\.senderUserID)))
            .filter { !$0.isEmpty && $0 != ownerID }
            .sorted()
        guard !senderIDs.isEmpty else { return "" }
        var sections: [String] = []
        for senderID in senderIDs {
            guard let card = (try? dbPool.read { db in
                try PeopleCardQueries.fetchByUser(db, userID: senderID, limit: 1).first
            }) ?? nil else { continue }
            var lines: [String] = []
            if !card.communicationStyle.isEmpty { lines.append("Their style: \(card.communicationStyle)") }
            if !card.communicationGuide.isEmpty { lines.append("How to talk to them: \(card.communicationGuide)") }
            if !card.relationshipContext.isEmpty { lines.append("Relationship: \(card.relationshipContext)") }
            if !lines.isEmpty {
                sections.append("[\(senderID)]\n" + lines.joined(separator: "\n"))
            }
        }
        guard !sections.isEmpty else { return "" }
        return """
        === COUNTERPARTIES (from prior AI analysis) ===
        \(sections.joined(separator: "\n\n"))

        """
    }

    /// The owner's last messages in each of the situation's channels — the
    /// concrete voice to imitate with this audience. Empty string when none.
    nonisolated private static func registerSampleBlock(
        memberSignals: [InboxItem], ownerID: String, dbPool: DatabasePool
    ) -> String {
        guard !ownerID.isEmpty else { return "" }
        let channelIDs = Array(Set(memberSignals.map(\.channelID))).filter { !$0.isEmpty }.sorted()
        guard !channelIDs.isEmpty else { return "" }
        var lines: [String] = []
        for channelID in channelIDs {
            let texts = (try? dbPool.read { db in
                try String.fetchAll(db, sql: """
                    SELECT text FROM messages
                    WHERE channel_id = ? AND user_id = ? AND is_deleted = 0 AND subtype = ''
                      AND LENGTH(TRIM(text)) >= 8
                    ORDER BY ts_unix DESC LIMIT 10
                    """, arguments: [channelID, ownerID])
            }) ?? []
            for text in texts {
                lines.append("- [\(channelID)] \(text.split(whereSeparator: \.isNewline).joined(separator: " "))")
            }
        }
        guard !lines.isEmpty else { return "" }
        return """
        === REGISTER SAMPLE (the owner's own recent messages in these channels — imitate this voice) ===
        \(lines.joined(separator: "\n"))

        """
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd WatchtowerDesktop && swift test --filter SituationChatViewModelTests > /tmp/t5-green.log 2>&1; echo "exit=$?"` → 0.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/ViewModels/SituationChatViewModel.swift WatchtowerDesktop/Tests/SituationChatViewModelTests.swift
git commit -m "feat(desktop): situation chat VM with owner-voice draft prompt"
```

---

### Task 6: SituationDiscussSection view + review-pane wiring

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Dashboard/SituationDiscussSection.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Dashboard/SituationReviewPane.swift` (render the section below `memberSignalsSection`; pane needs `@Environment(AppState.self)` for the DatabaseManager)

**Interfaces:**
- Consumes: Task 5's `SituationChatViewModel` (init, `messages`, `isStreaming`, `inputText`, `errorMessage`, `send()`, `draftReply()`, `cancelStream()`, `persistedMessageCount`); `ChatInput` (Views/Chat/ChatInput.swift — `text:isStreaming:onSend:onStop:placeholder:`); `MarkdownText`; `ChatMessage`.
- Produces: final UI. No new public API.

Views are not unit-tested in this repo; the gate is build + full suite + lint.

- [ ] **Step 1: Create `SituationDiscussSection.swift`**

```swift
import SwiftUI
import AppKit

// MARK: - SituationDiscussSection

/// Collapsed-by-default "Discuss with secretary" chat at the bottom of the
/// situation review pane. Inert while collapsed (one cheap message-count read);
/// the chat VM — and any AI call — exists only after the user expands it and
/// acts. Draft replies are copy-only: the app never posts to Slack.
struct SituationDiscussSection: View {
    let situation: Situation
    let memberSignals: [InboxItem]
    let dbManager: DatabaseManager

    @State private var isExpanded = false
    @State private var chatVM: SituationChatViewModel?
    @State private var persistedCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.vertical, 2)
            header
            if isExpanded, let chatVM {
                SituationDiscussChat(chatVM: chatVM)
                    .padding(.top, 6)
            }
        }
        .onAppear(perform: loadPersistedCount)
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                Text("Discuss with secretary")
                    .font(.subheadline)
                    .fontWeight(.medium)
                if persistedCount > 0 && !isExpanded {
                    Text("\(persistedCount)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor, in: Capsule())
                }
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggle() {
        if isExpanded {
            chatVM?.cancelStream()
            isExpanded = false
            loadPersistedCount()
            return
        }
        if chatVM == nil {
            chatVM = SituationChatViewModel(
                situation: situation, memberSignals: memberSignals, dbManager: dbManager
            )
        }
        isExpanded = true
    }

    private func loadPersistedCount() {
        let situationID = situation.id
        persistedCount = (try? dbManager.dbPool.read { db in
            try SituationChatViewModel.persistedMessageCount(db, situationID: situationID)
        }) ?? 0
    }
}

// MARK: - Chat body

private struct SituationDiscussChat: View {
    @Bindable var chatVM: SituationChatViewModel

    var body: some View {
        VStack(spacing: 8) {
            messageList
            if let err = chatVM.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Button {
                    chatVM.draftReply()
                } label: {
                    Label("Draft reply", systemImage: "square.and.pencil")
                }
                .buttonStyle(.bordered)
                .disabled(chatVM.isStreaming)
                .help("Ask the secretary for a ready-to-send reply in your voice")
                Spacer()
            }
            ChatInput(
                text: $chatVM.inputText,
                isStreaming: chatVM.isStreaming,
                onSend: { chatVM.send() },
                onStop: { chatVM.cancelStream() },
                placeholder: "Discuss this situation with the secretary…"
            )
        }
    }

    private var messageList: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            if chatVM.messages.isEmpty {
                Text("Ask anything about this situation, or hit Draft reply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            }
            ForEach(chatVM.messages) { msg in
                bubble(msg)
            }
        }
    }

    @ViewBuilder
    private func bubble(_ msg: ChatMessage) -> some View {
        switch msg.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(msg.text)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
            }
        case .assistant:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkle")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 9)
                VStack(alignment: .trailing, spacing: 4) {
                    Group {
                        if msg.text.isEmpty && msg.isStreaming {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("Thinking…").foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                        } else {
                            MarkdownText(text: msg.text)
                                .font(.subheadline)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !msg.isStreaming && !msg.text.isEmpty {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(msg.text, forType: .string)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Copy to paste into Slack")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
            }
        case .system:
            Text(msg.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
```

- [ ] **Step 2: Wire into `SituationReviewPane`**

Add `@Environment(AppState.self) private var appState` to `SituationReviewPane`, and in the scroll content, after `memberSignalsSection`, add:

```swift
                    if let dbManager = appState.databaseManager {
                        SituationDiscussSection(
                            situation: situation,
                            memberSignals: memberSignals,
                            dbManager: dbManager
                        )
                    }
```

The pane's existing `.id(situation.id)` already resets the section's `@State` (expansion + VM) when the selection changes — no extra plumbing.

- [ ] **Step 3: Verify**

```bash
cd WatchtowerDesktop && swift build > /tmp/t6-build.log 2>&1; echo "build=$?"
swift test > /tmp/t6-test.log 2>&1; echo "test=$?"
cd .. && make lint-swift > /tmp/t6-lint.log 2>&1; echo "lint=$?"
```
Expected: all 0.

- [ ] **Step 4: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Dashboard/SituationDiscussSection.swift WatchtowerDesktop/Sources/Views/Dashboard/SituationReviewPane.swift
git commit -m "feat(desktop): discuss-with-secretary chat in the situation review pane"
```

---

### Task 7: Docs + final verification sweep

**Files:**
- Modify: `docs/app-guide.md` (review pane: Discuss section; Profile tab: Communication style)
- Modify: `CLAUDE.md` (Inbox Secretary feature notes: one bullet for Discuss chat + style profile + `inbox style-sample` CLI)

**Interfaces:**
- Consumes: shipped behavior from Tasks 1–6. Read `SituationDiscussSection.swift`, `SecretaryProfileView.swift`, and `SituationChatViewModel.swift` BEFORE writing — every UI claim must have a code counterpart (the app-guide feeds the chat-bot system prompt; a prior task shipped fabricated UI text and was bounced by review).

No inventory entry in this iteration: the "inert until first user action" behavior has no view-level guard test to cite, so it stays a spec note, not a locked contract.

- [ ] **Step 1: Update `docs/app-guide.md`**

In the Inbox/Feed section, after the review-pane description, document: the collapsed "Discuss with secretary" section below the member signals (message-count badge; expands to a chat; nothing is generated until you send a message or press **Draft reply**); Draft reply produces a ready-to-send reply in your voice with a **Copy** button on every secretary message; the app never posts to Slack — copy the text and use the Slack links above. In the Profile tab section: the "Communication style" editor and **Generate from my messages** button (analyzes your recent Slack messages; Generate is disabled while the editor has unsaved edits; the profile is used by Discuss drafts).

- [ ] **Step 2: Update `CLAUDE.md`**

In the Inbox Secretary feature notes, add one bullet after the dashboard/master-detail bullet, e.g.: `Discuss chat (SituationDiscussSection / SituationChatViewModel, chat_conversations context_type='situation') — collapsed per-situation secretary chat with a Draft-reply contract (owner's voice via workspace.style_profile + counterparty people_cards + register sample); style profile generated by 'watchtower inbox style-sample' (inbox.style_sample, strong tier), edited in the Profile tab (SecretaryProfileViewModel in AppState).`

- [ ] **Step 3: Full verification sweep**

```bash
go test ./... > /tmp/final-go.log 2>&1; echo "go=$?"
go vet ./... && go build ./... ; echo "vet-build=$?"
golangci-lint run ./... > /tmp/final-golint.log 2>&1; echo "golint=$?"
cd WatchtowerDesktop && swift build > /tmp/final-swift-build.log 2>&1; echo "swift-build=$?"
swift test > /tmp/final-swift-test.log 2>&1; echo "swift-test=$?"
cd .. && make lint-swift > /tmp/final-lint.log 2>&1; echo "lint=$?"
```
Expected: every echo prints 0.

- [ ] **Step 4: Commit**

```bash
git add docs/app-guide.md CLAUDE.md
git commit -m "docs: discuss chat and communication style profile in app guide and feature notes"
```

---

## After all tasks

Manual smoke is the owner's step (`make app-dev`): generate a style profile on the Profile tab, expand Discuss on a real situation, request a draft, copy it. Push to PR #29 only after the full sweep is green (push account `vadimtrunov`).
