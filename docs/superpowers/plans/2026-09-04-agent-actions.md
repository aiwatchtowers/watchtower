# Agent Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the assistant a tool registry with controlled writes — write tools that record proposals the owner approves in chat — and ship the first two write tools (`create_target`, `create_jira_issue`) on the main AI Chat and the target chat.

**Architecture:** A Go registry (`internal/tools`) owns tool definitions, proposal recording (`agent_actions`), per-tool trust and execution. `internal/mcp` mounts the registry's write tools only in a new `--chat` mode (the developer-surface server stays read-only). The Desktop generates a turn id per send, passes chat-mode flags through `watchtower ai query`, observes `agent_actions` through GRDB, renders proposal cards, and drives Approve/Reject/Retry through `watchtower actions …`.

**Tech Stack:** Go 1.25, `modernc.org/sqlite` via `database/sql`, goose migrations, `github.com/modelcontextprotocol/go-sdk/mcp` v1.6.1, `github.com/google/jsonschema-go` v0.4.3, cobra; Swift 5.10 / SwiftUI, GRDB, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-04-agent-actions-design.md`

## Global Constraints

- Every write tool call through the chat server becomes an `agent_actions` row; with trust `ask` no data table changes (AGENT-01).
- Dev mode (`watchtower mcp` without `--chat`) registers no write tool and keeps `PRAGMA query_only=ON` (AGENT-02, DEV-01 untouched).
- `External` tools can never get trust `execute` (AGENT-03).
- Only the main AI Chat and the target chat pass `--tools chat`; situation/meeting/idea/track/setup chats never do (AGENT-04).
- `Apply` runs only from `approved` or `failed`; `applied`/`rejected` are terminal (AGENT-05).
- `create_target` surfaces: `{main}` only; `create_jira_issue`: `{main, target}` (TGT-BRIEF-01 axis 3).
- The 17-kind `watchtower-action` block grammar and TGT-BRIEF-01..03 are unchanged.
- Repo docs and code comments in English. Commit after every task with the trailer:
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_015ggx8kzgd1Jrnsc3Vx46pi`.
- Inner loop: `go test ./internal/<pkg>` for Go; `cd WatchtowerDesktop && swift test --filter <TestClass>` for Swift. Never delete `WatchtowerDesktop/.build`.
- Branch: `feature/agent-actions` (already exists; the spec is committed there).

## File Structure

**Go**
- `internal/db/migrations/00062_agent_actions.sql` — `agent_actions` + `tool_trust` tables.
- `internal/db/schema.sql` — mirror of both tables (AI-prompt schema).
- `internal/db/agent_actions.go` — `AgentAction` row type, insert/get/list, conditional status transition, trust get/set.
- `internal/tools/registry.go` — `Tool`, `Registry`, `Binding`, `Call`, `Receipt`, `Propose`, `Apply`, `SetTrust`, `List`.
- `internal/tools/targets.go` — `create_target`.
- `internal/tools/jira.go` — `create_jira_issue` + `JiraIssueClient` seam.
- `internal/jira/create.go` — `CreateIssue`, `GetIssue`, `ADFDocument`, `DescriptionText`, `APIError`.
- `internal/mcp/actions.go` — `WithRegistry` option, registry adapter, `get_action`.
- `internal/mcp/jira.go` — `list_jira_projects` (read, both modes).
- `cmd/mcp.go` — `--chat --surface --conversation --turn`.
- `cmd/actions.go` — `actions list|show|approve|reject|apply|trust|tools`.
- `cmd/actions_registry.go` — `buildToolRegistry`, Jira client factory (shared by `mcp --chat`, `actions`, `jira create`).
- `cmd/jira_create.go` — `jira create`.
- `cmd/ai.go`, `internal/ai/client.go`, `internal/codex/client.go`, `internal/codex/mcp.go` — chat-mode MCP args; delete `--allowed-tools`.
- `docs/inventory/agent-actions.md`, `docs/inventory/README.md`, `docs/inventory/dev-surface.md`, `docs/inventory/targets.md`, `docs/review/review-rules.md`, `CLAUDE.md`.

**Swift** (`WatchtowerDesktop/`)
- `Sources/Database/Queries/ChatMessageQueries.swift`, `Sources/Models/ChatMessageRecord.swift`, `Sources/Database/DatabaseManager.swift` — `turn_id` column.
- `Sources/WatchtowerCore/Models/AgentAction.swift`, `Sources/WatchtowerCore/Database/Queries/AgentActionQueries.swift`.
- `Sources/WatchtowerCore/Services/Actions/ChatToolMode.swift`, `AgentToolsContract.swift`, `AgentActionFeed.swift`.
- `Sources/WatchtowerCore/Services/ClaudeService.swift`, `WatchtowerAIService.swift` — `toolMode` replaces `extraAllowedTools`.
- `Sources/ViewModels/ChatViewModel.swift`, `Sources/ViewModels/TargetChatViewModel.swift`.
- `Sources/Views/Chat/AgentActionCardView.swift`, `Sources/Views/Chat/ChatView.swift`, `Sources/Views/Targets/TargetChatView.swift`.
- `Sources/ViewModels/AssistantToolsViewModel.swift`, `Sources/Views/Settings/AssistantToolsSettingsSection.swift`, `Sources/Views/Settings/ProfileSettings.swift`.
- Tests: `Tests/Support/TestDatabase.swift` (schema), `Tests/Support/MockClaudeService.swift`, `Tests/Core/AgentActionQueriesTests.swift`, `Tests/Core/AgentActionFeedTests.swift`, `Tests/Core/AgentToolsContractTests.swift`, `Tests/Core/WatchtowerAIServiceTests.swift`, `Tests/ViewModelTests.swift`, `Tests/TargetChatViewModelTests.swift`, `Tests/AssistantToolsViewModelTests.swift`, `Tests/AgentActionCardViewTests.swift`.

---

## Phase A — Go

### Task 1: Migration, schema mirror, DB layer

**Files:**
- Create: `internal/db/migrations/00062_agent_actions.sql`
- Modify: `internal/db/schema.sql` (append after the `jira_comments` table), `internal/db/db_test.go:185`
- Create: `internal/db/agent_actions.go`, `internal/db/agent_actions_test.go`

**Interfaces:**
- Produces: `db.AgentAction`, `(*DB).InsertAgentAction(AgentAction) (int64, error)`, `(*DB).GetAgentAction(int64) (*AgentAction, error)`, `db.AgentActionFilter`, `(*DB).ListAgentActions(AgentActionFilter) ([]AgentAction, error)`, `(*DB).TransitionAgentAction(id int64, from []string, to, resultJSON, errMsg string) (bool, error)`, `(*DB).GetToolTrust(tool string) (string, error)`, `(*DB).SetToolTrust(tool, trust string) error`.

- [ ] **Step 1: Write the migration**

`internal/db/migrations/00062_agent_actions.sql`:

```sql
-- +goose Up
-- Agent actions: every write tool the assistant calls lands here as a
-- proposal first (spec docs/superpowers/specs/2026-09-04-agent-actions-design.md).
-- Rows are the approval queue AND the audit log — never deleted.
CREATE TABLE IF NOT EXISTS agent_actions (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    tool            TEXT    NOT NULL,
    external        INTEGER NOT NULL DEFAULT 0,
    args_json       TEXT    NOT NULL,
    reason          TEXT    NOT NULL DEFAULT '',
    surface         TEXT    NOT NULL DEFAULT '',
    conversation_id INTEGER NOT NULL DEFAULT 0,
    context_type    TEXT    NOT NULL DEFAULT '',
    context_id      TEXT    NOT NULL DEFAULT '',
    turn_id         TEXT    NOT NULL DEFAULT '',
    status          TEXT    NOT NULL DEFAULT 'pending'
                    CHECK(status IN ('pending','approved','rejected','applied','failed')),
    trust_at_create TEXT    NOT NULL DEFAULT 'ask' CHECK(trust_at_create IN ('ask','execute')),
    result_json     TEXT    NOT NULL DEFAULT '',
    error           TEXT    NOT NULL DEFAULT '',
    created_at      TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    decided_at      TEXT    NOT NULL DEFAULT '',
    applied_at      TEXT    NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_agent_actions_conversation ON agent_actions(conversation_id, created_at);
CREATE INDEX IF NOT EXISTS idx_agent_actions_status ON agent_actions(status);

CREATE TABLE IF NOT EXISTS tool_trust (
    tool       TEXT PRIMARY KEY,
    trust      TEXT NOT NULL CHECK(trust IN ('ask','execute')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

-- +goose Down
DROP TABLE IF EXISTS tool_trust;
DROP INDEX IF EXISTS idx_agent_actions_status;
DROP INDEX IF EXISTS idx_agent_actions_conversation;
DROP TABLE IF EXISTS agent_actions;
```

- [ ] **Step 2: Mirror into schema.sql and the table list**

Append the two `CREATE TABLE` statements (same text, without the goose markers and indexes) to the end of `internal/db/schema.sql`. In `internal/db/db_test.go` extend `expectedTables` after `"jira_comments",`:

```go
		"agent_actions", "tool_trust",
```

- [ ] **Step 3: Write the failing DB tests**

`internal/db/agent_actions_test.go`:

```go
package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestAgentActions_InsertGetList(t *testing.T) {
	database := openTestDB(t)
	defer database.Close()

	id, err := database.InsertAgentAction(AgentAction{
		Tool: "create_target", ArgsJSON: `{"text":"x"}`, Reason: "owner asked",
		Surface: "main", ConversationID: 7, TurnID: "turn-1",
	})
	require.NoError(t, err)

	got, err := database.GetAgentAction(id)
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, "pending", got.Status)
	assert.Equal(t, "ask", got.TrustAtCreate)
	assert.Equal(t, int64(7), got.ConversationID)
	assert.NotEmpty(t, got.CreatedAt)

	rows, err := database.ListAgentActions(AgentActionFilter{ConversationID: 7})
	require.NoError(t, err)
	assert.Len(t, rows, 1)

	rows, err = database.ListAgentActions(AgentActionFilter{Status: "applied"})
	require.NoError(t, err)
	assert.Empty(t, rows)

	missing, err := database.GetAgentAction(999)
	require.NoError(t, err)
	assert.Nil(t, missing)
}

func TestAgentActions_TransitionIsConditional(t *testing.T) {
	database := openTestDB(t)
	defer database.Close()
	id, err := database.InsertAgentAction(AgentAction{Tool: "create_target", ArgsJSON: `{}`})
	require.NoError(t, err)

	ok, err := database.TransitionAgentAction(id, []string{"pending"}, "approved", "", "")
	require.NoError(t, err)
	assert.True(t, ok)
	row, _ := database.GetAgentAction(id)
	assert.Equal(t, "approved", row.Status)
	assert.NotEmpty(t, row.DecidedAt)
	assert.Empty(t, row.AppliedAt)

	// A second pending→approved must not match: the row is no longer pending.
	ok, err = database.TransitionAgentAction(id, []string{"pending"}, "approved", "", "")
	require.NoError(t, err)
	assert.False(t, ok)

	ok, err = database.TransitionAgentAction(id, []string{"approved", "failed"}, "applied", `{"target_id":3}`, "")
	require.NoError(t, err)
	assert.True(t, ok)
	row, _ = database.GetAgentAction(id)
	assert.Equal(t, "applied", row.Status)
	assert.Equal(t, `{"target_id":3}`, row.ResultJSON)
	assert.NotEmpty(t, row.AppliedAt)
}

func TestToolTrust_DefaultAskAndUpsert(t *testing.T) {
	database := openTestDB(t)
	defer database.Close()

	trust, err := database.GetToolTrust("create_target")
	require.NoError(t, err)
	assert.Equal(t, "ask", trust)

	require.NoError(t, database.SetToolTrust("create_target", "execute"))
	trust, _ = database.GetToolTrust("create_target")
	assert.Equal(t, "execute", trust)

	require.NoError(t, database.SetToolTrust("create_target", "ask"))
	trust, _ = database.GetToolTrust("create_target")
	assert.Equal(t, "ask", trust)
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `go test ./internal/db/ -run 'TestAgentActions|TestToolTrust|TestAllTablesExist'`
Expected: compile error — `AgentAction` undefined.

- [ ] **Step 5: Implement the DB layer**

`internal/db/agent_actions.go`:

```go
package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// AgentAction is one row of agent_actions: a write-tool call the assistant
// made, recorded as a proposal and later decided/executed by the owner's
// Desktop through `watchtower actions …`. Rows are never deleted (audit).
type AgentAction struct {
	ID             int64
	Tool           string
	External       bool
	ArgsJSON       string
	Reason         string
	Surface        string
	ConversationID int64
	ContextType    string
	ContextID      string
	TurnID         string
	Status         string // pending | approved | rejected | applied | failed
	TrustAtCreate  string // ask | execute
	ResultJSON     string
	Error          string
	CreatedAt      string
	DecidedAt      string
	AppliedAt      string
}

// AgentActionFilter narrows ListAgentActions; zero values mean "any".
type AgentActionFilter struct {
	Status         string
	ConversationID int64
	Limit          int
}

const agentActionColumns = `id, tool, external, args_json, reason, surface, conversation_id,
	context_type, context_id, turn_id, status, trust_at_create, result_json, error,
	created_at, decided_at, applied_at`

func scanAgentAction(row interface{ Scan(dest ...any) error }) (*AgentAction, error) {
	var a AgentAction
	err := row.Scan(&a.ID, &a.Tool, &a.External, &a.ArgsJSON, &a.Reason, &a.Surface, &a.ConversationID,
		&a.ContextType, &a.ContextID, &a.TurnID, &a.Status, &a.TrustAtCreate, &a.ResultJSON, &a.Error,
		&a.CreatedAt, &a.DecidedAt, &a.AppliedAt)
	if err != nil {
		return nil, err
	}
	return &a, nil
}

// InsertAgentAction records a proposal. Status defaults to pending and
// trust_at_create to ask unless the caller sets them (the execute path
// inserts as approved).
func (db *DB) InsertAgentAction(a AgentAction) (int64, error) {
	if a.Status == "" {
		a.Status = "pending"
	}
	if a.TrustAtCreate == "" {
		a.TrustAtCreate = "ask"
	}
	res, err := db.Exec(`INSERT INTO agent_actions
		(tool, external, args_json, reason, surface, conversation_id, context_type, context_id,
		 turn_id, status, trust_at_create)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		a.Tool, a.External, a.ArgsJSON, a.Reason, a.Surface, a.ConversationID, a.ContextType, a.ContextID,
		a.TurnID, a.Status, a.TrustAtCreate)
	if err != nil {
		return 0, fmt.Errorf("inserting agent action: %w", err)
	}
	return res.LastInsertId()
}

// GetAgentAction returns the row or nil when it does not exist.
func (db *DB) GetAgentAction(id int64) (*AgentAction, error) {
	a, err := scanAgentAction(db.QueryRow(`SELECT `+agentActionColumns+` FROM agent_actions WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("getting agent action %d: %w", id, err)
	}
	return a, nil
}

// ListAgentActions returns rows oldest-first, optionally filtered.
func (db *DB) ListAgentActions(f AgentActionFilter) ([]AgentAction, error) {
	var where []string
	var args []any
	if f.Status != "" {
		where = append(where, "status = ?")
		args = append(args, f.Status)
	}
	if f.ConversationID != 0 {
		where = append(where, "conversation_id = ?")
		args = append(args, f.ConversationID)
	}
	q := `SELECT ` + agentActionColumns + ` FROM agent_actions`
	if len(where) > 0 {
		q += " WHERE " + strings.Join(where, " AND ")
	}
	q += " ORDER BY created_at ASC, id ASC"
	if f.Limit > 0 {
		q += fmt.Sprintf(" LIMIT %d", f.Limit)
	}
	rows, err := db.Query(q, args...)
	if err != nil {
		return nil, fmt.Errorf("listing agent actions: %w", err)
	}
	defer rows.Close()
	var out []AgentAction
	for rows.Next() {
		a, err := scanAgentAction(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning agent action: %w", err)
		}
		out = append(out, *a)
	}
	return out, rows.Err()
}

