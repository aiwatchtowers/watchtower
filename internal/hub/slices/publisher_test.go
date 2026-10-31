package slices

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/link"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/wire"
	"watchtower/internal/logcanary"
)

const testZone = "data/hubtest-acme"

// fakeSource is a settable slice that records when it was read.
type fakeSource struct {
	kind Kind

	mu     sync.Mutex
	items  []Item
	err    error
	calls  []time.Time
	during func() // run inside Items (a mid-cycle event)
}

func (s *fakeSource) Kind() Kind { return s.kind }

func (s *fakeSource) Items(context.Context) ([]Item, error) {
	s.mu.Lock()
	s.calls = append(s.calls, time.Now())
	items, err, during := slices.Clone(s.items), s.err, s.during
	s.mu.Unlock()
	if during != nil {
		during()
	}
	out := make([]Item, len(items))
	for i, it := range items {
		it.Payload = bytes.Clone(it.Payload)
		out[i] = it
	}
	return out, err
}

func (s *fakeSource) set(items ...Item) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.items, s.err = items, nil
}

func (s *fakeSource) fail(err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.err = err
}

func (s *fakeSource) readTimes() []time.Time {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.calls)
}

// rig is one hub: a sidecar, a keyring, a fake transport, a settable clock.
type rig struct {
	t      *testing.T
	st     *state.Store
	kr     *identity.Keyring
	tr     *memfake.Fake
	mu     sync.Mutex
	now    time.Time
	linked bool
}

