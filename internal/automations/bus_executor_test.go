package automations_test

import (
	"io"
	"log"
	"strings"
	"testing"

	"watchtower/internal/automations"
	"watchtower/internal/db"
)

// busExecFixture couples a bus to an executor fixture on the same database,
// pinning that what Flush writes is what the executor decodes into trigger.
type busExecFixture struct {
	*exFixture
	bus *automations.Bus
}

func newBusExecFixture(t *testing.T) *busExecFixture {
	t.Helper()
	f := newExFixture(t, exOpts{})
	return &busExecFixture{exFixture: f, bus: automations.NewBus(f.d, f.clock, func() {}, log.New(io.Discard, "", 0))}
}

// seedEvent seeds an event automation on slack.new_messages returning script.
func (f *busExecFixture) seedEvent(t *testing.T, slug, script string) db.Automation {
	t.Helper()
	text := strings.Replace(exRecipeText(script, ""), "  manual: true\n",
		"  event:\n    type: slack.new_messages\n    where: {channel: releases}\n", 1)
	return f.seedText(t, slug, text, false)
}

// cycle runs one bus cycle: Begin, Publish events, Flush cycleID.
func (f *busExecFixture) cycle(t *testing.T, cycleID string, events ...automations.Event) automations.FlushReport {
	t.Helper()
	if err := f.bus.Begin(); err != nil {
		t.Fatalf("Begin: %v", err)
	}
	f.bus.Publish(events...)
	rep, err := f.bus.Flush(cycleID)
	if err != nil {
		t.Fatalf("Flush(%s): %v", cycleID, err)
	}
	return rep
}

// onlyRunID returns a's single run id.
func (f *busExecFixture) onlyRunID(t *testing.T, a db.Automation) int64 {
	t.Helper()
	runs, err := f.d.ListAutomationRuns(a.ID, 0)
	if err != nil || len(runs) != 1 {
		t.Fatalf("automation %s runs = %d, %v; want 1", a.Slug, len(runs), err)
	}
	return runs[0].ID
}

func TestBus_FlushedRunDecodesInExecutor(t *testing.T) {
	f := newBusExecFixture(t)
	a := f.seedEvent(t, "watch", `return trigger.events.length + ":" + trigger.events[0].channel + ":" + trigger.truncated`)
	if rep := f.cycle(t, busCycleA, slackEvent("releases", 1), slackEvent("releases", 2)); rep.Queued != 1 {
		t.Fatalf("report = %+v; want Queued 1", rep)
	}
	id := f.onlyRunID(t, a)
	f.step(t, 1)
	if r := f.wantRun(t, id, db.RunSucceeded, ""); r.Summary != "2:releases:false" {
		t.Fatalf("summary = %q; want 2:releases:false", r.Summary)
	}
}

func TestBus_MergedAndTruncatedRunDecodesInExecutor(t *testing.T) {
	f := newBusExecFixture(t)
	a := f.seedEvent(t, "watch", `return trigger.events.length + ":" + trigger.truncated`)
	batch := func(from, n int) []automations.Event {
		evs := make([]automations.Event, 0, n)
		for i := range n {
			evs = append(evs, slackEvent("releases", from+i))
		}
		return evs
	}
	if rep := f.cycle(t, busCycleA, batch(0, 75)...); rep.Queued != 1 {
		t.Fatalf("cycle A report = %+v; want Queued 1", rep)
	}
	if rep := f.cycle(t, busCycleB, batch(75, 75)...); rep.Merged != 1 || rep.Queued != 0 {
		t.Fatalf("cycle B report = %+v; want Merged 1", rep)
	}
	id := f.onlyRunID(t, a)
	f.step(t, 1)
	if r := f.wantRun(t, id, db.RunSucceeded, ""); r.Summary != "100:true" {
		t.Fatalf("summary = %q; want 100:true", r.Summary)
	}
}
