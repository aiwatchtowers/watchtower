package cmd

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/chat"
	"watchtower/internal/db"
	"watchtower/internal/policy/policytest"
)

type persistedRow struct {
	ID                 int64
	Role, Text, Status string
	TurnID             string
	ParentID           sql.NullInt64
	ErrorCode          sql.NullString
}

func persistedRows(t *testing.T, d *db.DB, conv int64) []persistedRow {
	t.Helper()
	rows, err := d.Query(`SELECT id, role, text, status, turn_id, parent_id, error_code FROM chat_messages WHERE conversation_id = ? ORDER BY id`, conv)
	require.NoError(t, err)
	defer rows.Close()
	var out []persistedRow
	for rows.Next() {
		var m persistedRow
		require.NoError(t, rows.Scan(&m.ID, &m.Role, &m.Text, &m.Status, &m.TurnID, &m.ParentID, &m.ErrorCode))
		out = append(out, m)
	}
	require.NoError(t, rows.Err())
	return out
}

// TestQueryPersist_EmbeddedChatTurnWritesItsRows: `ai query --events v2
// --persist` (an embedded chat's turn) writes what EmbeddedChatStore
// writes: the owner row and the reply's partial placeholder before the
// provider runs, the steps, and the end — text, status, tokens, model.
func TestQueryPersist_EmbeddedChatTurnWritesItsRows(t *testing.T) {
	policytest.Set(t, nil)
	t.Setenv("HOME", t.TempDir())
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "wt.db")
	d, err := db.Open(dbPath)
	require.NoError(t, err)
	t.Cleanup(func() { d.Close() })
	res, err := d.Exec(`INSERT INTO chat_conversations (title, context_type, context_id, created_at, updated_at)
		VALUES ('Track', 'track', '7', 1, 1)`)
	require.NoError(t, err)
	conv, err := res.LastInsertId()
	require.NoError(t, err)
	cfg := filepath.Join(dir, "config.yaml")
	require.NoError(t, os.WriteFile(cfg, fmt.Appendf(nil, `active_workspace: test-ws
workspaces:
  test-ws:
    slack_token: "xoxp-test-token"
claude_path: %q
ai:
  provider: claude
`, v2ClaudeStub(t)), 0o600))
	p := startCLI(t, "ai", "query", "--config", cfg, "--db-path", dbPath, "--events", "v2", "--prompt-stdin",
		"--persist", "--conversation", fmt.Sprint(conv), "--turn", "q1")
	query, err := json.Marshal(map[string]any{"prompt": "context + What next?", "owner_text": "What next?"})
	require.NoError(t, err)
	_, err = p.stdin.Write(query)
	require.NoError(t, err)
	require.NoError(t, p.stdin.Close())
	var types []string
	var started chat.Event
	for line := range p.lines {
		var e chat.Event
		require.NoError(t, json.Unmarshal([]byte(line), &e), line)
		types = append(types, e.Type)
		if e.Type == chat.EventStarted {
			started = e
		}
	}
	require.NoError(t, p.wait(), p.stderr.String())
	require.NotEmpty(t, types)
	assert.Equal(t, chat.EventStarted, types[0], "the rows are on disk before anything streams: %v", types)
	assert.Equal(t, conv, started.ConversationID)

	rows := persistedRows(t, d, conv)
	require.Len(t, rows, 2)
	assert.Equal(t, started.OwnerMessageID, rows[0].ID)
	assert.Equal(t, []string{"user", "What next?", "q1"}, []string{rows[0].Role, rows[0].Text, rows[0].TurnID})
	assert.False(t, rows[0].ParentID.Valid, "an embedded chat is linear")
	assert.Equal(t, started.AssistantMessageID, rows[1].ID)
	assert.Equal(t, []string{"assistant", "Let me check.\n\nFound it.", "complete", "q1"},
		[]string{rows[1].Role, rows[1].Text, rows[1].Status, rows[1].TurnID})
	var in, out sql.NullInt64
	var model, provider sql.NullString
	require.NoError(t, d.QueryRow(`SELECT tokens_in, tokens_out, model, provider FROM chat_messages WHERE id = ?`, rows[1].ID).
		Scan(&in, &out, &model, &provider))
	assert.Equal(t, int64(50), in.Int64)
	assert.Equal(t, int64(7), out.Int64)
	assert.Equal(t, "claude-x", model.String)
	assert.Equal(t, "claude", provider.String)
	var steps int
	var name string
	var ended sql.NullFloat64
	require.NoError(t, d.QueryRow(`SELECT COUNT(*), MAX(name), MAX(ended_at) FROM chat_turn_steps WHERE message_id = ?`, rows[1].ID).
		Scan(&steps, &name, &ended))
	assert.Equal(t, 1, steps)
	assert.Equal(t, "list_targets", name)
	assert.True(t, ended.Valid)
	var updated float64
	require.NoError(t, d.QueryRow(`SELECT updated_at FROM chat_conversations WHERE id = ?`, conv).Scan(&updated))
	assert.Greater(t, updated, 1.0, "a complete reply touches the conversation")
}

// TestQueryPersist_MainChatIsRefusedAndWritesNothing: `ai query --persist`
// against a main chat (context_type NULL) fails its start with an error
// line and writes no row — the main chat's rows are the chat engine's.
func TestQueryPersist_MainChatIsRefusedAndWritesNothing(t *testing.T) {
	policytest.Set(t, nil)
	t.Setenv("HOME", t.TempDir())
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "wt.db")
	d, err := db.Open(dbPath)
	require.NoError(t, err)
	t.Cleanup(func() { d.Close() })
	res, err := d.Exec(`INSERT INTO chat_conversations (title, created_at, updated_at) VALUES ('Main', 1, 1)`)
	require.NoError(t, err)
	conv, err := res.LastInsertId()
	require.NoError(t, err)
	cfg := filepath.Join(dir, "config.yaml")
	require.NoError(t, os.WriteFile(cfg, fmt.Appendf(nil, `active_workspace: test-ws
workspaces:
  test-ws:
    slack_token: "xoxp-test-token"
claude_path: %q
ai:
  provider: claude
`, v2ClaudeStub(t)), 0o600))
	p := startCLI(t, "ai", "query", "--config", cfg, "--db-path", dbPath, "--events", "v2", "--prompt-stdin",
		"--persist", "--conversation", fmt.Sprint(conv), "--turn", "q1")
	query, err := json.Marshal(map[string]any{"prompt": "hi", "owner_text": "hi"})
	require.NoError(t, err)
	_, err = p.stdin.Write(query)
	require.NoError(t, err)
	require.NoError(t, p.stdin.Close())
	var types []string
	for line := range p.lines {
		var e map[string]any
		require.NoError(t, json.Unmarshal([]byte(line), &e), line)
		if typ, ok := e["type"].(string); ok {
			types = append(types, typ)
		}
	}
	_ = p.wait()
	assert.NotContains(t, types, chat.EventStarted, "a refused start answers no started")
	assert.Contains(t, types, "error", "the refusal is an error line: %v", types)
	assert.Empty(t, persistedRows(t, d, conv), "no row is written into a main chat")
}
