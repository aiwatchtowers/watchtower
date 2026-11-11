package alerts

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"testing/synctest"
	"time"

	"google.golang.org/protobuf/proto"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/relay"
	"watchtower/internal/hub/transport/relay/client"
	"watchtower/internal/hub/transport/relay/relayv1"
	"watchtower/internal/logcanary"
)

// testKeys is a KeySource with one hub signing key and one alert key per
// epoch (current is 1 unless set; an epoch in gone has no keys left).
type testKeys struct {
	sig     ed25519.PrivateKey
	kx      *ecdh.PrivateKey
	alert   []byte
	mu      sync.Mutex
	seq     uint64
	current uint32
	gone    map[uint32]bool
}

func newTestKeys(t *testing.T) *testKeys {
	t.Helper()
	_, sig, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	kx, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	k := &testKeys{sig: sig, kx: kx, alert: make([]byte, 32)}
	_, _ = rand.Read(k.alert)
	return k
}

func (k *testKeys) HubID() secure.ID { return secure.ID{0xa, 0xb} }
func (k *testKeys) CurrentEpoch() (uint32, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	return max(k.current, 1), nil
}
func (k *testKeys) NextSeq() (uint64, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.seq++
	return k.seq, nil
}
func (k *testKeys) DataKey(uint32) ([]byte, error) { return bytes.Clone(k.alert), nil }
func (k *testKeys) AlertKey(e uint32) ([]byte, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	if k.gone[e] {
		return nil, errors.New("epoch erased")
	}
	b := bytes.Clone(k.alert)
	b[0] ^= byte(e)
	return b, nil
}
func (k *testKeys) MetaKey() ([]byte, error)           { return bytes.Clone(k.alert), nil }
func (k *testKeys) RelayDevices() ([]secure.ID, error) { return nil, nil }
func (k *testKeys) Signer() ed25519.PrivateKey         { return k.sig }
func (k *testKeys) Agreement() *ecdh.PrivateKey        { return k.kx }
func (k *testKeys) AcceptsRelayEpoch(uint32, secure.ID) (bool, error) {
	return false, nil
}
func (k *testKeys) RelayKey(secure.Direction, secure.ID, uint32) ([]byte, error) {
	return nil, errors.New("no relay keys")
}
func (k *testKeys) KeyboxRecipient(secure.ID) (*ecdh.PublicKey, error) {
	return nil, errors.New("no keybox")
}

// fakeClock is a settable clock whose timers fire on Advance; every timer it
// starts is announced on waits.
type fakeClock struct {
	mu     sync.Mutex
	now    time.Time
	timers []fakeTimer
	waits  chan time.Duration
}

type fakeTimer struct {
	at time.Time
	ch chan time.Time
}

func newFakeClock() *fakeClock {
	return &fakeClock{now: time.Unix(1_800_000_000, 0).UTC(), waits: make(chan time.Duration, 256)}
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *fakeClock) Timer(d time.Duration) (<-chan time.Time, func()) {
	c.mu.Lock()
	ch := make(chan time.Time, 1)
	c.timers = append(c.timers, fakeTimer{at: c.now.Add(d), ch: ch})
	c.mu.Unlock()
	c.waits <- d
	return ch, func() {}
}

func (c *fakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
	kept := c.timers[:0]
	for _, t := range c.timers {
		if !t.at.After(c.now) {
			t.ch <- c.now
			continue
		}
		kept = append(kept, t)
	}
	c.timers = kept
}

// call is one send_alert the fake saw.
type call struct {
	relay string
	key   string
	at    time.Time
	env   []byte
}

// fakeSend is a transport.Alerts with scripted answers per relay id; a nil
// answer is Ok. Every call is announced on calls.
type fakeSend struct {
	clock  *fakeClock
	mu     sync.Mutex
	script map[string][]error // relay id → answers in order (the last repeats)
	block  map[string]bool    // relay id → wait for ctx instead of answering
	// hold: relay id → the call waits for this channel (not for ctx), then
	// gives its scripted answer; the call's ctx is handed out on ctxs.
	hold   map[string]chan struct{}
	ctxs   chan context.Context
	seen   []call
	calls  chan call
	before func(c call) // runs inside the call, before the answer
}

func newFakeSend(clock *fakeClock) *fakeSend {
	return &fakeSend{clock: clock, script: map[string][]error{}, block: map[string]bool{},
		hold: map[string]chan struct{}{}, ctxs: make(chan context.Context, 16), calls: make(chan call, 256)}
}

func (f *fakeSend) answer(relayID string, errs ...error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.script[relayID] = errs
}

func (f *fakeSend) SendAlert(ctx context.Context, relayID string, p secure.Push) error {
	c := call{relay: relayID, key: p.Key(), at: f.clock.Now(), env: p.Envelope()}
	f.mu.Lock()
	f.seen = append(f.seen, c)
	block, hold := f.block[relayID], f.hold[relayID]
	var err error
	if s := f.script[relayID]; len(s) > 0 {
		err = s[0]
		if len(s) > 1 {
			f.script[relayID] = s[1:]
		}
	}
	before := f.before
	f.mu.Unlock()
	if before != nil {
		before(c)
	}
	f.calls <- c
	if block {
		<-ctx.Done()
		return ctx.Err()
	}
	if hold != nil {
		f.ctxs <- ctx
		<-hold
	}
	return err
}

func (f *fakeSend) count(relayID string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, c := range f.seen {
		if c.relay == relayID {
			n++
		}
	}
	return n
}

// settled is one settle the pusher made.
type settled struct{ key, device, outcome, reason string }

// fakeAway is a switchable owner-away input.
type fakeAway struct {
	mu   sync.Mutex
	away bool
	err  error
}

func (a *fakeAway) Away() (bool, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.away, a.err
}

func (a *fakeAway) set(away bool) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.away = away
}

