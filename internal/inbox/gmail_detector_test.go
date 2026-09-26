package inbox

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"watchtower/internal/db"
)

func TestDetectGmailAccounts_ReceivedVsCC(t *testing.T) {
	database := testDB(t)
	syncedAt := "2026-07-09T10:00:00Z"

	acctID, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "me@x.com", Label: "Me", GmailEnabled: true})
	if err != nil {
		t.Fatalf("seed google account: %v", err)
	}

	// m1: myEmail in To → email_received
	if err := database.UpsertGmailMessage(acctID, db.GmailMessage{
		ID: "m1", ThreadID: "t1", FromEmail: "a@x.com", Subject: "Direct",
		Snippet: "hello", ToJSON: `["me@x.com"]`, CcJSON: `[]`,
		InternalDate: "2026-07-09T09:00:00Z", Permalink: "p1", SyncedAt: syncedAt,
	}); err != nil {
		t.Fatalf("seed m1: %v", err)
	}
	// m2: myEmail only in Cc → email_cc
	if err := database.UpsertGmailMessage(acctID, db.GmailMessage{
		ID: "m2", ThreadID: "t2", FromEmail: "b@x.com", Subject: "Copied",
		Snippet: "fyi", ToJSON: `["other@x.com"]`, CcJSON: `["me@x.com"]`,
		InternalDate: "2026-07-09T09:30:00Z", Permalink: "p2", SyncedAt: syncedAt,
	}); err != nil {
		t.Fatalf("seed m2: %v", err)
	}
	// m3: myEmail nowhere → skipped
	if err := database.UpsertGmailMessage(acctID, db.GmailMessage{
		ID: "m3", ThreadID: "t3", FromEmail: "c@x.com", Subject: "None",
		ToJSON: `["x@x.com"]`, CcJSON: `[]`, InternalDate: "2026-07-09T09:40:00Z", SyncedAt: syncedAt,
	}); err != nil {
		t.Fatalf("seed m3: %v", err)
	}

	since := time.Date(2026, 7, 9, 0, 0, 0, 0, time.UTC)
	n, err := DetectGmailAccounts(context.Background(), database, since)
	if err != nil {
		t.Fatal(err)
	}
	if n != 2 {
		t.Fatalf("want 2 items, got %d", n)
	}

	received := queryInboxByTrigger(t, database, "email_received")
	if len(received) != 1 || received[0].ChannelID != fmt.Sprintf("gmail:%d:t1", acctID) {
		t.Errorf("want 1 email_received item for gmail:%d:t1, got %+v", acctID, received)
	}
	if received[0].Snippet != "Direct — hello" {
		t.Errorf("m1 snippet = %q, want %q", received[0].Snippet, "Direct — hello")
	}

	cc := queryInboxByTrigger(t, database, "email_cc")
	if len(cc) != 1 || cc[0].ChannelID != fmt.Sprintf("gmail:%d:t2", acctID) {
		t.Errorf("want 1 email_cc item for gmail:%d:t2, got %+v", acctID, cc)
	}

	// m3 shouldn't have created anything under any trigger.
	if len(queryInboxByTrigger(t, database, "email_received"))+len(queryInboxByTrigger(t, database, "email_cc")) != 2 {
		t.Errorf("unexpected extra items created")
	}

	// Idempotent: second run creates nothing.
	n2, err := DetectGmailAccounts(context.Background(), database, since)
	if err != nil {
		t.Fatal(err)
	}
	if n2 != 0 {
		t.Fatalf("want 0 on re-run, got %d", n2)
	}
}

