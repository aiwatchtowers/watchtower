package db

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func seedImapExtractMailbox(t *testing.T, d *DB) int64 {
	t.Helper()
	id, err := d.CreateEmailAccount(EmailAccount{Provider: "imap", EmailAddress: "me@example.com",
		Host: "imap.example.com", Port: 993, Security: "ssl", Folder: "INBOX"})
	require.NoError(t, err)
	require.NoError(t, d.SetImapWatermark(id, 0, 2)) // current UIDVALIDITY epoch 2
	return id
}

func seedImapExtractMessage(t *testing.T, d *DB, accountID, uid int64, date string) {
	t.Helper()
	require.NoError(t, d.UpsertImapMessage(ImapMessage{AccountID: accountID, UID: uid, UIDValidity: 2,
		Subject: "s", BodyText: "b", InternalDate: date}, date))
}

// #615: the IMAP extract loader returns messages above the floor oldest
// first, one thread per message ("<uidvalidity>-<uid>"), skips undated mail,
// honours the upper bound, and drains a LIMIT cut that lands inside a second.
func TestListImapMessagesForExtract_WindowAndBoundaryDrain(t *testing.T) {
	d := openTestDB(t)
	acct := seedImapExtractMailbox(t, d)
	base := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	iso := func(sec int) string { return base.Add(time.Duration(sec) * time.Second).Format(time.RFC3339) }
	seedImapExtractMessage(t, d, acct, 1, iso(0))  // at the floor: excluded
	seedImapExtractMessage(t, d, acct, 2, iso(10)) // first
	seedImapExtractMessage(t, d, acct, 3, iso(20)) // boundary second ...
	seedImapExtractMessage(t, d, acct, 4, iso(20)) // ... shared with this one ...
	seedImapExtractMessage(t, d, acct, 7, iso(20)) // ... and more tie-mates
	seedImapExtractMessage(t, d, acct, 8, iso(20)) // ... than the cap of 2 itself
	seedImapExtractMessage(t, d, acct, 5, iso(30)) // above the bound when bounded
	seedImapExtractMessage(t, d, acct, 6, "")      // undated: never returned
	// The same mail stored under an earlier UIDVALIDITY (before a reset):
	// never returned, or the window would be mined twice under two refs.
	require.NoError(t, d.UpsertImapMessage(ImapMessage{AccountID: acct, UID: 2, UIDValidity: 1,
		Subject: "s", BodyText: "b", InternalDate: iso(10)}, iso(10)))
	require.NoError(t, d.UpsertImapMessage(ImapMessage{AccountID: acct, UID: 9, UIDValidity: 1,
		Subject: "s", BodyText: "b", InternalDate: iso(40)}, iso(40)))

	floor := float64(base.Unix())
	got, err := d.ListImapMessagesForExtract(acct, floor, 0, 2)
	require.NoError(t, err)
	ids := make([]string, 0, len(got))
	for _, m := range got {
		assert.Equal(t, m.MessageID, m.ThreadID, "an IMAP message is its own thread")
		ids = append(ids, m.MessageID)
	}
	assert.Equal(t, []string{"2-2", "2-3", "2-4", "2-7", "2-8"}, ids,
		"the LIMIT cut inside second 20 drains the whole second, past the cap")

	bounded, err := d.ListImapMessagesForExtract(acct, floor, float64(base.Add(20*time.Second).Unix()), 0)
	require.NoError(t, err)
	assert.Len(t, bounded, 5, "beforeTS bounds the window")

	newest, err := d.ImapNewestMessageTS(acct)
	require.NoError(t, err)
	assert.Equal(t, float64(base.Add(30*time.Second).Unix()), newest)
}

