package imap

import (
	"bytes"
	"net"
	"strconv"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	goimap "github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapserver"
	"github.com/emersion/go-imap/v2/imapserver/imapmemserver"
)

const (
	testUsername = "test-user"
	testPassword = "test-password"
)

// literalBuf adapts a []byte into an imap.LiteralReader for test message seeding.
type literalBuf struct {
	*bytes.Reader
}

func (l literalBuf) Size() int64 { return l.Reader.Size() }

func newLiteral(b []byte) literalBuf {
	return literalBuf{bytes.NewReader(b)}
}

// testServer starts a plain (non-TLS) in-process IMAP server with one user
// and an INBOX mailbox — mirrors the setup in go-imap's own
// imapclient/client_test.go, minus TLS (our tests use AccountConfig.Security
// = SecurityNone, so no certs are needed).
type testServer struct {
	addr string
	user *imapmemserver.User
	srv  *imapserver.Server
	ln   net.Listener
}

func startTestServer(t *testing.T) *testServer {
	t.Helper()
	memServer := imapmemserver.New()
	user := imapmemserver.NewUser(testUsername, testPassword)
	if err := user.Create("INBOX", nil); err != nil {
		t.Fatalf("create INBOX: %v", err)
	}
	memServer.AddUser(user)

	srv := imapserver.New(&imapserver.Options{
		NewSession: func(conn *imapserver.Conn) (imapserver.Session, *imapserver.GreetingData, error) {
			return memServer.NewSession(), nil, nil
		},
		InsecureAuth: true,
		Caps: goimap.CapSet{
			goimap.CapIMAP4rev1: {},
			goimap.CapIMAP4rev2: {},
		},
	})

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	go func() { _ = srv.Serve(ln) }()
	t.Cleanup(func() {
		_ = srv.Close()
		_ = ln.Close()
	})

	return &testServer{addr: ln.Addr().String(), user: user, srv: srv, ln: ln}
}

// seedMessage appends a raw RFC822 message to INBOX, returning its assigned
// UID. The server stamps INTERNALDATE as now, regardless of the message's own
// Date: header — use seedMessageAt to simulate an older arrival for
// SINCE-search tests.
func (ts *testServer) seedMessage(t *testing.T, raw string) uint32 {
	t.Helper()
	return ts.seedMessageAt(t, raw, time.Now())
}

// seedMessageAt appends a raw message with an explicit INTERNALDATE — IMAP's
// SINCE search criteria matches INTERNALDATE (server receipt time), not the
// message's own Date: header, so backfill-window tests need this to
// simulate old mail.
func (ts *testServer) seedMessageAt(t *testing.T, raw string, at time.Time) uint32 {
	t.Helper()
	data, err := ts.user.Append("INBOX", newLiteral([]byte(raw)), &goimap.AppendOptions{Time: at})
	if err != nil {
		t.Fatalf("append message: %v", err)
	}
	return uint32(data.UID)
}

func (ts *testServer) hostPort(t *testing.T) (string, int) {
	t.Helper()
	host, portStr, err := net.SplitHostPort(ts.addr)
	if err != nil {
		t.Fatalf("split addr: %v", err)
	}
	port, err := strconv.Atoi(portStr)
	if err != nil {
		t.Fatalf("parse port: %v", err)
	}
	return host, port
}

const simpleRawMessage = `From: Alice <alice@example.com>
To: me@example.com
Subject: Hello
Date: Mon, 09 Jul 2026 09:00:00 +0000
Content-Type: text/plain; charset=utf-8

This is the body.
`

func TestDialAndFetchSince(t *testing.T) {
	ts := startTestServer(t)
	ts.seedMessage(t, simpleRawMessage)
	host, port := ts.hostPort(t)

	client, uidValidity, err := Dial(AccountConfig{Host: host, Port: port, Security: SecurityNone, Folder: "INBOX"},
		PasswordAuth{Username: testUsername, Password: testPassword})
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	defer func() { _ = client.Close() }()
	if uidValidity == 0 {
		t.Errorf("want non-zero uidValidity")
	}

	uids, err := client.SearchSince(time.Now().AddDate(0, 0, -7))
	if err != nil {
		t.Fatalf("SearchSince: %v", err)
	}
	if len(uids) != 1 {
		t.Fatalf("want 1 uid, got %d", len(uids))
	}
	msgs, err := client.FetchUIDs(uids)
	if err != nil {
		t.Fatalf("FetchUIDs: %v", err)
	}
	if len(msgs) != 1 {
		t.Fatalf("want 1 message, got %d", len(msgs))
	}
	m := msgs[0]
	if m.Subject != "Hello" {
		t.Errorf("Subject = %q, want %q", m.Subject, "Hello")
	}
	if m.FromEmail != "alice@example.com" {
		t.Errorf("FromEmail = %q, want %q", m.FromEmail, "alice@example.com")
	}
	if len(m.To) != 1 || m.To[0] != "me@example.com" {
		t.Errorf("To = %v, want [me@example.com]", m.To)
	}
	if m.BodyText != "This is the body.\n" {
		t.Errorf("BodyText = %q", m.BodyText)
	}
	if !m.IsUnread {
		t.Errorf("want IsUnread=true for a freshly appended message")
	}
}

