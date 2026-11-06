package actions

import (
	"context"
	"errors"
	"testing"
	"time"

	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// fakeSwitch is a Switch whose answers a test sets.
type fakeSwitch struct {
	active   transport.Kind
	reject   error
	requests []string // "<from> <target>"
	stale    int
	lapsed   bool
	// lapsedAt, when set, makes the lapse commit at that Lapsed call (a
	// lapse mid-pass); lapsedCalls counts the calls.
	lapsedAt, lapsedCalls int
	// spinLimit, when set, fails a Lapsed call past it: a drain that does not
	// move the order would otherwise spin for ever and hang the test.
	spinLimit int
	skipped   bool
	inactive  []string // devices reported by EntitlementInactive
}

func (f *fakeSwitch) IsActive(k transport.Kind) bool { return k == f.active }

func (f *fakeSwitch) Request(_ context.Context, from string, target transport.Kind, _ string) error {
	f.requests = append(f.requests, from+" "+string(target))
	return f.reject
}

func (f *fakeSwitch) Stale(context.Context, transport.Kind, string) (wire.Control, uint32, bool, error) {
	f.stale++
	return wire.Control{Kind: wire.ControlHubOnRelay}, 0, true, nil
}

func (f *fakeSwitch) Lapsed(transport.Kind, string, uint64) (bool, error) {
	f.lapsedCalls++
	if f.spinLimit > 0 && f.lapsedCalls > f.spinLimit {
		return false, errors.New("the drain is spinning")
	}
	if f.lapsedAt > 0 {
		return f.lapsedCalls >= f.lapsedAt, nil
	}
	return f.lapsed, nil
}

func (f *fakeSwitch) Skipped(transport.Kind, string, uint64, time.Time) (bool, error) {
	return f.skipped, nil
}

func (f *fakeSwitch) EntitlementInactive(_ transport.Kind, device string) {
	f.inactive = append(f.inactive, device)
}

func (w *world) withSwitch(f *fakeSwitch) {
	w.proc.cfg.Switch = f
}

func TestTransportSwitchGoesToTheSwitcher(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		sw := &fakeSwitch{active: w.tr.Kind()}
		w.withSwitch(sw)
		target := wire.TransportRelay
		id, err := w.phone.WriteControl(wire.Control{Kind: wire.ControlSwitch, Target: &target})
		if err != nil {
			t.Fatal(err)
		}
		w.settle()
		if len(sw.requests) != 1 || sw.requests[0] != w.phone.ID().String()+" relay" {
			t.Fatalf("requests %v", sw.requests)
		}
		if w.holds(w.phone.ControlWireName(id)) || len(w.phone.Controls) != 0 {
			t.Fatalf("accepted: the request stays or was answered: %+v", w.phone.Controls)
		}

		// Rejected: the reason and the wait, rounded up to whole seconds.
		sw.reject = &SwitchRejected{Reason: wire.SwitchTooSoon, RetryAfter: 239*time.Second + time.Millisecond}
		if _, err := w.phone.WriteControl(wire.Control{Kind: wire.ControlSwitch, Target: &target}); err != nil {
			t.Fatal(err)
		}
		w.settle()
		got := w.controls(wire.ControlSwitchRejected)
		if len(got) != 1 || *got[0].Reason != wire.SwitchTooSoon || got[0].RetryAfterS == nil || *got[0].RetryAfterS != 240 {
			t.Fatalf("rejections %+v", got)
		}

		// A switcher failure never stalls the mailbox: the phone is told to
		// ask again, and the actions behind the request are applied.
		sw.reject = errors.New("the sidecar is busy")
		if _, err := w.phone.WriteControl(wire.Control{Kind: wire.ControlSwitch, Target: &target}); err != nil {
			t.Fatal(err)
		}
		seq := w.act("test_noop")
		if _, err := w.proc.Pass(w.ctx); err != nil {
			t.Fatalf("a switcher failure came out of the pass: %v", err)
		}
		w.settle()
		w.wantCalls(noops(seq)...)
		got = w.controls(wire.ControlSwitchRejected)
		if len(got) != 2 || *got[1].Reason != wire.SwitchUnavailable || got[1].RetryAfterS == nil || *got[1].RetryAfterS != 60 {
			t.Fatalf("rejections %+v", got)
		}
		w.wantEmptyMailbox()
	})
}

// Sim rule 12a: on standby an action is never applied, deleted or marked;
// its phone gets the switcher's answer once per record version.
func TestStandbyLeavesActionsAndAnswersOncePerVersion(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		sw := &fakeSwitch{active: "elsewhere"}
		w.withSwitch(sw)
		seq := w.act("test_noop")
		w.settle()
		w.settle()
		w.wantCalls()
		if sw.stale != 1 || len(w.controls(wire.ControlHubOnRelay)) != 1 {
			t.Fatalf("answered %d times, phone read %+v", sw.stale, w.phone.Controls)
		}
		if name, _ := w.phone.Sealed(seq); !w.holds(name) {
			t.Fatal("the action was not left to the phone")
		}
		if len(w.phone.Echoes) != 0 {
			t.Fatalf("echoed on standby: %+v", w.phone.Echoes)
		}
		// A new version of the record is answered again.
		if err := w.phone.WriteCopy(seq); err != nil {
			t.Fatal(err)
		}
		w.settle()
		if sw.stale != 2 {
			t.Fatalf("answered %d times, want 2", sw.stale)
		}
		// Active again: after a rewind the left action is applied once.
		sw.active = w.tr.Kind()
		if err := w.proc.Rewind(); err != nil {
			t.Fatal(err)
		}
		w.settle()
		w.wantCalls(noops(seq)...)
		w.wantEcho(seq, wire.StatusApplied, "")
	})
}
