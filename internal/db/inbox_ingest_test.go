package db

import (
	"database/sql"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func syncedAtOf(t *testing.T, d *DB, channelID, ts string) float64 {
	t.Helper()
	var v float64
	require.NoError(t, d.QueryRow(`SELECT synced_at FROM messages WHERE channel_id = ? AND ts = ?`, channelID, ts).Scan(&v))
	return v
}

// An insert that does not stamp synced_at (rows stored before migration
// 00189, a writer other than the Slack sync, every existing test fixture)
// keeps 0, and the detectors read it as the post time, exactly as they read
// ts_unix before the column existed.
func TestMessagesSyncedAt_UnstampedReadsAsPostTime(t *testing.T) {
	d := openTestDB(t)
	_, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', '1500.000100', '1:U_OTHER', '<@U_ME> raw')`)
	require.NoError(t, err)
	require.NoError(t, d.UpsertMessage(Message{ChannelID: "1:C1", TS: "1501.000100", UserID: "1:U_OTHER", Text: "<@U_ME> via upsert"}))
	assert.Equal(t, 0.0, syncedAtOf(t, d, "1:C1", "1500.000100"))
	assert.Equal(t, 0.0, syncedAtOf(t, d, "1:C1", "1501.000100"))

	before, err := d.FindPendingMentions(1, "1:U_ME", 1400)
	require.NoError(t, err)
	assert.Len(t, before, 2, "posted after the watermark")
	after, err := d.FindPendingMentions(1, "1:U_ME", 1600)
	require.NoError(t, err)
	assert.Empty(t, after, "posted before the watermark")
}

// queryPlan is EXPLAIN QUERY PLAN's detail lines for query, every bind a
// placeholder value.
func queryPlan(t *testing.T, d *DB, query string) []string {
	t.Helper()
	args := make([]any, strings.Count(query, "?"))
	for i := range args {
		args[i] = "1"
	}
	rows, err := d.Query(`EXPLAIN QUERY PLAN `+query, args...)
	require.NoError(t, err)
	defer rows.Close()
	var plan []string
	for rows.Next() {
		var id, parent, notused int
		var detail string
		require.NoError(t, rows.Scan(&id, &parent, &notused, &detail))
		plan = append(plan, detail)
	}
	require.NoError(t, rows.Err())
	return plan
}

// Every Slack detector reads only the messages past its bound through an
// index range, never the whole table (a scan of every message each cycle).
func TestInboxDetectors_ReadARangeNotTheTable(t *testing.T) {
	d := openTestDB(t)
	cases := []struct {
		name, query, index string
	}{
		{"mentions", pendingMentionsStoredSQL, "idx_messages_synced_at"},
		{"mentions posted since", pendingMentionsPostedSQL, "idx_messages_ts_unix"},
		{"dms", pendingDMsSQL, "idx_messages_synced_at"},
		{"thread replies", threadRepliesSQL, "idx_messages_synced_at"},
		{"reaction requests", reactionRequestsSQL, "idx_messages_synced_at"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			plan := queryPlan(t, d, tc.query)
			joined := strings.Join(plan, "\n")
			assert.Contains(t, joined, "SEARCH m USING INDEX "+tc.index+" (", joined)
			for _, line := range plan {
				assert.False(t, strings.HasPrefix(line, "SCAN m"), "full scan: %s\n%s", line, joined)
				assert.False(t, strings.HasPrefix(line, "SCAN c") || strings.HasPrefix(line, "SCAN r"), "joined table scanned: %s\n%s", line, joined)
			}
		})
	}
}

