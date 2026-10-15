package automations_test

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/db"
)

const schedRecipe = `---
name: Scheduled check
trigger:
  schedule: "CRON"
missed: MISSED
permissions:
  - llm:light
outputs: [inbox]
---
Checks something on a schedule.

` + "```js\nlog(\"tick\")\n```\n"

func loadZone(t *testing.T, name string) *time.Location {
	t.Helper()
	loc, err := time.LoadLocation(name)
	if err != nil {
		t.Fatalf("load %s: %v", name, err)
	}
	return loc
}

// zoned returns s with its local zone fixed to loc.
func zoned(s *automations.Scheduler, loc *time.Location) *automations.Scheduler {
	automations.SetSchedulerZone(s, func() *time.Location { return loc })
	return s
}

type schedFixture struct {
	d     *db.DB
	ix    *automations.Indexer
	clock *automationstest.FakeClock
	dir   string
	loc   *time.Location
	s     *automations.Scheduler

	mu    sync.Mutex
	wakes int
}

func newSchedFixture(t *testing.T, start time.Time) *schedFixture {
	t.Helper()
	loc := loadZone(t, "Europe/Berlin")
	ws := t.TempDir()
	d := db.OpenTestDB(t)
	clock := automationstest.NewFakeClock(start)
	f := &schedFixture{d: d, clock: clock, dir: automations.PersonalDir(ws), loc: loc}
	f.ix = automations.NewIndexer(d, ws, clock)
	f.s = f.newScheduler()
	return f
}

// newScheduler returns a fresh Scheduler (a daemon restart) over the fixture.
func (f *schedFixture) newScheduler() *automations.Scheduler {
	return zoned(automations.NewScheduler(f.d, f.ix, f.clock, func() {
		f.mu.Lock()
		f.wakes++
		f.mu.Unlock()
	}), f.loc)
}

func (f *schedFixture) wakeCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.wakes
}

func (f *schedFixture) at(day, hour, minute int) time.Time {
	return time.Date(2026, 10, day, hour, minute, 0, 0, f.loc)
}