// TransitionAgentAction moves a row to `to` only when its current status is
// one of `from`; it returns false when the row was in another state (or does
// not exist), which is how callers detect a lost race or a bad transition.
// decided_at is stamped for approved/rejected, applied_at for applied/failed.
func (db *DB) TransitionAgentAction(id int64, from []string, to, resultJSON, errMsg string) (bool, error) {
	if len(from) == 0 {
		return false, fmt.Errorf("transition to %s: no source statuses", to)
	}
	now := time.Now().UTC().Format("2006-01-02T15:04:05Z")
	decided, applied := "", ""
	switch to {
	case "approved", "rejected":
		decided = now
	case "applied", "failed":
		applied = now
	}
	placeholders := strings.TrimSuffix(strings.Repeat("?,", len(from)), ",")
	args := []any{to, resultJSON, errMsg, decided, decided, applied, applied, id}
	for _, s := range from {
		args = append(args, s)
	}
	res, err := db.Exec(`UPDATE agent_actions SET status = ?, result_json = ?, error = ?,
		decided_at = CASE WHEN ? != '' THEN ? ELSE decided_at END,
		applied_at = CASE WHEN ? != '' THEN ? ELSE applied_at END
		WHERE id = ? AND status IN (`+placeholders+`)`, args...)
	if err != nil {
		return false, fmt.Errorf("transitioning agent action %d to %s: %w", id, to, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, err
	}
	return n > 0, nil
}

// GetToolTrust returns "ask" when no row exists.
func (db *DB) GetToolTrust(tool string) (string, error) {
	var trust string
	err := db.QueryRow(`SELECT trust FROM tool_trust WHERE tool = ?`, tool).Scan(&trust)
	if errors.Is(err, sql.ErrNoRows) {
		return "ask", nil
	}
	if err != nil {
		return "", fmt.Errorf("getting trust for %s: %w", tool, err)
	}
	return trust, nil
}

// SetToolTrust upserts the trust level. The registry, not this function,
// enforces the external-never-execute rule (AGENT-03).
func (db *DB) SetToolTrust(tool, trust string) error {
	_, err := db.Exec(`INSERT INTO tool_trust (tool, trust, updated_at)
		VALUES (?, ?, strftime('%Y-%m-%dT%H:%M:%SZ','now'))
		ON CONFLICT(tool) DO UPDATE SET trust = excluded.trust, updated_at = excluded.updated_at`, tool, trust)
	if err != nil {
		return fmt.Errorf("setting trust for %s: %w", tool, err)
	}
	return nil
}
```

- [ ] **Step 6: Run tests and regenerate the schema golden**

Run: `go test ./internal/db/ -run 'TestAgentActions|TestToolTrust|TestAllTablesExist'` — Expected: PASS.
Run: `go test ./internal/db/ -run TestSchemaGolden -update && go test ./internal/db/` — Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add internal/db/migrations/00062_agent_actions.sql internal/db/schema.sql internal/db/agent_actions.go internal/db/agent_actions_test.go internal/db/db_test.go internal/db/testdata
git commit -m "feat(db): agent_actions + tool_trust tables and accessors (migration 00062)"
```

(Confirm the golden snapshot path with `git status` before adding; it lives wherever `TestSchemaGolden -update` wrote it.)

---

### Task 2: Tool registry core (`internal/tools`)

**Files:**
- Create: `internal/tools/registry.go`, `internal/tools/registry_test.go`

**Interfaces:**
- Consumes: Task 1's DB accessors.
- Produces:
  ```go
  type Access string  // AccessRead = "read", AccessWrite = "write"
  type Trust string   // TrustAsk = "ask", TrustExecute = "execute"
  type Binding struct { Surface string; ConversationID int64; ContextType, ContextID, TurnID string }
  type Call struct { ActionID int64; Args json.RawMessage; Binding Binding }
  type Tool struct {
      Name, Description string
      InputSchema *jsonschema.Schema
      Access Access
      External bool
      Surfaces []string
      Validate func(ctx context.Context, d *db.DB, args json.RawMessage) error
      Execute  func(ctx context.Context, d *db.DB, call Call) (any, error)
  }
  type Receipt struct { ActionID int64; Status, Tool, Message string; Result any; Error string }
  type ValidationError struct{ Msg string }   // Error() returns Msg
  func New(d *db.DB) *Registry
  func (r *Registry) Register(t *Tool) error
  func (r *Registry) Get(name string) (*Tool, bool)
  func (r *Registry) List(surface string) []*Tool
  func (r *Registry) Propose(ctx, name string, args json.RawMessage, b Binding) (Receipt, error)
  func (r *Registry) Apply(ctx, id int64) (*db.AgentAction, error)
  func (r *Registry) Trust(name string) (Trust, error)
  func (r *Registry) SetTrust(name string, t Trust) error
  func RunDirect(ctx, d *db.DB, t *Tool, args json.RawMessage) (any, error)  // Validate + Execute with ActionID 0 (CLI use)
  var ErrUnknownTool, ErrNotWritable, ErrExternalExecute, ErrBadTransition, ErrNotFound error
  ```

- [ ] **Step 1: Write the failing registry tests**

`internal/tools/registry_test.go`:

```go
package tools

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"testing"

	"github.com/google/jsonschema-go/jsonschema"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

type echoArgs struct {
	Text   string `json:"text"`
	Reason string `json:"reason"`
}

// newEchoTool is a write tool whose Execute records what it was called with.
func newEchoTool(t *testing.T, external bool, executed *[]Call) *Tool {
	t.Helper()
	schema, err := jsonschema.For[echoArgs](nil)
	require.NoError(t, err)
	return &Tool{
		Name: "echo", Description: "test tool", InputSchema: schema,
		Access: AccessWrite, External: external, Surfaces: []string{"main"},
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a echoArgs
			if err := json.Unmarshal(raw, &a); err != nil {
				return &ValidationError{Msg: "bad json"}
			}
			if a.Text == "" {
				return &ValidationError{Msg: "text is required"}
			}
			return nil
		},
		Execute: func(_ context.Context, _ *db.DB, call Call) (any, error) {
			*executed = append(*executed, call)
			return map[string]any{"echoed": true}, nil
		},
	}
}

func openDB(t *testing.T) *db.DB {
	t.Helper()
	database, err := db.Open(filepath.Join(t.TempDir(), "t.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	return database
}

func TestPropose_RecordsPendingAndNeverExecutes(t *testing.T) {
	database := openDB(t)
	var executed []Call
	reg := New(database)
	require.NoError(t, reg.Register(newEchoTool(t, false, &executed)))

	rc, err := reg.Propose(context.Background(), "echo",
		json.RawMessage(`{"text":"hi","reason":"because"}`),
		Binding{Surface: "main", ConversationID: 4, TurnID: "t1"})
	require.NoError(t, err)
	assert.Equal(t, "pending", rc.Status)
	assert.Contains(t, rc.Message, "do not claim it is done")
	assert.Empty(t, executed, "a write tool must not execute on propose (AGENT-01)")

	row, err := database.GetAgentAction(rc.ActionID)
	require.NoError(t, err)
	assert.Equal(t, "because", row.Reason)
	assert.Equal(t, "main", row.Surface)
	assert.Equal(t, int64(4), row.ConversationID)
	assert.Equal(t, "t1", row.TurnID)
}

func TestPropose_ValidationErrorWritesNoRow(t *testing.T) {
	database := openDB(t)
	var executed []Call
	reg := New(database)
	require.NoError(t, reg.Register(newEchoTool(t, false, &executed)))

	_, err := reg.Propose(context.Background(), "echo", json.RawMessage(`{"reason":"x"}`), Binding{})
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	rows, _ := database.ListAgentActions(db.AgentActionFilter{})
	assert.Empty(t, rows)
}

func TestPropose_UnknownOrReadToolRejected(t *testing.T) {
	reg := New(openDB(t))
	_, err := reg.Propose(context.Background(), "nope", json.RawMessage(`{}`), Binding{})
	assert.ErrorIs(t, err, ErrUnknownTool)
}

func TestApply_ExecutesOnceAndRecordsResult(t *testing.T) {
	database := openDB(t)
	var executed []Call
	reg := New(database)
	require.NoError(t, reg.Register(newEchoTool(t, false, &executed)))
	rc, err := reg.Propose(context.Background(), "echo", json.RawMessage(`{"text":"hi","reason":"r"}`), Binding{})
	require.NoError(t, err)

	// pending is not applicable — the owner has to approve first.
	_, err = reg.Apply(context.Background(), rc.ActionID)
	assert.ErrorIs(t, err, ErrBadTransition)

	ok, err := database.TransitionAgentAction(rc.ActionID, []string{"pending"}, "approved", "", "")
	require.NoError(t, err)
	require.True(t, ok)

	row, err := reg.Apply(context.Background(), rc.ActionID)
	require.NoError(t, err)
	assert.Equal(t, "applied", row.Status)
	assert.JSONEq(t, `{"echoed":true}`, row.ResultJSON)
	assert.Len(t, executed, 1)
	assert.Equal(t, rc.ActionID, executed[0].ActionID)

	// AGENT-05: applied is terminal.
	_, err = reg.Apply(context.Background(), rc.ActionID)
	assert.ErrorIs(t, err, ErrBadTransition)
	assert.Len(t, executed, 1)
}

func TestApply_FailureLandsFailedAndIsRetriable(t *testing.T) {
	database := openDB(t)
	reg := New(database)
	calls := 0
	schema, _ := jsonschema.For[echoArgs](nil)
	require.NoError(t, reg.Register(&Tool{
		Name: "flaky", Description: "x", InputSchema: schema, Access: AccessWrite,
		Validate: func(context.Context, *db.DB, json.RawMessage) error { return nil },
		Execute: func(context.Context, *db.DB, Call) (any, error) {
			calls++
			if calls == 1 {
				return nil, errors.New("boom")
			}
			return map[string]any{"ok": true}, nil
		},
	}))
	rc, _ := reg.Propose(context.Background(), "flaky", json.RawMessage(`{"reason":"r"}`), Binding{})
	_, _ = database.TransitionAgentAction(rc.ActionID, []string{"pending"}, "approved", "", "")

	row, err := reg.Apply(context.Background(), rc.ActionID)
	require.NoError(t, err)
	assert.Equal(t, "failed", row.Status)
	assert.Equal(t, "boom", row.Error)

	row, err = reg.Apply(context.Background(), rc.ActionID)
	require.NoError(t, err)
	assert.Equal(t, "applied", row.Status)
	assert.Empty(t, row.Error)
}

func TestAgent03_ExternalToolCannotBeExecuteTrust(t *testing.T) {
	database := openDB(t)
	var executed []Call
	reg := New(database)
	require.NoError(t, reg.Register(newEchoTool(t, true, &executed)))

	err := reg.SetTrust("echo", TrustExecute)
	assert.ErrorIs(t, err, ErrExternalExecute)
	trust, _ := reg.Trust("echo")
	assert.Equal(t, TrustAsk, trust)
	assert.ErrorIs(t, reg.SetTrust("nope", TrustAsk), ErrUnknownTool)
}

func TestPropose_ExecuteTrustAppliesInline(t *testing.T) {
	database := openDB(t)
	var executed []Call
	reg := New(database)
	require.NoError(t, reg.Register(newEchoTool(t, false, &executed)))
	require.NoError(t, reg.SetTrust("echo", TrustExecute))

	rc, err := reg.Propose(context.Background(), "echo", json.RawMessage(`{"text":"hi","reason":"r"}`), Binding{})
	require.NoError(t, err)
	assert.Equal(t, "applied", rc.Status)
	assert.Len(t, executed, 1)
	row, _ := database.GetAgentAction(rc.ActionID)
	assert.Equal(t, "execute", row.TrustAtCreate)
	assert.NotEmpty(t, row.DecidedAt)
}

func TestList_FiltersBySurface(t *testing.T) {
	reg := New(openDB(t))
	var executed []Call
	require.NoError(t, reg.Register(newEchoTool(t, false, &executed)))
	assert.Len(t, reg.List("main"), 1)
	assert.Empty(t, reg.List("target"))
	assert.Error(t, reg.Register(newEchoTool(t, false, &executed)), "duplicate name")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/tools/`
Expected: FAIL — package does not exist / undefined identifiers.

- [ ] **Step 3: Implement the registry**

`internal/tools/registry.go`:

```go
// Package tools is the assistant's tool registry — the single catalog of
// what the assistant can do, with per-tool access class and trust.
//
// Controlled writes (spec §6): a write tool called through Propose never
// reaches its Execute; the registry records an agent_actions row and hands
// the model a receipt. Execution happens only through Apply, which the
// Desktop drives after the owner approved (or inline when the owner granted
// the tool "execute" trust). MCP is one adapter over this package; the Go
// tool loop for HTTP providers (runtime B) will be the second.
package tools

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"

	"github.com/google/jsonschema-go/jsonschema"

	"watchtower/internal/db"
)

type Access string

const (
	AccessRead  Access = "read"
	AccessWrite Access = "write"
)

type Trust string

const (
	TrustAsk     Trust = "ask"
	TrustExecute Trust = "execute"
)

// Binding is where a proposal came from: the chat surface, conversation and
// turn the Desktop passed to the chat-mode server.
type Binding struct {
	Surface        string
	ConversationID int64
	ContextType    string
	ContextID      string
	TurnID         string
}

// Call is what Execute receives: the recorded row id (0 for RunDirect), the
// raw arguments and the binding.
type Call struct {
	ActionID int64
	Args     json.RawMessage
	Binding  Binding
}

// Tool is one registry entry.
type Tool struct {
	Name        string
	Description string
	InputSchema *jsonschema.Schema
	Access      Access
	// External marks writes that leave this machine (Jira). Such a tool can
	// never be granted execute trust (AGENT-03).
	External bool
	// Surfaces lists the chat surfaces that may see the tool; empty = every
	// surface.
	Surfaces []string
	// Validate runs semantic checks beyond the schema; return *ValidationError
	// for a message the model should see verbatim.
	Validate func(ctx context.Context, d *db.DB, args json.RawMessage) error
	// Execute performs the write. Only Apply (and RunDirect) call it.
	Execute func(ctx context.Context, d *db.DB, call Call) (any, error)
}

// Receipt is what the model gets back from a write-tool call.
type Receipt struct {
	ActionID int64  `json:"action_id"`
	Status   string `json:"status"`
	Tool     string `json:"tool"`
	Message  string `json:"message"`
	Result   any    `json:"result,omitempty"`
	Error    string `json:"error,omitempty"`
}

// ValidationError carries a model-facing message; no row is written for it.
type ValidationError struct{ Msg string }

func (e *ValidationError) Error() string { return e.Msg }

var (
	ErrUnknownTool     = errors.New("unknown tool")
	ErrNotWritable     = errors.New("tool is not a write tool")
	ErrExternalExecute = errors.New("an external tool can never be trusted to execute without approval")
	ErrBadTransition   = errors.New("action is not in an applicable state")
	ErrNotFound        = errors.New("action not found")
)

// Registry holds the tools and the DB the proposal rows live in.
type Registry struct {
	db    *db.DB
	tools map[string]*Tool
	order []string
}

func New(d *db.DB) *Registry {
	return &Registry{db: d, tools: map[string]*Tool{}}
}

// Register adds a tool; names are unique and write tools need a schema.
func (r *Registry) Register(t *Tool) error {
	if t == nil || strings.TrimSpace(t.Name) == "" {
		return errors.New("register: tool has no name")
	}
	if _, dup := r.tools[t.Name]; dup {
		return fmt.Errorf("register: duplicate tool %q", t.Name)
	}
	if t.Access == AccessWrite && (t.InputSchema == nil || t.Validate == nil || t.Execute == nil) {
		return fmt.Errorf("register: write tool %q needs InputSchema, Validate and Execute", t.Name)
	}
	r.tools[t.Name] = t
	r.order = append(r.order, t.Name)
	return nil
}

func (r *Registry) Get(name string) (*Tool, bool) {
	t, ok := r.tools[name]
	return t, ok
}

// List returns the tools visible on surface, in registration order.
func (r *Registry) List(surface string) []*Tool {
	var out []*Tool
	for _, name := range r.order {
		t := r.tools[name]
		if len(t.Surfaces) == 0 || slices.Contains(t.Surfaces, surface) {
			out = append(out, t)
		}
	}
	return out
}

// Trust returns the tool's trust level ("ask" when never set).
func (r *Registry) Trust(name string) (Trust, error) {
	if _, ok := r.tools[name]; !ok {
		return "", ErrUnknownTool
	}
	s, err := r.db.GetToolTrust(name)
	if err != nil {
		return "", err
	}
	return Trust(s), nil
}

// SetTrust changes the trust level; execute is refused for External tools.
func (r *Registry) SetTrust(name string, trust Trust) error {
	t, ok := r.tools[name]
	if !ok {
		return ErrUnknownTool
	}
	if trust != TrustAsk && trust != TrustExecute {
		return fmt.Errorf("invalid trust %q", trust)
	}
	if t.External && trust == TrustExecute {
		return ErrExternalExecute
	}
	return r.db.SetToolTrust(name, string(trust))
}

// reasonOf extracts the mandatory "reason" argument every write tool carries.
func reasonOf(args json.RawMessage) string {
	var r struct {
		Reason string `json:"reason"`
	}
	_ = json.Unmarshal(args, &r)
	return strings.TrimSpace(r.Reason)
}

// Propose validates a write-tool call and records it. With trust "ask" the
// row is pending and nothing executes; with "execute" the row is inserted as
// approved and applied inline, so the model sees the result immediately.
func (r *Registry) Propose(ctx context.Context, name string, args json.RawMessage, b Binding) (Receipt, error) {
	t, ok := r.tools[name]
	if !ok {
		return Receipt{}, ErrUnknownTool
	}
	if t.Access != AccessWrite {
		return Receipt{}, ErrNotWritable
	}
	if len(args) == 0 {
		args = json.RawMessage(`{}`)
	}
	if !json.Valid(args) {
		return Receipt{}, &ValidationError{Msg: "arguments are not valid JSON"}
	}
	if err := t.Validate(ctx, r.db, args); err != nil {
		return Receipt{}, err
	}
	reason := reasonOf(args)
	if reason == "" {
		return Receipt{}, &ValidationError{Msg: `"reason" is required: say why you propose this`}
	}
	trust, err := r.Trust(name)
	if err != nil {
		return Receipt{}, err
	}
	row := db.AgentAction{
		Tool: name, External: t.External, ArgsJSON: string(args), Reason: reason,
		Surface: b.Surface, ConversationID: b.ConversationID,
		ContextType: b.ContextType, ContextID: b.ContextID, TurnID: b.TurnID,
		Status: "pending", TrustAtCreate: string(trust),
	}
	if trust == TrustExecute {
		row.Status = "approved"
	}
	id, err := r.db.InsertAgentAction(row)
	if err != nil {
		return Receipt{}, err
	}
	if trust == TrustExecute {
		// Stamp decided_at the way an owner approval would.
		if _, err := r.db.TransitionAgentAction(id, []string{"approved"}, "approved", "", ""); err != nil {
			return Receipt{}, err
		}
		applied, err := r.Apply(ctx, id)
		if err != nil {
			return Receipt{}, err
		}
		return receiptFor(applied), nil
	}
	return Receipt{
		ActionID: id, Status: "pending", Tool: name,
		Message: fmt.Sprintf("Proposal #%d recorded (%s). The owner must approve it in this chat before "+
			"anything happens — tell the owner it awaits their approval and do not claim it is done.", id, name),
	}, nil
}

// Apply executes an approved (or previously failed) row exactly once and
// records applied/failed. applied and rejected are terminal (AGENT-05).
func (r *Registry) Apply(ctx context.Context, id int64) (*db.AgentAction, error) {
	row, err := r.db.GetAgentAction(id)
	if err != nil {
		return nil, err
	}
	if row == nil {
		return nil, ErrNotFound
	}
	if row.Status != "approved" && row.Status != "failed" {
		return nil, fmt.Errorf("%w: #%d is %s", ErrBadTransition, id, row.Status)
	}
	from := []string{"approved", "failed"}
	t, ok := r.tools[row.Tool]
	if !ok {
		_, _ = r.db.TransitionAgentAction(id, from, "failed", "", "unknown tool "+row.Tool)
		return r.db.GetAgentAction(id)
	}
	call := Call{ActionID: id, Args: json.RawMessage(row.ArgsJSON), Binding: Binding{
		Surface: row.Surface, ConversationID: row.ConversationID,
		ContextType: row.ContextType, ContextID: row.ContextID, TurnID: row.TurnID,
	}}
	result, execErr := t.Execute(ctx, r.db, call)
	if execErr != nil {
		if _, err := r.db.TransitionAgentAction(id, from, "failed", "", execErr.Error()); err != nil {
			return nil, err
		}
		return r.db.GetAgentAction(id)
	}
	resultJSON, err := json.Marshal(result)
	if err != nil {
		resultJSON = []byte("{}")
	}
	if _, err := r.db.TransitionAgentAction(id, from, "applied", string(resultJSON), ""); err != nil {
		return nil, err
	}
	return r.db.GetAgentAction(id)
}

func receiptFor(row *db.AgentAction) Receipt {
	rc := Receipt{ActionID: row.ID, Status: row.Status, Tool: row.Tool}
	switch row.Status {
	case "applied":
		var result any
		_ = json.Unmarshal([]byte(row.ResultJSON), &result)
		rc.Result = result
		rc.Message = fmt.Sprintf("Action #%d executed (%s).", row.ID, row.Tool)
	default:
		rc.Error = row.Error
		rc.Message = fmt.Sprintf("Action #%d failed (%s): %s", row.ID, row.Tool, row.Error)
	}
	return rc
}

// RunDirect validates and executes a tool outside the proposal flow — the
// CLI face (`watchtower jira create`) for humans and tests. ActionID is 0.
func RunDirect(ctx context.Context, d *db.DB, t *Tool, args json.RawMessage) (any, error) {
	if err := t.Validate(ctx, d, args); err != nil {
		return nil, err
	}
	return t.Execute(ctx, d, Call{Args: args})
}
```

- [ ] **Step 4: Tidy the module and run tests**

Run: `go mod tidy && go test ./internal/tools/`
Expected: PASS (`github.com/google/jsonschema-go` moves from indirect to direct in `go.mod`).

- [ ] **Step 5: Commit**

```bash
git add go.mod go.sum internal/tools/
git commit -m "feat(tools): tool registry with proposal rows, per-tool trust and apply-once execution"
```

---

### Task 3: `create_target` tool

**Files:**
- Create: `internal/tools/targets.go`, `internal/tools/targets_test.go`

**Interfaces:**
- Produces: `tools.NewCreateTarget() *Tool` (name `create_target`, surfaces `{"main"}`, not external).

- [ ] **Step 1: Write the failing tests**

`internal/tools/targets_test.go`:

```go
package tools

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func TestCreateTarget_ValidateRejectsBadInput(t *testing.T) {
	database := openDB(t)
	tool := NewCreateTarget()
	cases := map[string]string{
		"empty text":    `{"text":"  ","reason":"r"}`,
		"unknown field": `{"text":"x","reason":"r","bogus":1}`,
		"bad priority":  `{"text":"x","reason":"r","priority":"urgent"}`,
		"bad due":       `{"text":"x","reason":"r","due":"tomorrow"}`,
		"long text":     `{"text":"` + string(make([]byte, 201)) + `","reason":"r"}`,
	}
	for name, raw := range cases {
		err := tool.Validate(context.Background(), database, json.RawMessage(raw))
		var verr *ValidationError
		assert.ErrorAs(t, err, &verr, name)
	}
	assert.NoError(t, tool.Validate(context.Background(), database,
		json.RawMessage(`{"text":"Call Vasya","reason":"r","due":"2026-09-05T16:00","priority":"high"}`)))
	assert.NoError(t, tool.Validate(context.Background(), database,
		json.RawMessage(`{"text":"Renew cert","reason":"r","due":"2026-09-12"}`)))
}

func TestCreateTarget_ExecuteMatchesRemindShape(t *testing.T) {
	database := openDB(t)
	tool := NewCreateTarget()
	out, err := tool.Execute(context.Background(), database, Call{
		ActionID: 42,
		Args:     json.RawMessage(`{"text":"Call Vasya","intent":"agree the date","reason":"r","due":"2026-09-05T16:00","priority":"high"}`),
	})
	require.NoError(t, err)
	res := out.(map[string]any)
	id := res["target_id"].(int64)

	row, err := database.GetTarget(int(id))
	require.NoError(t, err)
	assert.Equal(t, "Call Vasya", row.Text)
	assert.Equal(t, "agree the date", row.Intent)
	assert.Equal(t, "day", row.Level)
	assert.Equal(t, "todo", row.Status)
	assert.Equal(t, "high", row.Priority)
	assert.Equal(t, "mine", row.Ownership)
	assert.Equal(t, "2026-09-05T16:00", row.DueDate)
	assert.Equal(t, "chat", row.SourceType)
	assert.Equal(t, "42", row.SourceID)
	assert.Equal(t, row.PeriodStart, row.PeriodEnd)
}

func TestCreateTarget_Registration(t *testing.T) {
	tool := NewCreateTarget()
	assert.Equal(t, "create_target", tool.Name)
	assert.Equal(t, AccessWrite, tool.Access)
	assert.False(t, tool.External)
	assert.Equal(t, []string{"main"}, tool.Surfaces)
	require.NotNil(t, tool.InputSchema)
	_ = db.Target{} // keeps the import honest if GetTarget's name changes
}
```

Check the getter name first: `grep -n 'func (db \*DB) GetTarget' internal/db/targets.go` — if it is `GetTargetByID`, use that in the test.

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/tools/ -run TestCreateTarget`
Expected: FAIL — `NewCreateTarget` undefined.

- [ ] **Step 3: Implement**

`internal/tools/targets.go`:

```go
package tools

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/google/jsonschema-go/jsonschema"

	"watchtower/internal/db"
)

type createTargetArgs struct {
	Text     string `json:"text" jsonschema:"the task title, imperative, at most 200 characters"`
	Intent   string `json:"intent,omitempty" jsonschema:"why it matters / the desired outcome"`
	Due      string `json:"due,omitempty" jsonschema:"owner-local due date: YYYY-MM-DD or YYYY-MM-DDTHH:MM; a reminder is a task with a due"`
	Priority string `json:"priority,omitempty" jsonschema:"high | medium | low (default medium)"`
	Reason   string `json:"reason" jsonschema:"one sentence: why you propose this, shown to the owner"`
}

var dueDateRE = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2})?$`)

// decodeStrict decodes args into v rejecting unknown fields — the schema
// check every write tool applies before its own semantic rules.
func decodeStrict(raw json.RawMessage, v any) error {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		return &ValidationError{Msg: "invalid arguments: " + err.Error()}
	}
	return nil
}

func validDue(due string) bool {
	if due == "" {
		return true
	}
	if !dueDateRE.MatchString(due) {
		return false
	}
	layout := "2006-01-02"
	if len(due) > len(layout) {
		layout = "2006-01-02T15:04"
	}
	_, err := time.Parse(layout, due)
	return err == nil
}

// NewCreateTarget builds the create_target write tool: a new top-level task
// (a reminder is a task with a due date) in the `watchtower remind` shape.
// Main chat only — the target chat's mandate forbids creating work outside
// the target's vertical line (TGT-BRIEF-01).
func NewCreateTarget() *Tool {
	schema, err := jsonschema.For[createTargetArgs](nil)
	if err != nil {
		panic("create_target schema: " + err.Error())
	}
	return &Tool{
		Name: "create_target",
		Description: "Propose a new top-level task (or reminder: a task with a due date) in the owner's Watchtower " +
			"task list. The owner approves it in the chat before it is created. Use it when the owner asks to " +
			"remember, remind, or track something as a task.",
		InputSchema: schema,
		Access:      AccessWrite,
		Surfaces:    []string{"main"},
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a createTargetArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			text := strings.TrimSpace(a.Text)
			switch {
			case text == "":
				return &ValidationError{Msg: "text is required"}
			case len([]rune(text)) > 200:
				return &ValidationError{Msg: "text must be at most 200 characters"}
			case a.Priority != "" && a.Priority != "high" && a.Priority != "medium" && a.Priority != "low":
				return &ValidationError{Msg: "priority must be high, medium or low"}
			case !validDue(a.Due):
				return &ValidationError{Msg: "due must be YYYY-MM-DD or YYYY-MM-DDTHH:MM"}
			}
			return nil
		},
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a createTargetArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding create_target args: %w", err)
			}
			priority := a.Priority
			if priority == "" {
				priority = "medium"
			}
			today := time.Now().UTC().Format("2006-01-02")
			id, err := d.CreateTarget(db.Target{
				Text:        strings.TrimSpace(a.Text),
				Intent:      strings.TrimSpace(a.Intent),
				Level:       "day",
				PeriodStart: today,
				PeriodEnd:   today,
				Status:      "todo",
				Priority:    priority,
				Ownership:   "mine",
				DueDate:     a.Due,
				SourceType:  "chat",
				SourceID:    strconv.FormatInt(call.ActionID, 10),
			})
			if err != nil {
				return nil, fmt.Errorf("creating target: %w", err)
			}
			return map[string]any{"target_id": id}, nil
		},
	}
}
```

- [ ] **Step 4: Run tests**

Run: `go test ./internal/tools/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/tools/targets.go internal/tools/targets_test.go
git commit -m "feat(tools): create_target write tool in the remind row shape"
```

---

### Task 4: Jira client — `CreateIssue`, `GetIssue`, ADF

**Files:**
- Create: `internal/jira/create.go`, `internal/jira/create_test.go`

**Interfaces:**
- Produces:
  ```go
  type CreateIssueRequest struct { ProjectKey, IssueType, Summary, Description string; Labels []string; Priority string }
  type CreatedIssue struct { ID, Key, Self string }
  type APIError struct { Status int; Message string }   // Error() = "jira: <status>: <message>"
  func (c *Client) CreateIssue(ctx, req CreateIssueRequest) (CreatedIssue, error)
  func (c *Client) GetIssue(ctx, key string) (Issue, error)
  func ADFDocument(text string) map[string]any
  func DescriptionText(desc interface{}) string
  ```

- [ ] **Step 1: Write the failing tests**

`internal/jira/create_test.go`:

```go
package jira

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestCreateIssue_PostsFieldsWithADF(t *testing.T) {
	var got map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, http.MethodPost, r.Method)
		assert.Equal(t, "/rest/api/3/issue", r.URL.Path)
		assert.Equal(t, "application/json", r.Header.Get("Content-Type"))
		body, _ := io.ReadAll(r.Body)
		require.NoError(t, json.Unmarshal(body, &got))
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"id":"10001","key":"ABC-7","self":"https://x/rest/api/3/issue/10001"}`))
	}))
	defer srv.Close()

	c := makeTestClient(t, srv.URL)
	created, err := c.CreateIssue(context.Background(), CreateIssueRequest{
		ProjectKey: "ABC", IssueType: "Task", Summary: "Fix login",
		Description: "First paragraph.\n\nSecond one.", Labels: []string{"backend"}, Priority: "High",
	})
	require.NoError(t, err)
	assert.Equal(t, "ABC-7", created.Key)

	fields := got["fields"].(map[string]any)
	assert.Equal(t, "ABC", fields["project"].(map[string]any)["key"])
	assert.Equal(t, "Task", fields["issuetype"].(map[string]any)["name"])
	assert.Equal(t, "Fix login", fields["summary"])
	assert.Equal(t, "High", fields["priority"].(map[string]any)["name"])
	assert.Equal(t, []any{"backend"}, fields["labels"])
	desc := fields["description"].(map[string]any)
	assert.Equal(t, "doc", desc["type"])
	assert.Len(t, desc["content"].([]any), 2)
}

func TestCreateIssue_OmitsEmptyOptionalFields(t *testing.T) {
	var got map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(body, &got)
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"id":"1","key":"ABC-8"}`))
	}))
	defer srv.Close()
	_, err := makeTestClient(t, srv.URL).CreateIssue(context.Background(),
		CreateIssueRequest{ProjectKey: "ABC", IssueType: "Bug", Summary: "s"})
	require.NoError(t, err)
	fields := got["fields"].(map[string]any)
	_, hasDesc := fields["description"]
	_, hasPrio := fields["priority"]
	_, hasLabels := fields["labels"]
	assert.False(t, hasDesc)
	assert.False(t, hasPrio)
	assert.False(t, hasLabels)
}

func TestCreateIssue_MapsJiraErrors(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"errorMessages":[],"errors":{"issuetype":"The issue type selected is invalid."}}`))
	}))
	defer srv.Close()
	_, err := makeTestClient(t, srv.URL).CreateIssue(context.Background(),
		CreateIssueRequest{ProjectKey: "ABC", IssueType: "Nope", Summary: "s"})
	var apiErr *APIError
	require.ErrorAs(t, err, &apiErr)
	assert.Equal(t, 400, apiErr.Status)
	assert.Contains(t, apiErr.Message, "issuetype: The issue type selected is invalid.")
}

func TestCreateIssue_ForbiddenIsAPIError403(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"errorMessages":["You do not have permission to create issues in this project."],"errors":{}}`))
	}))
	defer srv.Close()
	_, err := makeTestClient(t, srv.URL).CreateIssue(context.Background(),
		CreateIssueRequest{ProjectKey: "ABC", IssueType: "Task", Summary: "s"})
	var apiErr *APIError
	require.ErrorAs(t, err, &apiErr)
	assert.Equal(t, 403, apiErr.Status)
	assert.Contains(t, apiErr.Message, "permission")
}

func TestCreateIssue_401AfterRefreshIsAuthRevoked(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/oauth/token" {
			_, _ = w.Write([]byte(`{"access_token":"at-new","refresh_token":"rt-new","expires_in":3600,"token_type":"Bearer"}`))
			return
		}
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer srv.Close()
	c := makeTestClient(t, srv.URL)
	c.oauthCfg = JiraOAuthConfig{ClientID: "cid", ClientSecret: "s", TokenURL: srv.URL + "/oauth/token"}
	_, err := c.CreateIssue(context.Background(), CreateIssueRequest{ProjectKey: "ABC", IssueType: "Task", Summary: "s"})
	assert.True(t, errors.Is(err, ErrAuthRevoked), "got %v", err)
}

func TestGetIssue_FetchesByKey(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, "/rest/api/3/issue/ABC-7", r.URL.Path)
		assert.Contains(t, r.URL.Query().Get("fields"), "summary")
		_, _ = w.Write([]byte(`{"id":"10001","key":"ABC-7","fields":{"summary":"Fix login","issuetype":{"name":"Task"},"status":{"name":"To Do","statusCategory":{"key":"new","name":"To Do"}},"created":"2026-09-04T10:00:00.000+0000","updated":"2026-09-04T10:00:00.000+0000"}}`))
	}))
	defer srv.Close()
	issue, err := makeTestClient(t, srv.URL).GetIssue(context.Background(), "ABC-7")
	require.NoError(t, err)
	assert.Equal(t, "Fix login", issue.Fields.Summary)
	assert.Equal(t, "Task", issue.Fields.IssueType.Name)
}

func TestADFDocument_ParagraphsAndText(t *testing.T) {
	doc := ADFDocument("line one\nline two\n\nsecond para")
	assert.Equal(t, "doc", doc["type"])
	assert.Equal(t, 1, doc["version"])
	content := doc["content"].([]map[string]any)
	require.Len(t, content, 2)
	assert.Equal(t, "paragraph", content[0]["type"])
	assert.Equal(t, "line one\nline two", content[0]["content"].([]map[string]any)[0]["text"])
	assert.Equal(t, "second para", DescriptionText(map[string]interface{}{
		"type": "doc", "content": []interface{}{map[string]interface{}{"type": "paragraph",
			"content": []interface{}{map[string]interface{}{"type": "text", "text": "second para"}}}},
	}))
}
```

