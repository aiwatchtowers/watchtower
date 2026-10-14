package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// emailFixture seeds one Google account (label "work", owner@example.com) and
// one IMAP account (label "home", home@example.com).
type emailFixture struct {
	d      *db.DB
	reg    *Registry
	gmail  int64
	imap   int64
	recent time.Time
}

func newEmailFixture(t *testing.T) emailFixture {
	t.Helper()
	d := openDB(t)
	gid, err := d.CreateGoogleAccount(db.GoogleAccount{Email: "owner@example.com", Label: "work", GmailEnabled: true})
	require.NoError(t, err)
	iid, err := d.CreateEmailAccount(db.EmailAccount{Provider: "imap", EmailAddress: "home@example.com",
		Host: "imap.example.com", Port: 993, Security: "ssl", Folder: "INBOX", Label: "home"})
	require.NoError(t, err)
	reg := New(d)
	require.NoError(t, reg.Register(NewListEmails()))
	require.NoError(t, reg.Register(NewGetEmail()))
	return emailFixture{d: d, reg: reg, gmail: gid, imap: iid, recent: time.Now().UTC().Truncate(time.Second)}
}

func (f emailFixture) seedGmail(t *testing.T, id string, at time.Time, unread bool, body string) {
	t.Helper()
	require.NoError(t, f.d.UpsertGmailMessage(f.gmail, db.GmailMessage{
		ID: id, ThreadID: "t-" + id, FromEmail: "colleague@example.com", FromName: "Colleague A",
		ToJSON: `["owner@example.com"]`, CcJSON: `["cc@example.com"]`, Subject: "subject " + id,
		Snippet: "snippet " + id, BodyText: body, InternalDate: at.UTC().Format(time.RFC3339),
		LabelsJSON: `["INBOX"]`, IsUnread: unread, Permalink: "https://mail.example.com/" + id,
		SyncedAt: at.UTC().Format(time.RFC3339),
	}))
}

func (f emailFixture) seedIMAP(t *testing.T, uid int64, at time.Time, body string) {
	t.Helper()
	require.NoError(t, f.d.UpsertImapMessage(db.ImapMessage{
		AccountID: f.imap, UID: uid, UIDValidity: 7, FromEmail: "friend@example.com", FromName: "Friend",
		ToJSON: `["home@example.com"]`, CcJSON: `[]`, Subject: fmt.Sprintf("imap %d", uid),
		Snippet: "imap snippet", BodyText: body, InternalDate: at.UTC().Format(time.RFC3339), IsUnread: true,
	}, at.UTC().Format(time.RFC3339)))
}

type listEmailsResult struct {
	Account  string `json:"account"`
	Messages []struct {
		ID        string `json:"id"`
		ThreadID  string `json:"thread_id"`
		From      string `json:"from"`
		Subject   string `json:"subject"`
		Snippet   string `json:"snippet"`
		Date      string `json:"date"`
		Unread    bool   `json:"unread"`
		Permalink string `json:"permalink"`
	} `json:"messages"`
}

func (f emailFixture) list(t *testing.T, args string) listEmailsResult {
	t.Helper()
	var out listEmailsResult
	require.NoError(t, json.Unmarshal([]byte(callReadString(t, f.reg, "list_emails", args)), &out))
	return out
}

func TestListEmails_ReadsLocalStoreOnly(t *testing.T) {
	f := newEmailFixture(t)
	f.seedGmail(t, "m1", f.recent.Add(-2*time.Hour), false, "older body")
	f.seedGmail(t, "m2", f.recent.Add(-1*time.Hour), true, "newer body")

	// The constructor takes no client factory: there is no live API to reach.
	var ctor func() *Tool = NewListEmails
	require.NotNil(t, ctor)

	got := f.list(t, `{"account":"work"}`)
	assert.Equal(t, "work", got.Account)
	require.Len(t, got.Messages, 2)
	assert.Equal(t, "m2", got.Messages[0].ID, "newest first")
	assert.Equal(t, "m1", got.Messages[1].ID)
	m := got.Messages[0]
	assert.Equal(t, "t-m2", m.ThreadID)
	assert.Equal(t, "Colleague A <colleague@example.com>", m.From)
	assert.Equal(t, "subject m2", m.Subject)
	assert.Equal(t, "snippet m2", m.Snippet)
	assert.Equal(t, f.recent.Add(-time.Hour).Format(time.RFC3339), m.Date)
	assert.True(t, m.Unread)
	assert.Equal(t, "https://mail.example.com/m2", m.Permalink)

	raw := callReadString(t, f.reg, "list_emails", `{"account":"work"}`)
	assert.NotContains(t, raw, "newer body", "a list never carries the body")
}

