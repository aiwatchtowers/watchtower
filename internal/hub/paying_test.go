package hub

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/link"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/transport/relay/relayv1"
	"watchtower/internal/hub/wire"
	"watchtower/internal/policy/policytest"
)

// payClock is a fake clock with timers for the PayingWatch's polls; every
// armed timer is announced on armed.
type payClock struct {
	mu     sync.Mutex
	now    time.Time
	timers map[int]payTimer
	next   int
	armed  chan time.Duration
}

type payTimer struct {
	at time.Time
	ch chan time.Time
}

func newPayClock() *payClock {
	return &payClock{now: time.Unix(1_800_000_000, 0).UTC(), timers: map[int]payTimer{}, armed: make(chan time.Duration, 64)}
}

func (c *payClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *payClock) Timer(d time.Duration) (<-chan time.Time, func()) {
	c.mu.Lock()
	id := c.next
	c.next++
	ch := make(chan time.Time, 1)
	c.timers[id] = payTimer{at: c.now.Add(d), ch: ch}
	c.mu.Unlock()
	select {
	case c.armed <- d:
	default:
	}
	return ch, func() {
		c.mu.Lock()
		defer c.mu.Unlock()
		delete(c.timers, id)
	}
}

// Advance moves the clock and fires the timers due.
func (c *payClock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
	for id, tm := range c.timers {
		if !c.now.Before(tm.at) {
			tm.ch <- c.now
			delete(c.timers, id)
		}
	}
}

// drain forgets the timers announced so far.
func (c *payClock) drain() {
	for {
		select {
		case <-c.armed:
		default:
			return
		}
	}
}

// waitArmed waits for the next armed timer and returns its duration.
func (c *payClock) waitArmed(t *testing.T) time.Duration {
	t.Helper()
	select {
	case d := <-c.armed:
		return d
	case <-time.After(5 * time.Second):
		t.Fatal("no poll timer was armed")
		return 0
	}
}

func notPaying() *relayv1.AccountState {
	return &relayv1.AccountState{Phones: []*relayv1.SlotHolder{{PhoneDeviceId: "phone-a", Paying: false}}}
}

func onePaying() *relayv1.AccountState {
	return &relayv1.AccountState{Phones: []*relayv1.SlotHolder{
		{PhoneDeviceId: "phone-a", Paying: false}, {PhoneDeviceId: "phone-b", Paying: true},
	}}
}

// watchRig is a PayingWatch over a settable account state on a fake clock;
// every read is announced on reads with the clock's time.
type watchRig struct {
	clock   *payClock
	w       *PayingWatch
	reads   chan time.Time
	changes chan bool
	mu      sync.Mutex
	st      *relayv1.AccountState
}

func newWatchRig(t *testing.T, st *relayv1.AccountState) *watchRig {
	t.Helper()
	r := &watchRig{clock: newPayClock(), reads: make(chan time.Time, 16), changes: make(chan bool, 16), st: st}
	r.w = NewPayingWatch(func(context.Context) (*relayv1.AccountState, error) {
		r.mu.Lock()
		st := r.st
		r.mu.Unlock()
		r.reads <- r.clock.Now()
		return st, nil
	})
	r.w.timer = r.clock.Timer
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- r.w.Run(ctx, func(p bool) { r.changes <- p }) }()
	t.Cleanup(func() {
		cancel()
		if err := <-done; !errors.Is(err, context.Canceled) {
			t.Errorf("Run = %v", err)
		}
	})
	return r
}

func (r *watchRig) set(st *relayv1.AccountState) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.st = st
}

func (r *watchRig) nextRead(t *testing.T) time.Time {
	t.Helper()
	select {
	case at := <-r.reads:
		return at
	case <-time.After(5 * time.Second):
		t.Fatal("the account state was not read")
		return time.Time{}
	}
}