// rig is a pusher over a real sidecar, a fake relay, a fake clock and a
// switchable target list.
type rig struct {
	t       *testing.T
	dir     string
	st      *state.Store
	sealer  *secure.Sealer
	keys    *testKeys
	clock   *fakeClock
	send    *fakeSend
	away    *fakeAway
	mu      sync.Mutex
	targets []Target
	epochOf map[string]uint32 // EpochFor per device (absent = 0)
	refresh int
	// refreshGate, when set, holds every RefreshAccount until it closes (or
	// its ctx ends).
	refreshGate chan struct{}
	p           *Pusher
	settles     chan settled
	settleMu    sync.Mutex
	all         []settled
}

func newRig(t *testing.T, phones ...string) *rig {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "hub")
	st, err := state.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	clock := newFakeClock()
	keys := newTestKeys(t)
	r := &rig{
		t: t, dir: dir, st: st, sealer: secure.NewSealer(keys), keys: keys, clock: clock,
		send: newFakeSend(clock), away: &fakeAway{away: true}, settles: make(chan settled, 512),
	}
	for _, ph := range phones {
		r.targets = append(r.targets, Target{DeviceID: ph, RelayID: "relay-" + ph})
	}
	r.p = r.newPusher()
	return r
}

func (r *rig) newPusher() *Pusher {
	p := New(Config{
		Store: r.st, Sealer: r.sealer, Send: r.send,
		Targets: func(context.Context) ([]Target, error) {
			r.mu.Lock()
			defer r.mu.Unlock()
			return slices.Clone(r.targets), nil
		},
		RefreshAccount: func(ctx context.Context) {
			r.mu.Lock()
			r.refresh++
			gate := r.refreshGate
			r.mu.Unlock()
			if gate != nil {
				select {
				case <-gate:
				case <-ctx.Done():
				}
			}
		},
		EpochFor: func(device string) uint32 {
			r.mu.Lock()
			defer r.mu.Unlock()
			return r.epochOf[device]
		},
		Away:  r.away,
		Clock: r.clock.Now,
		Timer: r.clock.Timer,
	})
	p.onSettle = func(key, device, outcome, reason string) {
		s := settled{key, device, outcome, reason}
		r.settleMu.Lock()
		r.all = append(r.all, s)
		r.settleMu.Unlock()
		r.settles <- s
	}
	return p
}

func (r *rig) start() {
	r.t.Helper()
	r.startPusher(r.p)
}

func (r *rig) startPusher(p *Pusher) {
	r.t.Helper()
	if err := p.Start(context.Background()); err != nil {
		r.t.Fatal(err)
	}
	r.t.Cleanup(p.Stop)
}

func (r *rig) enqueue(key string) {
	r.enqueueText(key, "Build finished", "All checks passed")
}

func (r *rig) enqueueText(key, title, body string) {
	r.p.Enqueue(key, secure.WorkAlertFields{
		Event: "session_stop", Key: key, WorkbenchID: 7, WorkbenchName: "acme",
		Title: title, Body: body,
	}, r.clock.Now())
}

// next waits for the next settle (a hang is bounded by go test -timeout).
func (r *rig) next() settled {
	return <-r.settles
}

// nextN waits for n settles, sorted by device then key.
func (r *rig) nextN(n int) []settled {
	r.t.Helper()
	out := make([]settled, 0, n)
	for range n {
		out = append(out, r.next())
	}
	slices.SortFunc(out, func(a, b settled) int {
		return strings.Compare(a.device+"\x00"+a.key, b.device+"\x00"+b.key)
	})
	return out
}

func (r *rig) call() call {
	return <-r.send.calls
}

func (r *rig) wait() time.Duration {
	return <-r.clock.waits
}

func (r *rig) refreshes() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.refresh
}

// relayErr is a relay-coded answer as the transport hands it on: the
// client's error for code, mapped by MapError (the classes every op shares;
// send_alert's own NOT_FOUND and "not implemented" mappings are written as
// their transport errors in the tests instead).
func relayErr(code relayv1.ErrorCode, message string, retryAfter *uint32) error {
	return fmt.Errorf("relay: send_alert: %w", relay.MapError(&client.Error{E: &relayv1.Error{
		Code: code, Message: message, RetryAfterS: retryAfter,
	}}))
}

func TestPushedOncePerKeyAndPhone(t *testing.T) {
	r := newRig(t, "phone-a", "phone-b")
	r.start()
	r.enqueue("ask-1")
	r.enqueue("ask-1")
	got := r.nextN(2)
	want := []settled{{"ask-1", "phone-a", "accepted", ""}, {"ask-1", "phone-b", "accepted", ""}}
	if !slices.Equal(got, want) {
		t.Fatalf("settled %v; want %v", got, want)
	}
	r.p.Stop()
	if a, b := r.send.count("relay-phone-a"), r.send.count("relay-phone-b"); a != 1 || b != 1 {
		t.Fatalf("send_alert per phone = %d, %d; want 1, 1", a, b)
	}
}

func TestOnlyPayingReadersAreTargets(t *testing.T) {
	devices := []state.Device{
		{ID: "phone-c", RelayDeviceID: "relay-c"}, // paying
		{ID: "phone-a", RelayDeviceID: "relay-a"}, // paying
		{ID: "phone-b", RelayDeviceID: "relay-b"}, // in a slot, not paying
		{ID: "phone-d", RelayDeviceID: "relay-d"}, // in no slot (not a reader)
		{ID: "phone-e"}, // CloudKit only: no relay id
		{ID: "phone-f", RelayDeviceID: "relay-stranger"}, // listed? no: another id is
	}
	acct := &relayv1.AccountState{Phones: []*relayv1.SlotHolder{
		{PhoneDeviceId: "relay-a", Paying: true},
		{PhoneDeviceId: "relay-b", Paying: false},
		{PhoneDeviceId: "relay-c", Paying: true},
		{PhoneDeviceId: "relay-unlinked", Paying: true}, // pays, never linked to this hub
	}}
	got := Eligible(devices, acct)
	want := []Target{{DeviceID: "phone-a", RelayID: "relay-a"}, {DeviceID: "phone-c", RelayID: "relay-c"}}
	if !slices.Equal(got, want) {
		t.Fatalf("Eligible = %v; want %v", got, want)
	}
	if got := Eligible(devices, nil); len(got) != 0 {
		t.Fatalf("Eligible with no account state = %v; want none", got)
	}
}