func newRig(t *testing.T, kind transport.Kind) *rig {
	t.Helper()
	st, err := state.Open(filepath.Join(t.TempDir(), "hub"))
	if err != nil {
		t.Fatalf("state.Open: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })
	id, err := identity.New()
	if err != nil {
		t.Fatal(err)
	}
	r := &rig{t: t, st: st, now: time.Unix(1_800_000_000, 0).UTC(), linked: true}
	if r.kr, err = identity.NewKeyring(id, st, r.clock); err != nil {
		t.Fatalf("NewKeyring: %v", err)
	}
	r.tr = memfake.New(kind, r.clock)
	return r
}

func (r *rig) clock() time.Time {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.now
}

func (r *rig) advance(d time.Duration) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.now = r.now.Add(d)
}

func (r *rig) setLinked(on bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.linked = on
}

func (r *rig) publisher(sources ...Source) *Publisher {
	return r.publisherWith(Config{}, sources...)
}

func (r *rig) publisherWith(c Config, sources ...Source) *Publisher {
	c.Store, c.Transport, c.Sealer, c.DataZone, c.Sources = r.st, r.tr, secure.NewSealer(r.kr), testZone, sources
	if c.Clock == nil {
		c.Clock = r.clock
	}
	c.Linked = func() (bool, error) {
		r.mu.Lock()
		defer r.mu.Unlock()
		return r.linked, nil
	}
	return NewPublisher(c)
}

func (r *rig) cycle(p *Publisher, kinds ...Kind) CycleReport {
	r.t.Helper()
	if len(kinds) == 0 {
		kinds = nil
	}
	rep, err := p.Cycle(context.Background(), kinds)
	if err != nil {
		r.t.Fatalf("Cycle: %v", err)
	}
	return rep
}

// live is the zone's live records by wire name.
func (r *rig) live() map[string][]byte {
	r.t.Helper()
	out := map[string][]byte{}
	var since uint64
	for {
		b, err := r.tr.Changes(context.Background(), testZone, since)
		if err != nil {
			r.t.Fatal(err)
		}
		for _, s := range b.Changed {
			out[s.Name] = s.Envelope
		}
		for _, n := range b.Deleted {
			delete(out, n)
		}
		since = b.NewSeq
		if !b.More {
			return out
		}
	}
}

// opened opens a data record the way the phone does and returns its frame.
func (r *rig) opened(env []byte, wireName string) secure.InnerFrame {
	r.t.Helper()
	_, f, err := secure.OpenSymmetric(env, []secure.EnvelopeClass{secure.ClassData},
		secure.Context{Zone: secure.ZoneData, WireName: wireName}, r.kr.Signer().Public().(ed25519.PublicKey),
		func(h secure.Header) ([]byte, error) { return r.kr.DataKey(h.Epoch) })
	if err != nil {
		r.t.Fatalf("open %s: %v", wireName, err)
	}
	return f
}

func (r *rig) wireName(plain string) string {
	r.t.Helper()
	w, err := secure.NewSealer(r.kr).WireName(secure.ZoneData, plain)
	if err != nil {
		r.t.Fatal(err)
	}
	return w
}

func item(id, payload string) Item { return Item{ID: id, Payload: []byte(payload)} }

func TestUnchangedPayloadIsNotResaved(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	src := &fakeSource{kind: "target"}
	src.set(item("1", `{"id":1,"title":"a"}`), item("2", `{"id":2}`))
	p := r.publisher(src)
	if rep := r.cycle(p); rep.Saved != 2 || len(rep.Skipped) != 0 {
		t.Fatalf("first cycle = %+v", rep)
	}
	frames := len(r.tr.Frames())
	r.advance(time.Second)
	if rep := r.cycle(p); rep.Saved != 0 || rep.Deleted != 0 {
		t.Fatalf("unchanged cycle = %+v", rep)
	}
	if got := len(r.tr.Frames()); got != frames {
		t.Fatalf("unchanged cycle saved %d records", got-frames)
	}
	src.set(item("1", `{"id":1,"title":"b"}`), item("2", `{"id":2}`))
	r.advance(time.Second)
	if rep := r.cycle(p); rep.Saved != 1 {
		t.Fatalf("changed cycle = %+v", rep)
	}
	w := r.wireName("target-1")
	env, ok := r.live()[w]
	if !ok {
		t.Fatalf("target-1 not live under %s", w)
	}
	if f := r.opened(env, w); f.Kind != "target" || f.ID != "target-1" || string(f.Payload) != `{"id":1,"title":"b"}` {
		t.Fatalf("frame = %+v", f)
	}
	hashes, err := r.st.SliceHashes("target")
	if err != nil || len(hashes) != 2 || hashes["target-1"].WireName != w {
		t.Fatalf("slice state = %+v %v", hashes, err)
	}
	// A rotation wipes the hashes: the next cycle reseals the window.
	if err := r.kr.Rotate(identity.ReasonManual); err != nil {
		t.Fatal(err)
	}
	r.advance(time.Second)
	if rep := r.cycle(p); rep.Saved != 2 {
		t.Fatalf("cycle after rotation = %+v", rep)
	}
}

func TestGoneRecordIsDeleted(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	src := &fakeSource{kind: "target"}
	src.set(item("1", `{"id":1}`), item("2", `{"id":2}`))
	p := r.publisher(src)
	r.cycle(p)
	gone := r.wireName("target-2")
	if _, ok := r.live()[gone]; !ok {
		t.Fatal("target-2 never published")
	}

	// A failing source deletes nothing.
	src.fail(errors.New("boom"))
	r.advance(time.Second)
	if rep := r.cycle(p); rep.Deleted != 0 || !slices.Equal(rep.Failed, []Kind{"target"}) {
		t.Fatalf("failed-source cycle = %+v", rep)
	}

	src.set(item("1", `{"id":1}`))
	r.advance(time.Second)
	if rep := r.cycle(p); rep.Deleted != 1 || rep.Saved != 0 {
		t.Fatalf("cycle = %+v", rep)
	}
	live := r.live()
	if _, ok := live[gone]; ok || len(live) != 1 {
		t.Fatalf("live after delete = %d records, gone still there: %v", len(live), ok)
	}
	hashes, err := r.st.SliceHashes("target")
	if _, ok := hashes["target-2"]; err != nil || ok || len(hashes) != 1 {
		t.Fatalf("slice state = %+v %v", hashes, err)
	}
}

// phone is a linked phone's agreement key.
type phone struct {
	kx *ecdh.PrivateKey
	id secure.ID
}

// linkPhone writes a linked phone with keys into the sidecar.
func (r *rig) linkPhone() phone {
	r.t.Helper()
	_, sig, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		r.t.Fatal(err)
	}
	kx, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		r.t.Fatal(err)
	}
	p := phone{kx: kx, id: secure.DeviceID(sig.Public().(ed25519.PublicKey))}
	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0xa}, 16))
	if err := r.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		return state.LinkDevice(tx, state.Device{
			ID: p.id.String(), Name: "iPhone", Scope: wire.ScopePrivate, LinkedAt: r.clock(),
			SigningKey: sig.Public().(ed25519.PublicKey), AgreementKey: kx.PublicKey().Bytes(), LinkNonce: nonce,
		})
	}); err != nil {
		r.t.Fatal(err)
	}
	return p
}

