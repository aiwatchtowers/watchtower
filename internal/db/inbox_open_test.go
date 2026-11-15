package db

import (
	"context"
	"fmt"
	"slices"
	"testing"
	"time"
)

// openItemsFixture is the open-items fixture the Desktop's InboxRefState
// tests read too.
const openItemsFixture = "../inbox/testdata/open_items.json"

func openIDs(items []OpenInboxItem) []int64 {
	ids := make([]int64, 0, len(items))
	for _, it := range items {
		ids = append(ids, int64(it.ID))
	}
	return ids
}

// The Go twin of HomeFeedQueries.openMessageClause agrees with the shared
// fixture: pending actionable feed-trigger rows, a snooze already past, a
// live Jira issue; not snoozed ahead, resolved, dismissed, ambient,
// archived, a deleted or unknown Jira issue, a non-feed trigger. Newest
// first by MAX(created_at, mentioned_at), then id.
func TestOpenInboxItems_SharedFixture(t *testing.T) {
	d := openTestDB(t)
	fx := SeedTestOpenItemsFixture(t, d, openItemsFixture)
	got, err := d.OpenInboxItems(context.Background(), fx.Now, 200)
	if err != nil {
		t.Fatal(err)
	}
	if ids := openIDs(got); !slices.Equal(ids, fx.OpenIDs) {
		t.Fatalf("open ids = %v, want %v", ids, fx.OpenIDs)
	}
	byID := map[int]OpenInboxItem{}
	for _, it := range got {
		byID[it.ID] = it
	}
	if it := byID[1]; it.SenderName != "Colleague A" || it.ChannelName != "general" || it.At != "2026-11-01T10:00:00Z" {
		t.Errorf("item 1 = sender %q channel %q at %q", it.SenderName, it.ChannelName, it.At)
	}
	if it := byID[17]; it.At != "2026-11-01T11:30:00Z" || it.Mentions == "[]" {
		t.Errorf("folded item 17 = at %q mentions %q; want its mentioned_at and its list", it.At, it.Mentions)
	}
	if it := byID[10]; it.SenderName != "" || it.ChannelName != "" {
		t.Errorf("Jira item 10 = sender %q channel %q; want none", it.SenderName, it.ChannelName)
	}
}

// A snooze ends at its instant: the item is open from snooze_until on.
func TestOpenInboxItems_SnoozeEndsAtItsInstant(t *testing.T) {
	d := openTestDB(t)
	fx := SeedTestOpenItemsFixture(t, d, openItemsFixture)
	got, err := d.OpenInboxItems(context.Background(), time.Date(2026, 11, 1, 18, 0, 0, 0, time.UTC), 200)
	if err != nil {
		t.Fatal(err)
	}
	if ids := openIDs(got); !slices.Contains(ids, 4) || len(ids) != len(fx.OpenIDs)+1 {
		t.Errorf("open ids at the snooze's end = %v; want the fixture's plus 4", ids)
	}
}

