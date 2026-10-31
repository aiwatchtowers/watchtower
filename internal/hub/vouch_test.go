package hub

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/link"
	"watchtower/internal/hub/relaytest"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/relay/relayv1"
	"watchtower/internal/hub/wire"
	"watchtower/internal/policy/policytest"
)

// Vouched hubs (relay proto README, "Vouched hubs"; Go hub design §7, §13
// vouch branches): the hub on the relay's in-process fake, which gates an
// unvouched hub the way the relay does.

// setClock is a settable clock (accountReader's poll window).
type setClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *setClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *setClock) Advance(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	c.mu.Unlock()
}

// accountReader answers polls inside unvouchedPoll from the last read only
// while the hub is unvouched; vouched, every poll reads.
func TestAccountReaderThrottlesOnlyWhileUnvouched(t *testing.T) {
	clock := &setClock{now: time.Unix(1_800_000_000, 0)}
	reads := 0
	vouched := false
	r := &accountReader{
		read: func(context.Context) (*relayv1.AccountState, error) {
			reads++
			return &relayv1.AccountState{}, nil
		},
		vouched: func() bool { return vouched },
		clock:   clock.Now,
	}
	poll := func() {
		t.Helper()
		if _, err := r.State(t.Context()); err != nil {
			t.Fatal(err)
		}
	}
	poll()
	poll()
	clock.Advance(unvouchedPoll - time.Second)
	poll()
	if reads != 1 {
		t.Fatalf("%d reads inside one window", reads)
	}
	clock.Advance(time.Second)
	poll()
	if reads != 2 {
		t.Fatalf("%d reads after the window, want 2", reads)
	}
	vouched = true
	poll()
	poll()
	if reads != 4 {
		t.Fatalf("%d reads while vouched, want 4", reads)
	}
}

// After HUB_NOT_VOUCHED the reader forgets its last answer: a pre-revoke
// state seeded inside the window is not answered again (the PayingWatch
// cannot read "paying" from it); the next read goes to the relay. An empty
// seed arms no window.
func TestAccountReaderInvalidateAndEmptySeed(t *testing.T) {
	clock := &setClock{now: time.Unix(1_800_000_000, 0)}
	reads := 0
	r := &accountReader{
		read: func(context.Context) (*relayv1.AccountState, error) {
			reads++
			return &relayv1.AccountState{}, nil
		},
		vouched: func() bool { return false },
		clock:   clock.Now,
	}
	r.seed(&relayv1.AccountState{})
	r.seed(nil)
	if _, err := r.State(t.Context()); err != nil || reads != 1 {
		t.Fatalf("after an empty seed: %d reads, %v", reads, err)
	}

	r.seed(onePaying())
	st, err := r.State(t.Context())
	if err != nil || reads != 1 || !paying(st) {
		t.Fatalf("inside the window: %d reads, %v, %v", reads, st, err)
	}
	r.invalidate()
	st, err = r.State(t.Context())
	if err != nil || reads != 2 || paying(st) {
		t.Fatalf("after invalidate: %d reads, %v, %v", reads, st, err)
	}
	if _, err := r.State(t.Context()); err != nil || reads != 2 {
		t.Fatalf("the window holds again after the read: %d reads", reads)
	}
}

// vouchRig is a test-mode Run (rules off unless asked) over the production
// relay transport against relaytest.
type vouchRig struct {
	*rig
	srv   *relaytest.Server
	clock *setClock
}

func startOnRelay(t *testing.T, rules bool) *vouchRig {
	t.Helper()
	policytest.Set(t, nil)
	dir := shortDir(t)
	setMeta(t, dir, state.MetaEnabled, "1")
	r := &vouchRig{rig: newRig(t, dir), srv: relaytest.Start(t), clock: &setClock{now: time.Unix(1_800_000_000, 0)}}
	o := r.options()
	o.newTransport = nil // the production relay transport
	o.RelayOrigin = r.srv.URL
	o.RelayOnlyRules = rules
	o.Clock = r.clock.Now
	o.linkEvery = 100 * time.Millisecond
	o.soonTimer = func(time.Duration) (<-chan time.Time, func()) { // the 2 s ticks, fast
		tm := time.NewTimer(20 * time.Millisecond)
		return tm.C, func() { tm.Stop() }
	}
	r.start(o)
	return r
}