// Review Focus 2: a crash between send_alert and the settle write.
func TestPendingPushAtStartIsSettledExpiredNeverResent(t *testing.T) {
	r := newRig(t, "phone-a")
	// The first run's request reaches the relay and never comes back: the
	// process "dies" with the row pending.
	r.send.block["relay-phone-a"] = true
	r.start()
	r.enqueue("ask-1")
	r.call()

	// The next run on the same sidecar.
	r.send.mu.Lock()
	r.send.block["relay-phone-a"] = false
	r.send.mu.Unlock()
	p2 := r.newPusher()
	r.startPusher(p2)
	r.p = p2
	r.enqueue("ask-1") // a republish after the restart, if one ever came
	r.mu.Lock()
	r.targets = append(r.targets, Target{DeviceID: "phone-b", RelayID: "relay-phone-b"})
	r.mu.Unlock()
	r.enqueue("ask-1") // a phone that never had it still gets it
	if s := r.next(); s != (settled{"ask-1", "phone-b", "accepted", ""}) {
		t.Fatalf("settled %v; want phone-b accepted", s)
	}
	p2.Stop()
	if n := r.send.count("relay-phone-a"); n != 1 {
		t.Fatalf("send_alert to phone-a %d times; want 1 (never resent)", n)
	}
	last, err := r.st.LastAlertOutcomes(time.Time{})
	if err != nil || last["phone-a"] != state.AlertExpired {
		t.Fatalf("phone-a's row = %v, %v; want expired", last, err)
	}
}

func TestEnqueueWritesPendingBeforeTheQueue(t *testing.T) {
	r := newRig(t, "phone-a")
	r.send.before = func(c call) {
		// The row exists when the request is made: Begin refuses a second one.
		if ok, err := r.st.BeginAlertPush(c.key, "phone-a", r.clock.Now()); err != nil || ok {
			t.Errorf("no pending row at send time (Begin = %v, %v)", ok, err)
		}
	}
	r.send.block["relay-phone-a"] = true
	r.start()
	r.enqueue("ask-1")
	r.call()           // ask-1 in flight
	r.enqueue("ask-2") // queued behind it, never sent
	// The process dies here; the next run's start finds both rows pending.
	n, err := r.st.ExpirePendingAlertPushes(r.clock.Now())
	if err != nil || n != 2 {
		t.Fatalf("ExpirePendingAlertPushes = %d, %v; want 2 (in flight and queued)", n, err)
	}
	r.p.Stop()
	if n := r.send.count("relay-phone-a"); n != 1 {
		t.Fatalf("send_alert %d times; want 1", n)
	}
}

func TestRateLimitedRetriesAfterRetryAfterWithinFreshness(t *testing.T) {
	r := newRig(t, "phone-a")
	r.send.answer("relay-phone-a", relayErr(relayv1.ErrorCode_ERROR_CODE_RATE_LIMITED, "slow down", proto.Uint32(7)))
	r.start()
	t0 := r.clock.Now()
	r.enqueue("stop-3-1000")
	first := r.call()
	if d := r.wait(); d != 7*time.Second {
		t.Fatalf("first retry wait %v; want the relay's 7 s", d)
	}
	r.clock.Advance(7 * time.Second)
	if c := r.call(); c.at.Sub(first.at) != 7*time.Second || !bytes.Equal(c.env, first.env) {
		t.Fatalf("retry at +%v (same envelope %v); want +7s, the same push", c.at.Sub(first.at), bytes.Equal(c.env, first.env))
	}
	// Still refused: retries go on every 7 s, and the last wait is cut at the
	// window's end, where the push expires unsent.
	for {
		select {
		case d := <-r.clock.waits:
			r.clock.Advance(d)
		case <-r.send.calls:
		case s := <-r.settles:
			if s != (settled{"stop-3-1000", "phone-a", "expired", "freshness"}) {
				t.Fatalf("settled %v; want expired (freshness)", s)
			}
			if now := r.clock.Now(); now.Sub(t0) != Freshness {
				t.Fatalf("expired at +%v; want +%v", now.Sub(t0), Freshness)
			}
			// 300 s / 7 s: sends at 0, 7, …, 294.
			if n := r.send.count("relay-phone-a"); n != 43 {
				t.Fatalf("send_alert %d times; want 43", n)
			}
			return
		}
	}
}

func TestRateLimitedWithoutRetryAfterWaitsOneSecondAndCapsAtAMinute(t *testing.T) {
	r := newRig(t, "phone-a")
	r.send.answer("relay-phone-a",
		relayErr(relayv1.ErrorCode_ERROR_CODE_RATE_LIMITED, "", nil),
		relayErr(relayv1.ErrorCode_ERROR_CODE_TRAFFIC_LIMIT_EXCEEDED, "", proto.Uint32(600)),
		nil)
	r.start()
	r.enqueue("ask-1")
	r.call()
	if d := r.wait(); d != time.Second {
		t.Fatalf("wait %v; want 1 s", d)
	}
	r.clock.Advance(time.Second)
	r.call()
	if d := r.wait(); d != time.Minute {
		t.Fatalf("wait %v; want the 60 s cap", d)
	}
	r.clock.Advance(time.Minute)
	if s := r.next(); s.outcome != state.AlertAccepted {
		t.Fatalf("settled %v", s)
	}
}

