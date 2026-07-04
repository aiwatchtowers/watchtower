package observers

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"strings"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// mockGen returns a canned AI response and records the prompts it saw. For the
// two-stage backfill it returns shortlistResp to the stage-1 (title) prompt and
// resp to the stage-2 (extract) prompt, distinguished by their headers.
// genErr fails every call; failOnUserSubstring fails only calls whose user
// prompt contains the substring (to fail one observer out of several).
type mockGen struct {
	resp                string
	shortlistResp       string
	genErr              error
	failOnUserSubstring string
	lastUser            string
	lastSys             string
	sysSeen             []string
	calls               int
}

func (m *mockGen) Generate(ctx context.Context, sys, user, sess string) (string, *digest.Usage, string, error) {
	m.calls++
	m.lastUser = user
	m.lastSys = sys
	m.sysSeen = append(m.sysSeen, sys)
	if m.genErr != nil {
		return "", nil, "", m.genErr
	}
	if m.failOnUserSubstring != "" && strings.Contains(user, m.failOnUserSubstring) {
		return "", nil, "", fmt.Errorf("simulated AI failure")
	}
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
	p := New(d, gen, "", log.Default())

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
	p := New(d, gen, "", log.Default())

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
	p := New(d, gen, "", log.Default())

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
	p := New(d, gen, "", log.Default())

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
	p := New(d, gen, "", log.Default())

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
	p := New(d, gen, "", log.Default())

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
	p := New(d, gen, "", log.Default())

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
	p := New(d, gen, "", log.Default())

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
	p := New(d, gen, "", log.Default())

	if _, err := p.RunForTargetSince(context.Background(), tid, ""); err == nil {
		t.Fatalf("empty since must error")
	}
}

func TestComposeParsesNameAndInstruction(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Ship billing migration")

	gen := &mockGen{resp: "```json\n{\"name\":\"Billing refund\",\"instruction\":\"Watch only the HashBank refund decision and its owner.\"}\n```"}
	p := New(d, gen, "", log.Default())

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
	p := New(d, gen, "", log.Default())

	if _, err := p.Compose(context.Background(), tid, "watch stuff"); err == nil {
		t.Fatalf("expected error for empty instruction")
	}
}

func TestComposeDefaultsBlankName(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Ship billing migration")
	gen := &mockGen{resp: `{"name":"","instruction":"Watch the refund decision."}`}
	p := New(d, gen, "", log.Default())

	res, err := p.Compose(context.Background(), tid, "watch stuff")
	if err != nil {
		t.Fatal(err)
	}
	if res.Name != "Observer" {
		t.Fatalf("blank name should default to Observer, got %q", res.Name)
	}
}

// seedDigestAt inserts one channel digest with an explicit created_at.
func seedDigestAt(t *testing.T, d *db.DB, i int, createdAt string) {
	t.Helper()
	if _, err := d.Exec(`INSERT INTO digests (channel_id, period_from, period_to, type, summary, created_at)
		VALUES ('C1', ?, ?, 'channel', ?, ?)`, i, i, fmt.Sprintf("digest %d", i), createdAt); err != nil {
		t.Fatal(err)
	}
}

// lastRunAt reads the watermark of the single observer on a target.
func lastRunAt(t *testing.T, d *db.DB, targetID int) string {
	t.Helper()
	obs, err := d.GetObserversForEntity("target", targetID)
	if err != nil || len(obs) != 1 {
		t.Fatalf("expected 1 observer, got %d (err %v)", len(obs), err)
	}
	return obs[0].LastRunAt
}

// TestRunCappedActivityAdvancesWatermarkToProcessed guards the F2 contract:
// when a forward run hits the per-source activity cap, the watermark advances
// only to the newest row actually processed — never to now — so overflow is
// picked up by the next cycle instead of being skipped forever.
func TestRunCappedActivityAdvancesWatermarkToProcessed(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Busy target")
	newObserver(t, d, tid)

	// 5 rows beyond the cap, oldest first: seconds 00..44 on a fixed minute.
	total := defaultActivityLimit + 5
	for i := 0; i < total; i++ {
		seedDigestAt(t, d, i, fmt.Sprintf("2026-07-01T00:00:%02dZ", i))
	}

	gen := &mockGen{resp: `{"events":[]}`}
	p := New(d, gen, "", log.Default())
	if _, err := p.Run(context.Background()); err != nil {
		t.Fatal(err)
	}

	// Oldest-first processing consumed rows 0..39; watermark = created_at of row 39.
	want := fmt.Sprintf("2026-07-01T00:00:%02dZ", defaultActivityLimit-1)
	if got := lastRunAt(t, d, tid); got != want {
		t.Fatalf("capped run watermark = %q, want %q (cap overflow would be skipped forever)", got, want)
	}

	// Second run picks up the remaining 5 rows and, uncapped, advances past them.
	gen.calls = 0
	if _, err := p.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if gen.calls != 1 {
		t.Fatalf("second run must process the overflow (1 AI call), got %d", gen.calls)
	}
	if got := lastRunAt(t, d, tid); got <= fmt.Sprintf("2026-07-01T00:00:%02dZ", total-1) {
		t.Fatalf("uncapped second run should advance watermark past the seeded rows, got %q", got)
	}
}

