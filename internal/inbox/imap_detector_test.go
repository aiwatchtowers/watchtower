package inbox

import (
	"context"
	"strconv"
	"testing"
	"time"

	"watchtower/internal/db"
)

func seedImapAccount(t *testing.T, database *db.DB, email, folder string) int64 {
	t.Helper()
	id, err := database.CreateEmailAccount(db.EmailAccount{
		Provider: "imap", EmailAddress: email, Host: "imap.example.com",
		Port: 993, Security: "ssl", Folder: folder,
	})
	if err != nil {
		t.Fatalf("seed email account: %v", err)
	}
	return id
}

func TestDetectImapAccountsReceivedVsCC(t *testing.T) {
	database := testDB(t)
	acctID := seedImapAccount(t, database, "me@x.com", "INBOX")
	syncedAt := "2026-07-09T10:00:00Z"

	// m1: account's address in To → email_received
	if err := database.UpsertImapMessage(db.ImapMessage{
		AccountID: acctID, UID: 1, FromEmail: "a@x.com", Subject: "Direct",
		Snippet: "hello", ToJSON: `["me@x.com"]`, CcJSON: `[]`,
		InternalDate: "2026-07-09T09:00:00Z",
	}, syncedAt); err != nil {
		t.Fatalf("seed m1: %v", err)
	}
	// m2: account's address only in Cc → email_cc
	if err := database.UpsertImapMessage(db.ImapMessage{
		AccountID: acctID, UID: 2, FromEmail: "b@x.com", Subject: "Copied",
		Snippet: "fyi", ToJSON: `["other@x.com"]`, CcJSON: `["me@x.com"]`,
		InternalDate: "2026-07-09T09:30:00Z",
	}, syncedAt); err != nil {
		t.Fatalf("seed m2: %v", err)
	}
	// m3: account's address nowhere → skipped
	if err := database.UpsertImapMessage(db.ImapMessage{
		AccountID: acctID, UID: 3, FromEmail: "c@x.com", Subject: "None",
		ToJSON: `["x@x.com"]`, CcJSON: `[]`, InternalDate: "2026-07-09T09:40:00Z",
	}, syncedAt); err != nil {
		t.Fatalf("seed m3: %v", err)
	}

	since := time.Date(2026, 7, 9, 0, 0, 0, 0, time.UTC)
	n, err := DetectImapAccounts(context.Background(), database, since)
	if err != nil {
		t.Fatal(err)
	}
	if n != 2 {
		t.Fatalf("want 2 items, got %d", n)
	}

	wantChannel := "imap:" + strconv.FormatInt(acctID, 10) + ":0:INBOX"

	received := queryInboxByTrigger(t, database, "email_received")
	if len(received) != 1 || received[0].ChannelID != wantChannel || received[0].MessageTS != "1" {
		t.Errorf("want 1 email_received item for uid 1, got %+v", received)
	}
	if received[0].Snippet != "Direct — hello" {
		t.Errorf("m1 snippet = %q, want %q", received[0].Snippet, "Direct — hello")
	}

	cc := queryInboxByTrigger(t, database, "email_cc")
	if len(cc) != 1 || cc[0].ChannelID != wantChannel || cc[0].MessageTS != "2" {
		t.Errorf("want 1 email_cc item for uid 2, got %+v", cc)
	}

	// Idempotent: second run creates nothing.
	n2, err := DetectImapAccounts(context.Background(), database, since)
	if err != nil {
		t.Fatal(err)
	}
	if n2 != 0 {
		t.Fatalf("want 0 on re-run, got %d", n2)
	}
}

