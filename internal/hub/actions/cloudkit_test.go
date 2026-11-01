package actions

import (
	"context"
	"database/sql"
	"slices"
	"strconv"
	"testing"
	"time"

	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// The processor on CloudKit's shape (Go hub phase 3, spec §12a, protocol
// §7.5 points 1–2): every phone of the hub on the one RelayZone, records
// routed by their envelope's sender.

// byDevice registers kind with a handler logging "<device>:<seq>".
func (w *world) byDevice(kind string) {
	w.disp.Register(kind, func(_ context.Context, r Request) Outcome {
		w.mu.Lock()
		defer w.mu.Unlock()
		w.calls = append(w.calls, r.Device.String()+":"+strconv.FormatUint(*r.Action.ActionSeq, 10))
		return Outcome{Status: wire.StatusApplied}
	}, KindOptions{})
}

// zoneNames is every live record name in the shared zone.
func (w *world) zoneNames() []string {
	w.t.Helper()
	var names []string
	var since uint64
	for {
		b, err := w.fake.Changes(w.ctx, w.mailbox, since)
		if err != nil {
			w.t.Fatal(err)
		}
		for _, r := range b.Changed {
			names = append(names, r.Name)
		}
		if !b.More {
			return names
		}
		since = b.NewSeq
	}
}

// Review Focus 3: phone A's hub control (resend_from) and phone B's echo sit
// in the one zone. B's pass neither deletes nor answers A's control, B's
// action applies as B's only, and A's records never count as B's.
func TestSharedRelayZoneRoutesBySender(t *testing.T) {
	w := newWorld(t, kindShared)
	w.byDevice("test_who")
	a, b := w.phone, w.addPhone()
	if a.Zone() != b.Zone() || a.Zone() != transport.SharedMailboxZone(hubRelayID) {
		t.Fatalf("zones %q %q, want one shared mailbox", a.Zone(), b.Zone())
	}
	// A: 1 never reaches the mailbox, 2 is held and resend_from(1) queued for A.
	one, err := a.Queue(a.NewAction("test_who"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := a.Act("test_who"); err != nil {
		t.Fatal(err)
	}
	// B: its action 1, applied and echoed.
	if _, err := b.Act("test_who"); err != nil {
		t.Fatal(err)
	}
	if r := w.pass(); r.Applied != 1 || r.Held != 1 {
		t.Fatalf("pass %+v", r)
	}
	bID, aID := b.ID().String(), a.ID().String()
	w.wantCalls(bID + ":1")
	if d := w.device(b); d.LastAppliedActionSeq != 1 {
		t.Fatalf("B last applied %d", d.LastAppliedActionSeq)
	}
	if d := w.device(a); d.LastAppliedActionSeq != 0 || d.ResendRequestedFrom != 1 {
		t.Fatalf("A %+v", d)
	}
	if held, err := w.st.HeldActions(bID); err != nil || len(held) != 0 {
		t.Fatalf("B holds %v %v", held, err)
	}

	// B reads the zone: its echo only; A's control and held echo stay.
	before := len(w.zoneNames())
	if n := w.sync(b); n != 1 {
		t.Fatalf("B handled %d hub records, want its one echo", n)
	}
	if len(b.Controls) != 0 {
		t.Fatalf("B read controls %+v", b.Controls)
	}
	if e, ok := b.Echoes[1]; !ok || e.Status != wire.StatusApplied {
		t.Fatalf("B's echo %+v", b.Echoes)
	}
	// The final echo replaced B's action record; B deleted that one record
	// and nothing of A's.
	if got := len(w.zoneNames()); got != before-1 {
		t.Fatalf("zone %d → %d records after B's pass", before, got)
	}
	// The hub's next pass reads its own records back and answers nothing.
	if r := w.pass(); r.Applied+r.Held+r.Repeats+r.Echoed != 0 {
		t.Fatalf("pass after B's read %+v", r)
	}

	// A still finds its control, answers it, and its order completes as A's.
	w.sync(a)
	if got := slices.DeleteFunc(slices.Clone(a.Controls), func(c wire.Control) bool { return c.Kind != wire.ControlResendFrom }); len(got) != 1 || *got[0].Seq != one {
		t.Fatalf("A's controls %+v", a.Controls)
	}
	for range 10 {
		r := w.pass()
		if w.sync(a)+w.sync(b) == 0 && r.Read+r.ControlsWritten == 0 {
			break
		}
	}
	w.wantCalls(bID+":1", aID+":1", aID+":2")
	if d := w.device(a); d.LastAppliedActionSeq != 2 {
		t.Fatalf("A last applied %d", d.LastAppliedActionSeq)
	}
	if d := w.device(b); d.LastAppliedActionSeq != 1 {
		t.Fatalf("B last applied %d", d.LastAppliedActionSeq)
	}
	if len(b.Controls) != 0 {
		t.Fatalf("B read A's controls %+v", b.Controls)
	}
	if names := w.zoneNames(); len(names) != 0 {
		t.Fatalf("zone still holds %d records", len(names))
	}
}

// A record sealed by phone B whose name names phone A (a-<A>-1, device-<A>)
// is dropped (class sender_mismatch): nothing applies as A's or as B's, and
// A stays linked.
func TestARecordWhoseSenderDiffersFromItsNameIsDropped(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		w.byDevice("test_who")
		a, b := w.phone, w.addPhone() // on the relay B forges in its own mailbox
		seq := uint64(1)
		forged := a.NewAction("test_who") // device_id A
		forged.ActionSeq = &seq
		payload, err := wire.Marshal(forged)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := b.WriteFrame("action", "a-"+a.ID().String()+"-1", payload); err != nil {
			t.Fatal(err)
		}
		unlinked := true
		if _, err := b.WriteDeviceRecord(wire.DevicePayload{
			DeviceID: a.ID().String(), Name: "Forged", Scope: "private", Unlinked: &unlinked,
		}, "device-"+a.ID().String()); err != nil {
			t.Fatal(err)
		}
		// B's own device record naming A in its payload: dropped too.
		if _, err := b.WriteDeviceRecord(wire.DevicePayload{
			DeviceID: a.ID().String(), Name: "Forged", Scope: "private", Unlinked: &unlinked,
		}, ""); err != nil {
			t.Fatal(err)
		}
		r := w.pass()
		if r.Applied+r.Held+r.Echoed+r.Repeats != 0 {
			t.Fatalf("pass %+v", r)
		}
		w.wantCalls()
		for _, ph := range []*hubtest.Phone{a, b} {
			d := w.device(ph) // both still linked
			if d.LastAppliedActionSeq != 0 || d.Ordered || d.Name != "Test Phone" {
				t.Fatalf("device %+v", d)
			}
			if rows, err := w.st.PendingControls(w.queue(ph)); err != nil || len(rows) != 0 {
				t.Fatalf("%d rows queued for %s, %v", len(rows), ph.ID(), err)
			}
		}
	})
}

// Today's phone (protocol §7.4) on CloudKit: a UUID-named action with no
// action_seq takes today's path — received, then the final echo, no order —
// and two phones' legacy actions in the one zone apply each as its sender's.
func TestLegacyActionOnCloudKitTakesTodaysPath(t *testing.T) {
	w := newWorld(t, kindShared)
	var devices []string
	w.disp.Register("session_start", func(_ context.Context, r Request) Outcome {
		devices = append(devices, r.Device.String())
		return Outcome{Status: wire.StatusApplied}
	}, KindOptions{})
	a, b := w.phone, w.addPhone()
	fromA, fromB := a.NewAction("session_start"), b.NewAction("session_start")
	if _, err := a.SendLegacy(fromA); err != nil {
		t.Fatal(err)
	}
	if _, err := b.SendLegacy(fromB); err != nil {
		t.Fatal(err)
	}
	for range 10 {
		r := w.pass()
		if w.sync(a)+w.sync(b) == 0 && r.Read+r.ControlsWritten == 0 {
			break
		}
	}
	if !slices.Equal(devices, []string{a.ID().String(), b.ID().String()}) {
		t.Fatalf("applied for %v", devices)
	}
	for _, c := range []struct {
		ph *hubtest.Phone
		id string
	}{{a, fromA.ID}, {b, fromB.ID}} {
		e, ok := c.ph.LegacyEchoes[c.id]
		if !ok || e.Status != wire.StatusApplied || e.ActionSeq != nil {
			t.Fatalf("legacy echo %+v %v", e, ok)
		}
		if _, ok := c.ph.LegacyEchoes[map[string]string{fromA.ID: fromB.ID, fromB.ID: fromA.ID}[c.id]]; ok {
			t.Fatal("a phone read the other phone's echo")
		}
		if d := w.device(c.ph); d.Ordered || d.LastAppliedActionSeq != 0 {
			t.Fatalf("device %+v", d)
		}
		if _, outcome, _, err := w.st.Phase("action-" + c.id); err != nil || outcome != wire.StatusApplied {
			t.Fatalf("ledger %q, %v", outcome, err)
		}
	}
	if names := w.zoneNames(); len(names) != 0 {
		t.Fatalf("zone still holds %d records", len(names))
	}
}

// Every linked phone has a mailbox on CloudKit, a phone without a relay
// device id (linked over iCloud) included; on the hosted relay it has none.
func TestEveryLinkedPhoneHasACloudKitMailbox(t *testing.T) {
	for _, k := range []transport.Kind{kindShared, transport.KindRelay} {
		t.Run(string(k), func(t *testing.T) {
			w := newWorld(t, k)
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
				HubRelayID: hubRelayID, Transport: w.fake, Clock: w.clock, Mailbox: w.mailbox,
			})
			if err != nil {
				t.Fatal(err)
			}
			d := ph.Device()
			d.RelayDeviceID = ""
			if err := w.st.WithTx(w.ctx, func(tx *sql.Tx) error { return state.LinkDevice(tx, d) }); err != nil {
				t.Fatal(err)
			}
			boxes, err := w.proc.mailboxes()
			if err != nil {
				t.Fatal(err)
			}
			if k == transport.KindRelay {
				if len(boxes) != 1 || boxes[0].id != w.phone.ID() {
					t.Fatalf("relay mailboxes %+v", boxes)
				}
				return
			}
			// Both linked at the same instant: listed by device id.
			if len(boxes) != 2 || (boxes[0].id != ph.ID() && boxes[1].id != ph.ID()) ||
				boxes[0].zone != w.mailbox || boxes[1].zone != w.mailbox || boxes[0].queue == boxes[1].queue {
				t.Fatalf("cloudkit mailboxes %+v", boxes)
			}
			seq, err := ph.Act("test_noop")
			if err != nil {
				t.Fatal(err)
			}
			if r := w.pass(); r.Applied != 1 {
				t.Fatalf("pass %+v", r)
			}
			w.wantCalls(noops(seq)...)
			w.sync(ph)
			if e, ok := ph.Echoes[seq]; !ok || e.Status != wire.StatusApplied {
				t.Fatalf("echo %+v", ph.Echoes)
			}
		})
	}
}