// The limit caps the rows, keeping the newest.
func TestOpenInboxItems_Limit(t *testing.T) {
	d := openTestDB(t)
	now := time.Date(2026, 11, 1, 12, 0, 0, 0, time.UTC)
	for _, n := range []int{0, 200, 201} {
		t.Run(fmt.Sprint(n), func(t *testing.T) {
			if _, err := d.Exec(`DELETE FROM inbox_items`); err != nil {
				t.Fatal(err)
			}
			for i := 1; i <= n; i++ {
				at := now.Add(-time.Duration(i) * time.Minute).Format(time.RFC3339)
				if _, err := d.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, created_at)
					VALUES ('C001', ?, 'U001', 'mention', ?)`, fmt.Sprintf("1000.%04d", i), at); err != nil {
					t.Fatal(err)
				}
			}
			got, err := d.OpenInboxItems(context.Background(), now, 200)
			if err != nil {
				t.Fatal(err)
			}
			if want := min(n, 200); len(got) != want {
				t.Fatalf("%d items read, want %d", len(got), want)
			}
			if n > 0 && got[0].MessageTS != "1000.0001" {
				t.Errorf("first = %s, want the newest", got[0].MessageTS)
			}
		})
	}
}

// A failed read is an error, never an empty list.
func TestOpenInboxItems_ReadErrorIsAnError(t *testing.T) {
	d := openTestDB(t)
	if _, err := d.Exec(`ALTER TABLE inbox_items RENAME TO inbox_items_gone`); err != nil {
		t.Fatal(err)
	}
	if got, err := d.OpenInboxItems(context.Background(), time.Now(), 200); err == nil {
		t.Fatalf("OpenInboxItems = %v, nil; want an error", got)
	}
}

// waitingSplitFixture is the people/mail fixture the Desktop's parity test
// reads too.
const waitingSplitFixture = "../inbox/testdata/waiting_split.json"

// The people/mail split, the people counts by section, the mail senders and
// the mute agree with the shared fixture.
func TestWaitingSplit_SharedFixture(t *testing.T) {
	d := openTestDB(t)
	fx := SeedTestWaitingSplitFixture(t, d, waitingSplitFixture)
	ctx := context.Background()
	want := fx.Expected

	triggers := fixtureTriggers(t, d)
	if len(want.Kinds) != len(triggers) {
		t.Fatalf("fixture names %d kinds for %d items", len(want.Kinds), len(triggers))
	}
	for id, kind := range want.Kinds {
		if got := WaitingKindOf(triggers[id]); got != kind {
			t.Errorf("WaitingKindOf(item %d, %s) = %s, want %s", id, triggers[id], got, kind)
		}
	}

	people, err := d.OpenPeopleCounts(ctx, fx.Now)
	if err != nil {
		t.Fatal(err)
	}
	if wantP := (PeopleWaitingCounts{want.People.Open, want.People.Today, want.People.Week, want.People.Older}); people != wantP {
		t.Errorf("OpenPeopleCounts = %+v, want %+v", people, wantP)
	}

	peopleItems, err := d.OpenInboxItemsOfKind(ctx, fx.Now, WaitingPeople, 200)
	if err != nil {
		t.Fatal(err)
	}
	var older []int64
	for _, it := range peopleItems {
		if WaitingKindOf(it.TriggerType) != WaitingPeople {
			t.Errorf("people read returned item %d (%s)", it.ID, it.TriggerType)
		}
		if WaitingSectionOf(parseFixtureStamp(t, it.At), fx.Now) == SectionOlder {
			older = append(older, int64(it.ID))
		}
	}
	if len(peopleItems) != want.People.Open {
		t.Errorf("%d people items, want %d", len(peopleItems), want.People.Open)
	}
	if !slices.Equal(older, want.OlderPeopleIDs) {
		t.Errorf("older people ids = %v, want %v", older, want.OlderPeopleIDs)
	}

	mail, err := d.OpenMailSenders(ctx, fx.Now, 200)
	if err != nil {
		t.Fatal(err)
	}
	if mail.Open != want.Mail.Open || mail.Today != want.Mail.Today ||
		mail.SenderCount != want.Mail.SenderCount || mail.TopTenShare != want.Mail.TopTenShare {
		t.Errorf("OpenMailSenders totals = open %d today %d senders %d share %d, want %+v",
			mail.Open, mail.Today, mail.SenderCount, mail.TopTenShare, want.Mail)
	}
	if len(mail.Senders) != len(want.Senders) {
		t.Fatalf("senders = %+v, want %+v", mail.Senders, want.Senders)
	}
	for i, s := range mail.Senders {
		w := want.Senders[i]
		if s.Address != w.Address || s.Open != w.Open || s.Today != w.Today || s.Subject != w.Subject {
			t.Errorf("sender %d = %q open %d today %d subject %q, want %+v", i, s.Address, s.Open, s.Today, s.Subject, w)
		}
	}

	mailItems, err := d.OpenInboxItemsOfKind(ctx, fx.Now, WaitingMail, 200)
	if err != nil {
		t.Fatal(err)
	}
	gotIDs := map[string][]int64{}
	for _, it := range mailItems {
		if it.TriggerType != "email_received" {
			t.Errorf("mail read returned item %d (%s)", it.ID, it.TriggerType)
		}
		key := MailSenderKey(it.SenderUserID)
		gotIDs[key] = append(gotIDs[key], int64(it.ID))
	}
	if len(gotIDs) != len(want.SenderIDs) {
		t.Errorf("mail senders read = %v, want %v", gotIDs, want.SenderIDs)
	}
	for addr, ids := range want.SenderIDs {
		if !slices.Equal(gotIDs[addr], ids) {
			t.Errorf("sender %q ids = %v, want %v", addr, gotIDs[addr], ids)
		}
	}
	for addr := range gotIDs {
		if addr == "news@example.com" {
			t.Errorf("a muted sender's mail was read: %v", gotIDs[addr])
		}
	}
	// The newest item of the first sender gives its time and link.
	if s := mail.Senders[0]; s.At != "2026-11-11T07:00:00Z" || s.Permalink != "https://mail.example.com/m/20" {
		t.Errorf("first sender at %q link %q; want its newest item's", s.At, s.Permalink)
	}
}

// fixtureTriggers maps every seeded item id to its trigger.
func fixtureTriggers(t *testing.T, d *DB) map[int64]string {
	t.Helper()
	rows, err := d.Query(`SELECT id, trigger_type FROM inbox_items`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	triggers := map[int64]string{}
	for rows.Next() {
		var id int64
		var trig string
		if err := rows.Scan(&id, &trig); err != nil {
			t.Fatal(err)
		}
		triggers[id] = trig
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return triggers
}

func parseFixtureStamp(t *testing.T, s string) time.Time {
	t.Helper()
	if s == "" {
		return time.Time{}
	}
	at, err := time.Parse(time.RFC3339, s)
	if err != nil {
		t.Fatalf("stamp %q: %v", s, err)
	}
	return at
}

// Each kind is capped on its own, newest first; the sender view keeps its
// totals over every sender while listing at most limit of them.
func TestOpenInboxItemsOfKind_CapsEachKindSeparately(t *testing.T) {
	d := openTestDB(t)
	ctx := context.Background()
	now := time.Date(2026, 11, 11, 8, 0, 0, 0, time.UTC)
	for i := 1; i <= 250; i++ {
		at := now.Add(-time.Duration(i) * time.Minute).Format(time.RFC3339)
		if _, err := d.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, created_at)
			VALUES ('C001', ?, 'U001', 'mention', ?)`, fmt.Sprintf("p.%04d", i), at); err != nil {
			t.Fatal(err)
		}
		if _, err := d.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, snippet, created_at)
			VALUES (?, ?, ?, 'email_received', 'Hi', ?)`, fmt.Sprintf("mail-%04d", i), fmt.Sprintf("m.%04d", i),
			fmt.Sprintf("sender-%04d@example.com", i), at); err != nil {
			t.Fatal(err)
		}
	}
	for _, c := range []struct {
		kind  WaitingKind
		first string
	}{{WaitingPeople, "p.0001"}, {WaitingMail, "m.0001"}} {
		got, err := d.OpenInboxItemsOfKind(ctx, now, c.kind, 200)
		if err != nil {
			t.Fatal(err)
		}
		if len(got) != 200 {
			t.Fatalf("%s: %d items, want 200", c.kind, len(got))
		}
		if got[0].MessageTS != c.first {
			t.Errorf("%s: first = %s, want %s", c.kind, got[0].MessageTS, c.first)
		}
		for i := 1; i < len(got); i++ {
			if got[i].At > got[i-1].At {
				t.Fatalf("%s: not newest first at %d", c.kind, i)
			}
		}
	}
	mail, err := d.OpenMailSenders(ctx, now, 200)
	if err != nil {
		t.Fatal(err)
	}
	// Ten of 250 one-item senders: (100·10 + 125) / 250 = 4.
	if len(mail.Senders) != 200 || mail.SenderCount != 250 || mail.Open != 250 || mail.TopTenShare != 4 {
		t.Errorf("sender view = %d listed, %d senders, %d open, share %d; want 200, 250, 250, 4",
			len(mail.Senders), mail.SenderCount, mail.Open, mail.TopTenShare)
	}
}

// One spelling rule for a sender: ASCII letters lowered, spaces trimmed,
// non-ASCII letters unchanged — SQLite's lower(trim(x)).
func TestMailSenderKey(t *testing.T) {
	cases := map[string]string{
		" Bob@Example.COM":  "bob@example.com",
		"bob@example.com  ": "bob@example.com",
		"JOSÉ@Example.com":  "josÉ@example.com",
		"Ärger@Example.com": "Ärger@example.com",
		"\tTab@Example.com": "\ttab@example.com",
		"":                  "",
	}
	d := openTestDB(t)
	for raw, want := range cases {
		if got := MailSenderKey(raw); got != want {
			t.Errorf("MailSenderKey(%q) = %q, want %q", raw, got, want)
		}
		var sqlKey string
		if err := d.QueryRow(`SELECT lower(trim(?))`, raw).Scan(&sqlKey); err != nil {
			t.Fatal(err)
		}
		if sqlKey != want {
			t.Errorf("SQLite lower(trim(%q)) = %q, want %q", raw, sqlKey, want)
		}
	}
}
