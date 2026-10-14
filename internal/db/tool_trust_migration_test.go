package db

import (
	"database/sql"
	"testing"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	_ "modernc.org/sqlite"
)

// TestMigration00112_ToolTrustPerSurface replays goose up to 00111 (where the
// 00065 seeds already sit in the per-tool table), adds owner-set rows, applies
// 00112 and asserts the mapping: every row — a seed at its seeded value, a
// seed the owner changed, an owner's own row — covers every surface the tool
// is on today, so nothing observable changes on upgrade (owner decision
// 2026-10-14, ask #118); a row no trust read can honour is dropped. Down folds
// back to one row per tool, ask winning where the surfaces differ.
func TestMigration00112_ToolTrustPerSurface(t *testing.T) {
	t.Parallel()
	raw, err := sql.Open("sqlite", ":memory:")
	require.NoError(t, err)
	defer raw.Close()
	raw.SetMaxOpenConns(1)
	require.NoError(t, goose.UpTo(raw, "migrations", 111))

	_, err = raw.Exec(`INSERT OR REPLACE INTO tool_trust (tool, trust) VALUES
		('create_target', 'execute'),
		('create_idea', 'ask'),
		('create_jira_issue', 'execute'),
		('gone_tool', 'execute')`)
	require.NoError(t, err)

	require.NoError(t, goose.UpByOne(raw, "migrations"))

	rows, err := raw.Query(`SELECT tool, surface, trust FROM tool_trust ORDER BY tool, surface`)
	require.NoError(t, err)
	defer rows.Close()
	got := map[string]string{}
	for rows.Next() {
		var tool, surface, trust string
		require.NoError(t, rows.Scan(&tool, &surface, &trust))
		got[tool+"@"+surface] = trust
	}
	require.NoError(t, rows.Err())
	assert.Equal(t, map[string]string{
		// 00065 seeds at their seeded value: every surface the tool is on.
		"remind_me@main":         "execute",
		"remind_me@reaction":     "execute",
		"brief_context@reaction": "execute",
		"create_track@main":      "ask",
		"create_track@reaction":  "ask",
		// A seed the owner changed to ask: ask everywhere.
		"create_idea@main":     "ask",
		"create_idea@reaction": "ask",
		// The owner's own row.
		"create_target@main":     "execute",
		"create_target@reaction": "execute",
	}, got, "the External tool's and the unknown tool's rows never took effect and are dropped")

	// A tool whose surfaces now differ folds to ask on the way down (MIN).
	_, err = raw.Exec(`UPDATE tool_trust SET trust = 'ask' WHERE tool = 'remind_me' AND surface = 'main'`)
	require.NoError(t, err)
	require.NoError(t, goose.Down(raw, "migrations"))
	down := map[string]string{}
	rows, err = raw.Query(`SELECT tool, trust FROM tool_trust`)
	require.NoError(t, err)
	defer rows.Close()
	for rows.Next() {
		var tool, trust string
		require.NoError(t, rows.Scan(&tool, &trust))
		down[tool] = trust
	}
	require.NoError(t, rows.Err())
	assert.Equal(t, map[string]string{
		"remind_me":     "ask", // execute on reaction, ask on main: ask wins
		"brief_context": "execute",
		"create_track":  "ask",
		"create_idea":   "ask",
		"create_target": "execute",
	}, down)
}
