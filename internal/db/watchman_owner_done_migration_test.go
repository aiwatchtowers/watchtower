package db

import (
	"database/sql"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestMigration00204_BackfillsCorrectionSent replays goose to 00203, seeds a
// corrected item (with and without feedback_at), an OK'd one and an unjudged
// one, applies 00204 and checks that only the corrected ones are stamped as
// sent (feedback_at, else created_at), so a correction stored before the
// column existed never shows Retry; owner_done_at starts empty.
func TestMigration00204_BackfillsCorrectionSent(t *testing.T) {
	t.Parallel()
	raw, err := sql.Open("sqlite3", ":memory:")
	require.NoError(t, err)
	defer raw.Close()
	raw.SetMaxOpenConns(1)
	require.NoError(t, gooseUpTo(raw, "migrations", 203))
	_, err = raw.Exec(`INSERT INTO projects (id, name, folder_path) VALUES (1, 'acme', '/tmp/acme')`)
	require.NoError(t, err)
	_, err = raw.Exec(`INSERT INTO watchman_items (id, workbench_id, kind, ref_kind, ref_id, state, outcome, feedback,
			feedback_text, feedback_at, created_at) VALUES
		(1, 1, 'ask', 'ask', 1, 'done', 'answered', 'corrected', 'Global', '2026-11-17T08:00:00Z', '2026-11-17T02:00:00Z'),
		(2, 1, 'ask', 'ask', 2, 'done', 'answered', 'corrected', 'Global', NULL, '2026-11-17T03:00:00Z'),
		(3, 1, 'ask', 'ask', 3, 'done', 'answered', 'ok', '', '2026-11-17T08:00:00Z', '2026-11-17T04:00:00Z'),
		(4, 1, 'ask', 'ask', 4, 'done', 'answered', '', '', NULL, '2026-11-17T05:00:00Z')`)
	require.NoError(t, err)

	require.NoError(t, gooseUpTo(raw, "migrations", 204))

	rows, err := raw.Query(`SELECT id, COALESCE(correction_sent_at, ''), COALESCE(owner_done_at, '') FROM watchman_items ORDER BY id`)
	require.NoError(t, err)
	defer rows.Close()
	got := map[int64]string{}
	for rows.Next() {
		var id int64
		var sent, done string
		require.NoError(t, rows.Scan(&id, &sent, &done))
		got[id] = sent
		assert.Empty(t, done, "item %d owner_done_at", id)
	}
	require.NoError(t, rows.Err())
	assert.Equal(t, map[int64]string{
		1: "2026-11-17T08:00:00Z", 2: "2026-11-17T03:00:00Z", 3: "", 4: "",
	}, got)
}