// The sync's own stamp is stored as given.
func TestMessagesSyncedAt_ExplicitStamp(t *testing.T) {
	d := openTestDB(t)
	require.NoError(t, d.UpsertMessage(Message{ChannelID: "1:C1", TS: "1000.000100", UserID: "1:U1", Text: "a", SyncedAt: 1234.5}))
	tx, err := d.Begin()
	require.NoError(t, err)
	_, err = d.UpsertMessageBatch(tx, []Message{{ChannelID: "1:C1", TS: "1001.000100", UserID: "1:U1", Text: "b", SyncedAt: 1001}})
	require.NoError(t, err)
	require.NoError(t, tx.Commit())

	assert.Equal(t, 1234.5, syncedAtOf(t, d, "1:C1", "1000.000100"))
	assert.Equal(t, 1001.0, syncedAtOf(t, d, "1:C1", "1001.000100"))
}

// An edit, a tombstone or a re-fetch of a stored message never moves
// synced_at: the upsert's DO UPDATE branch leaves it.
func TestMessagesSyncedAt_UpdateDoesNotBump(t *testing.T) {
	d := openTestDB(t)
	require.NoError(t, d.UpsertMessage(Message{ChannelID: "1:C1", TS: "1000.000100", UserID: "1:U1", Text: "a", SyncedAt: 500}))

	require.NoError(t, d.UpsertMessage(Message{ChannelID: "1:C1", TS: "1000.000100", UserID: "1:U1", Text: "edited", IsEdited: true, SyncedAt: 9999}))
	tx, err := d.Begin()
	require.NoError(t, err)
	_, err = d.UpsertMessageBatch(tx, []Message{{ChannelID: "1:C1", TS: "1000.000100", UserID: "1:U1", Text: "", IsDeleted: true}})
	require.NoError(t, err)
	require.NoError(t, tx.Commit())
	_, err = d.Exec(`UPDATE messages SET text = 'healed', is_deleted = 0 WHERE channel_id = '1:C1'`)
	require.NoError(t, err)

	assert.Equal(t, 500.0, syncedAtOf(t, d, "1:C1", "1000.000100"))
}

// A message stored after the watermark passed its post time is found by the
// pipeline detectors (they compare synced_at), not by the post-time variant
// `inbox backfill-mentions` uses.
func TestInbox_DetectorsCompareStoredTime(t *testing.T) {
	d := openTestDB(t)
	_, err := d.Exec(`INSERT INTO channels (id, name, type) VALUES ('1:C1', 'general', 'public'), ('1:D1', 'alice', 'dm')`)
	require.NoError(t, err)
	const watermark = 2000.0
	stored := []Message{
		{ChannelID: "1:C1", TS: "1500.000100", UserID: "1:U_OTHER", Text: "<@U_ME> late", SyncedAt: 2100},
		{ChannelID: "1:D1", TS: "1500.000200", UserID: "1:U_OTHER", Text: "late DM", SyncedAt: 2100},
		{ChannelID: "1:C1", TS: "1400.000100", UserID: "1:U_ME", Text: "root", ThreadTS: sql.NullString{String: "1400.000100", Valid: true}, SyncedAt: 1400},
		{ChannelID: "1:C1", TS: "1500.000300", UserID: "1:U_OTHER", Text: "late reply", ThreadTS: sql.NullString{String: "1400.000100", Valid: true}, SyncedAt: 2100},
		{ChannelID: "1:C1", TS: "1500.000400", UserID: "1:U_ME", Text: "mine", SyncedAt: 2100},
		{ChannelID: "1:C1", TS: "1900.000100", UserID: "1:U_OTHER", Text: "<@U_ME> early", SyncedAt: 1900},
	}
	for _, m := range stored {
		require.NoError(t, d.UpsertMessage(m))
	}
	_, err = d.Exec(`INSERT INTO reactions (channel_id, message_ts, user_id, emoji) VALUES ('1:C1', '1500.000400', '1:U_OTHER', 'eyes')`)
	require.NoError(t, err)

	mentions, err := d.FindPendingMentions(1, "1:U_ME", watermark)
	require.NoError(t, err)
	require.Len(t, mentions, 1)
	assert.Equal(t, "1500.000100", mentions[0].MessageTS)

	dms, err := d.FindPendingDMs(1, "1:U_ME", watermark)
	require.NoError(t, err)
	require.Len(t, dms, 1)
	assert.Equal(t, "1500.000200", dms[0].MessageTS)

	replies, err := d.FindThreadRepliesToUser(1, "1:U_ME", watermark)
	require.NoError(t, err)
	require.Len(t, replies, 1)
	assert.Equal(t, "1500.000300", replies[0].MessageTS)

	reactions, err := d.FindReactionRequests(1, "1:U_ME", watermark)
	require.NoError(t, err)
	require.Len(t, reactions, 1)
	assert.Equal(t, "1500.000400", reactions[0].MessageTS)

	posted, err := d.FindPendingMentionsPostedSince(1, "1:U_ME", 1450)
	require.NoError(t, err)
	require.Len(t, posted, 2, "post-time window: both mentions posted after 1450")
}