func (f *schedFixture) writeRecipe(t *testing.T, slug, cronExpr, missed string) {
	t.Helper()
	if err := os.MkdirAll(f.dir, 0o755); err != nil {
		t.Fatal(err)
	}
	text := strings.NewReplacer("CRON", cronExpr, "MISSED", missed).Replace(schedRecipe)
	if err := os.WriteFile(filepath.Join(f.dir, slug+".md"), []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

func (f *schedFixture) indexed(t *testing.T, slug string) db.Automation {
	t.Helper()
	if _, err := f.ix.RescanPersonal(context.Background()); err != nil {
		t.Fatalf("rescan: %v", err)
	}
	a, err := f.d.GetAutomationBySlug("personal", 0, slug)
	if err != nil {
		t.Fatalf("get %s: %v", slug, err)
	}
	return *a
}

// seed indexes, confirms and enables a schedule recipe at the clock's now.
func (f *schedFixture) seed(t *testing.T, slug, cronExpr, missed string) db.Automation {
	t.Helper()
	f.writeRecipe(t, slug, cronExpr, missed)
	a := f.indexed(t, slug)
	now := f.clock.Now()
	if err := f.d.ConfirmAutomation(a.ID, a.ApprovalHash, now); err != nil {
		t.Fatalf("confirm: %v", err)
	}
	if err := f.d.SetAutomationEnabled(a.ID, true, now); err != nil {
		t.Fatalf("enable: %v", err)
	}
	return f.get(t, a.ID)
}

func (f *schedFixture) get(t *testing.T, id int64) db.Automation {
	t.Helper()
	a, err := f.d.GetAutomation(id)
	if err != nil {
		t.Fatalf("get automation %d: %v", id, err)
	}
	return *a
}

func (f *schedFixture) setLast(t *testing.T, id int64, last time.Time) {
	t.Helper()
	if err := f.d.SetAutomationSchedule(id, &last, nil); err != nil {
		t.Fatalf("set schedule: %v", err)
	}
}

func (f *schedFixture) tick(t *testing.T, now time.Time) {
	t.Helper()
	f.tickWith(t, f.s, now)
}

func (f *schedFixture) tickWith(t *testing.T, s *automations.Scheduler, now time.Time) {
	t.Helper()
	f.clock.Set(now)
	if err := s.Tick(context.Background(), now); err != nil {
		t.Fatalf("Tick(%s): %v", now, err)
	}
}

// runs returns the automation's runs, oldest first.
func (f *schedFixture) runs(t *testing.T, id int64) []db.AutomationRun {
	t.Helper()
	rs, err := f.d.ListAutomationRuns(id, 0)
	if err != nil {
		t.Fatalf("list runs: %v", err)
	}
	slices.Reverse(rs)
	return rs
}

// settle cancels every queued run of the automation, as if the executor had
// consumed it, so a later duplicate would insert instead of coalescing.
func (f *schedFixture) settle(t *testing.T, id int64) {
	t.Helper()
	for _, r := range f.runs(t, id) {
		if r.Status != db.RunQueued {
			continue
		}
		if _, err := f.d.CancelAutomationRun(r.ID, f.clock.Now()); err != nil {
			t.Fatalf("cancel run %d: %v", r.ID, err)
		}
	}
}

func wantRun(t *testing.T, r db.AutomationRun, trigger string, scheduledFor time.Time) {
	t.Helper()
	if r.Trigger != trigger {
		t.Errorf("run %d trigger = %q, want %q", r.ID, r.Trigger, trigger)
	}
	if r.ScheduledFor == nil || !r.ScheduledFor.Equal(scheduledFor) {
		t.Errorf("run %d scheduled_for = %v, want %s", r.ID, r.ScheduledFor, scheduledFor)
	}
	if r.Status != db.RunQueued {
		t.Errorf("run %d status = %q, want queued", r.ID, r.Status)
	}
}

func wantTime(t *testing.T, what string, got *time.Time, want time.Time) {
	t.Helper()
	if got == nil || !got.Equal(want) {
		t.Errorf("%s = %v, want %s", what, got, want)
	}
}

func wantRunCount(t *testing.T, rs []db.AutomationRun, n int) {
	t.Helper()
	if len(rs) != n {
		t.Fatalf("runs = %d, want %d: %+v", len(rs), n, rs)
	}
}

func TestScheduler_OnTimeWithinGrace(t *testing.T) {
	f := newSchedFixture(t, time.Time{})
	f.clock.Set(f.at(14, 8, 0))
	a := f.seed(t, "morning", "0 9 * * *", "run_once")
	f.tick(t, f.at(14, 9, 1))
	rs := f.runs(t, a.ID)
	wantRunCount(t, rs, 1)
	wantRun(t, rs[0], db.TriggerSchedule, f.at(14, 9, 0))
	got := f.get(t, a.ID)
	wantTime(t, "last_scheduled_for", got.LastScheduledFor, f.at(14, 9, 0))
	wantTime(t, "next_run_at", got.NextRunAt, f.at(15, 9, 0))
	if f.wakeCount() != 1 {
		t.Errorf("wake calls = %d, want 1", f.wakeCount())
	}
}

func TestScheduler_GraceBoundary(t *testing.T) {
	cases := []struct {
		name    string
		late    time.Duration
		trigger string
	}{
		{"exactly on time", 0, db.TriggerSchedule},
		{"two minutes late", 2 * time.Minute, db.TriggerSchedule},
		{"just past grace", 2*time.Minute + time.Second, db.TriggerCatchUp},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newSchedFixture(t, time.Time{})
			f.clock.Set(f.at(14, 8, 0))
			a := f.seed(t, "morning", "0 9 * * *", "run_once")
			f.tick(t, f.at(14, 9, 0).Add(tc.late))
			rs := f.runs(t, a.ID)
			wantRunCount(t, rs, 1)
			wantRun(t, rs[0], tc.trigger, f.at(14, 9, 0))
		})
	}
}

