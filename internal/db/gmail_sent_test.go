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

// gmailAnsweredFixture is one owner account with a received message R from a
// colleague in thread thr-a and a pending email_received item for R.
type gmailAnsweredFixture struct {
	d      *DB
	acct   int64
	itemID int64
	recvAt time.Time
}

func seedGmailAnswered(t *testing.T) gmailAnsweredFixture {
	t.Helper()
	d := OpenTestDB(t)
	acct, err := d.CreateGoogleAccount(GoogleAccount{Email: "owner@example.com", Label: "acme", GmailEnabled: true})
	require.NoError(t, err)
	recvAt := time.Now().UTC().Add(-2 * time.Hour).Truncate(time.Second)
	require.NoError(t, d.UpsertGmailMessage(acct, GmailMessage{
		ID: "r1", ThreadID: "thr-a", FromEmail: "colleague-a@example.com",
		ToJSON: `["owner@example.com"]`, CcJSON: `[]`, LabelsJSON: `["INBOX"]`,
		InternalDate: recvAt.Format(time.RFC3339), SyncedAt: recvAt.Format(time.RFC3339),
	}))
	id, err := d.CreateInboxItem(InboxItem{
		ChannelID: GmailChannelID(acct, "thr-a"), MessageTS: "r1",
		SenderUserID: "colleague-a@example.com", TriggerType: "email_received",
	})
	require.NoError(t, err)
	return gmailAnsweredFixture{d: d, acct: acct, itemID: id, recvAt: recvAt}
}

func (f gmailAnsweredFixture) addMessage(t *testing.T, acct int64, id, from, labels string, at time.Time) {
	t.Helper()
	require.NoError(t, f.d.UpsertGmailMessage(acct, GmailMessage{
		ID: id, ThreadID: "thr-a", FromEmail: from, ToJSON: `["colleague-a@example.com"]`, CcJSON: `[]`,
		LabelsJSON: labels, InternalDate: at.UTC().Format(time.RFC3339), SyncedAt: at.UTC().Format(time.RFC3339),
	}))
}

func (f gmailAnsweredFixture) setItemCreatedAt(t *testing.T, id int64, at time.Time) {
	t.Helper()
	_, err := f.d.Exec(`UPDATE inbox_items SET created_at = ? WHERE id = ?`, at.UTC().Format(time.RFC3339), id)
	require.NoError(t, err)
}

func answeredIDs(t *testing.T, d *DB) []int {
	t.Helper()
	ids, err := d.GmailItemsAnsweredByOwner()
	require.NoError(t, err)
	return ids
}

func TestGmailItemsAnsweredByOwner_ReplyAfterReceived(t *testing.T) {
	f := seedGmailAnswered(t)
	f.addMessage(t, f.acct, "s1", "owner@example.com", `["SENT"]`, f.recvAt.Add(5*time.Minute))
	assert.Equal(t, []int{int(f.itemID)}, answeredIDs(t, f.d))
}

func TestGmailItemsAnsweredByOwner_ReplyBeforeItemCreated(t *testing.T) {
	f := seedGmailAnswered(t)
	f.setItemCreatedAt(t, f.itemID, f.recvAt.Add(10*time.Minute))
	f.addMessage(t, f.acct, "s1", "owner@example.com", `["SENT"]`, f.recvAt.Add(5*time.Minute))
	assert.Equal(t, []int{int(f.itemID)}, answeredIDs(t, f.d))
}

func TestGmailItemsAnsweredByOwner_OlderOwnMessageKeepsItem(t *testing.T) {
	f := seedGmailAnswered(t)
	f.addMessage(t, f.acct, "s0", "owner@example.com", `["SENT"]`, f.recvAt.Add(-time.Hour))
	assert.Empty(t, answeredIDs(t, f.d))
}