Before running: check how `makeTestClient`'s refresh path names the token endpoint — `grep -n 'TokenURL\|jiraTokenEndpoint' internal/jira/auth.go internal/jira/client_test.go`. If `JiraOAuthConfig` has no `TokenURL` override, look at how the existing 401-refresh test in `internal/jira/client_test.go` redirects the refresh (search for `StatusUnauthorized`) and copy that mechanism into `TestCreateIssue_401AfterRefreshIsAuthRevoked` instead of the `TokenURL` line.

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/jira/ -run 'TestCreateIssue|TestGetIssue|TestADFDocument'`
Expected: FAIL — `CreateIssue` undefined.

- [ ] **Step 3: Implement**

`internal/jira/create.go`:

```go
package jira

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strings"
)

// CreateIssueRequest is the input of CreateIssue. Description is plain text;
// it is converted to an ADF document of paragraphs.
type CreateIssueRequest struct {
	ProjectKey  string
	IssueType   string
	Summary     string
	Description string
	Labels      []string
	Priority    string
}

// CreatedIssue is Jira's POST /rest/api/3/issue response.
type CreatedIssue struct {
	ID   string `json:"id"`
	Key  string `json:"key"`
	Self string `json:"self"`
}

// APIError is a non-2xx Jira response with the messages Jira returned,
// e.g. "issuetype: The issue type selected is invalid." A 401 that survives
// a token refresh is NOT an APIError — Client.do maps it to ErrAuthRevoked.
type APIError struct {
	Status  int
	Message string
}

func (e *APIError) Error() string { return fmt.Sprintf("jira: %d: %s", e.Status, e.Message) }

// jiraErrorMessage flattens Jira's {"errorMessages":[...],"errors":{field:msg}}
// body into one line, falling back to the raw body.
func jiraErrorMessage(body []byte) string {
	var parsed struct {
		ErrorMessages []string          `json:"errorMessages"`
		Errors        map[string]string `json:"errors"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return strings.TrimSpace(string(body))
	}
	parts := append([]string{}, parsed.ErrorMessages...)
	keys := make([]string, 0, len(parsed.Errors))
	for k := range parsed.Errors {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		parts = append(parts, k+": "+parsed.Errors[k])
	}
	if len(parts) == 0 {
		return strings.TrimSpace(string(body))
	}
	return strings.Join(parts, "; ")
}

// ADFDocument renders plain text as an Atlassian Document Format doc: blank
// lines separate paragraphs, single newlines stay inside a paragraph.
func ADFDocument(text string) map[string]any {
	var paragraphs []map[string]any
	for _, block := range strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n\n") {
		block = strings.TrimSpace(block)
		if block == "" {
			continue
		}
		paragraphs = append(paragraphs, map[string]any{
			"type":    "paragraph",
			"content": []map[string]any{{"type": "text", "text": block}},
		})
	}
	if paragraphs == nil {
		paragraphs = []map[string]any{}
	}
	return map[string]any{"type": "doc", "version": 1, "content": paragraphs}
}

// DescriptionText is the exported face of extractDescriptionText (sync.go)
// so callers outside the syncer can flatten an ADF description.
func DescriptionText(desc interface{}) string { return extractDescriptionText(desc) }

// CreateIssue creates an issue via POST /rest/api/3/issue.
func (c *Client) CreateIssue(ctx context.Context, req CreateIssueRequest) (CreatedIssue, error) {
	fields := map[string]any{
		"project":   map[string]any{"key": req.ProjectKey},
		"issuetype": map[string]any{"name": req.IssueType},
		"summary":   req.Summary,
	}
	if strings.TrimSpace(req.Description) != "" {
		fields["description"] = ADFDocument(req.Description)
	}
	if len(req.Labels) > 0 {
		fields["labels"] = req.Labels
	}
	if req.Priority != "" {
		fields["priority"] = map[string]any{"name": req.Priority}
	}
	body, err := json.Marshal(map[string]any{"fields": fields})
	if err != nil {
		return CreatedIssue{}, fmt.Errorf("encoding create issue request: %w", err)
	}
	resp, err := c.do(ctx, http.MethodPost, "/rest/api/3/issue", bytes.NewReader(body))
	if err != nil {
		return CreatedIssue{}, err
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusOK {
		return CreatedIssue{}, &APIError{Status: resp.StatusCode, Message: jiraErrorMessage(respBody)}
	}
	var created CreatedIssue
	if err := json.Unmarshal(respBody, &created); err != nil {
		return CreatedIssue{}, fmt.Errorf("decoding create issue response: %w", err)
	}
	return created, nil
}

// GetIssue fetches one issue with the same field set the search sync uses.
func (c *Client) GetIssue(ctx context.Context, key string) (Issue, error) {
	params := url.Values{"fields": {strings.Join(searchFields, ",")}}
	var issue Issue
	if err := c.getWithQuery(ctx, "/rest/api/3/issue/"+url.PathEscape(key), params, &issue); err != nil {
		return Issue{}, err
	}
	return issue, nil
}
```

- [ ] **Step 4: Run tests**

Run: `go test ./internal/jira/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/jira/create.go internal/jira/create_test.go
git commit -m "feat(jira): CreateIssue/GetIssue client methods with ADF description and error mapping"
```

---

### Task 5: `create_jira_issue` tool

**Files:**
- Create: `internal/tools/jira.go`, `internal/tools/jira_test.go`

**Interfaces:**
- Consumes: Task 4's `jira.CreateIssueRequest`, `jira.CreatedIssue`, `jira.Issue`, `jira.APIError`, `jira.ErrAuthRevoked`, `jira.DescriptionText`; `db.ListEnabledJiraAccounts`, `db.GetJiraAccount`, `db.GetJiraSyncStates`, `db.UpsertJiraIssue`, `db.SetJiraAccountAuthState`.
- Produces:
  ```go
  type JiraIssueClient interface {
      CreateIssue(ctx context.Context, req jira.CreateIssueRequest) (jira.CreatedIssue, error)
      GetIssue(ctx context.Context, key string) (jira.Issue, error)
  }
  type JiraClientFactory func(account db.JiraAccount) (JiraIssueClient, error)
  func NewCreateJiraIssue(factory JiraClientFactory) *Tool   // name create_jira_issue, External, surfaces {main,target}
  func ResolveJiraAccount(d *db.DB, id int64) (db.JiraAccount, error)
  ```

- [ ] **Step 1: Write the failing tests**

`internal/tools/jira_test.go`:

```go
package tools

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/jira"
)

type fakeJira struct {
	created []jira.CreateIssueRequest
	createErr error
	key     string
}

func (f *fakeJira) CreateIssue(_ context.Context, req jira.CreateIssueRequest) (jira.CreatedIssue, error) {
	f.created = append(f.created, req)
	if f.createErr != nil {
		return jira.CreatedIssue{}, f.createErr
	}
	return jira.CreatedIssue{ID: "1", Key: f.key}, nil
}

func (f *fakeJira) GetIssue(_ context.Context, key string) (jira.Issue, error) {
	var issue jira.Issue
	_ = json.Unmarshal([]byte(`{"id":"1","key":"`+key+`","fields":{"summary":"Fix login","issuetype":{"name":"Task"},"status":{"name":"To Do","statusCategory":{"key":"new","name":"To Do"}},"priority":{"name":"High"},"labels":["backend"],"created":"2026-09-04T10:00:00.000+0000","updated":"2026-09-04T10:00:00.000+0000","description":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"body"}]}]}}}`), &issue)
	return issue, nil
}

func seedJira(t *testing.T, d *db.DB) int64 {
	t.Helper()
	id, err := d.CreateJiraAccount(db.JiraAccount{CloudID: "cloud", SiteURL: "https://acme.atlassian.net", SiteName: "Acme"})
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO jira_sync_state (account_id, project_key, last_synced_at, issues_synced) VALUES (?, 'ABC', '2026-09-01T00:00:00Z', 1)`, id)
	require.NoError(t, err)
	return id
}

func TestCreateJiraIssue_ValidateChecksAccountAndProject(t *testing.T) {
	database := openDB(t)
	tool := NewCreateJiraIssue(func(db.JiraAccount) (JiraIssueClient, error) { return &fakeJira{}, nil })
	ctx := context.Background()

	// No account connected yet.
	err := tool.Validate(ctx, database, json.RawMessage(`{"project_key":"ABC","issue_type":"Task","summary":"s","reason":"r"}`))
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.Contains(t, verr.Msg, "no Jira site")

	seedJira(t, database)
	assert.NoError(t, tool.Validate(ctx, database, json.RawMessage(`{"project_key":"ABC","issue_type":"Task","summary":"s","reason":"r"}`)))

	cases := map[string]string{
		"unsynced project": `{"project_key":"ZZZ","issue_type":"Task","summary":"s","reason":"r"}`,
		"empty summary":    `{"project_key":"ABC","issue_type":"Task","summary":" ","reason":"r"}`,
		"empty type":       `{"project_key":"ABC","issue_type":"","summary":"s","reason":"r"}`,
		"unknown field":    `{"project_key":"ABC","issue_type":"Task","summary":"s","reason":"r","assignee":"me"}`,
		"unknown account":  `{"account_id":99,"project_key":"ABC","issue_type":"Task","summary":"s","reason":"r"}`,
	}
	for name, raw := range cases {
		assert.ErrorAs(t, tool.Validate(ctx, database, json.RawMessage(raw)), &verr, name)
	}
}

func TestCreateJiraIssue_ExecuteCreatesFetchesAndStores(t *testing.T) {
	database := openDB(t)
	accountID := seedJira(t, database)
	fake := &fakeJira{key: "ABC-7"}
	tool := NewCreateJiraIssue(func(a db.JiraAccount) (JiraIssueClient, error) {
		assert.Equal(t, accountID, a.ID)
		return fake, nil
	})
	out, err := tool.Execute(context.Background(), database, Call{ActionID: 5, Args: json.RawMessage(
		`{"project_key":"ABC","issue_type":"Task","summary":"Fix login","description":"body","labels":["backend"],"priority":"High","reason":"r"}`)})
	require.NoError(t, err)
	res := out.(map[string]any)
	assert.Equal(t, "ABC-7", res["key"])
	assert.Equal(t, "https://acme.atlassian.net/browse/ABC-7", res["url"])
	require.Len(t, fake.created, 1)
	assert.Equal(t, "Fix login", fake.created[0].Summary)

	row, err := database.GetJiraIssueByKey("ABC-7")
	require.NoError(t, err)
	require.NotNil(t, row)
	assert.Equal(t, accountID, row.AccountID)
	assert.Equal(t, "ABC", row.ProjectKey)
	assert.Equal(t, "Task", row.IssueType)
	assert.Equal(t, "To Do", row.Status)
	assert.Equal(t, "body", row.DescriptionText)
	assert.Equal(t, `["backend"]`, row.Labels)
}

func TestCreateJiraIssue_AuthRevokedMarksAccount(t *testing.T) {
	database := openDB(t)
	accountID := seedJira(t, database)
	fake := &fakeJira{createErr: jira.ErrAuthRevoked}
	tool := NewCreateJiraIssue(func(db.JiraAccount) (JiraIssueClient, error) { return fake, nil })
	_, err := tool.Execute(context.Background(), database, Call{Args: json.RawMessage(
		`{"project_key":"ABC","issue_type":"Task","summary":"s","reason":"r"}`)})
	assert.True(t, errors.Is(err, jira.ErrAuthRevoked))
	acct, _ := database.GetJiraAccount(accountID)
	assert.Equal(t, "revoked", acct.Status)
}

func TestCreateJiraIssue_APIErrorSurfacesMessage(t *testing.T) {
	database := openDB(t)
	seedJira(t, database)
	fake := &fakeJira{createErr: &jira.APIError{Status: 400, Message: "issuetype: invalid"}}
	tool := NewCreateJiraIssue(func(db.JiraAccount) (JiraIssueClient, error) { return fake, nil })
	_, err := tool.Execute(context.Background(), database, Call{Args: json.RawMessage(
		`{"project_key":"ABC","issue_type":"Nope","summary":"s","reason":"r"}`)})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "issuetype: invalid")
}

func TestCreateJiraIssue_Registration(t *testing.T) {
	tool := NewCreateJiraIssue(nil)
	assert.Equal(t, "create_jira_issue", tool.Name)
	assert.True(t, tool.External)
	assert.ElementsMatch(t, []string{"main", "target"}, tool.Surfaces)
}

func TestResolveJiraAccount_SingleDefaultAndAmbiguity(t *testing.T) {
	database := openDB(t)
	_, err := ResolveJiraAccount(database, 0)
	require.Error(t, err)
	first := seedJira(t, database)
	a, err := ResolveJiraAccount(database, 0)
	require.NoError(t, err)
	assert.Equal(t, first, a.ID)
	_, err = database.CreateJiraAccount(db.JiraAccount{CloudID: "c2", SiteURL: "https://two.atlassian.net"})
	require.NoError(t, err)
	_, err = ResolveJiraAccount(database, 0)
	assert.Error(t, err, "two enabled accounts need an explicit id")
	a, err = ResolveJiraAccount(database, first)
	require.NoError(t, err)
	assert.Equal(t, first, a.ID)
}
```

Check `CreateJiraAccount` seeds `enabled=1` and `status='ok'` (`sed -n '24,45p' internal/db/jira_accounts.go`); if not, set them with an `UPDATE` in `seedJira`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/tools/ -run 'TestCreateJiraIssue|TestResolveJiraAccount'`
Expected: FAIL — `NewCreateJiraIssue` undefined.

- [ ] **Step 3: Implement**

`internal/tools/jira.go`:

```go
package tools

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/jsonschema-go/jsonschema"

	"watchtower/internal/db"
	"watchtower/internal/jira"
)

// JiraIssueClient is the slice of *jira.Client the tool needs — a seam so
// tests inject a fake and the CLI wiring injects a real per-account client.
type JiraIssueClient interface {
	CreateIssue(ctx context.Context, req jira.CreateIssueRequest) (jira.CreatedIssue, error)
	GetIssue(ctx context.Context, key string) (jira.Issue, error)
}

// JiraClientFactory builds a client for one connected account.
type JiraClientFactory func(account db.JiraAccount) (JiraIssueClient, error)

type createJiraIssueArgs struct {
	AccountID   int64    `json:"account_id,omitempty" jsonschema:"connected Jira account id; required only when more than one site is connected (see list_jira_projects)"`
	ProjectKey  string   `json:"project_key" jsonschema:"project key, e.g. ABC — must be a synced project (list_jira_projects)"`
	IssueType   string   `json:"issue_type" jsonschema:"issue type name, e.g. Task, Bug, Story"`
	Summary     string   `json:"summary" jsonschema:"issue title, at most 255 characters"`
	Description string   `json:"description,omitempty" jsonschema:"plain-text body; blank lines separate paragraphs"`
	Labels      []string `json:"labels,omitempty"`
	Priority    string   `json:"priority,omitempty" jsonschema:"Jira priority name, e.g. High"`
	Reason      string   `json:"reason" jsonschema:"one sentence: why you propose this, shown to the owner"`
}

// ResolveJiraAccount mirrors cmd/jira.go's resolveJiraAccount: an explicit id
// must exist and not be removed; 0 means "the single enabled account".
func ResolveJiraAccount(d *db.DB, id int64) (db.JiraAccount, error) {
	if id > 0 {
		a, err := d.GetJiraAccount(id)
		if err != nil {
			return db.JiraAccount{}, &ValidationError{Msg: fmt.Sprintf("no Jira account #%d", id)}
		}
		if a.Status == "removed" || !a.Enabled {
			return db.JiraAccount{}, &ValidationError{Msg: fmt.Sprintf("Jira account #%d is not enabled", id)}
		}
		return a, nil
	}
	accounts, err := d.ListEnabledJiraAccounts()
	if err != nil {
		return db.JiraAccount{}, err
	}
	switch len(accounts) {
	case 0:
		return db.JiraAccount{}, &ValidationError{Msg: "no Jira site is connected; the owner must run 'watchtower jira add' first"}
	case 1:
		return accounts[0], nil
	default:
		return db.JiraAccount{}, &ValidationError{Msg: "several Jira sites are connected — pass account_id (see list_jira_projects)"}
	}
}

func projectSynced(d *db.DB, accountID int64, projectKey string) (bool, error) {
	states, err := d.GetJiraSyncStates()
	if err != nil {
		return false, err
	}
	for _, s := range states {
		if s.AccountID == accountID && strings.EqualFold(s.ProjectKey, projectKey) {
			return true, nil
		}
	}
	return false, nil
}

// issueRow maps a fetched issue onto the synced-row shape without the
// syncer's user mapping; the next sync pass refreshes assignee/reporter and
// board fields.
func issueRow(accountID int64, issue jira.Issue) db.JiraIssue {
	f := issue.Fields
	now := time.Now().UTC().Format(time.RFC3339)
	projectKey := issue.Key
	if idx := strings.LastIndex(issue.Key, "-"); idx > 0 {
		projectKey = issue.Key[:idx]
	}
	labels, _ := json.Marshal(f.Labels)
	if f.Labels == nil {
		labels = []byte("[]")
	}
	priority := ""
	if f.Priority != nil {
		priority = f.Priority.Name
	}
	raw, _ := json.Marshal(issue)
	return db.JiraIssue{
		AccountID: accountID, Key: issue.Key, ID: issue.ID, ProjectKey: projectKey,
		Summary: f.Summary, DescriptionText: jira.DescriptionText(f.Description),
		IssueType: f.IssueType.Name, Status: f.Status.Name, StatusCategory: f.Status.StatusCategory.Key,
		Priority: priority, Labels: string(labels), Components: "[]", FixVersions: "[]",
		CreatedAt: f.Created, UpdatedAt: f.Updated, RawJSON: string(raw), SyncedAt: now,
	}
}

// NewCreateJiraIssue builds the create_jira_issue write tool — the first
// action whose write leaves the machine, hence External (AGENT-03).
func NewCreateJiraIssue(factory JiraClientFactory) *Tool {
	schema, err := jsonschema.For[createJiraIssueArgs](nil)
	if err != nil {
		panic("create_jira_issue schema: " + err.Error())
	}
	return &Tool{
		Name: "create_jira_issue",
		Description: "Propose creating a Jira issue. The owner approves it in the chat before anything is sent to " +
			"Jira. Call list_jira_projects first to pick a synced project and a known issue type; when the " +
			"project or type is ambiguous, ask the owner instead of guessing.",
		InputSchema: schema,
		Access:      AccessWrite,
		External:    true,
		Surfaces:    []string{"main", "target"},
		Validate: func(_ context.Context, d *db.DB, raw json.RawMessage) error {
			var a createJiraIssueArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			switch {
			case strings.TrimSpace(a.ProjectKey) == "":
				return &ValidationError{Msg: "project_key is required"}
			case strings.TrimSpace(a.IssueType) == "":
				return &ValidationError{Msg: "issue_type is required"}
			case strings.TrimSpace(a.Summary) == "":
				return &ValidationError{Msg: "summary is required"}
			case len([]rune(a.Summary)) > 255:
				return &ValidationError{Msg: "summary must be at most 255 characters"}
			}
			account, err := ResolveJiraAccount(d, a.AccountID)
			if err != nil {
				return err
			}
			ok, err := projectSynced(d, account.ID, a.ProjectKey)
			if err != nil {
				return err
			}
			if !ok {
				return &ValidationError{Msg: fmt.Sprintf("project %s is not synced for this account; call list_jira_projects", a.ProjectKey)}
			}
			return nil
		},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a createJiraIssueArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding create_jira_issue args: %w", err)
			}
			account, err := ResolveJiraAccount(d, a.AccountID)
			if err != nil {
				return nil, err
			}
			client, err := factory(account)
			if err != nil {
				return nil, err
			}
			created, err := client.CreateIssue(ctx, jira.CreateIssueRequest{
				ProjectKey: strings.ToUpper(strings.TrimSpace(a.ProjectKey)), IssueType: strings.TrimSpace(a.IssueType),
				Summary: strings.TrimSpace(a.Summary), Description: a.Description, Labels: a.Labels, Priority: a.Priority,
			})
			if err != nil {
				if errors.Is(err, jira.ErrAuthRevoked) {
					_ = d.SetJiraAccountAuthState(account.ID, "revoked", err.Error())
				}
				return nil, err
			}
			url := strings.TrimRight(account.SiteURL, "/") + "/browse/" + created.Key
			// Best effort: a fetch failure must not fail an issue that exists.
			if issue, gerr := client.GetIssue(ctx, created.Key); gerr == nil {
				_ = d.UpsertJiraIssue(issueRow(account.ID, issue))
			}
			return map[string]any{"key": created.Key, "url": url}, nil
		},
	}
}
```

- [ ] **Step 4: Run tests**

Run: `go test ./internal/tools/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/tools/jira.go internal/tools/jira_test.go
git commit -m "feat(tools): create_jira_issue write tool (external, propose-only) with post-create upsert"
```

---

### Task 6: MCP chat mode — registry adapter, `get_action`, `list_jira_projects`

**Files:**
- Create: `internal/mcp/actions.go`, `internal/mcp/actions_test.go`
- Modify: `internal/mcp/server.go` (Server fields, `NewServer`), `internal/mcp/jira.go` (add `list_jira_projects`), `internal/mcp/server_test.go` (`TestNoToolMutatesDatabase` call list + readVerbs untouched)

**Interfaces:**
- Consumes: `tools.Registry`, `tools.Binding`, `tools.Receipt`, `tools.ValidationError`, `db.GetAgentAction`, `db.ListEnabledJiraAccounts`, `db.GetJiraSyncStates`.
- Produces: `mcp.WithRegistry(reg *tools.Registry, binding tools.Binding) ServerOption`; MCP tools `create_target`, `create_jira_issue` (chat mode, surface-filtered), `get_action` (chat mode), `list_jira_projects` (both modes).

- [ ] **Step 1: Write the failing tests**

`internal/mcp/actions_test.go`:

```go
package mcp

import (
	"context"
	"encoding/json"
	"strconv"
	"strings"
	"testing"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// newChatSession mirrors cmd/mcp.go's --chat wiring: a WRITABLE connection
// (no SetReadOnly) with the registry mounted for one surface.
func newChatSession(t *testing.T, database *db.DB, reg *tools.Registry, binding tools.Binding) *mcpsdk.ClientSession {
	t.Helper()
	ctx := context.Background()
	srv := NewServer(database, WithRegistry(reg, binding))
	client := mcpsdk.NewClient(&mcpsdk.Implementation{Name: "test", Version: "v0"}, nil)
	st, ct := mcpsdk.NewInMemoryTransports()
	if _, err := srv.s.Connect(ctx, st, nil); err != nil {
		t.Fatalf("server connect: %v", err)
	}
	cs, err := client.Connect(ctx, ct, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	t.Cleanup(func() { _ = cs.Close() })
	return cs
}

func chatRegistry(t *testing.T, database *db.DB) *tools.Registry {
	t.Helper()
	reg := tools.New(database)
	if err := reg.Register(tools.NewCreateTarget()); err != nil {
		t.Fatal(err)
	}
	if err := reg.Register(tools.NewCreateJiraIssue(func(db.JiraAccount) (tools.JiraIssueClient, error) {
		t.Fatal("the Jira client must never be built on propose")
		return nil, nil
	})); err != nil {
		t.Fatal(err)
	}
	return reg
}

func toolNames(t *testing.T, cs *mcpsdk.ClientSession) map[string]bool {
	t.Helper()
	res, err := cs.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatalf("list tools: %v", err)
	}
	names := map[string]bool{}
	for _, tool := range res.Tools {
		names[tool.Name] = true
	}
	return names
}

func TestChatMode_ListsWriteToolsPerSurface(t *testing.T) {
	database := seedDB(t)
	main := toolNames(t, newChatSession(t, database, chatRegistry(t, database), tools.Binding{Surface: "main"}))
	if !main["create_target"] || !main["create_jira_issue"] || !main["get_action"] || !main["list_jira_projects"] {
		t.Fatalf("main surface tools = %v", main)
	}
	target := toolNames(t, newChatSession(t, seedDB(t), chatRegistry(t, database), tools.Binding{Surface: "target"}))
	if target["create_target"] {
		t.Fatalf("create_target must not be offered on the target surface (TGT-BRIEF-01)")
	}
	if !target["create_jira_issue"] {
		t.Fatalf("create_jira_issue missing on the target surface")
	}
}

// AGENT-02: the developer-surface server never mounts a write tool.
func TestAgent02_DevModeRegistersNoWriteTools(t *testing.T) {
	names := toolNames(t, newTestSession(t, seedDB(t)))
	for _, n := range []string{"create_target", "create_jira_issue", "get_action"} {
		if names[n] {
			t.Errorf("dev mode exposes write/chat tool %q", n)
		}
	}
	if !names["list_jira_projects"] {
		t.Errorf("list_jira_projects is a read tool and belongs to both modes")
	}
}

// AGENT-01: a write tool called through the chat server with trust "ask"
// leaves every data table untouched and records exactly one proposal.
func TestAgent01_WriteToolCallRecordsProposalOnly(t *testing.T) {
	database := seedDB(t)
	seedGuardFixture(t, database)
	before := countRows(t, database, guardTables)
	cs := newChatSession(t, database, chatRegistry(t, database), tools.Binding{Surface: "main", ConversationID: 3, TurnID: "t9"})

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name: "create_target", Arguments: map[string]any{"text": "Call Vasya", "reason": "owner asked"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.IsError {
		t.Fatalf("unexpected tool error: %s", textContent(t, res))
	}
	var rc tools.Receipt
	if err := json.Unmarshal([]byte(textContent(t, res)), &rc); err != nil {
		t.Fatal(err)
	}
	if rc.Status != "pending" || !strings.Contains(rc.Message, "do not claim it is done") {
		t.Fatalf("receipt = %+v", rc)
	}
	after := countRows(t, database, guardTables)
	for _, tbl := range guardTables {
		if before[tbl] != after[tbl] {
			t.Errorf("table %s changed %d -> %d on propose", tbl, before[tbl], after[tbl])
		}
	}
	rows, _ := database.ListAgentActions(db.AgentActionFilter{ConversationID: 3})
	if len(rows) != 1 || rows[0].TurnID != "t9" || rows[0].Surface != "main" {
		t.Fatalf("agent_actions = %+v", rows)
	}
}

func TestChatMode_ValidationErrorIsToolErrorWithoutRow(t *testing.T) {
	database := seedDB(t)
	cs := newChatSession(t, database, chatRegistry(t, database), tools.Binding{Surface: "main"})
	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name: "create_target", Arguments: map[string]any{"reason": "no text"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !res.IsError || !strings.Contains(textContent(t, res), "text is required") {
		t.Fatalf("expected validation error, got %s", textContent(t, res))
	}
	rows, _ := database.ListAgentActions(db.AgentActionFilter{})
	if len(rows) != 0 {
		t.Fatalf("validation failure wrote %d rows", len(rows))
	}
}

func TestGetAction_ReturnsRowAndNotFound(t *testing.T) {
	database := seedDB(t)
	id, _ := database.InsertAgentAction(db.AgentAction{Tool: "create_target", ArgsJSON: `{"text":"x"}`, Reason: "r"})
	cs := newChatSession(t, database, chatRegistry(t, database), tools.Binding{Surface: "main"})
	res, _ := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{Name: "get_action", Arguments: map[string]any{"id": id}})
	if res.IsError || !strings.Contains(textContent(t, res), `"status": "pending"`) {
		t.Fatalf("get_action = %s", textContent(t, res))
	}
	res, _ = cs.CallTool(context.Background(), &mcpsdk.CallToolParams{Name: "get_action", Arguments: map[string]any{"id": 999}})
	if !res.IsError {
		t.Fatalf("expected not-found error")
	}
}

func TestListJiraProjects_GroupsByAccount(t *testing.T) {
	database := seedDB(t)
	acct, err := database.CreateJiraAccount(db.JiraAccount{CloudID: "c", SiteURL: "https://acme.atlassian.net", SiteName: "Acme"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := database.Exec(`INSERT INTO jira_sync_state (account_id, project_key, last_synced_at, issues_synced) VALUES (?, 'ABC', 'x', 2)`, acct); err != nil {
		t.Fatal(err)
	}
	for _, it := range []string{"Task", "Bug", "Task"} {
		key := "ABC-" + it + "1"
		if err := database.UpsertJiraIssue(db.JiraIssue{AccountID: acct, Key: key, ProjectKey: "ABC", Summary: "s", IssueType: it,
			Status: "To Do", StatusCategory: "new", Labels: "[]", Components: "[]", FixVersions: "[]",
			CreatedAt: "2026-01-01T00:00:00Z", UpdatedAt: "2026-01-01T00:00:00Z", SyncedAt: "2026-01-01T00:00:00Z"}); err != nil {
			t.Fatal(err)
		}
	}
	cs := newTestSession(t, database)
	res, _ := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{Name: "list_jira_projects"})
	out := textContent(t, res)
	for _, want := range []string{`"account_id": ` + strconv.FormatInt(acct, 10), `"project_key": "ABC"`, `"Bug"`, `"Task"`} {
		if !strings.Contains(out, want) {
			t.Errorf("list_jira_projects output missing %s:\n%s", want, out)
		}
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/mcp/ -run 'TestChatMode|TestAgent0|TestGetAction|TestListJiraProjects'`
Expected: FAIL — `WithRegistry` undefined.

