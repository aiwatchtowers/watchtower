package db

import (
	"testing"
)

func TestAutomationEventSources_SlackReads(t *testing.T) {
	d := openTestDB(t)
	acct, err := d.CreateSlackAccount(SlackAccount{TeamDomain: "acme", Label: "work", CurrentUserID: "1:UOWNER"})
	if err != nil {
		t.Fatal(err)
	}
	if acct != 1 {
		t.Fatalf("account id %d, want 1", acct)
	}
	if err := d.UpsertChannel(Channel{ID: "1:C1", Name: "releases", Type: "public"}); err != nil {
		t.Fatal(err)
	}
	if err := d.UpdateSyncState("1:C1", SyncState{LastSyncedTS: "1700000000.000100", IsInitialSyncComplete: true}); err != nil {
		t.Fatal(err)
	}
	if err := d.UpdateSyncState("1:C2", SyncState{LastSyncedTS: ""}); err != nil {
		t.Fatal(err)
	}
	for _, m := range []Message{
		{ChannelID: "1:C1", TS: "1700000000.000100", UserID: "1:UA"},     // at the mark: not after
		{ChannelID: "1:C1", TS: "1700000001.000100", UserID: "1:UA"},     // counted
		{ChannelID: "1:C1", TS: "1700000002.000100", UserID: "1:UOWNER"}, // owner: excluded
		{ChannelID: "1:C1", TS: "1700000003.000100", UserID: "1:UA", IsDeleted: true},
		{ChannelID: "1:C1", TS: "1700000004.000100", UserID: ""}, // no user: counted
	} {
		if err := d.UpsertMessage(m); err != nil {
			t.Fatal(err)
		}
	}

	marks, err := d.SlackChannelSyncMarks()
	if err != nil {
		t.Fatal(err)
	}
	if got := marks["1:C1"]; got != (SlackSyncMark{LastSyncedTS: "1700000000.000100", InitialSyncComplete: true}) {
		t.Errorf("C1 mark = %+v", got)
	}
	if got, ok := marks["1:C2"]; !ok || got.InitialSyncComplete || got.LastSyncedTS != "" {
		t.Errorf("C2 mark = %+v, %v", got, ok)
	}

	n, err := d.CountSlackMessagesAfter("1:C1", "1700000000.000100", "1:UOWNER")
	if err != nil || n != 2 {
		t.Errorf("count = %d, %v; want 2", n, err)
	}
	n, err = d.CountSlackMessagesAfter("1:C1", "1700000000.000100", "")
	if err != nil || n != 3 {
		t.Errorf("count without owner = %d, %v; want 3", n, err)
	}

	label, owner, err := d.SlackEventLabels(acct)
	if err != nil || label != "work" || owner != "1:UOWNER" {
		t.Errorf("labels = %q, %q, %v", label, owner, err)
	}
	unlabelled, err := d.CreateSlackAccount(SlackAccount{TeamDomain: "acme-home"})
	if err != nil {
		t.Fatal(err)
	}
	label, owner, err = d.SlackEventLabels(unlabelled)
	if err != nil || label != "acme-home" || owner != "" {
		t.Errorf("fallback labels = %q, %q, %v", label, owner, err)
	}
	if _, _, err := d.SlackEventLabels(99); err == nil {
		t.Error("missing account: want an error")
	}
}

func TestAutomationEventSources_MailReads(t *testing.T) {
	d := openTestDB(t)
	g, err := d.CreateGoogleAccount(GoogleAccount{Email: "owner@example.com", Label: "work"})
	if err != nil {
		t.Fatal(err)
	}
	im, err := d.CreateEmailAccount(EmailAccount{Provider: "imap", EmailAddress: "owner@example.com", Host: "imap.example.com", Security: "ssl", Folder: "INBOX"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`UPDATE email_accounts SET label = '' WHERE id = ?`, im); err != nil {
		t.Fatal(err)
	}

	if label, err := d.MailEventLabel("gmail", g); err != nil || label != "work" {
		t.Errorf("gmail label = %q, %v", label, err)
	}
	if label, err := d.MailEventLabel("imap", im); err != nil || label != "owner@example.com" {
		t.Errorf("imap label = %q, %v", label, err)
	}
	if _, err := d.MailEventLabel("pop3", g); err == nil {
		t.Error("unknown provider: want an error")
	}
	if _, err := d.MailEventLabel("gmail", 99); err == nil {
		t.Error("missing account: want an error")
	}

	for _, p := range []string{"gmail", "imap"} {
		id := g
		if p == "imap" {
			id = im
		}
		if set, err := d.MailWatermarkSet(p, id); err != nil || set {
			t.Errorf("%s before sync: set=%v, %v", p, set, err)
		}
	}
	if err := d.SetGmailAccountWatermark(g, 1700000000); err != nil {
		t.Fatal(err)
	}
	if err := d.SetImapWatermark(im, 42, 7); err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{"gmail", "imap"} {
		id := g
		if p == "imap" {
			id = im
		}
		if set, err := d.MailWatermarkSet(p, id); err != nil || !set {
			t.Errorf("%s after sync: set=%v, %v", p, set, err)
		}
	}
	if _, err := d.MailWatermarkSet("pop3", g); err == nil {
		t.Error("unknown provider: want an error")
	}
}
