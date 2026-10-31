package hub

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"io/fs"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/link"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/wire"
	"watchtower/internal/logcanary"
	"watchtower/internal/policy/policytest"
)

// shortDir is a fresh hub dir with a short path: a unix socket path is
// capped near 104 bytes, which a t.TempDir path can pass on macOS.
func shortDir(t *testing.T) string {
	t.Helper()
	base, err := os.MkdirTemp("/tmp", "hubt")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(base) })
	return filepath.Join(base, "h")
}

// recorder keeps every status a Run reports.
type recorder struct {
	mu  sync.Mutex
	all []Status
}

func (r *recorder) report(s Status) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.all = append(r.all, s)
}

func (r *recorder) last() Status {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.all) == 0 {
		return Status{}
	}
	return r.all[len(r.all)-1]
}

// eventually polls cond until it holds or d passes.
func eventually(t *testing.T, d time.Duration, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(d)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// rig is one Run under test.
type rig struct {
	t      *testing.T
	dir    string
	fake   *memfake.Fake
	rec    *recorder
	opens  atomic.Int32
	dials  atomic.Int32
	cancel context.CancelFunc
	done   chan error
}

// options are a test Run's options over the fake: short cadences, every
// store open and transport build counted.
func (r *rig) options() Options {
	return Options{
		Dir: r.dir,
		newTransport: func(context.Context, identity.Identity, *state.Store, []string) (transport.Transport, error) {
			r.dials.Add(1)
			return r.fake, nil
		},
		openStore: func(dir string) (*state.Store, error) {
			r.opens.Add(1)
			return state.Open(dir)
		},
		report:     r.rec.report,
		checkEvery: 50 * time.Millisecond,
		passEvery:  200 * time.Millisecond,
		lockRetry:  50 * time.Millisecond,
	}
}

func newRig(t *testing.T, dir string) *rig {
	t.Helper()
	return &rig{t: t, dir: dir, fake: memfake.New(transport.KindRelay, nil), rec: &recorder{}}
}

// start runs o in the background until the test ends.
func (r *rig) start(o Options) {
	r.t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	r.cancel, r.done = cancel, make(chan error, 1)
	go func() { r.done <- Run(ctx, o) }()
	r.t.Cleanup(func() { _ = r.stop() })
}

// stop cancels the Run and waits for it.
func (r *rig) stop() error {
	r.t.Helper()
	if r.cancel == nil {
		return nil
	}
	r.cancel()
	r.cancel = nil
	select {
	case err := <-r.done:
		return err
	case <-time.After(10 * time.Second):
		r.t.Fatal("Run did not return after cancel")
		return nil
	}
}

func (r *rig) waitState(state, reason string) {
	r.t.Helper()
	eventually(r.t, 10*time.Second, state+"/"+reason, func() bool {
		s := r.rec.last()
		return s.State == state && s.Reason == reason
	})
}

// setMeta writes hub_meta values with no hub running.
func setMeta(t *testing.T, dir string, kv ...string) {
	t.Helper()
	st, err := state.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = st.Close() }()
	for i := 0; i+1 < len(kv); i += 2 {
		if err := st.SetMeta(kv[i], kv[i+1]); err != nil {
			t.Fatal(err)
		}
	}
}

func readMeta(t *testing.T, dir, key string) (string, bool) {
	t.Helper()
	st, err := state.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = st.Close() }()
	v, ok, err := st.Meta(key)
	if err != nil {
		t.Fatal(err)
	}
	return v, ok
}

// linkPhoneDirectly writes a linked phone's row with no hub running.
func linkPhoneDirectly(t *testing.T, dir string) {
	t.Helper()
	p, err := hubtest.New(hubtest.Config{})
	if err != nil {
		t.Fatal(err)
	}
	st, err := state.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = st.Close() }()
	if err := st.WithTx(context.Background(), func(tx *sql.Tx) error { return state.LinkDevice(tx, p.Device()) }); err != nil {
		t.Fatal(err)
	}
}

