package automations

import (
	"context"
	"path/filepath"
	"reflect"
	"testing"

	"watchtower/internal/db"
)

// openEventDB opens a seeded file database for the event-source tests.
func openEventDB(t *testing.T) *db.DB {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "watchtower.db"))
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { _ = d.Close() })
	return d
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

// slackFixture seeds Slack account 1 ("work", owner 1:UOWNER) with two
// channels, releases (1:C1) and general (1:C2), each already holding one
// stored message at ts 100. No sync_state row is written: the default search
// sync never writes one.
func slackFixture(t *testing.T) *db.DB {
	t.Helper()
	d := openEventDB(t)
	_, err := d.CreateSlackAccount(db.SlackAccount{TeamDomain: "acme", Label: "work", CurrentUserID: "1:UOWNER"})
	must(t, err)
	for id, name := range map[string]string{"1:C1": "releases", "1:C2": "general"} {
		must(t, d.UpsertChannel(db.Channel{ID: id, Name: name, Type: "public", Topic: contentMarker}))
		must(t, d.UpsertMessage(db.Message{ChannelID: id, TS: "1700000100.000000", UserID: "1:UA", Text: contentMarker}))
	}
	return d
}

// slackPhase simulates phaseSlackSync the way search sync writes: it stores
// msgs (text = contentMarker) in the messages table and nothing else.
func slackPhase(t *testing.T, d *db.DB, msgs ...db.Message) {
	t.Helper()
	for _, m := range msgs {
		m.Text = contentMarker
		must(t, d.UpsertMessage(m))
	}
}

// slackEvents runs the Slack source around phase.
func slackEvents(t *testing.T, d *db.DB, phase func()) []Event {
	t.Helper()
	ctx := context.Background()
	src := SlackSource(d)
	if src.Type() != "slack.new_messages" {
		t.Errorf("Type() = %q", src.Type())
	}
	diff, err := src.Before(ctx)
	must(t, err)
	phase()
	events, err := diff.After(ctx)
	must(t, err)
	return events
}

func msg(channel, ts, user string) db.Message {
	return db.Message{ChannelID: channel, TS: ts, UserID: user}
}

func TestSlackEvents_NewMessagesPerChannel(t *testing.T) {
	d := slackFixture(t)
	got := slackEvents(t, d, func() {
		slackPhase(t, d,
			msg("1:C1", "1700000101.000000", "1:UA"),
			msg("1:C1", "1700000102.000000", "1:UA"),
			msg("1:C1", "1700000103.000000", "1:UB"),
			msg("1:C2", "1700000104.000000", "1:UA"),
		)
	})
	want := []Event{
		{Type: "slack.new_messages", Fields: map[string]any{"account": "work", "channel": "releases", "channel_id": "1:C1", "count": 3}},
		{Type: "slack.new_messages", Fields: map[string]any{"account": "work", "channel": "general", "channel_id": "1:C2", "count": 1}},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("events = %+v\nwant %+v", got, want)
	}
}

// Regression: search sync, the daemon's default path, stores messages but
// never writes sync_state — the source must still see them.
func TestSlackEvents_SearchSyncWithoutSyncStatePublishes(t *testing.T) {
	d := slackFixture(t)
	got := slackEvents(t, d, func() {
		slackPhase(t, d, msg("1:C1", "1700000101.000000", "1:UA"))
	})
	var marks int
	must(t, d.QueryRow(`SELECT COUNT(*) FROM sync_state`).Scan(&marks))
	if marks != 0 {
		t.Fatalf("fixture wrote %d sync_state rows; the search path writes none", marks)
	}
	want := []Event{{Type: "slack.new_messages", Fields: map[string]any{
		"account": "work", "channel": "releases", "channel_id": "1:C1", "count": 1}}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("events = %+v\nwant %+v", got, want)
	}
}

