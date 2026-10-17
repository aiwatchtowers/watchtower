package automations_test

import (
	"bytes"
	"context"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/db"
)

const (
	busCycleA = "2026-10-14T12:00:00Z"
	busCycleB = "2026-10-14T12:15:00Z"
)

// busRecipe subscribes to TYPE with the where map WHERE ("{}" for none).
const busRecipe = "---\nname: Bus test\ntrigger:\n  event:\n    type: TYPE\n    where: WHERE\n" +
	"permissions:\n  - llm:light\noutputs: [inbox]\n---\nReacts to events.\n\n```js\nlog(\"event\")\n```\n"

func busRecipeText(eventType, where string) string {
	return strings.NewReplacer("TYPE", eventType, "WHERE", where).Replace(busRecipe)
}

type busFixture struct {
	d     *db.DB
	bus   *automations.Bus
	logs  *bytes.Buffer
	mu    sync.Mutex
	wakes int
}

func newBusFixture(t *testing.T) *busFixture {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "watchtower.db"))
	if err != nil {
		t.Fatalf("opening the test db: %v", err)
	}
	t.Cleanup(func() { _ = d.Close() })
	f := &busFixture{d: d, logs: &bytes.Buffer{}}
	f.bus = automations.NewBus(d, automationstest.NewFakeClock(exStart), func() {
		f.mu.Lock()
		f.wakes++
		f.mu.Unlock()
	}, log.New(f.logs, "", 0))
	return f
}

func (f *busFixture) seed(t *testing.T, slug, eventType, where string, opts automationstest.SeedOptions) db.Automation {
	t.Helper()
	opts.Slug, opts.Now = slug, exStart
	return automationstest.SeedAutomation(t, f.d, busRecipeText(eventType, where), opts)
}

func (f *busFixture) begin(t *testing.T) {
	t.Helper()
	if err := f.bus.Begin(); err != nil {
		t.Fatalf("Begin: %v", err)
	}
}

func (f *busFixture) flush(t *testing.T, cycle string) automations.FlushReport {
	t.Helper()
	rep, err := f.bus.Flush(cycle)
	if err != nil {
		t.Fatalf("Flush(%s): %v", cycle, err)
	}
	return rep
}

func (f *busFixture) wakeCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.wakes
}

func (f *busFixture) runs(t *testing.T, a db.Automation) []db.AutomationRun {
	t.Helper()
	runs, err := f.d.ListAutomationRuns(a.ID, 0)
	if err != nil {
		t.Fatal(err)
	}
	return runs
}

// onlyRun returns a's single run, failing the test when it has another count.
func (f *busFixture) onlyRun(t *testing.T, a db.Automation) db.AutomationRun {
	t.Helper()
	runs := f.runs(t, a)
	if len(runs) != 1 {
		t.Fatalf("automation %s has %d runs; want 1", a.Slug, len(runs))
	}
	return runs[0]
}

func payloadOf(t *testing.T, r db.AutomationRun) db.AutomationEventPayload {
	t.Helper()
	var p db.AutomationEventPayload
	if err := json.Unmarshal([]byte(r.EventJSON), &p); err != nil {
		t.Fatalf("run %d event_json %q: %v", r.ID, r.EventJSON, err)
	}
	return p
}

func slackEvent(channel string, n int) automations.Event {
	return automations.Event{Type: "slack.new_messages", Fields: map[string]any{
		"account": "work", "channel": channel, "channel_id": "C0001", "count": n}}
}