func TestUnavailableRetriesOnTheNextConnect(t *testing.T) {
	r := newRig(t, "phone-a")
	r.send.answer("relay-phone-a", relayErr(relayv1.ErrorCode_ERROR_CODE_UNAVAILABLE, "", nil), nil)
	r.start()
	r.enqueue("ask-1")
	r.call()
	if d := r.wait(); d != unavailableRetry {
		t.Fatalf("wait %v; want %v", d, unavailableRetry)
	}
	r.p.Reconnected() // no clock advance: the connection ends the wait
	r.call()
	if s := r.next(); s.outcome != state.AlertAccepted {
		t.Fatalf("settled %v", s)
	}
}

func TestRelayUnavailableRetriedAfterItsWait(t *testing.T) {
	r := newRig(t, "phone-a")
	r.send.answer("relay-phone-a", relayErr(relayv1.ErrorCode_ERROR_CODE_UNAVAILABLE, "", nil), nil)
	r.start()
	r.p.Reconnected() // a connection before the failure is stale: it ends no wait
	r.enqueue("ask-1")
	r.call()
	r.clock.Advance(r.wait())
	r.call()
	if s := r.next(); s.outcome != state.AlertAccepted {
		t.Fatalf("settled %v", s)
	}
	if n := r.send.count("relay-phone-a"); n != 2 {
		t.Fatalf("send_alert %d times; want 2", n)
	}
}

// A failure with no relay answer (MapError's ErrUnavailable around a
// connection error): the request may have reached the relay, so the push is
// never resent and counts as received.
func TestTransportFailureSettlesInFlightNoRetry(t *testing.T) {
	r := newRig(t, "phone-a")
	r.send.answer("relay-phone-a", fmt.Errorf("relay: send_alert: %w", relay.MapError(errors.New("connection reset"))))
	r.start()
	r.enqueue("ask-1")
	if s := r.next(); s != (settled{"ask-1", "phone-a", "expired", "in_flight"}) {
		t.Fatalf("settled %v; want expired (in_flight)", s)
	}
	r.p.Stop()
	if n := r.send.count("relay-phone-a"); n != 1 {
		t.Fatalf("send_alert %d times; want 1 (no retry)", n)
	}
	if len(r.clock.waits) != 0 {
		t.Fatal("a retry was scheduled")
	}
	got, err := r.st.ReceivedAlertPushes([]string{"ask-1"})
	if err != nil || !got["ask-1"]["phone-a"] {
		t.Fatalf("ReceivedAlertPushes = %v, %v; want phone-a", got, err)
	}
}

// Review Focus 3: a phone that stopped paying since the last account read.
func TestEntitlementInactiveStopsRetriesAndRefreshesOnce(t *testing.T) {
	r := newRig(t, "phone-a", "phone-b")
	r.send.answer("relay-phone-a", relayErr(relayv1.ErrorCode_ERROR_CODE_ENTITLEMENT_INACTIVE, "", nil))
	r.start()
	r.enqueue("ask-1")
	got := r.nextN(2)
	want := []settled{{"ask-1", "phone-a", "not_paying", ""}, {"ask-1", "phone-b", "accepted", ""}}
	if !slices.Equal(got, want) {
		t.Fatalf("settled %v; want %v", got, want)
	}
	r.p.Stop()
	if n := r.send.count("relay-phone-a"); n != 1 {
		t.Fatalf("send_alert to the lapsed phone %d times; want 1 (no retry)", n)
	}
	if n := r.refreshes(); n != 1 {
		t.Fatalf("account refreshed %d times; want 1", n)
	}
	if len(r.clock.waits) != 0 {
		t.Fatal("a retry was scheduled")
	}
}

func TestOnePhoneRefusedOthersStillSent(t *testing.T) {
	for _, tc := range []struct {
		name string
		err  error
	}{
		{"forbidden", relayErr(relayv1.ErrorCode_ERROR_CODE_FORBIDDEN, "", nil)},
		{"hub not vouched", relayErr(relayv1.ErrorCode_ERROR_CODE_HUB_NOT_VOUCHED, "", nil)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := newRig(t, "phone-a", "phone-b", "phone-c")
			r.send.answer("relay-phone-b", tc.err)
			r.start()
			r.enqueue("perm-9")
			got := r.nextN(3)
			want := []settled{
				{"perm-9", "phone-a", "accepted", ""},
				{"perm-9", "phone-b", "forbidden", ""},
				{"perm-9", "phone-c", "accepted", ""},
			}
			if !slices.Equal(got, want) {
				t.Fatalf("settled %v; want %v", got, want)
			}
			r.p.Stop()
			if n := r.send.count("relay-phone-b"); n != 1 {
				t.Fatalf("refused phone sent %d times; want 1", n)
			}
			if n := r.refreshes(); n != 1 {
				t.Fatalf("account refreshed %d times; want 1", n)
			}
		})
	}
}

func TestOutcomeClasses(t *testing.T) {
	cases := []struct {
		err  error
		want string
	}{
		{nil, "accepted"},
		{fmt.Errorf("relay: send_alert: %w", transport.ErrNoPushToken), "no_token"},
		{relayErr(relayv1.ErrorCode_ERROR_CODE_ENTITLEMENT_INACTIVE, "", nil), "not_paying"},
		{relayErr(relayv1.ErrorCode_ERROR_CODE_FORBIDDEN, "", nil), "forbidden"},
		{relayErr(relayv1.ErrorCode_ERROR_CODE_HUB_NOT_VOUCHED, "", nil), "forbidden"},
		{relayErr(relayv1.ErrorCode_ERROR_CODE_ATTESTATION_REQUIRED, "", nil), "forbidden"},
		{relayErr(relayv1.ErrorCode_ERROR_CODE_RECORD_TOO_LARGE, "", nil), "too_large"},
		{fmt.Errorf("relay: send_alert: %w", transport.ErrPushOff), "push_off"},
		{relayErr(relayv1.ErrorCode_ERROR_CODE_UNSPECIFIED, "boom", nil), "failed"},
		{errors.New("something else"), "failed"},
	}
	var phones []string
	for i := range cases {
		phones = append(phones, fmt.Sprintf("phone-%02d", i))
	}
	r := newRig(t, phones...)
	for i, c := range cases {
		r.send.answer("relay-"+phones[i], c.err)
	}
	r.start()
	r.enqueue("ask-1")
	got := r.nextN(len(cases))
	for i, c := range cases {
		if got[i].device != phones[i] || got[i].outcome != c.want || got[i].reason != "" {
			t.Errorf("answer %v → %+v; want %s", c.err, got[i], c.want)
		}
	}
	last, err := r.st.LastAlertOutcomes(time.Time{})
	if err != nil || last[phones[0]] != "accepted" {
		t.Fatalf("ledger %v, %v", last, err)
	}
}

