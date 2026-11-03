package actions

import (
	"context"
	"database/sql"
	"errors"
	"slices"
	"sync"
	"testing"
	"time"

	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// Go twins of the Swift RelayProcessorTests that had none (Go hub phase 3,
// Task 24, spec §13 "Ported guards").

// stranger is a phone the hub never linked, writing into the world's
// mailbox zone: its records open for nobody here.
func (w *world) stranger() *hubtest.Phone {
	w.t.Helper()
	meta, err := w.keys.MetaKey()
	if err != nil {
		w.t.Fatal(err)
	}
	epoch, err := w.keys.CurrentEpoch()
	if err != nil {
		w.t.Fatal(err)
	}
	ph, err := hubtest.New(hubtest.Config{
		Hub: w.keys.HubID(), HubKX: w.ident.Agreement.PublicKey(), MetaKey: meta, Epoch: epoch,
		HubRelayID: hubRelayID, Transport: w.fake, Clock: w.clock, Mailbox: w.mailbox,
	})
	if err != nil {
		w.t.Fatal(err)
	}
	return ph
}

// contacts records every contact the processor reports.
func (w *world) contacts() func() []time.Time {
	var mu sync.Mutex
	var got []time.Time
	w.proc.cfg.Contact = func(at time.Time) {
		mu.Lock()
		got = append(got, at)
		mu.Unlock()
	}
	return func() []time.Time {
		mu.Lock()
		defer mu.Unlock()
		return slices.Clone(got)
	}
}

// unlinkAll removes every linked phone from the sidecar.
func (w *world) unlinkAll() {
	w.t.Helper()
	if err := w.st.WithTx(w.ctx, func(tx *sql.Tx) error {
		_, err := tx.Exec(`DELETE FROM devices`)
		return err
	}); err != nil {
		w.t.Fatal(err)
	}
}

// devicePayload is ph's own device record, dated updated.
func devicePayload(ph *hubtest.Phone, updated time.Time) wire.DevicePayload {
	return wire.DevicePayload{DeviceID: ph.ID().String(), Name: "Test Phone", Scope: "private",
		UpdatedAt: wire.Time{Time: updated}}
}

// A phone's device record is phone activity: the pass reads it (Read > 0,
// which keeps the runtime's active cadence) and reports a contact.
// twin of RelayProcessorTests.testAHandedOverDeviceRecordCountsAsPhoneActivity
func TestAHandedOverDeviceRecordCountsAsPhoneActivity(t *testing.T) {
	onShared(t, func(t *testing.T, w *world) {
		got := w.contacts()
		if _, err := w.phone.WriteDeviceRecord(devicePayload(w.phone, w.clock()), ""); err != nil {
			t.Fatal(err)
		}
		if r := w.pass(); r.Read != 1 {
			t.Fatalf("pass %+v: the device record is no activity", r)
		}
		if len(got()) != 1 {
			t.Fatalf("contacts %v", got())
		}
	})
}

// An action that passes the gates stamps the phone contact at now.
// twin of RelayProcessorTests.testAnAdmittedActionStampsThePhoneContact
func TestAnAdmittedActionStampsThePhoneContact(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		got := w.contacts()
		w.act("test_noop")
		w.pass()
		if c := got(); len(c) != 1 || !c[0].Equal(w.clock()) {
			t.Fatalf("contacts %v, want [%v]", c, w.clock())
		}
	})
}

// A refused action stamps no contact: one naming another device (failed
// device_not_linked) and one sealed by a phone the hub never linked.
// twin of RelayProcessorTests.testARefusedActionStampsNoContact
func TestARefusedActionStampsNoContact(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		got := w.contacts()
		a := w.phone.NewAction("test_noop")
		other := secure.ID{0x77}.String()
		a.DeviceID = &other
		seq := w.send(a)
		if _, err := w.stranger().Act("test_noop"); err != nil {
			t.Fatal(err)
		}
		w.settle()
		w.wantEcho(seq, wire.StatusFailed, reasonDeviceNotLinked)
		if c := got(); len(c) != 0 {
			t.Fatalf("a refused action stamped %v", c)
		}
	})
}