func (r *watchRig) nextChange(t *testing.T) bool {
	t.Helper()
	select {
	case p := <-r.changes:
		return p
	case <-time.After(5 * time.Second):
		t.Fatal("no paying change reported")
		return false
	}
}

// With no paying phone the account state is read at start and every
// NeedsRelayPoll after: at 0, 5 and 10 minutes, never in between.
func TestPausedHubRereadsTheAccountStateEvery5Min(t *testing.T) {
	r := newWatchRig(t, notPaying())
	start := r.nextRead(t)
	if r.nextChange(t) {
		t.Fatal("a state with no paying phone reported paying")
	}
	for i := 1; i <= 2; i++ {
		if d := r.clock.waitArmed(t); d != NeedsRelayPoll {
			t.Fatalf("poll armed for %v, want %v", d, NeedsRelayPoll)
		}
		r.clock.Advance(NeedsRelayPoll - time.Second)
		select {
		case at := <-r.reads:
			t.Fatalf("read at %v, before the poll", at.Sub(start))
		default:
		}
		r.clock.Advance(time.Second)
		if at := r.nextRead(t); at.Sub(start) != time.Duration(i)*NeedsRelayPoll {
			t.Fatalf("read %d at %v, want %v", i, at.Sub(start), time.Duration(i)*NeedsRelayPoll)
		}
	}
}

// ENTITLEMENT_EXPIRED, SLOT_REMOVED and ENTITLEMENT_INACTIVE re-read the
// account state at once, without waiting for a poll; other events do not.
func TestEntitlementExpiredRereadsAtOnce(t *testing.T) {
	r := newWatchRig(t, onePaying())
	r.nextRead(t)
	if !r.nextChange(t) {
		t.Fatal("one paying phone reported not paying")
	}
	for _, c := range []struct {
		name string
		ev   transport.Event
		err  error
	}{
		{"entitlement_expired", transport.Event{Control: &transport.Control{Kind: transport.EntitlementExpired}}, nil},
		{"slot_removed", transport.Event{Control: &transport.Control{Kind: transport.SlotRemoved}}, nil},
		{"inactive event", transport.Event{Err: fmt.Errorf("relay: %w", transport.ErrEntitlementInactive)}, nil},
		{"inactive save", transport.Event{}, fmt.Errorf("save: %w", transport.ErrEntitlementInactive)},
	} {
		r.w.Observe(c.ev, c.err)
		r.nextRead(t)
	}

	r.set(notPaying())
	r.w.Observe(transport.Event{Control: &transport.Control{Kind: transport.EntitlementExpired}}, nil)
	r.nextRead(t)
	if r.nextChange(t) {
		t.Fatal("the expired entitlement did not end paying")
	}
}

// Observe ignores every other event and error: nothing is queued.
func TestObserveIgnoresOtherEvents(t *testing.T) {
	w := NewPayingWatch(nil)
	for _, c := range []struct {
		ev  transport.Event
		err error
	}{
		{transport.Event{Control: &transport.Control{Kind: transport.SessionExpired}}, nil},
		{transport.Event{Control: &transport.Control{Kind: transport.SubscriptionMoved}}, nil},
		{transport.Event{Control: &transport.Control{Kind: transport.PairingOpened, Detail: "s"}}, nil},
		{transport.Event{Zone: "data/x"}, transport.ErrUnavailable},
		{transport.Event{Err: transport.ErrForbidden}, nil},
	} {
		w.Observe(c.ev, c.err)
		if len(w.kick) != 0 {
			t.Fatalf("%+v / %v asked for a re-read", c.ev, c.err)
		}
	}
	w.Observe(transport.Event{}, transport.ErrEntitlementInactive)
	if len(w.kick) != 1 {
		t.Fatal("ENTITLEMENT_INACTIVE asked for no re-read")
	}
}

// countingTransport is the hub's side of the fake, counting the hub's
// writes outside the pairing zones and its reads per zone.
type countingTransport struct {
	*memfake.Fake
	mu     sync.Mutex
	writes int
	reads  map[string]int
}