func TestAuto09_FlushOnlyQueues(t *testing.T) {
	f := newBusFixture(t)
	gen := &automationstest.FakeGenerator{Replies: []string{"done"}}
	reg := &automationstest.FakeRegistry{}
	_ = automations.NewExecutor(f.d, automations.Backends{DB: f.d, Generator: gen, Registry: reg,
		Clock: automationstest.NewFakeClock(exStart)}, automations.ExecutorOptions{Logger: log.New(f.logs, "", 0)})
	a := f.seed(t, "watch", "slack.new_messages", "{channel: releases}", automationstest.SeedOptions{})
	f.begin(t)
	f.bus.Publish(slackEvent("releases", 2))
	if rep := f.flush(t, busCycleA); rep.Queued != 1 {
		t.Errorf("report = %+v; want Queued 1", rep)
	}
	r := f.onlyRun(t, a)
	if r.Status != db.RunQueued || r.Trigger != db.TriggerEvent || r.EventCycle != busCycleA {
		t.Errorf("run = %s/%s/%q; want queued/event/%s", r.Status, r.Trigger, r.EventCycle, busCycleA)
	}
	if gen.CallCount() != 0 || len(reg.ReadCalls()) != 0 || len(reg.ProposedCalls()) != 0 {
		t.Errorf("generator %d, reads %d, proposals %d calls; want none", gen.CallCount(), len(reg.ReadCalls()), len(reg.ProposedCalls()))
	}
	if got := f.onlyRun(t, a); got.Status != db.RunQueued || got.StartedAt != nil {
		t.Errorf("run left queued: %s started %v", got.Status, got.StartedAt)
	}
}

func TestBus_OneRunPerAutomationPerCycle(t *testing.T) {
	f := newBusFixture(t)
	a := f.seed(t, "first", "slack.new_messages", "{}", automationstest.SeedOptions{})
	b := f.seed(t, "second", "slack.new_messages", "{channel: rel*}", automationstest.SeedOptions{})
	f.begin(t)
	f.bus.Publish(slackEvent("releases", 1), slackEvent("releases", 2))
	f.bus.Publish(slackEvent("releases", 3))
	f.flush(t, busCycleA)
	f.bus.Publish(slackEvent("releases", 4))
	if rep := f.flush(t, busCycleA); rep.Queued != 0 || rep.Merged != 0 || rep.Coalesced != 2 {
		t.Errorf("second flush of the cycle = %+v; want Coalesced 2 only", rep)
	}
	for _, auto := range []db.Automation{a, b} {
		p := payloadOf(t, f.onlyRun(t, auto))
		if len(p.Events) != 3 || p.Count != 3 || p.Truncated || !reflect.DeepEqual(p.Cycles, []string{busCycleA}) {
			t.Errorf("%s payload = %d events, count %d, truncated %v, cycles %v; want 3, 3, false, [A]",
				auto.Slug, len(p.Events), p.Count, p.Truncated, p.Cycles)
		}
	}
	var first map[string]any
	if err := json.Unmarshal(payloadOf(t, f.onlyRun(t, a)).Events[0], &first); err != nil {
		t.Fatal(err)
	}
	if first["type"] != "slack.new_messages" || first["channel"] != "releases" || first["count"] != float64(1) {
		t.Errorf("first event = %v; want the flat slack event with count 1", first)
	}
}

func TestBus_TruncatesAt100(t *testing.T) {
	f := newBusFixture(t)
	a := f.seed(t, "watch", "slack.new_messages", "{}", automationstest.SeedOptions{})
	f.begin(t)
	for i := range 150 {
		f.bus.Publish(slackEvent("releases", i))
	}
	f.flush(t, busCycleA)
	p := payloadOf(t, f.onlyRun(t, a))
	if len(p.Events) != automations.MaxEventsPerRun || p.Count != 150 || !p.Truncated {
		t.Fatalf("payload = %d events, count %d, truncated %v; want 100, 150, true", len(p.Events), p.Count, p.Truncated)
	}
	var last map[string]any
	if err := json.Unmarshal(p.Events[99], &last); err != nil {
		t.Fatal(err)
	}
	if last["count"] != float64(99) {
		t.Errorf("last kept event = %v; want the 100th published (count 99)", last)
	}
}

