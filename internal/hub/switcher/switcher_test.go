package switcher_test

import (
	"context"
	"crypto/ed25519"
	"database/sql"
	"errors"
	"maps"
	"slices"
	"strconv"
	"sync"
	"testing"
	"time"

	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/link"
	"watchtower/internal/hub/secure"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/switcher"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/cloudkit"
	"watchtower/internal/hub/transport/cloudkit/bridgefake"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/wire"
)

const hubRelayID = "hubrelaytest"

// sharedMailbox is the CloudKit memfake as the bridge client names
// mailboxes: every phone's is the one RelayZone.
type sharedMailbox struct{ transport.Transport }

func (sharedMailbox) MailboxFor(hub, _ string) string { return transport.SharedMailboxZone(hub) }

// world is one desktop hub on two transports: the relay memfake and CloudKit
// (the memfake behind the shared mailbox, or the bridge client over
// bridgefake), its phones and a publisher on the switcher's front.
type world struct {
	t       *testing.T
	ctx     context.Context
	st      *state.Store
	keys    *identity.Keyring
	ident   identity.Identity
	relay   *memfake.Fake
	ck      transport.Transport // the hub's CloudKit side
	ckStore hubtest.Records     // the phones' CloudKit store
	ckFake  *memfake.Fake       // the CloudKit records (availability)
	bridge  *bridgefake.Fake    // the bridge (bridgefake flavour), nil otherwise
	sw      *switcher.Switcher
	cfg     switcher.Config
	center  *link.Center
	pub     *hubslices.Publisher

	mu     sync.Mutex
	now    time.Time
	calls  []string
	paying map[string]bool
	payErr error
}

var flavours = []string{"memfake", "bridgefake"}

func eachFlavour(t *testing.T, fn func(t *testing.T, w *world)) {
	t.Helper()
	for _, f := range flavours {
		t.Run(f, func(t *testing.T) { fn(t, newWorld(t, f)) })
	}
}

func (w *world) clock() time.Time {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.now
}

func (w *world) advance(d time.Duration) {
	w.mu.Lock()
	w.now = w.now.Add(d)
	w.mu.Unlock()
}

func newWorld(t *testing.T, flavour string) *world {
	t.Helper()
	w := &world{t: t, ctx: context.Background(), now: time.Date(2026, 11, 1, 12, 0, 0, 0, time.UTC), paying: map[string]bool{}}
	st, err := state.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	w.st = st
	if w.ident, err = identity.New(); err != nil {
		t.Fatal(err)
	}
	if w.keys, err = identity.NewKeyring(w.ident, st, w.clock); err != nil {
		t.Fatal(err)
	}
	w.relay = memfake.New(transport.KindRelay, w.clock)
	switch flavour {
	case "memfake":
		w.ckFake = memfake.New(transport.KindCloudKit, w.clock)
		w.ck, w.ckStore = sharedMailbox{w.ckFake}, w.ckFake
	case "bridgefake":
		dir := bridgefake.Dir(t)
		b := bridgefake.Serve(t, dir, bridgefake.WithClock(w.clock))
		client := cloudkit.New(cloudkit.Config{Dir: dir, HubID: w.keys.HubID().String(), RelayID: hubRelayID, Clock: w.clock})
		t.Cleanup(func() { _ = client.Close() })
		w.ck, w.ckFake, w.ckStore, w.bridge = client, b.Store(), b.PhoneRecords(w.keys.HubID().String()), b
	}
	disp := actions.NewDispatcher()
	disp.Register("test_noop", func(_ context.Context, r actions.Request) actions.Outcome {
		w.mu.Lock()
		defer w.mu.Unlock()
		id := r.RecordName // a legacy action has no action_seq
		if r.Action.ActionSeq != nil {
			id = strconv.FormatUint(*r.Action.ActionSeq, 10)
		}
		w.calls = append(w.calls, *r.Action.DeviceID+":"+id)
		return actions.Outcome{Status: wire.StatusApplied}
	}, actions.KindOptions{})
	sealer := secure.NewSealer(w.keys)
	opener := secure.NewOpener(w.keys, w.keys)
	w.center = link.NewCenter(link.Config{Store: st, Keys: w.keys, Opener: opener, Clock: w.clock})
	w.cfg = switcher.Config{
		Store: st, Keys: w.keys, Relay: w.relay, CloudKit: w.ck,
		Actions: actions.Config{
			Store: st, Sealer: sealer, Opener: opener, Keys: w.keys, Dispatcher: disp,
			HubRelayID: hubRelayID, Clock: w.clock, Links: w.center,
		},
		Keyboxes: w.center.Keyboxes,
		Paying: func(context.Context) (map[string]bool, error) {
			w.mu.Lock()
			defer w.mu.Unlock()
			if w.payErr != nil {
				return nil, w.payErr
			}
			return maps.Clone(w.paying), nil
		},
		OldSideTimeout: testOldSide,
	}
	w.rebuild(nil)
	return w
}