func TestAuto10_SleepAcrossTwoDueTimesRunsOnceCatchUp(t *testing.T) {
	f := newSchedFixture(t, time.Time{})
	f.clock.Set(f.at(14, 7, 0))
	a := f.seed(t, "twice", "0 9,17 * * *", "run_once")
	f.setLast(t, a.ID, f.at(14, 8, 0))
	f.tick(t, f.at(15, 8, 0))
	rs := f.runs(t, a.ID)
	wantRunCount(t, rs, 1)
	wantRun(t, rs[0], db.TriggerCatchUp, f.at(14, 17, 0))
	got := f.get(t, a.ID)
	wantTime(t, "last_scheduled_for", got.LastScheduledFor, f.at(14, 17, 0))
	wantTime(t, "next_run_at", got.NextRunAt, f.at(15, 9, 0))
}

func TestAuto10_SkipPolicyRunsNone(t *testing.T) {
	f := newSchedFixture(t, time.Time{})
	f.clock.Set(f.at(14, 7, 0))
	a := f.seed(t, "twice", "0 9,17 * * *", "skip")
	f.setLast(t, a.ID, f.at(14, 8, 0))
	f.tick(t, f.at(15, 8, 0))
	wantRunCount(t, f.runs(t, a.ID), 0)
	got := f.get(t, a.ID)
	wantTime(t, "last_scheduled_for", got.LastScheduledFor, f.at(14, 17, 0))
	wantTime(t, "next_run_at", got.NextRunAt, f.at(15, 9, 0))
	if f.wakeCount() != 0 {
		t.Errorf("wake calls = %d, want 0", f.wakeCount())
	}
}

func TestAuto10_RestartDoesNotRepeatCatchUp(t *testing.T) {
	f := newSchedFixture(t, time.Time{})
	f.clock.Set(f.at(14, 7, 0))
	a := f.seed(t, "twice", "0 9,17 * * *", "run_once")
	f.setLast(t, a.ID, f.at(14, 8, 0))
	now := f.at(15, 8, 0)
	f.tick(t, now)
	// The executor consumed the catch-up; the daemon restarts at the same now.
	f.settle(t, a.ID)
	f.tickWith(t, f.newScheduler(), now)
	f.tickWith(t, f.newScheduler(), now.Add(time.Minute))
	wantRunCount(t, f.runs(t, a.ID), 1)
}

func TestScheduler_NewAndReenabledDoNotCatchUp(t *testing.T) {
	f := newSchedFixture(t, time.Time{})
	f.clock.Set(f.at(14, 10, 0))
	a := f.seed(t, "morning", "0 9 * * *", "run_once")
	f.tick(t, f.at(14, 10, 1))
	wantRunCount(t, f.runs(t, a.ID), 0)

	if err := f.d.SetAutomationEnabled(a.ID, false, f.at(14, 10, 5)); err != nil {
		t.Fatal(err)
	}
	f.tick(t, f.at(15, 9, 0)) // disabled: not considered
	if err := f.d.SetAutomationEnabled(a.ID, true, f.at(16, 10, 5)); err != nil {
		t.Fatal(err)
	}
	f.tick(t, f.at(16, 10, 6))
	wantRunCount(t, f.runs(t, a.ID), 0)

	// Not stalled: the next due time fires on time.
	f.tick(t, f.at(17, 9, 0))
	rs := f.runs(t, a.ID)
	wantRunCount(t, rs, 1)
	wantRun(t, rs[0], db.TriggerSchedule, f.at(17, 9, 0))
}

