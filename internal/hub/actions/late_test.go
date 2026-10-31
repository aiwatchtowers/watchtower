package actions

import (
	"context"
	"database/sql"
	"errors"
	"testing"

	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// heldThenLate registers a kind answering held and returns the request the
// handler saw.
func heldThenLate(w *world) *Request {
	var seen Request
	w.disp.Register("session_input", func(_ context.Context, r Request) Outcome {
		seen = r
		return Outcome{Status: wire.StatusHeld, Reason: "agent_busy"}
	}, KindOptions{})
	return &seen
}

// The relay echoes held, then the line's later outcome into the same record,
// and the ledger keeps the later one (Swift
// testTheRelayEchoesHeldThenTheLaterOutcomeAndKeepsIt, relay half).
func TestLateEchoReplacesTheHeldEchoAndTheLedgerKeepsIt(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		seen := heldThenLate(w)
		seq := w.act("session_input")
		w.settle()
		w.wantEcho(seq, wire.StatusHeld, "agent_busy")

		late := Outcome{Status: wire.StatusApplied, Delivery: "submitted"}
		if err := w.proc.LateEcho(w.ctx, *seen, late); err != nil {
			t.Fatalf("late echo: %v", err)
		}
		w.settle()
		e := w.wantEcho(seq, wire.StatusApplied, "")
		if string(e.Result["delivery"]) != `"submitted"` {
			t.Errorf("result %v", e.Result)
		}
		phase, outcome, stored, err := w.st.Phase(w.ledgerKey(seq))
		if err != nil || phase != state.PhaseDone || outcome != wire.StatusApplied {
			t.Fatalf("ledger %s/%s %v", phase, outcome, err)
		}
		if o, ok := decodeStored(stored); !ok || o.Status != wire.StatusApplied {
			t.Fatalf("stored echo %+v", o)
		}
	})
}

// A phone removed since (or one that never sent the record) gets no echo.
func TestLateEchoToARemovedPhoneWritesNothing(t *testing.T) {
	w := newWorld(t, transport.KindRelay)
	seen := heldThenLate(w)
	w.act("session_input")
	w.settle()
	if err := w.st.WithTx(w.ctx, func(tx *sql.Tx) error {
		_, err := tx.Exec(`DELETE FROM devices`)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	err := w.proc.LateEcho(w.ctx, *seen, Outcome{Status: wire.StatusApplied})
	if !errors.Is(err, ErrNotDecided) {
		t.Fatalf("err = %v, want ErrNotDecided", err)
	}
	if rows, _ := w.st.PendingControls(w.phone.Zone()); len(rows) != 0 {
		t.Fatalf("%d writes queued for a removed phone", len(rows))
	}
}

// An action the ledger never decided is not echoed late.
func TestLateEchoOfAnUndecidedActionIsRefused(t *testing.T) {
	w := newWorld(t, transport.KindRelay)
	a := w.phone.NewAction("session_input")
	seq := uint64(7)
	a.ActionSeq = &seq
	r := Request{Device: w.phone.ID(), RecordName: actionName(w.phone.ID(), seq), Action: a}
	if err := w.proc.LateEcho(w.ctx, r, Outcome{Status: wire.StatusApplied}); !errors.Is(err, ErrNotDecided) {
		t.Fatalf("err = %v, want ErrNotDecided", err)
	}
}
