package cmd

import (
	"log"
	"strconv"
	"testing"

	"watchtower/internal/catchup"
	"watchtower/internal/config"
	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestCatchupCommandRegistered(t *testing.T) {
	found := false
	for _, cmd := range rootCmd.Commands() {
		if cmd.Name() == "catchup" {
			found = true
			break
		}
	}
	assert.True(t, found, "catchup command should be registered")
}

// The v2 catchup command is a parent with run/regen/feedback/ack subcommands.
func TestCatchupSubcommandsRegistered(t *testing.T) {
	want := map[string]bool{"run": false, "regen": false, "feedback": false, "ack": false}
	for _, sub := range catchupCmd.Commands() {
		if _, ok := want[sub.Name()]; ok {
			want[sub.Name()] = true
		}
	}
	for name, found := range want {
		assert.True(t, found, "catchup subcommand %q should be registered", name)
	}
}

func TestCatchupSubcommandFlags(t *testing.T) {
	assert.NotNil(t, catchupRunCmd.Flags().Lookup("json"), "catchup run --json")
	assert.NotNil(t, catchupRegenCmd.Flags().Lookup("comment"), "catchup regen --comment")
	assert.NotNil(t, catchupFeedbackCmd.Flags().Lookup("rating"), "catchup feedback --rating")
	assert.NotNil(t, catchupFeedbackCmd.Flags().Lookup("comment"), "catchup feedback --comment")
}

func TestCatchupRunRequiresConfig(t *testing.T) {
	oldFlagConfig := flagConfig
	flagConfig = "/nonexistent/path/config.yaml"
	defer func() { flagConfig = oldFlagConfig }()

	err := catchupRunCmd.RunE(catchupRunCmd, nil)
	assert.Error(t, err)
}

// TestCatchupAcknowledgeCascade exercises the pipeline Acknowledge cascade: a
// theme referencing one digest + one inbox item is acknowledged → exactly those
// rows become read, an unrelated digest stays unread, the theme flips to
// reviewed, and the session's reviewed_count is bumped.
func TestCatchupAcknowledgeCascade(t *testing.T) {
	d := db.OpenTestDB(t)

	// Referenced digest (will be acked) + an unrelated digest (must stay unread).
	res, err := d.Exec(
		`INSERT INTO digests (channel_id, period_from, period_to, type, summary, read_at)
		 VALUES ('C1', 1, 2, 'channel', 'referenced', NULL)`)
	require.NoError(t, err)
	digestID, err := res.LastInsertId()
	require.NoError(t, err)

	res, err = d.Exec(
		`INSERT INTO digests (channel_id, period_from, period_to, type, summary, read_at)
		 VALUES ('C2', 1, 2, 'channel', 'unrelated', NULL)`)
	require.NoError(t, err)
	otherDigestID, err := res.LastInsertId()
	require.NoError(t, err)

	// Referenced inbox item (will be acked).
	res, err = d.Exec(
		`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, status, priority, read_at)
		 VALUES ('C1', '100.1', 'U9', 'mention', 'pending', 'high', NULL)`)
	require.NoError(t, err)
	inboxID, err := res.LastInsertId()
	require.NoError(t, err)

	sessionID, err := d.CreateCatchupSession("")
	require.NoError(t, err)
	themeID, err := d.InsertCatchupTheme(db.CatchupTheme{
		SessionID: sessionID,
		Title:     "T",
		GenState:  "ready",
		RefsJSON:  `[{"area":"digests","id":` + strconv.FormatInt(digestID, 10) + `,"label":"d"},{"area":"inbox","id":` + strconv.FormatInt(inboxID, 10) + `,"label":"i"}]`,
	})
	require.NoError(t, err)

	cfg := &config.Config{}
	p := catchup.New(d, cfg, nil, log.New(log.Writer(), "", 0))
	require.NoError(t, p.Acknowledge(themeID))

	// Referenced digest + inbox item are now read.
	assert.True(t, digestRead(t, d, digestID), "referenced digest should be read")
	assert.True(t, inboxRead(t, d, inboxID), "referenced inbox item should be read")
	// Unrelated digest untouched.
	assert.False(t, digestRead(t, d, otherDigestID), "unrelated digest should stay unread")

	// Theme reviewed + session progressed.
	theme, err := d.GetCatchupTheme(themeID)
	require.NoError(t, err)
	assert.Equal(t, "reviewed", theme.ReviewState)

	sess, err := d.GetActiveCatchupSession()
	require.NoError(t, err)
	require.NotNil(t, sess)
	assert.Equal(t, 1, sess.ReviewedCount)
}

func digestRead(t *testing.T, d *db.DB, id int64) bool {
	t.Helper()
	var readAt *string
	err := d.QueryRow(`SELECT read_at FROM digests WHERE id=?`, id).Scan(&readAt)
	require.NoError(t, err)
	return readAt != nil && *readAt != ""
}

func inboxRead(t *testing.T, d *db.DB, id int64) bool {
	t.Helper()
	var readAt *string
	err := d.QueryRow(`SELECT read_at FROM inbox_items WHERE id=?`, id).Scan(&readAt)
	require.NoError(t, err)
	return readAt != nil && *readAt != ""
}
