package actions

import (
	"testing"

	"watchtower/internal/hub/wire"
)

// A paused processor reads no mailbox, runs no handler and writes nothing,
// and its queue and ledger stay; after the pause the action is applied once
// and echoed applied.
func TestPausedProcessorRunsNoHandlerAndWritesNothing(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		w.proc.SetPaused(true)
		seq := w.act("test_noop")
		frames := len(w.fake.Frames())
		if rep := w.pass(); rep != (PassReport{}) {
			t.Fatalf("paused pass = %+v", rep)
		}
		if n, f, err := w.proc.FlushControls(w.ctx); n != 0 || f != 0 || err != nil {
			t.Fatalf("paused flush = %d, %d, %v", n, f, err)
		}
		if rep, err := w.proc.Hygiene(w.ctx); err != nil || rep.Ran {
			t.Fatalf("paused hygiene = %+v, %v", rep, err)
		}
		w.wantCalls()
		if got := len(w.fake.Frames()); got != frames {
			t.Fatalf("%d records written while paused", got-frames)
		}
		if _, err := w.phone.Sync(); err != nil {
			t.Fatal(err)
		}
		if _, ok := w.phone.Echoes[seq]; ok {
			t.Fatal("an echo reached the phone while paused")
		}

		w.proc.SetPaused(false)
		w.settle()
		w.wantCalls("test_noop:1")
		w.wantEcho(seq, wire.StatusApplied, "")
		w.settle()
		w.wantCalls("test_noop:1")
	})
}

// A late echo during the pause is recorded and queued, and goes out with
// the first pass after it.
func TestLateEchoWhilePausedIsQueuedForTheResume(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		seen := heldThenLate(w)
		seq := w.act("session_input")
		w.settle()
		w.wantEcho(seq, wire.StatusHeld, "agent_busy")

		w.proc.SetPaused(true)
		frames := len(w.fake.Frames())
		if err := w.proc.LateEcho(w.ctx, *seen, Outcome{Status: wire.StatusApplied, Delivery: "submitted"}); err != nil {
			t.Fatalf("late echo: %v", err)
		}
		if got := len(w.fake.Frames()); got != frames {
			t.Fatal("a late echo was written while paused")
		}
		w.proc.SetPaused(false)
		w.settle()
		w.wantEcho(seq, wire.StatusApplied, "")
	})
}
