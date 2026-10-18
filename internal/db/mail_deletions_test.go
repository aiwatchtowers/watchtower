package db

import (
	"testing"
)

// mailInboxItem stores an inbox item carrying a copy of a mail's text.
func mailInboxItem(t *testing.T, d *DB, channelID, messageTS string) int64 {
	t.Helper()
	id, err := d.CreateInboxItem(InboxItem{ChannelID: channelID, MessageTS: messageTS, SenderUserID: "x@example.com",
		TriggerType: "email_received", Snippet: "Subject — body", Context: "ctx", RawText: "raw"})
	if err != nil {
		t.Fatal(err)
	}
	return id
}

// mailInboxCopies returns an inbox item's snippet, context and raw_text joined.
func mailInboxCopies(t *testing.T, d *DB, id int64) string {
	t.Helper()
	var s string
	if err := d.QueryRow(`SELECT snippet || context || raw_text FROM inbox_items WHERE id = ?`, id).Scan(&s); err != nil {
		t.Fatal(err)
	}
	return s
}

func TestDeleteGmailMessages_BlanksInboxCopies(t *testing.T) {
	d := OpenTestDB(t)
	a, err := d.CreateGoogleAccount(GoogleAccount{Email: "a@example.com", Label: "A"})
	if err != nil {
		t.Fatal(err)
	}
	for _, m := range []GmailMessage{{ID: "m1", ThreadID: "t1"}, {ID: "m2", ThreadID: "t1"}} {
		if err := d.UpsertGmailMessage(a, m); err != nil {
			t.Fatal(err)
		}
	}
	gone := mailInboxItem(t, d, GmailChannelID(a, "t1"), "m1")
	kept := mailInboxItem(t, d, GmailChannelID(a, "t1"), "m2")
	otherAcct := mailInboxItem(t, d, GmailChannelID(a*10+1, "t1"), "m1")

	if n, err := d.DeleteGmailMessages(a, []string{"m1"}); err != nil || n != 1 {
		t.Fatalf("deleted %d, err %v; want 1", n, err)
	}
	if got := mailInboxCopies(t, d, gone); got != "" {
		t.Errorf("deleted mail's inbox copies = %q, want blank", got)
	}
	if got := mailInboxCopies(t, d, kept); got == "" {
		t.Error("kept mail's inbox copies were blanked")
	}
	if got := mailInboxCopies(t, d, otherAcct); got == "" {
		t.Error("another account's inbox copies were blanked")
	}
}

func TestDeleteImapMessages_BlanksInboxCopies(t *testing.T) {
	d := OpenTestDB(t)
	a, err := d.CreateEmailAccount(EmailAccount{Provider: "imap", EmailAddress: "a@example.com", Host: "h", Port: 1, Security: "none", Folder: "INBOX"})
	if err != nil {
		t.Fatal(err)
	}
	for _, uid := range []int64{1, 2} {
		if err := d.UpsertImapMessage(ImapMessage{AccountID: a, UID: uid, UIDValidity: 7}, "2026-01-01T00:00:00Z"); err != nil {
			t.Fatal(err)
		}
	}
	gone := mailInboxItem(t, d, ImapChannelPrefix(a, 7)+":INBOX", "1")
	kept := mailInboxItem(t, d, ImapChannelPrefix(a, 7)+":INBOX", "2")
	otherEpoch := mailInboxItem(t, d, ImapChannelPrefix(a, 8)+":INBOX", "1")

	if n, err := d.DeleteImapMessages(a, 7, []int64{1}); err != nil || n != 1 {
		t.Fatalf("deleted %d, err %v; want 1", n, err)
	}
	if got := mailInboxCopies(t, d, gone); got != "" {
		t.Errorf("deleted mail's inbox copies = %q, want blank", got)
	}
	if got := mailInboxCopies(t, d, kept); got == "" {
		t.Error("kept mail's inbox copies were blanked")
	}
	if got := mailInboxCopies(t, d, otherEpoch); got == "" {
		t.Error("another epoch's inbox copies were blanked")
	}
}

func TestDeleteImapMessagesOutsideUIDValidity_BlanksInboxCopies(t *testing.T) {
	d := OpenTestDB(t)
	a, err := d.CreateEmailAccount(EmailAccount{Provider: "imap", EmailAddress: "a@example.com", Host: "h", Port: 1, Security: "none", Folder: "INBOX"})
	if err != nil {
		t.Fatal(err)
	}
	if err := d.UpsertImapMessage(ImapMessage{AccountID: a, UID: 1, UIDValidity: 5}, "2026-01-01T00:00:00Z"); err != nil {
		t.Fatal(err)
	}
	stale := mailInboxItem(t, d, ImapChannelPrefix(a, 5)+":INBOX", "1")
	current := mailInboxItem(t, d, ImapChannelPrefix(a, 6)+":INBOX", "1")
	// Account a*10 (e.g. 10 for 1) starts with the same digits but is another account.
	otherAcct := mailInboxItem(t, d, ImapChannelPrefix(a*10, 5)+":INBOX", "1")

	if n, err := d.DeleteImapMessagesOutsideUIDValidity(a, 6); err != nil || n != 1 {
		t.Fatalf("deleted %d, err %v; want 1", n, err)
	}
	if got := mailInboxCopies(t, d, stale); got != "" {
		t.Errorf("stale epoch's inbox copies = %q, want blank", got)
	}
	if got := mailInboxCopies(t, d, current); got == "" {
		t.Error("current epoch's inbox copies were blanked")
	}
	if got := mailInboxCopies(t, d, otherAcct); got == "" {
		t.Error("another account's inbox copies were blanked")
	}
}