func (r *rig) center() *link.Center {
	return link.NewCenter(link.Config{
		Store: r.st, Keys: r.kr, Opener: secure.NewOpener(r.kr, r.kr), Clock: r.clock,
		Host: link.HostInfo{Name: "acme-host", Transports: []string{wire.TransportRelay},
			RelayDeviceID: "relaydeviceidacme", RelayAuthPub: "cmVsYXktYXV0aC1wdWItYWNtZQ"},
	})
}

func TestOnlyUnlinkedKindsWhileNoPhone(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	ph := r.linkPhone()
	target := &fakeSource{kind: "target"}
	target.set(item("1", `{"id":1}`))
	r.setLinked(false)
	p := r.publisher(target, GrantSource(r.center()))

	rep := r.cycle(p)
	if rep.Saved != 1 {
		t.Fatalf("unlinked cycle = %+v", rep)
	}
	if len(target.readTimes()) != 0 {
		t.Fatal("a normal kind was read with no phone linked")
	}
	box := "keybox-" + ph.id.String()
	env, ok := r.live()[box]
	if !ok || len(r.live()) != 1 {
		t.Fatalf("live = %d records, keybox there: %v", len(r.live()), ok)
	}
	hub := r.kr.HubID()
	_, f, err := secure.OpenHPKE(env, secure.ClassKeybox, ph.kx, secure.KeyboxInfo(hub, ph.id),
		secure.Context{Zone: secure.ZoneData, WireName: box}, r.kr.Signer().Public().(ed25519.PublicKey))
	if err != nil {
		t.Fatalf("open keybox: %v", err)
	}
	var kb wire.Keybox
	if err := json.Unmarshal(f.Payload, &kb); err != nil {
		t.Fatal(err)
	}
	if f.ID != "device_grant-"+ph.id.String() || !kb.Grant.Linked || kb.Keys == nil ||
		!slices.Equal(kb.Grant.Transports, []string{wire.TransportRelay}) || kb.Grant.RelayDeviceID != "relaydeviceidacme" ||
		kb.Grant.RelayAuthPub != "cmVsYXktYXV0aC1wdWItYWNtZQ" || kb.Grant.OrderedActions == nil || *kb.Grant.OrderedActions != 1 {
		t.Fatalf("keybox = %s %+v", f.ID, kb.Grant)
	}

	// The first cycle that sees a phone diffs every kind, whatever it was asked.
	r.setLinked(true)
	r.advance(time.Second)
	if rep := r.cycle(p, KindDeviceGrant); rep.Saved != 1 {
		t.Fatalf("newly linked cycle = %+v", rep)
	}
	if _, ok := r.live()[r.wireName("target-1")]; !ok {
		t.Fatal("target not published once a phone is linked")
	}
	// Then a cycle diffs only what it is asked.
	target.set(item("1", `{"id":1,"v":2}`))
	r.advance(time.Second)
	if rep := r.cycle(p, KindDeviceGrant); rep.Saved != 0 {
		t.Fatalf("device_grant-only cycle = %+v", rep)
	}
}

