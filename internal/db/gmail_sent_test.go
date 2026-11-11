package db

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

type gmailOwnSentCase struct {
	name, labels, from, account string
	want                        bool
}

var gmailOwnSentCases = []gmailOwnSentCase{
	{"sent label, any sender", `["SENT"]`, "colleague-a@example.com", "owner@example.com", true},
	{"sent among labels, other sender", `["INBOX","SENT"]`, "colleague-a@example.com", "owner@example.com", true},
	{"owner address, case and space", `["INBOX"]`, "Owner@Example.com ", "owner@example.com", true},
	{"other sender", `["INBOX"]`, "colleague-a@example.com", "owner@example.com", false},
	{"labels not json", `not json`, "colleague-a@example.com", "owner@example.com", false},
	{"empty sender and account", `["INBOX"]`, "", "", false},
	{"user label containing SENT unquoted", `["Label_SENT_1"]`, "colleague-a@example.com", "owner@example.com", false},
}

func TestGmailOwnSent_Cases(t *testing.T) {
	for _, c := range gmailOwnSentCases {
		assert.Equal(t, c.want, GmailOwnSent(c.labels, c.from, c.account), c.name)
	}
}

// TestGmailOwnSentSQL_MatchesGo: the SQL twin decides every case exactly as
// the Go predicate does.
func TestGmailOwnSentSQL_MatchesGo(t *testing.T) {
	d := OpenTestDB(t)
	for i, c := range gmailOwnSentCases {
		acct, err := d.CreateGoogleAccount(GoogleAccount{Email: c.account, Label: "acme"})
		require.NoError(t, err)
		msgID := "m" + string(rune('a'+i))
		_, err = d.Exec(`INSERT INTO gmail_messages (account_id, id, thread_id, from_email, labels_json) VALUES (?, ?, 't', ?, ?)`,
			acct, msgID, c.from, c.labels)
		require.NoError(t, err)
		var got bool
		require.NoError(t, d.QueryRow(`SELECT `+GmailOwnSentSQL("m", "a")+
			` FROM gmail_messages m JOIN google_accounts a ON a.id = m.account_id WHERE m.account_id = ? AND m.id = ?`,
			acct, msgID).Scan(&got), c.name)
		assert.Equal(t, GmailOwnSent(c.labels, c.from, c.account), got, c.name)
	}
}

func TestParseGmailChannelID(t *testing.T) {
	acct, thread, ok := ParseGmailChannelID("gmail:3:thr-a")
	assert.True(t, ok)
	assert.Equal(t, int64(3), acct)
	assert.Equal(t, "thr-a", thread)

	acct, thread, ok = ParseGmailChannelID(GmailChannelID(42, "a:b:c"))
	assert.True(t, ok)
	assert.Equal(t, int64(42), acct)
	assert.Equal(t, "a:b:c", thread)

	for _, bad := range []string{"gmail:3:", "gmail:x:thr", "imap:1:2-3", "C123", "", "gmail:3"} {
		_, _, ok := ParseGmailChannelID(bad)
		assert.False(t, ok, "must not parse %q", bad)
	}
}

func TestGmailSentCatchUpAt_RoundTrip(t *testing.T) {
	d := OpenTestDB(t)
	id, err := d.CreateGoogleAccount(GoogleAccount{Email: "owner@example.com", Label: "acme"})
	require.NoError(t, err)

	got, err := d.GmailSentCatchUpAt(id)
	require.NoError(t, err)
	assert.Equal(t, "", got)

	now := time.Now()
	require.NoError(t, d.SetGmailSentCatchUpAt(id, now))
	got, err = d.GmailSentCatchUpAt(id)
	require.NoError(t, err)
	assert.Equal(t, now.UTC().Format(time.RFC3339), got)

	got, err = d.GmailSentCatchUpAt(id + 1000)
	require.NoError(t, err)
	assert.Equal(t, "", got)
}
