package hub

import (
	"context"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"database/sql"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/link"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/wire"
	"watchtower/internal/policy/policytest"
)

// ckShares is a CloudKit-kind memfake with the bridge's linking surface:
// the shared RelayZone, an available account, the shares' accepted
// participants, the share calls recorded (op, or op:zone:users for a
// removal), the first failing calls of an op and the ops held until
// released. Its events go through out; quiet drops the memfake's own (the
// zone events of the phones' writes) while inject still delivers.
type ckShares struct {
	*memfake.Fake
	out   chan transport.Event
	quiet atomic.Bool

	mu    sync.Mutex
	calls []string
	fail  map[string]int
	held  map[string]chan struct{}
	parts map[string][]string
}

func newCKShares() *ckShares {
	return &ckShares{
		Fake: memfake.New(transport.KindCloudKit, nil), out: make(chan transport.Event, 64),
		fail: map[string]int{}, held: map[string]chan struct{}{}, parts: map[string][]string{},
	}
}

// forward passes the memfake's events on until ctx ends.
func (c *ckShares) forward(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case ev := <-c.Fake.Events():
			if c.quiet.Load() {
				continue
			}
			select {
			case c.out <- ev:
			case <-ctx.Done():
				return
			}
		}
	}
}

func (c *ckShares) Events() <-chan transport.Event { return c.out }

func (c *ckShares) inject(ev transport.Event) { c.out <- ev }

