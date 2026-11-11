package automations_test

import (
	"context"
	"fmt"
	"log"
	"strings"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/db"
)

// A Power Nap dark wake (board #877): the Mac is awake for seconds with CPU
// and network but no graphics, and work started then hangs. The scheduler
// holds its ticks and the executor claims nothing until full wake.

const darkWakeLog = "dark wake (Power Nap, caps 0x0d), holding the schedule until full wake"

// boolProbe is a full-wake probe over b with the capability bits of a real
// read: 0x0f (CPU, graphics, audio, network) awake, 0x0d (no graphics) dark.
func boolProbe(b *atomic.Bool) func() (uint32, bool) {
	return func() (uint32, bool) {
		if b.Load() {
			return 0x0f, true
		}
		return 0x0d, false
	}
}

// darkWakeRun starts s.Run over clock and returns a stop func.
func darkWakeRun(t *testing.T, s *automations.Scheduler) (stop func()) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- s.Run(ctx) }()
	return func() {
		cancel()
		if err := <-done; err != nil {
			t.Errorf("Run = %v, want nil after cancel", err)
		}
	}
}

func TestScheduler_DarkWakeHoldsTheSchedule(t *testing.T) {
	cases := []struct {
		name    string
		missed  string
		wakeAt  time.Duration // full wake, after 09:00
		trigger string        // "" = no run
	}{
		{"full wake within grace runs on time", "run_once", time.Minute, db.TriggerSchedule},
		{"full wake past grace catches up once", "run_once", 10 * time.Minute, db.TriggerCatchUp},
		{"full wake past grace with skip runs none", "skip", 10 * time.Minute, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newSchedFixture(t, time.Time{})
			nine := f.at(14, 9, 0) // everything runs on the fake clock
			f.clock.Set(f.at(14, 8, 0))
			a := f.seed(t, "morning", "0 9 * * *", tc.missed)
			lastBefore := f.get(t, a.ID).LastScheduledFor

			var awake atomic.Bool
			logs := &syncBuffer{}
			clock := &stepClock{now: nine.Add(30 * time.Second), calls: make(chan time.Duration, 4), fire: make(chan time.Time)}
			s := zoned(automations.NewScheduler(f.d, f.ix, clock, nil), f.loc)
			s.SetLogger(log.New(logs, "", 0))
			s.SetFullWakeProbe(boolProbe(&awake))
			stop := darkWakeRun(t, s)
			defer stop()

			clock.waitAfter(t) // the start tick, in a dark wake
			clock.set(nine.Add(time.Minute))
			clock.fire <- clock.Now()
			clock.waitAfter(t) // a second dark tick
			wantRunCount(t, f.runs(t, a.ID), 0)
			got := f.get(t, a.ID)
			if !sameTime(got.LastScheduledFor, lastBefore) {
				t.Fatalf("last_scheduled_for moved in a dark wake: %v, was %v", got.LastScheduledFor, lastBefore)
			}
			if n := strings.Count(logs.String(), darkWakeLog); n != 1 {
				t.Fatalf("dark wake logged %d times over two ticks; want once:\n%s", n, logs.String())
			}

			awake.Store(true)
			clock.set(nine.Add(tc.wakeAt))
			clock.fire <- clock.Now()
			clock.waitAfter(t) // the full-wake tick
			rs := f.runs(t, a.ID)
			if tc.trigger == "" {
				wantRunCount(t, rs, 0)
			} else {
				wantRunCount(t, rs, 1)
				wantRun(t, rs[0], tc.trigger, nine)
			}
			wantTime(t, "last_scheduled_for", f.get(t, a.ID).LastScheduledFor, nine)
			// Held from the start tick (09:00:30) to the full-wake tick.
			mustContain(t, "log", logs.String(), fmt.Sprintf("automations: full wake (caps 0x0f), schedule resumed after ~%s",
				tc.wakeAt-30*time.Second))
		})
	}
}

// TestScheduler_DarkWakeLogsOncePerDeferral: a second dark wake after a full
// wake is logged again.
func TestScheduler_DarkWakeLogsOncePerDeferral(t *testing.T) {
	f := newSchedFixture(t, time.Time{})
	var awake atomic.Bool
	logs := &syncBuffer{}
	clock := &stepClock{now: f.at(14, 8, 0).Add(30 * time.Second), calls: make(chan time.Duration, 4), fire: make(chan time.Time)}
	s := zoned(automations.NewScheduler(f.d, f.ix, clock, nil), f.loc)
	s.SetLogger(log.New(logs, "", 0))
	s.SetFullWakeProbe(boolProbe(&awake))
	stop := darkWakeRun(t, s)
	defer stop()
	clock.waitAfter(t) // dark
	for _, a := range []bool{true, false, false} {
		awake.Store(a)
		clock.fire <- clock.Now()
		clock.waitAfter(t)
	}
	if n := strings.Count(logs.String(), darkWakeLog); n != 2 {
		t.Fatalf("dark wake logged %d times over two dark wakes; want 2:\n%s", n, logs.String())
	}
	if n := strings.Count(logs.String(), "schedule resumed after"); n != 1 {
		t.Fatalf("full wake logged %d times over one full wake; want 1:\n%s", n, logs.String())
	}
}

