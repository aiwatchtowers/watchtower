package actions

import (
	"context"
	"testing"

	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

func (w *world) sendLegacy(kind string) wire.ActionRequest {
	w.t.Helper()
	a := w.phone.NewAction(kind)
	if _, err := w.phone.SendLegacy(a); err != nil {
		w.t.Fatal(err)
	}
	return a
}

func (w *world) wantLegacyEcho(id, status, reason string) {
	w.t.Helper()
	e, ok := w.phone.LegacyEchoes[id]
	if !ok {
		w.t.Fatalf("no echo of legacy action %s", id)
	}
	got := ""
	if e.Reason != nil {
		got = *e.Reason
	}
	if e.Status != status || got != reason || e.ActionSeq != nil {
		w.t.Fatalf("echo of legacy action: %s/%s seq %v, want %s/%s", e.Status, got, e.ActionSeq, status, reason)
	}
}

func TestLegacyActionWithoutSeqTakesTodaysPath(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		var seenBeforeHandler, startID string
		w.disp.Register("session_start", func(context.Context, Request) Outcome {
			w.sync(w.phone) // the received echo is written before the handler runs
			if e, ok := w.phone.LegacyEchoes[startID]; ok {
				seenBeforeHandler = e.Status
			}
			return Outcome{Status: wire.StatusApplied}
		}, KindOptions{})
		noop := w.sendLegacy("test_noop")
		start := w.sendLegacy("session_start")
		startID = start.ID
		w.settle()
		w.wantCalls("test_noop:action-" + noop.ID)
		if seenBeforeHandler != wire.StatusReceived {
			t.Fatalf("before the handler the phone saw %q", seenBeforeHandler)
		}
		w.wantLegacyEcho(noop.ID, wire.StatusApplied, "")
		w.wantLegacyEcho(start.ID, wire.StatusApplied, "")
		if _, outcome, _, err := w.st.Phase("action-" + noop.ID); err != nil || outcome != wire.StatusApplied {
			t.Fatalf("ledger %q, %v", outcome, err)
		}
		if d := w.device(w.phone); d.Ordered || d.LastAppliedActionSeq != 0 || d.ResendRequestedFrom != 0 {
			t.Fatalf("device %+v", d)
		}
		if len(w.phone.Controls) != 0 {
			t.Fatalf("controls %+v", w.phone.Controls)
		}
		w.wantEmptyMailbox()

		// A copy read again is echoed with its stored outcome, never re-applied.
		delete(w.phone.LegacyEchoes, noop.ID)
		if err := w.phone.WriteLegacyCopy(noop.ID); err != nil {
			t.Fatal(err)
		}
		w.settle()
		w.wantCalls("test_noop:action-" + noop.ID)
		w.wantLegacyEcho(noop.ID, wire.StatusApplied, "")
		w.wantEmptyMailbox()
	})
}

func TestLegacyActionGatesAnswerWithoutHandler(t *testing.T) {
	w := newWorld(t, transport.KindRelay)
	unknown := w.sendLegacy("not_a_kind")
	other := w.addPhone().ID().String()
	a := w.phone.NewAction("test_noop")
	a.DeviceID = &other
	if _, err := w.phone.SendLegacy(a); err != nil {
		t.Fatal(err)
	}
	w.settle()
	w.wantCalls()
	w.wantLegacyEcho(unknown.ID, wire.StatusFailed, reasonUnsupported)
	w.wantLegacyEcho(a.ID, wire.StatusFailed, reasonDeviceNotLinked)
	w.wantEmptyMailbox()
}

func TestLegacyStoppedAfterReceivedEchoAnswersOutcomeUnknown(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		calls := 0
		w.disp.Register("session_input", func(context.Context, Request) Outcome {
			calls++
			panic("the hub stops mid-apply")
		}, KindOptions{})
		a := w.sendLegacy("session_input")
		func() {
			defer func() { _ = recover() }()
			_, _ = w.proc.Pass(w.ctx)
		}()
		w.sync(w.phone)
		w.wantLegacyEcho(a.ID, wire.StatusReceived, "")
		w.settle()
		if calls != 1 {
			t.Fatalf("handler ran %d times", calls)
		}
		w.wantLegacyEcho(a.ID, wire.StatusFailed, reasonOutcomeUnknown)
		w.wantEmptyMailbox()
	})
}

func TestOrderedModeStartsAtFirstSeq(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		w.sendLegacy("test_noop")
		w.settle()
		if d := w.device(w.phone); d.Ordered {
			t.Fatal("a legacy action switched the phone to ordered mode")
		}
		seq := w.act("test_noop")
		w.settle()
		if d := w.device(w.phone); !d.Ordered || d.LastAppliedActionSeq != seq {
			t.Fatalf("device %+v after its first action_seq", d)
		}
		w.wantEcho(seq, wire.StatusApplied, "")
	})
}