- [ ] **Step 3: Implement the adapter**

Add to `Server` in `internal/mcp/server.go`:

```go
	// registry + binding are set only by the chat-mode server (cmd/mcp.go
	// --chat): the registry's write tools and get_action are mounted, and
	// every proposal is stamped with the binding. nil in dev mode — AGENT-02.
	registry *tools.Registry
	binding  tools.Binding
```

and in `NewServer`, after `registerSkills(...)`:

```go
	if srv.registry != nil {
		registerRegistry(srv.s, database, srv.registry, srv.binding)
	}
```

(import `"watchtower/internal/tools"`). Then `internal/mcp/actions.go`:

```go
package mcp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// WithRegistry turns the server into the assistant's chat-mode server: the
// registry's tools visible on binding.Surface are mounted, write calls become
// proposals stamped with binding, and get_action is registered. The
// developer-surface server never passes this option (AGENT-02).
func WithRegistry(reg *tools.Registry, binding tools.Binding) ServerOption {
	return func(srv *Server) {
		srv.registry = reg
		srv.binding = binding
	}
}

type getActionArgs struct {
	ID int64 `json:"id" jsonschema:"the action id from a write tool's receipt"`
}

func registerRegistry(s *mcpsdk.Server, database *db.DB, reg *tools.Registry, binding tools.Binding) {
	for _, t := range reg.List(binding.Surface) {
		tool := t
		s.AddTool(&mcpsdk.Tool{
			Name:        tool.Name,
			Description: tool.Description,
			InputSchema: tool.InputSchema,
		}, func(ctx context.Context, req *mcpsdk.CallToolRequest) (*mcpsdk.CallToolResult, error) {
			raw := json.RawMessage(req.Params.Arguments)
			if tool.Access != tools.AccessWrite {
				out, err := tool.Execute(ctx, database, tools.Call{Args: raw, Binding: binding})
				if err != nil {
					return errResult(err.Error()), nil
				}
				res, _, err := jsonResult(out)
				return res, err
			}
			rc, err := reg.Propose(ctx, tool.Name, raw, binding)
			if err != nil {
				var verr *tools.ValidationError
				if errors.As(err, &verr) {
					return errResult(verr.Msg), nil
				}
				return errResult(fmt.Sprintf("recording proposal: %v", err)), nil
			}
			res, _, err := jsonResult(rc)
			return res, err
		})
	}

	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name: "get_action",
		Description: "Look up one proposed action by id: its status (pending, approved, rejected, applied, " +
			"failed), result and error. Use it when the owner asks what happened to a proposal.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args getActionArgs) (*mcpsdk.CallToolResult, any, error) {
		row, err := database.GetAgentAction(args.ID)
		if err != nil {
			return errResult("getting action: " + err.Error()), nil, nil
		}
		if row == nil {
			return errResult(fmt.Sprintf("no action #%d", args.ID)), nil, nil
		}
		return jsonResult(newActionView(*row))
	})
}

// actionView is the model-facing shape of an agent_actions row.
type actionView struct {
	ID         int64           `json:"id"`
	Tool       string          `json:"tool"`
	Status     string          `json:"status"`
	Args       json.RawMessage `json:"args"`
	Reason     string          `json:"reason"`
	Result     json.RawMessage `json:"result,omitempty"`
	Error      string          `json:"error,omitempty"`
	CreatedAt  string          `json:"created_at"`
	DecidedAt  string          `json:"decided_at,omitempty"`
	AppliedAt  string          `json:"applied_at,omitempty"`
}

func newActionView(a db.AgentAction) actionView {
	v := actionView{ID: a.ID, Tool: a.Tool, Status: a.Status, Args: json.RawMessage(a.ArgsJSON), Reason: a.Reason,
		Error: a.Error, CreatedAt: a.CreatedAt, DecidedAt: a.DecidedAt, AppliedAt: a.AppliedAt}
	if a.ResultJSON != "" {
		v.Result = json.RawMessage(a.ResultJSON)
	}
	return v
}
```

If `req.Params.Arguments` does not compile as `json.RawMessage` (the SDK's raw params type is `*CallToolParamsRaw`; check with `go doc github.com/modelcontextprotocol/go-sdk/mcp CallToolParamsRaw`), marshal it: `raw, _ := json.Marshal(req.Params.Arguments)`.

- [ ] **Step 4: Add `list_jira_projects` to `internal/mcp/jira.go`**

Inside `registerJira`, after `get_jira_issue`:

```go
	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name: "list_jira_projects",
		Description: "List the connected Jira accounts and their synced projects, with the issue types seen in " +
			"each project — what create_jira_issue accepts for account_id, project_key and issue_type.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args struct{}) (*mcpsdk.CallToolResult, any, error) {
		accounts, err := database.ListEnabledJiraAccounts()
		if err != nil {
			return errResult("listing jira accounts: " + err.Error()), nil, nil
		}
		states, err := database.GetJiraSyncStates()
		if err != nil {
			return errResult("listing jira projects: " + err.Error()), nil, nil
		}
		typesByProject, err := jiraIssueTypesByProject(database)
		if err != nil {
			return errResult("listing issue types: " + err.Error()), nil, nil
		}
		var out []jiraProjectsView
		for _, a := range accounts {
			view := jiraProjectsView{AccountID: a.ID, Label: a.Label, SiteName: a.SiteName, SiteURL: a.SiteURL}
			for _, s := range states {
				if s.AccountID != a.ID {
					continue
				}
				pt := typesByProject[projectKeyID{a.ID, s.ProjectKey}]
				view.Projects = append(view.Projects, jiraProjectView{
					ProjectKey: s.ProjectKey, IssueTypes: pt.types, IssueCount: pt.count,
				})
			}
			out = append(out, view)
		}
		return jsonListResult(out)
	})
```

with these helpers at the bottom of the file:

```go
type jiraProjectsView struct {
	AccountID int64             `json:"account_id"`
	Label     string            `json:"label,omitempty"`
	SiteName  string            `json:"site_name,omitempty"`
	SiteURL   string            `json:"site_url,omitempty"`
	Projects  []jiraProjectView `json:"projects"`
}

type jiraProjectView struct {
	ProjectKey string   `json:"project_key"`
	IssueTypes []string `json:"issue_types"`
	IssueCount int      `json:"issue_count"`
}

type projectKeyID struct {
	accountID  int64
	projectKey string
}

type projectTypes struct {
	types []string
	count int
}

// jiraIssueTypesByProject aggregates the distinct issue types (and the issue
// count) per (account, project) from the synced issues.
func jiraIssueTypesByProject(database *db.DB) (map[projectKeyID]projectTypes, error) {
	rows, err := database.Query(`SELECT account_id, project_key, issue_type, COUNT(*)
		FROM jira_issues WHERE is_deleted = 0
		GROUP BY account_id, project_key, issue_type ORDER BY account_id, project_key, issue_type`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[projectKeyID]projectTypes{}
	for rows.Next() {
		var id projectKeyID
		var issueType string
		var n int
		if err := rows.Scan(&id.accountID, &id.projectKey, &issueType, &n); err != nil {
			return nil, err
		}
		pt := out[id]
		if issueType != "" {
			pt.types = append(pt.types, issueType)
		}
		pt.count += n
		out[id] = pt
	}
	return out, rows.Err()
}
```

The `jsonListResult` call needs `[]jiraProjectsView`; when `out` is nil it renders `[]`. Add `{Name: "list_jira_projects"}` to the `calls` list in `TestNoToolMutatesDatabase` (`internal/mcp/server_test.go`) — it is a read tool of the dev surface and must keep passing the row-count guard.

- [ ] **Step 5: Run the package tests**

Run: `go test ./internal/mcp/`
Expected: PASS, including `TestAllToolsAreReadOnly` (dev-mode session lists no write tool; `list_jira_projects` matches the `list_` prefix).

- [ ] **Step 6: Commit**

```bash
git add internal/mcp/
git commit -m "feat(mcp): chat mode mounts the tool registry (proposals), get_action and list_jira_projects"
```

---

### Task 7: CLI — `actions` commands and the shared registry wiring

**Files:**
- Create: `cmd/actions_registry.go`, `cmd/actions.go`, `cmd/actions_test.go`
- Modify: `cmd/mcp.go` (chat flags)

**Interfaces:**
- Consumes: `tools.New/Register/Propose/Apply/SetTrust/Trust/List`, `db.TransitionAgentAction`, `db.ListAgentActions`, `db.GetAgentAction`, `jira.NewClient`, `jira.NewTokenStore`, `resolveJiraOAuthConfig` (cmd/jira.go).
- Produces:
  ```go
  func buildToolRegistry(cfg *config.Config, database *db.DB) *tools.Registry   // create_target + create_jira_issue
  func jiraClientFactory(cfg *config.Config) tools.JiraClientFactory
  ```
  CLI: `watchtower actions list [--status S] [--conversation N] [--json]`, `actions show <id> [--json]`, `actions approve <id> [--json]`, `actions reject <id> [--json]`, `actions apply <id> [--json]`, `actions trust <tool> ask|execute`, `actions tools [--surface S] [--json]`; `watchtower mcp --chat --surface S --conversation N --turn T`.
  JSON shapes (Desktop decodes them verbatim):
  - action: `{"id","tool","external","status","args":{...},"reason","surface","conversation_id","turn_id","result":{...}|null,"error","created_at","decided_at","applied_at"}`
  - approve/apply/reject: `{"ok":true,"action":{…},"applied_ok":bool,"error":""}`
  - tools: `[{"name","description","access","external","surfaces":[…],"trust"}]`

- [ ] **Step 1: Write the failing CLI tests**

`cmd/actions_test.go`:

```go
package cmd

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// writeActionsConfig points flagConfig at a temp workspace whose DB path
// lives under a temp HOME (the writeFeaturesConfig precedent).
func writeActionsConfig(t *testing.T) *db.DB {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	tmpDir := t.TempDir()
	configPath := filepath.Join(tmpDir, "config.yaml")
	require.NoError(t, os.WriteFile(configPath, []byte("active_workspace: test\n"), 0o600))
	original := flagConfig
	flagConfig = configPath
	t.Cleanup(func() { flagConfig = original })
	database, err := openDBFromConfig()
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	return database
}

func runActions(t *testing.T, args ...string) (string, error) {
	t.Helper()
	var out bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&out)
	rootCmd.SetArgs(append([]string{"actions"}, args...))
	err := rootCmd.Execute()
	rootCmd.SetArgs(nil)
	return out.String(), err
}

func TestActions_ApproveExecutesCreateTarget(t *testing.T) {
	database := writeActionsConfig(t)
	id, err := database.InsertAgentAction(db.AgentAction{Tool: "create_target",
		ArgsJSON: `{"text":"Call Vasya","reason":"r","due":"2026-09-05T16:00"}`, Reason: "r", Surface: "main"})
	require.NoError(t, err)

	out, err := runActions(t, "approve", "1", "--json")
	require.NoError(t, err)
	var env struct {
		OK        bool `json:"ok"`
		AppliedOK bool `json:"applied_ok"`
		Action    struct {
			Status string          `json:"status"`
			Result json.RawMessage `json:"result"`
		} `json:"action"`
	}
	require.NoError(t, json.Unmarshal([]byte(out), &env), out)
	assert.True(t, env.OK)
	assert.True(t, env.AppliedOK)
	assert.Equal(t, "applied", env.Action.Status)
	assert.Contains(t, string(env.Action.Result), "target_id")

	targets, err := database.GetTargets(db.TargetFilter{})
	require.NoError(t, err)
	require.Len(t, targets, 1)
	assert.Equal(t, "Call Vasya", targets[0].Text)
	_ = id
}

func TestActions_RejectAndTerminalStates(t *testing.T) {
	database := writeActionsConfig(t)
	_, err := database.InsertAgentAction(db.AgentAction{Tool: "create_target", ArgsJSON: `{"text":"x","reason":"r"}`})
	require.NoError(t, err)

	out, err := runActions(t, "reject", "1", "--json")
	require.NoError(t, err)
	assert.Contains(t, out, `"status": "rejected"`)

	// AGENT-05: rejected is terminal — approve and apply both refuse.
	_, err = runActions(t, "approve", "1", "--json")
	assert.Error(t, err)
	_, err = runActions(t, "apply", "1", "--json")
	assert.Error(t, err)
}

func TestActions_ApproveWithFailingToolExitsZeroWithAppliedFalse(t *testing.T) {
	database := writeActionsConfig(t)
	// No Jira account connected → Execute fails at ResolveJiraAccount.
	_, err := database.InsertAgentAction(db.AgentAction{Tool: "create_jira_issue", External: true,
		ArgsJSON: `{"project_key":"ABC","issue_type":"Task","summary":"s","reason":"r"}`})
	require.NoError(t, err)

	out, err := runActions(t, "approve", "1", "--json")
	require.NoError(t, err, "status change persisted → exit 0 (the recap_ok precedent)")
	assert.Contains(t, out, `"applied_ok": false`)
	assert.Contains(t, out, `"status": "failed"`)

	// Retry from failed is allowed (and fails again the same way).
	out, err = runActions(t, "apply", "1", "--json")
	require.NoError(t, err)
	assert.Contains(t, out, `"status": "failed"`)
}

func TestActions_TrustAndTools(t *testing.T) {
	writeActionsConfig(t)
	_, err := runActions(t, "trust", "create_jira_issue", "execute")
	assert.Error(t, err, "AGENT-03: external tools can never execute without approval")

	_, err = runActions(t, "trust", "create_target", "execute")
	require.NoError(t, err)

	out, err := runActions(t, "tools", "--json")
	require.NoError(t, err)
	var listed []struct {
		Name     string   `json:"name"`
		External bool     `json:"external"`
		Trust    string   `json:"trust"`
		Surfaces []string `json:"surfaces"`
	}
	require.NoError(t, json.Unmarshal([]byte(out), &listed), out)
	byName := map[string]int{}
	for i, l := range listed {
		byName[l.Name] = i
	}
	assert.Equal(t, "execute", listed[byName["create_target"]].Trust)
	assert.True(t, listed[byName["create_jira_issue"]].External)
	assert.Equal(t, "ask", listed[byName["create_jira_issue"]].Trust)
	assert.ElementsMatch(t, []string{"main", "target"}, listed[byName["create_jira_issue"]].Surfaces)

	out, err = runActions(t, "tools", "--surface", "target", "--json")
	require.NoError(t, err)
	assert.NotContains(t, out, `"create_target"`)
}

func TestActions_ListAndShow(t *testing.T) {
	database := writeActionsConfig(t)
	_, _ = database.InsertAgentAction(db.AgentAction{Tool: "create_target", ArgsJSON: `{"text":"a","reason":"r"}`, ConversationID: 5})
	_, _ = database.InsertAgentAction(db.AgentAction{Tool: "create_target", ArgsJSON: `{"text":"b","reason":"r"}`, ConversationID: 6})

	out, err := runActions(t, "list", "--conversation", "5", "--json")
	require.NoError(t, err)
	assert.Contains(t, out, `"text": "a"`)
	assert.NotContains(t, out, `"text": "b"`)

	out, err = runActions(t, "show", "2", "--json")
	require.NoError(t, err)
	assert.Contains(t, out, `"conversation_id": 6`)

	_, err = runActions(t, "show", "99", "--json")
	assert.Error(t, err)
}
```

Check the target listing helper name before running: `grep -n 'func (db \*DB) GetTargets\|func (db \*DB) ListTargets' internal/db/targets.go` and adjust `GetTargets(db.TargetFilter{})` to the real signature.

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./cmd/ -run TestActions_`
Expected: FAIL — `unknown command "actions"`.

- [ ] **Step 3: Implement the shared registry wiring**

`cmd/actions_registry.go`:

```go
package cmd

import (
	"fmt"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/jira"
	"watchtower/internal/tools"
)

// jiraClientFactory builds a per-account Jira client the way the sync wiring
// does: the account's token file + the resolved OAuth client credentials.
func jiraClientFactory(cfg *config.Config) tools.JiraClientFactory {
	return func(account db.JiraAccount) (tools.JiraIssueClient, error) {
		store := jira.NewTokenStore(cfg.WorkspaceDir(), account.ID)
		if !store.Exists() {
			return nil, fmt.Errorf("jira account #%d has no token; run 'watchtower jira login --account %d'", account.ID, account.ID)
		}
		if account.CloudID == "" {
			return nil, fmt.Errorf("jira account #%d has no cloud id; run 'watchtower jira login --account %d'", account.ID, account.ID)
		}
		return jira.NewClient(account.CloudID, resolveJiraOAuthConfig(), store), nil
	}
}

// buildToolRegistry is the ONE place the assistant's write tools are
// assembled — shared by `mcp --chat`, `actions …` and `jira create`, so the
// three entry points can never disagree about what exists.
func buildToolRegistry(cfg *config.Config, database *db.DB) *tools.Registry {
	reg := tools.New(database)
	for _, t := range []*tools.Tool{
		tools.NewCreateTarget(),
		tools.NewCreateJiraIssue(jiraClientFactory(cfg)),
	} {
		if err := reg.Register(t); err != nil {
			panic("tool registry: " + err.Error())
		}
	}
	return reg
}
```

- [ ] **Step 4: Implement the `actions` command**

`cmd/actions.go`:

```go
package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/tools"
)

var (
	actionsFlagJSON         bool
	actionsFlagStatus       string
	actionsFlagConversation int64
	actionsFlagSurface      string
)

var actionsCmd = &cobra.Command{
	Use:   "actions",
	Short: "Proposed assistant actions: list, approve, reject, retry, tool trust",
	Long: `Every write tool the assistant calls lands in agent_actions as a proposal.
The Desktop drives these commands from the proposal cards; they are also the
CLI face for inspection and recovery.`,
}

var actionsListCmd = &cobra.Command{Use: "list", Short: "List proposed actions", RunE: runActionsList}
var actionsShowCmd = &cobra.Command{Use: "show <id>", Short: "Show one action", Args: cobra.ExactArgs(1), RunE: runActionsShow}
var actionsApproveCmd = &cobra.Command{Use: "approve <id>", Short: "Approve a pending action and execute it", Args: cobra.ExactArgs(1), RunE: runActionsApprove}
var actionsRejectCmd = &cobra.Command{Use: "reject <id>", Short: "Reject a pending action", Args: cobra.ExactArgs(1), RunE: runActionsReject}
var actionsApplyCmd = &cobra.Command{Use: "apply <id>", Short: "Retry an approved or failed action", Args: cobra.ExactArgs(1), RunE: runActionsApply}
var actionsTrustCmd = &cobra.Command{Use: "trust <tool> ask|execute", Short: "Set a tool's trust level", Args: cobra.ExactArgs(2), RunE: runActionsTrust}
var actionsToolsCmd = &cobra.Command{Use: "tools", Short: "List the registry's write tools", RunE: runActionsTools}

func init() {
	rootCmd.AddCommand(actionsCmd)
	for _, c := range []*cobra.Command{actionsListCmd, actionsShowCmd, actionsApproveCmd, actionsRejectCmd, actionsApplyCmd, actionsToolsCmd} {
		c.Flags().BoolVar(&actionsFlagJSON, "json", false, "output JSON (the Desktop contract)")
		actionsCmd.AddCommand(c)
	}
	actionsCmd.AddCommand(actionsTrustCmd)
	actionsListCmd.Flags().StringVar(&actionsFlagStatus, "status", "", "filter by status")
	actionsListCmd.Flags().Int64Var(&actionsFlagConversation, "conversation", 0, "filter by chat conversation id")
	actionsToolsCmd.Flags().StringVar(&actionsFlagSurface, "surface", "", "filter by chat surface (main|target)")
}

// actionJSON is the wire shape of one row. Field names are load-bearing:
// the Desktop's AgentActionQueries reads the table directly, but the CLI
// envelopes are decoded by AgentActionFeed verbatim.
type actionJSON struct {
	ID             int64           `json:"id"`
	Tool           string          `json:"tool"`
	External       bool            `json:"external"`
	Status         string          `json:"status"`
	Args           json.RawMessage `json:"args"`
	Reason         string          `json:"reason"`
	Surface        string          `json:"surface"`
	ConversationID int64           `json:"conversation_id"`
	TurnID         string          `json:"turn_id"`
	Result         json.RawMessage `json:"result"`
	Error          string          `json:"error"`
	CreatedAt      string          `json:"created_at"`
	DecidedAt      string          `json:"decided_at"`
	AppliedAt      string          `json:"applied_at"`
}

func toActionJSON(a db.AgentAction) actionJSON {
	out := actionJSON{ID: a.ID, Tool: a.Tool, External: a.External, Status: a.Status,
		Args: json.RawMessage(a.ArgsJSON), Reason: a.Reason, Surface: a.Surface, ConversationID: a.ConversationID,
		TurnID: a.TurnID, Result: json.RawMessage("null"), Error: a.Error,
		CreatedAt: a.CreatedAt, DecidedAt: a.DecidedAt, AppliedAt: a.AppliedAt}
	if a.ResultJSON != "" {
		out.Result = json.RawMessage(a.ResultJSON)
	}
	return out
}

type actionEnvelope struct {
	OK        bool       `json:"ok"`
	Action    actionJSON `json:"action"`
	AppliedOK bool       `json:"applied_ok"`
	Error     string     `json:"error"`
}

func openActionsCmd() (*config.Config, *db.DB, *tools.Registry, error) {
	cfg, database, err := openJiraCmdDB()
	if err != nil {
		return nil, nil, nil, err
	}
	return cfg, database, buildToolRegistry(cfg, database), nil
}

func writeJSON(w io.Writer, v any) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}

func parseActionID(arg string) (int64, error) {
	id, err := strconv.ParseInt(arg, 10, 64)
	if err != nil || id <= 0 {
		return 0, fmt.Errorf("invalid action id %q", arg)
	}
	return id, nil
}

func printAction(w io.Writer, a db.AgentAction) {
	fmt.Fprintf(w, "#%d %s [%s] %s\n", a.ID, a.Tool, a.Status, a.Reason)
	fmt.Fprintf(w, "  args:   %s\n", a.ArgsJSON)
	if a.ResultJSON != "" {
		fmt.Fprintf(w, "  result: %s\n", a.ResultJSON)
	}
	if a.Error != "" {
		fmt.Fprintf(w, "  error:  %s\n", a.Error)
	}
}