func (c *countingTransport) Save(ctx context.Context, items []transport.SaveItem) ([]transport.Outcome, error) {
	c.mu.Lock()
	for _, it := range items {
		if !strings.HasPrefix(it.Record.Zone(), transport.PairZone("")) {
			c.writes++
		}
	}
	c.mu.Unlock()
	return c.Fake.Save(ctx, items)
}

func (c *countingTransport) Delete(ctx context.Context, zone string, items []transport.DeleteItem) ([]transport.Outcome, error) {
	c.mu.Lock()
	if !strings.HasPrefix(zone, transport.PairZone("")) {
		c.writes += len(items)
	}
	c.mu.Unlock()
	return c.Fake.Delete(ctx, zone, items)
}

func (c *countingTransport) Changes(ctx context.Context, zone string, since uint64) (transport.Batch, error) {
	c.mu.Lock()
	c.reads[zone]++
	c.mu.Unlock()
	return c.Fake.Changes(ctx, zone, since)
}

func (c *countingTransport) hubWrites() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.writes
}

func (c *countingTransport) readsOf(zone string) int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.reads[zone]
}

// relayOnly is a Run with the relay-only rules on over a counting fake and a
// fake poll clock.
type relayOnly struct {
	*rig
	ct      *countingTransport
	clock   *payClock
	marks   atomic.Int32
	barrier int
}

// startRelayOnly starts an enabled hub with the rules on (rules false: off)
// whose account state is st, with a phone row written first when linked;
// configure (nil = none) adjusts the options.
func startRelayOnly(t *testing.T, rules bool, st *relayv1.AccountState, linked bool, configure func(*Options)) *relayOnly {
	t.Helper()
	policytest.Set(t, nil)
	dir := shortDir(t)
	setMeta(t, dir, state.MetaEnabled, "1")
	if linked {
		linkPhoneDirectly(t, dir)
	}
	r := &relayOnly{rig: newRig(t, dir), clock: newPayClock()}
	r.ct = &countingTransport{Fake: r.fake, reads: map[string]int{}}
	r.fake.SetAccountState(st)
	o := r.options()
	o.newTransport = func(context.Context, identity.Identity, *state.Store, []string) (transport.Transport, error) {
		r.dials.Add(1)
		return r.ct, nil
	}
	o.RelayOnlyRules = rules
	o.payTimer = r.clock.Timer
	o.Register = func(d *actions.Dispatcher) {
		d.Register("test_mark", func(context.Context, actions.Request) actions.Outcome {
			r.marks.Add(1)
			return actions.Outcome{Status: wire.StatusApplied}
		}, actions.KindOptions{})
	}
	if configure != nil {
		configure(&o)
	}
	if !rules {
		o.payTimer = nil
	}
	r.start(o)
	return r
}

// settled waits until the hub's worker handled every event sent before:
// it reads the zone of a pairing slot opened after them.
func (r *relayOnly) settled() {
	r.t.Helper()
	r.barrier++
	slot := fmt.Sprintf("barrier%d", r.barrier)
	r.fake.SendEvent(transport.Event{Control: &transport.Control{Kind: transport.PairingOpened, Detail: slot}})
	eventually(r.t, 10*time.Second, "the worker to reach "+slot, func() bool {
		return r.ct.readsOf(transport.PairZone(slot)) > 0
	})
}

func (r *relayOnly) dataZone() string {
	r.t.Helper()
	s, err := ReadStatus(r.dir)
	if err != nil {
		r.t.Fatal(err)
	}
	return transport.DataZone(s.RelayDeviceID)
}

