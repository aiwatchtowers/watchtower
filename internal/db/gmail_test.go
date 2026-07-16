package db

import "testing"

func TestGmailUpsertAndQuery(t *testing.T) {
	database := openTestDB(t)
	m := GmailMessage{
		ID: "msg1", ThreadID: "thr1", FromEmail: "a@x.com", FromName: "A",
		ToJSON: `["me@x.com"]`, CcJSON: `[]`, Subject: "Hi", Snippet: "preview",
		BodyText: "full body", InternalDate: "2026-07-09T10:00:00Z",
		LabelsJSON: `["INBOX","UNREAD"]`, IsUnread: true,
		Permalink: "https://mail.google.com/#inbox/msg1",
	}
	if err := database.UpsertGmailMessage(m, "2026-07-09T10:00:01Z"); err != nil {
		t.Fatalf("upsert: %v", err)
	}
	// upsert again (idempotent update)
	m.Subject = "Hi again"
	if err := database.UpsertGmailMessage(m, "2026-07-09T10:00:02Z"); err != nil {
		t.Fatalf("re-upsert: %v", err)
	}
	got, err := database.GmailMessagesSyncedAfter("2026-07-09T00:00:00Z")
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	if len(got) != 1 || got[0].Subject != "Hi again" || !got[0].IsUnread {
		t.Fatalf("unexpected rows: %+v", got)
	}
}

func TestGmailWatermark(t *testing.T) {
	database := openTestDB(t)
	seedWorkspace(t, database) // SetGmailLastInternalDate targets the workspace row; see situations_test.go
	if err := database.SetGmailLastInternalDate(1720519200); err != nil {
		t.Fatalf("set: %v", err)
	}
	got, err := database.GetGmailLastInternalDate()
	if err != nil || got != 1720519200 {
		t.Fatalf("got %v err %v", got, err)
	}
}

func TestGetGmailBodyByID(t *testing.T) {
	database := openTestDB(t)
	m := GmailMessage{
		ID: "msg1", ThreadID: "thr1", FromEmail: "a@x.com", FromName: "A",
		ToJSON: `["me@x.com"]`, CcJSON: `[]`, Subject: "Hi", Snippet: "preview",
		BodyText: "full email body text", InternalDate: "2026-07-09T10:00:00Z",
		LabelsJSON: `["INBOX"]`,
	}
	if err := database.UpsertGmailMessage(m, "2026-07-09T10:00:01Z"); err != nil {
		t.Fatalf("upsert: %v", err)
	}

	got, err := database.GetGmailBodyByID("msg1")
	if err != nil || got != "full email body text" {
		t.Fatalf("got %q err %v", got, err)
	}

	got, err = database.GetGmailBodyByID("does-not-exist")
	if err != nil || got != "" {
		t.Fatalf("missing row: got %q err %v, want (\"\", nil)", got, err)
	}
}

func TestGmailAuthState(t *testing.T) {
	database := openTestDB(t)
	if err := database.SetGmailAuthState("revoked", "invalid_grant"); err != nil {
		t.Fatalf("set: %v", err)
	}
	s, err := database.GetGmailAuthState()
	if err != nil || s.Status != "revoked" {
		t.Fatalf("got %+v err %v", s, err)
	}
}
