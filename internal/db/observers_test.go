package db

import "testing"

func TestObserverCRUD(t *testing.T) {
	d, err := Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()

	id, err := d.CreateObserver(Observer{
		EntityType: "target", EntityID: 7,
		Name: "Progress watcher", Instruction: "track progress", Enabled: true,
	})
	if err != nil || id == 0 {
		t.Fatalf("create: id=%d err=%v", id, err)
	}

	got, err := d.GetObserverByID(id)
	if err != nil {
		t.Fatal(err)
	}
	if got.Name != "Progress watcher" || !got.Enabled || got.EntityID != 7 {
		t.Fatalf("unexpected observer: %+v", got)
	}
	if got.LastRunAt != "" {
		t.Fatalf("new observer should have empty watermark, got %q", got.LastRunAt)
	}

	if err := d.UpdateObserver(id, "Renamed", "new instruction"); err != nil {
		t.Fatal(err)
	}
	if err := d.SetObserverEnabled(id, false); err != nil {
		t.Fatal(err)
	}
	if err := d.SetObserverLastRun(id, "2026-06-27T10:00:00Z"); err != nil {
		t.Fatal(err)
	}
	got, _ = d.GetObserverByID(id)
	if got.Name != "Renamed" || got.Enabled || got.LastRunAt != "2026-06-27T10:00:00Z" {
		t.Fatalf("update/enable/watermark not applied: %+v", got)
	}

	cnt, err := d.CountObserversForEntity("target", 7)
	if err != nil || cnt != 1 {
		t.Fatalf("count: %d err=%v", cnt, err)
	}

	// enabled list excludes the disabled one
	enabled, err := d.GetEnabledObservers()
	if err != nil {
		t.Fatal(err)
	}
	if len(enabled) != 0 {
		t.Fatalf("expected 0 enabled, got %d", len(enabled))
	}

	if err := d.DeleteObserver(id); err != nil {
		t.Fatal(err)
	}
	cnt, _ = d.CountObserversForEntity("target", 7)
	if cnt != 0 {
		t.Fatalf("expected 0 after delete, got %d", cnt)
	}
}

func TestObserverEvents(t *testing.T) {
	d, err := Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()

	obsID, _ := d.CreateObserver(Observer{EntityType: "target", EntityID: 3, Name: "w", Enabled: true})

	evID, err := d.InsertObserverEvent(ObserverEvent{
		ObserverID: obsID, EntityType: "target", EntityID: 3,
		Summary: "decision made", SourceType: "digest", SourceID: "12",
		SourceRefs:     `["https://x"]`,
		ProposedAction: `{"type":"update_status","reason":"done in slack","status":"done"}`,
		ActionStatus:   "pending",
	})
	if err != nil || evID == 0 {
		t.Fatalf("insert event: id=%d err=%v", evID, err)
	}

	events, err := d.GetObserverEventsForEntity("target", 3, 50)
	if err != nil || len(events) != 1 {
		t.Fatalf("events: %d err=%v", len(events), err)
	}
	if events[0].ProposedAction == "" || events[0].ActionStatus != "pending" {
		t.Fatalf("event fields lost: %+v", events[0])
	}

	if err := d.MarkObserverEventRead(evID, "2026-06-27T11:00:00Z"); err != nil {
		t.Fatal(err)
	}
	if err := d.SetObserverEventActionStatus(evID, "applied"); err != nil {
		t.Fatal(err)
	}
	events, _ = d.GetObserverEventsForEntity("target", 3, 50)
	if events[0].ReadAt == "" || events[0].ActionStatus != "applied" {
		t.Fatalf("read/action not updated: %+v", events[0])
	}

	// deleting the observer cascades its events
	if err := d.DeleteObserver(obsID); err != nil {
		t.Fatal(err)
	}
	events, _ = d.GetObserverEventsForEntity("target", 3, 50)
	if len(events) != 0 {
		t.Fatalf("events should cascade-delete, got %d", len(events))
	}
}