// pair links a phone through the pairing slot with the control socket, the
// way the owner's terminal does; promote (nil = none) runs before the
// owner confirms the code, as a phone's promote_pairing would.
func (r *relayOnly) pair(promote func()) (*hubtest.Phone, wire.LinkPayload) {
	r.t.Helper()
	t := r.t
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
	qr := next(link.EventQR)
	lp, err := wire.ParseLinkURL(qr.URL)
	if err != nil {
		t.Fatal(err)
	}
	phone, err := hubtest.FromLink(lp, r.fake, nil)
	if err != nil {
		t.Fatal(err)
	}
	pair := transport.PairZone("slot1")
	if err := phone.Hello(pair); err != nil {
		t.Fatal(err)
	}
	r.fake.SendEvent(transport.Event{Control: &transport.Control{Kind: transport.PairingOpened, Detail: "slot1"}})
	next(link.EventSAS)
	var awaiting wire.Keybox
	eventually(t, 10*time.Second, "the awaiting keybox in the pair zone", func() bool {
		kb, ok, err := phone.ReadKeybox(pair)
		if err != nil {
			t.Fatal(err)
		}
		awaiting = kb
		return ok && kb.Grant.ConfirmNonce != nil
	})
	if _, err := phone.SAS(*awaiting.Grant.ConfirmNonce); err != nil {
		t.Fatal(err)
	}
	if promote != nil {
		promote()
	}
	if err := c.Send(ControlRequest{Op: OpConfirm, Device: phone.ID().String(), Confirm: true}); err != nil {
		t.Fatal(err)
	}
	next(link.EventLinked)
	eventually(t, 10*time.Second, "the keys in the pair zone", func() bool {
		kb, ok, err := phone.ReadKeybox(pair)
		if err != nil {
			t.Fatal(err)
		}
		return ok && kb.Keys != nil
	})
	return phone, lp
}

// pairAndRun links a phone that pays from its promotion on: the hub runs.
func (r *relayOnly) pairAndRun() *hubtest.Phone {
	r.t.Helper()
	r.waitState(StatePaused, ReasonNeedsRelay)
	phone, _ := r.pair(func() { r.fake.SetAccountState(onePaying()) })
	r.waitState(StateRunning, "")
	return phone
}

// pauseNow ends the phones' entitlement: the relay's ENTITLEMENT_EXPIRED
// pauses the hub without waiting for a poll.
func (r *relayOnly) pauseNow() {
	r.t.Helper()
	r.fake.SetAccountState(notPaying())
	r.fake.SendEvent(transport.Event{Control: &transport.Control{Kind: transport.EntitlementExpired}})
	r.waitState(StatePaused, ReasonNeedsRelay)
}

func (r *relayOnly) grantInDataZone(phone *hubtest.Phone) bool {
	r.t.Helper()
	kb, ok, err := phone.ReadKeybox(r.dataZone())
	if err != nil {
		r.t.Fatal(err)
	}
	return ok && kb.Grant.Linked
}

// Off (FromEnv's test mode), nothing pauses and the account state is
// never read: Phase 1's behaviour.
func TestRelayOnlyRulesOffNeverPause(t *testing.T) {
	r := startRelayOnly(t, false, notPaying(), true, nil)
	r.waitState(StateRunning, "")
	eventually(t, 10*time.Second, "the heartbeat published", func() bool {
		return slices.Contains(liveRecords(t, r.fake, r.dataZone()), "heartbeat")
	})
	r.fake.SendEvent(transport.Event{Control: &transport.Control{Kind: transport.EntitlementExpired}})
	r.settled()
	if n := r.fake.AccountStateReads(); n != 0 {
		t.Fatalf("the account state was read %d times with the rules off", n)
	}
	if s := r.rec.last(); s.State != StateRunning {
		t.Fatalf("status %+v", s)
	}
}