// A device record stamps the time the phone says it was last in touch
// (seen_at, else updated_at), never a time later than now, and an unlink is
// no contact.
// twin of RelayProcessorTests.testADeviceRecordStampsItsSeenAtAndNeverALaterTime
func TestADeviceRecordStampsItsSeenAtAndNeverALaterTime(t *testing.T) {
	onShared(t, func(t *testing.T, w *world) {
		got := w.contacts()
		now := w.clock()
		seen := wire.Time{Time: now.Add(-10 * time.Minute)}
		d := devicePayload(w.phone, now.Add(-2*time.Hour))
		d.SeenAt = &seen
		if _, err := w.phone.WriteDeviceRecord(d, ""); err != nil {
			t.Fatal(err)
		}
		w.pass()
		future := wire.Time{Time: now.Add(time.Hour)}
		d.SeenAt = &future
		if _, err := w.phone.WriteDeviceRecord(d, ""); err != nil {
			t.Fatal(err)
		}
		w.pass()
		d.SeenAt = nil
		if _, err := w.phone.WriteDeviceRecord(d, ""); err != nil {
			t.Fatal(err)
		}
		w.pass()
		unlinked := true
		d.Unlinked = &unlinked
		if _, err := w.phone.WriteDeviceRecord(d, ""); err != nil {
			t.Fatal(err)
		}
		w.pass()
		want := []time.Time{seen.Time, now, now.Add(-2 * time.Hour)}
		if c := got(); !slices.EqualFunc(c, want, time.Time.Equal) {
			t.Fatalf("contacts %v, want %v", c, want)
		}
	})
}

// A removed phone's device record stamps no contact, while another phone
// is still linked: the hub holds no key for it any more.
// twin of RelayProcessorTests.testARemovedPhonesDeviceRecordStampsNoContactWhileAnotherPhoneIsLinked
func TestARemovedPhonesDeviceRecordStampsNoContactWhileAnotherPhoneIsLinked(t *testing.T) {
	onShared(t, func(t *testing.T, w *world) {
		got := w.contacts()
		removed := w.phone
		if _, err := removed.WriteDeviceRecord(devicePayload(removed, w.clock()), ""); err != nil {
			t.Fatal(err)
		}
		w.unlinkAll()
		w.phone = w.addPhone()
		w.pass()
		if c := got(); len(c) != 0 {
			t.Fatalf("a removed phone stamped %v", c)
		}
	})
}

// An action whose payload names another record than the one its envelope
// authenticated is dropped: never applied, ledgered or echoed, under either
// name. Ordered (a-<device>-1 carrying action_seq 2) and legacy (action-X
// carrying id Y).
// twin of RelayProcessorTests.testAnActionWhosePayloadNamesAnotherRecordIsIgnored
func TestAnActionWhosePayloadNamesAnotherRecordIsIgnored(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		dev := w.phone.ID().String()
		ordered := w.phone.NewAction("test_noop")
		two := uint64(2)
		ordered.ActionSeq = &two
		body, err := wire.Marshal(ordered)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := w.phone.WriteFrame(kindAction, "a-"+dev+"-1", body); err != nil {
			t.Fatal(err)
		}
		legacy := w.phone.NewAction("test_noop")
		legacy.ID = "Y"
		if body, err = wire.Marshal(legacy); err != nil {
			t.Fatal(err)
		}
		if _, err := w.phone.WriteFrame(kindAction, "action-X", body); err != nil {
			t.Fatal(err)
		}

		r := w.pass()
		w.sync(w.phone)
		w.wantCalls()
		if r.Applied+r.Echoed+r.Held != 0 || len(w.phone.Echoes) != 0 {
			t.Fatalf("pass %+v, echoes %v", r, w.phone.Echoes)
		}
		for _, key := range []string{w.ledgerKey(1), w.ledgerKey(2), "action-X", "action-Y"} {
			if phase, _, _, err := w.st.Phase(key); err != nil || phase != "" {
				t.Fatalf("ledger %s = %q, %v", key, phase, err)
			}
		}
		if d := w.device(w.phone); d.LastAppliedActionSeq != 0 {
			t.Fatalf("the order moved to %d", d.LastAppliedActionSeq)
		}
	})
}

// Hygiene ages records by the server's date, never the sender's claim: a
// stranger's action claiming to be fresh is deleted once the server stored
// it over a week ago, one claiming to be ancient that just arrived stays.
// twin of RelayProcessorTests.testHygieneAgesRecordsByTheServersDate
func TestHygieneAgesRecordsByTheServersDate(t *testing.T) {
	w := newWorld(t, kindShared)
	s := w.stranger()
	claimsFresh := s.NewAction("test_noop")
	claimsFresh.CreatedAt = wire.Time{Time: w.clock().Add(365 * 24 * time.Hour)}
	freshSeq, err := s.Queue(claimsFresh)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Send(freshSeq); err != nil {
		t.Fatal(err)
	}
	w.advance(ActionMaxAge + time.Hour)
	claimsAged := s.NewAction("test_noop")
	claimsAged.CreatedAt = wire.Time{Time: time.Unix(1, 0)}
	agedSeq, err := s.Queue(claimsAged)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Send(agedSeq); err != nil {
		t.Fatal(err)
	}

	if rep, err := w.proc.Hygiene(w.ctx); err != nil || !rep.Ran {
		t.Fatalf("hygiene %+v, %v", rep, err)
	}
	aged, _ := s.Sealed(agedSeq)
	if names := w.zoneNames(); !slices.Equal(names, []string{aged}) {
		fresh, _ := s.Sealed(freshSeq)
		t.Fatalf("left %v, want only the server-fresh record %s (the server-aged one is %s)", names, aged, fresh)
	}
}