// #615 (F2/F5): migration 00135 keeps every non-IMAP row through Down and
// Up, drops only the IMAP rows on Down, and carries both recreated tables'
// AUTOINCREMENT high-water marks, so a new id never reuses one at or below
// the consolidator's id floor.
func TestMigration00135_DownUpKeepsRowsAndSequences(t *testing.T) {
	d, err := Open(filepath.Join(t.TempDir(), "imap-streams-cycle.db"))
	require.NoError(t, err)
	defer d.Close()
	acct := seedImapExtractMailbox(t, d)
	require.NoError(t, d.SetIdeasImapFloor(acct, 99))
	insert := func(q string, args ...any) int64 {
		res, err := d.Exec(q, args...)
		require.NoError(t, err)
		id, err := res.LastInsertId()
		require.NoError(t, err)
		return id
	}
	sd := `INSERT INTO stream_digests (source, account_id, period_from, period_to) VALUES (?, 1, 'a', 'b')`
	gmailDigest := insert(sd, "gmail")
	insert(sd, "imap")
	gone := insert(sd, "jira")
	_, err = d.Exec(`DELETE FROM stream_digests WHERE id = ?`, gone) // seq now above MAX(id)
	require.NoError(t, err)
	idea := insert(`INSERT INTO ideas (kind, title) VALUES ('idea', 't')`)
	im := `INSERT INTO idea_mentions (idea_id, source, ref) VALUES (?, ?, ?)`
	gmailMention := insert(im, idea, "gmail", "gmail:1:t")
	insert(im, idea, "imap", "imap:1:1-1")
	goneMention := insert(im, idea, "jira", "AA-1")
	_, err = d.Exec(`DELETE FROM idea_mentions WHERE id = ?`, goneMention)
	require.NoError(t, err)

	require.NoError(t, goose.DownTo(d.DB, "migrations", 134))
	assert.False(t, columnNames(t, d.DB, "email_accounts")["ideas_email_floor"], "Down dropped the floor column")
	assert.Equal(t, 1, countRows(t, d, `SELECT COUNT(*) FROM stream_digests WHERE id = ?`, gmailDigest))
	assert.Zero(t, countRows(t, d, `SELECT COUNT(*) FROM stream_digests WHERE source = 'imap'`))
	assert.Equal(t, 1, countRows(t, d, `SELECT COUNT(*) FROM idea_mentions WHERE id = ?`, gmailMention))
	assert.Zero(t, countRows(t, d, `SELECT COUNT(*) FROM idea_mentions WHERE source = 'imap'`))
	assert.Greater(t, insert(sd, "gmail"), gone, "Down carried the stream_digests sequence")

	require.NoError(t, goose.Up(d.DB, "migrations"))
	assert.Equal(t, 1, countRows(t, d, `SELECT COUNT(*) FROM stream_digests WHERE id = ?`, gmailDigest))
	assert.Equal(t, 1, countRows(t, d, `SELECT COUNT(*) FROM idea_mentions WHERE id = ?`, gmailMention))
	assert.Greater(t, insert(sd, "imap"), gone+1, "Up carried the stream_digests sequence")
	assert.Greater(t, insert(im, idea, "imap", "imap:1:1-2"), goneMention, "Up carried the idea_mentions sequence")
	assert.Equal(t, 1, countRows(t, d, `SELECT COUNT(*) FROM email_accounts WHERE id = ?`, acct))
}

// #615: the mailbox ideas floor round-trips, a missing mailbox reads as 0,
// and stream_digests accepts source 'imap' after migration 00135.
func TestIdeasImapFloorAndImapStreamDigest(t *testing.T) {
	d := openTestDB(t)
	acct := seedImapExtractMailbox(t, d)
	require.NoError(t, d.SetIdeasImapFloor(acct, 1234))
	f, err := d.IdeasImapFloor(acct)
	require.NoError(t, err)
	assert.Equal(t, float64(1234), f)
	missing, err := d.IdeasImapFloor(acct + 100)
	require.NoError(t, err)
	assert.Zero(t, missing)
	require.Error(t, d.SetIdeasImapFloor(acct+100, 1))

	_, err = d.InsertStreamDigest(StreamDigest{Source: "imap", AccountID: acct,
		PeriodFrom: "2026-09-01T10:00:00Z", PeriodTo: "2026-09-01T11:00:00Z", TopicsJSON: "[]"})
	require.NoError(t, err)
	covered, err := d.HasStreamDigestCovering("imap", acct, "2026-09-01T10:00:00Z", "2026-09-01T11:00:00Z")
	require.NoError(t, err)
	assert.True(t, covered)
}