// The daily CloudKit sweep reads the shared zone once and judges each record
// as its sender's: phone A's undecided action is kept although it is not
// phone B's; the hub's own records (B's echo, A's control) go.
func TestSharedZoneHygieneJudgesEachRecordAsItsSenders(t *testing.T) {
	w := newWorld(t, kindShared)
	a, b := w.phone, w.addPhone()
	if _, err := a.Queue(a.NewAction("test_noop")); err != nil { // 1 never reaches the mailbox
		t.Fatal(err)
	}
	two, err := a.Act("test_noop")
	if err != nil {
		t.Fatal(err)
	}
	undecided, _ := a.Sealed(two)
	if _, err := b.Act("test_noop"); err != nil {
		t.Fatal(err)
	}
	w.pass()                                 // A's 2 held (its held echo replaces the record), B's 1 applied
	if err := a.WriteCopy(two); err != nil { // A's pending 2 again, still undecided
		t.Fatal(err)
	}
	w.mu.Lock()
	w.now = w.now.Add(ActionMaxAge + 2*24*time.Hour)
	w.mu.Unlock()
	rep, err := w.proc.Hygiene(w.ctx)
	if err != nil || !rep.Ran {
		t.Fatalf("hygiene %+v, %v", rep, err)
	}
	names := w.zoneNames()
	if len(names) != 1 || names[0] != undecided {
		t.Fatalf("deleted %d, left %d records: want A's undecided action only", rep.Deleted, len(names))
	}
}