func liveRecords(t *testing.T, f *memfake.Fake, zone string) []string {
	t.Helper()
	var names []string
	var since uint64
	for {
		b, err := f.Changes(context.Background(), zone, since)
		if err != nil {
			t.Fatal(err)
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

func noEntries(t *testing.T, dir string) {
	t.Helper()
	if _, err := os.Stat(dir); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("the hub dir was created (stat: %v)", err)
	}
}

func TestSecondHubRefusedWhileLocked(t *testing.T) {
	policytest.Set(t, nil)
	dir := shortDir(t)
	setMeta(t, dir, state.MetaEnabled, "1")
	first := newRig(t, dir)
	first.start(first.options())
	first.waitState(StateRunning, "")

	second := newRig(t, dir)
	second.fake = first.fake
	second.start(second.options())
	second.waitState(StateStarting, ReasonLocked)
	time.Sleep(200 * time.Millisecond) // a few lock retries
	if n := second.opens.Load(); n != 0 {
		t.Fatalf("the second hub opened the sidecar %d times while the first held the lock", n)
	}
	if s, err := ReadStatus(dir); err != nil || s.State != StateRunning {
		t.Fatalf("the waiting hub overwrote the running hub's status: %+v, %v", s, err)
	}

	if err := first.stop(); err != nil {
		t.Fatal(err)
	}
	second.waitState(StateRunning, "")
	if n := second.opens.Load(); n != 1 {
		t.Fatalf("second hub opened the sidecar %d times", n)
	}
}

func TestHubStartWaitsForACLIHoldingTheLock(t *testing.T) {
	policytest.Set(t, nil)
	t.Run("within the retry window", func(t *testing.T) {
		dir := shortDir(t)
		setMeta(t, dir, state.MetaEnabled, "1")
		lock, err := state.AcquireLock(dir)
		if err != nil {
			t.Fatal(err)
		}
		r := newRig(t, dir)
		o := r.options()
		o.lockRetry = 0 // the production 1 s
		r.start(o)
		r.waitState(StateStarting, ReasonLocked)
		if s, _ := ReadStatus(dir); s.State != StateStarting || s.Reason != ReasonLocked {
			t.Fatalf("status while a CLI holds the lock: %+v", s)
		}
		time.Sleep(2500 * time.Millisecond)
		if r.opens.Load() != 0 {
			t.Fatal("the sidecar was opened while the CLI held the lock")
		}
		released := time.Now()
		if err := lock.Release(); err != nil {
			t.Fatal(err)
		}
		r.waitState(StateRunning, "")
		if d := time.Since(released); d > 2*time.Second { // one 1 s retry plus scheduling slack under load
			t.Fatalf("the hub started %s after the lock was released, want within the 1 s retry", d)
		}
	})
	t.Run("past the window it retries per cycle", func(t *testing.T) {
		dir := shortDir(t)
		setMeta(t, dir, state.MetaEnabled, "1")
		lock, err := state.AcquireLock(dir)
		if err != nil {
			t.Fatal(err)
		}
		r := newRig(t, dir)
		tick := make(chan struct{})
		o := r.options()
		o.lockRetry, o.lockWindow, o.CycleTick = 20*time.Millisecond, 100*time.Millisecond, tick
		r.start(o)
		r.waitState(StateStarting, ReasonLocked)
		time.Sleep(200 * time.Millisecond) // past the window
		if err := lock.Release(); err != nil {
			t.Fatal(err)
		}
		time.Sleep(300 * time.Millisecond)
		if r.opens.Load() != 0 {
			t.Fatal("the hub retried the lock past its window without a daemon cycle")
		}
		tick <- struct{}{}
		r.waitState(StateRunning, "")
	})
}

func TestHubRefusesWithoutMatchingTestWorkspace(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "hub")
	t.Setenv(EnvHubDir, dir)
	t.Setenv(EnvRelayOrigin, "https://relay.example.com")
	for _, c := range []struct{ name, env, active string }{
		{"unset", "", "hubtest-a"},
		{"another workspace", "hubtest-b", "hubtest-a"},
		{"a live name, even when named", "acme", "acme"},
		{"a prefixed name that is not the active one", "hubtest-a", "acme"},
	} {
		t.Run(c.name, func(t *testing.T) {
			t.Setenv(EnvTestWorkspace, c.env)
			_, ok, err := FromEnv(&config.Config{ActiveWorkspace: c.active}, nil)
			if ok || !errors.Is(err, ErrNotTestWorkspace) || Refusal(err) != ReasonNotTestWorkspace {
				t.Fatalf("FromEnv: ok=%v err=%v", ok, err)
			}
			noEntries(t, dir)
		})
	}
	t.Setenv(EnvTestWorkspace, "hubtest-a")
	o, ok, err := FromEnv(&config.Config{ActiveWorkspace: "hubtest-a"}, nil)
	if !ok || err != nil || o.Dir != dir || o.RelayOrigin != "https://relay.example.com" ||
		o.RecordingsDir != filepath.Join(dir, "recordings") {
		t.Fatalf("FromEnv in the test workspace: %+v ok=%v err=%v", o, ok, err)
	}
	noEntries(t, dir)
	t.Setenv(EnvHubDir, "")
	if _, ok, err := FromEnv(&config.Config{ActiveWorkspace: "hubtest-a"}, nil); ok || err != nil {
		t.Fatalf("no hub dir: ok=%v err=%v", ok, err)
	}
}

func TestDevFlagRefusesSwiftHubDir(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv(EnvRelayOrigin, "https://relay.example.com")
	t.Setenv(EnvTestWorkspace, "hubtest-a")
	cfg := &config.Config{ActiveWorkspace: "hubtest-a"}
	support, err := config.AppSupportDir()
	if err != nil {
		t.Fatal(err)
	}
	swift := filepath.Join(support, "MobileHub")
	for _, dir := range []string{swift, filepath.Join(swift, "go"), swift + "/./x/.."} {
		t.Setenv(EnvHubDir, dir)
		if _, ok, err := FromEnv(cfg, nil); ok || !errors.Is(err, ErrSwiftHubDir) {
			t.Fatalf("FromEnv(%s): ok=%v err=%v", dir, ok, err)
		}
		if err := Run(context.Background(), Options{Dir: dir}); !errors.Is(err, ErrSwiftHubDir) {
			t.Fatalf("Run(%s): %v", dir, err)
		}
		noEntries(t, swift)
	}
	t.Setenv(EnvHubDir, "relative/hub")
	if _, ok, err := FromEnv(cfg, nil); ok || !errors.Is(err, ErrDirNotAbsolute) {
		t.Fatalf("relative dir: ok=%v err=%v", ok, err)
	}
	// A sibling of MobileHub is not the Swift hub's dir.
	t.Setenv(EnvHubDir, filepath.Join(support, "MobileHubGo"))
	if _, ok, err := FromEnv(cfg, nil); !ok || err != nil {
		t.Fatalf("sibling dir: ok=%v err=%v", ok, err)
	}
}

func TestHubOffWithoutRelayOrigin(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "hub")
	t.Setenv(EnvHubDir, dir)
	t.Setenv(EnvTestWorkspace, "hubtest-a")
	cfg := &config.Config{ActiveWorkspace: "hubtest-a"}
	for _, origin := range []string{"", "relay.example.com", "ftp://relay.example.com", "https://"} {
		t.Setenv(EnvRelayOrigin, origin)
		if _, ok, err := FromEnv(cfg, nil); ok || !errors.Is(err, ErrNoRelayOrigin) {
			t.Fatalf("origin %q: ok=%v err=%v", origin, ok, err)
		}
		noEntries(t, dir)
	}
}