func runActionsList(cmd *cobra.Command, _ []string) error {
	_, database, _, err := openActionsCmd()
	if err != nil {
		return err
	}
	defer database.Close()
	rows, err := database.ListAgentActions(db.AgentActionFilter{Status: actionsFlagStatus, ConversationID: actionsFlagConversation, Limit: 200})
	if err != nil {
		return err
	}
	if actionsFlagJSON {
		out := make([]actionJSON, 0, len(rows))
		for _, r := range rows {
			out = append(out, toActionJSON(r))
		}
		return writeJSON(cmd.OutOrStdout(), out)
	}
	for _, r := range rows {
		printAction(cmd.OutOrStdout(), r)
	}
	return nil
}

func runActionsShow(cmd *cobra.Command, args []string) error {
	id, err := parseActionID(args[0])
	if err != nil {
		return err
	}
	_, database, _, err := openActionsCmd()
	if err != nil {
		return err
	}
	defer database.Close()
	row, err := database.GetAgentAction(id)
	if err != nil {
		return err
	}
	if row == nil {
		return fmt.Errorf("no action #%d", id)
	}
	if actionsFlagJSON {
		return writeJSON(cmd.OutOrStdout(), toActionJSON(*row))
	}
	printAction(cmd.OutOrStdout(), *row)
	return nil
}

// decideAndMaybeApply is approve/reject/apply's shared core. The status
// change is the persisted outcome (exit 0 once it landed); execution is
// reported separately through applied_ok/error — the recap_ok precedent —
// so a Jira failure never masquerades as "the approve did not happen".
func decideAndMaybeApply(cmd *cobra.Command, idArg string, from []string, to string, execute bool) error {
	id, err := parseActionID(idArg)
	if err != nil {
		return err
	}
	_, database, reg, err := openActionsCmd()
	if err != nil {
		return err
	}
	defer database.Close()
	if to != "" {
		ok, err := database.TransitionAgentAction(id, from, to, "", "")
		if err != nil {
			return err
		}
		if !ok {
			row, _ := database.GetAgentAction(id)
			if row == nil {
				return fmt.Errorf("no action #%d", id)
			}
			return fmt.Errorf("action #%d is %s, cannot %s it", id, row.Status, to)
		}
	}
	env := actionEnvelope{OK: true}
	var row *db.AgentAction
	if execute {
		row, err = reg.Apply(context.Background(), id)
		if errors.Is(err, tools.ErrBadTransition) || errors.Is(err, tools.ErrNotFound) {
			return err
		}
		if err != nil {
			return err
		}
		env.AppliedOK = row.Status == "applied"
		env.Error = row.Error
	} else {
		row, err = database.GetAgentAction(id)
		if err != nil {
			return err
		}
	}
	env.Action = toActionJSON(*row)
	if actionsFlagJSON {
		return writeJSON(cmd.OutOrStdout(), env)
	}
	printAction(cmd.OutOrStdout(), *row)
	return nil
}

func runActionsApprove(cmd *cobra.Command, args []string) error {
	return decideAndMaybeApply(cmd, args[0], []string{"pending"}, "approved", true)
}

func runActionsReject(cmd *cobra.Command, args []string) error {
	return decideAndMaybeApply(cmd, args[0], []string{"pending"}, "rejected", false)
}

func runActionsApply(cmd *cobra.Command, args []string) error {
	return decideAndMaybeApply(cmd, args[0], nil, "", true)
}

func runActionsTrust(cmd *cobra.Command, args []string) error {
	_, database, reg, err := openActionsCmd()
	if err != nil {
		return err
	}
	defer database.Close()
	if err := reg.SetTrust(args[0], tools.Trust(args[1])); err != nil {
		return err
	}
	fmt.Fprintf(cmd.OutOrStdout(), "%s: trust = %s\n", args[0], args[1])
	return nil
}

type toolJSON struct {
	Name        string   `json:"name"`
	Description string   `json:"description"`
	Access      string   `json:"access"`
	External    bool     `json:"external"`
	Surfaces    []string `json:"surfaces"`
	Trust       string   `json:"trust"`
}

func runActionsTools(cmd *cobra.Command, _ []string) error {
	_, database, reg, err := openActionsCmd()
	if err != nil {
		return err
	}
	defer database.Close()
	var listed []*tools.Tool
	if actionsFlagSurface != "" {
		listed = reg.List(actionsFlagSurface)
	} else {
		listed = reg.All()
	}
	out := make([]toolJSON, 0, len(listed))
	for _, t := range listed {
		trust, err := reg.Trust(t.Name)
		if err != nil {
			return err
		}
		surfaces := t.Surfaces
		if surfaces == nil {
			surfaces = []string{}
		}
		out = append(out, toolJSON{Name: t.Name, Description: t.Description, Access: string(t.Access),
			External: t.External, Surfaces: surfaces, Trust: string(trust)})
	}
	if actionsFlagJSON {
		return writeJSON(cmd.OutOrStdout(), out)
	}
	for _, t := range out {
		fmt.Fprintf(cmd.OutOrStdout(), "%-20s %-6s external=%-5v trust=%s\n", t.Name, t.Access, t.External, t.Trust)
	}
	return nil
}
```

`runActionsTools` uses `reg.All()` — add it to `internal/tools/registry.go`:

```go
// All returns every registered tool in registration order.
func (r *Registry) All() []*Tool {
	out := make([]*Tool, 0, len(r.order))
	for _, name := range r.order {
		out = append(out, r.tools[name])
	}
	return out
}
```

- [ ] **Step 5: Add chat mode to `cmd/mcp.go`**

Flags and wiring:

```go
var (
	mcpFlagDBPath       string
	mcpFlagChat         bool
	mcpFlagSurface      string
	mcpFlagConversation int64
	mcpFlagTurn         string
	mcpFlagContextType  string
	mcpFlagContextID    string
)

func init() {
	rootCmd.AddCommand(mcpCmd)
	mcpCmd.Flags().StringVar(&mcpFlagDBPath, "db-path", "", "SQLite database path (overrides the workspace default)")
	mcpCmd.Flags().BoolVar(&mcpFlagChat, "chat", false, "assistant chat mode: mount write tools as proposals (never for external clients)")
	mcpCmd.Flags().StringVar(&mcpFlagSurface, "surface", "main", "chat surface for --chat: main|target")
	mcpCmd.Flags().Int64Var(&mcpFlagConversation, "conversation", 0, "chat conversation id for --chat")
	mcpCmd.Flags().StringVar(&mcpFlagTurn, "turn", "", "turn id for --chat (proposals attach to it)")
	mcpCmd.Flags().StringVar(&mcpFlagContextType, "context-type", "", "chat context type for --chat (e.g. target)")
	mcpCmd.Flags().StringVar(&mcpFlagContextID, "context-id", "", "chat context id for --chat")
}
```

In `runMCP`, replace the `SetReadOnly` block and the `opts` construction with:

```go
	opts := []internalmcp.ServerOption{
		internalmcp.WithSkillsDir(skills.Dir(cfg.WorkspaceDir())),
	}
	if mcpFlagChat {
		// Chat mode: the connection stays writable ONLY so the registry can
		// record proposals (agent_actions) — the tools themselves still never
		// write domain data on propose (AGENT-01). Dev mode below keeps the
		// query_only fence (AGENT-02 / DEV-01).
		if mcpFlagSurface != "main" && mcpFlagSurface != "target" {
			return fmt.Errorf("--surface must be main or target")
		}
		opts = append(opts, internalmcp.WithRegistry(buildToolRegistry(cfg, database), tools.Binding{
			Surface: mcpFlagSurface, ConversationID: mcpFlagConversation, TurnID: mcpFlagTurn,
			ContextType: mcpFlagContextType, ContextID: mcpFlagContextID,
		}))
	} else {
		// The MCP surface is read-only; enforce it at the connection level so even
		// a buggy handler cannot write. Must run after Open (migrations need writes).
		if err := database.SetReadOnly(); err != nil {
			return fmt.Errorf("enforcing read-only: %w", err)
		}
	}
```

(import `"watchtower/internal/tools"`; keep the memory options block as is, after this).

- [ ] **Step 6: Run tests**

Run: `go test ./cmd/ -run 'TestActions_|TestMCP' && go build ./...`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add cmd/actions.go cmd/actions_registry.go cmd/actions_test.go cmd/mcp.go internal/tools/registry.go
git commit -m "feat(cli): watchtower actions (approve/reject/apply/trust/tools) and mcp --chat mode"
```

---

### Task 8: `watchtower jira create`

**Files:**
- Create: `cmd/jira_create.go`, `cmd/jira_create_test.go`

**Interfaces:**
- Consumes: `tools.RunDirect`, `tools.NewCreateJiraIssue`, `jiraClientFactory`, `resolveJiraAccount`, the persistent `--account` flag (`jiraFlagAccount`).
- Produces: `watchtower jira create --project P --type T --summary S [--description-file F] [--label L]… [--priority X] [--json]` → `{"ok":true,"key":"ABC-7","url":"…"}` / `{"ok":false,"error":"…"}` exit 1.

- [ ] **Step 1: Write the failing test**

`cmd/jira_create_test.go`:

```go
package cmd

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func runJira(t *testing.T, args ...string) (string, error) {
	t.Helper()
	var out bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&out)
	rootCmd.SetArgs(append([]string{"jira"}, args...))
	err := rootCmd.Execute()
	rootCmd.SetArgs(nil)
	jiraFlagAccount = 0
	return out.String(), err
}

func TestJiraCreate_ValidatesBeforeTouchingJira(t *testing.T) {
	writeActionsConfig(t) // no Jira account connected
	out, err := runJira(t, "create", "--project", "ABC", "--type", "Task", "--summary", "s", "--json")
	require.Error(t, err)
	assert.Contains(t, out+err.Error(), "no Jira site")
}

func TestJiraCreate_ReadsDescriptionFile(t *testing.T) {
	writeActionsConfig(t)
	path := filepath.Join(t.TempDir(), "d.txt")
	require.NoError(t, os.WriteFile(path, []byte("body"), 0o600))
	// Still fails on the missing account, but AFTER the file was read — a
	// missing file must be the first error when the path is wrong.
	_, err := runJira(t, "create", "--project", "ABC", "--type", "Task", "--summary", "s", "--description-file", "/nonexistent")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "description-file")
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./cmd/ -run TestJiraCreate_`
Expected: FAIL — `unknown command "create" for "watchtower jira"`.

- [ ] **Step 3: Implement**

`cmd/jira_create.go`:

```go
package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"os"

	"github.com/spf13/cobra"

	"watchtower/internal/tools"
)

var (
	jiraCreateFlagProject     string
	jiraCreateFlagType        string
	jiraCreateFlagSummary     string
	jiraCreateFlagDescription string
	jiraCreateFlagLabels      []string
	jiraCreateFlagPriority    string
	jiraCreateFlagJSON        bool
)

var jiraCreateCmd = &cobra.Command{
	Use:   "create",
	Short: "Create a Jira issue (the CLI face of the create_jira_issue tool)",
	Long: `Create an issue on the connected Jira site and store it locally so it is
immediately visible to the read tools. Runs the same validation and execution
the assistant's create_jira_issue proposal runs on Approve — without a proposal.`,
	RunE: runJiraCreate,
}

func init() {
	jiraCmd.AddCommand(jiraCreateCmd)
	jiraCreateCmd.Flags().StringVar(&jiraCreateFlagProject, "project", "", "project key (required)")
	jiraCreateCmd.Flags().StringVar(&jiraCreateFlagType, "type", "", "issue type name, e.g. Task (required)")
	jiraCreateCmd.Flags().StringVar(&jiraCreateFlagSummary, "summary", "", "issue summary (required)")
	jiraCreateCmd.Flags().StringVar(&jiraCreateFlagDescription, "description-file", "", "plain-text description file")
	jiraCreateCmd.Flags().StringArrayVar(&jiraCreateFlagLabels, "label", nil, "label (repeatable)")
	jiraCreateCmd.Flags().StringVar(&jiraCreateFlagPriority, "priority", "", "priority name")
	jiraCreateCmd.Flags().BoolVar(&jiraCreateFlagJSON, "json", false, "output JSON")
	_ = jiraCreateCmd.MarkFlagRequired("project")
	_ = jiraCreateCmd.MarkFlagRequired("type")
	_ = jiraCreateCmd.MarkFlagRequired("summary")
}