// Every phone holding the hub not paying: the hub pauses from its start,
// writes nothing to its data zone or a mailbox, and says needs_relay.
func TestHeadlessHubPausesWithoutAPayingPhone(t *testing.T) {
	r := startRelayOnly(t, true, notPaying(), true, nil)
	r.waitState(StatePaused, ReasonNeedsRelay)
	s, err := ReadStatus(r.dir)
	if err != nil || s.State != StatePaused || s.Reason != ReasonNeedsRelay {
		t.Fatalf("status file %+v, %v", s, err)
	}
	r.fake.SendEvent(transport.Event{Zone: r.dataZone(), Resync: true})
	r.settled()
	if n := r.ct.hubWrites(); n != 0 {
		t.Fatalf("a paused hub wrote %d records", n)
	}
	if got := liveRecords(t, r.fake, r.dataZone()); len(got) != 0 {
		t.Fatalf("the data zone holds %d records", len(got))
	}
}

// A hub with no phone yet (a fresh install) pairs while paused; once the
// new phone pays, it resumes and publishes the device_grant.
func TestPairingWorksWhilePaused(t *testing.T) {
	r := startRelayOnly(t, true, nil, false, nil)
	r.waitState(StatePaused, ReasonNeedsRelay)
	phone, lp := r.pair(func() {
		if got := liveRecords(t, r.fake, r.dataZone()); len(got) != 0 {
			t.Fatalf("%d records went out while paused", len(got))
		}
		r.fake.SetAccountState(onePaying())
	})
	if !slices.Equal(lp.Transports, []string{wire.TransportRelay}) {
		t.Fatalf("link code transports %v", lp.Transports)
	}
	r.waitState(StateRunning, "")
	eventually(t, 10*time.Second, "the device_grant in the data zone", func() bool {
		return r.grantInDataZone(phone)
	})
}

// An action written during the pause: no handler runs, no echo is written,
// nothing is saved; after the resume (the 5-minute poll finds a paying
// phone) it is applied once and echoed applied.
func TestPausedHubKeepsStateAndRunsNoHandler(t *testing.T) {
	r := startRelayOnly(t, true, nil, false, nil)
	phone := r.pairAndRun()
	r.clock.drain()
	r.pauseNow()
	writes := r.ct.hubWrites()
	seq, err := phone.Act("test_mark")
	if err != nil {
		t.Fatal(err)
	}
	r.settled()
	if n := r.marks.Load(); n != 0 {
		t.Fatalf("the handler ran %d times while paused", n)
	}
	if n := r.ct.hubWrites() - writes; n != 0 {
		t.Fatalf("a paused hub wrote %d records", n)
	}
	if _, err := phone.Sync(); err != nil {
		t.Fatal(err)
	}
	if _, ok := phone.Echoes[seq]; ok {
		t.Fatal("an echo reached the phone while paused")
	}

	r.fake.SetAccountState(onePaying())
	if d := r.clock.waitArmed(t); d != NeedsRelayPoll {
		t.Fatalf("poll armed for %v", d)
	}
	r.clock.Advance(NeedsRelayPoll)
	r.waitState(StateRunning, "")
	eventually(t, 10*time.Second, "the applied echo", func() bool {
		if _, err := phone.Sync(); err != nil {
			t.Fatal(err)
		}
		return phone.Echoes[seq].Status == wire.StatusApplied
	})
	r.settled()
	if n := r.marks.Load(); n != 1 {
		t.Fatalf("the handler ran %d times, want once", n)
	}
}

// One paying phone among others keeps the hub publishing, and an
// ENTITLEMENT_EXPIRED that leaves it paying does not pause it.
func TestOnePayingPhoneKeepsTheHubPublishing(t *testing.T) {
	r := startRelayOnly(t, true, onePaying(), true, nil)
	r.waitState(StateRunning, "")
	eventually(t, 10*time.Second, "the heartbeat published", func() bool {
		return slices.Contains(liveRecords(t, r.fake, r.dataZone()), "heartbeat")
	})
	reads := r.fake.AccountStateReads()
	r.fake.SendEvent(transport.Event{Control: &transport.Control{Kind: transport.EntitlementExpired}})
	eventually(t, 10*time.Second, "the account state re-read", func() bool {
		return r.fake.AccountStateReads() > reads
	})
	r.settled()
	if s := r.rec.last(); s.State != StateRunning || s.Reason != "" {
		t.Fatalf("status %+v", s)
	}
}

