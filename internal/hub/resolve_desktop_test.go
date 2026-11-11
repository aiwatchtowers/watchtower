package hub

import (
	"context"
	"crypto/ed25519"
	"database/sql"
	"encoding/json"
	"errors"
	"io/fs"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"testing/synctest"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/db/lockmetrics"
	"watchtower/internal/hub/adopt"
	"watchtower/internal/hub/hostkind"
	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/identity/identitytest"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/switcher"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/cloudkit"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/transport/relay/relayv1"
	"watchtower/internal/hub/wire"
	"watchtower/internal/logcanary"
	"watchtower/internal/policy/policytest"
	"watchtower/internal/sessionhost"
	"watchtower/internal/sessionstart"
)

// deskRig is a desktop host's Run under test: the relay and CloudKit over
// two fakes, the Swift hub's MobileHub/ in its own temp dir, the file
// identity store, and every transport build counted.
type deskRig struct {
	*rig
	ck        *memfake.Fake
	mobile    string
	ckDial    atomic.Int32
	v1        atomic.Bool  // the session-host probe answers as a v1 host
	bridgePID atomic.Int64 // the stand-in bridge last launched (realBridge)
	// realBridge: the production supervisor runs a stand-in bridge process;
	// otherwise (a bubble rig) a process-less fake whose state is bridgeUp.
	realBridge bool
	bridgeUp   atomic.Bool
	tick       chan struct{}
}

// fakeBridge is a bridge supervisor with no process: running from Run to
// its ctx's end.
type fakeBridge struct{ up *atomic.Bool }

func (b fakeBridge) Run(ctx context.Context) error {
	b.up.Store(true)
	<-ctx.Done()
	b.up.Store(false)
	return ctx.Err()
}

func (b fakeBridge) Running() bool { return b.up.Load() }

// bridgedFake is the CloudKit fake behind a bridge: a delete fails while no
// bridge process runs (as the real client's, whose socket the bridge serves).
type bridgedFake struct {
	*memfake.Fake
	alive func() bool
}

func (b bridgedFake) Delete(ctx context.Context, zone string, items []transport.DeleteItem) ([]transport.Outcome, error) {
	if !b.alive() {
		return nil, transport.ErrUnavailable
	}
	return b.Fake.Delete(ctx, zone, items)
}

// bridgeAlive: the bridge runs (a real rig's last stand-in bridge runs and
// was not reaped).
func (r *deskRig) bridgeAlive() bool {
	if !r.realBridge {
		return r.bridgeUp.Load()
	}
	pid := r.bridgePID.Load()
	return pid > 0 && syscall.Kill(int(pid), 0) == nil
}

// newDeskRig is a desktop-host rig for a synctest bubble: the control
// socket in memory, the bridge a process-less fake.
func newDeskRig(t *testing.T, dir string) *deskRig {
	t.Helper()
	mobile := filepath.Join(filepath.Dir(dir), "MobileHub")
	return &deskRig{rig: newBubbleRig(t, dir), ck: memfake.New(transport.KindCloudKit, nil), mobile: mobile, tick: make(chan struct{}, 1)}
}

// newRealDeskRig is newDeskRig over the real control socket and the
// production supervisor with a stand-in bridge process (no bubble).
func newRealDeskRig(t *testing.T, dir string) *deskRig {
	t.Helper()
	mobile := filepath.Join(filepath.Dir(dir), "MobileHub")
	return &deskRig{rig: newRig(t, dir), ck: memfake.New(transport.KindCloudKit, nil), mobile: mobile, tick: make(chan struct{}, 1), realBridge: true}
}

// cycles runs daemon cycles through the hub's loop, whichever loop it is in
// (the desktop gate, the lock wait or the reconcile loop): r.tick holds one,
// so the n+1th send returns once n were taken, so n-1 cycles have finished.
// A bubble rig then settles, so all n have.
func (r *deskRig) cycles(n int) {
	for range n + 1 {
		r.tick <- struct{}{}
	}
	if !r.realBridge {
		synctest.Wait()
	}
}

func (r *deskRig) options() Options {
	o := r.rig.options()
	o.Mode, o.Host = ModeLive, hostkind.Desktop
	o.RelayOrigin = "https://relay.example.com"
	o.RecordingsDir = filepath.Join(filepath.Dir(r.dir), "recordings")
	o.CycleTick = r.tick
	o.Desktop = &Desktop{
		MobileHubDir: r.mobile,
		newCloudKit: func(cloudkit.Config) transport.Transport {
			r.ckDial.Add(1)
			return bridgedFake{Fake: r.ck, alive: r.bridgeAlive}
		},
		launch: func(context.Context) (*os.Process, error) {
			p, err := startStub(r.t, "sleep 60")
			if err == nil {
				r.bridgePID.Store(int64(p.Pid))
			}
			return p, err
		},
		hostCheck: func(context.Context) error {
			if r.v1.Load() {
				return sessionhost.ErrHostV1
			}
			return nil
		},
	}
	if !r.realBridge {
		o.Desktop.supervise = func(cloudkit.Config) bridgeRunner { return fakeBridge{&r.bridgeUp} }
	}
	return o
}

// writeSwiftState puts a Swift hub sidecar (opaque bytes: it is never
// opened) into MobileHub/.
func (r *deskRig) writeSwiftState() {
	r.t.Helper()
	if err := os.MkdirAll(r.mobile, 0o700); err != nil {
		r.t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(r.mobile, state.FileName), []byte("swift hub state"), 0o600); err != nil {
		r.t.Fatal(err)
	}
}