func TestQueueOverflowSettlesExpired(t *testing.T) {
	r := newRig(t, "phone-a")
	r.send.block["relay-phone-a"] = true
	r.start()
	r.enqueue("ask-0")
	r.call() // in flight: the queue behind it fills
	for i := 1; i <= QueuePerPhone+2; i++ {
		r.enqueue(fmt.Sprintf("ask-%d", i))
	}
	for _, want := range []string{fmt.Sprintf("ask-%d", QueuePerPhone+1), fmt.Sprintf("ask-%d", QueuePerPhone+2)} {
		if s := r.next(); s != (settled{want, "phone-a", "expired", "overflow"}) {
			t.Fatalf("settled %v; want %s expired (overflow)", s, want)
		}
	}
	if n, err := r.st.AlertPushOverflows(time.Time{}); err != nil || n != 2 {
		t.Fatalf("AlertPushOverflows = %d, %v; want 2", n, err)
	}
}

func TestOwnerBackBeforeSendSettlesExpired(t *testing.T) {
	r := newRig(t, "phone-a")
	r.away.set(false)
	r.start()
	r.enqueue("ask-1")
	if s := r.next(); s != (settled{"ask-1", "phone-a", "expired", "owner_back"}) {
		t.Fatalf("settled %v", s)
	}
	if n := r.send.count("relay-phone-a"); n != 0 {
		t.Fatalf("send_alert %d times while the owner is back", n)
	}
}

func TestOwnerBackBeforeRetrySettlesExpired(t *testing.T) {
	r := newRig(t, "phone-a")
	r.send.answer("relay-phone-a", relayErr(relayv1.ErrorCode_ERROR_CODE_RATE_LIMITED, "", proto.Uint32(3)))
	r.start()
	r.enqueue("ask-1")
	r.call()
	r.wait()
	r.away.set(false)
	r.clock.Advance(3 * time.Second)
	if s := r.next(); s != (settled{"ask-1", "phone-a", "expired", "owner_back"}) {
		t.Fatalf("settled %v", s)
	}
	if n := r.send.count("relay-phone-a"); n != 1 {
		t.Fatalf("send_alert %d times; want 1 (no retry once the owner is back)", n)
	}
}

func TestAwayErrorReadsAsAway(t *testing.T) {
	r := newRig(t, "phone-a")
	r.away.mu.Lock()
	r.away.away, r.away.err = false, errors.New("console unreadable")
	r.away.mu.Unlock()
	r.start()
	r.enqueue("ask-1")
	if s := r.next(); s.outcome != state.AlertAccepted {
		t.Fatalf("settled %v; want accepted", s)
	}
}

func TestStopSettlesQueuedExpired(t *testing.T) {
	r := newRig(t, "phone-a")
	r.send.block["relay-phone-a"] = true
	r.start()
	r.enqueue("ask-1")
	r.call()
	r.enqueue("ask-2")
	r.enqueue("ask-3")
	r.p.Stop()
	got := r.nextN(3)
	slices.SortFunc(got, func(a, b settled) int { return strings.Compare(a.key, b.key) })
	want := []settled{
		{"ask-1", "phone-a", "expired", "in_flight"}, // its request was in progress
		{"ask-2", "phone-a", "expired", "stopped"},
		{"ask-3", "phone-a", "expired", "stopped"},
	}
	if !slices.Equal(got, want) {
		t.Fatalf("settled %v; want %v", got, want)
	}
	// After Stop nothing is queued.
	r.enqueue("ask-4")
	if n := r.send.count("relay-phone-a"); n != 1 {
		t.Fatalf("send_alert %d times; want 1", n)
	}
	last, err := r.st.LastAlertOutcomes(time.Time{})
	if err != nil || last["phone-a"] != "expired" {
		t.Fatalf("ledger %v, %v", last, err)
	}
}

func TestAbandonSettlesQueuedAndReturnsKeys(t *testing.T) {
	r := newRig(t, "phone-a", "phone-b")
	r.send.block["relay-phone-a"] = true
	r.start()
	r.enqueue("ask-1")
	r.nextN(1) // phone-b accepted ask-1
	r.call()
	r.call()
	r.enqueue("ask-2")
	r.nextN(1) // phone-b accepted ask-2; phone-a's waits behind ask-1
	r.call()
	keys := r.p.Abandon(state.ReasonSwitched)
	if !slices.Equal(keys, []string{"ask-1", "ask-2"}) {
		t.Fatalf("Abandon = %v", keys)
	}
	got := r.nextN(2)
	slices.SortFunc(got, func(a, b settled) int { return strings.Compare(a.key, b.key) })
	want := []settled{
		{"ask-1", "phone-a", "expired", "in_flight"}, // interrupted mid-request
		{"ask-2", "phone-a", "expired", "switched"},  // queued, never sent
	}
	if !slices.Equal(got, want) {
		t.Fatalf("settled %v; want %v", got, want)
	}
	// ask-1 may have reached phone-a: Resignal must skip it there too.
	rec, err := r.st.ReceivedAlertPushes(keys)
	if err != nil || !rec["ask-1"]["phone-a"] || !rec["ask-1"]["phone-b"] || rec["ask-2"]["phone-a"] || !rec["ask-2"]["phone-b"] {
		t.Fatalf("received %v, %v", rec, err)
	}
	// The pusher keeps running after a switch.
	r.send.mu.Lock()
	r.send.block["relay-phone-a"] = false
	r.send.mu.Unlock()
	r.enqueue("ask-3")
	if got := r.nextN(2); got[0].outcome != "accepted" || got[1].outcome != "accepted" {
		t.Fatalf("after Abandon %v", got)
	}
	r.p.Stop()
	var toA []string
	r.send.mu.Lock()
	for _, c := range r.send.seen {
		if c.relay == "relay-phone-a" {
			toA = append(toA, c.key)
		}
	}
	r.send.mu.Unlock()
	if !slices.Equal(toA, []string{"ask-1", "ask-3"}) {
		t.Fatalf("phone-a got %v; want [ask-1 ask-3] (ask-2 abandoned unsent)", toA)
	}
}

