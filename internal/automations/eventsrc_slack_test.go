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
// synced channels, releases (1:C1) and general (1:C2), both marked at ts 100.
func slackFixture(t *testing.T) *db.DB {
	t.Helper()
	d := openEventDB(t)
	_, err := d.CreateSlackAccount(db.SlackAccount{TeamDomain: "acme", Label: "work", CurrentUserID: "1:UOWNER"})
	must(t, err)
	for id, name := range map[string]string{"1:C1": "releases", "1:C2": "general"} {
		must(t, d.UpsertChannel(db.Channel{ID: id, Name: name, Type: "public", Topic: contentMarker}))
		must(t, d.UpdateSyncState(id, db.SyncState{LastSyncedTS: "1700000100.000000", IsInitialSyncComplete: true}))
	}
	return d
}

// slackPhase simulates phaseSlackSync: it stores msgs (text = contentMarker)
// and advances each touched channel's mark to its newest message.
func slackPhase(t *testing.T, d *db.DB, msgs ...db.Message) {
	t.Helper()
	newest := map[string]string{}
	for _, m := range msgs {
		m.Text = contentMarker
		must(t, d.UpsertMessage(m))
		if m.TS > newest[m.ChannelID] {
			newest[m.ChannelID] = m.TS
		}
	}
	for id, ts := range newest {
		must(t, d.UpdateSyncState(id, db.SyncState{LastSyncedTS: ts, IsInitialSyncComplete: true}))
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

func TestSlackEvents_FirstSyncOfChannelPublishesNothing(t *testing.T) {
	d := slackFixture(t)
	must(t, d.UpsertChannel(db.Channel{ID: "1:C3", Name: "fresh", Type: "public"}))
	must(t, d.UpdateSyncState("1:C3", db.SyncState{}))
	got := slackEvents(t, d, func() {
		slackPhase(t, d, msg("1:C3", "1700000101.000000", "1:UA"))
	})
	if len(got) != 0 {
		t.Errorf("first sync published %+v", got)
	}
	// A channel with no sync_state row at all before the phase is a first sync too.
	must(t, d.UpsertChannel(db.Channel{ID: "1:C4", Name: "brand-new", Type: "public"}))
	got = slackEvents(t, d, func() {
		slackPhase(t, d, msg("1:C4", "1700000101.000000", "1:UA"))
	})
	if len(got) != 0 {
		t.Errorf("unseen channel published %+v", got)
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

func TestSlackEvents_UnchangedWatermarkNoEvent(t *testing.T) {
	d := slackFixture(t)
	got := slackEvents(t, d, func() {
		// A message lands but the mark does not move: not this phase's news.
		must(t, d.UpsertMessage(db.Message{ChannelID: "1:C1", TS: "1700000101.000000", UserID: "1:UA", Text: contentMarker}))
	})
	if len(got) != 0 {
		t.Errorf("unchanged watermark published %+v", got)
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