func TestBus_SecondCycleMergesIntoQueuedRun(t *testing.T) {
	f := newBusFixture(t)
	a := f.seed(t, "watch", "slack.new_messages", "{}", automationstest.SeedOptions{})
	f.begin(t)
	f.bus.Publish(slackEvent("releases", 1), slackEvent("releases", 2))
	f.flush(t, busCycleA)
	f.begin(t)
	f.bus.Publish(slackEvent("general", 3))
	if rep := f.flush(t, busCycleB); rep.Merged != 1 || rep.Queued != 0 {
		t.Errorf("cycle B report = %+v; want Merged 1", rep)
	}
	r := f.onlyRun(t, a)
	p := payloadOf(t, r)
	if r.EventCycle != busCycleA || !reflect.DeepEqual(p.Cycles, []string{busCycleA, busCycleB}) ||
		len(p.Events) != 3 || p.Count != 3 || p.Truncated {
		t.Errorf("run = event_cycle %q cycles %v, %d events, count %d, truncated %v; want A, [A B], 3, 3, false",
			r.EventCycle, p.Cycles, len(p.Events), p.Count, p.Truncated)
	}
	before := r.EventJSON
	f.bus.Publish(slackEvent("general", 4))
	if rep := f.flush(t, busCycleB); rep.Coalesced != 1 || rep.Merged != 0 {
		t.Errorf("repeated cycle B report = %+v; want Coalesced 1", rep)
	}
	if got := f.onlyRun(t, a).EventJSON; got != before {
		t.Errorf("repeated cycle B changed event_json: %s; want %s", got, before)
	}
}

func TestBus_MergeRaceWithClaimEnqueuesAgain(t *testing.T) {
	f := newBusFixture(t)
	a := f.seed(t, "watch", "slack.new_messages", "{}", automationstest.SeedOptions{})
	f.begin(t)
	f.bus.Publish(slackEvent("releases", 1))
	f.flush(t, busCycleA)
	first := f.onlyRun(t, a)
	automations.SetBusBeforeMerge(f.bus, func(runID int64) {
		if runID != first.ID {
			t.Errorf("merge into run %d; want %d", runID, first.ID)
		}
		if ok, err := f.d.ClaimAutomationRun(runID, a.ApprovalHash, "snapshot", 50000, 5, exStart); err != nil || !ok {
			t.Errorf("claim = %v, %v", ok, err)
		}
	})
	f.begin(t)
	f.bus.Publish(slackEvent("releases", 2))
	if rep := f.flush(t, busCycleB); rep.Queued != 1 || rep.Merged != 0 {
		t.Errorf("report = %+v; want Queued 1", rep)
	}
	runs := f.runs(t, a) // newest first
	if len(runs) != 2 || runs[0].Status != db.RunQueued || runs[0].EventCycle != busCycleB || runs[1].Status != db.RunRunning {
		t.Fatalf("runs = %+v; want a queued cycle-B run and the running cycle-A one", runs)
	}
	if p := payloadOf(t, runs[1]); !reflect.DeepEqual(p.Cycles, []string{busCycleA}) {
		t.Errorf("claimed run cycles = %v; want [A]", p.Cycles)
	}
}

func TestBus_NonMatchingAndNotRunnableQueueNothing(t *testing.T) {
	f := newBusFixture(t)
	mismatch := f.seed(t, "mismatch", "slack.new_messages", "{channel: general, account: work}", automationstest.SeedOptions{})
	unconfirmed := f.seed(t, "unconfirmed", "slack.new_messages", "{}", automationstest.SeedOptions{Unconfirmed: true})
	disabled := f.seed(t, "disabled", "slack.new_messages", "{}", automationstest.SeedOptions{Disabled: true})
	other := f.seed(t, "other", "gmail.new_messages", "{}", automationstest.SeedOptions{})
	broken := seedBrokenRecipe(t, f.d)
	f.begin(t)
	f.bus.Publish(slackEvent("releases", 1))
	if rep := f.flush(t, busCycleA); rep != (automations.FlushReport{}) {
		t.Errorf("report = %+v; want zero", rep)
	}
	for _, a := range []db.Automation{mismatch, unconfirmed, disabled, other, broken} {
		if runs := f.runs(t, a); len(runs) != 0 {
			t.Errorf("%s has %d runs; want none", a.Slug, len(runs))
		}
	}
	if f.wakeCount() != 0 {
		t.Errorf("wake called %d times; want 0", f.wakeCount())
	}
}