func TestAbandonLetsAnAnswerThatWinsStand(t *testing.T) {
	r := newRig(t, "phone-a")
	gate := make(chan struct{})
	r.send.hold["relay-phone-a"] = gate
	r.start()
	r.enqueue("ask-1")
	r.call()
	callCtx := <-r.send.ctxs
	keys := make(chan []string, 1)
	go func() { keys <- r.p.Abandon(state.ReasonSwitched) }()
	<-callCtx.Done() // Abandon has cancelled the request…
	close(gate)      // …and the relay's Ok arrives anyway
	if got := <-keys; len(got) != 0 {
		t.Fatalf("Abandon = %v; want none (the push was accepted)", got)
	}
	if s := r.next(); s != (settled{"ask-1", "phone-a", "accepted", ""}) {
		t.Fatalf("settled %v; want accepted", s)
	}
}

func TestAbandonDuringARetryWait(t *testing.T) {
	r := newRig(t, "phone-a")
	r.send.answer("relay-phone-a", relayErr(relayv1.ErrorCode_ERROR_CODE_RATE_LIMITED, "", proto.Uint32(30)))
	r.start()
	r.enqueue("ask-1")
	r.call()
	r.wait()
	if keys := r.p.Abandon(state.ReasonSwitched); !slices.Equal(keys, []string{"ask-1"}) {
		t.Fatalf("Abandon = %v", keys)
	}
	if s := r.next(); s != (settled{"ask-1", "phone-a", "expired", "switched"}) {
		t.Fatalf("settled %v; want expired (switched)", s)
	}
	r.clock.Advance(time.Minute)
	r.p.Stop()
	if n := r.send.count("relay-phone-a"); n != 1 {
		t.Fatalf("send_alert %d times; want 1", n)
	}
	if rec, _ := r.st.ReceivedAlertPushes([]string{"ask-1"}); len(rec) != 0 {
		t.Fatalf("received %v; a refused push is not received", rec)
	}
}

// An Enqueue whose rows are written before an Abandon and whose items would
// enter the queue after it queues nothing.
func TestEnqueueOverlappingAbandonQueuesNothing(t *testing.T) {
	r := newRig(t, "phone-a")
	r.start()
	r.p.beforeQueue = func() {
		if keys := r.p.Abandon(state.ReasonSwitched); len(keys) != 0 {
			t.Errorf("Abandon = %v; nothing was queued yet", keys)
		}
	}
	r.enqueue("ask-1")
	if s := r.next(); s != (settled{"ask-1", "phone-a", "expired", "switched"}) {
		t.Fatalf("settled %v; want expired (switched)", s)
	}
	r.p.beforeQueue = nil
	r.p.Stop()
	if n := r.send.count("relay-phone-a"); n != 0 {
		t.Fatalf("send_alert %d times; want 0", n)
	}
}

func TestStartRefusedTwiceAndAfterStop(t *testing.T) {
	r := newRig(t, "phone-a")
	r.start()
	if err := r.p.Start(context.Background()); err == nil {
		t.Fatal("second Start accepted")
	}
	p2 := r.newPusher()
	p2.Stop()
	if err := p2.Start(context.Background()); err == nil {
		t.Fatal("Start after Stop accepted")
	}
}

func TestRefreshCoalescedAcrossPhones(t *testing.T) {
	r := newRig(t, "phone-a", "phone-b", "phone-c")
	r.refreshGate = make(chan struct{})
	r.send.answer("relay-phone-a", relayErr(relayv1.ErrorCode_ERROR_CODE_FORBIDDEN, "", nil))
	r.send.answer("relay-phone-b", relayErr(relayv1.ErrorCode_ERROR_CODE_ENTITLEMENT_INACTIVE, "", nil))
	r.send.block["relay-phone-c"] = true
	r.start()
	r.enqueue("ask-1")
	for range 3 {
		r.call()
	}
	r.nextN(2) // a forbidden, b not_paying: one refresh runs, held
	// Abandon never waits on the refresh.
	if keys := r.p.Abandon(state.ReasonSwitched); !slices.Equal(keys, []string{"ask-1"}) {
		t.Fatalf("Abandon = %v", keys)
	}
	if s := r.next(); s != (settled{"ask-1", "phone-c", "expired", "in_flight"}) {
		t.Fatalf("settled %v", s)
	}
	close(r.refreshGate)
	r.p.Stop()
	if n := r.refreshes(); n != 1 {
		t.Fatalf("account refreshed %d times; want 1 for the burst", n)
	}
}

func TestTooLargeAnswerIsLoggedOnce(t *testing.T) {
	sink := logcanary.Capture(t)
	r := newRig(t, "phone-a", "phone-b")
	tooBig := relayErr(relayv1.ErrorCode_ERROR_CODE_RECORD_TOO_LARGE, "", nil)
	r.send.answer("relay-phone-a", tooBig)
	r.send.answer("relay-phone-b", tooBig)
	r.start()
	r.enqueue("ask-1")
	r.nextN(2)
	if n := strings.Count(sink.String(), "too large"); n != 1 {
		t.Fatalf("too-large logged %d times; want 1:\n%s", n, sink.String())
	}
}