func TestAKindIsSavedAtMostOncePerSpacing(t *testing.T) {
	if RelaySpacing != 150*time.Millisecond || CloudKitSpacing != 2*time.Second {
		t.Fatalf("spacing constants = %v / %v", RelaySpacing, CloudKitSpacing)
	}
	for _, tc := range []struct {
		kind    transport.Kind
		spacing time.Duration
	}{{transport.KindRelay, RelaySpacing}, {transport.KindCloudKit, CloudKitSpacing}} {
		t.Run(string(tc.kind), func(t *testing.T) {
			r := newRig(t, tc.kind)
			src := &fakeSource{kind: "target"}
			src.set(item("1", `{"v":1}`))
			p := r.publisher(src)
			start := r.clock()
			if rep := r.cycle(p); rep.Saved != 1 {
				t.Fatalf("first = %+v", rep)
			}
			src.set(item("1", `{"v":2}`))
			r.advance(tc.spacing - time.Millisecond)
			rep := r.cycle(p)
			if rep.Saved != 0 || !rep.Deferred["target"].Equal(start.Add(tc.spacing)) {
				t.Fatalf("within spacing = %+v", rep)
			}
			r.advance(time.Millisecond)
			if rep := r.cycle(p); rep.Saved != 1 || len(rep.Deferred) != 0 {
				t.Fatalf("at spacing = %+v", rep)
			}
		})
	}
}

// fakeTime is Run's clock and timers under the test's control.
type fakeTime struct {
	mu     sync.Mutex
	now    time.Time
	timers map[int]fakeTimer
	nextID int
	armed  int
}

type fakeTimer struct {
	at time.Time
	ch chan time.Time
}

func newFakeTime() *fakeTime {
	return &fakeTime{now: time.Unix(1_800_000_000, 0).UTC(), timers: map[int]fakeTimer{}}
}

func (f *fakeTime) Now() time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.now
}

func (f *fakeTime) Timer(d time.Duration) (<-chan time.Time, func()) {
	f.mu.Lock()
	defer f.mu.Unlock()
	ch := make(chan time.Time, 1)
	id := f.nextID
	f.nextID++
	f.armed++
	if d <= 0 {
		ch <- f.now
	} else {
		f.timers[id] = fakeTimer{at: f.now.Add(d), ch: ch}
	}
	return ch, func() {
		f.mu.Lock()
		defer f.mu.Unlock()
		delete(f.timers, id)
	}
}

func (f *fakeTime) armedCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.armed
}

// advance moves the clock and fires the timers due; true when one fired.
func (f *fakeTime) advance(d time.Duration) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.now = f.now.Add(d)
	fired := false
	for id, t := range f.timers {
		if !t.at.After(f.now) {
			t.ch <- f.now
			delete(f.timers, id)
			fired = true
		}
	}
	return fired
}

// runner drives p.Run on a fake clock, one settled step at a time: every
// step waits until Run has gone back to sleep on a new timer.
type runner struct {
	t  *testing.T
	ft *fakeTime
	p  *Publisher
}

func (r *rig) runFake(sources ...Source) *runner {
	r.t.Helper()
	ft := newFakeTime()
	p := r.publisherWith(Config{Clock: ft.Now}, sources...)
	p.mono, p.timer = ft.Now, ft.Timer
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- p.Run(ctx) }()
	r.t.Cleanup(func() {
		cancel()
		if err := <-done; !errors.Is(err, context.Canceled) {
			r.t.Errorf("Run = %v", err)
		}
	})
	ru := &runner{t: r.t, ft: ft, p: p}
	ru.settle(0) // the full cycle at start
	return ru
}