// TestPolicy03_OffStopsHubKeepsSetting is the Go twin of
// MobileHubPolicyTests.testOffStopsHubKeepsSetting: MobileSync = off stops
// the running hub and deletes what it published, and the owner's switch is
// left as it was; turning it on is refused while off.
func TestPolicy03_OffStopsHubKeepsSetting(t *testing.T) {
	policytest.Set(t, map[string]any{"MobileSync": "allowed"})
	dir := shortDir(t)
	setMeta(t, dir, state.MetaEnabled, "1")
	linkPhoneDirectly(t, dir)
	r := newRig(t, dir)
	r.start(r.options())
	r.waitState(StateRunning, "")
	s, err := ReadStatus(dir)
	if err != nil {
		t.Fatal(err)
	}
	data := transport.DataZone(s.RelayDeviceID)
	eventually(t, 10*time.Second, "the heartbeat published", func() bool {
		return slices.Contains(liveRecords(t, r.fake, data), "heartbeat")
	})

	policytest.Set(t, map[string]any{"MobileSync": "off"})
	r.waitState(StateOff, ReasonPolicyOff)
	if got := liveRecords(t, r.fake, data); len(got) != 0 {
		t.Fatalf("the data zone still holds %v after the policy turned off", got)
	}
	c, err := Dial(dir)
	if err != nil {
		t.Fatal(err)
	}
	a, err := c.Do(ControlRequest{Op: OpEnable})
	_ = c.Close()
	if err != nil || a.OK || a.Error != ErrClassPolicyOff {
		t.Fatalf("enable under off: %+v, %v", a, err)
	}
	if err := r.stop(); err != nil {
		t.Fatal(err)
	}
	if v, _ := readMeta(t, dir, state.MetaEnabled); v != "1" {
		t.Fatalf("the owner's switch was rewritten to %q", v)
	}
	st, err := state.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = st.Close() }()
	for _, k := range []string{"heartbeat", "device_grant"} {
		if h, err := st.SliceHashes(k); err != nil || len(h) != 0 {
			t.Fatalf("slice state of %s kept after the wipe: %v %v", k, h, err)
		}
	}
}

