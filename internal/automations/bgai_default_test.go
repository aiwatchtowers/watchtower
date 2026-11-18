package automations_test

import (
	"context"
	"io"
	"log"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"watchtower/internal/aiconsent/aiconsenttest"
	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/automations/builtin"
	"watchtower/internal/config"
	"watchtower/internal/db"
)

// countingGate is a built-in Gate that is always due and counts its calls.
type countingGate struct{ calls atomic.Int32 }

func (g *countingGate) Due(context.Context, builtin.Entry, time.Time) bool {
	g.calls.Add(1)
	return true
}

// TestBGAI01_NilReaderFailsClosed (BGAI-01, Decision 9): a scheduler, bus,
// executor and built-in runner built without a consent reader read
// aiconsent.Current, and an install whose owner has not answered reads
// paused there — no component built anywhere is ungated by default.
func TestBGAI01_NilReaderFailsClosed(t *testing.T) {
	aiconsenttest.Unanswered(t)

	t.Run("scheduler", func(t *testing.T) {
		f := newSchedFixture(t, time.Time{})
		f.clock.Set(f.at(14, 8, 0))
		a := f.seed(t, "morning", "0 9 * * *", "run_once")
		f.tick(t, f.at(14, 9, 0))
		wantRunCount(t, f.runs(t, a.ID), 0)
	})

	t.Run("bus", func(t *testing.T) {
		f := newBusFixture(t)
		ai := f.seed(t, "ai", automations.SlackReactionAdded, "{}", automationstest.SeedOptions{})
		f.begin(t)
		if f.bus.Wants(automations.SlackReactionAdded) {
			t.Fatal("Wants = true; the only listener is an AI recipe")
		}
		f.bus.Publish(automations.ReactionEvent("work", "C0001", "1.0", "eyes"))
		if rep := f.flush(t, busCycleA); rep.Queued != 0 {
			t.Fatalf("report = %+v; want nothing queued", rep)
		}
		if runs := f.runs(t, ai); len(runs) != 0 {
			t.Fatalf("AI recipe has %d runs; want none", len(runs))
		}
	})

	t.Run("executor", func(t *testing.T) {
		gen := &automationstest.FakeGenerator{Replies: []string{"done"}}
		f := newExFixture(t, exOpts{gen: gen})
		a := f.seed(t, "digest", `return llm("x")`, false)
		id := f.enqueue(t, a, db.TriggerSchedule)
		f.step(t, 0)
		r := f.wantRun(t, id, db.RunCancelled, db.ErrKindCancelled)
		if r.Error != automations.BackgroundAIPausedMessage {
			t.Fatalf("run error = %q; want %q", r.Error, automations.BackgroundAIPausedMessage)
		}
		if n := gen.CallCount(); n != 0 {
			t.Fatalf("generator calls = %d; want 0", n)
		}
	})

	t.Run("built-in runner", func(t *testing.T) {
		d := db.OpenTestDB(t)
		cfg, err := config.Load(filepath.Join(t.TempDir(), "absent.yaml"))
		if err != nil {
			t.Fatal(err)
		}
		cfg.Briefing.Enabled, cfg.DayPlan.Enabled = true, true
		clock := automationstest.NewFakeClock(exStart)
		if _, err := builtin.Sync(context.Background(), d, t.TempDir(), cfg, clock.Now()); err != nil {
			t.Fatalf("builtin.Sync: %v", err)
		}
		quiet := log.New(io.Discard, "", 0)
		exec := automations.NewExecutor(d, automations.Backends{DB: d, Clock: clock}, automations.ExecutorOptions{Logger: quiet})
		gate := &countingGate{}
		r := builtin.NewRunner(d, exec, map[string]builtin.Gate{"morning-brief": gate}, cfg, clock, quiet)

		out := r.RunSlot(context.Background(), builtin.SlotMorningBrief)
		if len(out) != 1 || out[0].Skipped != builtin.SkippedPaused || out[0].RunID != 0 {
			t.Fatalf("RunSlot = %+v; want Morning brief skipped as paused", out)
		}
		if n := gate.calls.Load(); n != 0 {
			t.Fatalf("gate calls = %d; want 0", n)
		}
		var runs int
		if err := d.QueryRow(`SELECT COUNT(*) FROM automation_runs`).Scan(&runs); err != nil {
			t.Fatal(err)
		}
		if runs != 0 {
			t.Fatalf("automation_runs = %d; want 0", runs)
		}
	})
}