// settle waits (bounded) until Run armed more than n timers.
func (ru *runner) settle(n int) {
	ru.t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for ru.ft.armedCount() <= n {
		if time.Now().After(deadline) {
			ru.t.Fatal("Run never went back to sleep")
		}
		time.Sleep(time.Millisecond)
	}
}

func (ru *runner) publishSoon(k Kind) {
	n := ru.ft.armedCount()
	ru.p.PublishSoon(k)
	ru.settle(n)
}

// step advances the fake clock and lets Run handle what fell due.
func (ru *runner) step(d time.Duration) {
	n := ru.ft.armedCount()
	if ru.ft.advance(d) {
		ru.settle(n)
	}
}

func TestDebounceCoalescesBurst(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	src := &fakeSource{kind: "target"}
	src.set(item("1", `{"v":1}`))
	ru := r.runFake(src)
	if n := len(src.readTimes()); n != 1 {
		t.Fatalf("start read %d times", n)
	}
	for range 5 {
		ru.publishSoon("target")
		ru.step(20 * time.Millisecond)
	}
	if n := len(src.readTimes()); n != 1 {
		t.Fatalf("read %d times inside the burst", n)
	}
	ru.step(Debounce)
	ru.step(Debounce)
	if n := len(src.readTimes()); n != 2 {
		t.Fatalf("source read %d times after a burst, want 1 + 1", n)
	}
}

func TestDebounceMaxWaitBoundsAContinuousBurst(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	src := &fakeSource{kind: "target"}
	src.set(item("1", `{"v":1}`))
	ru := r.runFake(src)
	last, reads, cycles := ru.ft.Now(), 1, 0
	for range 30 { // PublishSoon every 100 ms for 3 s: the trailing debounce never comes
		ru.publishSoon("target")
		ru.step(100 * time.Millisecond)
		if n := len(src.readTimes()); n > reads {
			reads, cycles, last = n, cycles+1, ru.ft.Now()
		}
		if gap := ru.ft.Now().Sub(last); gap > MaxDebounceWait {
			t.Fatalf("a dirty kind waited %v, more than %v", gap, MaxDebounceWait)
		}
	}
	if cycles < 3 {
		t.Fatalf("%d cycles in a 3 s burst, want one every %v", cycles, MaxDebounceWait)
	}
}

// A failed save is retried after RetryFirst, then after a doubled delay,
// well before the full diff.
func TestFailedSaveIsRetriedWithBackoff(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	r.tr.FailNext("save", transport.ErrUnavailable)
	r.tr.FailNext("save", transport.ErrUnavailable)
	src := &fakeSource{kind: "owner_ask"}
	src.set(item("1", `{"id":1}`))
	ru := r.runFake(src)
	w := r.wireName("owner_ask-1")
	if _, ok := r.live()[w]; ok {
		t.Fatal("saved through a failing transport")
	}
	ru.step(RetryFirst) // second attempt fails: the next waits 2 s
	if n := len(src.readTimes()); n != 2 {
		t.Fatalf("read %d times after the first retry", n)
	}
	ru.step(RetryFirst)
	if n := len(src.readTimes()); n != 2 {
		t.Fatalf("retried before the doubled delay: %d reads", n)
	}
	ru.step(RetryFirst)
	if _, ok := r.live()[w]; !ok {
		t.Fatal("owner_ask not published by the retry")
	}
	if RetryFirst != time.Second || RetryMax != 10*time.Second {
		t.Fatalf("retry bounds = %v / %v", RetryFirst, RetryMax)
	}
}

func TestFailedSourceIsRetried(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	src := &fakeSource{kind: "permission_request"}
	src.set(item("1", `{"id":1}`))
	src.fail(errors.New("db busy"))
	ru := r.runFake(src)
	src.set(item("1", `{"id":1}`))
	ru.step(RetryFirst)
	if _, ok := r.live()[r.wireName("permission_request-1")]; !ok {
		t.Fatal("kind with a failed source not retried")
	}
}