// countingSource is a target slice that counts its reads.
type countingSource struct{ reads atomic.Int32 }

func (*countingSource) Kind() hubslices.Kind { return "target" }
func (s *countingSource) Items(context.Context) ([]hubslices.Item, error) {
	s.reads.Add(1)
	return []hubslices.Item{{ID: "1", Payload: []byte(`{"id":1}`)}}, nil
}

// A paused hub reads no slice source; the resume runs one full diff, which
// publishes what is there.
func TestResumePublishesOneFullDiff(t *testing.T) {
	src := &countingSource{}
	r := startRelayOnly(t, true, notPaying(), true, func(o *Options) {
		o.Sources = func(*state.Store) []hubslices.Source { return []hubslices.Source{src} }
	})
	r.waitState(StatePaused, ReasonNeedsRelay)
	r.clock.waitArmed(t)
	r.settled()
	if n := src.reads.Load(); n != 0 {
		t.Fatalf("a paused hub read a source %d times", n)
	}

	r.fake.SetAccountState(onePaying())
	r.clock.Advance(NeedsRelayPoll)
	r.waitState(StateRunning, "")
	eventually(t, 10*time.Second, "the full diff", func() bool {
		got := liveRecords(t, r.fake, r.dataZone())
		return slices.Contains(got, "heartbeat") && len(got) >= 2
	})
	if n := src.reads.Load(); n < 1 {
		t.Fatalf("source read %d times after the resume", n)
	}
}

// A headless hub stays relay-only: its link code and device_grant name the
// relay alone, and a phone's transport_switch still gets Plan 1a's
// transport_switch_rejected (guard over Phase 1).
func TestHeadlessHubNeverUsesCloudKit(t *testing.T) {
	r := startRelayOnly(t, true, nil, false, nil)
	r.waitState(StatePaused, ReasonNeedsRelay)
	phone, lp := r.pair(func() { r.fake.SetAccountState(onePaying()) })
	if !slices.Equal(lp.Transports, []string{wire.TransportRelay}) {
		t.Fatalf("link code transports %v", lp.Transports)
	}
	r.waitState(StateRunning, "")
	eventually(t, 10*time.Second, "a relay-only device_grant", func() bool {
		kb, ok, err := phone.ReadKeybox(r.dataZone())
		if err != nil {
			t.Fatal(err)
		}
		return ok && kb.Grant.Linked && slices.Equal(kb.Grant.Transports, []string{wire.TransportRelay})
	})
	target := wire.TransportCloudKit
	if _, err := phone.WriteControl(wire.Control{Kind: wire.ControlSwitch, Target: &target}); err != nil {
		t.Fatal(err)
	}
	eventually(t, 10*time.Second, "transport_switch_rejected", func() bool {
		if _, err := phone.Sync(); err != nil {
			t.Fatal(err)
		}
		return slices.ContainsFunc(phone.Controls, func(c wire.Control) bool { return c.Kind == wire.ControlSwitchRejected })
	})
	if r.ct.Kind() != transport.KindRelay {
		t.Fatal("the hub's transport is not the relay")
	}
}

// A transport without the relay's account state cannot run the rules: the
// hub does not start (fail closed) rather than run unpaused.
func TestRelayOnlyRulesNeedTheAccountState(t *testing.T) {
	policytest.Set(t, nil)
	dir := shortDir(t)
	setMeta(t, dir, state.MetaEnabled, "1")
	r := newRig(t, dir)
	o := r.options()
	o.newTransport = func(context.Context, identity.Identity, *state.Store, []string) (transport.Transport, error) {
		return struct{ transport.Transport }{r.fake}, nil
	}
	o.RelayOnlyRules = true
	r.start(o)
	r.waitState(StateStarting, ReasonStartFailed)
}
