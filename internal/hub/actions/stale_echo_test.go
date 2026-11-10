package actions

import (
	"database/sql"
	"testing"

	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/wire"
)

// hookedWrites is the phone's record store with a hook run after each of its
// writes (the hub answering between two writes of one resend_from).
type hookedWrites struct {
	*memfake.Fake
	after func(name string)
}

func (h hookedWrites) Write(zone, name string, env []byte, expect transport.Expect) (transport.Outcome, error) {
	out, err := h.Fake.Write(zone, name, env, expect)
	h.after(name)
	return out, err
}

// A fast hub answers a resend_from while the phone is still handling the
// page the control came in: by the phone's resend of 5 the hub has applied
// 3..5 and written 5's final echo over its held one, which the phone reads
// from the write conflict, settles and deletes. The page's older copy of the
// held echo of 5, handled after the control, must not undo that: the phone's
// last echo of 5 stays applied (the interop ordering test's stall).
func TestPhoneKeepsFinalEchoOverStaleHeldOne(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		var a4 string
		answered := false
		hooked := hookedWrites{Fake: w.fake, after: func(name string) {
			if name == a4 && !answered && len(w.phone.Controls) > 0 {
				answered = true
				w.pass()
			}
		}}
		meta, err := w.keys.MetaKey()
		if err != nil {
			t.Fatal(err)
		}
		epoch, err := w.keys.CurrentEpoch()
		if err != nil {
			t.Fatal(err)
		}
		ph, err := hubtest.New(hubtest.Config{
			Hub: w.keys.HubID(), HubKX: w.ident.Agreement.PublicKey(), MetaKey: meta, Epoch: epoch,
			HubRelayID: hubRelayID, Transport: hooked, Clock: w.clock, Mailbox: w.mailbox,
		})
		if err != nil {
			t.Fatal(err)
		}
		if err := w.st.WithTx(w.ctx, func(tx *sql.Tx) error { return state.LinkDevice(tx, ph.Device()) }); err != nil {
			t.Fatal(err)
		}
		w.phone = ph
		for range 5 {
			if _, err := ph.Queue(ph.NewAction("test_noop")); err != nil {
				t.Fatal(err)
			}
		}
		a4, _ = ph.Sealed(4)
		for _, s := range []uint64{1, 2, 4} {
			if err := ph.Send(s); err != nil {
				t.Fatal(err)
			}
		}
		w.pass() // 1 and 2 applied, 4 held, resend_from(3) queued
		if err := ph.Send(5); err != nil {
			t.Fatal(err)
		}
		w.pass() // 5 held: its held echo lands after the control
		w.sync(ph)
		if !answered {
			t.Fatal("the phone never resent 4")
		}
		w.settle()
		for s := uint64(1); s <= 5; s++ {
			w.wantEcho(s, wire.StatusApplied, "")
		}
		w.wantCalls("test_noop:1", "test_noop:2", "test_noop:3", "test_noop:4", "test_noop:5")
		if len(ph.Outbox()) != 0 {
			t.Fatalf("outbox %v", ph.Outbox())
		}
	})
}