// TestPolicy03_LooseningDoesNotStartHubWhenSettingOff is the Go twin of
// MobileHubPolicyTests.testLooseningDoesNotStartHubWhenSettingOff:
// loosening the policy with the owner's switch off starts nothing, wipes
// nothing and leaves the switch off.
func TestPolicy03_LooseningDoesNotStartHubWhenSettingOff(t *testing.T) {
	policytest.Set(t, map[string]any{"MobileSync": "off"})
	dir := shortDir(t)
	r := newRig(t, dir)
	r.start(r.options())
	r.waitState(StateOff, ReasonPolicyOff)
	policytest.Set(t, map[string]any{"MobileSync": "allowed"})
	r.waitState(StateOff, ReasonDisabled)
	time.Sleep(200 * time.Millisecond)
	if n := r.dials.Load(); n != 0 {
		t.Fatalf("a transport was built %d times", n)
	}
	if err := r.stop(); err != nil {
		t.Fatal(err)
	}
	if v, ok := readMeta(t, dir, state.MetaEnabled); ok && v == "1" {
		t.Fatal("loosening turned the owner's switch on")
	}
	if _, err := os.Stat(filepath.Join(dir, identity.FileName)); !errors.Is(err, fs.ErrNotExist) {
		t.Fatal("a hub identity was created for a hub that never started")
	}
}

func TestSidecarUnreadableKeepsHubOffAndSaysSo(t *testing.T) {
	policytest.Set(t, nil)
	dir := shortDir(t)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, state.FileName), bytes.Repeat([]byte("not a database "), 512), 0o600); err != nil {
		t.Fatal(err)
	}
	r := newRig(t, dir)
	o := r.options()
	err := Run(context.Background(), o)
	if !errors.Is(err, ErrSidecarUnreadable) || Refusal(err) != ReasonSidecarUnreadable {
		t.Fatalf("Run: %v", err)
	}
	s, err := ReadStatus(dir)
	if err != nil || s.State != StateOff || s.Reason != ReasonSidecarUnreadable {
		t.Fatalf("status: %+v, %v", s, err)
	}
	if r.dials.Load() != 0 {
		t.Fatal("a transport was built over an unreadable sidecar")
	}
	lock, err := state.AcquireLock(dir)
	if err != nil {
		t.Fatalf("the lock is still held: %v", err)
	}
	_ = lock.Release()
}

func TestRunReleasesLockOnCancel(t *testing.T) {
	policytest.Set(t, nil)
	dir := shortDir(t)
	setMeta(t, dir, state.MetaEnabled, "1")
	r := newRig(t, dir)
	r.start(r.options())
	r.waitState(StateRunning, "")
	if _, err := state.AcquireLock(dir); !errors.Is(err, state.ErrLocked) {
		t.Fatalf("the lock is not held while running: %v", err)
	}
	if err := r.stop(); err != nil {
		t.Fatal(err)
	}
	lock, err := state.AcquireLock(dir)
	if err != nil {
		t.Fatalf("the lock was not released: %v", err)
	}
	_ = lock.Release()
	if _, err := os.Stat(filepath.Join(dir, SocketName)); !errors.Is(err, fs.ErrNotExist) {
		t.Fatal("the control socket is left behind")
	}
	if s, err := ReadStatus(dir); err != nil || s.State != StateOff {
		t.Fatalf("status after cancel: %+v, %v", s, err)
	}
}