// canaryFields is an alert whose every text carries a canary marker.
func canaryFields(key string) secure.WorkAlertFields {
	return secure.WorkAlertFields{
		Event: "ask", Key: key, WorkbenchID: 7,
		WorkbenchName: logcanary.Text("workbench_name"),
		Title:         logcanary.Text("title"), Body: logcanary.Text("body"),
	}
}

func TestFILES01_PusherLogsIdsAndClassesOnly(t *testing.T) {
	sink := logcanary.Capture(t)
	r := newRig(t, "phone-a", "phone-b", "phone-c", "phone-d")
	// Answers whose own text carries the canary too: only classes are logged.
	r.send.answer("relay-phone-a", errors.New("relay said "+logcanary.Text("error")))
	r.send.answer("relay-phone-b", relayErr(relayv1.ErrorCode_ERROR_CODE_RECORD_TOO_LARGE, logcanary.Text("message"), nil))
	r.send.answer("relay-phone-c",
		relayErr(relayv1.ErrorCode_ERROR_CODE_RATE_LIMITED, logcanary.Text("rate"), proto.Uint32(1)), nil)
	r.start()
	r.p.Enqueue("ask-1", canaryFields("ask-1"), r.clock.Now())
	r.wait()
	r.clock.Advance(time.Second)
	r.nextN(4)
	r.p.Enqueue("ask-2", canaryFields("ask-2"), r.clock.Now().Add(-2*Freshness)) // expires unsent
	r.nextN(4)
	r.p.Stop()
	if !strings.Contains(sink.String(), "ask-1") {
		t.Fatalf("no push logged:\n%s", sink.String())
	}
	sink.AssertClean(t)
}

func TestAlertPushLedgerHasNoContent(t *testing.T) {
	r := newRig(t, "phone-a", "phone-b")
	r.send.answer("relay-phone-b", fmt.Errorf("relay: send_alert: %w", transport.ErrPushOff))
	r.start()
	r.p.Enqueue("ask-1", canaryFields("ask-1"), r.clock.Now())
	r.nextN(2)
	r.p.Stop()
	if err := r.st.Close(); err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(r.dir)
	if err != nil {
		t.Fatal(err)
	}
	rows := false
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		b, err := os.ReadFile(filepath.Join(r.dir, e.Name()))
		if err != nil {
			t.Fatal(err)
		}
		if bytes.Contains(b, []byte(logcanary.Marker)) {
			t.Errorf("%s holds alert text", e.Name())
		}
		rows = rows || bytes.Contains(b, []byte("ask-1"))
	}
	if !rows {
		t.Fatal("no ledger row on disk: the canary proves nothing")
	}
}

func TestSealFailureSettlesWithoutSending(t *testing.T) {
	r := newRig(t, "phone-a")
	r.start()
	// A key that is not the payload's: the sealer refuses it.
	r.p.Enqueue("ask-1", secure.WorkAlertFields{Key: "ask-2"}, r.clock.Now())
	if s := r.next(); s != (settled{"ask-1", "phone-a", "failed", ""}) {
		t.Fatalf("settled %v", s)
	}
	if n := r.send.count("relay-phone-a"); n != 0 {
		t.Fatalf("send_alert %d times", n)
	}
}

// Start's ctx ending before Stop: the idle senders are gone, so an Enqueue
// then queues nothing and leaves no pending row.
func TestEnqueueAfterStartContextEndsQueuesNothing(t *testing.T) {
	r := newRig(t, "phone-a")
	ctx, cancel := context.WithCancel(context.Background())
	if err := r.p.Start(ctx); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(r.p.Stop)
	r.enqueue("ask-1")
	if s := r.next(); s.outcome != state.AlertAccepted {
		t.Fatalf("settled %v", s)
	}
	// Ended between the pending rows and the queue: the rows settle stopped.
	r.p.beforeQueue = cancel
	r.enqueue("ask-2")
	if s := r.next(); s != (settled{"ask-2", "phone-a", "expired", "stopped"}) {
		t.Fatalf("settled %v; want expired (stopped)", s)
	}
	// Ended before the Enqueue: no row at all.
	r.p.beforeQueue = nil
	r.enqueue("ask-3")
	if ok, err := r.st.BeginAlertPush("ask-3", "phone-a", r.clock.Now()); err != nil || !ok {
		t.Fatalf("ask-3 has a row (Begin = %v, %v)", ok, err)
	}
	if n, err := r.st.ExpirePendingAlertPushes(r.clock.Now()); err != nil || n != 1 {
		t.Fatalf("pending rows %d, %v; want only the test's own", n, err)
	}
	if n := r.send.count("relay-phone-a"); n != 1 {
		t.Fatalf("send_alert %d times; want 1", n)
	}
}

// The window ends while a request is in progress, with no relay answer: it
// may have reached the relay, so it counts as received. The attempt's own
// deadline is a real context timer, so the test runs in a synctest bubble.
func TestFreshnessTimeoutMidRequestSettlesInFlight(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newRig(t, "phone-a")
		r.send.block["relay-phone-a"] = true // answers only when its ctx ends
		r.start()
		// 50 ms of the window left: the attempt's own deadline ends the call.
		r.p.Enqueue("ask-1", secure.WorkAlertFields{Event: "ask", Key: "ask-1", Title: "t", Body: "b"},
			r.clock.Now().Add(-Freshness+50*time.Millisecond))
		t0 := time.Now()
		if s := r.next(); s != (settled{"ask-1", "phone-a", "expired", "in_flight"}) {
			t.Fatalf("settled %v; want expired (in_flight)", s)
		}
		if d := time.Since(t0); d != 50*time.Millisecond {
			t.Fatalf("the request ended after %v of bubble time; want the window's 50 ms", d)
		}
		if n := r.send.count("relay-phone-a"); n != 1 {
			t.Fatalf("send_alert %d times; want 1", n)
		}
		if rec, err := r.st.ReceivedAlertPushes([]string{"ask-1"}); err != nil || !rec["ask-1"]["phone-a"] {
			t.Fatalf("received %v, %v", rec, err)
		}
	})
}

