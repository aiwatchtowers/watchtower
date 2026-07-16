package inbox

import (
	"context"
	"testing"
	"time"

	"watchtower/internal/db"
)

func TestDetectGmailReceivedVsCC(t *testing.T) {
	database := testDB(t)
	syncedAt := "2026-07-09T10:00:00Z"

	// m1: myEmail in To → email_received
	if err := database.UpsertGmailMessage(db.GmailMessage{
		ID: "m1", ThreadID: "t1", FromEmail: "a@x.com", Subject: "Direct",
		Snippet: "hello", ToJSON: `["me@x.com"]`, CcJSON: `[]`,
		InternalDate: "2026-07-09T09:00:00Z", Permalink: "p1",
	}, syncedAt); err != nil {
		t.Fatalf("seed m1: %v", err)
	}
	// m2: myEmail only in Cc → email_cc
	if err := database.UpsertGmailMessage(db.GmailMessage{
		ID: "m2", ThreadID: "t2", FromEmail: "b@x.com", Subject: "Copied",
		Snippet: "fyi", ToJSON: `["other@x.com"]`, CcJSON: `["me@x.com"]`,
		InternalDate: "2026-07-09T09:30:00Z", Permalink: "p2",
	}, syncedAt); err != nil {
		t.Fatalf("seed m2: %v", err)
	}
	// m3: myEmail nowhere → skipped
	if err := database.UpsertGmailMessage(db.GmailMessage{
		ID: "m3", ThreadID: "t3", FromEmail: "c@x.com", Subject: "None",
		ToJSON: `["x@x.com"]`, CcJSON: `[]`, InternalDate: "2026-07-09T09:40:00Z",
	}, syncedAt); err != nil {
		t.Fatalf("seed m3: %v", err)
	}

	since := time.Date(2026, 7, 9, 0, 0, 0, 0, time.UTC)
	n, err := DetectGmail(context.Background(), database, "me@x.com", since)
	if err != nil {
		t.Fatal(err)
	}
	if n != 2 {
		t.Fatalf("want 2 items, got %d", n)
	}

	received := queryInboxByTrigger(t, database, "email_received")
	if len(received) != 1 || received[0].ChannelID != "t1" {
		t.Errorf("want 1 email_received item for t1, got %+v", received)
	}
	if received[0].Snippet != "Direct — hello" {
		t.Errorf("m1 snippet = %q, want %q", received[0].Snippet, "Direct — hello")
	}

	cc := queryInboxByTrigger(t, database, "email_cc")
	if len(cc) != 1 || cc[0].ChannelID != "t2" {
		t.Errorf("want 1 email_cc item for t2, got %+v", cc)
	}

	// m3 shouldn't have created anything under any trigger.
	if len(queryInboxByTrigger(t, database, "email_received"))+len(queryInboxByTrigger(t, database, "email_cc")) != 2 {
		t.Errorf("unexpected extra items created")
	}

	// Idempotent: second run creates nothing.
	n2, err := DetectGmail(context.Background(), database, "me@x.com", since)
	if err != nil {
		t.Fatal(err)
	}
	if n2 != 0 {
		t.Fatalf("want 0 on re-run, got %d", n2)
	}
}
