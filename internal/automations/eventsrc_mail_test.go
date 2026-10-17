package automations

import (
	"reflect"
	"testing"

	"watchtower/internal/db"
)

// mailFixture seeds a Gmail account labelled "work" and an unlabelled IMAP
// mailbox, plus one contentMarker message in each.
func mailFixture(t *testing.T) (d *db.DB, gmailID, imapID int64) {
	t.Helper()
	d = openEventDB(t)
	gmailID, err := d.CreateGoogleAccount(db.GoogleAccount{Email: "owner@example.com", Label: "work", GmailEnabled: true})
	must(t, err)
	imapID, err = d.CreateEmailAccount(db.EmailAccount{Provider: "imap", EmailAddress: "home@example.com", Host: "imap.example.com", Security: "ssl", Folder: "INBOX"})
	must(t, err)
	_, err = d.Exec(`UPDATE email_accounts SET label = '' WHERE id = ?`, imapID)
	must(t, err)
	must(t, d.UpsertImapMessage(db.ImapMessage{AccountID: imapID, UID: 1, UIDValidity: 1, Subject: contentMarker, Snippet: contentMarker, BodyText: contentMarker}, "2026-10-01T00:00:00Z"))
	return d, gmailID, imapID
}

func TestMailEvents_LabelFallbackAndProvider(t *testing.T) {
	d, gmailID, imapID := mailFixture(t)
	cases := []struct {
		provider string
		id       int64
		want     Event
	}{
		{"gmail", gmailID, Event{Type: "gmail.new_messages", Fields: map[string]any{"account": "work", "provider": "gmail", "count": 2}}},
		{"imap", imapID, Event{Type: "gmail.new_messages", Fields: map[string]any{"account": "home@example.com", "provider": "imap", "count": 2}}},
	}
	for _, c := range cases {
		got, ok, err := MailEvent(d, c.provider, c.id, 2)
		if err != nil || !ok || !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: MailEvent = %+v, %v, %v; want %+v", c.provider, got, ok, err, c.want)
		}
	}
	if _, ok, err := MailEvent(d, "gmail", gmailID, 0); ok || err != nil {
		t.Errorf("count 0: ok=%v, err=%v; want no event", ok, err)
	}
	if _, _, err := MailEvent(d, "gmail", 99, 1); err == nil {
		t.Error("missing account: want an error")
	}
}

func TestMailEvents_InitialBackfillPublishesNothing(t *testing.T) {
	d, gmailID, imapID := mailFixture(t)
	// The daemon reads MailWatermarkSet before the syncer runs: 0 means the
	// phase is the initial backfill, so it publishes nothing.
	for _, c := range []struct {
		provider string
		id       int64
	}{{"gmail", gmailID}, {"imap", imapID}} {
		set, err := d.MailWatermarkSet(c.provider, c.id)
		if err != nil || set {
			t.Errorf("%s: watermark set=%v, %v before the first sync", c.provider, set, err)
		}
	}
	must(t, d.SetGmailAccountWatermark(gmailID, 1700000000))
	must(t, d.SetImapWatermark(imapID, 1, 1))
	for _, c := range []struct {
		provider string
		id       int64
	}{{"gmail", gmailID}, {"imap", imapID}} {
		set, err := d.MailWatermarkSet(c.provider, c.id)
		if err != nil || !set {
			t.Errorf("%s: watermark set=%v, %v after a sync", c.provider, set, err)
		}
	}
}

// mailContentEvents builds mail events from the contentMarker fixtures for
// TestBus_EventsCarryNoContent.
func mailContentEvents(t *testing.T) []Event {
	d, gmailID, imapID := mailFixture(t)
	var out []Event
	for p, id := range map[string]int64{"gmail": gmailID, "imap": imapID} {
		e, ok, err := MailEvent(d, p, id, 1)
		if err != nil || !ok {
			t.Fatalf("%s: MailEvent: %v, %v", p, ok, err)
		}
		out = append(out, e)
	}
	return out
}