func TestGmailItemsAnsweredByOwner_AliasSentLabel(t *testing.T) {
	f := seedGmailAnswered(t)
	f.addMessage(t, f.acct, "c2", "colleague-b@example.com", `["INBOX"]`, f.recvAt.Add(5*time.Minute))
	assert.Empty(t, answeredIDs(t, f.d), "a colleague's later message without SENT is not the owner's reply")

	f.addMessage(t, f.acct, "s1", "alias@example.com", `["SENT"]`, f.recvAt.Add(6*time.Minute))
	assert.Equal(t, []int{int(f.itemID)}, answeredIDs(t, f.d))
}

func TestGmailItemsAnsweredByOwner_OtherAccountKeepsItem(t *testing.T) {
	f := seedGmailAnswered(t)
	other, err := f.d.CreateGoogleAccount(GoogleAccount{Email: "owner2@example.com", Label: "acme-2", GmailEnabled: true})
	require.NoError(t, err)
	f.addMessage(t, other, "s1", "owner2@example.com", `["SENT"]`, f.recvAt.Add(5*time.Minute))
	assert.Empty(t, answeredIDs(t, f.d))
}

func TestGmailItemsAnsweredByOwner_ReceivedRowGoneUsesCreatedAt(t *testing.T) {
	f := seedGmailAnswered(t)
	_, err := f.d.Exec(`DELETE FROM gmail_messages WHERE account_id = ? AND id = 'r1'`, f.acct)
	require.NoError(t, err)
	created := f.recvAt.Add(30 * time.Minute)
	f.setItemCreatedAt(t, f.itemID, created)

	f.addMessage(t, f.acct, "s0", "owner@example.com", `["SENT"]`, created.Add(-5*time.Minute))
	assert.Empty(t, answeredIDs(t, f.d), "a reply before the item's created_at does not answer it")

	f.addMessage(t, f.acct, "s1", "owner@example.com", `["SENT"]`, created.Add(5*time.Minute))
	assert.Equal(t, []int{int(f.itemID)}, answeredIDs(t, f.d))
}

func TestGmailItemsAnsweredByOwner_OnlyPendingEmailReceived(t *testing.T) {
	f := seedGmailAnswered(t)
	_, err := f.d.Exec(`DELETE FROM inbox_items WHERE id = ?`, f.itemID)
	require.NoError(t, err)
	_, err = f.d.CreateInboxItem(InboxItem{ChannelID: GmailChannelID(f.acct, "thr-a"), MessageTS: "r1", TriggerType: "email_cc"})
	require.NoError(t, err)
	// A resolved item for a second received message of the same thread.
	f.addMessage(t, f.acct, "r2", "colleague-a@example.com", `["INBOX"]`, f.recvAt)
	resolvedID, err := f.d.CreateInboxItem(InboxItem{ChannelID: GmailChannelID(f.acct, "thr-a"), MessageTS: "r2", TriggerType: "email_received"})
	require.NoError(t, err)
	require.NoError(t, f.d.ResolveInboxItem(int(resolvedID), "done"))
	_, err = f.d.CreateInboxItem(InboxItem{ChannelID: "imap:1:thr-a", MessageTS: "r1", TriggerType: "email_received"})
	require.NoError(t, err)

	f.addMessage(t, f.acct, "s1", "owner@example.com", `["SENT"]`, f.recvAt.Add(5*time.Minute))
	assert.Empty(t, answeredIDs(t, f.d))
}

func TestGmailItemsAnsweredByOwner_ArchivedItemSkipped(t *testing.T) {
	f := seedGmailAnswered(t)
	_, err := f.d.Exec(`UPDATE inbox_items SET archived_at = ? WHERE id = ?`,
		time.Now().UTC().Format(time.RFC3339), f.itemID)
	require.NoError(t, err)
	f.addMessage(t, f.acct, "s1", "owner@example.com", `["SENT"]`, f.recvAt.Add(5*time.Minute))
	assert.Empty(t, answeredIDs(t, f.d), "an archived pending item is not closed by a later reply")
}
