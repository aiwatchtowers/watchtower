package automations

import (
	"context"
	"fmt"
	"reflect"
	"testing"

	"watchtower/internal/db"
)

// mailConnectedAt is when both fixture accounts were connected (created_at).
const mailConnectedAt = "2026-10-10T00:00:00Z"

// mailFixture seeds a Gmail account labelled "work" and an unlabelled IMAP
// mailbox, both connected at mailConnectedAt, plus one contentMarker message
// in the IMAP one.
func mailFixture(t *testing.T) (d *db.DB, gmailID, imapID int64) {
	t.Helper()
	d = openEventDB(t)
	gmailID, err := d.CreateGoogleAccount(db.GoogleAccount{Email: "owner@example.com", Label: "work", GmailEnabled: true})
	must(t, err)
	imapID, err = d.CreateEmailAccount(db.EmailAccount{Provider: "imap", EmailAddress: "home@example.com", Host: "imap.example.com", Security: "ssl", Folder: "INBOX"})
	must(t, err)
	_, err = d.Exec(`UPDATE email_accounts SET label = '', created_at = ? WHERE id = ?`, mailConnectedAt, imapID)
	must(t, err)
	_, err = d.Exec(`UPDATE google_accounts SET created_at = ? WHERE id = ?`, mailConnectedAt, gmailID)
	must(t, err)
	must(t, d.UpsertImapMessage(db.ImapMessage{AccountID: imapID, UID: 1, UIDValidity: 1, Subject: contentMarker, Snippet: contentMarker, BodyText: contentMarker}, "2026-10-01T00:00:00Z"))
	return d, gmailID, imapID
}

// mailStore stores one message per date the way a provider's syncer does:
// a Gmail id or an IMAP uid under uidvalidity, numbered from first.
func mailStore(t *testing.T, d *db.DB, provider string, accountID, uidValidity int64, first int, dates ...string) {
	t.Helper()
	for i, date := range dates {
		n := first + i
		if provider == "gmail" {
			must(t, d.UpsertGmailMessage(accountID, db.GmailMessage{ID: fmt.Sprintf("m%d", n), InternalDate: date, Subject: contentMarker}))
			continue
		}
		must(t, d.UpsertImapMessage(db.ImapMessage{AccountID: accountID, UID: int64(n), UIDValidity: uidValidity,
			InternalDate: date, Subject: contentMarker}, date))
	}
}

// markSynced sets a mail account's watermark, as a sync does.
func markSynced(t *testing.T, d *db.DB, provider string, accountID int64) {
	t.Helper()
	if provider == "gmail" {
		must(t, d.SetGmailAccountWatermark(accountID, 1700000000))
		return
	}
	must(t, d.SetImapWatermark(accountID, 100, 1))
}

// mailEvents runs a mail account's source around phase.
func mailEvents(t *testing.T, d *db.DB, provider string, accountID int64, phase func()) []Event {
	t.Helper()
	ctx := context.Background()
	src := MailSource(d, provider, accountID)
	if src.Type() != "gmail.new_messages" {
		t.Errorf("Type() = %q", src.Type())
	}
	diff, err := src.Before(ctx)
	must(t, err)
	phase()
	events, err := diff.After(ctx)
	must(t, err)
	return events
}

// eventCount is a mail phase's published count, 0 for no event.
func eventCount(t *testing.T, events []Event) any {
	t.Helper()
	switch len(events) {
	case 0:
		return 0
	case 1:
		return events[0].Fields["count"]
	}
	t.Fatalf("one account published %d events", len(events))
	return nil
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
		got, ok, err := mailEvent(d, c.provider, c.id, 2)
		if err != nil || !ok || !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: mailEvent = %+v, %v, %v; want %+v", c.provider, got, ok, err, c.want)
		}
	}
	if _, ok, err := mailEvent(d, "gmail", gmailID, 0); ok || err != nil {
		t.Errorf("count 0: ok=%v, err=%v; want no event", ok, err)
	}
	if _, _, err := mailEvent(d, "gmail", 99, 1); err == nil {
		t.Error("missing account: want an error")
	}
}

// A first sync capped to the oldest messages drains the backlog over later
// cycles: only mail dated after the account was connected is news, each
// message once.
func TestMailSource_CappedFirstSyncDrainPublishesOnlyNewerMail(t *testing.T) {
	d, gmailID, imapID := mailFixture(t)
	for provider, id := range map[string]int64{"gmail": gmailID, "imap": imapID} {
		cycles := []struct {
			dates []string
			want  any
		}{
			{[]string{"2026-10-04T08:00:00Z", "2026-10-05T08:00:00Z"}, 0}, // first sync
			{[]string{"2026-10-06T08:00:00Z", "2026-10-07T08:00:00Z"}, 0}, // backlog
			{[]string{"2026-10-08T08:00:00Z", "2026-10-11T08:00:00Z", "2026-10-12T08:00:00Z"}, 2},
			{nil, 0},
			{[]string{"2026-10-13T08:00:00Z"}, 1},
		}
		next := 10
		for i, c := range cycles {
			got := mailEvents(t, d, provider, id, func() {
				mailStore(t, d, provider, id, 1, next, c.dates...)
				markSynced(t, d, provider, id)
			})
			next += len(c.dates)
			if n := eventCount(t, got); n != c.want {
				t.Errorf("%s cycle %d: count %v, want %v", provider, i+1, n, c.want)
			}
		}
	}
}

// A UIDVALIDITY change makes the IMAP syncer store the known mail again under
// new uids: only the genuinely newer message is news.
func TestMailSource_UIDValidityResyncOfKnownMailPublishesNothing(t *testing.T) {
	d, _, imapID := mailFixture(t)
	known := []string{"2026-10-11T08:00:00Z", "2026-10-12T08:00:00Z"}
	mailStore(t, d, "imap", imapID, 1, 10, known...)
	markSynced(t, d, "imap", imapID)

	got := mailEvents(t, d, "imap", imapID, func() { mailStore(t, d, "imap", imapID, 2, 1, known...) })
	if len(got) != 0 {
		t.Errorf("re-synced known mail published %+v", got)
	}
	got = mailEvents(t, d, "imap", imapID, func() {
		mailStore(t, d, "imap", imapID, 3, 1, append(known, "2026-10-13T08:00:00Z")...)
	})
	if n := eventCount(t, got); n != 1 {
		t.Errorf("re-sync plus one new message: count %v, want 1", n)
	}
}

func TestMailSource_MissingAccountAndUnknownProvider(t *testing.T) {
	d, _, _ := mailFixture(t)
	if _, err := MailSource(d, "gmail", 99).Before(context.Background()); err != nil {
		t.Errorf("missing account reads as never synced: %v", err)
	}
	if _, err := MailSource(d, "pop3", 1).Before(context.Background()); err == nil {
		t.Error("unknown provider: want an error")
	}
}

// mailContentEvents builds mail events from the contentMarker fixtures for
// TestBus_EventsCarryNoContent.
func mailContentEvents(t *testing.T) []Event {
	d, gmailID, imapID := mailFixture(t)
	var out []Event
	for p, id := range map[string]int64{"gmail": gmailID, "imap": imapID} {
		markSynced(t, d, p, id)
		out = append(out, mailEvents(t, d, p, id, func() { mailStore(t, d, p, id, 1, 50, "2026-10-14T08:00:00Z") })...)
	}
	if len(out) != 2 {
		t.Fatalf("content fixtures published %d mail events, want 2", len(out))
	}
	return out
}
