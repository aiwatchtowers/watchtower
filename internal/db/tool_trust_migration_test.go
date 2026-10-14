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
// 00112 and asserts the mapping: a seed still at its seeded value lands on the
// reaction surface only, so the main chat now asks for create_idea/remind_me;
// an owner's row (or a seed the owner changed) covers every surface the tool
// is on; a row no trust read can honour is dropped. Down folds back to one
// row per tool, ask winning.
func TestMigration00112_ToolTrustPerSurface(t *testing.T) {
	t.Parallel()
	raw, err := sql.Open("sqlite", ":memory:")
	require.NoError(t, err)
	defer raw.Close()
	raw.SetMaxOpenConns(1)
	require.NoError(t, goose.UpTo(raw, "migrations", 111))

	_, err = raw.Exec(`INSERT OR REPLACE INTO tool_trust (tool, trust) VALUES
		('create_target', 'execute'),
		('create_track', 'execute'),
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
		// 00065 seeds at their seeded value: reaction only.
		"create_idea@reaction":   "execute",
		"remind_me@reaction":     "execute",
		"brief_context@reaction": "execute",
		// Owner decisions (create_track's seed was ask; the owner raised it):
		// every surface the tool is on today.
		"create_track@main":      "execute",
		"create_track@reaction":  "execute",
		"create_target@main":     "execute",
		"create_target@reaction": "execute",
	}, got, "the External tool's and the unknown tool's rows never took effect and are dropped")

	require.NoError(t, goose.Down(raw, "migrations"))
	var trust string
	require.NoError(t, raw.QueryRow(`SELECT trust FROM tool_trust WHERE tool = 'create_idea'`).Scan(&trust))
	assert.Equal(t, "execute", trust)
	require.NoError(t, raw.QueryRow(`SELECT trust FROM tool_trust WHERE tool = 'create_target'`).Scan(&trust))
	assert.Equal(t, "execute", trust)
}