// adoptedIdentity writes the identity a key hand-over would have adopted
// into the file store and records the store, as Task 16 does.
func adoptedIdentity(t *testing.T, dir string) identity.Identity {
	t.Helper()
	id, err := identity.New()
	if err != nil {
		t.Fatal(err)
	}
	if err := (identity.FileStore{Path: filepath.Join(dir, identity.FileName)}).Save(id); err != nil {
		t.Fatal(err)
	}
	setMeta(t, dir, identity.MetaIdentityStore, identity.IdentityStoreFile)
	return id
}

func relayIDOf(id identity.Identity) string {
	return identity.RelayDeviceID(id.RelayAuth.Public().(ed25519.PublicKey))
}

// lockHeld reports whether another holder has dir's hub lock.
func lockHeld(t *testing.T, dir string) bool {
	t.Helper()
	l, err := state.AcquireLock(dir)
	if errors.Is(err, state.ErrLocked) {
		return true
	}
	if err != nil {
		t.Fatal(err)
	}
	_ = l.Release()
	return false
}

// waitStatus waits for a report whose status meets cond (what names it).
func (r *deskRig) waitStatus(what string, cond func(Status) bool) {
	r.t.Helper()
	_ = what
	for {
		s, changed := r.rec.lastAndChanged()
		if cond(s) {
			return
		}
		<-changed
	}
}

// TestDesktopHostOffUntilAdopted: beside the Swift hub's state the hub stays
// off without the lock, without a sidecar and without a transport, through
// every adoption state (in progress, failed, adopted without the keys); it
// starts on the handed-over identity once the hand-over is adopted, and
// never makes one of its own.
func TestDesktopHostOffUntilAdopted(t *testing.T) {
	bubble(t, func(t *testing.T) {
		policytest.Set(t, nil)
		r := newDeskRig(t, shortDir(t))
		r.writeSwiftState()
		before := listing(t, r.mobile)
		r.start(r.options())
		r.waitState(StateOff, ReasonAwaitingAdoption)
		r.cycles(3) // a few gate checks
		if _, err := os.Stat(filepath.Join(r.dir, state.FileName)); !errors.Is(err, fs.ErrNotExist) {
			t.Fatalf("a sidecar beside the Swift hub's state (stat: %v)", err)
		}
		if lockHeld(t, r.dir) {
			t.Fatal("the hub lock is held while the adoption waits (the adoption needs it)")
		}
		if r.opens.Load() != 0 || r.dials.Load() != 0 || r.ckDial.Load() != 0 {
			t.Fatalf("opened %d, relay %d, cloudkit %d before the adoption", r.opens.Load(), r.dials.Load(), r.ckDial.Load())
		}
		if after := listing(t, r.mobile); !mapsEqual(before, after) {
			t.Fatalf("MobileHub/ changed:\n%v\n%v", before, after)
		}

		// The adoption moved the Swift state in and stopped mid-way. Its Go
		// sidecar is written while the Swift one is still there (the gate holds
		// at every intermediate state: a real adoption renames a finished copy
		// in), then the Swift one goes.
		setMeta(t, r.dir, adopt.MetaAdoptStep, string(adopt.StepSettings), state.MetaEnabled, "1")
		if err := os.Remove(filepath.Join(r.mobile, state.FileName)); err != nil {
			t.Fatal(err)
		}
		r.waitStatus("in progress", func(s Status) bool {
			return s.Reason == ReasonAwaitingAdoption && s.Adoption == AdoptionInProgress
		})
		setMeta(t, r.dir, adopt.MetaAdoptError, adopt.ClassSwiftBusy)
		r.waitStatus("failed", func(s Status) bool {
			return s.State == StateOff && s.Reason == ReasonAdoptionFailed && s.Adoption == AdoptionFailed
		})
		// Adopted, the keys only staged: still off.
		id := adoptedIdentity(t, r.dir)
		setMeta(t, r.dir, adopt.MetaAdoptError, "", adopt.MetaAdoptStep, string(adopt.StepDone),
			adopt.MetaAdoptedAt, "1800000000", adopt.MetaIdentity, adopt.IdentityStaged)
		r.waitStatus("keys staged", func(s Status) bool { return s.Reason == ReasonAwaitingAdoption })
		r.cycles(3)
		if r.opens.Load() != 0 || r.dials.Load() != 0 || r.ckDial.Load() != 0 {
			t.Fatal("the hub started before the keys were adopted")
		}

		setMeta(t, r.dir, adopt.MetaIdentity, adopt.IdentityAdopted)
		r.waitState(StateRunning, "")
		s := r.rec.last()
		if s.RelayDeviceID != relayIDOf(id) {
			t.Fatalf("the hub runs on identity %s, not the adopted one", s.RelayDeviceID)
		}
		if s.Adoption != AdoptionDone || s.Identity != identity.IdentityStoreFile || s.Transport != string(transport.KindCloudKit) {
			t.Fatalf("status %+v", s)
		}
	})
}

// TestDesktopHostNeverMakesAnIdentityForAnAdoptedHub: an adopted sidecar
// whose identity is missing from its store fails to start; no new identity
// (and so no new hub_id) is made.
func TestDesktopHostNeverMakesAnIdentityForAnAdoptedHub(t *testing.T) {
	bubble(t, func(t *testing.T) {
		policytest.Set(t, nil)
		r := newDeskRig(t, shortDir(t))
		setMeta(t, r.dir, state.MetaEnabled, "1", adopt.MetaAdoptStep, string(adopt.StepDone),
			adopt.MetaAdoptedAt, "1800000000", adopt.MetaIdentity, adopt.IdentityAdopted,
			identity.MetaIdentityStore, identity.IdentityStoreFile)
		r.start(r.options())
		r.waitState(StateStarting, ReasonStartFailed)
		if _, err := os.Stat(filepath.Join(r.dir, identity.FileName)); !errors.Is(err, fs.ErrNotExist) {
			t.Fatalf("an identity was made for an adopted hub (stat: %v)", err)
		}
	})
}