func TestSearchNewSinceOnlyReturnsNewerUIDs(t *testing.T) {
	ts := startTestServer(t)
	firstUID := ts.seedMessage(t, simpleRawMessage)
	secondUID := ts.seedMessage(t, `From: Bob <bob@example.com>
To: me@example.com
Subject: Second
Date: Mon, 09 Jul 2026 10:00:00 +0000
Content-Type: text/plain; charset=utf-8

Second body.
`)
	host, port := ts.hostPort(t)

	client, _, err := Dial(AccountConfig{Host: host, Port: port, Security: SecurityNone, Folder: "INBOX"},
		PasswordAuth{Username: testUsername, Password: testPassword})
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	defer func() { _ = client.Close() }()

	uids, err := client.SearchNewSince(firstUID)
	if err != nil {
		t.Fatalf("SearchNewSince: %v", err)
	}
	if len(uids) != 1 || uids[0] != secondUID {
		t.Fatalf("want [%d], got %v", secondUID, uids)
	}

	msgs, err := client.FetchUIDs(uids)
	if err != nil {
		t.Fatalf("FetchUIDs: %v", err)
	}
	if len(msgs) != 1 {
		t.Fatalf("want 1 message newer than first UID, got %d", len(msgs))
	}
	if msgs[0].Subject != "Second" {
		t.Errorf("Subject = %q, want %q", msgs[0].Subject, "Second")
	}
}

// TestFetchUIDsEmptyIsNoop covers the discard side of the two-phase shape
// (fix #7): FetchUIDs on an empty slice must not issue any FETCH at all,
// matching the "discarded tail is never fetched" contract Syncer.Sync relies
// on when SearchNewSince/SearchSince's result is capped down to nothing new.
func TestFetchUIDsEmptyIsNoop(t *testing.T) {
	ts := startTestServer(t)
	ts.seedMessage(t, simpleRawMessage)
	host, port := ts.hostPort(t)

	client, _, err := Dial(AccountConfig{Host: host, Port: port, Security: SecurityNone, Folder: "INBOX"},
		PasswordAuth{Username: testUsername, Password: testPassword})
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	defer func() { _ = client.Close() }()

	msgs, err := client.FetchUIDs(nil)
	if err != nil {
		t.Fatalf("FetchUIDs(nil): %v", err)
	}
	if msgs != nil {
		t.Fatalf("want nil messages for an empty UID list, got %v", msgs)
	}
}

// TestMessageFromBufferSnippetDoesNotSplitRune is an end-to-end check that
// messageFromBuffer's Snippet is always valid UTF-8 even when snippetLen
// lands in the middle of a multibyte rune in the real fetched message body —
// a raw m.BodyText[:snippetLen] byte slice (the pre-fix code) would corrupt
// it; truncateUTF8 backs off to the last valid rune boundary instead.
func TestMessageFromBufferSnippetDoesNotSplitRune(t *testing.T) {
	ts := startTestServer(t)
	// "€" is 3 bytes/rune; 100 of them = 300 bytes, and snippetLen=200 lands
	// strictly between the rune boundaries at 198 and 201 — a raw [:200]
	// slice cuts the 67th rune in half.
	body := strings.Repeat("€", 100)
	raw := "From: Sender <sender@example.com>\r\nTo: me@example.com\r\nSubject: Multibyte\r\n" +
		"Content-Type: text/plain; charset=utf-8\r\n\r\n" + body + "\r\n"
	ts.seedMessage(t, raw)
	host, port := ts.hostPort(t)

	client, _, err := Dial(AccountConfig{Host: host, Port: port, Security: SecurityNone, Folder: "INBOX"},
		PasswordAuth{Username: testUsername, Password: testPassword})
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	defer func() { _ = client.Close() }()

	uids, err := client.SearchSince(time.Now().AddDate(0, 0, -7))
	if err != nil {
		t.Fatalf("SearchSince: %v", err)
	}
	msgs, err := client.FetchUIDs(uids)
	if err != nil {
		t.Fatalf("FetchUIDs: %v", err)
	}
	if len(msgs) != 1 {
		t.Fatalf("want 1 message, got %d", len(msgs))
	}

	if !utf8.ValidString(msgs[0].Snippet) {
		t.Fatalf("Snippet = %q is not valid UTF-8", msgs[0].Snippet)
	}
	want := truncateUTF8(msgs[0].BodyText, snippetLen)
	if msgs[0].Snippet != want {
		t.Fatalf("Snippet = %q, want %q (truncateUTF8, not a raw byte slice)", msgs[0].Snippet, want)
	}
}

func TestDialWrongPasswordFails(t *testing.T) {
	ts := startTestServer(t)
	host, port := ts.hostPort(t)

	_, _, err := Dial(AccountConfig{Host: host, Port: port, Security: SecurityNone, Folder: "INBOX"},
		PasswordAuth{Username: testUsername, Password: "wrong"})
	if err == nil {
		t.Fatal("want error for wrong password, got nil")
	}
}