func TestControlSocketIsPrivateAndChecksPeer(t *testing.T) {
	policytest.Set(t, nil)
	dir := shortDir(t)
	r := newRig(t, dir)
	var foreign atomic.Bool
	o := r.options()
	o.peerUID = func(c *net.UnixConn) (int, error) {
		uid, err := socketPeerUID(c)
		if foreign.Load() {
			return uid + 1, err
		}
		return uid, err
	}
	r.start(o)
	r.waitState(StateOff, ReasonDisabled)
	eventually(t, 5*time.Second, "the control socket", func() bool {
		_, err := os.Stat(filepath.Join(dir, SocketName))
		return err == nil
	})
	fi, err := os.Stat(filepath.Join(dir, SocketName))
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Type() != fs.ModeSocket || fi.Mode().Perm() != 0o600 {
		t.Fatalf("control socket mode %v", fi.Mode())
	}

	foreign.Store(true)
	c, err := Dial(dir)
	if err != nil {
		t.Fatal(err)
	}
	if a, err := c.Do(ControlRequest{Op: OpEnable}); err == nil {
		t.Fatalf("a client of another user was answered: %+v", a)
	}
	_ = c.Close()
	time.Sleep(200 * time.Millisecond)
	if s := r.rec.last(); s.State != StateOff || s.Reason != ReasonDisabled {
		t.Fatalf("a foreign client's request was applied: %+v", s)
	}

	foreign.Store(false)
	c, err = Dial(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = c.Close() }()
	a, err := c.Do(ControlRequest{Op: OpEnable})
	if err != nil || !a.OK || a.Enabled == nil || !*a.Enabled {
		t.Fatalf("enable: %+v, %v", a, err)
	}
	r.waitState(StateRunning, "")
}

// targetSource is a stand-in for a Plan 1b slice outside workbench_only.
type targetSource struct{}

func (targetSource) Kind() hubslices.Kind { return "target" }
func (targetSource) Items(context.Context) ([]hubslices.Item, error) {
	return []hubslices.Item{{ID: "T1", Payload: []byte(`{"id":"T1"}`)}}, nil
}

// TestWorkbenchOnlyRetriesAFailedDelete: when the switch to workbench_only
// fails to delete a kind it no longer allows, the running hub deletes it on
// a later housekeeping pass instead of forgetting it.
func TestWorkbenchOnlyRetriesAFailedDelete(t *testing.T) {
	policytest.Set(t, map[string]any{"MobileSync": "allowed"})
	dir := shortDir(t)
	setMeta(t, dir, state.MetaEnabled, "1")
	linkPhoneDirectly(t, dir)
	r := newRig(t, dir)
	o := r.options()
	o.Sources = func(*state.Store) []hubslices.Source { return []hubslices.Source{targetSource{}} }
	r.start(o)
	r.waitState(StateRunning, "")
	s, err := ReadStatus(dir)
	if err != nil {
		t.Fatal(err)
	}
	data := transport.DataZone(s.RelayDeviceID)
	count := func() int { return len(liveRecords(t, r.fake, data)) }
	eventually(t, 10*time.Second, "the target published", func() bool { return count() >= 3 }) // grant, heartbeat, target
	published := count()

	r.fake.FailNext("delete", transport.ErrUnavailable)
	policytest.Set(t, map[string]any{"MobileSync": "workbench_only"})
	eventually(t, 10*time.Second, "the target deleted on a retry", func() bool { return count() == published-1 })
	st, err := state.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = st.Close() }()
	if h, err := st.SliceHashes("target"); err != nil || len(h) != 0 {
		t.Fatalf("the target's slice state is kept: %v %v", h, err)
	}
}