// TestResolveIgnoresALaterMobileHub is Review Focus 2: a MobileHub/ that
// appears after the adoption (adopted_at set) never holds the hub off and is
// never read, changed or imported; the one line is logged once.
func TestResolveIgnoresALaterMobileHub(t *testing.T) {
	bubble(t, func(t *testing.T) {
		sink := logcanary.Capture(t)
		live := liveHome(t)
		home, _ := os.UserHomeDir()
		support, err := config.AppSupportDir()
		if err != nil {
			t.Fatal(err)
		}
		setMeta(t, live, state.MetaEnabled, "1")
		adoptedIdentity(t, live)
		setMeta(t, live, adopt.MetaAdoptStep, string(adopt.StepDone), adopt.MetaAdoptedAt, "1800000000",
			adopt.MetaIdentity, adopt.IdentityConfirmed)
		mobile := filepath.Join(support, "MobileHub")
		if err := os.MkdirAll(mobile, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(mobile, state.FileName), []byte("a pre-guard app's hub"), 0o600); err != nil {
			t.Fatal(err)
		}
		beforeSwift := listing(t, mobile)
		hubID, _ := readMeta(t, live, state.MetaHubID)

		o, err := Resolve(&config.Config{}, nil, desktopProbe(home, support))
		if err != nil || o.Mode != ModeLive || o.Dir != live || o.Desktop == nil || o.Desktop.MobileHubDir != mobile {
			t.Fatalf("Resolve: %+v, %v", o, err)
		}
		if reason, _, later, err := desktopGate(o.Dir, o.Desktop.MobileHubDir); reason != "" || !later || err != nil {
			t.Fatalf("gate: %q later=%v %v", reason, later, err)
		}

		// The hub runs beside it (over the fakes).
		r := newDeskRig(t, live)
		r.mobile = mobile
		r.start(r.options())
		r.waitState(StateRunning, "")
		if err := r.stop(); err != nil {
			t.Fatal(err)
		}
		if after := listing(t, mobile); !mapsEqual(beforeSwift, after) {
			t.Fatalf("the later MobileHub/ changed:\n%v\n%v", beforeSwift, after)
		}
		if b, _ := os.ReadFile(filepath.Join(mobile, state.FileName)); string(b) != "a pre-guard app's hub" {
			t.Fatal("the later MobileHub/ sidecar was rewritten")
		}
		if after, _ := readMeta(t, live, state.MetaHubID); hubID != "" && after != hubID {
			t.Fatalf("hub_id changed: %q → %q", hubID, after)
		}
		if n := strings.Count(sink.String(), adopt.LaterMobileHubLog); n != 1 {
			t.Fatalf("the later MobileHub line logged %d times:\n%s", n, sink.String())
		}
	})
}

// TestDesktopHostStaysOffBesideSwiftStateWhateverTheSidecarSays: while
// MobileHub/ holds a Swift sidecar and the Go one has no adopted_at, no Go
// hub runs — not on a sidecar that never adopted with enabled = 1 written by
// hand (a leftover headless run), and a running one stops and lets the lock
// go when such a Swift sidecar shows up.
func TestDesktopHostStaysOffBesideSwiftStateWhateverTheSidecarSays(t *testing.T) {
	bubble(t, func(t *testing.T) {
		policytest.Set(t, nil)
		r := newDeskRig(t, shortDir(t))
		setMeta(t, r.dir, state.MetaEnabled, "1")
		r.writeSwiftState()
		r.start(r.options())
		r.waitState(StateOff, ReasonSwiftBesideGo)
		r.cycles(3)
		if r.opens.Load() != 0 || r.dials.Load() != 0 || r.ckDial.Load() != 0 || lockHeld(t, r.dir) {
			t.Fatal("a hub (or its lock) beside the Swift hub's state")
		}
		if err := r.stop(); err != nil {
			t.Fatal(err)
		}

		// Running without Swift state; then one appears.
		if err := os.Remove(filepath.Join(r.mobile, state.FileName)); err != nil {
			t.Fatal(err)
		}
		r.start(r.options())
		r.waitState(StateRunning, "")
		r.writeSwiftState()
		r.waitState(StateOff, ReasonSwiftBesideGo)
		eventually(t, "the lock let go", func() bool { return !lockHeld(t, r.dir) })
	})
}

