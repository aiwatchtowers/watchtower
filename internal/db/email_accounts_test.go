package db

import "testing"

func TestDeleteImapMessagesOutsideUIDValidity_ScopesToAccount(t *testing.T) {
	d := OpenTestDB(t)
	a, err := d.CreateEmailAccount(EmailAccount{Provider: "imap", EmailAddress: "a@example.com", Host: "h", Port: 1, Security: "none", Folder: "INBOX"})
	if err != nil {
		t.Fatal(err)
	}
	b, err := d.CreateEmailAccount(EmailAccount{Provider: "imap", EmailAddress: "b@example.com", Host: "h", Port: 1, Security: "none", Folder: "INBOX"})
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range []struct{ acct, uid, v int64 }{{a, 1, 5}, {a, 2, 6}, {a, 3, 6}, {b, 1, 5}, {b, 2, 6}} {
		if err := d.UpsertImapMessage(ImapMessage{AccountID: r.acct, UID: r.uid, UIDValidity: r.v}, "2026-01-01T00:00:00Z"); err != nil {
			t.Fatal(err)
		}
	}
	n, err := d.DeleteImapMessagesOutsideUIDValidity(a, 6)
	if err != nil || n != 1 {
		t.Fatalf("deleted %d, err %v; want 1", n, err)
	}
	if got, _ := d.ImapStoredUIDs(a, 6); len(got) != 2 {
		t.Errorf("account a epoch 6 = %v", got)
	}
	if got, _ := d.ImapStoredUIDs(b, 5); len(got) != 1 {
		t.Errorf("account b epoch 5 touched: %v", got)
	}
}

func TestDeleteImapMessages_ChunkedAndScoped(t *testing.T) {
	d := OpenTestDB(t)
	a, err := d.CreateEmailAccount(EmailAccount{Provider: "imap", EmailAddress: "a@example.com", Host: "h", Port: 1, Security: "none", Folder: "INBOX"})
	if err != nil {
		t.Fatal(err)
	}
	var del []int64
	for uid := int64(1); uid <= 1200; uid++ {
		if err := d.UpsertImapMessage(ImapMessage{AccountID: a, UID: uid, UIDValidity: 7}, "2026-01-01T00:00:00Z"); err != nil {
			t.Fatal(err)
		}
		if uid <= 1100 {
			del = append(del, uid)
		}
	}
	n, err := d.DeleteImapMessages(a, 7, del)
	if err != nil || n != 1100 {
		t.Fatalf("deleted %d, err %v; want 1100", n, err)
	}
	if got, _ := d.ImapStoredUIDs(a, 7); len(got) != 100 {
		t.Errorf("left %d, want 100", len(got))
	}
	if n, err := d.DeleteImapMessages(a, 8, []int64{1201}); err != nil || n != 0 {
		t.Errorf("other epoch: %d %v", n, err)
	}
}