func TestSlackEvents_FirstSyncOfChannelPublishesNothing(t *testing.T) {
	d := slackFixture(t)
	// A channel with no stored message before the phase is a first sync.
	must(t, d.UpsertChannel(db.Channel{ID: "1:C3", Name: "fresh", Type: "public"}))
	got := slackEvents(t, d, func() {
		slackPhase(t, d, msg("1:C3", "1700000101.000000", "1:UA"), msg("1:C3", "1700000102.000000", "1:UB"))
	})
	if len(got) != 0 {
		t.Errorf("first sync published %+v", got)
	}
}

func TestSlackEvents_OlderMessagesNotCounted(t *testing.T) {
	d := slackFixture(t)
	got := slackEvents(t, d, func() {
		// A history backfill or thread fill below the newest stored ts.
		slackPhase(t, d, msg("1:C1", "1700000050.000000", "1:UA"), msg("1:C2", "1700000099.000000", "1:UA"))
		slackPhase(t, d, msg("1:C1", "1700000101.000000", "1:UA"))
	})
	if len(got) != 1 || got[0].Fields["channel_id"] != "1:C1" || got[0].Fields["count"] != 1 {
		t.Errorf("events = %+v, want one releases event with count 1", got)
	}
}

func TestSlackEvents_MissingChannelRowKeepsEmptyName(t *testing.T) {
	d := slackFixture(t)
	// Messages stored for a channel the channels table does not hold.
	must(t, d.UpsertMessage(db.Message{ChannelID: "1:C9", TS: "1700000100.000000", UserID: "1:UA"}))
	got := slackEvents(t, d, func() {
		slackPhase(t, d, msg("1:C9", "1700000101.000000", "1:UA"))
	})
	want := []Event{{Type: "slack.new_messages", Fields: map[string]any{
		"account": "work", "channel": "", "channel_id": "1:C9", "count": 1}}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("events = %+v\nwant %+v", got, want)
	}
}

func TestSlackEvents_OwnerMessagesNotCounted(t *testing.T) {
	d := slackFixture(t)
	got := slackEvents(t, d, func() {
		slackPhase(t, d,
			msg("1:C1", "1700000101.000000", "1:UOWNER"),
			msg("1:C1", "1700000102.000000", "1:UOWNER"),
			msg("1:C1", "1700000103.000000", "1:UA"),
			msg("1:C2", "1700000104.000000", "1:UOWNER"),
		)
	})
	if len(got) != 1 || got[0].Fields["channel_id"] != "1:C1" || got[0].Fields["count"] != 1 {
		t.Errorf("events = %+v, want one releases event with count 1", got)
	}
}

func TestSlackEvents_DeletedMessagesNotCounted(t *testing.T) {
	d := slackFixture(t)
	got := slackEvents(t, d, func() {
		deleted := msg("1:C1", "1700000102.000000", "1:UA")
		deleted.IsDeleted = true
		slackPhase(t, d, msg("1:C1", "1700000101.000000", "1:UA"), deleted)
		gone := msg("1:C2", "1700000103.000000", "1:UA")
		gone.IsDeleted = true
		slackPhase(t, d, gone)
	})
	if len(got) != 1 || got[0].Fields["channel_id"] != "1:C1" || got[0].Fields["count"] != 1 {
		t.Errorf("events = %+v, want one releases event with count 1", got)
	}
}

func TestSlackEvents_UnchangedNoEvent(t *testing.T) {
	d := slackFixture(t)
	got := slackEvents(t, d, func() {
		// A re-sync rewrites the stored message: nothing newer, no news.
		slackPhase(t, d, msg("1:C1", "1700000100.000000", "1:UA"))
	})
	if len(got) != 0 {
		t.Errorf("unchanged channel published %+v", got)
	}
}

// slackContentEvents builds Slack events from the contentMarker fixtures for
// TestBus_EventsCarryNoContent.
func slackContentEvents(t *testing.T) []Event {
	d := slackFixture(t)
	return slackEvents(t, d, func() {
		slackPhase(t, d, msg("1:C1", "1700000101.000000", "1:UA"), msg("1:C2", "1700000102.000000", "1:UB"))
	})
}