// TestGoHubFirstThenSwiftSidecarIsSwiftBesideGo pins owner ask #949's
// state (pending): a Go hub that ran first (never adopted) with a Swift
// sidecar appearing beside it is held off with its own reason,
// swift_beside_go, which CLI writes respect; and the adoption still refuses
// that Swift sidecar as a later MobileHub.
func TestGoHubFirstThenSwiftSidecarIsSwiftBesideGo(t *testing.T) {
	live := liveHome(t)
	support, err := config.AppSupportDir()
	if err != nil {
		t.Fatal(err)
	}
	setMeta(t, live, state.MetaEnabled, "1")
	mobile := filepath.Join(support, "MobileHub")
	if err := os.MkdirAll(mobile, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(mobile, state.FileName), []byte("swift"), 0o600); err != nil {
		t.Fatal(err)
	}
	if reason, adoption, later, err := desktopGate(live, mobile); reason != ReasonSwiftBesideGo || adoption != AdoptionNone || later || err != nil {
		t.Fatalf("gate: %q %q later=%v %v", reason, adoption, later, err)
	}
	if r := DesktopOffReason(live, mobile); r != ReasonSwiftBesideGo {
		t.Fatalf("off reason %q", r)
	}
	if waiting, err := AwaitingAdoption(live, mobile); !waiting || err != nil {
		t.Fatalf("CLI writes allowed: %v %v", waiting, err)
	}
	if r := AdoptionWait(Options{Dir: live, Desktop: &Desktop{MobileHubDir: mobile}}); r != ReasonSwiftBesideGo {
		t.Fatalf("daemon line reason %q", r)
	}
	res, err := adopt.Run(context.Background(), mobile, live, filepath.Join(support, "recordings"), adopt.Settings{}, nil)
	if !errors.Is(err, adopt.ErrLaterMobileHub) || res.Error != adopt.ClassLaterMobileHub {
		t.Fatalf("adopt.Run: %+v %v", res, err)
	}
	if b, _ := os.ReadFile(filepath.Join(mobile, state.FileName)); string(b) != "swift" {
		t.Fatal("the Swift sidecar was touched")
	}
}

// TestResolve_DesktopHostNeverStartsBeforeAdoption (Phase 2's
// TestResolve_DesktopHostNeverStartsALiveHub, renamed 2026-11-02 with the
// same meaning: no live hub beside the Swift hub's state): with
// hub_meta.enabled = 1 written by hand into a Go sidecar that never adopted,
// Resolve changes nothing under the live dir or MobileHub/, and the gate
// holds the hub off while the Swift state is there (swift_beside_go: that
// Go sidecar never adopted; a Swift state with no Go sidecar is
// awaiting_adoption, TestDesktopHostOffUntilAdopted).
func TestResolve_DesktopHostNeverStartsBeforeAdoption(t *testing.T) {
	dir := liveHome(t)
	DefaultRelayOrigin = "https://relay.example.com"
	t.Cleanup(func() { DefaultRelayOrigin = "" })
	setMeta(t, dir, state.MetaEnabled, "1")
	home, _ := os.UserHomeDir()
	support, err := config.AppSupportDir() // a darwin path on a Mac, <data root>/.support on Linux
	if err != nil {
		t.Fatal(err)
	}
	swift := filepath.Join(support, "MobileHub")
	if err := os.MkdirAll(swift, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(swift, state.FileName), []byte("swift"), 0o600); err != nil {
		t.Fatal(err)
	}
	backdate(t, dir, swift) // a write by Resolve would show in the mtimes
	before, beforeSwift := listing(t, dir), listing(t, swift)

	resolved := map[string]Options{}
	probes := map[string]hostkind.Probe{
		"app bundle": desktopProbe(home, support),
		"MobileHub/": {GOOS: "darwin", Home: home, AppSupport: support, Stat: os.Stat, ReadFile: os.ReadFile},
	}
	for name, p := range probes {
		o, err := Resolve(&config.Config{}, nil, p)
		if err != nil || o.Mode != ModeLive || o.Host != hostkind.Desktop || o.Desktop == nil || o.RelayOnlyRules {
			t.Fatalf("%s: %+v err %v", name, o, err)
		}
		if d, mode, kind, err := Dir(p); err != nil || d != dir || mode != ModeLive || kind != hostkind.Desktop {
			t.Fatalf("%s: Dir %q %q %q %v", name, d, mode, kind, err)
		}
		resolved[name] = o
	}
	if after := listing(t, dir); !mapsEqual(before, after) {
		t.Fatalf("Resolve changed the live dir:\n%v\n%v", before, after)
	}
	// The gate (a read-only read of the hand-made sidecar) holds it off.
	for name, o := range resolved {
		if reason, _, _, err := desktopGate(o.Dir, o.Desktop.MobileHubDir); reason != ReasonSwiftBesideGo || err != nil {
			t.Fatalf("%s: gate %q %v", name, reason, err)
		}
		if r := DesktopOffReason(o.Dir, o.Desktop.MobileHubDir); r != ReasonSwiftBesideGo {
			t.Fatalf("%s: off reason %q", name, r)
		}
		if waiting, err := AwaitingAdoption(o.Dir, o.Desktop.MobileHubDir); !waiting || err != nil {
			t.Fatalf("%s: AwaitingAdoption %v %v", name, waiting, err)
		}
	}
	if v, _ := readMetaRO(t, dir, state.MetaEnabled); v != "1" {
		t.Fatalf("the hand-written switch reads %q", v)
	}
	if after := listing(t, swift); !mapsEqual(beforeSwift, after) {
		t.Fatalf("MobileHub/ changed:\n%v\n%v", beforeSwift, after)
	}
}