// TestStartFailureHasItsOwnReason: a start step that is not a sidecar read
// (here an identity file with loose permissions) reads starting/start_failed,
// never sidecar_unreadable.
func TestStartFailureHasItsOwnReason(t *testing.T) {
	policytest.Set(t, nil)
	dir := shortDir(t)
	setMeta(t, dir, state.MetaEnabled, "1")
	if err := os.WriteFile(filepath.Join(dir, identity.FileName), make([]byte, 136), 0o644); err != nil {
		t.Fatal(err)
	}
	r := newRig(t, dir)
	r.start(r.options())
	r.waitState(StateStarting, ReasonStartFailed)
	if r.dials.Load() != 0 {
		t.Fatal("a transport was built without an identity")
	}
}

// TestControlSocketDropsAStalledClient: a pairing stream that stops reading
// is dropped (write deadline or full queue) and never holds back another
// stream, which gets every pairing event.
func TestControlSocketDropsAStalledClient(t *testing.T) {
	policytest.Set(t, nil)
	dir := shortDir(t)
	setMeta(t, dir, state.MetaEnabled, "1")
	r := newRig(t, dir)
	o := r.options()
	o.writeTimeout = 200 * time.Millisecond
	r.start(o)
	r.waitState(StateRunning, "")

	stalled, err := Dial(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = stalled.Close() }()
	if err := stalled.Send(ControlRequest{Op: OpPair}); err != nil {
		t.Fatal(err)
	}

	good, err := Dial(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = good.Close() }()
	var qrs atomic.Int32
	answers := make(chan ControlAnswer, 1)
	go func() {
		for {
			a, err := good.Next()
			if err != nil {
				close(answers)
				return
			}
			switch {
			case a.Event == link.EventQR:
				qrs.Add(1)
			case a.Op != "":
				answers <- a
			}
		}
	}()
	const n = 60
	for i := range n {
		if err := good.Send(ControlRequest{Op: OpPair}); err != nil {
			t.Fatal(err)
		}
		select {
		case a, ok := <-answers:
			if !ok || !a.OK {
				t.Fatalf("pair %d: %+v (open %v)", i, a, ok)
			}
		case <-time.After(5 * time.Second):
			t.Fatalf("pair %d: no answer: the stalled client holds the hub up", i)
		}
	}
	eventually(t, 10*time.Second, "every qr event on the reading stream", func() bool { return qrs.Load() >= n })

	// The stalled stream was closed: draining it ends in EOF, not a timeout.
	_ = stalled.c.SetReadDeadline(time.Now().Add(10 * time.Second))
	buf := make([]byte, 64<<10)
	for {
		_, err := stalled.c.Read(buf)
		if err == nil {
			continue
		}
		var ne net.Error
		if errors.As(err, &ne) && ne.Timeout() {
			t.Fatal("the stalled client was never dropped")
		}
		break
	}
}

// TestEndToEndOverMemfake links a hubtest phone through the control socket
// and a pairing slot, sends probe a1..a2 and gets applied echoes, and reads
// its device_grant from the data zone with ordered_actions 1 — every record
// on the fake sealed (no plaintext marker in any frame).
func TestEndToEndOverMemfake(t *testing.T) {
	runEndToEnd(t, "")
}

// TestFILES01_HubLogsNoNamesCodesOrKeys: the whole flow — a renamed hub
// (restarted for the name), a pairing, a link and two actions — logs no
// name, no link code or URL and no four-digit code.
func TestFILES01_HubLogsNoNamesCodesOrKeys(t *testing.T) {
	sink := logcanary.Capture(t)
	e := runEndToEnd(t, logcanary.Text("hub.name"))
	sink.AssertClean(t)
	for what, v := range map[string]string{"link URL": e.url, "link nonce": e.nonce, "code": e.code, "phone name": "Test Phone"} {
		if strings.Contains(sink.String(), v) {
			t.Errorf("the %s reached the log", what)
		}
	}
}

// endToEnd is what a run showed the owner and the phone.
type endToEnd struct{ url, nonce, code string }

