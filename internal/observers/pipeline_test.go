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

func newObserver(t *testing.T, d *db.DB, targetID int) {
	t.Helper()
	if _, err := d.CreateObserver(db.Observer{
		EntityType: "target", EntityID: targetID,
		Name: "Billing watcher", Instruction: "Watch billing migration progress.", Enabled: true,
	}); err != nil {
		t.Fatal(err)
	}
}

func TestRunNoObserversCreatesNothing(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Ship the billing migration")

	gen := &mockGen{resp: `{"events":[]}`}
	p := New(d, gen, log.Default())

	n, err := p.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Fatalf("expected 0 events with no observers, got %d", n)
	}
	if gen.calls != 0 {
		t.Fatalf("AI must not be called when no observers exist, got %d calls", gen.calls)
	}
	if cnt, _ := d.CountObserversForEntity("target", tid); cnt != 0 {
		t.Fatalf("Run must not auto-create observers, got %d", cnt)
	}
}

func TestRunPersistsEventsForExistingObserver(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Ship the billing migration")
	newObserver(t, d, tid)

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
	events, _ := d.GetObserverEventsForEntity("target", tid, 50)
	if len(events) != 1 || events[0].ActionStatus != "pending" {
		t.Fatalf("event not persisted with pending action: %+v", events)
	}
	if events[0].Decision == "" || events[0].ProposedAction == "" {
		t.Fatalf("decision/proposed_action lost: %+v", events[0])
	}
}

func TestRunDegenerateNoEventsAdvancesWatermarkCleanly(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Quiet target")
	newObserver(t, d, tid)
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
	if events, _ := d.GetObserverEventsForEntity("target", tid, 50); len(events) != 0 {
		t.Fatalf("no events should be inserted, got %d", len(events))
	}
}

func TestRunForTargetReturnsNewEvents(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Force target")
	newObserver(t, d, tid)
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

func TestRunForTargetNoObserversReturnsEmpty(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "No observers here")
	gen := &mockGen{resp: `{"events":[]}`}
	p := New(d, gen, log.Default())

	events, err := p.RunForTarget(context.Background(), tid)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 0 {
		t.Fatalf("expected no events, got %+v", events)
	}
	if cnt, _ := d.CountObserversForEntity("target", tid); cnt != 0 {
		t.Fatalf("RunForTarget must not auto-create observers, got %d", cnt)
	}
}

func TestComposeParsesNameAndInstruction(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Ship billing migration")

	gen := &mockGen{resp: "```json\n{\"name\":\"Billing refund\",\"instruction\":\"Watch only the HashBank refund decision and its owner.\"}\n```"}
	p := New(d, gen, log.Default())

	res, err := p.Compose(context.Background(), tid, "the refund commission thing with HashBank")
	if err != nil {
		t.Fatal(err)
	}
	if res.Name != "Billing refund" {
		t.Fatalf("name = %q", res.Name)
	}
	if res.Instruction == "" {
		t.Fatalf("instruction empty")
	}
	if gen.calls != 1 {
		t.Fatalf("expected 1 AI call, got %d", gen.calls)
	}
}

func TestComposeEmptyInstructionErrors(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Ship billing migration")
	gen := &mockGen{resp: `{"name":"X","instruction":""}`}
	p := New(d, gen, log.Default())

	if _, err := p.Compose(context.Background(), tid, "watch stuff"); err == nil {
		t.Fatalf("expected error for empty instruction")
	}
}

func TestComposeDefaultsBlankName(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Ship billing migration")
	gen := &mockGen{resp: `{"name":"","instruction":"Watch the refund decision."}`}
	p := New(d, gen, log.Default())

	res, err := p.Compose(context.Background(), tid, "watch stuff")
	if err != nil {
		t.Fatal(err)
	}
	if res.Name != "Observer" {
		t.Fatalf("blank name should default to Observer, got %q", res.Name)
	}
}