// testOldSide is the old-side timeout the tests run with.
const testOldSide = 300 * time.Millisecond

// rebuild makes a new switcher (a restart) over the same sidecar and
// transports, with mut applied to the config, and a publisher on its front.
func (w *world) rebuild(mut func(*switcher.Config)) {
	w.t.Helper()
	cfg := w.cfg
	if mut != nil {
		mut(&cfg)
	}
	sw, err := switcher.New(cfg)
	if err != nil {
		w.t.Fatal(err)
	}
	w.sw = sw
	w.pub = hubslices.NewPublisher(hubslices.Config{
		Store: w.st, Transport: sw.Front(), Sealer: cfg.Actions.Sealer, DataZone: transport.DataZone(hubRelayID),
		Sources: []hubslices.Source{hubslices.GrantSource(w.center)}, Clock: w.clock,
	})
	sw.SetPublisher(w.pub)
}

// addPhone links a phone on CloudKit holding the current keys; pays marks it
// paying for the relay.
func (w *world) addPhone(pays bool) *hubtest.Phone {
	w.t.Helper()
	kk, err := w.keys.KeyboxKeys()
	if err != nil {
		w.t.Fatal(err)
	}
	ph, err := hubtest.New(hubtest.Config{
		Hub: w.keys.HubID(), HubKX: w.ident.Agreement.PublicKey(), HubSig: w.ident.Signing.Public().(ed25519.PublicKey),
		Epoch: kk.Epoch, HubRelayID: hubRelayID, Transport: w.ckStore, Clock: w.clock,
		Mailbox: transport.SharedMailboxZone(hubRelayID),
	})
	if err != nil {
		w.t.Fatal(err)
	}
	if err := ph.Keep(kk); err != nil {
		w.t.Fatal(err)
	}
	if err := w.st.WithTx(w.ctx, func(tx *sql.Tx) error { return state.LinkDevice(tx, ph.Device()) }); err != nil {
		w.t.Fatal(err)
	}
	w.mu.Lock()
	w.paying[ph.ID().String()] = pays
	w.mu.Unlock()
	return ph
}

// onRelay / onCloudKit move a phone's view to that transport's store.
func (w *world) onRelay(ph *hubtest.Phone) { ph.Use(w.relay, "") }
func (w *world) onCloudKit(ph *hubtest.Phone) {
	ph.Use(w.ckStore, transport.SharedMailboxZone(hubRelayID))
}

// hub runs one round of the hub: the active pass, the other side's poll and
// the switch step.
func (w *world) hub() {
	w.t.Helper()
	pctx, cancel := context.WithTimeout(w.ctx, 2*testOldSide)
	_, _ = w.sw.ActiveProcessor().Pass(pctx)
	cancel()
	if err := w.sw.Step(w.ctx); err != nil {
		w.t.Fatalf("step: %v", err)
	}
	w.sw.PollOther(w.ctx)
	if err := w.sw.Step(w.ctx); err != nil {
		w.t.Fatalf("step: %v", err)
	}
}

// settle runs hub rounds and phone syncs (a phone on an unreachable store
// just waits).
func (w *world) settle(phones ...*hubtest.Phone) {
	w.t.Helper()
	for range 8 {
		w.hub()
		for _, ph := range phones {
			_, _ = ph.Sync()
		}
	}
}

// ask writes ph's transport_switch toward target on the store it is on.
func (w *world) ask(ph *hubtest.Phone, target string) {
	w.t.Helper()
	if _, err := ph.WriteControl(wire.Control{Kind: wire.ControlSwitch, Target: &target}); err != nil {
		w.t.Fatal(err)
	}
}