// TestFreshDesktopHostStartsWhenEnabled: a Mac that never ran the Swift hub
// is off (disabled, no sidecar made) until the owner turns Mobile on; then
// the hub starts with a new hub_id and its identity in the store it
// recorded.
func TestFreshDesktopHostStartsWhenEnabled(t *testing.T) {
	bubble(t, func(t *testing.T) {
		policytest.Set(t, nil)
		r := newDeskRig(t, shortDir(t))
		r.start(r.options())
		r.waitState(StateOff, ReasonDisabled)
		if _, err := os.Stat(filepath.Join(r.dir, state.FileName)); !errors.Is(err, fs.ErrNotExist) {
			t.Fatalf("a sidecar before Mobile was turned on (stat: %v)", err)
		}
		setMeta(t, r.dir, state.MetaEnabled, "1") // `hub enable`, written directly
		r.waitState(StateRunning, "")
		s := r.rec.last()
		if s.HubID == "" || s.Adoption != AdoptionNone || s.Identity != identity.IdentityStoreFile {
			t.Fatalf("status %+v", s)
		}
		if err := r.stop(); err != nil {
			t.Fatal(err)
		}
		if v, _ := readMeta(t, r.dir, identity.MetaIdentityStore); v != identity.IdentityStoreFile {
			t.Fatalf("recorded identity store %q", v)
		}
		id, err := (identity.FileStore{Path: filepath.Join(r.dir, identity.FileName)}).Load()
		if err != nil {
			t.Fatal(err)
		}
		if relayIDOf(id) != s.RelayDeviceID {
			t.Fatal("the hub ran on another identity than the one it stored")
		}
	})
}

// TestDaemonWaitsWhileAV1HostAnswers: while a v1 session host answers the
// hub stays off (session_host_v1) and builds nothing (so no session host of
// its own is started); a v2 host there starts it within one check.
func TestDaemonWaitsWhileAV1HostAnswers(t *testing.T) {
	bubble(t, func(t *testing.T) {
		policytest.Set(t, nil)
		r := newDeskRig(t, shortDir(t))
		setMeta(t, r.dir, state.MetaEnabled, "1")
		r.v1.Store(true)
		r.start(r.options())
		r.waitState(StateOff, ReasonSessionHostV1)
		r.cycles(3)
		if r.dials.Load() != 0 || r.ckDial.Load() != 0 {
			t.Fatal("the hub started beside a v1 session host")
		}
		r.v1.Store(false)
		r.tick <- struct{}{} // the next daemon cycle probes again
		r.waitState(StateRunning, "")
	})
}

// TestDesktopHostV1ProbeOverTheSocket: the production probe says v1 only
// for a host that refuses a v2 hello; nothing listening is no reason to
// wait.
func TestDesktopHostV1ProbeOverTheSocket(t *testing.T) {
	s := &supervisor{o: Options{Desktop: &Desktop{}, SessionStart: sessionstart.Deps{Socket: filepath.Join(shortDir(t), "none.sock")}}}
	if s.v1HostAnswers(context.Background()) {
		t.Fatal("a missing socket read as a v1 host")
	}
	s.o.SessionStart.Socket = ""
	if s.v1HostAnswers(context.Background()) {
		t.Fatal("no socket read as a v1 host")
	}

	// A v1 host over the real sessionhost.Dial: the hub waits, and no
	// session host of its own is spawned.
	policytest.Set(t, nil)
	r := newRealDeskRig(t, shortDir(t))
	setMeta(t, r.dir, state.MetaEnabled, "1")
	sock, hellos := fakeV1Host(t, filepath.Join(filepath.Dir(r.dir), "sh.sock"))
	marker := filepath.Join(filepath.Dir(r.dir), "spawned")
	exe := filepath.Join(filepath.Dir(r.dir), "watchtower-stub")
	if err := os.WriteFile(exe, []byte("#!/bin/sh\ntouch '"+marker+"'\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	o := r.options()
	o.Desktop.hostCheck = nil
	o.SessionStart = sessionstart.Deps{Socket: sock, CLIPath: exe}
	r.start(o)
	r.waitState(StateOff, ReasonSessionHostV1)
	r.cycles(3)
	if hellos.Load() == 0 {
		t.Fatal("the v1 host was never asked")
	}
	if _, err := os.Stat(marker); !errors.Is(err, fs.ErrNotExist) || r.dials.Load() != 0 || r.ckDial.Load() != 0 {
		t.Fatalf("a session host or a hub started beside a v1 host (stat: %v)", err)
	}
}

// fakeV1Host serves a v1 session host on path (HelloOK with version 1) and
// counts the hellos.
func fakeV1Host(t *testing.T, path string) (string, *atomic.Int32) {
	t.Helper()
	l, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = l.Close() })
	var hellos atomic.Int32
	ok, _ := json.Marshal(sessionhost.HelloMsg{Version: 1, Pid: 1})
	go func() {
		for {
			nc, err := l.Accept()
			if err != nil {
				return
			}
			go func() {
				defer func() { _ = nc.Close() }()
				if _, _, err := sessionhost.ReadFrame(nc); err != nil {
					return
				}
				hellos.Add(1)
				_ = sessionhost.WriteFrame(nc, sessionhost.HelloOK, ok)
				_, _, _ = sessionhost.ReadFrame(nc) // until the client hangs up
			}()
		}
	}()
	return path, &hellos
}