// TestScheduler_NilProbeRestoresAlwaysAwake: SetFullWakeProbe(nil) after a
// dark probe puts the default back, so the start tick runs (no hold).
func TestScheduler_NilProbeRestoresAlwaysAwake(t *testing.T) {
	f := newSchedFixture(t, time.Time{})
	logs := &syncBuffer{}
	clock := &stepClock{now: f.at(14, 8, 0).Add(30 * time.Second), calls: make(chan time.Duration, 4), fire: make(chan time.Time)}
	s := zoned(automations.NewScheduler(f.d, f.ix, clock, nil), f.loc)
	s.SetLogger(log.New(logs, "", 0))
	var dark atomic.Bool // false: the probe reports a dark wake
	s.SetFullWakeProbe(boolProbe(&dark))
	s.SetFullWakeProbe(nil)
	stop := darkWakeRun(t, s)
	defer stop()
	clock.waitAfter(t) // the start tick
	if strings.Contains(logs.String(), "dark wake") {
		t.Fatalf("a nil probe still held the schedule:\n%s", logs.String())
	}
}

func sameTime(a, b *time.Time) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return a.Equal(*b)
}

func TestExecutor_NoClaimsInDarkWake(t *testing.T) {
	var awake atomic.Bool
	f := newExFixture(t, exOpts{fullWake: boolProbe(&awake)})
	id := f.enqueue(t, f.seed(t, "digest", `return 1`, false), db.TriggerManual)
	unconfirmed := f.enqueue(t, f.seed(t, "draft", `return 1`, true), db.TriggerManual)
	f.step(t, 0)
	f.step(t, 0)
	f.wantRun(t, id, db.RunQueued, "")
	f.wantRun(t, unconfirmed, db.RunCancelled, db.ErrKindNotRunnable) // still cancelled in a dark wake
	if n := strings.Count(f.logs.String(), "dark wake (Power Nap, caps 0x0d), no run is claimed until full wake"); n != 1 {
		t.Fatalf("dark wake logged %d times over two polls; want once:\n%s", n, f.logs.String())
	}
	awake.Store(true)
	f.step(t, 1)
	f.wantRun(t, id, db.RunSucceeded, "")
	mustContain(t, "log", f.logs.String(), "full wake (caps 0x0f); claiming again")
}

// TestExecutor_DarkWakeDoesNotResumeKeptRun: a waiting run the previous
// daemon kept for a resume is resumed only at full wake.
func TestExecutor_DarkWakeDoesNotResumeKeptRun(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var awake atomic.Bool
		awake.Store(true)
		w := newWriteFixtureOpts(t, exOpts{fullWake: boolProbe(&awake)})
		a := w.seedWorkbenchOutput(t, "deploy", []string{"ask:owner"}, "inbox",
			`const r = `+resumeAskCall+`; return JSON.stringify(r)`)
		id := w.enqueue(t, a, db.TriggerManual)
		w.stopWhileWaiting(t, id)

		w.restart()
		awake.Store(false)
		if !automations.ExecutorMarkInterrupted(context.Background(), w.e) {
			t.Fatal("the restart sweep did not run")
		}
		kept, err := w.d.NextResumePendingAutomationRuns()
		if err != nil || len(kept) != 1 || kept[0].ID != id {
			t.Fatalf("runs kept for a resume = %+v, %v; want run %d", kept, err, id)
		}
		w.step(t, 0) // a dark-wake poll starts nothing
		w.step(t, 0)
		if r := w.run(t, id); r.Status != db.RunWaiting {
			t.Fatalf("run in a dark wake = %s; want still waiting", r.Status)
		}
		if kept, err := w.d.NextResumePendingAutomationRuns(); err != nil || len(kept) != 1 {
			t.Fatalf("runs kept for a resume after the dark polls = %d, %v; want 1", len(kept), err)
		}

		awake.Store(true)
		stop := runExecutor(t, w.exFixture)
		defer stop()
		waitLog(t, w.logs, "resumed after restart")
	})
}

// waitLog lets the test's synctest bubble settle and wants logs to contain
// want then. Bubble only.
func waitLog(t *testing.T, logs *syncBuffer, want string) {
	t.Helper()
	synctest.Wait()
	if !strings.Contains(logs.String(), want) {
		t.Fatalf("log does not contain %q once settled:\n%s", want, logs.String())
	}
}