// follow is a phone reacting to the transport_switched it read (rule 12):
// it moves to the target's store, takes the keys, acks and resends its
// outbox with the same bytes (rule 13).
func (w *world) follow(ph *hubtest.Phone) {
	w.t.Helper()
	c, ok := ph.LastSwitch()
	if !ok {
		w.t.Fatal("the phone read no transport_switched")
	}
	if *c.Target == wire.TransportRelay {
		w.onRelay(ph)
	} else {
		w.onCloudKit(ph)
	}
	if err := ph.Follow(c); err != nil {
		w.t.Fatal(err)
	}
	if err := ph.ResendOutbox(); err != nil {
		w.t.Fatal(err)
	}
}

func (w *world) act(ph *hubtest.Phone) uint64 {
	w.t.Helper()
	seq, err := ph.Act("test_noop")
	if err != nil {
		w.t.Fatal(err)
	}
	return seq
}

func (w *world) callLog() []string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return slices.Clone(w.calls)
}

func call(ph *hubtest.Phone, seq uint64) string {
	return ph.ID().String() + ":" + strconv.FormatUint(seq, 10)
}

func (w *world) wantCalls(want ...string) {
	w.t.Helper()
	if got := w.callLog(); !slices.Equal(got, want) {
		w.t.Fatalf("handler calls %v, want %v", got, want)
	}
}

func (w *world) epoch() uint32 {
	w.t.Helper()
	e, err := w.keys.CurrentEpoch()
	if err != nil {
		w.t.Fatal(err)
	}
	return e
}

func (w *world) wantActive(k transport.Kind) {
	w.t.Helper()
	if got := w.sw.Active().Kind(); got != k {
		w.t.Fatalf("active transport %s, want %s", got, k)
	}
	if v, _, _ := w.st.Meta(switcher.MetaTransport); v != string(k) && !(v == "" && k == transport.KindCloudKit) {
		w.t.Fatalf("hub_meta.transport %q, want %s", v, k)
	}
}

// switched are the transport_switched controls ph read.
func switched(ph *hubtest.Phone) []wire.Control {
	var out []wire.Control
	for _, c := range ph.Controls {
		if c.Kind == wire.ControlSwitched {
			out = append(out, c)
		}
	}
	return out
}

// switchedEpochs is the envelope epochs of the transport_switched ph read.
func switchedEpochs(ph *hubtest.Phone) []uint32 {
	var out []uint32
	for i, c := range ph.Controls {
		if c.Kind == wire.ControlSwitched {
			out = append(out, ph.ControlEpochs[i])
		}
	}
	return out
}

func count(ph *hubtest.Phone, kind string) int {
	n := 0
	for _, c := range ph.Controls {
		if c.Kind == kind {
			n++
		}
	}
	return n
}

// moveTo switches the hub to target on ph's request and settles; ph follows.
func (w *world) moveTo(ph *hubtest.Phone, target string, others ...*hubtest.Phone) {
	w.t.Helper()
	w.ask(ph, target)
	w.settle(append([]*hubtest.Phone{ph}, others...)...)
	w.wantActive(transport.Kind(target))
	for _, p := range append([]*hubtest.Phone{ph}, others...) {
		w.follow(p)
	}
	w.settle(append([]*hubtest.Phone{ph}, others...)...)
}

// Rule 8: only a person switches. Outages, failures, refused writes and a
// stream of transport errors never move the hub or rotate its epoch.
func TestOnlyAPersonSwitches(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		ph := w.addPhone(true)
		e := w.epoch()
		w.ckFake.SetAvailable(false)
		w.relay.FailNext("save", transport.ErrEntitlementInactive)
		w.relay.SendEvent(transport.Event{Err: transport.ErrUnavailable})
		w.relay.SendEvent(transport.Event{Control: &transport.Control{Kind: transport.SessionExpired}})
		for range 5 {
			w.hub()
			w.advance(switcher.OtherPoll)
		}
		w.ckFake.SetAvailable(true)
		w.relay.SetAvailable(false)
		w.act(ph)
		w.settle(ph)
		w.wantActive(transport.KindCloudKit)
		if w.epoch() != e || w.sw.Pending() {
			t.Fatalf("epoch %d (was %d), pending %v", w.epoch(), e, w.sw.Pending())
		}
		if _, _, ok, _ := w.sw.SwitchedAt(); ok {
			t.Fatal("a switch was recorded")
		}
	})
}