// TestDesktopHostAnnouncesBothTransports: a desktop host runs and announces
// CloudKit and the relay (CloudKit only without a relay origin); a headless
// host announces the relay alone.
func TestDesktopHostAnnouncesBothTransports(t *testing.T) {
	bubble(t, func(t *testing.T) {
		live := liveHome(t)
		home, _ := os.UserHomeDir()
		support, _ := config.AppSupportDir()
		root := t.TempDir()
		p := desktopProbe(home, support)
		p.Stat = func(path string) (os.FileInfo, error) { return os.Stat(filepath.Join(root, path)) }
		bin := filepath.Join(root, "/Applications/Watchtower.app", BridgeExecutable)
		if err := os.MkdirAll(filepath.Dir(bin), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(bin, []byte("#!/bin/sh\n"), 0o755); err != nil {
			t.Fatal(err)
		}
		pub := ed25519.PublicKey(make([]byte, ed25519.PublicKeySize))

		o, err := Resolve(&config.Config{}, nil, p)
		if err != nil || o.RelayOrigin != "" || !slices.Equal(o.Transports, []string{wire.TransportCloudKit}) {
			t.Fatalf("no origin: %+v %v", o, err)
		}
		t.Setenv(EnvRelayOrigin, "https://relay.example.com")
		o, err = Resolve(&config.Config{}, nil, p)
		both := []string{wire.TransportCloudKit, wire.TransportRelay}
		if err != nil || o.Dir != live || o.RelayOrigin != "https://relay.example.com" || !slices.Equal(o.Transports, both) {
			t.Fatalf("with an origin: %+v %v", o, err)
		}
		if got := hostInfo(o, "acme", pub).Transports; !slices.Equal(got, both) {
			t.Fatalf("announced %v", got)
		}
		if got := hostInfo(Options{}, "acme", pub).Transports; !slices.Equal(got, []string{wire.TransportRelay}) {
			t.Fatalf("headless announces %v", got)
		}

		// Running, the hub has both transports behind the switch: CloudKit
		// active on a fresh hub, the relay polled as the other.
		policytest.Set(t, nil)
		r := newDeskRig(t, shortDir(t))
		setMeta(t, r.dir, state.MetaEnabled, "1")
		r.start(r.options())
		r.waitState(StateRunning, "")
		if r.dials.Load() != 1 || r.ckDial.Load() != 1 {
			t.Fatalf("relay built %d, cloudkit %d", r.dials.Load(), r.ckDial.Load())
		}
		if s := r.rec.last(); s.Transport != string(transport.KindCloudKit) {
			t.Fatalf("active transport %q", s.Transport)
		}
		if v, _ := readMetaRO(t, r.dir, switcher.MetaTransport); v != string(transport.KindCloudKit) {
			t.Fatalf("hub_meta.transport %q", v)
		}
	})
}

// TestRecordingsDirIsAppSupport: a desktop host keeps the phones' recordings
// in <app support>/recordings, the folder Desktop's transcriber uses.
func TestRecordingsDirIsAppSupport(t *testing.T) {
	liveHome(t)
	home, _ := os.UserHomeDir()
	support, err := config.AppSupportDir()
	if err != nil {
		t.Fatal(err)
	}
	o, err := Resolve(&config.Config{}, nil, desktopProbe(home, support))
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(support, "recordings"); o.RecordingsDir != want {
		t.Fatalf("recordings in %q, want %q", o.RecordingsDir, want)
	}
}

// TestBridgeUnavailableSaysSoInStatus: a build without the bridge offers
// no CloudKit — it runs relay-only with a relay origin, announcing the relay
// alone, and is off (bridge_unavailable) with none — and says unavailable
// whether the hub runs or not; with a bridge, the status follows it and the
// bridge goes with the hub.
func TestBridgeUnavailableSaysSoInStatus(t *testing.T) {
	policytest.Set(t, nil)
	r := newRealDeskRig(t, shortDir(t))
	setMeta(t, r.dir, state.MetaEnabled, "1")
	var h *hubRuntime
	o := r.options()
	o.Desktop.launch = nil
	o.started = func(rt *hubRuntime) { h = rt }
	r.start(o)
	r.waitStatus("relay-only", func(s Status) bool {
		return s.State == StateRunning && s.Bridge == BridgeUnavailable && s.Transport == string(transport.KindRelay)
	})
	pub := ed25519.PublicKey(make([]byte, ed25519.PublicKeySize))
	if got := hostInfo(o, "acme", pub).Transports; !slices.Equal(got, []string{wire.TransportRelay}) || h.ck != nil || r.ckDial.Load() != 0 {
		t.Fatalf("CloudKit offered without a bridge: %v", got)
	}
	if err := r.stop(); err != nil {
		t.Fatal(err)
	}

	o.RelayOrigin = ""
	r.start(o)
	r.waitStatus("no transport", func(s Status) bool {
		return s.State == StateOff && s.Reason == ReasonBridgeUnavailable && s.Bridge == BridgeUnavailable
	})
	if err := r.stop(); err != nil {
		t.Fatal(err)
	}

	r.start(r.options())
	r.waitStatus("bridge running", func(s Status) bool { return s.State == StateRunning && s.Bridge == BridgeRunning })
	pid := r.bridgePID.Load()
	if err := r.stop(); err != nil {
		t.Fatal(err)
	}
	if syscall.Kill(int(pid), 0) == nil {
		t.Fatalf("the bridge %d outlived the hub", pid)
	}
}

// TestDesktopHostWiresTheRelayBeforeTheSwitch: the relay's account reader,
// the switcher's Paying and the zone subscriptions see the relay while the
// runtime is built (before the switcher exists).
func TestDesktopHostWiresTheRelayBeforeTheSwitch(t *testing.T) {
	bubble(t, func(t *testing.T) {
		policytest.Set(t, nil)
		r := newDeskRig(t, shortDir(t))
		setMeta(t, r.dir, state.MetaEnabled, "1")
		phone := linkPhoneDirectly(t, r.dir)
		pdev := phone.Device()
		r.fake.SetAccountState(&relayv1.AccountState{Phones: []*relayv1.SlotHolder{{PhoneDeviceId: pdev.RelayDeviceID, Paying: true}}})
		w := &watchFake{Fake: r.fake}
		var h *hubRuntime
		o := r.options()
		o.newTransport = func(context.Context, identity.Identity, *state.Store, []string) (transport.Transport, error) {
			r.dials.Add(1)
			return w, nil
		}
		o.started = func(rt *hubRuntime) { h = rt }
		r.start(o)
		r.waitState(StateRunning, "")
		if h.acct == nil {
			t.Fatal("no account reader on the relay")
		}
		paying, err := h.payingByDevice(context.Background())
		if err != nil || !paying[pdev.ID] {
			t.Fatalf("Paying by device id: %v %v", paying, err)
		}
		mailbox := transport.MailboxZone(r.rec.last().RelayDeviceID, pdev.RelayDeviceID)
		eventually(t, "the phone's mailbox subscribed", func() bool { return w.watched(mailbox) })
	})
}

// watchFake is the relay fake with zone subscriptions (zoneWatcher).
type watchFake struct {
	*memfake.Fake
	mu    sync.Mutex
	zones []string
}

func (w *watchFake) WatchZone(_ context.Context, zone string) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.zones = append(w.zones, zone)
	return nil
}