// TestRunInsertFailureHoldsWatermark pins the documented contract at
// pipeline.go: a failed event insert must leave the watermark un-advanced so
// the next run re-queries the window instead of silently dropping the event.
func TestRunInsertFailureHoldsWatermark(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Fragile target")
	newObserver(t, d, tid)
	seedDigestAt(t, d, 1, "2026-07-01T00:00:01Z")

	// Simulate a persist failure for one specific event via a trigger.
	if _, err := d.Exec(`CREATE TRIGGER fail_insert BEFORE INSERT ON observer_events
		WHEN NEW.summary = 'BOOM' BEGIN SELECT RAISE(ABORT, 'simulated insert failure'); END`); err != nil {
		t.Fatal(err)
	}

	gen := &mockGen{resp: `{"events":[
		{"summary":"BOOM","source_type":"digest","source_id":"1"},
		{"summary":"Survivor event","source_type":"digest","source_id":"1"}]}`}
	p := New(d, gen, "", log.Default())

	before := lastRunAt(t, d, tid)
	if _, err := p.Run(context.Background()); err != nil {
		t.Fatalf("Run logs per-observer failures and must not error: %v", err)
	}

	if got := lastRunAt(t, d, tid); got != before {
		t.Fatalf("watermark advanced %q -> %q despite insert failure (window silently dropped)", before, got)
	}
	events, _ := d.GetObserverEventsForEntity("target", tid, 50)
	if len(events) != 1 || !strings.Contains(events[0].Summary, "Survivor") {
		t.Fatalf("the non-failing event should still persist, got: %+v", events)
	}
}

// newObserverWithInstruction creates an enabled observer with a custom
// instruction (so per-observer AI failures can be targeted by prompt content).
func newObserverWithInstruction(t *testing.T, d *db.DB, targetID int, instr string) {
	t.Helper()
	if _, err := d.CreateObserver(db.Observer{
		EntityType: "target", EntityID: targetID,
		Name: "Watcher", Instruction: instr, Enabled: true,
	}); err != nil {
		t.Fatal(err)
	}
}

// TestRunForTargetAllObserversFailedErrors guards the F5/F11 fix: RunForTarget
// backs the user-initiated Refresh action, so when EVERY enabled observer
// fails the call must fail visibly instead of returning (nil, nil).
func TestRunForTargetAllObserversFailedErrors(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Doomed target")
	newObserverWithInstruction(t, d, tid, "Watch A.")
	newObserverWithInstruction(t, d, tid, "Watch B.")
	seedDigestAt(t, d, 1, time.Now().UTC().Format("2006-01-02T15:04:05Z")) // fresh activity so runOne reaches the AI call

	gen := &mockGen{genErr: fmt.Errorf("provider exploded")}
	p := New(d, gen, "", log.Default())

	_, err := p.RunForTarget(context.Background(), tid)
	if err == nil {
		t.Fatal("expected error when all observers fail, got nil")
	}
	if !strings.Contains(err.Error(), "all 2 observer(s) failed") {
		t.Fatalf("error should say all observers failed, got: %v", err)
	}
	if !strings.Contains(err.Error(), "provider exploded") {
		t.Fatalf("error should wrap the last observer failure, got: %v", err)
	}
}