func TestListEmails_AccountByLabelOrAddress(t *testing.T) {
	f := newEmailFixture(t)
	f.seedGmail(t, "m1", f.recent, false, "")

	assert.Len(t, f.list(t, `{"account":"work"}`).Messages, 1)
	assert.Len(t, f.list(t, `{"account":"owner@example.com"}`).Messages, 1)
	assert.Len(t, f.list(t, `{"account":"OWNER@example.com"}`).Messages, 1, "an address matches case-insensitively")

	_, err := f.reg.CallRead(context.Background(), "list_emails", json.RawMessage(`{"account":"nobody"}`), Binding{})
	var ve *ValidationError
	require.ErrorAs(t, err, &ve)
	assert.Contains(t, ve.Msg, "unknown account")

	// A label two mailboxes share is refused, never silently resolved to one.
	_, err = f.d.CreateGoogleAccount(db.GoogleAccount{Email: "a@example.com", Label: "shared"})
	require.NoError(t, err)
	_, err = f.d.CreateEmailAccount(db.EmailAccount{Provider: "imap", EmailAddress: "b@example.com", Security: "ssl", Label: "Shared"})
	require.NoError(t, err)
	_, err = f.reg.CallRead(context.Background(), "list_emails", json.RawMessage(`{"account":"shared"}`), Binding{})
	require.ErrorAs(t, err, &ve)
	assert.Contains(t, ve.Msg, "ambiguous account")
	assert.Empty(t, f.list(t, `{"account":"b@example.com"}`).Messages, "the address still resolves")

	// A list with no messages is [] in JSON, never null.
	empty := callReadString(t, f.reg, "list_emails", `{"account":"home"}`)
	assert.Contains(t, empty, `"messages":[]`)
}

func TestListEmails_IMAPAccount(t *testing.T) {
	f := newEmailFixture(t)
	f.seedGmail(t, "g1", f.recent, false, "")
	f.seedIMAP(t, 41, f.recent.Add(-time.Hour), "")
	f.seedIMAP(t, 42, f.recent, "")

	got := f.list(t, `{"account":"home"}`)
	assert.Equal(t, "home", got.Account)
	require.Len(t, got.Messages, 2)
	assert.Equal(t, "imap 42", got.Messages[0].Subject)
	assert.Equal(t, "7-42", got.Messages[0].ID)
	assert.Equal(t, "Friend <friend@example.com>", got.Messages[0].From)
	assert.Empty(t, got.Messages[0].ThreadID)

	byAddr := f.list(t, `{"account":"home@example.com"}`)
	assert.Len(t, byAddr.Messages, 2)
}

func TestListEmails_SinceLimitUnreadOnly(t *testing.T) {
	f := newEmailFixture(t)
	for i := range 250 {
		f.seedGmail(t, fmt.Sprintf("m%03d", i), f.recent.Add(-time.Duration(i)*time.Minute), i%2 == 0, "")
	}

	assert.Len(t, f.list(t, `{"account":"work"}`).Messages, 50, "default limit")
	assert.Len(t, f.list(t, `{"account":"work","limit":0}`).Messages, 50, "limit 0 → 50")
	assert.Len(t, f.list(t, `{"account":"work","limit":500}`).Messages, 200, "limit 500 → 200")
	assert.Len(t, f.list(t, `{"account":"work","limit":3}`).Messages, 3)

	since := f.recent.Add(-9 * time.Minute).Format(time.RFC3339)
	got := f.list(t, `{"account":"work","since":"`+since+`"}`)
	require.Len(t, got.Messages, 10, "since is inclusive")
	assert.Equal(t, "m009", got.Messages[9].ID)

	// A since in another offset means the same instant.
	sinceOffset := f.recent.Add(-9 * time.Minute).In(time.FixedZone("x", 3*3600)).Format(time.RFC3339)
	assert.Len(t, f.list(t, `{"account":"work","since":"`+sinceOffset+`"}`).Messages, 10)

	unread := f.list(t, `{"account":"work","since":"`+since+`","unread_only":true}`)
	require.Len(t, unread.Messages, 5)
	for _, m := range unread.Messages {
		assert.True(t, m.Unread)
	}

	_, err := f.reg.CallRead(context.Background(), "list_emails", json.RawMessage(`{"account":"work","since":"yesterday"}`), Binding{})
	var ve *ValidationError
	require.ErrorAs(t, err, &ve)
	assert.Contains(t, ve.Msg, "since")
}