// Rules 9–10: toward the relay at least AntiFlap after the last accepted
// switch (too_soon with the wait); toward CloudKit always and at once.
func TestSwitchToRelayRejectedWithin5Min(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		ph := w.addPhone(true)
		w.moveTo(ph, wire.TransportRelay)
		w.advance(time.Minute)
		w.moveTo(ph, wire.TransportCloudKit) // toward CloudKit: at once
		w.advance(time.Minute)
		before := w.epoch()
		w.ask(ph, wire.TransportRelay)
		w.settle(ph)
		w.wantActive(transport.KindCloudKit)
		var rej []wire.Control
		for _, c := range ph.Controls {
			if c.Kind == wire.ControlSwitchRejected {
				rej = append(rej, c)
			}
		}
		if len(rej) != 1 || *rej[0].Reason != wire.SwitchTooSoon || rej[0].RetryAfterS == nil || *rej[0].RetryAfterS != 240 {
			t.Fatalf("rejections %+v", rej)
		}
		if w.epoch() != before {
			t.Fatal("a rejected switch rotated the epoch")
		}
		w.advance(4 * time.Minute)
		w.moveTo(ph, wire.TransportRelay)
		w.wantActive(transport.KindRelay)
	})
}

// Rule 10: the last accepted request wins, before and after the rotation.
func TestLastAcceptedSwitchWins(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, b := w.addPhone(true), w.addPhone(true)
		e := w.epoch()
		// Both read before the switch runs: relay then CloudKit — no move.
		if err := w.sw.Request(w.ctx, a.ID().String(), transport.KindRelay, ""); err != nil {
			t.Fatal(err)
		}
		if err := w.sw.Request(w.ctx, b.ID().String(), transport.KindCloudKit, ""); err != nil {
			t.Fatal(err)
		}
		w.settle(a, b)
		w.wantActive(transport.KindCloudKit)
		if w.epoch() != e {
			t.Fatalf("epoch %d, want %d (no switch ran)", w.epoch(), e)
		}
		// A no-op undo is no switch: anti-flap does not restart.
		if _, _, ok, _ := w.sw.SwitchedAt(); ok {
			t.Fatal("switched_at written for a switch that never ran")
		}
		// Both requesters are told where the hub runs (a's was replaced).
		for _, ph := range []*hubtest.Phone{a, b} {
			if c, ok := ph.LastSwitch(); !ok || *c.Target != wire.TransportCloudKit {
				t.Fatalf("no answer for a requester: %+v", ph.Controls)
			}
		}
		// One after the other: the later one is where the hub ends.
		if err := w.sw.Request(w.ctx, a.ID().String(), transport.KindRelay, ""); err != nil {
			t.Fatal(err)
		}
		if err := w.sw.Step(w.ctx); err != nil {
			t.Fatal(err)
		}
		if err := w.sw.Request(w.ctx, b.ID().String(), transport.KindCloudKit, ""); err != nil {
			t.Fatal(err)
		}
		w.settle(a, b)
		w.wantActive(transport.KindCloudKit)
		if w.epoch() != e+2 {
			t.Fatalf("epoch %d, want %d (two switches)", w.epoch(), e+2)
		}
	})
}

// Every accepted switch rotates exactly once, even when Step runs again or
// the hub stops between the rotation and the notices.
func TestSwitchRotatesEpochOnce(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		ph := w.addPhone(true)
		e := w.epoch()
		if err := w.sw.Request(w.ctx, ph.ID().String(), transport.KindRelay, ""); err != nil {
			t.Fatal(err)
		}
		// The relay is down for the notices: Step still finishes, once.
		w.relay.SetAvailable(false)
		for range 3 {
			if err := w.sw.Step(w.ctx); err != nil {
				t.Fatal(err)
			}
		}
		if w.epoch() != e+1 {
			t.Fatalf("epoch %d, want %d", w.epoch(), e+1)
		}
		// A restart over the same sidecar: the switch is not run again.
		again, err := switcher.New(switcher.Config{Store: w.st, Keys: w.keys, Relay: w.relay, CloudKit: w.ck,
			Actions: actions.Config{Store: w.st, Sealer: secure.NewSealer(w.keys), Opener: secure.NewOpener(w.keys, w.keys),
				Keys: w.keys, Dispatcher: actions.NewDispatcher(), HubRelayID: hubRelayID, Clock: w.clock},
			Keyboxes: w.center.Keyboxes})
		if err != nil {
			t.Fatal(err)
		}
		if err := again.Step(w.ctx); err != nil {
			t.Fatal(err)
		}
		if w.epoch() != e+1 || again.Active().Kind() != transport.KindRelay {
			t.Fatalf("after a restart: epoch %d, active %s", w.epoch(), again.Active().Kind())
		}
	})
}