func TestFirstCycleAt_SetOnceKeepsTheFirst(t *testing.T) {
	d := openTestDB(t)
	id, err := d.CreateSlackAccount(SlackAccount{})
	require.NoError(t, err)
	got, err := d.SlackFirstCycleAt(id)
	require.NoError(t, err)
	assert.True(t, got.IsZero(), "a new account row has no first cycle")

	first := time.Date(2026, 11, 15, 12, 0, 0, 0, time.UTC)
	require.NoError(t, d.SetSlackFirstCycleAtOnce(id, first))
	require.NoError(t, d.SetSlackFirstCycleAtOnce(id, first.Add(time.Hour)))
	got, err = d.SlackFirstCycleAt(id)
	require.NoError(t, err)
	assert.True(t, first.Equal(got), "got %v", got)

	missing, err := d.SlackFirstCycleAt(id + 100)
	require.NoError(t, err)
	assert.True(t, missing.IsZero())
}

// The migration rewrites no message row: those stored before it keep
// synced_at = 0 and are detected by their post time.
func TestMigration_MessagesSyncedAtFromTs(t *testing.T) {
	path := filepath.Join(t.TempDir(), "w.db")
	d, err := Open(path)
	require.NoError(t, err)
	require.NoError(t, gooseDownTo(d.DB, "migrations", 188))
	_, err = d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', '1700000000.000100', '1:U_OTHER', '<@U_ME> old')`)
	require.NoError(t, err)
	require.NoError(t, d.Close())

	d, err = Open(path)
	require.NoError(t, err)
	defer d.Close()
	assert.Equal(t, 0.0, syncedAtOf(t, d, "1:C1", "1700000000.000100"))
	found, err := d.FindPendingMentions(1, "1:U_ME", 1699999999)
	require.NoError(t, err)
	assert.Len(t, found, 1)
	found, err = d.FindPendingMentions(1, "1:U_ME", 1700000000)
	require.NoError(t, err)
	assert.Empty(t, found)
}

// Existing accounts start their first cycle at the migration, so a late page
// of theirs is not mistaken for a first sync; an account added later starts
// with none.
func TestMigration_FirstCycleAtForExistingAccounts(t *testing.T) {
	path := filepath.Join(t.TempDir(), "w.db")
	d, err := Open(path)
	require.NoError(t, err)
	require.NoError(t, gooseDownTo(d.DB, "migrations", 188))
	_, err = d.Exec(`INSERT INTO slack_accounts (id, team_id) VALUES (1, 'T000')`)
	require.NoError(t, err)
	require.NoError(t, d.Close())

	before := time.Now().Add(-time.Second)
	d, err = Open(path)
	require.NoError(t, err)
	defer d.Close()
	first, err := d.SlackFirstCycleAt(1)
	require.NoError(t, err)
	assert.False(t, first.Before(before.Truncate(time.Second)), "first_cycle_at = the migration, got %v", first)
	assert.False(t, first.After(time.Now()), "got %v", first)

	id, err := d.CreateSlackAccount(SlackAccount{})
	require.NoError(t, err)
	fresh, err := d.SlackFirstCycleAt(id)
	require.NoError(t, err)
	assert.True(t, fresh.IsZero())
}