// TestDetectGmailAccounts_PerAccountScoping seeds two google accounts
// (a@x.com / b@x.com) and asserts: matching is per source account's own
// email (a message To a@x.com sitting in account B's mailbox still mints
// from B, keyed on B's channel_id), and own-message suppression is scoped
// per account (a message FROM a@x.com in A's mailbox mints nothing, but the
// same FromEmail in B's mailbox is just an ordinary sender).
func TestDetectGmailAccounts_PerAccountScoping(t *testing.T) {
	database := testDB(t)
	syncedAt := "2026-07-09T10:00:00Z"

	acctA, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "a@x.com", Label: "A", GmailEnabled: true})
	if err != nil {
		t.Fatalf("seed account A: %v", err)
	}
	acctB, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "b@x.com", Label: "B", GmailEnabled: true})
	if err != nil {
		t.Fatalf("seed account B: %v", err)
	}

	// In account A's own mailbox: a message FROM a@x.com (A's own address)
	// must mint nothing even though it's also To a@x.com — own-message
	// suppression.
	if err := database.UpsertGmailMessage(acctA, db.GmailMessage{
		ID: "ma1", ThreadID: "ta1", FromEmail: "a@x.com", Subject: "Self",
		ToJSON: `["a@x.com"]`, CcJSON: `[]`, InternalDate: "2026-07-09T09:00:00Z", SyncedAt: syncedAt,
	}); err != nil {
		t.Fatalf("seed ma1: %v", err)
	}

	// In account B's mailbox: a message To a@x.com (NOT b@x.com) — should
	// NOT mint from B, since matching is per source account's own email.
	if err := database.UpsertGmailMessage(acctB, db.GmailMessage{
		ID: "mb1", ThreadID: "tb1", FromEmail: "c@x.com", Subject: "Wrong recipient",
		ToJSON: `["a@x.com"]`, CcJSON: `[]`, InternalDate: "2026-07-09T09:10:00Z", SyncedAt: syncedAt,
	}); err != nil {
		t.Fatalf("seed mb1: %v", err)
	}

	// In account B's mailbox: a message FROM a@x.com (an ordinary external
	// sender from B's perspective) To b@x.com — must mint from B, since
	// suppression only applies to the source account's own address.
	if err := database.UpsertGmailMessage(acctB, db.GmailMessage{
		ID: "mb2", ThreadID: "tb2", FromEmail: "a@x.com", Subject: "From A to B",
		ToJSON: `["b@x.com"]`, CcJSON: `[]`, InternalDate: "2026-07-09T09:20:00Z", SyncedAt: syncedAt,
	}); err != nil {
		t.Fatalf("seed mb2: %v", err)
	}

	since := time.Date(2026, 7, 9, 0, 0, 0, 0, time.UTC)
	n, err := DetectGmailAccounts(context.Background(), database, since)
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("want 1 item (only mb2), got %d", n)
	}

	received := queryInboxByTrigger(t, database, "email_received")
	if len(received) != 1 || received[0].ChannelID != fmt.Sprintf("gmail:%d:tb2", acctB) {
		t.Fatalf("want 1 email_received item for gmail:%d:tb2, got %+v", acctB, received)
	}
}

// TestDetectGmailAccounts_GmailEnabledWithEmptyEmailReturnsError covers the
// case where the account's email hasn't resolved yet (the profile lookup
// hasn't completed) but Gmail is enabled and messages are already syncing:
// this must error, naming the account, rather than skip cleanly — a clean
// skip would let the inbox watermark advance (INBOX-09 only freezes on a
// detector error) over mail that was never actually examined.
func TestDetectGmailAccounts_GmailEnabledWithEmptyEmailReturnsError(t *testing.T) {
	database := testDB(t)

	acctID, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "", Label: "Pending", GmailEnabled: true})
	if err != nil {
		t.Fatalf("seed pending account: %v", err)
	}

	since := time.Date(2026, 7, 9, 0, 0, 0, 0, time.UTC)
	_, err = DetectGmailAccounts(context.Background(), database, since)
	if err == nil {
		t.Fatal("want error for gmail-enabled account with unresolved email, got nil")
	}
	if !strings.Contains(err.Error(), fmt.Sprintf("account %d", acctID)) {
		t.Errorf("error %q does not name account %d", err.Error(), acctID)
	}
}

// TestDetectGmailAccounts_GmailDisabledAccountSkippedCleanly covers the
// distinct degenerate case: an account with Gmail disabled must be skipped
// with no error regardless of whether its email is resolved yet, since
// there's nothing unexamined to worry about — the account isn't syncing mail
// at all.
func TestDetectGmailAccounts_GmailDisabledAccountSkippedCleanly(t *testing.T) {
	database := testDB(t)

	if _, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "", Label: "Disabled", GmailEnabled: false}); err != nil {
		t.Fatalf("seed disabled account: %v", err)
	}

	since := time.Date(2026, 7, 9, 0, 0, 0, 0, time.UTC)
	n, err := DetectGmailAccounts(context.Background(), database, since)
	if err != nil {
		t.Fatalf("want clean skip for gmail-disabled account, got error: %v", err)
	}
	if n != 0 {
		t.Fatalf("want 0 items, got %d", n)
	}
}
