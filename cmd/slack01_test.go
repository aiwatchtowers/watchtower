package cmd

import (
	"bytes"
	"path/filepath"
	"testing"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	watchtowerslack "watchtower/internal/slack"
)

// tableRowCounts returns COUNT(*) of every table in the database, keyed by
// table name.
func tableRowCounts(t *testing.T, database *db.DB) map[string]int {
	t.Helper()
	rows, err := database.Query(`SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name`)
	require.NoError(t, err)
	defer rows.Close()
	var names []string
	for rows.Next() {
		var name string
		require.NoError(t, rows.Scan(&name))
		names = append(names, name)
	}
	require.NoError(t, rows.Err())

	counts := make(map[string]int, len(names))
	for _, name := range names {
		var n int
		require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM "`+name+`"`).Scan(&n))
		counts[name] = n
	}
	return counts
}

// TestSlack01_RemoveIsNonDestructive guards SLACK-01: `slack remove <id>`
// deletes only that account's token file and marks its row removed/disabled.
// The row stays, every synced or derived row stays (no cascade delete, unlike
// `google remove`), and the other account is untouched.
func TestSlack01_RemoveIsNonDestructive(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	writeLegacyConfig(t, "")
	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)

	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	keepID, err := database.CreateSlackAccount(db.SlackAccount{TeamID: "T1", Label: "Keep", CurrentUserID: "1:U1", Enabled: true})
	require.NoError(t, err)
	removeID, err := database.CreateSlackAccount(db.SlackAccount{TeamID: "T2", Label: "Remove", CurrentUserID: "2:U2", Enabled: true})
	require.NoError(t, err)
	require.Equal(t, int64(2), removeID)

	// Synced and derived data of the account being removed.
	require.NoError(t, database.UpsertChannel(db.Channel{ID: "2:C1", Name: "general", Type: "public"}))
	require.NoError(t, database.UpsertUser(db.User{ID: "2:U2", Name: "owner"}))
	require.NoError(t, database.UpsertMessage(db.Message{ChannelID: "2:C1", TS: "1700000000.000100", UserID: "2:U2", Text: "hello"}))
	for _, stmt := range []string{
		`INSERT INTO digests (channel_id, period_from, period_to, type, summary) VALUES ('2:C1', 1, 2, 'channel', 'kept')`,
		`INSERT INTO tracks (text, channel_ids, assignee_user_id) VALUES ('kept track', '["2:C1"]', '2:U2')`,
		`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type) VALUES ('2:C1', '1700000000.000100', '2:U2', 'mention')`,
	} {
		_, err := database.Exec(stmt)
		require.NoError(t, err, stmt)
	}

	keepBefore, err := database.GetSlackAccount(keepID)
	require.NoError(t, err)
	countsBefore := tableRowCounts(t, database)
	require.NoError(t, database.Close())

	keepToken := watchtowerslack.NewTokenStore(cfg.WorkspaceDir(), keepID)
	removeToken := watchtowerslack.NewTokenStore(cfg.WorkspaceDir(), removeID)
	require.NoError(t, keepToken.Save(&watchtowerslack.Token{AccessToken: "xoxp-keep", TeamID: "T1"}))
	require.NoError(t, removeToken.Save(&watchtowerslack.Token{AccessToken: "xoxp-remove", TeamID: "T2"}))

	cmd := &cobra.Command{}
	out := &bytes.Buffer{}
	cmd.SetOut(out)
	require.NoError(t, runSlackRemove(cmd, []string{"2"}))
	assert.Contains(t, out.String(), "Its synced data was kept")

	assert.False(t, removeToken.Exists(), "the removed account's token file must be deleted")
	assert.True(t, keepToken.Exists(), "another account's token file must survive")

	database, err = db.Open(cfg.DBPath())
	require.NoError(t, err)
	defer database.Close()

	removed, err := database.GetSlackAccount(removeID)
	require.NoError(t, err, "the removed account's row must be kept")
	assert.Equal(t, "removed", removed.Status)
	assert.False(t, removed.Enabled)
	assert.Equal(t, "Remove", removed.Label, "label stays for historical attribution")

	keepAfter, err := database.GetSlackAccount(keepID)
	require.NoError(t, err)
	assert.Equal(t, keepBefore, keepAfter)

	countsAfter := tableRowCounts(t, database)
	assert.Equal(t, countsBefore, countsAfter, "remove must not delete or add a row in any table")
	for _, table := range []string{"channels", "users", "messages", "digests", "tracks", "inbox_items"} {
		assert.Positive(t, countsAfter[table], "seeded %s rows must survive", table)
	}
}

// TestSlack01_RemoveUnknownAccountChangesNothing: removing an id with no row
// fails before touching any token file.
func TestSlack01_RemoveUnknownAccountChangesNothing(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	writeLegacyConfig(t, "")
	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)

	token := watchtowerslack.NewTokenStore(cfg.WorkspaceDir(), 7)
	require.NoError(t, token.Save(&watchtowerslack.Token{AccessToken: "xoxp-orphan"}))

	cmd := &cobra.Command{}
	cmd.SetOut(&bytes.Buffer{})
	require.Error(t, runSlackRemove(cmd, []string{"7"}))
	assert.True(t, token.Exists(), "a failed remove must not delete a token file")
}

// TestSlack01_ConnectRollbackIsSoftRemove: the add-failure rollback uses the
// same soft remove — the freshly created row is kept as removed/disabled,
// never hard-deleted.
func TestSlack01_ConnectRollbackIsSoftRemove(t *testing.T) {
	database, err := db.Open(filepath.Join(t.TempDir(), "watchtower.db"))
	require.NoError(t, err)
	defer database.Close()

	id, err := database.CreateSlackAccount(db.SlackAccount{Label: "Half-connected", Enabled: true})
	require.NoError(t, err)

	warn := &bytes.Buffer{}
	rollbackSlackAccount(database, id, warn)
	assert.Empty(t, warn.String())

	acct, err := database.GetSlackAccount(id)
	require.NoError(t, err, "the rolled-back row must be kept")
	assert.Equal(t, "removed", acct.Status)
	assert.False(t, acct.Enabled)
}