func (c *ckShares) call(ctx context.Context, op string) error {
	c.mu.Lock()
	c.calls = append(c.calls, op)
	gate := c.held[op]
	failing := c.fail[op] > 0
	if failing {
		c.fail[op]--
	}
	c.mu.Unlock()
	if gate != nil {
		select {
		case <-gate:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	if failing {
		return transport.ErrUnavailable
	}
	return nil
}

func (c *ckShares) failNext(op string, n int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.fail[op] = n
}

// hold holds every call of op until the returned release.
func (c *ckShares) hold(op string) (release func()) {
	gate := make(chan struct{})
	c.mu.Lock()
	c.held[op] = gate
	c.mu.Unlock()
	var once sync.Once
	return func() { once.Do(func() { close(gate) }) }
}

func (c *ckShares) count(prefix string) int {
	c.mu.Lock()
	defer c.mu.Unlock()
	n := 0
	for _, op := range c.calls {
		if strings.HasPrefix(op, prefix) {
			n++
		}
	}
	return n
}

// join puts user on the shares of zones as an accepted participant.
func (c *ckShares) join(user string, zones ...string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, z := range zones {
		c.parts[z] = append(c.parts[z], user)
	}
}

func (c *ckShares) members(zone string) []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return slices.Clone(c.parts[zone])
}

func (c *ckShares) MailboxFor(hub, _ string) string { return transport.SharedMailboxZone(hub) }

func (c *ckShares) AccountStatus(ctx context.Context) (transport.Account, error) {
	return transport.AccountAvailable, c.call(ctx, "account_status")
}

func (c *ckShares) OwnerUser(ctx context.Context) (string, error) {
	return "_owner-acme", c.call(ctx, "owner_user")
}

func (c *ckShares) EnsureShares(ctx context.Context) (string, string, error) {
	return "https://share.example.com/d", "https://share.example.com/r", c.call(ctx, "ensure_shares")
}

func (c *ckShares) SetPublicLink(ctx context.Context, open bool) error {
	if open {
		return c.call(ctx, "set_public_link:open")
	}
	return c.call(ctx, "set_public_link:close")
}

func (c *ckShares) Participants(ctx context.Context, zone string) ([]transport.Participant, error) {
	if err := c.call(ctx, "participants"); err != nil {
		return nil, err
	}
	var out []transport.Participant
	for _, u := range c.members(zone) {
		out = append(out, transport.Participant{UserRecordName: u, Accepted: true})
	}
	return out, nil
}

func (c *ckShares) RemoveParticipants(ctx context.Context, zone string, users []string) error {
	if err := c.call(ctx, "remove_participants:"+zone+":"+strings.Join(users, ",")); err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.parts[zone] = slices.DeleteFunc(c.parts[zone], func(u string) bool { return slices.Contains(users, u) })
	return nil
}

// ckHub is a running hub over ckShares, enabled, with its control client.
type ckHub struct {
	*rig
	ck     *ckShares
	c      *ControlClient
	status Status
	passes *atomic.Int64
}

// startCloudKitHub runs a hub over a ckShares; before runs on the hub dir
// and the fake first (meta, a linked phone, failing calls), configure on
// the options.
func startCloudKitHub(t *testing.T, before func(dir string, ck *ckShares), configure func(*Options)) *ckHub {
	t.Helper()
	policytest.Set(t, nil)
	dir := shortDir(t)
	r := newRig(t, dir)
	ck := newCKShares()
	fctx, fcancel := context.WithCancel(context.Background())
	t.Cleanup(fcancel)
	go ck.forward(fctx)
	r.fake = ck.Fake
	if before != nil {
		before(dir, ck)
	}
	passes := &atomic.Int64{}
	o := r.options()
	o.newTransport = func(context.Context, identity.Identity, *state.Store, []string) (transport.Transport, error) {
		return ck, nil
	}
	o.onPass = func() { passes.Add(1) }
	if configure != nil {
		configure(&o)
	}
	r.start(o)
	r.waitState(StateOff, ReasonDisabled)
	eventually(t, 5*time.Second, "the control socket", func() bool {
		_, err := os.Stat(filepath.Join(dir, SocketName))
		return err == nil
	})
	c, err := Dial(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	if a, err := c.Do(ControlRequest{Op: OpEnable}); err != nil || !a.OK {
		t.Fatalf("enable: %+v, %v", a, err)
	}
	r.waitState(StateRunning, "")
	status, err := ReadStatus(dir)
	if err != nil {
		t.Fatal(err)
	}
	if status.Transport != string(transport.KindCloudKit) {
		t.Fatalf("status: %+v", status)
	}
	return &ckHub{rig: r, ck: ck, c: c, status: status, passes: passes}
}

// zones are the hub's two share zones (data, relay).
func (h *ckHub) zones() []string {
	return []string{transport.DataZone(h.status.RelayDeviceID), transport.SharedMailboxZone(h.status.RelayDeviceID)}
}

// sweepMark reads hub_meta's share_sweep_pending from a second handle.
func (h *ckHub) sweepMark() string {
	h.t.Helper()
	st, err := state.Open(h.dir)
	if err != nil {
		h.t.Fatal(err)
	}
	defer func() { _ = st.Close() }()
	v, _, err := st.Meta(link.MetaShareSweepPending)
	if err != nil {
		h.t.Fatal(err)
	}
	return v
}

// next reads the control stream up to event.
func (h *ckHub) next(event string) ControlAnswer {
	h.t.Helper()
	for {
		a, err := h.c.Next()
		if err != nil {
			h.t.Fatalf("waiting for %s: %v", event, err)
		}
		if a.Error != "" {
			h.t.Fatalf("waiting for %s: %+v", event, a)
		}
		if a.Event == event {
			return a
		}
	}
}

// settle waits until no pass started for 200 ms.
func (h *ckHub) settle() int64 {
	settled := h.passes.Load()
	for {
		time.Sleep(200 * time.Millisecond)
		n := h.passes.Load()
		if n == settled {
			return n
		}
		settled = n
	}
}

// fakeCadence is a CloudKit hub's clock and pass ticker under the test's
// control (the link check's short-retry timer never fires).
type fakeCadence struct {
	now   atomic.Int64
	ticks chan time.Time
}

func newFakeCadence() *fakeCadence {
	f := &fakeCadence{ticks: make(chan time.Time)}
	f.now.Store(time.Unix(1_800_000_000, 0).UnixNano())
	return f
}

func (f *fakeCadence) clock() time.Time { return time.Unix(0, f.now.Load()).UTC() }

func (f *fakeCadence) advance(d time.Duration) { f.now.Add(int64(d)) }

func (f *fakeCadence) configure(o *Options) {
	o.Clock = f.clock
	o.passEvery, o.linkEvery = time.Hour, time.Hour
	o.passTicker = func(time.Duration) (<-chan time.Time, func()) { return f.ticks, func() {} }
	o.soonTimer = func(time.Duration) (<-chan time.Time, func()) { return nil, func() {} }
}

// tickPasses advances the clock by d, ticks, and reports whether the tick
// ran a pass: a second tick at the same instant (which passes no more than
// the first) is sent so the first was handled before the count is read.
func (h *ckHub) tickPasses(f *fakeCadence, d time.Duration) bool {
	h.t.Helper()
	before := h.passes.Load()
	f.advance(d)
	f.ticks <- time.Time{}
	f.ticks <- time.Time{}
	return h.passes.Load() > before
}

func TestCloudKitPassIs3sWhileInTouchElse30s(t *testing.T) {
	if CloudKitActivePass != 3*time.Second || CloudKitIdlePass != 30*time.Second || cloudKitTouchWindow != 10*time.Minute {
		t.Fatalf("cadence = %v / %v, window %v", CloudKitActivePass, CloudKitIdlePass, cloudKitTouchWindow)
	}
	now := time.Unix(1_800_000_000, 0).UTC()
	for _, tc := range []struct {
		name      string
		lastTouch time.Time
		urgent    bool
		want      time.Duration
	}{
		{"no phone wrote since start", time.Time{}, false, CloudKitIdlePass},
		{"a phone wrote just now", now, false, CloudKitActivePass},
		{"a phone wrote 9m59s ago", now.Add(-cloudKitTouchWindow + time.Second), false, CloudKitActivePass},
		{"a phone wrote 10m ago", now.Add(-cloudKitTouchWindow), false, CloudKitIdlePass},
		{"a link is waiting", time.Time{}, true, CloudKitActivePass},
		{"a link is waiting, the phone long gone", now.Add(-time.Hour), true, CloudKitActivePass},
	} {
		if got := cloudKitPassEvery(now, tc.lastTouch, tc.urgent); got != tc.want {
			t.Errorf("%s: %v, want %v", tc.name, got, tc.want)
		}
	}
	// A tick a few milliseconds early still passes (half a tick of slack).
	last := now.Add(-CloudKitActivePass + 5*time.Millisecond)
	if !cloudKitPassDue(now, last, now, false) {
		t.Error("an active pass skipped for a tick 5 ms early")
	}
	if cloudKitPassDue(now, now.Add(-CloudKitActivePass), time.Time{}, false) {
		t.Error("an idle hub passed after 3 s")
	}
}

// The worker's cadence on the fake clock: idle, a pass every 30 s and none
// at the 3 s ticks between; in touch (a phone's write), one at every 3 s
// tick; ten minutes after the touch, idle again.
func TestCloudKitWorkerPassesOnTheCadence(t *testing.T) {
	f := newFakeCadence()
	h := startCloudKitHub(t, nil, f.configure)
	h.settle()
	for i := range 9 {
		if h.tickPasses(f, CloudKitActivePass) {
			t.Fatalf("idle: a pass at tick %d (%v after the last)", i+1, time.Duration(i+1)*CloudKitActivePass)
		}
	}
	if !h.tickPasses(f, CloudKitActivePass) {
		t.Fatal("idle: no pass 30 s after the last")
	}
	h.ck.inject(transport.Event{Zone: transport.SharedMailboxZone(h.status.RelayDeviceID)}) // a phone wrote
	eventually(t, 5*time.Second, "the pass of the phone's write", func() bool { return h.passes.Load() > 0 })
	h.settle()
	for i := range 5 {
		if !h.tickPasses(f, CloudKitActivePass) {
			t.Fatalf("in touch: no pass at tick %d", i+1)
		}
	}
	if !h.tickPasses(f, cloudKitTouchWindow) {
		t.Fatal("no pass after ten minutes")
	}
	if h.tickPasses(f, CloudKitActivePass) {
		t.Fatal("still active ten minutes after the touch")
	}
}

// A hello read before any phone is linked; the confirm closes the link
// (CloseUsed) in the background. While the answer grace runs the pass is
// active with no phone in touch (an urgent link) and no sweep runs; at the
// grace's end the sweep takes the stranger's participant off and clears the
// mark, and the cadence goes idle.
func TestCloudKitConfirmCloseKeepsTheParticipantsForTheGrace(t *testing.T) {
	f := newFakeCadence()
	var zones []string
	h := startCloudKitHub(t, func(dir string, ck *ckShares) {
		leftOpenFailingOnce(t)(dir, ck)
		ck.quiet.Store(true) // no zone events: passes come from the ticks only
	}, f.configure)
	zones = h.zones()
	h.ck.join("_stranger-acme", zones...)
	h.waitFailedRestartClose()
	if err := h.c.Send(ControlRequest{Op: OpPair}); err != nil {
		t.Fatal(err)
	}
	lp, err := wire.ParseLinkURL(h.next(link.EventQR).URL)
	if err != nil {
		t.Fatal(err)
	}
	phone, err := hubtest.FromLink(lp, h.ck.Fake, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := phone.Hello(zones[1]); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if !h.tickPasses(f, CloudKitIdlePass) {
		t.Fatal("no idle pass")
	}
	h.next(link.EventSAS)
	if err := h.c.Send(ControlRequest{Op: OpConfirm, Device: phone.ID().String(), Confirm: true}); err != nil {
		t.Fatal(err)
	}
	h.next(link.EventLinked)
	eventually(t, 5*time.Second, "the close after the confirm", func() bool { return h.ck.count("set_public_link:close") == 2 })
	h.settle()
	reads := h.ck.count("participants")
	for _, d := range []time.Duration{CloudKitActivePass, CloudKitActivePass, time.Minute} {
		if !h.tickPasses(f, d) {
			t.Fatal("no active pass while the answer grace runs")
		}
	}
	if n := h.ck.count("participants"); n != reads || h.ck.count("remove_participants") != 0 {
		t.Fatal("a sweep ran before the answer grace ended")
	}
	if !h.tickPasses(f, link.DefaultSweep.AnswerGrace) {
		t.Fatal("no pass at the grace's end")
	}
	eventually(t, 5*time.Second, "the sweep after the grace", func() bool { return h.sweepMark() == "0" })
	for _, z := range zones {
		if got := h.ck.members(z); len(got) != 0 {
			t.Errorf("%s still has %v", z, got)
		}
	}
	if h.tickPasses(f, CloudKitActivePass) {
		t.Fatal("still active after the grace")
	}
}

func TestPullNowRunsAPassAtOnce(t *testing.T) {
	var mu sync.Mutex
	var urgent bool
	h := startCloudKitHub(t, nil, func(o *Options) {
		o.passEvery, o.linkEvery = time.Hour, time.Hour
		o.published = func(kinds []hubslices.Kind) {
			if slices.Contains(kinds, hubslices.UrgentKinds[0]) {
				mu.Lock()
				urgent = true
				mu.Unlock()
			}
		}
	})
	// The start's passes settle; with no phone in touch the CloudKit
	// cadence is idle (30 s), so no tick passes meanwhile.
	settled := h.settle()
	mu.Lock()
	urgent = false
	mu.Unlock()
	h.ck.inject(transport.Event{PullNow: true})
	// A pass at once, and the link check's pass after it (the relay's resync).
	eventually(t, 2*time.Second, "two passes after the push", func() bool { return h.passes.Load() >= settled+2 })
	mu.Lock()
	defer mu.Unlock()
	if !urgent {
		t.Fatal("the push did not publish what the phones wait for")
	}
}

// A link an earlier run left open (the sweep marked pending) is closed once
// at start, with no grace: the public link closes, the participants are
// swept, the mark clears.
func TestCloudKitHubClosesALinkLeftOpenAtStart(t *testing.T) {
	h := startCloudKitHub(t, func(dir string, _ *ckShares) { setMeta(t, dir, link.MetaShareSweepPending, "1") }, nil)
	eventually(t, 5*time.Second, "the restart close", func() bool { return h.sweepMark() == "0" })
	if h.ck.count("set_public_link:close") == 0 || h.ck.count("participants") == 0 {
		t.Fatalf("no restart close")
	}
	if n := h.ck.count("set_public_link:open"); n != 0 {
		t.Fatalf("the public link was opened %d times", n)
	}
}

// With nothing marked the start makes no share call.
func TestCloudKitHubStartsWithNoShareCallWhenNothingIsLeftOpen(t *testing.T) {
	h := startCloudKitHub(t, nil, nil)
	time.Sleep(300 * time.Millisecond)
	if n := h.ck.count("set_public_link") + h.ck.count("participants") + h.ck.count("remove_participants"); n != 0 {
		t.Fatalf("%d share calls at start", n)
	}
}

// leftOpenFailingOnce marks the sweep pending (a link an earlier run left
// open) and fails the restart close's public-link call once, so the mark is
// still pending after the start.
func leftOpenFailingOnce(t *testing.T) func(string, *ckShares) {
	return func(dir string, ck *ckShares) {
		setMeta(t, dir, link.MetaShareSweepPending, "1")
		ck.failNext("set_public_link:close", 1)
	}
}

// waitFailedRestartClose waits for the restart close that failed.
func (h *ckHub) waitFailedRestartClose() {
	h.t.Helper()
	eventually(h.t, 5*time.Second, "the failed restart close", func() bool { return h.ck.count("set_public_link:close") == 1 })
	if h.sweepMark() != "1" {
		h.t.Fatal("the failed restart close cleared the mark")
	}
}

// The bridge's account_changed closes the link the old iCloud user opened,
// with no grace: the sweep runs at once.
func TestCloudKitAccountChangedClosesTheLink(t *testing.T) {
	h := startCloudKitHub(t, leftOpenFailingOnce(t), nil)
	h.waitFailedRestartClose()
	h.ck.inject(transport.Event{AccountChanged: true})
	eventually(t, 5*time.Second, "the close after the account change", func() bool { return h.sweepMark() == "0" })
	if n := h.ck.count("set_public_link:close"); n != 2 {
		t.Fatalf("%d public-link closes, want 2", n)
	}
}

// A hello in the shared RelayZone reaches the link center before any phone
// is linked; the owner's confirm links it and closes the link (CloseUsed:
// the public link closes now, the participants wait for the grace).
func TestCloudKitHelloInTheRelayZoneLinksAndTheConfirmClosesTheLink(t *testing.T) {
	h := startCloudKitHub(t, leftOpenFailingOnce(t), nil)
	h.waitFailedRestartClose()
	if err := h.c.Send(ControlRequest{Op: OpPair}); err != nil {
		t.Fatal(err)
	}
	lp, err := wire.ParseLinkURL(h.next(link.EventQR).URL)
	if err != nil {
		t.Fatal(err)
	}
	phone, err := hubtest.FromLink(lp, h.ck.Fake, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := phone.Hello(transport.SharedMailboxZone(h.status.RelayDeviceID)); err != nil {
		t.Fatal(err)
	}
	sas := h.next(link.EventSAS)
	if sas.DeviceID != phone.ID().String() {
		t.Fatalf("sas for %s, want %s", sas.DeviceID, phone.ID())
	}
	if err := h.c.Send(ControlRequest{Op: OpConfirm, Device: phone.ID().String(), Confirm: true}); err != nil {
		t.Fatal(err)
	}
	h.next(link.EventLinked)
	eventually(t, 5*time.Second, "the close after the confirm", func() bool { return h.ck.count("set_public_link:close") == 2 })
	if n := h.ck.count("remove_participants"); n != 0 {
		t.Fatalf("participants swept before the answer grace (%d calls)", n)
	}
}

// F1/F2: with the bridge hanging, the owner's confirm and Remove are
// answered once their database change is made, and the hub stops without
// waiting for the hung share calls.
func TestCloudKitConfirmAndRemoveNeverWaitOnTheBridge(t *testing.T) {
	h := startCloudKitHub(t, func(dir string, ck *ckShares) {
		leftOpenFailingOnce(t)(dir, ck)
		linkSharedPhone(t, dir, sharedPhoneID, "_colleague-a")
	}, nil)
	h.waitFailedRestartClose()
	h.ck.join("_colleague-a", h.zones()...)
	release := h.ck.hold("set_public_link:close")
	defer release()
	defer h.ck.hold("remove_participants:" + h.zones()[0] + ":_colleague-a")()
	if err := h.c.Send(ControlRequest{Op: OpPair}); err != nil {
		t.Fatal(err)
	}
	lp, err := wire.ParseLinkURL(h.next(link.EventQR).URL)
	if err != nil {
		t.Fatal(err)
	}
	phone, err := hubtest.FromLink(lp, h.ck.Fake, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := phone.Hello(h.zones()[1]); err != nil {
		t.Fatal(err)
	}
	h.next(link.EventSAS)

	answered := func(what string, do func() ControlAnswer) {
		t.Helper()
		start := time.Now()
		if a := do(); !a.OK {
			t.Fatalf("%s: %+v", what, a)
		}
		if d := time.Since(start); d > 2*time.Second {
			t.Fatalf("%s answered after %v: it waited on the bridge", what, d)
		}
	}
	c2, err := Dial(h.dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = c2.Close() }()
	answered("confirm", func() ControlAnswer {
		if err := h.c.Send(ControlRequest{Op: OpConfirm, Device: phone.ID().String(), Confirm: true}); err != nil {
			t.Fatal(err)
		}
		for {
			a, err := h.c.Next()
			if err != nil {
				t.Fatal(err)
			}
			if a.Event == "" || a.Error != "" {
				return a
			}
		}
	})
	eventually(t, 5*time.Second, "the held close", func() bool { return h.ck.count("set_public_link:close") == 2 })
	answered("unlink", func() ControlAnswer {
		a, err := c2.Do(ControlRequest{Op: OpUnlink, Device: sharedPhoneID})
		if err != nil {
			t.Fatal(err)
		}
		return a
	})
	eventually(t, 5*time.Second, "the held removal", func() bool {
		return h.ck.count("remove_participants:"+h.zones()[0]+":_colleague-a") == 1
	})
	start := time.Now()
	if err := h.stop(); err != nil {
		t.Fatalf("stop: %v", err)
	}
	if d := time.Since(start); d > 3*time.Second {
		t.Fatalf("the stop waited %v on the hung share calls", d)
	}
}

const sharedPhoneID = "6F9619FF-8B86-D011-B42D-00C04FC964FF"

// The owner's Remove of a shared phone on CloudKit takes its iCloud user
// off both shares at once (RemoveCloudKit).
func TestCloudKitRemoveTakesThePhonesParticipant(t *testing.T) {
	h := startCloudKitHub(t, func(dir string, _ *ckShares) { linkSharedPhone(t, dir, sharedPhoneID, "_colleague-a") }, nil)
	h.ck.join("_colleague-a", h.zones()...)
	if a, err := h.c.Do(ControlRequest{Op: OpUnlink, Device: sharedPhoneID}); err != nil || !a.OK {
		t.Fatalf("unlink: %+v, %v", a, err)
	}
	for _, zone := range h.zones() {
		eventually(t, 5*time.Second, "the removal from "+zone, func() bool {
			return h.ck.count("remove_participants:"+zone+":_colleague-a") > 0 && len(h.ck.members(zone)) == 0
		})
	}
}

// The sweep fallback: the removal fails, the Remove still answers OK, the
// mark stays pending, and a later pass's sweep removes the participant and
// clears the mark.
func TestCloudKitAFailedRemovalIsLeftToTheSweep(t *testing.T) {
	h := startCloudKitHub(t, func(dir string, _ *ckShares) { linkSharedPhone(t, dir, sharedPhoneID, "_colleague-a") }, nil)
	h.ck.join("_colleague-a", h.zones()...)
	removal := "remove_participants:" + h.zones()[0] + ":_colleague-a"
	h.ck.failNext(removal, 1)
	if a, err := h.c.Do(ControlRequest{Op: OpUnlink, Device: sharedPhoneID}); err != nil || !a.OK {
		t.Fatalf("unlink: %+v, %v", a, err)
	}
	if a, err := h.c.Do(ControlRequest{Op: OpUnlink, Device: sharedPhoneID}); err != nil || a.Error != ErrClassNoDevice {
		t.Fatalf("a second unlink: %+v, %v", a, err)
	}
	eventually(t, 10*time.Second, "the sweep's removal", func() bool {
		return h.ck.count(removal) >= 2 && h.sweepMark() == "0"
	})
	for _, z := range h.zones() {
		if got := h.ck.members(z); len(got) != 0 {
			t.Errorf("%s still has %v", z, got)
		}
	}
}

// linkSharedPhone writes a shared-scope linked phone of user into the hub
// dir before the hub runs.
func linkSharedPhone(t *testing.T, dir, id, user string) {
	t.Helper()
	st, err := state.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = st.Close() }()
	sig, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	kx, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	d := state.Device{ID: id, Name: "acme phone", Scope: wire.ScopeShared, LinkedAt: time.Now().UTC(),
		SigningKey: sig, AgreementKey: kx.PublicKey().Bytes(), LinkNonce: "nonce-acme"}
	if err := st.WithTx(context.Background(), func(tx *sql.Tx) error {
		if err := state.LinkDevice(tx, d); err != nil {
			return err
		}
		_, err := tx.Exec(`UPDATE devices SET user_record_name = ? WHERE device_id = ?`, user, id)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if devices, err := st.Devices(); err != nil || !slices.ContainsFunc(devices, func(d state.Device) bool { return d.ID == id }) {
		t.Fatalf("devices: %v, %v", devices, err)
	}
}