func TestGetEmail_ClipsBodyAt32KiB(t *testing.T) {
	f := newEmailFixture(t)
	f.seedGmail(t, "big", f.recent, true, strings.Repeat("a", 40*1024))
	f.seedGmail(t, "small", f.recent, false, "short body")
	f.seedIMAP(t, 9, f.recent, "imap body")

	var big struct {
		Account   string   `json:"account"`
		ID        string   `json:"id"`
		To        []string `json:"to"`
		Cc        []string `json:"cc"`
		Body      string   `json:"body"`
		Truncated bool     `json:"truncated"`
		Subject   string   `json:"subject"`
	}
	require.NoError(t, json.Unmarshal([]byte(callReadString(t, f.reg, "get_email", `{"account":"work","id":"big"}`)), &big))
	assert.Equal(t, "big", big.ID)
	assert.Len(t, big.Body, 32*1024)
	assert.True(t, big.Truncated)
	assert.Equal(t, []string{"owner@example.com"}, big.To)
	assert.Equal(t, []string{"cc@example.com"}, big.Cc)
	assert.Equal(t, "subject big", big.Subject)

	var small struct {
		Body      string `json:"body"`
		Truncated bool   `json:"truncated"`
	}
	require.NoError(t, json.Unmarshal([]byte(callReadString(t, f.reg, "get_email", `{"account":"owner@example.com","id":"small"}`)), &small))
	assert.Equal(t, "short body", small.Body)
	assert.False(t, small.Truncated)

	var imapMsg struct {
		Body string   `json:"body"`
		Cc   []string `json:"cc"`
	}
	require.NoError(t, json.Unmarshal([]byte(callReadString(t, f.reg, "get_email", `{"account":"home","id":"7-9"}`)), &imapMsg))
	assert.Equal(t, "imap body", imapMsg.Body)
	assert.NotNil(t, imapMsg.Cc, "an empty recipient list is [] not null")

	// A multi-byte body is cut on a rune boundary, never mid-character.
	f.seedGmail(t, "cyr", f.recent, false, strings.Repeat("я", 20*1024))
	var cyr struct {
		Body      string `json:"body"`
		Truncated bool   `json:"truncated"`
	}
	require.NoError(t, json.Unmarshal([]byte(callReadString(t, f.reg, "get_email", `{"account":"work","id":"cyr"}`)), &cyr))
	assert.True(t, cyr.Truncated)
	assert.LessOrEqual(t, len(cyr.Body), 32*1024)
	assert.Equal(t, strings.Repeat("я", 16*1024), cyr.Body)

	for _, args := range []string{`{"account":"work","id":"missing"}`, `{"account":"home","id":"big"}`, `{"account":"home","id":"7-x"}`} {
		_, err := f.reg.CallRead(context.Background(), "get_email", json.RawMessage(args), Binding{})
		var ve *ValidationError
		require.ErrorAs(t, err, &ve, args)
	}
}

func TestEmailTools_NotOnDevSurface(t *testing.T) {
	for _, tool := range []*Tool{NewListEmails(), NewGetEmail()} {
		assert.Equal(t, AccessRead, tool.Access, tool.Name)
		assert.False(t, tool.VisibleOn("main"), tool.Name)
		assert.False(t, tool.VisibleOn(WorkbenchSurface), tool.Name)
		assert.True(t, tool.VisibleOn(AutomationSurface), tool.Name)
		for _, rt := range ReadTools() {
			assert.NotEqual(t, tool.Name, rt.Name, "dev-mode MCP never mounts %s (DEV-01)", tool.Name)
		}
	}
	assert.Equal(t, "automation", AutomationSurface)
	assert.Equal(t, "automation_run", AutomationContextType)
}