func TestConcurrentStopWaitsForTheFirst(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newRig(t, "phone-a")
		gate := make(chan struct{})
		r.send.hold["relay-phone-a"] = gate // ignores its ctx: the first Stop waits on it
		r.start()
		r.enqueue("ask-1")
		r.call()
		callCtx := <-r.send.ctxs
		first := make(chan struct{})
		go func() { r.p.Stop(); close(first) }()
		<-callCtx.Done() // the first Stop is in, waiting for the sender
		second := make(chan struct{})
		go func() { r.p.Stop(); close(second) }()
		synctest.Wait() // every goroutine is blocked: the sender on gate, both Stops on it
		select {
		case <-second:
			t.Fatal("second Stop returned while the first still waits for the sender")
		default:
		}
		close(gate)
		<-first
		<-second
	})
}

// A phone whose "When work stops" switch is off is no target, paying or not;
// its neighbours stay.
func TestEligibleSkipsAPhoneWithWorkAlertsOff(t *testing.T) {
	devices := []state.Device{
		{ID: "phone-a", RelayDeviceID: "relay-a", WorkAlertsOff: true},
		{ID: "phone-b", RelayDeviceID: "relay-b"},
	}
	acct := &relayv1.AccountState{Phones: []*relayv1.SlotHolder{
		{PhoneDeviceId: "relay-a", Paying: true},
		{PhoneDeviceId: "relay-b", Paying: true},
	}}
	got := Eligible(devices, acct)
	want := []Target{{DeviceID: "phone-b", RelayID: "relay-b"}}
	if !slices.Equal(got, want) {
		t.Fatalf("Eligible = %v; want %v", got, want)
	}
}

// ---- the epoch a push is sealed in (relay client Phase 5, Task 5) ----

// sealedEpochs opens every envelope the fake relay got with the test keys and
// returns each relay id's epoch and envelope.
func (r *rig) sealedEpochs() map[string]struct {
	epoch uint32
	env   []byte
} {
	r.t.Helper()
	r.send.mu.Lock()
	seen := slices.Clone(r.send.seen)
	r.send.mu.Unlock()
	out := map[string]struct {
		epoch uint32
		env   []byte
	}{}
	for _, c := range seen {
		h, _, err := secure.OpenSymmetric(c.env, []secure.EnvelopeClass{secure.ClassAlert},
			secure.Context{Zone: secure.ZoneData, WireName: secure.AlertPushWireName}, r.keys.sig.Public().(ed25519.PublicKey),
			func(h secure.Header) ([]byte, error) { return r.keys.AlertKey(h.Epoch) })
		if err != nil {
			r.t.Fatalf("the push to %s does not open: %v", c.relay, err)
		}
		out[c.relay] = struct {
			epoch uint32
			env   []byte
		}{h.Epoch, c.env}
	}
	return out
}

// TestAlertPushSealedOncePerEpochItsPhonesHold: phones on the same epoch
// share one seal; a phone on another gets its own, in the epoch EpochFor
// names (0 = the current one).
func TestAlertPushSealedOncePerEpochItsPhonesHold(t *testing.T) {
	r := newRig(t, "phone-a", "phone-b", "phone-c")
	r.keys.current = 3
	r.epochOf = map[string]uint32{"phone-a": 2, "phone-c": 2}
	r.start()
	r.enqueue("ask-1")
	r.nextN(3)
	got := r.sealedEpochs()
	a, b, c := got["relay-phone-a"], got["relay-phone-b"], got["relay-phone-c"]
	if a.epoch != 2 || c.epoch != 2 || b.epoch != 3 {
		t.Fatalf("sealed in epochs a=%d b=%d c=%d, want 2, 3, 2", a.epoch, b.epoch, c.epoch)
	}
	if !bytes.Equal(a.env, c.env) {
		t.Fatal("two phones on one epoch got two seals, want one")
	}
}

// TestAlertPushInAnEpochGoneIsSealedInTheCurrentOne: an epoch whose keys left
// between EpochFor and the seal falls back to the current epoch, the rule's
// answer past retention; the push still goes.
func TestAlertPushInAnEpochGoneIsSealedInTheCurrentOne(t *testing.T) {
	r := newRig(t, "phone-a")
	r.keys.current = 3
	r.keys.gone = map[uint32]bool{2: true}
	r.epochOf = map[string]uint32{"phone-a": 2}
	r.start()
	r.enqueue("ask-1")
	if s := r.next(); s.outcome != state.AlertAccepted {
		t.Fatalf("settled %+v, want accepted", s)
	}
	if e := r.sealedEpochs()["relay-phone-a"].epoch; e != 3 {
		t.Fatalf("sealed in epoch %d, want the current 3", e)
	}
}

// TestAFailedSealSettlesOnlyItsEpochsPhones: when one epoch's seal fails the
// phones on it settle failed and the others are still pushed.
func TestAFailedSealSettlesOnlyItsEpochsPhones(t *testing.T) {
	r := newRig(t, "phone-a", "phone-b")
	r.keys.current = 3
	r.keys.gone = map[uint32]bool{3: true} // the current epoch does not seal
	r.epochOf = map[string]uint32{"phone-a": 2}
	r.start()
	r.enqueue("ask-1")
	got := r.nextN(2)
	slices.SortFunc(got, func(x, y settled) int { return strings.Compare(x.device, y.device) })
	want := []settled{{"ask-1", "phone-a", "accepted", ""}, {"ask-1", "phone-b", "failed", ""}}
	if !slices.Equal(got, want) {
		t.Fatalf("settled %v; want %v", got, want)
	}
	if n := r.send.count("relay-phone-b"); n != 0 {
		t.Fatalf("send_alert to the phone whose seal failed %d times", n)
	}
}