// Hellos count toward the pass budget: a flood spreads over passes instead
// of holding one pass for its whole length.
// twin of RelayProcessorTests.testHellosCountTowardTheBatchLimit
func TestHellosCountTowardTheBatchLimit(t *testing.T) {
	w := newWorld(t, kindShared)
	phones := []*hubtest.Phone{w.phone, w.addPhone(), w.addPhone()}
	w.unlinkAll()
	for _, ph := range phones {
		if err := ph.Hello(w.mailbox); err != nil {
			t.Fatal(err)
		}
	}
	seen := 0
	w.proc.cfg.Hello = func(context.Context, transport.Stored) error {
		seen++
		return nil
	}
	w.proc.batch = 1

	if r := w.pass(); r.Remaining != 2 || seen != 1 {
		t.Fatalf("pass %+v with %d hellos seen, want 1 seen and 2 remaining", r, seen)
	}
	w.pass()
	w.pass()
	if seen != 3 {
		t.Fatalf("%d hellos seen after three passes", seen)
	}
}

// blockingKind registers kind with a handler that logs its call and, on its
// first call, signals entered and waits for release.
func (w *world) blockingKind(kind string, opts KindOptions) (entered, release chan struct{}) {
	entered, release = make(chan struct{}), make(chan struct{})
	first := true
	w.disp.Register(kind, func(_ context.Context, r Request) Outcome {
		w.mu.Lock()
		w.calls = append(w.calls, r.RecordName)
		block := first
		first = false
		w.mu.Unlock()
		if block {
			close(entered)
			<-release
		}
		return Outcome{Status: wire.StatusApplied}
	}, opts)
	return entered, release
}

// Two passes at once apply each non-idempotent record once.
// twin of RelayProcessorTests.testConcurrentPassesApplyEachNonIdempotentRecordOnce
func TestConcurrentPassesApplyEachNonIdempotentRecordOnce(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		entered, release := w.blockingKind("slow_write", KindOptions{NonIdempotent: true})
		for range 3 {
			w.act("slow_write")
		}
		errs := make(chan error, 2)
		for range 2 {
			go func() {
				_, err := w.proc.Pass(w.ctx)
				errs <- err
			}()
		}
		<-entered
		close(release)
		for range 2 {
			if err := <-errs; err != nil {
				t.Fatal(err)
			}
		}
		calls := w.callLog()
		if len(calls) != 3 || len(slices.Compact(slices.Sorted(slices.Values(calls)))) != 3 {
			t.Fatalf("calls %v: want each of the 3 records applied once", calls)
		}
	})
}

// A pass stopped while a record is being applied finishes that record (its
// outcome commits and is echoed) and leaves the next one untouched; the next
// pass applies the one left, once. Both for a non-idempotent kind (claimed
// begun first) and an idempotent one (no claim).
// twin of RelayProcessorTests.testCancellationStopsThePassBetweenRecordsNeverMidApply
func TestCancellationStopsThePassBetweenRecordsNeverMidApply(t *testing.T) {
	for _, nonIdempotent := range []bool{true, false} {
		eachKind(t, func(t *testing.T, w *world) {
			cancelMidApply(t, w, KindOptions{NonIdempotent: nonIdempotent})
		})
	}
}

func cancelMidApply(t *testing.T, w *world, opts KindOptions) {
	t.Helper()
	entered, release := w.blockingKind("slow_write", opts)
	first, second := w.act("slow_write"), w.act("slow_write")
	ctx, cancel := context.WithCancel(w.ctx)
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, err := w.proc.Pass(ctx)
		done <- err
	}()
	<-entered
	cancel()
	close(release)
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("a stopped pass returned %v", err)
	}
	if n := len(w.callLog()); n != 1 {
		t.Fatalf("%d handler calls: the next record was not left", n)
	}
	if phase, outcome, _, err := w.st.Phase(w.ledgerKey(first)); err != nil || phase != "done" || outcome != "applied" {
		t.Fatalf("the record being applied: %q/%q, %v", phase, outcome, err)
	}
	if phase, _, _, err := w.st.Phase(w.ledgerKey(second)); err != nil || phase != "" {
		t.Fatalf("the next record was touched: %q, %v", phase, err)
	}

	w.settle()
	w.wantEcho(first, wire.StatusApplied, "")
	w.wantEcho(second, wire.StatusApplied, "")
	if n := len(w.callLog()); n != 2 {
		t.Fatalf("%d handler calls after the next pass, want 2", n)
	}
}