// TestRunForTargetPartialFailureKeepsSkipAndLog: when only some observers
// fail, RunForTarget keeps the original skip-and-log semantics and returns
// the surviving events without an error.
func TestRunForTargetPartialFailureKeepsSkipAndLog(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Mixed target")
	newObserverWithInstruction(t, d, tid, "Watch billing FAILME.")
	newObserverWithInstruction(t, d, tid, "Watch shipping.")
	seedDigestAt(t, d, 1, time.Now().UTC().Format("2006-01-02T15:04:05Z"))

	gen := &mockGen{
		resp:                `{"events":[{"summary":"shipping moved","source_type":"digest"}]}`,
		failOnUserSubstring: "FAILME",
	}
	p := New(d, gen, "", log.Default())

	events, err := p.RunForTarget(context.Background(), tid)
	if err != nil {
		t.Fatalf("partial failure must not error: %v", err)
	}
	if len(events) != 1 || events[0].Summary != "shipping moved" {
		t.Fatalf("surviving observer's events lost: %+v", events)
	}
}

// TestRunForTargetNoEventsReturnsNonNilEmptySlice pins the JSON contract for
// the CLI: `targets observe` encodes the result directly, and Swift expects
// [] — a nil slice would encode as null.
func TestRunForTargetNoEventsReturnsNonNilEmptySlice(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Quiet target")
	newObserver(t, d, tid)

	gen := &mockGen{resp: `{"events":[]}`}
	p := New(d, gen, "", log.Default())

	events, err := p.RunForTarget(context.Background(), tid)
	if err != nil {
		t.Fatal(err)
	}
	if events == nil {
		t.Fatal("RunForTarget must return a non-nil slice on success")
	}
	buf, err := json.Marshal(events)
	if err != nil {
		t.Fatal(err)
	}
	if string(buf) != "[]" {
		t.Fatalf("empty result must encode as [], got %s", buf)
	}
}

// TestRunAllObserversFailedStillNoError pins that the daemon path is
// unchanged by the F5 fix: Run keeps skip-and-log semantics even when every
// observer fails (the daemon logs and moves to the next phase).
func TestRunAllObserversFailedStillNoError(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Daemon target")
	newObserver(t, d, tid)
	seedDigestAt(t, d, 1, time.Now().UTC().Format("2006-01-02T15:04:05Z"))

	gen := &mockGen{genErr: fmt.Errorf("provider exploded")}
	p := New(d, gen, "", log.Default())

	n, err := p.Run(context.Background())
	if err != nil {
		t.Fatalf("Run must keep skip-and-log semantics: %v", err)
	}
	if n != 0 {
		t.Fatalf("expected 0 events, got %d", n)
	}
}

// TestObserverPromptsCarryLanguageDirective enforces the prompts.Directive
// contract (F7) for the observer pipeline: the run and compose system prompts
// must carry the configured response language; the shortlist prompt returns
// an ids-only JSON object and is explicitly exempt.
func TestObserverPromptsCarryLanguageDirective(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Localized target")
	newObserver(t, d, tid)
	seedDigestAt(t, d, 1, time.Now().UTC().Format("2006-01-02T15:04:05Z"))

	gen := &mockGen{resp: `{"events":[]}`}
	p := New(d, gen, "Ukrainian", log.Default())

	if _, err := p.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !prompts.HasDirective(gen.lastSys) || !strings.Contains(gen.lastSys, "Ukrainian") {
		t.Fatalf("observer.run system prompt missing language directive:\n%s", gen.lastSys)
	}

	gen.resp = `{"name":"W","instruction":"Watch the refund decision."}`
	if _, err := p.Compose(context.Background(), tid, "watch refunds"); err != nil {
		t.Fatal(err)
	}
	if !prompts.HasDirective(gen.lastSys) || !strings.Contains(gen.lastSys, "Ukrainian") {
		t.Fatalf("observer.compose system prompt missing language directive:\n%s", gen.lastSys)
	}
}

// TestObserverShortlistPromptOmitsDirective pins the documented exception:
// the stage-1 shortlist call outputs ids-only JSON, so it carries no
// language directive.
func TestObserverShortlistPromptOmitsDirective(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Backfill target")
	newObserver(t, d, tid)
	seedDigestAt(t, d, 1, "2020-01-01T00:00:00Z")

	gen := &mockGen{
		resp:          `{"events":[]}`,
		shortlistResp: `{"refs":[]}`,
	}
	p := New(d, gen, "Ukrainian", log.Default())

	if _, err := p.RunForTargetSince(context.Background(), tid, "1970-01-01T00:00:00Z"); err != nil {
		t.Fatal(err)
	}
	if gen.calls != 1 {
		t.Fatalf("expected only the shortlist call, got %d", gen.calls)
	}
	if prompts.HasDirective(gen.lastSys) {
		t.Fatalf("shortlist prompt must not carry the language directive (ids-only output):\n%s", gen.lastSys)
	}
}