func (w *watchFake) watched(zone string) bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	return slices.Contains(w.zones, zone)
}

// TestDesktopGateKeepsTheLockMetricsSink: the gate's read-only sidecar open
// leaves the daemon's dblock.jsonl beside its database.
func TestDesktopGateKeepsTheLockMetricsSink(t *testing.T) {
	bubble(t, func(t *testing.T) {
		policytest.Set(t, nil)
		r := newDeskRig(t, shortDir(t))
		ws := filepath.Join(filepath.Dir(r.dir), "ws")
		if err := os.MkdirAll(ws, 0o700); err != nil {
			t.Fatal(err)
		}
		d, err := db.Open(filepath.Join(ws, "watchtower.db"))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = d.Close() })
		// A Go sidecar the gate opens on every check, beside Swift state.
		setMeta(t, r.dir, state.MetaEnabled, "1")
		r.writeSwiftState()
		o := r.options()
		o.DB = d
		r.start(o)
		r.waitState(StateOff, ReasonSwiftBesideGo)
		r.cycles(3) // a few gate reads
		lockmetrics.Record(lockmetrics.Event{Kind: lockmetrics.KindBusy})
		if _, err := os.Stat(filepath.Join(ws, lockmetrics.FileName)); err != nil {
			t.Fatalf("the event is not beside the database: %v", err)
		}
		if _, err := os.Stat(filepath.Join(r.dir, lockmetrics.FileName)); !errors.Is(err, fs.ErrNotExist) {
			t.Fatalf("the sink moved to the hub dir (stat: %v)", err)
		}
	})
}

// linkCloudKitPhone links a phone with no relay id (a CloudKit link), so the
// hub's default transport is CloudKit.
func linkCloudKitPhone(t *testing.T, dir string) {
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
	d := p.Device()
	d.RelayDeviceID = ""
	if err := st.WithTx(context.Background(), func(tx *sql.Tx) error { return state.LinkDevice(tx, d) }); err != nil {
		t.Fatal(err)
	}
}

// TestPolicy03_DesktopHostWipesWhileTheBridgeRuns: MobileSync = off deletes
// what the hub published on CloudKit before the bridge stops (a delete
// through a stopped bridge would fail and leave the records).
func TestPolicy03_DesktopHostWipesWhileTheBridgeRuns(t *testing.T) {
	policytest.Set(t, map[string]any{"MobileSync": "allowed"})
	r := newRealDeskRig(t, shortDir(t))
	setMeta(t, r.dir, state.MetaEnabled, "1")
	linkCloudKitPhone(t, r.dir)
	r.start(r.options())
	r.waitState(StateRunning, "")
	s := r.rec.last()
	if s.Transport != string(transport.KindCloudKit) {
		t.Fatalf("active %q", s.Transport)
	}
	data := transport.DataZone(s.RelayDeviceID)
	eventually(t, "the heartbeat published on CloudKit", func() bool {
		return slices.Contains(liveRecords(t, r.ck, data), "heartbeat")
	})
	policytest.Set(t, map[string]any{"MobileSync": "off"})
	r.waitState(StateOff, ReasonPolicyOff)
	if got := liveRecords(t, r.ck, data); len(got) != 0 {
		t.Fatalf("CloudKit still holds %v after the policy turned off", got)
	}
	if r.bridgeAlive() {
		t.Fatal("the bridge outlived the stopped hub")
	}
}