func TestScheduler_UnconfirmedNeverQueued(t *testing.T) {
	f := newSchedFixture(t, time.Time{})
	f.clock.Set(f.at(14, 8, 0))
	f.writeRecipe(t, "morning", "0 9 * * *", "run_once")
	a := f.indexed(t, "morning")
	if err := f.d.SetAutomationEnabled(a.ID, true, f.clock.Now()); err != nil {
		t.Fatal(err)
	}
	f.tick(t, f.at(14, 9, 0))
	f.tick(t, f.at(15, 9, 0))
	wantRunCount(t, f.runs(t, a.ID), 0)
	if f.wakeCount() != 0 {
		t.Errorf("wake calls = %d, want 0", f.wakeCount())
	}
}

func TestScheduler_CoalescesWhileQueued(t *testing.T) {
	f := newSchedFixture(t, time.Time{})
	f.clock.Set(f.at(14, 8, 0))
	a := f.seed(t, "hourly", "0 9,10 * * *", "run_once")
	f.tick(t, f.at(14, 9, 0))
	f.tick(t, f.at(14, 10, 0)) // the 09:00 run is still queued
	rs := f.runs(t, a.ID)
	wantRunCount(t, rs, 1)
	wantRun(t, rs[0], db.TriggerSchedule, f.at(14, 9, 0))
	wantTime(t, "last_scheduled_for", f.get(t, a.ID).LastScheduledFor, f.at(14, 10, 0))
	if f.wakeCount() != 1 {
		t.Errorf("wake calls = %d, want 1 (a coalesced tick inserts nothing)", f.wakeCount())
	}
}

func TestScheduler_ClockBackwardsNoDuplicate(t *testing.T) {
	f := newSchedFixture(t, time.Time{})
	f.clock.Set(f.at(14, 8, 0))
	a := f.seed(t, "morning", "0 9 * * *", "run_once")
	f.tick(t, f.at(14, 9, 0))
	f.settle(t, a.ID)

	f.tick(t, f.at(14, 8, 30)) // the clock steps back half an hour
	wantTime(t, "last_scheduled_for", f.get(t, a.ID).LastScheduledFor, f.at(14, 9, 0))
	f.tick(t, f.at(14, 9, 0)) // 09:00 again
	f.tick(t, f.at(14, 9, 1))
	wantRunCount(t, f.runs(t, a.ID), 1)

	f.tick(t, f.at(15, 9, 0))
	rs := f.runs(t, a.ID)
	wantRunCount(t, rs, 2)
	wantRun(t, rs[1], db.TriggerSchedule, f.at(15, 9, 0))
}

func TestScheduler_ClockJumps(t *testing.T) {
	t.Run("forward three days runs one catch-up", func(t *testing.T) {
		f := newSchedFixture(t, time.Time{})
		f.clock.Set(f.at(14, 8, 0))
		a := f.seed(t, "morning", "0 9 * * *", "run_once")
		f.tick(t, f.at(17, 12, 0))
		rs := f.runs(t, a.ID)
		wantRunCount(t, rs, 1)
		wantRun(t, rs[0], db.TriggerCatchUp, f.at(17, 9, 0))
	})
	t.Run("far backwards re-primes instead of stalling", func(t *testing.T) {
		f := newSchedFixture(t, time.Time{})
		f.clock.Set(f.at(14, 8, 0))
		a := f.seed(t, "morning", "0 9 * * *", "run_once")
		// The clock ran two days ahead and advanced the schedule there.
		f.tick(t, f.at(16, 9, 0))
		f.settle(t, a.ID)
		// Corrected back: no run, and the schedule restarts from now.
		f.tick(t, f.at(14, 8, 30))
		wantRunCount(t, f.runs(t, a.ID), 1)
		got := f.get(t, a.ID)
		wantTime(t, "last_scheduled_for", got.LastScheduledFor, f.at(14, 8, 30))
		wantTime(t, "next_run_at", got.NextRunAt, f.at(14, 9, 0))
		f.tick(t, f.at(14, 9, 0))
		rs := f.runs(t, a.ID)
		wantRunCount(t, rs, 2)
		wantRun(t, rs[1], db.TriggerSchedule, f.at(14, 9, 0))
	})
}

