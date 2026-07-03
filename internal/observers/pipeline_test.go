package observers

import (
	"context"
	"log"
	"strings"
	"testing"

	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// mockGen returns a canned AI response and records the prompt it saw. For the
// two-stage backfill it returns shortlistResp to the stage-1 (title) prompt and
// resp to the stage-2 (extract) prompt, distinguished by their headers.
type mockGen struct {
	resp          string
	shortlistResp string
	lastUser      string
	calls         int
}

func (m *mockGen) Generate(ctx context.Context, sys, user, sess string) (string, *digest.Usage, string, error) {
	m.calls++
	m.lastUser = user
	if m.shortlistResp != "" && strings.Contains(user, "ACTIVITY TITLES:") {
		return m.shortlistResp, &digest.Usage{}, "", nil
	}
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

func TestRunForTargetSinceScansDeepHistory(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Deep history target")
	newObserver(t, d, tid)
	// A digest older than the default 7-day lookback: a normal run misses it.
	if _, err := d.Exec(`INSERT INTO digests (channel_id, period_from, period_to, type, summary, created_at)
		VALUES ('C1', 0, 0, 'channel', 'old billing decision', '2020-01-01T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	gen := &mockGen{
		resp:          `{"events":[{"summary":"old billing event","source_type":"digest"}]}`,
		shortlistResp: `{"refs":[{"kind":"digest","id":1}]}`,
	}
	p := New(d, gen, log.Default())

	// Normal forward run sees nothing (the activity predates the 7-day window).
	if n, err := p.Run(context.Background()); err != nil || n != 0 {
		t.Fatalf("forward run should find nothing, got n=%d err=%v", n, err)
	}

	// Backfill from the epoch picks up the old activity.
	events, err := p.RunForTargetSince(context.Background(), tid, "1970-01-01T00:00:00Z")
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 || events[0].Summary != "old billing event" {
		t.Fatalf("backfill should surface the old event, got %+v", events)
	}
}

func TestRunForTargetSinceDedupsRepeatedSummaries(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Dedup target")
	newObserver(t, d, tid)
	if _, err := d.Exec(`INSERT INTO digests (channel_id, period_from, period_to, type, summary, created_at)
		VALUES ('C1', 0, 0, 'channel', 'recurring decision', '2020-01-01T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	gen := &mockGen{
		resp:          `{"events":[{"summary":"same event","source_type":"digest"}]}`,
		shortlistResp: `{"refs":[{"kind":"digest","id":1}]}`,
	}
	p := New(d, gen, log.Default())

	first, err := p.RunForTargetSince(context.Background(), tid, "1970-01-01T00:00:00Z")
	if err != nil || len(first) != 1 {
		t.Fatalf("first backfill should create 1 event, got %d err=%v", len(first), err)
	}
	// Re-running the same window yields the same summary, which must be deduped.
	second, err := p.RunForTargetSince(context.Background(), tid, "1970-01-01T00:00:00Z")
	if err != nil {
		t.Fatal(err)
	}
	if len(second) != 0 {
		t.Fatalf("repeated summary must be deduped, got %+v", second)
	}
	if all, _ := d.GetObserverEventsForEntity("target", tid, 50); len(all) != 1 {
		t.Fatalf("timeline should hold exactly 1 event after dedup, got %d", len(all))
	}
}

func TestRunForTargetSinceEmptyShortlistSkipsExtract(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Filter target")
	newObserver(t, d, tid)
	if _, err := d.Exec(`INSERT INTO digests (channel_id, period_from, period_to, type, summary, created_at)
		VALUES ('C1', 0, 0, 'channel', 'unrelated chatter', '2020-01-01T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	gen := &mockGen{
		resp:          `{"events":[{"summary":"should never be extracted"}]}`,
		shortlistResp: `{"refs":[]}`,
	}
	p := New(d, gen, log.Default())

	events, err := p.RunForTargetSince(context.Background(), tid, "1970-01-01T00:00:00Z")
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 0 {
		t.Fatalf("empty shortlist must produce no events, got %+v", events)
	}
	// Only the cheap stage-1 call should have run; the expensive extract is skipped.
	if gen.calls != 1 {
		t.Fatalf("extract must be skipped when nothing is shortlisted; want 1 AI call, got %d", gen.calls)
	}
}

func TestRunForTargetSinceEmptyErrors(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Target")
	newObserver(t, d, tid)
	gen := &mockGen{resp: `{"events":[]}`}
	p := New(d, gen, log.Default())

	if _, err := p.RunForTargetSince(context.Background(), tid, ""); err == nil {
		t.Fatalf("empty since must error")
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
