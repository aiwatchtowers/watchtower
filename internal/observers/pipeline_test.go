package observers

import (
	"context"
	"log"
	"testing"

	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// mockGen returns a canned AI response and records the prompt it saw.
type mockGen struct {
	resp     string
	lastUser string
	calls    int
}

func (m *mockGen) Generate(ctx context.Context, sys, user, sess string) (string, *digest.Usage, string, error) {
	m.calls++
	m.lastUser = user
	return m.resp, &digest.Usage{}, "", nil
}

func newTarget(t *testing.T, d *db.DB, text string) int {
	t.Helper()
	id, err := d.CreateTarget(db.Target{
		Text: text, Level: "week", PeriodStart: "2026-06-22", PeriodEnd: "2026-06-28",
		Status: "in_progress", Priority: "high", Ownership: "mine", SourceType: "manual",
	})
	if err != nil {
		t.Fatal(err)
	}
	return int(id) // CreateTarget returns int64
}

func TestRunSeedsDefaultObserverAndPersistsEvents(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Ship the billing migration")

	// Seed one channel digest so the observer has activity to analyze.
	if _, err := d.Exec(`INSERT INTO digests (channel_id, period_from, period_to, type, summary)
		VALUES ('C1', 0, 0, 'channel', 'Billing plan B agreed in #eng')`); err != nil {
		t.Fatal(err)
	}

	gen := &mockGen{resp: `{"events":[
		{"summary":"Billing decision finalized in #eng","source_type":"digest","source_id":"5",
		 "source_refs":["https://x"],"decision":{"text":"go with plan B","by":"@ann","importance":"high"},
		 "proposed_action":{"type":"update_status","reason":"decided","status":"in_progress"}}]}`}
	p := New(d, gen, log.Default())

	n, err := p.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("expected 1 event, got %d", n)
	}

	// lazy default observer created exactly once
	cnt, _ := d.CountObserversForEntity("target", tid)
	if cnt != 1 {
		t.Fatalf("expected 1 default observer, got %d", cnt)
	}

	events, _ := d.GetObserverEventsForEntity("target", tid, 50)
	if len(events) != 1 || events[0].ActionStatus != "pending" {
		t.Fatalf("event not persisted with pending action: %+v", events)
	}
	if events[0].Decision == "" || events[0].ProposedAction == "" {
		t.Fatalf("decision/proposed_action lost: %+v", events[0])
	}

	// second run does NOT create a second default observer
	gen.resp = `{"events":[]}`
	if _, err := p.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	cnt, _ = d.CountObserversForEntity("target", tid)
	if cnt != 1 {
		t.Fatalf("default observer duplicated on second run: %d", cnt)
	}
}

func TestRunDegenerateNoEventsAdvancesWatermarkCleanly(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Quiet target")
	gen := &mockGen{resp: `{"events":[]}`}
	p := New(d, gen, log.Default())

	n, err := p.Run(context.Background())
	if err != nil {
		t.Fatalf("degenerate run must not error: %v", err)
	}
	if n != 0 {
		t.Fatalf("expected 0 events, got %d", n)
	}
	obs, _ := d.GetObserversForEntity("target", tid)
	if len(obs) != 1 || obs[0].LastRunAt == "" {
		t.Fatalf("watermark must advance even with no events: %+v", obs)
	}
	events, _ := d.GetObserverEventsForEntity("target", tid, 50)
	if len(events) != 0 {
		t.Fatalf("no events should be inserted, got %d", len(events))
	}
}

func TestRunForTargetReturnsNewEvents(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Force target")
	if _, err := d.Exec(`INSERT INTO digests (channel_id, period_from, period_to, type, summary)
		VALUES ('C1', 0, 0, 'channel', 'manual run activity')`); err != nil {
		t.Fatal(err)
	}
	gen := &mockGen{resp: `{"events":[{"summary":"manual run event","source_type":"track"}]}`}
	p := New(d, gen, log.Default())

	events, err := p.RunForTarget(context.Background(), tid)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 || events[0].Summary != "manual run event" {
		t.Fatalf("unexpected: %+v", events)
	}
}

func TestRunActivityPresentButNoEventsAdvancesWatermark(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Has activity, no relevant events")
	if _, err := d.Exec(`INSERT INTO digests (channel_id, period_from, period_to, type, summary)
		VALUES ('C1', 0, 0, 'channel', 'unrelated chatter')`); err != nil {
		t.Fatal(err)
	}
	gen := &mockGen{resp: `{"events":[]}`}
	p := New(d, gen, log.Default())

	n, err := p.Run(context.Background())
	if err != nil {
		t.Fatalf("must not error: %v", err)
	}
	if n != 0 {
		t.Fatalf("expected 0 events, got %d", n)
	}
	if gen.calls != 1 {
		t.Fatalf("AI should be called once when activity is present, got %d calls", gen.calls)
	}
	obs, _ := d.GetObserversForEntity("target", tid)
	if len(obs) != 1 || obs[0].LastRunAt == "" {
		t.Fatalf("watermark must advance: %+v", obs)
	}
	if events, _ := d.GetObserverEventsForEntity("target", tid, 50); len(events) != 0 {
		t.Fatalf("no events should be inserted, got %d", len(events))
	}
}