// tickEveryMinute ticks from..to (inclusive) once a minute, settling after
// each tick, and returns the runs created.
func (f *schedFixture) tickEveryMinute(t *testing.T, id int64, from, to time.Time) []db.AutomationRun {
	t.Helper()
	for now := from; !now.After(to); now = now.Add(time.Minute) {
		f.tick(t, now)
		f.settle(t, id)
	}
	return f.runs(t, id)
}

func scheduledTimes(rs []db.AutomationRun, loc *time.Location) []string {
	out := make([]string, 0, len(rs))
	for _, r := range rs {
		if r.ScheduledFor != nil {
			out = append(out, r.ScheduledFor.In(loc).Format("01-02 15:04 MST"))
		}
	}
	return out
}

func TestScheduler_DSTTransition(t *testing.T) {
	// Europe/Berlin 2026: spring forward 03-29 02:00 CET → 03:00 CEST;
	// fall back 10-25 03:00 CEST → 02:00 CET.
	cases := []struct {
		name     string
		cron     string
		start    [3]int // month, day, hour (local) of the last scheduled point
		from, to [3]int // month, day, hour of the ticking window
		want     []string
	}{
		{"spring forward fixed time fires once at the jump", "30 2 * * *",
			[3]int{3, 28, 3}, [3]int{3, 29, 0}, [3]int{3, 30, 0}, []string{"03-29 03:00 CEST"}},
		{"fall back fixed time fires once", "30 2 * * *",
			[3]int{10, 24, 3}, [3]int{10, 25, 0}, [3]int{10, 26, 0}, []string{"10-25 02:30 CEST"}},
		{"fall back fixed hour range fires once per wall time", "*/30 2 * * *",
			[3]int{10, 24, 3}, [3]int{10, 25, 0}, [3]int{10, 25, 6},
			[]string{"10-25 02:00 CEST", "10-25 02:30 CEST"}},
		{"spring forward hourly follows elapsed time", "0 * * * *",
			[3]int{3, 29, 0}, [3]int{3, 29, 0}, [3]int{3, 29, 5},
			[]string{"03-29 01:00 CET", "03-29 03:00 CEST", "03-29 04:00 CEST", "03-29 05:00 CEST"}},
		{"fall back hourly follows elapsed time", "0 * * * *",
			[3]int{10, 25, 0}, [3]int{10, 25, 0}, [3]int{10, 25, 4},
			[]string{"10-25 01:00 CEST", "10-25 02:00 CEST", "10-25 02:00 CET", "10-25 03:00 CET", "10-25 04:00 CET"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newSchedFixture(t, time.Time{})
			local := func(v [3]int) time.Time {
				return time.Date(2026, time.Month(v[0]), v[1], v[2], 0, 0, 0, f.loc)
			}
			f.clock.Set(local(tc.start))
			a := f.seed(t, "nightly", tc.cron, "run_once")
			// Walk minute by minute in real time; the fall-back hour is lived twice.
			rs := f.tickEveryMinute(t, a.ID, local(tc.from).Add(time.Minute), local(tc.to))
			if got := scheduledTimes(rs, f.loc); !slices.Equal(got, tc.want) {
				t.Errorf("scheduled = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestScheduler_DSTSleepOverGapCatchesUpOnce(t *testing.T) {
	f := newSchedFixture(t, time.Time{})
	f.clock.Set(time.Date(2026, 3, 28, 3, 0, 0, 0, f.loc))
	a := f.seed(t, "nightly", "30 2 * * *", "run_once")
	f.tick(t, time.Date(2026, 3, 29, 10, 0, 0, 0, f.loc))
	rs := f.runs(t, a.ID)
	wantRunCount(t, rs, 1)
	wantRun(t, rs[0], db.TriggerCatchUp, time.Date(2026, 3, 29, 3, 0, 0, 0, f.loc))
	wantTime(t, "next_run_at", f.get(t, a.ID).NextRunAt, time.Date(2026, 3, 30, 2, 30, 0, 0, f.loc))
}

func TestAuto09_SchedulerOnlyQueues(t *testing.T) {
	f := newSchedFixture(t, time.Time{})
	f.clock.Set(f.at(14, 8, 0))
	a := f.seed(t, "twice", "0 9,17 * * *", "run_once")
	f.tick(t, f.at(14, 9, 0))
	f.tick(t, f.at(15, 8, 0))
	f.tick(t, f.at(15, 9, 0))
	rs := f.runs(t, a.ID)
	if len(rs) == 0 {
		t.Fatal("no runs queued")
	}
	for _, r := range rs {
		if r.Status != db.RunQueued || r.StartedAt != nil || r.RecipeSnapshot != "" {
			t.Errorf("run %d status=%q started_at=%v snapshot=%d bytes, want queued and never claimed",
				r.ID, r.Status, r.StartedAt, len(r.RecipeSnapshot))
		}
		steps, err := f.d.ListAutomationRunSteps(r.ID)
		if err != nil {
			t.Fatal(err)
		}
		if len(steps) != 0 {
			t.Errorf("run %d has %d steps, want 0", r.ID, len(steps))
		}
	}
}

func TestScheduler_TickRescansChangedPersonalFolder(t *testing.T) {
	f := newSchedFixture(t, time.Time{})
	f.clock.Set(f.at(14, 8, 0))
	f.tick(t, f.at(14, 8, 0))
	f.writeRecipe(t, "late-added", "0 9 * * *", "run_once")
	f.tick(t, f.at(14, 8, 1))
	a, err := f.d.GetAutomationBySlug("personal", 0, "late-added")
	if err != nil {
		t.Fatalf("tick did not index the new recipe: %v", err)
	}
	wantTime(t, "last_scheduled_for", a.LastScheduledFor, f.at(14, 8, 1))
}

// stepClock is a Clock whose After calls the test observes and fires.
type stepClock struct {
	mu    sync.Mutex
	now   time.Time
	calls chan time.Duration
	fire  chan time.Time
}

func (c *stepClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *stepClock) set(t time.Time) {
	c.mu.Lock()
	c.now = t
	c.mu.Unlock()
}

func (c *stepClock) After(d time.Duration) <-chan time.Time {
	c.calls <- d
	return c.fire
}

func (c *stepClock) waitAfter(t *testing.T) time.Duration {
	t.Helper()
	select {
	case d := <-c.calls:
		return d
	case <-time.After(5 * time.Second):
		t.Fatal("scheduler did not wait on the clock")
		return 0
	}
}

func TestScheduler_RunTicksAtMinuteBoundaryAndOnWake(t *testing.T) {
	f := newSchedFixture(t, time.Time{})
	f.clock.Set(f.at(14, 8, 0))
	a := f.seed(t, "morning", "0 9 * * *", "run_once")
	clock := &stepClock{now: f.at(14, 8, 59).Add(30 * time.Second), calls: make(chan time.Duration, 4), fire: make(chan time.Time)}
	s := zoned(automations.NewScheduler(f.d, f.ix, clock, nil), f.loc)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- s.Run(ctx) }()

	if d := clock.waitAfter(t); d != 30*time.Second {
		t.Errorf("first wait = %s, want 30s to the minute boundary", d)
	}
	clock.set(f.at(14, 9, 0))
	clock.fire <- f.at(14, 9, 0)
	if d := clock.waitAfter(t); d != time.Minute {
		t.Errorf("second wait = %s, want 1m", d)
	}
	wantRunCount(t, f.runs(t, a.ID), 1)

	s.Wake()
	clock.waitAfter(t) // a wake ticks at once, then waits again
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Errorf("Run = %v, want nil after cancel", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Run did not return after cancel")
	}
}

func TestScheduler_NeverDueScheduleQueuesNothing(t *testing.T) {
	f := newSchedFixture(t, time.Time{})
	f.clock.Set(f.at(14, 8, 0))
	a := f.seed(t, "leap", "0 0 30 2 *", "run_once") // February 30th never comes
	f.tick(t, f.at(20, 8, 0))
	wantRunCount(t, f.runs(t, a.ID), 0)
	if got := f.get(t, a.ID).NextRunAt; got != nil {
		t.Errorf("next_run_at = %v, want NULL", got)
	}
}

func TestScheduler_OneBadRowDoesNotBlockOthers(t *testing.T) {
	f := newSchedFixture(t, time.Time{})
	f.clock.Set(f.at(14, 8, 0))
	bad := f.seed(t, "broken", "0 9 * * *", "run_once")
	good := f.seed(t, "morning", "0 9 * * *", "run_once")
	if _, err := f.d.Exec(`UPDATE automations SET trigger_spec = '{"schedule":"not cron"}' WHERE id = ?`, bad.ID); err != nil {
		t.Fatal(err)
	}
	now := f.at(14, 9, 0)
	f.clock.Set(now)
	// No indexer: a rescan would rewrite the corrupted row from its file.
	err := zoned(automations.NewScheduler(f.d, nil, f.clock, nil), f.loc).Tick(context.Background(), now)
	if err == nil || !strings.Contains(err.Error(), "broken") {
		t.Errorf("Tick error = %v, want one naming the broken automation", err)
	}
	wantRunCount(t, f.runs(t, bad.ID), 0)
	wantRunCount(t, f.runs(t, good.ID), 1)
}

func TestScheduler_ClockBackwardsTransientWaits(t *testing.T) {
	f := newSchedFixture(t, time.Time{})
	f.clock.Set(f.at(14, 8, 0))
	a := f.seed(t, "morning", "0 9 * * *", "run_once")
	f.tick(t, f.at(14, 9, 0))
	f.settle(t, a.ID)
	// The clock steps back 2.5 h and runs through 09:00 again, then is corrected.
	for now := f.at(14, 6, 30); !now.After(f.at(14, 9, 30)); now = now.Add(5 * time.Minute) {
		f.tick(t, now)
		f.settle(t, a.ID)
	}
	wantTime(t, "last_scheduled_for", f.get(t, a.ID).LastScheduledFor, f.at(14, 9, 0))
	f.tick(t, f.at(14, 12, 0))
	wantRunCount(t, f.runs(t, a.ID), 1)
	f.tick(t, f.at(15, 9, 0))
	rs := f.runs(t, a.ID)
	wantRunCount(t, rs, 2)
	wantRun(t, rs[1], db.TriggerSchedule, f.at(15, 9, 0))
}

func TestScheduler_ClockBackwardsUnderADayDoesNotReprime(t *testing.T) {
	f := newSchedFixture(t, time.Time{})
	f.clock.Set(f.at(14, 8, 0))
	a := f.seed(t, "morning", "0 9 * * *", "run_once")
	f.setLast(t, a.ID, f.at(15, 7, 0)) // 23 h ahead of the next tick
	f.tick(t, f.at(14, 8, 0))
	wantTime(t, "last_scheduled_for", f.get(t, a.ID).LastScheduledFor, f.at(15, 7, 0))
	f.tick(t, f.at(14, 9, 0))
	wantRunCount(t, f.runs(t, a.ID), 0)
	f.tick(t, f.at(15, 9, 0))
	wantRunCount(t, f.runs(t, a.ID), 1)
}

func TestScheduler_ConcurrentConfirmSkipsRow(t *testing.T) {
	f := newSchedFixture(t, time.Time{})
	f.clock.Set(f.at(14, 8, 0))
	a := f.seed(t, "morning", "0 9 * * *", "run_once")
	hookRan := false
	automations.SetSchedulerBeforeWrite(f.s, func(row db.Automation) {
		if hookRan {
			return
		}
		hookRan = true
		// The owner edits the script and confirms it between the
		// scheduler's read and its write: the confirm stamps
		// last_scheduled_for = now.
		text := strings.NewReplacer("CRON", "0 9 * * *", "MISSED", "run_once").Replace(schedRecipe)
		text = strings.Replace(text, `log("tick")`, `log("tock")`, 1)
		if err := os.WriteFile(row.Path, []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
		edited := f.indexed(t, "morning")
		if err := f.d.ConfirmAutomation(edited.ID, edited.ApprovalHash, f.at(14, 9, 0).Add(30*time.Second)); err != nil {
			t.Fatal(err)
		}
	})
	f.tick(t, f.at(14, 9, 0))
	if !hookRan {
		t.Fatal("the write hook never ran")
	}
	wantRunCount(t, f.runs(t, a.ID), 0)
	wantTime(t, "last_scheduled_for", f.get(t, a.ID).LastScheduledFor, f.at(14, 9, 0).Add(30*time.Second))
	f.tick(t, f.at(14, 9, 1))
	wantRunCount(t, f.runs(t, a.ID), 0)
	f.tick(t, f.at(15, 9, 0))
	wantRunCount(t, f.runs(t, a.ID), 1)
}

func TestScheduler_ZoneChangeTakesEffectWithoutRestart(t *testing.T) {
	f := newSchedFixture(t, time.Time{})
	f.clock.Set(f.at(14, 8, 0))
	a := f.seed(t, "morning", "0 9 * * *", "run_once")
	newYork := loadZone(t, "America/New_York")
	zone := f.loc
	automations.SetSchedulerZone(f.s, func() *time.Location { return zone })
	f.tick(t, f.at(14, 8, 30))
	wantTime(t, "next_run_at", f.get(t, a.ID).NextRunAt, f.at(14, 9, 0))

	zone = newYork // the owner flies to New York and the Mac follows
	f.tick(t, f.at(14, 9, 0))
	wantRunCount(t, f.runs(t, a.ID), 0)
	nyNine := time.Date(2026, 10, 14, 9, 0, 0, 0, newYork)
	wantTime(t, "next_run_at", f.get(t, a.ID).NextRunAt, nyNine)
	f.tick(t, nyNine)
	rs := f.runs(t, a.ID)
	wantRunCount(t, rs, 1)
	wantRun(t, rs[0], db.TriggerSchedule, nyNine)
}

func TestScheduler_ZoneNameFromLink(t *testing.T) {
	cases := []struct {
		target, want string
		ok           bool
	}{
		{"/var/db/timezone/zoneinfo/Europe/Berlin", "Europe/Berlin", true},
		{"/usr/share/zoneinfo/America/Argentina/Buenos_Aires", "America/Argentina/Buenos_Aires", true},
		{"../usr/share/zoneinfo/UTC", "UTC", true},
		{"/usr/share/zoneinfo/", "", false},
		{"/etc/some-other-file", "", false},
	}
	for _, tc := range cases {
		got, ok := automations.ZoneNameFromLink(tc.target)
		if got != tc.want || ok != tc.ok {
			t.Errorf("ZoneNameFromLink(%q) = %q, %v; want %q, %v", tc.target, got, ok, tc.want, tc.ok)
		}
	}
}

func TestScheduler_WakeCoalesces(t *testing.T) {
	f := newSchedFixture(t, time.Time{})
	clock := &stepClock{now: f.at(14, 8, 0).Add(30 * time.Second), calls: make(chan time.Duration, 8), fire: make(chan time.Time)}
	s := zoned(automations.NewScheduler(f.d, f.ix, clock, nil), f.loc)
	// Three wakes before Run starts: one buffered, two coalesced into it.
	s.Wake()
	s.Wake()
	s.Wake()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- s.Run(ctx) }()
	clock.waitAfter(t) // the start tick
	clock.waitAfter(t) // the one coalesced wake's tick
	select {
	case d := <-clock.calls:
		t.Fatalf("a third tick ran (wait %s); wakes were not coalesced", d)
	case <-time.After(200 * time.Millisecond):
	}
	cancel()
	if err := <-done; err != nil {
		t.Errorf("Run = %v, want nil", err)
	}
}