// TestRunCappedSameSecondBatchNotLost guards the same-second tie hole: when
// MORE than the per-source cap of rows share one created_at second (realistic:
// inbox_items batch-inserted 100-in-one-second on a cold start), the whole tie
// group must be fed to the prompt in one batch — the watermark advances to the
// boundary second and the next window opens with a strict `>`, so anything
// left behind would be skipped forever.
func TestRunCappedSameSecondBatchNotLost(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Cold-start target")
	newObserver(t, d, tid)

	total := defaultActivityLimit + 10
	for i := 0; i < total; i++ {
		seedDigestAt(t, d, i, "2026-07-01T00:00:00Z")
	}

	gen := &mockGen{resp: `{"events":[]}`}
	p := New(d, gen, "", log.Default())
	if _, err := p.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := strings.Count(gen.lastUser, "[digest id="); got != total {
		t.Fatalf("prompt carried %d of %d same-second rows (boundary ties lost)", got, total)
	}

	// The whole tie group was consumed, so the second run finds nothing new:
	// no AI call, no events.
	gen.calls = 0
	if _, err := p.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if gen.calls != 0 {
		t.Fatalf("second run must make no AI call (window fully consumed), got %d", gen.calls)
	}
	if events, _ := d.GetObserverEventsForEntity("target", tid, 100); len(events) != 0 {
		t.Fatalf("no events expected, got %d", len(events))
	}
}

// TestRunCappedBoundaryTiesNotLost guards the mixed shape: increasing
// timestamps up to the cap plus a few rows tied at the boundary second. The
// tied rows must be fed with the first batch, not dropped when the watermark
// advances to the boundary.
func TestRunCappedBoundaryTiesNotLost(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Tied-boundary target")
	newObserver(t, d, tid)

	// 39 rows with increasing seconds, then 5 tied at the boundary second.
	for i := 0; i < defaultActivityLimit-1; i++ {
		seedDigestAt(t, d, i, fmt.Sprintf("2026-07-01T00:00:%02dZ", i))
	}
	boundary := fmt.Sprintf("2026-07-01T00:00:%02dZ", defaultActivityLimit-1)
	total := defaultActivityLimit + 4
	for i := defaultActivityLimit - 1; i < total; i++ {
		seedDigestAt(t, d, i, boundary)
	}

	gen := &mockGen{resp: `{"events":[]}`}
	p := New(d, gen, "", log.Default())
	if _, err := p.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := strings.Count(gen.lastUser, "[digest id="); got != total {
		t.Fatalf("prompt carried %d of %d rows (tied boundary rows lost)", got, total)
	}
	if got := lastRunAt(t, d, tid); got != boundary {
		t.Fatalf("watermark = %q, want boundary %q", got, boundary)
	}

	gen.calls = 0
	if _, err := p.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if gen.calls != 0 {
		t.Fatalf("second run must make no AI call (window fully consumed), got %d", gen.calls)
	}
}

// TestRunForwardDedupSkipsAndLogs covers the forward-run dedup path (F2): a
// capped first run persists event "X"; the second run re-emits "X" alongside a
// new "Y". Only "Y" may be created, and the skip must be observable in the log.
func TestRunForwardDedupSkipsAndLogs(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Forward dedup target")
	newObserver(t, d, tid)

	// Cap the first run so the second run still has overflow rows to process.
	total := defaultActivityLimit + 5
	for i := 0; i < total; i++ {
		seedDigestAt(t, d, i, fmt.Sprintf("2026-07-01T00:00:%02dZ", i))
	}

	var buf bytes.Buffer
	gen := &mockGen{resp: `{"events":[{"summary":"X","source_type":"digest"}]}`}
	p := New(d, gen, "", log.New(&buf, "", 0))

	if _, err := p.Run(context.Background()); err != nil {
		t.Fatal(err)
	}

	gen.resp = `{"events":[
		{"summary":"X","source_type":"digest"},
		{"summary":"Y","source_type":"digest"}]}`
	buf.Reset()
	if _, err := p.Run(context.Background()); err != nil {
		t.Fatal(err)
	}

	events, _ := d.GetObserverEventsForEntity("target", tid, 50)
	if len(events) != 2 {
		t.Fatalf("expected X + Y only (X deduped on the second run), got %d: %+v", len(events), events)
	}
	if !strings.Contains(buf.String(), "1 event(s) deduped") {
		t.Fatalf("dedup must be logged, log was:\n%s", buf.String())
	}
}
