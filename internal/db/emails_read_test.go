package db

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestListLocalEmails_RefusesBadQuery(t *testing.T) {
	d := OpenTestDB(t)
	ctx := context.Background()

	_, err := d.ListLocalEmails(ctx, LocalEmailQuery{Store: EmailStoreGmail, AccountID: 1, Limit: 0})
	require.Error(t, err, "a non-positive limit is never an unbounded read")
	_, err = d.ListLocalEmails(ctx, LocalEmailQuery{Store: "pop3", AccountID: 1, Limit: 10})
	require.Error(t, err)

	got, err := d.ListLocalEmails(ctx, LocalEmailQuery{Store: EmailStoreIMAP, AccountID: 1, Limit: 10})
	require.NoError(t, err)
	assert.NotNil(t, got, "no rows is an empty slice")
	assert.Empty(t, got)
}

func TestGetLocalEmail_MissingAndMalformed(t *testing.T) {
	d := OpenTestDB(t)
	ctx := context.Background()
	acct, err := d.CreateEmailAccount(EmailAccount{Provider: "imap", EmailAddress: "home@example.com", Security: "ssl", Label: "home"})
	require.NoError(t, err)
	now := time.Now().UTC().Format(time.RFC3339)
	require.NoError(t, d.UpsertImapMessage(ImapMessage{AccountID: acct, UID: 5, UIDValidity: 3, Subject: "hi",
		BodyText: "body", InternalDate: now, ToJSON: "[]", CcJSON: "[]"}, now))

	m, found, err := d.GetLocalEmail(ctx, EmailStoreIMAP, acct, "3-5")
	require.NoError(t, err)
	require.True(t, found)
	assert.Equal(t, "3-5", m.ID)
	assert.Equal(t, "body", m.BodyText)

	for _, id := range []string{"", "5", "3-", "-5", "x-5", "3-5-1", "-1-5"} {
		_, found, err := d.GetLocalEmail(ctx, EmailStoreIMAP, acct, id)
		require.NoError(t, err, id)
		assert.False(t, found, id)
	}
	_, found, err = d.GetLocalEmail(ctx, EmailStoreIMAP, acct+1, "3-5")
	require.NoError(t, err)
	assert.False(t, found, "another account's message is not found")
	_, found, err = d.GetLocalEmail(ctx, EmailStoreGmail, 1, "nope")
	require.NoError(t, err)
	assert.False(t, found)
	_, _, err = d.GetLocalEmail(ctx, "pop3", 1, "x")
	require.Error(t, err)
}

// list_emails pages one account's mail by date: both stores carry an
// (account_id, internal_date) index (migration 00113).
func TestLocalEmails_AccountDateIndexes(t *testing.T) {
	d := OpenTestDB(t)
	for table, index := range map[string]string{
		"gmail_messages": "idx_gmail_messages_account_date",
		"imap_messages":  "idx_imap_messages_account_date",
	} {
		assert.Equal(t, []string{"account_id", "internal_date"}, localEmailIndexColumns(t, d, index), table)

		var owner string
		require.NoError(t, d.QueryRow(`SELECT tbl_name FROM sqlite_master WHERE type='index' AND name=?`, index).Scan(&owner))
		assert.Equal(t, table, owner)
	}
}

func localEmailIndexColumns(t *testing.T, d *DB, index string) []string {
	t.Helper()
	rows, err := d.Query(`SELECT name FROM pragma_index_info(?)`, index)
	require.NoError(t, err)
	defer rows.Close()
	var cols []string
	for rows.Next() {
		var c string
		require.NoError(t, rows.Scan(&c))
		cols = append(cols, c)
	}
	require.NoError(t, rows.Err())
	return cols
}
