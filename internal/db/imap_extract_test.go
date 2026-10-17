package db

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func seedImapExtractMailbox(t *testing.T, d *DB) int64 {
	t.Helper()
	id, err := d.CreateEmailAccount(EmailAccount{Provider: "imap", EmailAddress: "me@example.com",
		Host: "imap.example.com", Port: 993, Security: "ssl", Folder: "INBOX"})
	require.NoError(t, err)
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
	seedImapExtractMessage(t, d, acct, 4, iso(20)) // ... shared with this one
	seedImapExtractMessage(t, d, acct, 5, iso(30)) // above the bound when bounded
	seedImapExtractMessage(t, d, acct, 6, "")      // undated: never returned

	floor := float64(base.Unix())
	got, err := d.ListImapMessagesForExtract(acct, floor, 0, 2)
	require.NoError(t, err)
	ids := make([]string, 0, len(got))
	for _, m := range got {
		assert.Equal(t, m.MessageID, m.ThreadID, "an IMAP message is its own thread")
		ids = append(ids, m.MessageID)
	}
	assert.Equal(t, []string{"2-2", "2-3", "2-4"}, ids, "the LIMIT cut inside second 20 is drained")

	bounded, err := d.ListImapMessagesForExtract(acct, floor, float64(base.Add(20*time.Second).Unix()), 0)
	require.NoError(t, err)
	assert.Len(t, bounded, 3, "beforeTS bounds the window")

	newest, err := d.ImapNewestMessageTS(acct)
	require.NoError(t, err)
	assert.Equal(t, float64(base.Add(30*time.Second).Unix()), newest)
}

// #615: the mailbox ideas floor round-trips, a missing mailbox reads as 0,
// and stream_digests accepts source 'imap' after migration 00134.
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