// TestPolicy03_StoppedDesktopHostWipesWithTheRecordedStore: a desktop host
// whose identity is in the Keychain store, stopped with records published,
// wipes them under MobileSync = off with that identity, through a bridge
// started for the wipe and stopped after it.
func TestPolicy03_StoppedDesktopHostWipesWithTheRecordedStore(t *testing.T) {
	policytest.Set(t, map[string]any{"MobileSync": "allowed"})
	r := newRealDeskRig(t, shortDir(t))
	setMeta(t, r.dir, state.MetaEnabled, "1")
	linkCloudKitPhone(t, r.dir)
	kc, _ := identitytest.NewKeychainStore(identity.KeychainService)
	keychain := func(o Options) Options {
		o.Desktop.identityStore = func(st *state.Store, _ string) (identity.Staging, error) {
			if _, ok, err := st.Meta(identity.MetaIdentityStore); err != nil || !ok {
				if err := st.SetMeta(identity.MetaIdentityStore, identity.IdentityStoreKeychain); err != nil {
					return nil, err
				}
			}
			return kc, nil
		}
		return o
	}
	r.start(keychain(r.options()))
	r.waitState(StateRunning, "")
	s := r.rec.last()
	if s.Identity != identity.IdentityStoreKeychain {
		t.Fatalf("identity store %q", s.Identity)
	}
	data := transport.DataZone(s.RelayDeviceID)
	eventually(t, "the heartbeat published on CloudKit", func() bool {
		return slices.Contains(liveRecords(t, r.ck, data), "heartbeat")
	})
	if err := r.stop(); err != nil { // stopped with its records in place
		t.Fatal(err)
	}
	if got := liveRecords(t, r.ck, data); len(got) == 0 {
		t.Fatal("a plain stop deleted the records")
	}

	policytest.Set(t, map[string]any{"MobileSync": "off"})
	r.start(keychain(r.options()))
	r.waitState(StateOff, ReasonPolicyOff)
	eventually(t, "the stopped hub's wipe", func() bool { return len(liveRecords(t, r.ck, data)) == 0 })
	eventually(t, "the wipe's bridge stopped", func() bool { return !r.bridgeAlive() })
	if _, err := os.Stat(filepath.Join(r.dir, identity.FileName)); !errors.Is(err, fs.ErrNotExist) {
		t.Fatal("an identity file was made beside the Keychain store")
	}
}

// TestFindBridge: the helper inside the running app's bundle first, then
// the installed app's; none (a dev build) is "".
func TestFindBridge(t *testing.T) {
	root := t.TempDir()
	p := hostkind.Probe{GOOS: "darwin", Home: "/Users/owner", Stat: func(path string) (os.FileInfo, error) {
		return os.Stat(filepath.Join(root, path))
	}}
	put := func(app string) string {
		bin := filepath.Join(app, BridgeExecutable)
		if err := os.MkdirAll(filepath.Join(root, filepath.Dir(bin)), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, bin), []byte("#!/bin/sh\n"), 0o755); err != nil {
			t.Fatal(err)
		}
		return bin
	}
	exe := func(path string) func() (string, error) { return func() (string, error) { return path, nil } }
	if got := findBridge(p, exe("/usr/local/bin/watchtower")); got != "" {
		t.Fatalf("no app: %q", got)
	}
	home := put("/Users/owner/Applications/Watchtower.app")
	if got := findBridge(p, exe("/usr/local/bin/watchtower")); got != home {
		t.Fatalf("~/Applications: %q", got)
	}
	system := put("/Applications/Watchtower.app")
	if got := findBridge(p, exe("/usr/local/bin/watchtower")); got != system {
		t.Fatalf("/Applications first: %q", got)
	}
	own := put("/Volumes/dev/Watchtower.app")
	if got := findBridge(p, exe("/Volumes/dev/Watchtower.app/Contents/MacOS/watchtower")); got != own {
		t.Fatalf("the running bundle first: %q", got)
	}
}

// TestPolicy03_OffStopsDesktopHostHubKeepsSetting is the desktop host's twin
// of TestPolicy03_OffStopsHubKeepsSetting (same meaning): MobileSync = off
// stops the running hub and deletes what it published from the active
// transport's data zone; the owner's switch is left as it was and turning it
// on is refused while off.
func TestPolicy03_OffStopsDesktopHostHubKeepsSetting(t *testing.T) {
	policytest.Set(t, map[string]any{"MobileSync": "allowed"})
	r := newRealDeskRig(t, shortDir(t))
	setMeta(t, r.dir, state.MetaEnabled, "1")
	linkPhoneDirectly(t, r.dir)
	r.start(r.options())
	r.waitState(StateRunning, "")
	// The phone came over the relay: a hub of relay links starts there.
	s := r.rec.last()
	active := r.fake
	if s.Transport == string(transport.KindCloudKit) {
		active = r.ck
	}
	data := transport.DataZone(s.RelayDeviceID)
	eventually(t, "the heartbeat published", func() bool {
		return slices.Contains(liveRecords(t, active, data), "heartbeat")
	})

	policytest.Set(t, map[string]any{"MobileSync": "off"})
	r.waitState(StateOff, ReasonPolicyOff)
	if got := liveRecords(t, active, data); len(got) != 0 {
		t.Fatalf("the data zone still holds %v after the policy turned off", got)
	}
	c, err := Dial(r.dir)
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
	if v, _ := readMeta(t, r.dir, state.MetaEnabled); v != "1" {
		t.Fatalf("the owner's switch was rewritten to %q", v)
	}
}

// readMetaRO reads one hub_meta value read-only (a hub may hold the lock).
func readMetaRO(t *testing.T, dir, key string) (string, bool) {
	t.Helper()
	st, err := state.OpenReadOnly(dir)
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

// backdate sets every mtime under roots an hour back, so a later write
// shows in a listing whatever the file system's time resolution.
func backdate(t *testing.T, roots ...string) {
	t.Helper()
	old := time.Now().Add(-time.Hour)
	for _, root := range roots {
		if err := filepath.WalkDir(root, func(path string, _ fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			return os.Chtimes(path, old, old) //nolint:gosec // G122: the test's own temp dirs
		}); err != nil {
			t.Fatal(err)
		}
	}
}

// startStub starts a stand-in bridge in its own process group, reaped at
// the test's end.
func startStub(t *testing.T, script string) (*os.Process, error) {
	cmd := exec.Command("/bin/sh", "-c", script)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	pid := cmd.Process.Pid
	t.Cleanup(func() { _ = syscall.Kill(-pid, syscall.SIGKILL) })
	return cmd.Process, nil
}