// runEndToEnd is TestEndToEndOverMemfake; a non-empty name renames the hub
// first (the hub restarts for it) and must reach the link code.
func runEndToEnd(t *testing.T, name string) endToEnd {
	t.Helper()
	policytest.Set(t, nil)
	dir := shortDir(t)
	r := newRig(t, dir)
	r.start(r.options())
	r.waitState(StateOff, ReasonDisabled)
	eventually(t, 5*time.Second, "the control socket", func() bool {
		_, err := os.Stat(filepath.Join(dir, SocketName))
		return err == nil
	})
	c, err := Dial(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = c.Close() }()
	if a, err := c.Do(ControlRequest{Op: OpEnable}); err != nil || !a.OK {
		t.Fatalf("enable: %+v, %v", a, err)
	}
	r.waitState(StateRunning, "")
	if name != "" {
		if a, err := c.Do(ControlRequest{Op: OpName, Name: name}); err != nil || !a.OK || a.Name != name {
			t.Fatalf("name: %+v, %v", a, err)
		}
		time.Sleep(200 * time.Millisecond) // the restart for the new name
		r.waitState(StateRunning, "")
	}
	status, err := ReadStatus(dir)
	if err != nil {
		t.Fatal(err)
	}
	if status.Impl != "go" || status.Transport != "relay" || status.HubID == "" || status.RelayDeviceID == "" {
		t.Fatalf("status: %+v", status)
	}

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
	if lp.RelayDeviceID != status.RelayDeviceID || !slices.Equal(lp.Transports, []string{wire.TransportRelay}) {
		t.Fatalf("link code relay identity: %+v", lp)
	}
	if name != "" && lp.MacName != name {
		t.Fatal("the link code does not carry the hub's new name")
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
	sas := next(link.EventSAS)
	if sas.DeviceID != phone.ID().String() {
		t.Fatalf("sas for %s, want %s", sas.DeviceID, phone.ID())
	}
	var awaiting wire.Keybox
	eventually(t, 10*time.Second, "the awaiting keybox in the pair zone", func() bool {
		kb, ok, err := phone.ReadKeybox(pair)
		if err != nil {
			t.Fatal(err)
		}
		awaiting = kb
		return ok && kb.Grant.ConfirmNonce != nil
	})
	code, err := phone.SAS(*awaiting.Grant.ConfirmNonce)
	if err != nil {
		t.Fatal(err)
	}
	if code != sas.Code {
		t.Fatal("the phone's code differs from the hub's")
	}
	if err := c.Send(ControlRequest{Op: OpConfirm, Device: phone.ID().String(), Confirm: true}); err != nil {
		t.Fatal(err)
	}
	if linked := next(link.EventLinked); linked.DeviceID != phone.ID().String() {
		t.Fatalf("linked: %+v", linked)
	}
	eventually(t, 10*time.Second, "the keys in the pair zone", func() bool {
		kb, ok, err := phone.ReadKeybox(pair)
		if err != nil {
			t.Fatal(err)
		}
		return ok && kb.Keys != nil
	})

	for want := uint64(1); want <= 2; want++ {
		seq, err := phone.Act("probe")
		if err != nil {
			t.Fatal(err)
		}
		if seq != want {
			t.Fatalf("action_seq %d, want %d", seq, want)
		}
	}
	eventually(t, 15*time.Second, "applied echoes for a1..a2", func() bool {
		if _, err := phone.Sync(); err != nil {
			t.Fatal(err)
		}
		return phone.Echoes[1].Status == wire.StatusApplied && phone.Echoes[2].Status == wire.StatusApplied
	})

	data := transport.DataZone(status.RelayDeviceID)
	eventually(t, 15*time.Second, "the device_grant in the data zone", func() bool {
		kb, ok, err := phone.ReadKeybox(data)
		if err != nil {
			t.Fatal(err)
		}
		return ok && kb.Grant.Linked && kb.Grant.OrderedActions != nil && *kb.Grant.OrderedActions == 1 &&
			slices.Equal(kb.Grant.Transports, []string{wire.TransportRelay})
	})
	eventually(t, 5*time.Second, "one phone in the status", func() bool {
		s, err := ReadStatus(dir)
		return err == nil && s.Phones == 1
	})

	for i, f := range r.fake.Frames() {
		for _, marker := range []string{"Test Phone", "iPhone18,1", `"device_grant"`, `"probe"`} {
			if bytes.Contains(f, []byte(marker)) {
				t.Fatalf("frame %d carries %q in the clear", i, marker)
			}
		}
	}
	return endToEnd{url: qr.URL, nonce: lp.Nonce, code: sas.Code}
}