// seedBrokenRecipe indexes a recipe that fails to parse (its row carries a
// parse error) and tries to confirm and enable it.
func seedBrokenRecipe(t *testing.T, d *db.DB) db.Automation {
	t.Helper()
	ws := t.TempDir()
	dir := automations.PersonalDir(ws)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	text := strings.Replace(busRecipeText("slack.new_messages", "{}"), "slack.new_messages", "slack.nope", 1)
	if err := os.WriteFile(filepath.Join(dir, "broken.md"), []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := automations.NewIndexer(d, ws, automationstest.NewFakeClock(exStart)).RescanPersonal(context.Background()); err != nil {
		t.Fatal(err)
	}
	a, err := d.GetAutomationBySlug("personal", 0, "broken")
	if err != nil {
		t.Fatal(err)
	}
	if a.ParseError == "" {
		t.Fatal("broken recipe parsed")
	}
	_ = d.ConfirmAutomation(a.ID, a.ApprovalHash, exStart)
	_ = d.SetAutomationEnabled(a.ID, true, exStart)
	return *a
}

func TestBus_WantsOnlySubscribedTypes(t *testing.T) {
	f := newBusFixture(t)
	if f.bus.Wants("slack.new_messages") {
		t.Error("Wants before Begin = true")
	}
	f.seed(t, "watch", "slack.new_messages", "{}", automationstest.SeedOptions{})
	f.seed(t, "off", "jira.issue_changed", "{}", automationstest.SeedOptions{Disabled: true})
	f.begin(t)
	for typ, want := range map[string]bool{"slack.new_messages": true, "jira.issue_changed": false, "gmail.new_messages": false} {
		if got := f.bus.Wants(typ); got != want {
			t.Errorf("Wants(%s) = %v; want %v", typ, got, want)
		}
	}
}

func TestBus_BeginClearsPreviousCycle(t *testing.T) {
	f := newBusFixture(t)
	a := f.seed(t, "watch", "slack.new_messages", "{}", automationstest.SeedOptions{})
	f.begin(t)
	f.bus.Publish(slackEvent("releases", 1), slackEvent("releases", 2))
	f.begin(t) // a cycle that never flushed
	f.bus.Publish(slackEvent("releases", 3))
	f.flush(t, busCycleA)
	p := payloadOf(t, f.onlyRun(t, a))
	if len(p.Events) != 1 || p.Count != 1 {
		t.Errorf("payload = %d events, count %d; want only the event published after the second Begin", len(p.Events), p.Count)
	}
	if rep := f.flush(t, busCycleB); rep != (automations.FlushReport{}) {
		t.Errorf("flush with no new matches = %+v; want zero (matches cleared by the last flush)", rep)
	}
}

func TestBus_WakeCalledOnceWhenQueued(t *testing.T) {
	f := newBusFixture(t)
	f.seed(t, "first", "slack.new_messages", "{}", automationstest.SeedOptions{})
	f.seed(t, "second", "slack.new_messages", "{}", automationstest.SeedOptions{})
	f.begin(t)
	f.bus.Publish(slackEvent("releases", 1))
	f.flush(t, busCycleA)
	if f.wakeCount() != 1 {
		t.Errorf("wake called %d times after queueing two runs; want 1", f.wakeCount())
	}
	f.bus.Publish(slackEvent("releases", 2))
	f.flush(t, busCycleA) // already delivered: nothing queued or merged
	if f.wakeCount() != 1 {
		t.Errorf("wake called %d times after a no-op flush; want 1", f.wakeCount())
	}
}

func TestBus_WakeNotCalledWhenNothingQueued(t *testing.T) {
	f := newBusFixture(t)
	f.seed(t, "watch", "slack.new_messages", "{channel: general}", automationstest.SeedOptions{})
	f.begin(t)
	f.bus.Publish(slackEvent("releases", 1))
	f.flush(t, busCycleA)
	if f.wakeCount() != 0 {
		t.Errorf("wake called %d times; want 0", f.wakeCount())
	}
}

func TestBus_PublishIsSafeForConcurrentCallers(t *testing.T) {
	f := newBusFixture(t)
	a := f.seed(t, "watch", "slack.new_messages", "{}", automationstest.SeedOptions{})
	f.begin(t)
	var wg sync.WaitGroup
	for i := range 8 {
		wg.Go(func() {
			for j := range 20 {
				f.bus.Publish(slackEvent("releases", i*20+j))
			}
			_ = f.bus.Wants("slack.new_messages")
		})
	}
	wg.Wait()
	f.flush(t, busCycleA)
	if p := payloadOf(t, f.onlyRun(t, a)); p.Count != 160 || len(p.Events) != automations.MaxEventsPerRun {
		t.Errorf("payload = %d events, count %d; want 100, 160", len(p.Events), p.Count)
	}
}
