package db

import (
	"database/sql"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestMigration00190_SeedsMutedAtWithTheUpgrade replays goose to 00189,
// seeds a channel muted long ago whose updated_at is old (the old mute
// writers did not always touch it) and an unmuted one, applies 00190 and
// checks that the muted one's muted_at is the upgrade time, so the "muted
// 30+ days" suggestion counts from the upgrade, and the unmuted one has none.
func TestMigration00190_SeedsMutedAtWithTheUpgrade(t *testing.T) {
	t.Parallel()
	raw, err := sql.Open("sqlite3", ":memory:")
	require.NoError(t, err)
	defer raw.Close()
	raw.SetMaxOpenConns(1)
	require.NoError(t, gooseUpTo(raw, "migrations", 189))
	_, err = raw.Exec(`INSERT INTO channels (id, name, type) VALUES ('1:C0MUTED', 'muted', 'public'), ('1:C0OPEN', 'open', 'public')`)
	require.NoError(t, err)
	_, err = raw.Exec(`INSERT INTO channel_settings (channel_id, is_muted_for_llm, updated_at) VALUES
		('1:C0MUTED', 1, '2020-01-01T00:00:00Z'), ('1:C0OPEN', 0, '2020-01-01T00:00:00Z')`)
	require.NoError(t, err)

	before := time.Now().UTC().Add(-time.Second)
	require.NoError(t, gooseUpTo(raw, "migrations", 190))

	var mutedAt, openAt string
	require.NoError(t, raw.QueryRow(`SELECT muted_at FROM channel_settings WHERE channel_id = '1:C0MUTED'`).Scan(&mutedAt))
	require.NoError(t, raw.QueryRow(`SELECT muted_at FROM channel_settings WHERE channel_id = '1:C0OPEN'`).Scan(&openAt))
	at, err := time.Parse(time.RFC3339, mutedAt)
	require.NoError(t, err)
	assert.False(t, at.Before(before.Truncate(time.Second)), "muted_at %s is the upgrade time", mutedAt)
	assert.Empty(t, openAt)
}