func runJiraCreate(cmd *cobra.Command, _ []string) error {
	description := ""
	if jiraCreateFlagDescription != "" {
		b, err := os.ReadFile(jiraCreateFlagDescription)
		if err != nil {
			return fmt.Errorf("reading --description-file: %w", err)
		}
		description = string(b)
	}
	cfg, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()

	args, err := json.Marshal(map[string]any{
		"account_id": jiraFlagAccount, "project_key": jiraCreateFlagProject, "issue_type": jiraCreateFlagType,
		"summary": jiraCreateFlagSummary, "description": description, "labels": jiraCreateFlagLabels,
		"priority": jiraCreateFlagPriority, "reason": "created from the CLI",
	})
	if err != nil {
		return err
	}
	tool := tools.NewCreateJiraIssue(jiraClientFactory(cfg))
	out, err := tools.RunDirect(context.Background(), database, tool, args)
	if err != nil {
		if jiraCreateFlagJSON {
			_ = writeJSON(cmd.OutOrStdout(), map[string]any{"ok": false, "error": err.Error()})
		}
		return err
	}
	res := out.(map[string]any)
	if jiraCreateFlagJSON {
		return writeJSON(cmd.OutOrStdout(), map[string]any{"ok": true, "key": res["key"], "url": res["url"]})
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Created %s — %s\n", res["key"], res["url"])
	return nil
}
```

Note: `json.Marshal` of `"labels": nil` yields `null`; the tool's strict decoder accepts `null` for a slice. `"account_id": 0` is omitted-equivalent (0 = resolve the single account).

- [ ] **Step 4: Run tests**

Run: `go test ./cmd/ -run 'TestJiraCreate_|TestActions_'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add cmd/jira_create.go cmd/jira_create_test.go
git commit -m "feat(cli): jira create — the CLI face of create_jira_issue"
```

---

### Task 9: `ai query --tools chat` wiring; delete `--allowed-tools`

**Files:**
- Modify: `cmd/ai.go`, `internal/ai/client.go` (+ `internal/ai/client_test.go`), `internal/codex/client.go`, `internal/codex/mcp.go` (+ `internal/codex/mcp_test.go` or `client_test.go`)

**Interfaces:**
- Produces: `ai query … --tools chat --surface S --conversation N --turn T [--context-type X --context-id Y]`; `ai.(*Client).SetMCPArgs([]string)`, `codex.(*Client).SetMCPArgs([]string)`; a local interface in `cmd/ai.go`:
  ```go
  type mcpConfigurable interface{ SetMCPArgs(extra []string) }
  ```
  `--allowed-tools` removed.

- [ ] **Step 1: Write the failing Go tests**

Append to `internal/ai/client_test.go` (create the file if absent, package `ai`):

```go
func TestBuildMCPConfig_IncludesExtraArgs(t *testing.T) {
	c := NewClient("sonnet", "/tmp/w.db", "")
	c.SetMCPArgs([]string{"--chat", "--surface", "main", "--conversation", "12", "--turn", "abc"})
	cfg := c.buildMCPConfig()
	var parsed struct {
		Servers map[string]struct {
			Args []string `json:"args"`
		} `json:"mcpServers"`
	}
	if err := json.Unmarshal([]byte(cfg), &parsed); err != nil {
		t.Fatal(err)
	}
	got := parsed.Servers["watchtower"].Args
	want := []string{"mcp", "--db-path", "/tmp/w.db", "--chat", "--surface", "main", "--conversation", "12", "--turn", "abc"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("args = %v, want %v", got, want)
	}
}

func TestBuildArgs_NoAllowedToolsFlagLeak(t *testing.T) {
	c := NewClient("sonnet", "/tmp/w.db", "")
	args := c.buildArgs("sys", "hi", "stream-json", "")
	for _, a := range args {
		if a == "--allowed-tools" {
			t.Fatalf("legacy flag leaked into claude args")
		}
	}
}
```

Append to `internal/codex/client_test.go` (package `codex`):

```go
func TestMCPWorkDir_WritesExtraArgs(t *testing.T) {
	dir, err := mcpWorkDir("/tmp/w.db", []string{"--chat", "--surface", "target"})
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	b, err := os.ReadFile(filepath.Join(dir, ".codex", "config.toml"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), `args = ["mcp", "--db-path", "/tmp/w.db", "--chat", "--surface", "target"]`) {
		t.Fatalf("config.toml = %s", b)
	}
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `go test ./internal/ai/ ./internal/codex/ -run 'TestBuildMCPConfig|TestBuildArgs_NoAllowed|TestMCPWorkDir'`
Expected: FAIL — `SetMCPArgs` undefined / wrong arity.

- [ ] **Step 3: Implement on the claude client**

In `internal/ai/client.go` add a field and setter, and use it in `buildMCPConfig`:

```go
type Client struct {
	model     string
	dbPath    string // path to SQLite database for MCP server
	claudeCmd string // path to claude binary, default "claude"
	// mcpArgs are appended to `watchtower mcp --db-path <db>` — the chat
	// mode flags (--chat --surface … --conversation … --turn …) the Desktop
	// passes through `ai query --tools chat`. Empty = the read-only dev server.
	mcpArgs []string
}

// SetMCPArgs appends extra flags to the MCP server command (chat mode).
func (c *Client) SetMCPArgs(extra []string) { c.mcpArgs = extra }
```

and in `buildMCPConfig`:

```go
	args := append([]string{"mcp", "--db-path", c.dbPath}, c.mcpArgs...)
	cfg := map[string]any{
		"mcpServers": map[string]any{
			"watchtower": map[string]any{
				"command": watchtowerBinary(),
				"args":    args,
			},
		},
	}
```

Update the `--allowedTools` comment in `buildArgs` to say: "…the watchtower MCP server — read-only in dev mode; in chat mode its write tools only record proposals (see internal/tools), so the allowlist stays one entry."

- [ ] **Step 4: Implement on the codex client**

`internal/codex/client.go`: add `mcpArgs []string` to `Client`, `func (c *Client) SetMCPArgs(extra []string) { c.mcpArgs = extra }`, and call `mcpWorkDir(c.dbPath, c.mcpArgs)` in `Query` (and in `QuerySync` if it also calls `mcpWorkDir` — `grep -n mcpWorkDir internal/codex/*.go`). In `internal/codex/mcp.go` change the signature and the TOML rendering:

```go
func mcpWorkDir(dbPath string, extra []string) (string, error) {
	…
	args := append([]string{"mcp", "--db-path", dbPath}, extra...)
	quoted := make([]string, 0, len(args))
	for _, a := range args {
		quoted = append(quoted, strconv.Quote(a))
	}
	configContent := fmt.Sprintf("[mcp_servers.watchtower]\ncommand = %q\nargs = [%s]\n",
		watchtowerBinary(), strings.Join(quoted, ", "))
```

(imports `strconv`, `strings`). Fix every existing caller/test of `mcpWorkDir` to pass `nil`.

- [ ] **Step 5: Wire `ai query`**

In `cmd/ai.go` replace `aiFlagAllowedTools` with:

```go
	aiFlagTools        string
	aiFlagSurface      string
	aiFlagConversation int64
	aiFlagTurn         string
	aiFlagContextType  string
	aiFlagContextID    string
```

flags (delete the `--allowed-tools` line):

```go
	aiQueryCmd.Flags().StringVar(&aiFlagTools, "tools", "", "tool mode: chat = mount the assistant's write tools as proposals")
	aiQueryCmd.Flags().StringVar(&aiFlagSurface, "surface", "main", "chat surface for --tools chat: main|target")
	aiQueryCmd.Flags().Int64Var(&aiFlagConversation, "conversation", 0, "chat conversation id for --tools chat")
	aiQueryCmd.Flags().StringVar(&aiFlagTurn, "turn", "", "turn id for --tools chat")
	aiQueryCmd.Flags().StringVar(&aiFlagContextType, "context-type", "", "chat context type (e.g. target)")
	aiQueryCmd.Flags().StringVar(&aiFlagContextID, "context-id", "", "chat context id")
```

and after `aiClient := newAIClientWithModel(...)`:

```go
	if aiFlagTools == "chat" {
		if c, ok := aiClient.(mcpConfigurable); ok {
			c.SetMCPArgs(chatMCPArgs())
		}
	}
```

with, at file bottom:

```go
// mcpConfigurable is implemented by the CLI-backed providers (claude, codex)
// that relaunch this binary as an MCP server. Ollama has no tools at all, so
// the flag is a no-op there — the Desktop already builds an honest prompt.
type mcpConfigurable interface{ SetMCPArgs(extra []string) }

func chatMCPArgs() []string {
	args := []string{"--chat", "--surface", aiFlagSurface, "--conversation", strconv.FormatInt(aiFlagConversation, 10), "--turn", aiFlagTurn}
	if aiFlagContextType != "" {
		args = append(args, "--context-type", aiFlagContextType, "--context-id", aiFlagContextID)
	}
	return args
}
```

(import `strconv`). Add a cmd test in `cmd/ai_test.go` (create if absent):

```go
func TestChatMCPArgs_Shape(t *testing.T) {
	aiFlagSurface, aiFlagConversation, aiFlagTurn, aiFlagContextType, aiFlagContextID = "target", 7, "t1", "target", "42"
	t.Cleanup(func() { aiFlagSurface, aiFlagConversation, aiFlagTurn, aiFlagContextType, aiFlagContextID = "main", 0, "", "", "" })
	got := chatMCPArgs()
	want := []string{"--chat", "--surface", "target", "--conversation", "7", "--turn", "t1", "--context-type", "target", "--context-id", "42"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v", got)
	}
}
```

- [ ] **Step 6: Run tests and build**

Run: `go build ./... && go test ./internal/ai/ ./internal/codex/ ./cmd/ -run 'TestBuildMCPConfig|TestBuildArgs|TestMCPWorkDir|TestChatMCPArgs|TestAI'`
Expected: PASS. Then `make lint-diff` — Expected: no new issues.

- [ ] **Step 7: Commit**

```bash
git add cmd/ai.go cmd/ai_test.go internal/ai internal/codex
git commit -m "feat(ai): ai query --tools chat relaunches the MCP server in chat mode; drop dead --allowed-tools"
```

---

### Task 10: Contracts and docs (Go side)

**Files:**
- Create: `docs/inventory/agent-actions.md`
- Modify: `docs/inventory/README.md` (module row), `docs/inventory/dev-surface.md` (DEV-01 note + changelog), `docs/inventory/targets.md` (changelog), `docs/review/review-rules.md` ("The assistant & chat contracts"), `CLAUDE.md` (new feature note)

- [ ] **Step 1: Write `docs/inventory/agent-actions.md`**

```markdown
# Agent Actions — Behavior Inventory

**Module:** `internal/tools/`, `internal/db/agent_actions.go`, `internal/mcp/actions.go` (chat mode), `cmd/actions.go`, `cmd/mcp.go` (`--chat`), `WatchtowerDesktop/Sources/WatchtowerCore/Services/Actions/`
**Spec:** `docs/superpowers/specs/2026-09-04-agent-actions-design.md`
**Last full audit:** 2026-09-04

## AGENT-01 — The model never writes

**Status:** Enforced

**Observable:** Every write-tool call that reaches the chat-mode MCP server becomes one `agent_actions` row and nothing else. With trust `ask` (the default) no data table changes on the call; the tool's `Execute` runs only from `Registry.Apply`, which the Desktop drives after the owner approved. A validation failure writes no row at all.

**Why locked:** This is the whole premise of giving the assistant write tools at all — "model proposes, code disposes" (MEM-08) applied to actions. If a write tool ever executed on propose, every prompt-injection payload in synced Slack/Jira text would become an unreviewed write.

**Test guards:** `internal/mcp/actions_test.go` `TestAgent01_WriteToolCallRecordsProposalOnly` (guard tables byte-count-identical, one row); `internal/tools/registry_test.go` `TestPropose_RecordsPendingAndNeverExecutes`, `TestPropose_ValidationErrorWritesNoRow`.

**Locked since:** 2026-09-04

## AGENT-02 — Dev surface untouched

**Status:** Enforced

**Observable:** `watchtower mcp` without `--chat` registers no write tool and no `get_action`, and keeps `PRAGMA query_only=ON`. The chat mode is a separate entry point (`--chat`) that only the Desktop's `ai query --tools chat` launches.

**Why locked:** The dev-surface server is handed to external coding agents via `watchtower integrate`; DEV-01 promises them a read-only knowledge base. A proposal tool on that server would let a foreign agent file actions into the owner's app.

**Test guards:** `internal/mcp/actions_test.go` `TestAgent02_DevModeRegistersNoWriteTools`; `internal/mcp/server_test.go` `TestAllToolsAreReadOnly`, `TestNoToolMutatesDatabase` (dev mode).

**Locked since:** 2026-09-04

## AGENT-03 — External tools never auto-execute

**Status:** Enforced

**Observable:** `Registry.SetTrust(tool, execute)` returns `ErrExternalExecute` for a tool with `External: true` (`create_jira_issue`); `watchtower actions trust` surfaces that error; the Settings toggle is disabled for external tools.

**Why locked:** An external write cannot be undone by the app. The owner's click is the only thing standing between a model mistake and a ticket in a shared tracker.

**Test guards:** `internal/tools/registry_test.go` `TestAgent03_ExternalToolCannotBeExecuteTrust`; `cmd/actions_test.go` `TestActions_TrustAndTools`.

**Locked since:** 2026-09-04

## AGENT-04 — Draft-only surfaces see no tools

**Status:** Enforced

**Observable:** Only the main AI Chat (`ChatViewModel`) and the target chat (`TargetChatViewModel`) pass a `toolMode` to `WatchtowerAIService`; situation, meeting, idea, track and setup chats call the convenience overloads that forward `toolMode: nil`, so their `ai query` never carries `--tools chat` and the model there never sees a write tool.

**Why locked:** review-rules "The assistant & chat contracts": draft-only surfaces never act on the world. A copied VM that silently inherits the tool mode would give a draft-only surface an action path.

**Test guards:** `WatchtowerDesktop/Tests/Core/WatchtowerAIServiceTests.swift` (`--tools` emitted only with a toolMode); the `toolModes == [nil]` assertions in the situation/meeting/idea/track VM test suites.

**Locked since:** 2026-09-04

## AGENT-05 — Apply exactly once

**Status:** Enforced

**Observable:** `Registry.Apply` runs a tool only from `approved` or `failed`; `applied` and `rejected` are terminal and return `ErrBadTransition`. `watchtower actions approve` moves `pending → approved` with a conditional update, so two concurrent approves cannot both execute.

**Why locked:** External writes are not idempotent; a double apply is a duplicate Jira issue.

**Test guards:** `internal/tools/registry_test.go` `TestApply_ExecutesOnceAndRecordsResult`, `TestApply_FailureLandsFailedAndIsRetriable`; `internal/db/agent_actions_test.go` `TestAgentActions_TransitionIsConditional`; `cmd/actions_test.go` `TestActions_RejectAndTerminalStates`.

**Locked since:** 2026-09-04

## Changelog

- 2026-09-04: file created with AGENT-01..05, all Enforced, by the agent-actions feature (sub-project 1 of the "Hermes inside Watchtower" initiative).
```

- [ ] **Step 2: Cross-reference the other inventory files**

- `docs/inventory/README.md`: add the row
  `| Agent actions | [agent-actions.md](agent-actions.md) | `internal/tools/`, `internal/db/agent_actions.go`, `internal/mcp/actions.go`, `cmd/actions.go`, `cmd/mcp.go` (`--chat`), `WatchtowerDesktop/Sources/WatchtowerCore/Services/Actions/`, `WatchtowerDesktop/Sources/Views/Chat/AgentActionCardView.swift` |`
- `docs/inventory/dev-surface.md`, under DEV-01's Observable, append the paragraph: "The chat-mode server (`watchtower mcp --chat`, launched only by the Desktop's `ai query --tools chat`) is a separate entry point governed by AGENT-01/02 (`agent-actions.md`); it mounts write tools that record proposals and is never registered for external clients." Add a changelog line dated 2026-09-04.
- `docs/inventory/targets.md` changelog: "2026-09-04: the agent-actions registry adds two write tools behind Approve. `create_target` is offered on the main chat only — the target chat's mandate (TGT-BRIEF-01 axis 3) forbids creating work outside the vertical line. `create_jira_issue` is offered on the target chat: a Jira issue is an external artifact outside the target mandate, still behind Approve. The block grammar and TGT-BRIEF-01..03 are unchanged."
- `docs/review/review-rules.md`, in "The assistant & chat contracts", extend the Action surfaces bullet: "…or through the tool registry's proposal path (`agent_actions`, AGENT-01..05) — both land behind Approve; a draft-only surface must never receive `toolMode` (AGENT-04)."

- [ ] **Step 3: CLAUDE.md feature note**

Add a `### Agent Actions — tool registry + controlled writes (2026-09-04)` section after the Persona Merge note, ≤ 8 bullets: registry = core / MCP = adapter, chat mode vs dev mode, proposal rows + trust, the two tools and their surfaces, `actions` CLI + `jira create`, Desktop feed/cards/turn_id, contracts file, and the mandatory runtime-B follow-up (Go loop for HTTP providers; existing read tools migrate then).

- [ ] **Step 4: Commit**

```bash
git add docs/inventory/agent-actions.md docs/inventory/README.md docs/inventory/dev-surface.md docs/inventory/targets.md docs/review/review-rules.md CLAUDE.md
git commit -m "docs: AGENT-01..05 contracts, inventory cross-references, CLAUDE.md note"
```

---

## Phase B — Swift (Desktop)

### Task 11: `chat_messages.turn_id`

**Files:**
- Modify: `WatchtowerDesktop/Sources/Database/Queries/ChatMessageQueries.swift`, `WatchtowerDesktop/Sources/Models/ChatMessageRecord.swift`, `WatchtowerDesktop/Sources/Database/DatabaseManager.swift:41-45`, `WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift:5-16` (`ChatMessage`)
- Test: `WatchtowerDesktop/Tests/ChatMessageTurnIDTests.swift`

**Interfaces:**
- Produces: `ChatMessageQueries.ensureTurnIDColumn(_:)`, `ChatMessageQueries.insert(_:conversationID:role:text:turnID:)` (`turnID` defaults to `""`), `ChatMessageRecord.turnID: String`, `ChatMessage.turnID: String?` (defaulted, so every existing memberwise call compiles).

- [ ] **Step 1: Write the failing test**

`WatchtowerDesktop/Tests/ChatMessageTurnIDTests.swift`:

```swift
import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

final class ChatMessageTurnIDTests: XCTestCase {
    func testEnsureTurnIDColumnIsIdempotentAndRoundTrips() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try manager.dbPool.write { db in
            try ChatConversationQueries.ensureTable(db)
            try ChatMessageQueries.ensureTable(db)
            try ChatMessageQueries.ensureTurnIDColumn(db)
            try ChatMessageQueries.ensureTurnIDColumn(db) // second call must not throw
            let conv = try ChatConversationQueries.create(db, title: "t")
            try ChatMessageQueries.insert(db, conversationID: conv.id, role: "assistant", text: "hi", turnID: "turn-1")
            try ChatMessageQueries.insert(db, conversationID: conv.id, role: "user", text: "yo")
        }
        let records = try manager.dbPool.read { db in
            try ChatMessageQueries.fetchByConversation(db, conversationID: 1)
        }
        XCTAssertEqual(records.map(\.turnID), ["turn-1", ""])
        XCTAssertEqual(records[0].toChatMessage().turnID, "turn-1")
        XCTAssertNil(records[1].toChatMessage().turnID)
    }

    func testDatabaseManagerAddsColumnToLegacyTable() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try manager.dbPool.write { db in
            try ChatConversationQueries.ensureTable(db)
            try ChatMessageQueries.ensureTable(db) // legacy shape, no turn_id
        }
        try manager.dbPool.write { db in try ChatMessageQueries.ensureTurnIDColumn(db) }
        let columns = try manager.dbPool.read { db in try db.columns(in: "chat_messages").map(\.name) }
        XCTAssertTrue(columns.contains("turn_id"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd WatchtowerDesktop && swift test --filter ChatMessageTurnIDTests`
Expected: compile error — `ensureTurnIDColumn` undefined.

- [ ] **Step 3: Implement**

`ChatMessageQueries.swift` — add after `ensureTable`:

```swift
    /// `turn_id` joins a persisted assistant message to the agent_actions rows
    /// proposed during that turn (the Desktop-generated UUID passed to
    /// `ai query --turn`). Guarded ALTER, the `ensureContextColumns` precedent.
    static func ensureTurnIDColumn(_ db: Database) throws {
        let columns = try db.columns(in: "chat_messages").map(\.name)
        if !columns.contains("turn_id") {
            try db.execute(sql: "ALTER TABLE chat_messages ADD COLUMN turn_id TEXT NOT NULL DEFAULT ''")
        }
    }
```

change `insert`:

```swift
    @discardableResult
    static func insert(_ db: Database, conversationID: Int64, role: String, text: String, turnID: String = "") throws -> Int64 {
        let now = Date().timeIntervalSince1970
        try db.execute(sql: """
            INSERT INTO chat_messages (conversation_id, role, text, created_at, turn_id) VALUES (?, ?, ?, ?, ?)
        """, arguments: [conversationID, role, text, now, turnID])
        return db.lastInsertedRowID
    }
```

Include `turn_id TEXT NOT NULL DEFAULT ''` in `ensureTable`'s `CREATE TABLE IF NOT EXISTS` so fresh installs get it directly (the ALTER covers upgrades). `ChatMessageRecord.swift`: add `let turnID: String` with `case turnID = "turn_id"` and pass `turnID: turnID.isEmpty ? nil : turnID` into `ChatMessage`. `ChatViewModel.swift`'s `ChatMessage`: add `var turnID: String? = nil` as the LAST stored property. `DatabaseManager.swift`: call `try ChatMessageQueries.ensureTurnIDColumn(db)` right after `ensureTable(db)`.

- [ ] **Step 4: Run tests**

Run: `cd WatchtowerDesktop && swift test --filter 'ChatMessageTurnIDTests|DatabaseManagerTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Database WatchtowerDesktop/Sources/Models/ChatMessageRecord.swift WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift WatchtowerDesktop/Tests/ChatMessageTurnIDTests.swift
git commit -m "feat(desktop): chat_messages.turn_id joins assistant turns to their proposals"
```

---

### Task 12: Core model + queries for `agent_actions`; test schema

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Models/AgentAction.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/AgentActionQueries.swift`, `WatchtowerDesktop/Tests/Core/AgentActionQueriesTests.swift`
- Modify: `WatchtowerDesktop/Tests/Support/TestDatabase.swift` (schema + `insertAgentAction` fixture)

**Interfaces:**
- Produces:
  ```swift
  package struct AgentAction: FetchableRecord, Identifiable, Equatable, Sendable {
      package let id: Int64; tool: String; external: Bool; argsJSON: String; reason: String; surface: String
      conversationID: Int64; contextType: String; contextID: String; turnID: String; status: String
      trustAtCreate: String; resultJSON: String; error: String; createdAt: String; decidedAt: String; appliedAt: String
      package var args: [String: Any]; package var result: [String: Any]
      package func argString(_ key: String) -> String?; package func resultString(_ key: String) -> String?
      package var isPending: Bool; isTerminal: Bool; canRetry: Bool
  }
  package enum AgentActionQueries {
      static func fetchByConversation(_ db: Database, conversationID: Int64) throws -> [AgentAction]
      static func fetchDecidedAfter(_ db: Database, conversationID: Int64, after: String) throws -> [AgentAction]
  }
  ```

- [ ] **Step 1: Extend the Swift test schema**

In `WatchtowerDesktop/Tests/Support/TestDatabase.swift`, append to the `schema` string (before its closing `"""`) the two `CREATE TABLE IF NOT EXISTS` statements from Task 1, verbatim (indexes optional), and add a fixture next to `insertJiraAccount`:

```swift
    @discardableResult
    package static func insertAgentAction(
        _ db: Database,
        tool: String = "create_target",
        external: Bool = false,
        argsJSON: String = #"{"text":"Call Vasya","reason":"r"}"#,
        reason: String = "r",
        surface: String = "main",
        conversationID: Int64 = 1,
        turnID: String = "turn-1",
        status: String = "pending",
        resultJSON: String = "",
        error: String = "",
        createdAt: String = "2026-09-04T10:00:00Z",
        decidedAt: String = "",
        appliedAt: String = ""
    ) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO agent_actions
                (tool, external, args_json, reason, surface, conversation_id, turn_id, status,
                 result_json, error, created_at, decided_at, applied_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [tool, external, argsJSON, reason, surface, conversationID, turnID, status,
                             resultJSON, error, createdAt, decidedAt, appliedAt])
        return db.lastInsertedRowID
    }
```

- [ ] **Step 2: Write the failing tests**

`WatchtowerDesktop/Tests/Core/AgentActionQueriesTests.swift`:

```swift
import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

final class AgentActionQueriesTests: XCTestCase {
    func testFetchByConversationOrdersAndDecodes() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try TestDatabase.insertAgentAction(db, conversationID: 1, turnID: "a", createdAt: "2026-09-04T10:00:01Z")
            try TestDatabase.insertAgentAction(db, tool: "create_jira_issue", external: true,
                argsJSON: #"{"project_key":"ABC","issue_type":"Task","summary":"Fix","reason":"r"}"#,
                conversationID: 1, turnID: "b", status: "applied",
                resultJSON: #"{"key":"ABC-7","url":"https://x/browse/ABC-7"}"#,
                createdAt: "2026-09-04T10:00:00Z", appliedAt: "2026-09-04T10:05:00Z")
            try TestDatabase.insertAgentAction(db, conversationID: 2)
        }
        let rows = try queue.read { db in try AgentActionQueries.fetchByConversation(db, conversationID: 1) }
        XCTAssertEqual(rows.map(\.turnID), ["b", "a"], "oldest first by created_at")
        let jira = rows[0]
        XCTAssertTrue(jira.external)
        XCTAssertEqual(jira.argString("summary"), "Fix")
        XCTAssertEqual(jira.resultString("key"), "ABC-7")
        XCTAssertTrue(jira.isTerminal)
        XCTAssertFalse(jira.canRetry)
        XCTAssertTrue(rows[1].isPending)
    }

    func testFetchDecidedAfterUsesDecidedOrApplied() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try TestDatabase.insertAgentAction(db, status: "rejected", decidedAt: "2026-09-04T10:00:00Z")
            try TestDatabase.insertAgentAction(db, status: "applied", decidedAt: "2026-09-04T09:00:00Z", appliedAt: "2026-09-04T10:30:00Z")
            try TestDatabase.insertAgentAction(db, status: "pending")
            try TestDatabase.insertAgentAction(db, status: "failed", appliedAt: "2026-09-04T08:00:00Z")
        }
        let rows = try queue.read { db in
            try AgentActionQueries.fetchDecidedAfter(db, conversationID: 1, after: "2026-09-04T09:30:00Z")
        }
        XCTAssertEqual(rows.map(\.status), ["rejected", "applied"])
        XCTAssertTrue(try queue.read { db in
            try AgentActionQueries.fetchDecidedAfter(db, conversationID: 1, after: "2026-09-05T00:00:00Z")
        }.isEmpty)
    }

    func testStateFlags() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try TestDatabase.insertAgentAction(db, status: "failed", error: "boom")
        }
        let row = try queue.read { db in try AgentActionQueries.fetchByConversation(db, conversationID: 1) }[0]
        XCTAssertTrue(row.canRetry)
        XCTAssertFalse(row.isPending)
        XCTAssertFalse(row.isTerminal)
        XCTAssertEqual(row.error, "boom")
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `cd WatchtowerDesktop && swift test --filter AgentActionQueriesTests`
Expected: compile error — `AgentAction` undefined.

- [ ] **Step 4: Implement**

`Sources/WatchtowerCore/Models/AgentAction.swift`:

```swift
import Foundation
import GRDB

/// One agent_actions row — a write-tool proposal the assistant made. Go owns
/// every status transition (`watchtower actions …`); the Desktop only reads
/// and observes. Mirrors `internal/db/agent_actions.go`.
package struct AgentAction: FetchableRecord, Identifiable, Equatable, Sendable {
    package let id: Int64
    package let tool: String
    package let external: Bool
    package let argsJSON: String
    package let reason: String
    package let surface: String
    package let conversationID: Int64
    package let contextType: String
    package let contextID: String
    package let turnID: String
    package let status: String
    package let trustAtCreate: String
    package let resultJSON: String
    package let error: String
    package let createdAt: String
    package let decidedAt: String
    package let appliedAt: String

    package init(row: Row) {
        id = row["id"]
        tool = row["tool"]
        external = row["external"] ?? false
        argsJSON = row["args_json"] ?? ""
        reason = row["reason"] ?? ""
        surface = row["surface"] ?? ""
        conversationID = row["conversation_id"] ?? 0
        contextType = row["context_type"] ?? ""
        contextID = row["context_id"] ?? ""
        turnID = row["turn_id"] ?? ""
        status = row["status"] ?? "pending"
        trustAtCreate = row["trust_at_create"] ?? "ask"
        resultJSON = row["result_json"] ?? ""
        error = row["error"] ?? ""
        createdAt = row["created_at"] ?? ""
        decidedAt = row["decided_at"] ?? ""
        appliedAt = row["applied_at"] ?? ""
    }

    package var isPending: Bool { status == "pending" }
    package var isTerminal: Bool { status == "applied" || status == "rejected" }
    package var canRetry: Bool { status == "failed" }

    package var args: [String: Any] { Self.object(argsJSON) }
    package var result: [String: Any] { Self.object(resultJSON) }

    package func argString(_ key: String) -> String? { Self.stringValue(args[key]) }
    package func resultString(_ key: String) -> String? { Self.stringValue(result[key]) }

    private static func object(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case let a as [Any]: return a.compactMap { stringValue($0) }.joined(separator: ", ")
        default: return nil
        }
    }
}
```

`Sources/WatchtowerCore/Database/Queries/AgentActionQueries.swift`:

```swift
import GRDB

package enum AgentActionQueries {
    /// Every proposal of one conversation, oldest first — the feed's
    /// observation query.
    package static func fetchByConversation(_ db: Database, conversationID: Int64) throws -> [AgentAction] {
        try AgentAction.fetchAll(db, sql: """
            SELECT * FROM agent_actions WHERE conversation_id = ?
            ORDER BY created_at ASC, id ASC
            """, arguments: [conversationID])
    }

    /// Proposals decided or executed after `after` (an RFC3339 UTC string —
    /// the column format, so a string compare is a time compare). Feeds the
    /// "actions since your last message" block.
    package static func fetchDecidedAfter(_ db: Database, conversationID: Int64, after: String) throws -> [AgentAction] {
        try AgentAction.fetchAll(db, sql: """
            SELECT * FROM agent_actions
            WHERE conversation_id = ? AND (decided_at > ? OR applied_at > ?)
            ORDER BY created_at ASC, id ASC
            """, arguments: [conversationID, after, after])
    }
}
```

- [ ] **Step 5: Run tests**

Run: `cd WatchtowerDesktop && swift test --filter AgentActionQueriesTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add WatchtowerDesktop/Sources/WatchtowerCore/Models/AgentAction.swift WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/AgentActionQueries.swift WatchtowerDesktop/Tests/Core/AgentActionQueriesTests.swift WatchtowerDesktop/Tests/Support/TestDatabase.swift
git commit -m "feat(desktop): AgentAction model and queries over agent_actions"
```

---

### Task 13: `ChatToolMode` through the AI service (replaces `extraAllowedTools`)

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Actions/ChatToolMode.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/ClaudeService.swift` (protocol + overloads), `WatchtowerDesktop/Sources/WatchtowerCore/Services/WatchtowerAIService.swift`, `WatchtowerDesktop/Tests/Support/MockClaudeService.swift`, `WatchtowerDesktop/Sources/Views/Tracks/TrackChatView.swift:169`, `WatchtowerDesktop/Tests/ViewModelTests.swift:511`, `WatchtowerDesktop/Tests/Core/WatchtowerAIServiceTests.swift`

**Interfaces:**
- Produces:
  ```swift
  package struct ChatToolMode: Equatable, Sendable {
      package let surface: String; conversationID: Int64; turnID: String; contextType: String?; contextID: String?
      package var cliArgs: [String]
  }
  ```
  `AIServiceProtocol.stream(prompt:systemPrompt:sessionID:dbPath:model:provider:toolMode:)`; `WatchtowerAIService.buildArgs(…, toolMode: ChatToolMode?)`; `MockClaudeService.toolModes: [ChatToolMode?]`.

- [ ] **Step 1: Write the failing tests**

Replace the four `extraAllowedTools: []` arguments in `Tests/Core/WatchtowerAIServiceTests.swift` with `toolMode: nil` and add:

```swift
    func testBuildArgsEmitsChatToolModeFlags() {
        let mode = ChatToolMode(surface: "target", conversationID: 7, turnID: "t1", contextType: "target", contextID: "42")
        let args = WatchtowerAIService.buildArgs(
            prompt: "hi", systemPrompt: nil, sessionID: nil, dbPath: "/tmp/w.db", model: nil, provider: nil, toolMode: mode
        )
        XCTAssertEqual(args, ["ai", "query", "hi", "--db-path", "/tmp/w.db",
                              "--tools", "chat", "--surface", "target", "--conversation", "7", "--turn", "t1",
                              "--context-type", "target", "--context-id", "42"])
    }

    /// AGENT-04: no toolMode → no --tools flag, ever. And the retired
    /// --allowed-tools flag is gone for good.
    func testBuildArgsWithoutToolModeNeverEmitsToolsFlag() {
        let args = WatchtowerAIService.buildArgs(
            prompt: "hi", systemPrompt: "s", sessionID: "sid", dbPath: "/tmp/w.db", model: "m", provider: "claude", toolMode: nil
        )
        XCTAssertFalse(args.contains("--tools"))
        XCTAssertFalse(args.contains("--allowed-tools"))
    }

    func testChatToolModeMainOmitsContext() {
        let mode = ChatToolMode(surface: "main", conversationID: 3, turnID: "x")
        XCTAssertEqual(mode.cliArgs, ["--tools", "chat", "--surface", "main", "--conversation", "3", "--turn", "x"])
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd WatchtowerDesktop && swift test --filter WatchtowerAIServiceTests`
Expected: compile error — `ChatToolMode` undefined.

- [ ] **Step 3: Implement**

`Sources/WatchtowerCore/Services/Actions/ChatToolMode.swift`:

```swift
import Foundation

/// The chat-mode binding a chat VM hands to `watchtower ai query`: which
/// surface is speaking, which conversation, and the turn id proposals made
/// during this turn attach to. Only the main AI Chat and the target chat
/// ever build one (AGENT-04); every other surface passes nil.
package struct ChatToolMode: Equatable, Sendable {
    package let surface: String
    package let conversationID: Int64
    package let turnID: String
    package let contextType: String?
    package let contextID: String?

    package init(surface: String, conversationID: Int64, turnID: String, contextType: String? = nil, contextID: String? = nil) {
        self.surface = surface
        self.conversationID = conversationID
        self.turnID = turnID
        self.contextType = contextType
        self.contextID = contextID
    }

    package var cliArgs: [String] {
        var args = ["--tools", "chat", "--surface", surface, "--conversation", String(conversationID), "--turn", turnID]
        if let contextType, let contextID {
            args += ["--context-type", contextType, "--context-id", contextID]
        }
        return args
    }
}
```

`ClaudeService.swift`: in the protocol replace `extraAllowedTools: [String]` with `toolMode: ChatToolMode?`; in every convenience overload of the `extension AIServiceProtocol` forward `toolMode: nil` (the 4-argument `stream(prompt:systemPrompt:sessionID:dbPath:)` and the `model:` variant the target chat uses — `grep -n 'package func stream' Sources/WatchtowerCore/Services/ClaudeService.swift` lists them all). Add one more overload the two action surfaces will use:

```swift
    package func stream(
        prompt: String, systemPrompt: String?, sessionID: String?, dbPath: String?,
        model: String?, provider: String?, toolMode: ChatToolMode?
    ) -> AsyncThrowingStream<StreamEvent, Error>
```

is the protocol requirement itself, so nothing extra is needed beyond forwarding `nil` in the convenience overloads.

`WatchtowerAIService.swift`: rename the parameter in `stream`, `run` and `buildArgs` to `toolMode: ChatToolMode?` and replace the `extraAllowedTools` branch in `buildArgs` with:

```swift
        if let toolMode {
            args += toolMode.cliArgs
        }
```

`Tests/Support/MockClaudeService.swift`: rename the parameter, add

```swift
    private var _toolModes: [ChatToolMode?] = []
    /// Every toolMode passed to `stream`, in call order — nil on every
    /// draft-only surface (AGENT-04).
    package var toolModes: [ChatToolMode?] { lock.withLock { _toolModes } }
```

and `_toolModes.append(toolMode)` inside the lock. `TrackChatView.swift:169`: replace `extraAllowedTools: []` (and its comment) with `toolMode: nil` — keep a one-line comment: `// Draft-only surface: never a tool mode (AGENT-04).` `Tests/ViewModelTests.swift:511` (`StallingMockService`): rename the parameter.

- [ ] **Step 4: Build and run tests**

Run: `cd WatchtowerDesktop && swift build && swift test --filter 'WatchtowerAIServiceTests|WorkspaceOverviewViewModelTests|ChatViewModelTests'`
Expected: PASS; `grep -rn extraAllowedTools Sources Tests` returns nothing.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources WatchtowerDesktop/Tests
git commit -m "feat(desktop): ChatToolMode replaces the dead extraAllowedTools plumbing"
```

---

### Task 14: `AgentToolsContract` prompt block

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Actions/AgentToolsContract.swift`, `WatchtowerDesktop/Tests/Core/AgentToolsContractTests.swift`

**Interfaces:**
- Produces:
  ```swift
  package enum AgentSurface: String, Sendable { case main, target }
  package enum AgentToolsContract {
      package static func promptBlock(surface: AgentSurface) -> String
      package static let noToolsBlock: String
      package static func actionsSinceLastTurnBlock(_ rows: [AgentAction]) -> String?   // nil when rows is empty
  }
  ```

- [ ] **Step 1: Write the failing tests**

`Tests/Core/AgentToolsContractTests.swift`:

```swift
import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

final class AgentToolsContractTests: XCTestCase {
    func testMainBlockListsBothWriteTools() {
        let block = AgentToolsContract.promptBlock(surface: .main)
        XCTAssertTrue(block.contains("=== AGENT ACTIONS ==="))
        XCTAssertTrue(block.contains("create_target"))
        XCTAssertTrue(block.contains("create_jira_issue"))
        XCTAssertTrue(block.contains("list_jira_projects"))
        XCTAssertTrue(block.contains("get_action"))
        XCTAssertTrue(block.contains("never claim"))
        XCTAssertTrue(block.contains("awaits their approval"))
    }

    func testTargetBlockOmitsCreateTargetAndDrawsTheLine() {
        let block = AgentToolsContract.promptBlock(surface: .target)
        XCTAssertFalse(block.contains("create_target"))
        XCTAssertTrue(block.contains("create_jira_issue"))
        XCTAssertTrue(block.contains("watchtower-action"), "coexistence rule with the block grammar")
    }

    func testNoToolsBlockIsHonest() {
        XCTAssertTrue(AgentToolsContract.noToolsBlock.contains("No tools are connected"))
        XCTAssertFalse(AgentToolsContract.noToolsBlock.contains("create_"))
    }

    func testActionsSinceLastTurnRendersOutcomes() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try TestDatabase.insertAgentAction(db, tool: "create_jira_issue", status: "applied",
                resultJSON: #"{"key":"ABC-7","url":"https://x/browse/ABC-7"}"#, appliedAt: "2026-09-04T10:05:00Z")
            try TestDatabase.insertAgentAction(db, status: "rejected", decidedAt: "2026-09-04T10:06:00Z")
            try TestDatabase.insertAgentAction(db, status: "failed", error: "issuetype: invalid", appliedAt: "2026-09-04T10:07:00Z")
        }
        let rows = try queue.read { db in try AgentActionQueries.fetchByConversation(db, conversationID: 1) }
        let block = try XCTUnwrap(AgentToolsContract.actionsSinceLastTurnBlock(rows))
        XCTAssertTrue(block.hasPrefix("=== ACTIONS SINCE YOUR LAST MESSAGE ==="))
        XCTAssertTrue(block.contains("#1 create_jira_issue: applied"))
        XCTAssertTrue(block.contains("ABC-7"))
        XCTAssertTrue(block.contains("#2 create_target: rejected"))
        XCTAssertTrue(block.contains("#3 create_target: failed — issuetype: invalid"))
        XCTAssertNil(AgentToolsContract.actionsSinceLastTurnBlock([]))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd WatchtowerDesktop && swift test --filter AgentToolsContractTests`
Expected: compile error.

- [ ] **Step 3: Implement**

`Sources/WatchtowerCore/Services/Actions/AgentToolsContract.swift`:

```swift
import Foundation

package enum AgentSurface: String, Sendable {
    case main
    case target
}

/// The system-prompt block that teaches an action surface how write tools
/// work: they create PROPOSALS the owner approves in the chat. Shared by the
/// main AI Chat and the target chat (the two action surfaces, AGENT-04).
package enum AgentToolsContract {
    package static func promptBlock(surface: AgentSurface) -> String {
        let tools: String
        let coexistence: String
        switch surface {
        case .main:
            tools = """
            - create_target — propose a new task or reminder (a task with a due date) in the owner's task list.
            - create_jira_issue — propose a Jira issue on a connected site.
            """
            coexistence = ""
        case .target:
            tools = """
            - create_jira_issue — propose a Jira issue on a connected site.
            """
            coexistence = """

            Changes to THIS task and its vertical line still go through `watchtower-action` blocks \
            (TASK ACTIONS above); a Jira issue goes through the create_jira_issue tool. Never create \
            other Watchtower tasks from here — report the finding in prose instead.
            """
        }
        return """
        === AGENT ACTIONS ===
        You have write TOOLS. A write tool never changes anything by itself: calling it records a \
        PROPOSAL and returns a receipt with an action id. The owner sees a card in this chat and \
        approves or rejects it; only then does the app execute it.
        Write tools on this surface:
        \(tools)
        Rules:
        - After calling a write tool, tell the owner what you proposed and that it awaits their approval. \
        Never claim it is done, created, or sent.
        - One proposal per item; never propose the same item twice in one turn.
        - For Jira, call list_jira_projects FIRST to pick a synced project and a known issue type. When the \
        project or type is ambiguous, ask the owner instead of guessing.
        - get_action <id> answers what happened to a proposal; an ACTIONS SINCE YOUR LAST MESSAGE block \
        at the top of the owner's message reports outcomes since your last turn.
        \(coexistence)
        """
    }

    /// The honest variant for a provider without tools (Ollama): the TOOLS
    /// section is replaced, nothing promises what the session cannot do.
    package static let noToolsBlock = """
        === TOOLS ===
        No tools are connected in this session. Answer from the conversation only, and say so plainly \
        when the owner asks you to look something up or to create something.
        """

    /// Outcomes to prepend to the owner's next message, nil when there are
    /// none — the target chat's context re-injection precedent. Not persisted.
    package static func actionsSinceLastTurnBlock(_ rows: [AgentAction]) -> String? {
        guard !rows.isEmpty else { return nil }
        let lines = rows.map { row -> String in
            var line = "- #\(row.id) \(row.tool): \(row.status)"
            if row.status == "applied", !row.resultJSON.isEmpty {
                line += " — \(row.resultJSON)"
            } else if !row.error.isEmpty {
                line += " — \(row.error)"
            }
            return line
        }
        return "=== ACTIONS SINCE YOUR LAST MESSAGE ===\n" + lines.joined(separator: "\n")
    }
}
```

- [ ] **Step 4: Run tests**

Run: `cd WatchtowerDesktop && swift test --filter AgentToolsContractTests` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/WatchtowerCore/Services/Actions/AgentToolsContract.swift WatchtowerDesktop/Tests/Core/AgentToolsContractTests.swift
git commit -m "feat(desktop): AGENT ACTIONS prompt contract and the honest no-tools block"
```

---

### Task 15: `AgentActionFeed`

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Actions/AgentActionFeed.swift`, `WatchtowerDesktop/Tests/Core/AgentActionFeedTests.swift`

**Interfaces:**
- Consumes: `AgentActionQueries`, `CLIRunnerProtocol`, `AgentToolsContract.actionsSinceLastTurnBlock`.
- Produces:
  ```swift
  @MainActor @Observable package final class AgentActionFeed {
      package private(set) var rows: [AgentAction]
      package private(set) var inFlight: Set<Int64>
      package var lastError: String?
      package init(dbPool: DatabasePool, cliRunner: CLIRunnerProtocol? = nil)
      package func start(conversationID: Int64)   // replaces any previous observation
      package func stop()
      package func cards(forTurn turnID: String) -> [AgentAction]
      package var pendingCount: Int
      package func approve(_ id: Int64) async
      package func reject(_ id: Int64) async
      package func retry(_ id: Int64) async
      package func approveAllPending(forTurn turnID: String) async
      package func outcomesBlock(after: Date?) -> String?
      package static func timestampString(_ date: Date) -> String   // "yyyy-MM-dd'T'HH:mm:ss'Z'" UTC
  }
  ```

- [ ] **Step 1: Write the failing tests**

`Tests/Core/AgentActionFeedTests.swift`:

```swift
import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class AgentActionFeedTests: XCTestCase {
    private func makePool() throws -> (DatabasePool, String) { try TestDatabase.createPool() }

    /// Wait for the observation to deliver `count` rows (ValueObservation is
    /// asynchronous; poll on the main actor with a bounded budget).
    private func waitForRows(_ feed: AgentActionFeed, count: Int) async {
        for _ in 0..<50 where feed.rows.count != count {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testStartObservesConversationRows() async throws {
        let (pool, path) = try makePool()
        defer { TestDatabase.cleanup(path: path) }
        try await pool.write { db in
            try TestDatabase.insertAgentAction(db, conversationID: 1, turnID: "a")
            try TestDatabase.insertAgentAction(db, conversationID: 2, turnID: "b")
        }
        let feed = AgentActionFeed(dbPool: pool, cliRunner: FakeCLIRunner())
        feed.start(conversationID: 1)
        await waitForRows(feed, count: 1)
        XCTAssertEqual(feed.rows.map(\.turnID), ["a"])
        XCTAssertEqual(feed.cards(forTurn: "a").count, 1)
        XCTAssertTrue(feed.cards(forTurn: "zzz").isEmpty)
        XCTAssertEqual(feed.pendingCount, 1)

        try await pool.write { db in try TestDatabase.insertAgentAction(db, conversationID: 1, turnID: "a2") }
        await waitForRows(feed, count: 2)
        XCTAssertEqual(feed.rows.count, 2)
        feed.stop()
    }

    func testApproveRunsCLIWithJSONAndTracksInFlight() async throws {
        let (pool, path) = try makePool()
        defer { TestDatabase.cleanup(path: path) }
        try await pool.write { db in try TestDatabase.insertAgentAction(db) }
        let runner = FakeCLIRunner(stdout: Data(#"{"ok":true,"applied_ok":true,"error":"","action":{"id":1,"status":"applied"}}"#.utf8))
        let feed = AgentActionFeed(dbPool: pool, cliRunner: runner)
        feed.start(conversationID: 1)
        await waitForRows(feed, count: 1)

        await feed.approve(1)
        XCTAssertEqual(runner.invocations, [["actions", "approve", "1", "--json"]])
        XCTAssertTrue(feed.inFlight.isEmpty)
        XCTAssertNil(feed.lastError)

        await feed.reject(1)
        await feed.retry(1)
        XCTAssertEqual(runner.invocations.count, 3)
        XCTAssertEqual(runner.invocations[1], ["actions", "reject", "1", "--json"])
        XCTAssertEqual(runner.invocations[2], ["actions", "apply", "1", "--json"])
    }

    func testApproveSurfacesExecutionErrorFromEnvelope() async throws {
        let (pool, path) = try makePool()
        defer { TestDatabase.cleanup(path: path) }
        try await pool.write { db in try TestDatabase.insertAgentAction(db) }
        let runner = FakeCLIRunner(stdout: Data(#"{"ok":true,"applied_ok":false,"error":"issuetype: invalid","action":{"id":1,"status":"failed"}}"#.utf8))
        let feed = AgentActionFeed(dbPool: pool, cliRunner: runner)
        await feed.approve(1)
        XCTAssertEqual(feed.lastError, "issuetype: invalid")
    }

    func testApproveSurfacesProcessFailure() async throws {
        let (pool, path) = try makePool()
        defer { TestDatabase.cleanup(path: path) }
        struct Boom: Error {}
        let feed = AgentActionFeed(dbPool: pool, cliRunner: FakeCLIRunner(error: Boom()))
        await feed.approve(1)
        XCTAssertNotNil(feed.lastError)
        XCTAssertTrue(feed.inFlight.isEmpty)
    }

    func testApproveAllPendingForTurn() async throws {
        let (pool, path) = try makePool()
        defer { TestDatabase.cleanup(path: path) }
        try await pool.write { db in
            try TestDatabase.insertAgentAction(db, turnID: "t")
            try TestDatabase.insertAgentAction(db, turnID: "t", status: "applied")
            try TestDatabase.insertAgentAction(db, turnID: "t")
            try TestDatabase.insertAgentAction(db, turnID: "other")
        }
        let runner = FakeCLIRunner(stdout: Data(#"{"ok":true,"applied_ok":true,"error":"","action":{"id":1,"status":"applied"}}"#.utf8))
        let feed = AgentActionFeed(dbPool: pool, cliRunner: runner)
        feed.start(conversationID: 1)
        await waitForRows(feed, count: 4)
        await feed.approveAllPending(forTurn: "t")
        XCTAssertEqual(runner.invocations.map { $0[2] }.sorted(), ["1", "3"])
    }

    func testOutcomesBlockUsesTimestampFloor() async throws {
        let (pool, path) = try makePool()
        defer { TestDatabase.cleanup(path: path) }
        try await pool.write { db in
            try TestDatabase.insertAgentAction(db, status: "applied", resultJSON: #"{"target_id":9}"#, appliedAt: "2026-09-04T10:05:00Z")
            try TestDatabase.insertAgentAction(db, status: "rejected", decidedAt: "2026-09-04T09:00:00Z")
        }
        let feed = AgentActionFeed(dbPool: pool, cliRunner: FakeCLIRunner())
        feed.start(conversationID: 1)
        let after = ISO8601DateFormatter().date(from: "2026-09-04T10:00:00Z")
        let block = try XCTUnwrap(feed.outcomesBlock(after: after))
        XCTAssertTrue(block.contains("#1 create_target: applied"))
        XCTAssertFalse(block.contains("#2"))
        XCTAssertNil(feed.outcomesBlock(after: nil), "no previous owner message → nothing to report")
        XCTAssertEqual(AgentActionFeed.timestampString(after!), "2026-09-04T10:00:00Z")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd WatchtowerDesktop && swift test --filter AgentActionFeedTests`
Expected: compile error.

- [ ] **Step 3: Implement**

`Sources/WatchtowerCore/Services/Actions/AgentActionFeed.swift`:

```swift
import Foundation
import GRDB

/// The proposal feed one chat VM composes (the `SkillsCatalog` precedent —
/// one shared piece, composed per VM): observes agent_actions for the bound
/// conversation, and drives Approve/Reject/Retry through the CLI, which is
/// the only status writer (Go owns every transition).
@MainActor
@Observable
package final class AgentActionFeed {
    package private(set) var rows: [AgentAction] = []
    package private(set) var inFlight: Set<Int64> = []
    package var lastError: String?

    private let dbPool: DatabasePool
    private let cliRunner: CLIRunnerProtocol?
    private var observationTask: Task<Void, Never>?
    private var conversationID: Int64?

    package init(dbPool: DatabasePool, cliRunner: CLIRunnerProtocol? = nil) {
        self.dbPool = dbPool
        self.cliRunner = cliRunner
    }

    package func start(conversationID: Int64) {
        stop()
        self.conversationID = conversationID
        let pool = dbPool
        observationTask = Task { [weak self] in
            let observation = ValueObservation.tracking { db in
                try AgentActionQueries.fetchByConversation(db, conversationID: conversationID)
            }
            do {
                for try await rows in observation.values(in: pool) {
                    guard !Task.isCancelled, let self else { break }
                    self.rows = rows
                }
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }

    package func stop() {
        observationTask?.cancel()
        observationTask = nil
        conversationID = nil
        rows = []
    }

    package func cards(forTurn turnID: String) -> [AgentAction] {
        rows.filter { $0.turnID == turnID }
    }

    package var pendingCount: Int { rows.filter(\.isPending).count }

    package func approve(_ id: Int64) async { await run("approve", id: id) }
    package func reject(_ id: Int64) async { await run("reject", id: id) }
    package func retry(_ id: Int64) async { await run("apply", id: id) }

    package func approveAllPending(forTurn turnID: String) async {
        for row in cards(forTurn: turnID) where row.isPending {
            await approve(row.id)
        }
    }

    /// Outcomes decided or executed after `after`, rendered for the model.
    /// nil when there is no floor (first turn) or nothing changed.
    package func outcomesBlock(after: Date?) -> String? {
        guard let after, let conversationID else { return nil }
        let floor = Self.timestampString(after)
        let decided = (try? dbPool.read { db in
            try AgentActionQueries.fetchDecidedAfter(db, conversationID: conversationID, after: floor)
        }) ?? []
        return AgentToolsContract.actionsSinceLastTurnBlock(decided)
    }

    package static func timestampString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return fmt.string(from: date)
    }

    private struct Envelope: Decodable {
        let ok: Bool
        let appliedOK: Bool?
        let error: String?
        enum CodingKeys: String, CodingKey {
            case ok
            case appliedOK = "applied_ok"
            case error
        }
    }

    private func run(_ verb: String, id: Int64) async {
        guard let runner = cliRunner ?? ProcessCLIRunner.makeDefault() else {
            lastError = CLIRunnerError.binaryNotFound.localizedDescription
            return
        }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        lastError = nil
        do {
            let data = try await runner.run(args: ["actions", verb, String(id), "--json"])
            if let env = try? JSONDecoder().decode(Envelope.self, from: data),
               let err = env.error, !err.isEmpty {
                lastError = err
            }
        } catch {
            lastError = error.localizedDescription
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `cd WatchtowerDesktop && swift test --filter AgentActionFeedTests` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/WatchtowerCore/Services/Actions/AgentActionFeed.swift WatchtowerDesktop/Tests/Core/AgentActionFeedTests.swift
git commit -m "feat(desktop): AgentActionFeed observes proposals and drives approve/reject/retry via the CLI"
```

---

### Task 16: Main AI Chat becomes an action surface

**Files:**
- Modify: `WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift` (`init`, `bind(to:)`, `newChat()`, `send()`, `persistResponseStatic`, `buildSystemPrompt`, `formatSystemPrompt`, `promptHeader`, `promptDeepLinksAndRestrictions`)
- Test: `WatchtowerDesktop/Tests/ViewModelTests.swift` (the `ChatViewModelTests` class)

**Interfaces:**
- Consumes: `AgentActionFeed`, `ChatToolMode`, `AgentToolsContract`, `ChatMessageQueries.insert(…turnID:)`.
- Produces: `ChatViewModel.actionFeed: AgentActionFeed`; `ChatViewModel.init(aiService:dbManager:provider:cliRunner:)` (`cliRunner` defaults to nil); `static func buildSystemPrompt(dbPool:toolsAvailable:)` (`toolsAvailable` defaults to `true`); `static func formatSystemPrompt(workspace:schema:toolsAvailable:)`; `var toolsAvailable: Bool { selectedProvider != .ollama }`.

- [ ] **Step 1: Write the failing tests**

Add to the `ChatViewModelTests` class in `Tests/ViewModelTests.swift` (it already has `dbManager` + `MockClaudeService`):

```swift
    private func makeConversation() throws -> ChatConversation {
        try dbManager.dbPool.write { db in
            try ChatConversationQueries.ensureTable(db)
            try ChatMessageQueries.ensureTable(db)
            try ChatMessageQueries.ensureTurnIDColumn(db)
            return try ChatConversationQueries.create(db, title: "t")
        }
    }

    @MainActor
    func testSendPassesMainChatToolModeWithFreshTurnID() async throws {
        let mock = MockClaudeService(events: [.text("ok"), .done])
        let vm = ChatViewModel(aiService: mock, dbManager: dbManager)
        vm.bind(to: try makeConversation())
        vm.inputText = "hello"
        vm.send()
        for _ in 0..<50 where vm.isStreaming { try await Task.sleep(for: .milliseconds(20)) }

        let mode = try XCTUnwrap(mock.toolModes.first ?? nil)
        XCTAssertEqual(mode.surface, "main")
        XCTAssertEqual(mode.conversationID, vm.conversationID)
        XCTAssertFalse(mode.turnID.isEmpty)
        XCTAssertNil(mode.contextType)
        // The persisted assistant row carries the same turn id.
        let records = try dbManager.dbPool.read { db in
            try ChatMessageQueries.fetchByConversation(db, conversationID: vm.conversationID!)
        }
        XCTAssertEqual(records.last?.role, "assistant")
        XCTAssertEqual(records.last?.turnID, mode.turnID)
        XCTAssertEqual(vm.messages.last?.turnID, mode.turnID)
    }

    @MainActor
    func testOllamaSendsNoToolModeAndHonestPrompt() async throws {
        let mock = MockClaudeService(events: [.text("ok"), .done])
        let vm = ChatViewModel(aiService: mock, dbManager: dbManager, provider: .ollama)
        vm.bind(to: try makeConversation())
        vm.inputText = "hello"
        vm.send()
        for _ in 0..<50 where vm.isStreaming { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(mock.toolModes, [nil])
        let prompt = try XCTUnwrap(mock.systemPrompts.first ?? nil)
        XCTAssertTrue(prompt.contains("No tools are connected"))
        XCTAssertFalse(prompt.contains("=== AGENT ACTIONS ==="))
    }

    func testBuildSystemPromptCarriesAgentActionsContract() throws {
        try dbManager.dbPool.write { db in try TestDatabase.insertWorkspace(db) }
        let prompt = ChatViewModel.buildSystemPrompt(dbPool: dbManager.dbPool)
        XCTAssertTrue(prompt.contains("=== AGENT ACTIONS ==="))
        XCTAssertTrue(prompt.contains("create_target"))
        XCTAssertTrue(prompt.contains("every write is a proposal"))
        XCTAssertFalse(prompt.contains("never write"), "the old blanket restriction is reworded")
        XCTAssertTrue(prompt.contains("There is no SQL tool and no shell"))
    }

    @MainActor
    func testResumedTurnPrependsOutcomesSinceLastMessage() async throws {
        let mock = MockClaudeService(eventSequence: [[.sessionID("s1"), .text("a"), .done], [.text("b"), .done]])
        let vm = ChatViewModel(aiService: mock, dbManager: dbManager)
        let conv = try makeConversation()
        vm.bind(to: conv)
        vm.inputText = "first"
        vm.send()
        for _ in 0..<50 where vm.isStreaming { try await Task.sleep(for: .milliseconds(20)) }

        // A proposal from that turn got applied after the owner's first message.
        let applied = AgentActionFeed.timestampString(Date().addingTimeInterval(60))
        try dbManager.dbPool.write { db in
            try TestDatabase.insertAgentAction(db, conversationID: conv.id, status: "applied",
                resultJSON: #"{"target_id":5}"#, appliedAt: applied)
        }
        vm.inputText = "second"
        vm.send()
        for _ in 0..<50 where vm.isStreaming { try await Task.sleep(for: .milliseconds(20)) }

        let second = try XCTUnwrap(mock.prompts.last)
        XCTAssertTrue(second.hasPrefix("=== ACTIONS SINCE YOUR LAST MESSAGE ==="))
        XCTAssertTrue(second.contains("create_target: applied"))
        XCTAssertTrue(second.hasSuffix("second"))
        // The stored owner message is the bare text.
        let records = try dbManager.dbPool.read { db in
            try ChatMessageQueries.fetchByConversation(db, conversationID: conv.id)
        }
        XCTAssertEqual(records.filter { $0.role == "user" }.map(\.text), ["first", "second"])
    }
```

`TestDatabase.insertAgentAction` lives in `WatchtowerTestSupport`, which this test target already imports.

- [ ] **Step 2: Run to verify they fail**

Run: `cd WatchtowerDesktop && swift test --filter ChatViewModelTests`
Expected: compile errors (`actionFeed`, `toolModes`, `buildSystemPrompt(dbPool:toolsAvailable:)`).

- [ ] **Step 3: Implement**

In `ChatViewModel`:

```swift
    /// Proposal cards for the bound conversation — the main chat is an
    /// action surface (AGENT-04): write tools land here behind Approve.
    let actionFeed: AgentActionFeed

    /// Only CLI-backed providers reach the MCP server; Ollama has no tools,
    /// so the prompt says so and no tool mode is sent.
    var toolsAvailable: Bool { selectedProvider != .ollama }

    init(aiService: any AIServiceProtocol, dbManager: DatabaseManager, provider: AIProvider = .claude,
         cliRunner: CLIRunnerProtocol? = nil) {
        self.aiService = aiService
        self.dbManager = dbManager
        self.selectedProvider = provider
        self.actionFeed = AgentActionFeed(dbPool: dbManager.dbPool, cliRunner: cliRunner)
    }
```

`bind(to:)`: after `startMessageObservation()` add `actionFeed.start(conversationID: conversation.id)`. `newChat()`: add `actionFeed.stop()`.

`send()` — compute the floor BEFORE appending the new user message, mint the turn id, pass the tool mode, and inject outcomes on resumed turns:

```swift
        let previousOwnerMessageAt = messages.last(where: { $0.role == .user })?.timestamp
        let turnID = UUID().uuidString
        …
        messages.append(ChatMessage(id: UUID(), role: .assistant, text: "", timestamp: Date(), isStreaming: true, turnID: turnID))
        …
        let toolMode: ChatToolMode? = (toolsAvailable && conversationID != nil)
            ? ChatToolMode(surface: "main", conversationID: conversationID!, turnID: turnID)
            : nil
        let outcomes = currentSessionID == nil ? nil : actionFeed.outcomesBlock(after: previousOwnerMessageAt)
        let effectivePrompt = outcomes.map { "\($0)\n\n\(text)" } ?? text
        let capturedToolsAvailable = toolsAvailable
```

then inside the `streamTask`:

```swift
            let systemPrompt: String? = currentSessionID == nil
                ? Self.buildSystemPrompt(dbPool: dbPool, toolsAvailable: capturedToolsAvailable)
                : nil
            …
                let stream = capturedAIService.stream(
                    prompt: effectivePrompt, systemPrompt: systemPrompt, sessionID: currentSessionID,
                    dbPath: dbPath, model: model, provider: provider, toolMode: toolMode
                )
```

and the persist tail passes `turnID`:

```swift
                Self.persistResponseStatic(dbManager: capturedDBManager, conversationID: convID, text: fullText, turnID: turnID)
```

with `persistResponseStatic` gaining `turnID: String` and forwarding it to `ChatMessageQueries.insert(db, conversationID:, role: "assistant", text:, turnID:)`. `cancelStream()`'s partial persist also passes `messages[idx].turnID ?? ""` — add a `turnID:` parameter to `persistMessage` with default `""`.

Prompt builders:

```swift
    nonisolated static func buildSystemPrompt(dbPool: DatabasePool, toolsAvailable: Bool = true) -> String {
        do {
            return try dbPool.read { db in
                let ws = try WorkspaceQueries.fetchWorkspace(db)
                let schema = try Self.fetchSchema(db)
                return Self.formatSystemPrompt(workspace: ws, schema: schema, toolsAvailable: toolsAvailable)
            }
        } catch { … unchanged … }
    }

    nonisolated static func formatSystemPrompt(workspace ws: Workspace?, schema: String, toolsAvailable: Bool = true) -> String {
        …
        let toolsBlock = toolsAvailable
            ? AgentToolsContract.promptBlock(surface: .main) + "\n\n"
            : ""
        return promptHeader(name: name, domain: domain, now: now, schema: schema, toolsAvailable: toolsAvailable)
            + toolsBlock
            + promptDeepLinksAndRestrictions(teamID: teamID)
            + promptRules(teamID: teamID)
            + promptAppGuide()
    }
```

In `promptHeader`, wrap the `=== TOOLS … ===` list: when `toolsAvailable` is false, replace the whole TOOLS section (from `IMPORTANT: You MUST look things up` through `Never ask for a database path…`) with `AgentToolsContract.noToolsBlock`; keep "There is no SQL tool and no shell…" and the schema in both variants. In `promptDeepLinksAndRestrictions` reword the second restriction bullet to:

```
        - Your ONLY data source is the local database, reached through the tools above. \
        You cannot write directly — every write is a proposal through a write tool, executed only after the owner approves.
```

- [ ] **Step 4: Run tests**

Run: `cd WatchtowerDesktop && swift test --filter ChatViewModelTests`
Expected: PASS (including the pre-existing `testBuildSystemPrompt*`, `testCancelStream*`, provider-switch tests).

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift WatchtowerDesktop/Tests/ViewModelTests.swift
git commit -m "feat(desktop): main AI Chat sends the chat tool mode, carries turn ids and the actions contract"
```

---

### Task 17: Target chat composes the feed; AGENT-04 pins on the draft-only surfaces

**Files:**
- Modify: `WatchtowerDesktop/Sources/ViewModels/TargetChatViewModel.swift` (`init`, `stop()`, `send()`, `startStream`, `executeStream`, `buildSystemPrompt`, `persistResponse`)
- Test: `WatchtowerDesktop/Tests/TargetChatViewModelTests.swift`, plus one assertion each in the situation/meeting/idea/track VM suites

**Interfaces:**
- Produces: `TargetChatViewModel.actionFeed: AgentActionFeed`; `init(target:viewModel:dbManager:conversationID:aiService:cliRunner:)` (`cliRunner` defaults to nil); `static func buildSystemPrompt(target:dbPool:memoryChatEnabled:memoryVaultDir:skillsDir:toolsAvailable:)` (`toolsAvailable` defaults to `true`).

- [ ] **Step 1: Write the failing tests**

Append to `Tests/TargetChatViewModelTests.swift`:

```swift
    func testSystemPromptCarriesAgentActionsContractForTargetSurface() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try manager.dbPool.write { db in try TestDatabase.insertWorkspace(db) }
        let target = try makeTarget(manager, intent: "x")
        let prompt = TargetChatViewModel.buildSystemPrompt(target: target, dbPool: manager.dbPool)
        XCTAssertTrue(prompt.contains("=== AGENT ACTIONS ==="))
        XCTAssertTrue(prompt.contains("create_jira_issue"))
        XCTAssertFalse(prompt.contains("- create_target"), "TGT-BRIEF-01: no top-level task creation from a target chat")
        XCTAssertTrue(prompt.contains("=== TASK ACTIONS ==="), "the block grammar is unchanged")
        let ollama = TargetChatViewModel.buildSystemPrompt(target: target, dbPool: manager.dbPool, toolsAvailable: false)
        XCTAssertFalse(ollama.contains("=== AGENT ACTIONS ==="))
    }

    func testSendPassesTargetToolModeWithContext() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try ensureChatTables(manager)
        try manager.dbPool.write { db in try ChatMessageQueries.ensureTurnIDColumn(db) }
        let target = try makeTarget(manager, intent: "x")
        let vm = TargetsViewModel(dbManager: manager)
        let mock = MockClaudeService(events: [.text("ok"), .done])
        let chat = try makeChat(target: target, vm: vm, manager: manager, aiService: mock)
        chat.inputText = "make a ticket"
        chat.send()
        for _ in 0..<50 where chat.isStreaming { try await Task.sleep(for: .milliseconds(20)) }

        let mode = try XCTUnwrap(mock.toolModes.first ?? nil)
        XCTAssertEqual(mode.surface, "target")
        XCTAssertEqual(mode.contextType, "target")
        XCTAssertEqual(mode.contextID, String(target.id))
        XCTAssertEqual(chat.messages.last?.turnID, mode.turnID)
        let persisted = try fetchPersistedMessages(manager, targetID: target.id)
        XCTAssertEqual(persisted.last?.turnID, mode.turnID)
    }
```

And in each draft-only suite — find them with `ls WatchtowerDesktop/Tests | grep -E 'SituationChat|MeetingChat|IdeaChatViewModel|TrackChat'` — add to the existing test that already calls `send()` on a `MockClaudeService` the single assertion:

```swift
        // AGENT-04: draft-only surfaces never send a tool mode.
        XCTAssertEqual(mock.toolModes, [nil])
```

(if a suite names its mock differently, use that name; if a suite has no send test, add one that mirrors its neighbour's setup and asserts only this line).

- [ ] **Step 2: Run to verify they fail**

Run: `cd WatchtowerDesktop && swift test --filter TargetChatViewModelTests`
Expected: FAIL (contract missing; `toolModes.first` is nil).

- [ ] **Step 3: Implement**

`TargetChatViewModel`:

```swift
    /// Proposal cards for this tab — the target chat is an action surface
    /// alongside its block grammar (AGENT-04).
    let actionFeed: AgentActionFeed
    /// Provider kind is chosen app-wide for Discuss chats; the VM passes
    /// `model: nil` and the CLI resolves the provider — so the only case
    /// without tools is the app-wide Ollama provider.
    var toolsAvailable: Bool { Constants.aiProviderID() != "ollama" }

    init(target: Target, viewModel: TargetsViewModel, dbManager: DatabaseManager, conversationID: Int64,
         aiService: (any AIServiceProtocol)? = nil, cliRunner: CLIRunnerProtocol? = nil) {
        …
        self.actionFeed = AgentActionFeed(dbPool: dbManager.dbPool, cliRunner: cliRunner)
        loadConversation(id: conversationID)
        startMessageObservation()
        if let conversationID = self.conversationID { actionFeed.start(conversationID: conversationID) }
    }
```

`Constants.aiProviderID()` — add to `WatchtowerCore/Utilities/Constants.swift` next to `memorySurfacesChatEnabled()`: read `ai.provider` from the config yaml the same way that helper reads its key, defaulting to `"claude"`. `stop()`: add `actionFeed.stop()`.

`send()`: capture `let previousOwnerMessageAt = messages.last(where: { $0.role == .user })?.timestamp` before appending, mint `let turnID = UUID().uuidString`, append the assistant placeholder with `turnID: turnID`, and call `startStream(prompt: prependQueuedFollowUps(to: text), turnID: turnID, previousOwnerMessageAt: previousOwnerMessageAt)`. `sendFollowUp`/`flushQueuedFollowUps` call `startStream(prompt:, turnID: UUID().uuidString, previousOwnerMessageAt: nil)` and give their placeholder that turn id too. `startStream` forwards both to `executeStream`, which builds:

```swift
        let toolMode: ChatToolMode? = (toolsAvailable && conversationID != nil)
            ? ChatToolMode(surface: "target", conversationID: conversationID!, turnID: turnID,
                           contextType: "target", contextID: String(target.id))
            : nil
        let outcomes = currentSessionID == nil ? nil : actionFeed.outcomesBlock(after: previousOwnerMessageAt)
        let effectivePrompt: String = {
            let base = currentSessionID == nil
                ? text
                : "\(Self.taskContextBlock(target))\n\(Self.taskTreeBlock(target: target, dbPool: dbPool))\n\n"
                    + "\(Self.taskActionsContract)\n\n\(AgentToolsContract.promptBlock(surface: .target))\n\n\(text)"
            return outcomes.map { "\($0)\n\n\(base)" } ?? base
        }()
```

and passes `toolMode: toolMode` (plus `provider: nil`) to `aiService.stream(…)`, and `turnID` into `Self.persistResponse(dbManager:conversationID:text:turnID:)` → `ChatMessageQueries.insert(…, turnID:)`. `buildSystemPrompt` gains `toolsAvailable: Bool = true` and appends, right after `\(memoryBlock)\(Self.taskActionsContract)`:

```swift
        \(toolsAvailable ? AgentToolsContract.promptBlock(surface: .target) : "")
```

`resolved(_:overrideKind:)` and the existing card machinery are untouched.

- [ ] **Step 4: Run tests**

Run: `cd WatchtowerDesktop && swift test --filter 'TargetChatViewModelTests|SituationChat|MeetingChat|IdeaChat|TrackChat|TargetBriefCenterTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources WatchtowerDesktop/Tests
git commit -m "feat(desktop): target chat composes the proposal feed; AGENT-04 pins on draft-only surfaces"
```

---

### Task 18: Proposal cards in both message lists

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Chat/AgentActionCardView.swift`, `WatchtowerDesktop/Tests/AgentActionCardViewTests.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Chat/ChatView.swift:165-168`, `WatchtowerDesktop/Sources/Views/Targets/TargetChatView.swift:296-313`

**Interfaces:**
- Produces:
  ```swift
  struct AgentActionCardView: View {
      let action: AgentAction; let inFlight: Bool
      let onApprove: () -> Void; let onReject: () -> Void; let onRetry: () -> Void
      static func title(for action: AgentAction) -> String        // "Create task" / "Create Jira issue" / tool name
      static func summaryLines(for action: AgentAction) -> [String] // per-tool argument rendering
  }
  ```

- [ ] **Step 1: Write the failing view tests**

`Tests/AgentActionCardViewTests.swift`:

```swift
import XCTest
import GRDB
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class AgentActionCardViewTests: XCTestCase {
    private func row(_ configure: (Database) throws -> Void) throws -> AgentAction {
        let queue = try TestDatabase.create()
        try queue.write(configure)
        return try queue.read { db in try AgentActionQueries.fetchByConversation(db, conversationID: 1) }[0]
    }

    func testJiraSummaryLinesAndTitle() throws {
        let action = try row { db in
            try TestDatabase.insertAgentAction(db, tool: "create_jira_issue", external: true,
                argsJSON: #"{"project_key":"ABC","issue_type":"Task","summary":"Fix login","description":"body","labels":["a","b"],"reason":"r"}"#)
        }
        XCTAssertEqual(AgentActionCardView.title(for: action), "Create Jira issue")
        let lines = AgentActionCardView.summaryLines(for: action)
        XCTAssertEqual(lines, ["Project: ABC · Task", "Summary: Fix login", "Description: body", "Labels: a, b"])
    }

    func testTargetSummaryLines() throws {
        let action = try row { db in
            try TestDatabase.insertAgentAction(db, argsJSON: #"{"text":"Call Vasya","due":"2026-09-05T16:00","priority":"high","reason":"r"}"#)
        }
        XCTAssertEqual(AgentActionCardView.title(for: action), "Create task")
        XCTAssertEqual(AgentActionCardView.summaryLines(for: action), ["Call Vasya", "Due: 2026-09-05T16:00 · Priority: high"])
    }

    func testPendingCardShowsApproveAndReject() throws {
        let action = try row { db in try TestDatabase.insertAgentAction(db) }
        let view = AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
        XCTAssertNoThrow(try view.inspect().find(button: "Approve"))
        XCTAssertNoThrow(try view.inspect().find(button: "Reject"))
        XCTAssertThrowsError(try view.inspect().find(button: "Retry"))
    }

    func testFailedExternalCardShowsRetryWithDuplicateWarning() throws {
        let action = try row { db in
            try TestDatabase.insertAgentAction(db, tool: "create_jira_issue", external: true, status: "failed", error: "boom")
        }
        let view = AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
        XCTAssertNoThrow(try view.inspect().find(button: "Retry"))
        XCTAssertNoThrow(try view.inspect().find(text: "boom"))
        XCTAssertNoThrow(try view.inspect().find(textWhere: { text, _ in text.contains("check Jira") }))
    }

    func testAppliedJiraCardShowsLink() throws {
        let action = try row { db in
            try TestDatabase.insertAgentAction(db, tool: "create_jira_issue", status: "applied",
                resultJSON: #"{"key":"ABC-7","url":"https://acme.atlassian.net/browse/ABC-7"}"#)
        }
        let view = AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
        XCTAssertNoThrow(try view.inspect().find(text: "ABC-7"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd WatchtowerDesktop && swift test --filter AgentActionCardViewTests`
Expected: compile error.

- [ ] **Step 3: Implement the card**

`Sources/Views/Chat/AgentActionCardView.swift`:

```swift
import SwiftUI
import WatchtowerCore

/// One agent_actions proposal as a chat card. Generic over the tool — the
/// argument rendering is the only per-tool code; state comes from the row
/// (Go owns transitions), so the card never guesses what happened.
struct AgentActionCardView: View {
    let action: AgentAction
    let inFlight: Bool
    let onApprove: () -> Void
    let onReject: () -> Void
    let onRetry: () -> Void

    static func title(for action: AgentAction) -> String {
        switch action.tool {
        case "create_target": return "Create task"
        case "create_jira_issue": return "Create Jira issue"
        default: return action.tool
        }
    }

    static func summaryLines(for action: AgentAction) -> [String] {
        switch action.tool {
        case "create_target":
            var lines = [action.argString("text") ?? ""]
            var meta: [String] = []
            if let due = action.argString("due"), !due.isEmpty { meta.append("Due: \(due)") }
            if let p = action.argString("priority"), !p.isEmpty { meta.append("Priority: \(p)") }
            if !meta.isEmpty { lines.append(meta.joined(separator: " · ")) }
            if let intent = action.argString("intent"), !intent.isEmpty { lines.append("Why: \(intent)") }
            return lines
        case "create_jira_issue":
            var lines = ["Project: \(action.argString("project_key") ?? "?") · \(action.argString("issue_type") ?? "?")"]
            lines.append("Summary: \(action.argString("summary") ?? "")")
            if let d = action.argString("description"), !d.isEmpty { lines.append("Description: \(d)") }
            if let l = action.argString("labels"), !l.isEmpty { lines.append("Labels: \(l)") }
            if let p = action.argString("priority"), !p.isEmpty { lines.append("Priority: \(p)") }
            return lines
        default:
            return [action.argsJSON]
        }
    }

    private var statusLabel: String {
        switch action.status {
        case "pending": return "Awaiting your approval"
        case "approved": return "Approved — executing"
        case "applied": return "Done"
        case "rejected": return "Rejected"
        case "failed": return "Failed"
        default: return action.status
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: action.external ? "arrow.up.right.square" : "checklist")
                    .foregroundStyle(Color.accentColor)
                Text(Self.title(for: action)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(statusLabel).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("agentAction.status")
            }
            ForEach(Self.summaryLines(for: action), id: \.self) { line in
                Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if !action.reason.isEmpty {
                Text(action.reason).font(.caption).foregroundStyle(.secondary).italic()
            }
            if action.status == "applied", let url = action.resultString("url"), let key = action.resultString("key"),
               let link = URL(string: url) {
                Link(key, destination: link).font(.callout)
            } else if action.status == "applied", let id = action.resultString("target_id") {
                Text("Task #\(id) created").font(.callout)
            }
            if !action.error.isEmpty {
                Text(action.error).font(.caption).foregroundStyle(.red)
            }
            if action.canRetry, action.external {
                Text("Retrying re-sends the request — check Jira for a duplicate first.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                if action.isPending {
                    Button("Approve", action: onApprove).buttonStyle(.borderedProminent)
                    Button("Reject", action: onReject)
                } else if action.canRetry {
                    Button("Retry", action: onRetry)
                }
                if inFlight { ProgressView().controlSize(.small) }
            }
            .disabled(inFlight)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}
```

- [ ] **Step 4: Interleave in both lists**

`ChatView.swift` (`chatContent`, inside `ForEach(chatVM.messages)`):

```swift
                        ForEach(chatVM.messages) { msg in
                            MessageBubble(message: msg)
                                .id(msg.id)
                            if let turn = msg.turnID {
                                let cards = chatVM.actionFeed.cards(forTurn: turn)
                                if cards.filter(\.isPending).count >= 2 {
                                    Button("Approve all") { Task { await chatVM.actionFeed.approveAllPending(forTurn: turn) } }
                                        .font(.caption)
                                }
                                ForEach(cards) { action in
                                    AgentActionCardView(
                                        action: action,
                                        inFlight: chatVM.actionFeed.inFlight.contains(action.id),
                                        onApprove: { Task { await chatVM.actionFeed.approve(action.id) } },
                                        onReject: { Task { await chatVM.actionFeed.reject(action.id) } },
                                        onRetry: { Task { await chatVM.actionFeed.retry(action.id) } }
                                    )
                                }
                            }
                        }
                        if let err = chatVM.actionFeed.lastError {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
```

and add `.onChange(of: chatVM.actionFeed.rows.count) { if let last = chatVM.messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }` next to the existing `onChange`. `TargetChatView.swift` (`messageList`, after the existing `TargetActionCardView` loop for each `msg`): the same `if let turn = msg.turnID { … }` block using `chatVM.actionFeed`, and `.onChange(of: chatVM.actionFeed.rows.count) { scrollToBottom(proxy) }`.

- [ ] **Step 5: Build, run the view tests, then look at it**

Run: `cd WatchtowerDesktop && swift build && swift test --filter 'AgentActionCardViewTests|TargetChatViewTests'`
Expected: PASS. Then `make app` (or the documented dev launch in `docs/`), open the main chat with the claude provider, type `напомни мне завтра в 16:00 позвонить Васе`, and confirm: a "Create task" card appears under the reply, Approve creates the task (visible in the Tasks tab), the card flips to "Done", and the next message carries the outcome (check `~/Library/Logs` or the daemon log for the `ai query` args if in doubt).

- [ ] **Step 6: Commit**

```bash
git add WatchtowerDesktop/Sources/Views WatchtowerDesktop/Tests/AgentActionCardViewTests.swift
git commit -m "feat(desktop): proposal cards interleave with assistant turns in both chats"
```

---

### Task 19: Settings → Assistant tools

**Files:**
- Create: `WatchtowerDesktop/Sources/ViewModels/AssistantToolsViewModel.swift`, `WatchtowerDesktop/Sources/Views/Settings/AssistantToolsSettingsSection.swift`, `WatchtowerDesktop/Tests/AssistantToolsViewModelTests.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Settings/ProfileSettings.swift:45` (add the section after `SkillsSettingsSection()`)

**Interfaces:**
- Produces:
  ```swift
  struct AssistantToolRow: Identifiable, Equatable, Decodable { let name, description, access: String; let external: Bool; let surfaces: [String]; var trust: String }
  @MainActor @Observable final class AssistantToolsViewModel {
      private(set) var rows: [AssistantToolRow]; var error: String?; private(set) var isLoading: Bool
      init(cliRunner: CLIRunnerProtocol? = nil)
      func load() async
      func setTrust(_ name: String, execute: Bool) async
  }
  ```

- [ ] **Step 1: Write the failing tests**

`Tests/AssistantToolsViewModelTests.swift`:

```swift
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class AssistantToolsViewModelTests: XCTestCase {
    private let listing = Data("""
    [{"name":"create_target","description":"d1","access":"write","external":false,"surfaces":["main"],"trust":"ask"},
     {"name":"create_jira_issue","description":"d2","access":"write","external":true,"surfaces":["main","target"],"trust":"ask"}]
    """.utf8)

    func testLoadDecodesListing() async {
        let runner = FakeCLIRunner(stdout: listing)
        let vm = AssistantToolsViewModel(cliRunner: runner)
        await vm.load()
        XCTAssertEqual(runner.invocations, [["actions", "tools", "--json"]])
        XCTAssertEqual(vm.rows.map(\.name), ["create_target", "create_jira_issue"])
        XCTAssertTrue(vm.rows[1].external)
        XCTAssertNil(vm.error)
    }

    func testSetTrustRunsCLIThenReloads() async {
        let runner = FakeCLIRunner(stdout: listing)
        let vm = AssistantToolsViewModel(cliRunner: runner)
        await vm.setTrust("create_target", execute: true)
        XCTAssertEqual(runner.invocations.first, ["actions", "trust", "create_target", "execute"])
        XCTAssertEqual(runner.invocations.last, ["actions", "tools", "--json"])
    }

    func testSetTrustSurfacesCLIError() async {
        struct Boom: Error {}
        let vm = AssistantToolsViewModel(cliRunner: FakeCLIRunner(error: Boom()))
        await vm.setTrust("create_jira_issue", execute: true)
        XCTAssertNotNil(vm.error)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd WatchtowerDesktop && swift test --filter AssistantToolsViewModelTests` — Expected: compile error.

- [ ] **Step 3: Implement**

`Sources/ViewModels/AssistantToolsViewModel.swift`:

```swift
import Foundation
import WatchtowerCore

/// One registry tool as `watchtower actions tools --json` lists it.
struct AssistantToolRow: Identifiable, Equatable, Decodable, Sendable {
    var id: String { name }
    let name: String
    let description: String
    let access: String
    let external: Bool
    let surfaces: [String]
    var trust: String
}

/// Settings → Assistant tools backing store. The registry lives in Go; this
/// VM only lists it and flips trust through the CLI, then re-reads.
@MainActor
@Observable
final class AssistantToolsViewModel {
    private(set) var rows: [AssistantToolRow] = []
    private(set) var isLoading = false
    var error: String?
    private let cliRunner: CLIRunnerProtocol?

    init(cliRunner: CLIRunnerProtocol? = nil) {
        self.cliRunner = cliRunner
    }

    private func runner() throws -> CLIRunnerProtocol {
        if let cliRunner { return cliRunner }
        if let r = ProcessCLIRunner.makeDefault() { return r }
        throw CLIRunnerError.binaryNotFound
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await runner().run(args: ["actions", "tools", "--json"])
            rows = try JSONDecoder().decode([AssistantToolRow].self, from: data)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func setTrust(_ name: String, execute: Bool) async {
        do {
            _ = try await runner().run(args: ["actions", "trust", name, execute ? "execute" : "ask"])
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        await load()
    }
}
```

`Sources/Views/Settings/AssistantToolsSettingsSection.swift`:

```swift
import SwiftUI
import WatchtowerCore

/// Settings → Assistant tools card: the registry's write tools and their
/// trust. External tools (Jira) are locked to "ask" — AGENT-03.
struct AssistantToolsSettingsSection: View {
    @State private var viewModel = AssistantToolsViewModel()

    var body: some View {
        Section {
            if viewModel.rows.isEmpty && !viewModel.isLoading {
                Text("No tools listed. Is the watchtower CLI available?").foregroundStyle(.secondary)
            }
            ForEach(viewModel.rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(row.name).font(.body.monospaced())
                        if row.external {
                            Text("external").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.orange.opacity(0.2), in: Capsule())
                        }
                        Spacer()
                        Toggle("Execute without approval", isOn: Binding(
                            get: { row.trust == "execute" },
                            set: { on in Task { await viewModel.setTrust(row.name, execute: on) } }
                        ))
                        .labelsHidden()
                        .disabled(row.external)
                        .help(row.external
                              ? "External tools always need your approval."
                              : "When on, the assistant's proposals with this tool run immediately and show as done.")
                    }
                    Text(row.description).font(.caption).foregroundStyle(.secondary)
                    Text("Surfaces: \(row.surfaces.joined(separator: ", "))").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
            }
            if let error = viewModel.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Assistant tools")
        } footer: {
            Text("Write tools create proposals you approve in the chat. \"Execute without approval\" skips the card "
                 + "for that tool; it can never be enabled for tools that write outside this Mac.")
        }
        .task { await viewModel.load() }
    }
}
```

Insert `AssistantToolsSettingsSection()` after `SkillsSettingsSection()` in `ProfileSettings.swift`.

- [ ] **Step 4: Run tests and build**

Run: `cd WatchtowerDesktop && swift build && swift test --filter AssistantToolsViewModelTests` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/ViewModels/AssistantToolsViewModel.swift WatchtowerDesktop/Sources/Views/Settings/AssistantToolsSettingsSection.swift WatchtowerDesktop/Sources/Views/Settings/ProfileSettings.swift WatchtowerDesktop/Tests/AssistantToolsViewModelTests.swift
git commit -m "feat(desktop): Settings → Assistant tools with per-tool trust (external locked)"
```

---

### Task 20: Gate, review, PR

**Files:** none new; `docs/app-guide.md` gets a short "Proposed actions" paragraph in its AI Chat section.

- [ ] **Step 1: Full gate**

Run, in order, and fix anything red:

```bash
make lint-all
make test
make test-swift
```

Expected: all green. `bash scripts/dev-health.sh` first if the machine is loaded.

- [ ] **Step 2: App-guide note**

In `docs/app-guide.md` under `### AI Chat`, add one paragraph: write tools (`create_target`, `create_jira_issue`) create proposal cards you approve in the chat; Settings → Assistant tools controls per-tool trust; external tools always ask. Commit: `docs(app-guide): proposed actions in the AI chat`.

- [ ] **Step 3: Local review loop**

Invoke the `local-review` skill on the branch (it runs the CI mirror and the review panel; triage every finding; loop until convergence).

- [ ] **Step 4: Open the PR and shepherd CI to green**

```bash
git push -u origin feature/agent-actions
gh pr create --title "feat: agent actions — tool registry, controlled writes, create_target/create_jira_issue" --body-file - <<'EOF'
## Summary
- Go tool registry (`internal/tools`): write tools record proposals (`agent_actions`), per-tool trust, apply-once execution; MCP is an adapter (`watchtower mcp --chat`), the dev surface stays read-only.
- First write tools: `create_target` (main chat) and `create_jira_issue` (main + target chat), behind Approve; `watchtower actions …` and `watchtower jira create`.
- Desktop: turn ids on assistant messages, proposal cards in both chats, honest no-tools prompt for Ollama, Settings → Assistant tools.
- Contracts AGENT-01..05 (`docs/inventory/agent-actions.md`); TGT-BRIEF-01..03 and DEV-01 unchanged.

Spec: `docs/superpowers/specs/2026-09-04-agent-actions-design.md`. Plan: `docs/superpowers/plans/2026-09-04-agent-actions.md`.

## Test plan
- [ ] `make lint-all && make test && make test-swift` green locally
- [ ] Main chat: "напомни завтра в 16:00 позвонить Васе" → Create task card → Approve → task in Tasks, card Done
- [ ] Main chat with a connected Jira: "заведи тикет про X в ABC" → Create Jira issue card → Approve → link to the issue
- [ ] Target chat: Jira card offered, no create_target
- [ ] Ollama provider: no cards, prompt says no tools

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_015ggx8kzgd1Jrnsc3Vx46pi
EOF
```

Then watch checks with `gh pr checks --watch` (a Sonnet babysitter agent, per the project's agent-model rule), fix failures on the branch, push, repeat until green. Report the PR URL and the final check status.