// A crash between the rotation and the notices: the next Step queues the
// notices of the same switch with the same epoch.
func TestSwitchResumesAfterTheRotation(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		ph := w.addPhone(true)
		e := w.epoch()
		if err := w.sw.Request(w.ctx, ph.ID().String(), transport.KindRelay, ""); err != nil {
			t.Fatal(err)
		}
		calls := 0
		crashing, err := switcher.New(switcher.Config{Store: w.st, Keys: w.keys, Relay: w.relay, CloudKit: w.ck,
			Actions: actions.Config{Store: w.st, Sealer: secure.NewSealer(w.keys), Opener: secure.NewOpener(w.keys, w.keys),
				Keys: w.keys, Dispatcher: actions.NewDispatcher(), HubRelayID: hubRelayID, Clock: w.clock},
			Keyboxes: func() ([]wire.Keybox, error) {
				calls++
				return nil, errors.New("the hub stops here")
			}})
		if err != nil {
			t.Fatal(err)
		}
		if err := crashing.Step(w.ctx); err == nil || calls == 0 {
			t.Fatalf("step %v, keyboxes read %d times", err, calls)
		}
		if w.epoch() != e+1 || !crashing.Pending() {
			t.Fatalf("epoch %d, pending %v", w.epoch(), crashing.Pending())
		}
		w.settle(ph)
		if w.epoch() != e+1 {
			t.Fatalf("epoch %d, want %d", w.epoch(), e+1)
		}
		got := switched(ph)
		if len(got) != 1 || *got[0].Epoch != e+1 {
			t.Fatalf("notices %+v", got)
		}
	})
}

// Contract point 3: the keybox opens with the phone's dev_kx, is signed by
// hub_sig and holds epoch e+1.
func TestTransportSwitchedCarriesTheNewEpochKeybox(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		ph := w.addPhone(true)
		e := w.epoch()
		w.ask(ph, wire.TransportRelay)
		w.settle(ph)
		got := switched(ph)
		if len(got) != 1 {
			t.Fatalf("notices %+v", got)
		}
		c := got[0]
		if *c.Target != wire.TransportRelay || *c.Epoch != e+1 || *c.By != ph.ID().String() || c.At == nil ||
			c.DeviceID == nil || *c.DeviceID != ph.ID().String() || c.HubID == nil {
			t.Fatalf("notice %+v", c)
		}
		kb, err := ph.OpenSwitchKeybox(c)
		if err != nil {
			t.Fatal(err)
		}
		if kb.Keys == nil || kb.Keys.Epoch != e+1 || kb.Grant.DeviceID != ph.ID().String() {
			t.Fatalf("keybox %+v", kb)
		}
		if kb.Keys.PreviousEpoch == nil || *kb.Keys.PreviousEpoch != e {
			t.Fatalf("the keybox does not keep the old epoch: %+v", kb.Keys)
		}
		// Another phone's dev_kx does not open it.
		other := w.addPhone(true)
		if _, err := other.OpenSwitchKeybox(c); err == nil {
			t.Fatal("another phone opened the keybox")
		}
	})
}

// Rule 11 step 1: an action waiting on the old transport is applied, and
// echoed in the old epoch, before the rotation.
func TestOldTransportMailboxDrainedBeforeRotation(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		ph := w.addPhone(true)
		e := w.epoch()
		w.ask(ph, wire.TransportRelay)
		if _, err := w.sw.ActiveProcessor().Pass(w.ctx); err != nil { // the request is accepted
			t.Fatal(err)
		}
		seq := w.act(ph) // written after the request was read: the step's drain applies it
		w.wantCalls()
		if err := w.sw.Step(w.ctx); err != nil {
			t.Fatal(err)
		}
		w.wantCalls(call(ph, seq))
		var echoEpoch uint32
		b, err := w.ckStore.Changes(w.ctx, transport.SharedMailboxZone(hubRelayID), 0)
		if err != nil {
			t.Fatal(err)
		}
		name, _ := ph.Sealed(seq)
		for _, r := range b.Changed {
			if r.Name == name {
				h, err := secure.ParseHeader(r.Envelope)
				if err != nil {
					t.Fatal(err)
				}
				echoEpoch = h.Epoch
			}
		}
		if echoEpoch != e {
			t.Fatalf("the echo was sealed in epoch %d, want the old %d", echoEpoch, e)
		}
		if w.epoch() != e+1 {
			t.Fatalf("epoch %d", w.epoch())
		}
	})
}