func TestDetectImapAccountsMultipleAccountsDontCollide(t *testing.T) {
	database := testDB(t)
	acctA := seedImapAccount(t, database, "me@a.com", "INBOX")
	acctB := seedImapAccount(t, database, "me@b.com", "INBOX")
	syncedAt := "2026-07-09T10:00:00Z"

	// Same UID (1) in both accounts' own mailboxes — must not collide since
	// channel_id embeds the account ID.
	if err := database.UpsertImapMessage(db.ImapMessage{
		AccountID: acctA, UID: 1, FromEmail: "x@x.com", Subject: "A1",
		ToJSON: `["me@a.com"]`, CcJSON: `[]`, InternalDate: "2026-07-09T09:00:00Z",
	}, syncedAt); err != nil {
		t.Fatalf("seed acctA msg: %v", err)
	}
	if err := database.UpsertImapMessage(db.ImapMessage{
		AccountID: acctB, UID: 1, FromEmail: "y@y.com", Subject: "B1",
		ToJSON: `["me@b.com"]`, CcJSON: `[]`, InternalDate: "2026-07-09T09:00:00Z",
	}, syncedAt); err != nil {
		t.Fatalf("seed acctB msg: %v", err)
	}

	since := time.Date(2026, 7, 9, 0, 0, 0, 0, time.UTC)
	n, err := DetectImapAccounts(context.Background(), database, since)
	if err != nil {
		t.Fatal(err)
	}
	if n != 2 {
		t.Fatalf("want 2 items (one per account), got %d", n)
	}

	received := queryInboxByTrigger(t, database, "email_received")
	if len(received) != 2 {
		t.Fatalf("want 2 email_received items, got %+v", received)
	}
	channels := map[string]bool{}
	for _, r := range received {
		channels[r.ChannelID] = true
	}
	if !channels["imap:"+strconv.FormatInt(acctA, 10)+":0:INBOX"] || !channels["imap:"+strconv.FormatInt(acctB, 10)+":0:INBOX"] {
		t.Errorf("expected distinct per-account channel ids, got %+v", channels)
	}
}

// TestDetectImapAccountsUIDValidityResetDoesNotCollide covers fix #1
// (UIDVALIDITY reuse silently overwriting/suppressing messages): a UID
// reused after the server recreates the mailbox (a new uidvalidity epoch)
// must produce its own, independent inbox item rather than being treated as
// an already-seen duplicate of the pre-reset message at the same UID. This
// must fail against the pre-fix dedup key (channel_id without uidvalidity).
func TestDetectImapAccountsUIDValidityResetDoesNotCollide(t *testing.T) {
	database := testDB(t)
	acctID := seedImapAccount(t, database, "me@x.com", "INBOX")
	syncedAt := "2026-07-09T10:00:00Z"

	// Pre-reset message: uid=5 under uidvalidity=100.
	if err := database.UpsertImapMessage(db.ImapMessage{
		AccountID: acctID, UID: 5, UIDValidity: 100, FromEmail: "a@x.com", Subject: "Old",
		Snippet: "old body", ToJSON: `["me@x.com"]`, CcJSON: `[]`,
		InternalDate: "2026-07-09T09:00:00Z",
	}, syncedAt); err != nil {
		t.Fatalf("seed pre-reset message: %v", err)
	}
	// Post-reset message: same uid=5, but a new uidvalidity=200 — the server
	// recreated the mailbox and reused UID 5 for a completely different message.
	if err := database.UpsertImapMessage(db.ImapMessage{
		AccountID: acctID, UID: 5, UIDValidity: 200, FromEmail: "b@x.com", Subject: "New",
		Snippet: "new body", ToJSON: `["me@x.com"]`, CcJSON: `[]`,
		InternalDate: "2026-07-09T09:30:00Z",
	}, syncedAt); err != nil {
		t.Fatalf("seed post-reset message: %v", err)
	}

	// Both rows must persist independently — no overwrite despite sharing uid=5.
	stored, err := database.ImapMessagesSyncedAfter(acctID, "2000-01-01T00:00:00Z")
	if err != nil {
		t.Fatalf("query imap_messages: %v", err)
	}
	if len(stored) != 2 {
		t.Fatalf("want 2 stored imap_messages rows (one per uidvalidity epoch), got %d: %+v", len(stored), stored)
	}

	since := time.Date(2026, 7, 9, 0, 0, 0, 0, time.UTC)
	n, err := DetectImapAccounts(context.Background(), database, since)
	if err != nil {
		t.Fatal(err)
	}
	if n != 2 {
		t.Fatalf("want 2 independent inbox items (one per uidvalidity epoch), got %d", n)
	}

	received := queryInboxByTrigger(t, database, "email_received")
	if len(received) != 2 {
		t.Fatalf("want 2 email_received items, got %+v", received)
	}
	channels := map[string]bool{}
	for _, r := range received {
		channels[r.ChannelID] = true
	}
	wantOld := "imap:" + strconv.FormatInt(acctID, 10) + ":100:INBOX"
	wantNew := "imap:" + strconv.FormatInt(acctID, 10) + ":200:INBOX"
	if !channels[wantOld] || !channels[wantNew] {
		t.Errorf("expected distinct per-uidvalidity channel ids %q and %q, got %+v", wantOld, wantNew, channels)
	}
}