// A failed save leaves its kind and every kind after it unfinished.
func TestCycleReportsUnfinishedKinds(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	ask, target := &fakeSource{kind: "owner_ask"}, &fakeSource{kind: "target"}
	ask.set(item("1", `{"id":1}`))
	target.set(item("1", `{"id":1}`))
	r.tr.FailNext("save", transport.ErrUnavailable)
	rep, err := r.publisher(target, ask).Cycle(context.Background(), nil)
	if !errors.Is(err, transport.ErrUnavailable) || !slices.Equal(rep.Unfinished, []Kind{"owner_ask", "target"}) {
		t.Fatalf("Cycle = %+v %v", rep, err)
	}
}

func TestOversizedRecordIsSkippedAndLogged(t *testing.T) {
	sink := logcanary.Capture(t)
	r := newRig(t, transport.KindRelay)
	canary := logcanary.Text("target.title")
	big := `{"title":"` + canary + strings.Repeat("a", secure.MaxEnvelopeBytes) + `"}`
	src := &fakeSource{kind: "target"}
	src.set(item("big", big), item("1", `{"title":"`+canary+`"}`))
	p := r.publisher(src)
	rep := r.cycle(p)
	if rep.Saved != 1 || !slices.Equal(rep.Skipped, []string{"target-big"}) {
		t.Fatalf("cycle = %+v", rep)
	}
	if _, ok := r.live()[r.wireName("target-big")]; ok {
		t.Fatal("oversized record saved")
	}
	hashes, _ := r.st.SliceHashes("target")
	if _, ok := hashes["target-big"]; ok {
		t.Fatal("oversized record hashed: it would never be retried")
	}
	if n := strings.Count(sink.String(), "target-big"); n != 1 || !strings.Contains(sink.String(), "oversized") {
		t.Fatalf("log = %q", sink.String())
	}
	// Unchanged, it is skipped again without another line; shrunk, it goes.
	r.advance(time.Second)
	r.cycle(p)
	if n := strings.Count(sink.String(), "target-big"); n != 1 {
		t.Fatalf("logged %d times for one payload", n)
	}
	src.set(item("big", `{"title":"small"}`), item("1", `{"title":"`+canary+`"}`))
	r.advance(time.Second)
	if rep := r.cycle(p); rep.Saved != 1 {
		t.Fatalf("shrunk cycle = %+v", rep)
	}
	sink.AssertClean(t)
}

// A rotation committed while a kind is sealed records nothing; the next
// cycle reseals under the new epoch.
func TestRotationMidCycleRecordsNothing(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	src := &fakeSource{kind: "target"}
	src.set(item("1", `{"v":1}`))
	src.during = func() {
		src.mu.Lock()
		src.during = nil
		src.mu.Unlock()
		if err := r.kr.Rotate(identity.ReasonManual); err != nil {
			t.Error(err)
		}
	}
	p := r.publisher(src)
	if rep := r.cycle(p); !rep.Aborted || rep.Saved != 0 {
		t.Fatalf("cycle = %+v", rep)
	}
	if hashes, _ := r.st.SliceHashes("target"); len(hashes) != 0 {
		t.Fatalf("hashes recorded across a rotation: %+v", hashes)
	}
	r.advance(time.Second)
	if rep := r.cycle(p); rep.Saved != 1 || rep.Aborted {
		t.Fatalf("next cycle = %+v", rep)
	}
}

func TestNoKeysPublishesNothing(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	if err := r.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		_, err := tx.Exec(`DELETE FROM hub_epochs`)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	src := &fakeSource{kind: "target"}
	src.set(item("1", `{"v":1}`))
	if _, err := r.publisher(src).Cycle(context.Background(), nil); !errors.Is(err, ErrNoKeys) {
		t.Fatalf("Cycle = %v, want ErrNoKeys", err)
	}
	if len(r.tr.Frames()) != 0 {
		t.Fatal("published without keys")
	}
}