// linked is a phone linked to the hub over a pairing slot (owner confirmed,
// keys in the pair zone), not vouched or promoted yet.
type linkedPhone struct {
	phone *hubtest.Phone
	store *hubtest.RelayStore
	lp    wire.LinkPayload
	slot  string
}

func (r *vouchRig) link() linkedPhone {
	r.t.Helper()
	t := r.t
	eventually(t, 10*time.Second, "the hub up, not vouched", func() bool { return r.rec.last().Reason == ReasonNotVouched })
	c, err := Dial(r.dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	if err := c.Send(ControlRequest{Op: OpPair}); err != nil {
		t.Fatal(err)
	}
	next := func(event string) ControlAnswer {
		t.Helper()
		for {
			a, err := c.Next()
			if err != nil {
				t.Fatalf("waiting for %s: %v", event, err)
			}
			if a.Error != "" {
				t.Fatalf("waiting for %s: %+v", event, a)
			}
			if a.Event == event {
				return a
			}
		}
	}
	lp, err := wire.ParseLinkURL(next(link.EventQR).URL)
	if err != nil {
		t.Fatal(err)
	}
	store := &hubtest.RelayStore{}
	phone, err := hubtest.FromLink(lp, store, nil)
	if err != nil {
		t.Fatal(err)
	}
	store.C = hubtest.NewPhoneClient(r.srv.URL, phone)
	if _, err := store.Register(t.Context()); err != nil {
		t.Fatal(err)
	}
	slot, err := store.OpenPairing(t.Context(), lp.RelayDeviceID)
	if err != nil {
		t.Fatal(err)
	}
	pair := transport.PairZone(slot)
	if err := phone.Hello(pair); err != nil {
		t.Fatal(err)
	}
	next(link.EventSAS)
	var awaiting wire.Keybox
	eventually(t, 10*time.Second, "the awaiting keybox", func() bool {
		kb, ok, err := phone.ReadKeybox(pair)
		awaiting = kb
		return err == nil && ok && kb.Grant.ConfirmNonce != nil
	})
	if _, err := phone.SAS(*awaiting.Grant.ConfirmNonce); err != nil {
		t.Fatal(err)
	}
	if err := c.Send(ControlRequest{Op: OpConfirm, Device: phone.ID().String(), Confirm: true}); err != nil {
		t.Fatal(err)
	}
	next(link.EventLinked)
	eventually(t, 10*time.Second, "the keys in the pair zone", func() bool {
		kb, ok, err := phone.ReadKeybox(pair)
		return err == nil && ok && kb.Keys != nil
	})
	return linkedPhone{phone: phone, store: store, lp: lp, slot: slot}
}

// admit is the phone's vouch then promote_pairing; the hub runs admitted.
func (r *vouchRig) admit(l linkedPhone) {
	r.t.Helper()
	if err := l.phone.VouchLink(r.t.Context(), l.lp); err != nil {
		r.t.Fatal(err)
	}
	if err := l.store.PromotePairing(r.t.Context(), l.slot); err != nil {
		r.t.Fatal(err)
	}
	r.waitState(StateRunning, "")
}

// opsOutsidePairZones lists every zone op outside a pair/ zone and every
// set_hub_readers the relay received. Before the hub is admitted the phone
// too writes and reads only pair zones, so any entry is the hub's.
func (r *vouchRig) opsOutsidePairZones() []string {
	var out []string
	note := func(op, zone string) {
		if !strings.HasPrefix(zone, "pair/") {
			out = append(out, op+" "+zone)
		}
	}
	for _, req := range r.srv.Requests("save") {
		for _, it := range req.GetSave().GetItems() {
			note("save", it.GetRecord().GetZone())
		}
	}
	for _, req := range r.srv.Requests("delete") {
		note("delete", req.GetDelete().GetZone())
	}
	for _, req := range r.srv.Requests("changes") {
		note("changes", req.GetChanges().GetZone())
	}
	for _, req := range r.srv.Requests("create_upload") {
		note("create_upload", req.GetCreateUpload().GetZone())
	}
	for range r.srv.Requests("set_hub_readers") {
		out = append(out, "set_hub_readers")
	}
	return out
}

func (r *vouchRig) device(t *testing.T) state.Device {
	t.Helper()
	st, err := state.OpenReadOnly(r.dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = st.Close() }()
	devices, err := st.Devices()
	if err != nil || len(devices) != 1 {
		t.Fatalf("devices %v, %v", devices, err)
	}
	return devices[0]
}

func (r *vouchRig) accountReads() int { return len(r.srv.Requests("get_account_state")) }

// TestUnvouchedHubOnlyWritesItsPairingSlot: registered and linked but in no
// phone's slot, the hub writes only its pair/<slot> zone — never the data
// zone, a mailbox or set_hub_readers — and says not_vouched; the phone is
// pending.
func TestUnvouchedHubOnlyWritesItsPairingSlot(t *testing.T) {
	r := startOnRelay(t, false)
	r.link()
	r.waitState(StateRunning, ReasonNotVouched)
	time.Sleep(300 * time.Millisecond) // several link and pass ticks
	if ops := r.opsOutsidePairZones(); len(ops) > 0 {
		t.Fatalf("an unvouched hub ran %v", ops)
	}
	if !r.device(t).RelayAdmittedAt.IsZero() {
		t.Fatal("a phone not holding the hub was stamped admitted")
	}
}

// TestUnvouchedHubPollsTheAccountStateAtMostEvery30s: the short link retry
// ticks fast after the link, but an unvouched hub reads the account state
// at most once per unvouchedPoll of its clock.
func TestUnvouchedHubPollsTheAccountStateAtMostEvery30s(t *testing.T) {
	r := startOnRelay(t, false)
	r.link()
	time.Sleep(200 * time.Millisecond) // ~10 short-retry ticks and two link backstops
	base := r.accountReads()
	time.Sleep(300 * time.Millisecond)
	if n := r.accountReads() - base; n != 0 {
		t.Fatalf("%d account-state reads inside one poll window", n)
	}
	r.clock.Advance(unvouchedPoll)
	eventually(t, 5*time.Second, "one read after the window", func() bool { return r.accountReads() > base })
	time.Sleep(200 * time.Millisecond)
	if n := r.accountReads() - base; n != 1 {
		t.Fatalf("%d account-state reads after one window, want 1", n)
	}
}

// TestVouchAcceptedAdmitsTheHub: vouch_hub and promote_pairing put the
// hub into the phone's slot; SLOT_ADDED opens the gate at once, the
// device_grant reaches the data zone and the phone is stamped admitted.
func TestVouchAcceptedAdmitsTheHub(t *testing.T) {
	r := startOnRelay(t, false)
	l := r.link()
	reads := r.accountReads()
	r.admit(l)
	data := transport.DataZone(l.lp.RelayDeviceID)
	eventually(t, 10*time.Second, "the device_grant in the data zone", func() bool {
		kb, ok, err := l.phone.ReadKeybox(data)
		return err == nil && ok && kb.Grant.Linked
	})
	if r.device(t).RelayAdmittedAt.IsZero() {
		t.Fatal("the admitted phone carries no relay_admitted_at")
	}
	if n := r.accountReads() - reads; n > 3 {
		t.Fatalf("%d account-state reads to learn of the slot", n)
	}
}

// TestVouchRefusedKeepsTheHubOffTheRelay: a refused vouch_hub leaves the
// phone without promote_pairing (it shows the server's reason): the hub
// stays not_vouched, writes nothing outside its pair zone and the phone
// stays pending.
func TestVouchRefusedKeepsTheHubOffTheRelay(t *testing.T) {
	for _, code := range []relayv1.ErrorCode{
		relayv1.ErrorCode_ERROR_CODE_ATTESTATION_REQUIRED,
		relayv1.ErrorCode_ERROR_CODE_ATTESTATION_FAILED,
		relayv1.ErrorCode_ERROR_CODE_SLOT_LIMIT,
	} {
		t.Run(code.String(), func(t *testing.T) {
			r := startOnRelay(t, false)
			l := r.link()
			r.srv.FailNext("vouch_hub", code)
			if err := l.phone.VouchLink(t.Context(), l.lp); err == nil {
				t.Fatal("the refused vouch succeeded")
			}
			// The phone does not promote after a refusal; a promote anyway
			// is refused too (no pending vouch).
			if err := l.store.PromotePairing(t.Context(), l.slot); err == nil {
				t.Fatal("promote_pairing without a vouch succeeded")
			}
			time.Sleep(200 * time.Millisecond)
			r.waitState(StateRunning, ReasonNotVouched)
			if ops := r.opsOutsidePairZones(); len(ops) > 0 {
				t.Fatalf("a refused hub ran %v", ops)
			}
			if !r.device(t).RelayAdmittedAt.IsZero() {
				t.Fatal("pending phone stamped admitted")
			}
		})
	}
}

// TestHubNotVouchedAfterAdmissionIsRevoked: the hub leaves its last slot
// (SLOT_REMOVED; the relay then answers it HUB_NOT_VOUCHED): vouch_revoked,
// nothing published, the sidecar intact, also across a restart; the phone's
// new vouch and add_slot admit it again.
func TestHubNotVouchedAfterAdmissionIsRevoked(t *testing.T) {
	r := startOnRelay(t, false)
	l := r.link()
	r.admit(l)
	data := transport.DataZone(l.lp.RelayDeviceID)
	eventually(t, 10*time.Second, "the device_grant in the data zone", func() bool {
		kb, ok, err := l.phone.ReadKeybox(data)
		return err == nil && ok && kb.Grant.Linked
	})

	r.srv.RemoveSlot(l.phone.RelayDeviceID(), l.lp.RelayDeviceID)
	r.waitState(StateRunning, ReasonVouchRevoked)
	saves := len(r.srv.Requests("save"))
	time.Sleep(300 * time.Millisecond)
	for _, req := range r.srv.Requests("save")[saves:] {
		for _, it := range req.GetSave().GetItems() {
			if !strings.HasPrefix(it.GetRecord().GetZone(), "pair/") {
				t.Fatalf("a revoked hub saved into %s", it.GetRecord().GetZone())
			}
		}
	}
	if d := r.device(t); d.RelayAdmittedAt.IsZero() {
		t.Fatal("the sidecar lost the phone's admission")
	}
	hubRegisters := 0
	for _, req := range r.srv.Requests("register") {
		if req.GetRegister().GetDeviceKind() == relayv1.DeviceKind_DEVICE_KIND_HUB {
			hubRegisters++
		}
	}
	if hubRegisters != 1 {
		t.Fatalf("%d hub registers: the hub registered again", hubRegisters)
	}

	// A restart while revoked reads the same.
	if err := r.stop(); err != nil {
		t.Fatal(err)
	}
	r2 := &vouchRig{rig: newRig(t, r.dir), srv: r.srv, clock: r.clock}
	o := r2.options()
	o.newTransport, o.RelayOrigin, o.Clock = nil, r.srv.URL, r.clock.Now
	r2.start(o)
	r2.waitState(StateRunning, ReasonVouchRevoked)

	if err := l.phone.VouchLink(t.Context(), l.lp); err != nil {
		t.Fatal(err)
	}
	if _, err := l.store.C.Do(t.Context(), &relayv1.Request{Op: &relayv1.Request_AddSlot{AddSlot: &relayv1.AddMacSlot{
		MacDeviceId: l.lp.RelayDeviceID,
	}}}); err != nil {
		t.Fatal(err)
	}
	r2.waitState(StateRunning, "")
}

// TestHubNeverCountsItselfOnTheRelayBeforeAdmitted: before a phone holds
// the hub in a slot it is not admitted (no paying slot), says not_vouched
// and publishes no heartbeat; in live mode (relay-only rules) it is paused
// with the same reason first.
func TestHubNeverCountsItselfOnTheRelayBeforeAdmitted(t *testing.T) {
	r := startOnRelay(t, true)
	r.waitState(StatePaused, ReasonNotVouched)
	l := r.link()
	r.waitState(StatePaused, ReasonNotVouched)
	if ops := r.opsOutsidePairZones(); len(ops) > 0 {
		t.Fatalf("an unvouched live hub ran %v", ops)
	}
	if err := l.phone.VouchLink(t.Context(), l.lp); err != nil {
		t.Fatal(err)
	}
	if err := l.store.PromotePairing(t.Context(), l.slot); err != nil {
		t.Fatal(err)
	}
	r.waitState(StateRunning, "")
}

// restart stops r's Run and starts it again on the same dir and relay with
// the link backstop off (linkEvery an hour), so only the start, a control
// or a kick read the account state.
func (r *vouchRig) restart(t *testing.T) *vouchRig {
	t.Helper()
	if err := r.stop(); err != nil {
		t.Fatal(err)
	}
	r2 := &vouchRig{rig: newRig(t, r.dir), srv: r.srv, clock: r.clock}
	o := r2.options()
	o.newTransport, o.RelayOrigin, o.Clock, o.linkEvery = nil, r.srv.URL, r.clock.Now, time.Hour
	r2.start(o)
	return r2
}

// A hub that starts already vouched — every hub after migration 00007,
// whose phones carry no stamp yet — stamps its phones from the account state
// its start read (phones relay), and a later HUB_NOT_VOUCHED reads
// vouch_revoked.
func TestHubStartedVouchedStampsItsPhonesAtOnce(t *testing.T) {
	r := startOnRelay(t, false)
	l := r.link()
	r.admit(l)
	if err := r.stop(); err != nil {
		t.Fatal(err)
	}
	st, err := state.Open(r.dir)
	if err != nil {
		t.Fatal(err)
	}
	devices, err := st.Devices()
	if err == nil {
		err = st.WithTx(t.Context(), func(tx *sql.Tx) error { return state.LinkDevice(tx, devices[0]) }) // stamp cleared
	}
	_ = st.Close()
	if err != nil {
		t.Fatal(err)
	}
	if !r.device(t).RelayAdmittedAt.IsZero() {
		t.Fatal("the stamp was not cleared")
	}

	r2 := r.restart(t)
	r2.waitState(StateRunning, "")
	eventually(t, 5*time.Second, "the phone stamped from the start's account state", func() bool {
		return !r2.device(t).RelayAdmittedAt.IsZero()
	})
	r2.srv.RemoveSlot(l.phone.RelayDeviceID(), l.lp.RelayDeviceID)
	r2.waitState(StateRunning, ReasonVouchRevoked)
}

// HUB_NOT_VOUCHED on a publisher write closes the gate at once: no poll
// (the clock is frozen, so a poll inside the window reads the last answer)
// is needed for the hub to stop and say vouch_revoked.
func TestPublisherNotVouchedClosesTheGateAtOnce(t *testing.T) {
	r := startOnRelay(t, false)
	l := r.link()
	r.srv.FailNextSaveIn(transport.DataZone(l.lp.RelayDeviceID), relayv1.ErrorCode_ERROR_CODE_HUB_NOT_VOUCHED)
	if err := l.phone.VouchLink(t.Context(), l.lp); err != nil {
		t.Fatal(err)
	}
	if err := l.store.PromotePairing(t.Context(), l.slot); err != nil {
		t.Fatal(err)
	}
	// The gate opens on SLOT_ADDED, the publisher's first data-zone save is
	// refused, and the gate closes again without a new account read.
	r.waitState(StateRunning, ReasonVouchRevoked)
}

func TestNotVouchedHasItsClassAndStartReason(t *testing.T) {
	err := fmt.Errorf("relay: connect: %w", transport.ErrNotVouched)
	if got := errClass(err); got != "not_vouched" {
		t.Errorf("errClass = %q", got)
	}
	if got := startFailure(err); got != ReasonNotVouched {
		t.Errorf("startFailure = %q", got)
	}
}
