package hub

import (
	"context"
	"crypto/ed25519"
	"errors"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/hub/adopt"
	"watchtower/internal/hub/hostkind"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/switcher"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/cloudkit"
	"watchtower/internal/hub/transport/memfake"
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
	ck     *memfake.Fake
	mobile string
	ckDial atomic.Int32
	v1     atomic.Bool // the session-host probe answers as a v1 host
}

func newDeskRig(t *testing.T, dir string) *deskRig {
	t.Helper()
	mobile := filepath.Join(filepath.Dir(dir), "MobileHub")
	return &deskRig{rig: newRig(t, dir), ck: memfake.New(transport.KindCloudKit, nil), mobile: mobile}
}

func (r *deskRig) options() Options {
	o := r.rig.options()
	o.Mode, o.Host = ModeLive, hostkind.Desktop
	o.RelayOrigin = "https://relay.example.com"
	o.Transports = []string{wire.TransportCloudKit, wire.TransportRelay}
	o.RecordingsDir = filepath.Join(filepath.Dir(r.dir), "recordings")
	o.Desktop = &Desktop{
		MobileHubDir: r.mobile,
		newCloudKit: func(cloudkit.Config) transport.Transport {
			r.ckDial.Add(1)
			return r.ck
		},
		hostCheck: func(context.Context) error {
			if r.v1.Load() {
				return sessionhost.ErrHostV1
			}
			return nil
		},
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

func (r *deskRig) waitStatus(what string, cond func(Status) bool) {
	r.t.Helper()
	eventually(r.t, 10*time.Second, what, func() bool { return cond(r.rec.last()) })
}

// TestDesktopHostOffUntilAdopted: beside the Swift hub's state the hub stays
// off without the lock, without a sidecar and without a transport, through
// every adoption state (in progress, failed, adopted without the keys); it
// starts on the handed-over identity once the hand-over is adopted, and
// never makes one of its own.
func TestDesktopHostOffUntilAdopted(t *testing.T) {
	policytest.Set(t, nil)
	r := newDeskRig(t, shortDir(t))
	r.writeSwiftState()
	before := listing(t, r.mobile)
	r.start(r.options())
	r.waitState(StateOff, ReasonAwaitingAdoption)
	time.Sleep(200 * time.Millisecond) // a few gate checks
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

	// The adoption moved the Swift state in and stopped mid-way.
	if err := os.Remove(filepath.Join(r.mobile, state.FileName)); err != nil {
		t.Fatal(err)
	}
	setMeta(t, r.dir, adopt.MetaAdoptStep, string(adopt.StepSettings), state.MetaEnabled, "1")
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
	time.Sleep(200 * time.Millisecond)
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
}

// TestDesktopHostNeverMakesAnIdentityForAnAdoptedHub: an adopted sidecar
// whose identity is missing from its store fails to start; no new identity
// (and so no new hub_id) is made.
func TestDesktopHostNeverMakesAnIdentityForAnAdoptedHub(t *testing.T) {
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
}

// TestResolveIgnoresALaterMobileHub is Review Focus 2: a MobileHub/ that
// appears after the adoption (or beside a Go hub of its own) never holds the
// hub off and is never read, changed or imported; the one line is logged
// once.
func TestResolveIgnoresALaterMobileHub(t *testing.T) {
	for _, adopted := range []bool{true, false} {
		name := "beside a Go hub of its own"
		if adopted {
			name = "after the adoption"
		}
		t.Run(name, func(t *testing.T) {
			sink := logcanary.Capture(t)
			live := liveHome(t)
			home, _ := os.UserHomeDir()
			support, err := config.AppSupportDir()
			if err != nil {
				t.Fatal(err)
			}
			setMeta(t, live, state.MetaEnabled, "1")
			if adopted {
				adoptedIdentity(t, live)
				setMeta(t, live, adopt.MetaAdoptStep, string(adopt.StepDone), adopt.MetaAdoptedAt, "1800000000",
					adopt.MetaIdentity, adopt.IdentityConfirmed)
			}
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
}

// TestResolve_DesktopHostNeverStartsBeforeAdoption (Phase 2's
// TestResolve_DesktopHostNeverStartsALiveHub, same meaning: no live hub
// beside the Swift hub's state): Resolve opens and creates nothing — not
// under the live dir, not in MobileHub/ — even with hub_meta.enabled = 1
// written by hand, and the gate holds the hub off while the Swift state
// waits for its adoption.
func TestResolve_DesktopHostNeverStartsBeforeAdoption(t *testing.T) {
	dir := liveHome(t)
	DefaultRelayOrigin = "https://relay.example.com"
	t.Cleanup(func() { DefaultRelayOrigin = "" })
	setMeta(t, dir, state.MetaEnabled, "1")
	home, _ := os.UserHomeDir()
	support := filepath.Join(home, "Library", "Application Support", "Watchtower")
	swift := filepath.Join(support, "MobileHub")
	if err := os.MkdirAll(swift, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(swift, state.FileName), []byte("swift"), 0o600); err != nil {
		t.Fatal(err)
	}
	// Remove the hand-made sidecar: the Swift state waits, no Go state yet.
	for _, n := range []string{state.FileName, state.FileName + "-wal", state.FileName + "-shm"} {
		_ = os.Remove(filepath.Join(dir, n))
	}
	time.Sleep(20 * time.Millisecond) // a write by Resolve would show in the mtimes
	before, beforeSwift := listing(t, dir), listing(t, swift)

	for name, p := range map[string]hostkind.Probe{
		"app bundle": desktopProbe(home, support),
		"MobileHub/": {GOOS: "darwin", Home: home, AppSupport: support, Stat: os.Stat, ReadFile: os.ReadFile},
	} {
		o, err := Resolve(&config.Config{}, nil, p)
		if err != nil || o.Mode != ModeLive || o.Host != hostkind.Desktop || o.Desktop == nil || o.RelayOnlyRules {
			t.Fatalf("%s: %+v err %v", name, o, err)
		}
		if reason, _, _, err := desktopGate(o.Dir, o.Desktop.MobileHubDir); reason != ReasonAwaitingAdoption || err != nil {
			t.Fatalf("%s: gate %q %v", name, reason, err)
		}
		if r := DesktopOffReason(o.Dir, o.Desktop.MobileHubDir); r != ReasonAwaitingAdoption {
			t.Fatalf("%s: off reason %q", name, r)
		}
		if waiting, err := AwaitingAdoption(o.Dir, o.Desktop.MobileHubDir); !waiting || err != nil {
			t.Fatalf("%s: AwaitingAdoption %v %v", name, waiting, err)
		}
		if d, mode, kind, err := Dir(p); err != nil || d != dir || mode != ModeLive || kind != hostkind.Desktop {
			t.Fatalf("%s: Dir %q %q %q %v", name, d, mode, kind, err)
		}
	}
	if after := listing(t, dir); !mapsEqual(before, after) {
		t.Fatalf("the live dir changed:\n%v\n%v", before, after)
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
}

// TestDaemonWaitsWhileAV1HostAnswers: while a v1 session host answers the
// hub stays off (session_host_v1) and builds nothing (so no session host of
// its own is started); a v2 host there starts it within one check.
func TestDaemonWaitsWhileAV1HostAnswers(t *testing.T) {
	policytest.Set(t, nil)
	r := newDeskRig(t, shortDir(t))
	setMeta(t, r.dir, state.MetaEnabled, "1")
	r.v1.Store(true)
	r.start(r.options())
	r.waitState(StateOff, ReasonSessionHostV1)
	time.Sleep(200 * time.Millisecond)
	if r.dials.Load() != 0 || r.ckDial.Load() != 0 {
		t.Fatal("the hub started beside a v1 session host")
	}
	r.v1.Store(false)
	r.waitState(StateRunning, "")
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
}

// TestDesktopHostAnnouncesBothTransports: a desktop host runs and announces
// CloudKit and the relay (CloudKit only without a relay origin); a headless
// host announces the relay alone.
func TestDesktopHostAnnouncesBothTransports(t *testing.T) {
	live := liveHome(t)
	home, _ := os.UserHomeDir()
	support, _ := config.AppSupportDir()
	p := desktopProbe(home, support)
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

// TestBridgeUnavailableSaysSoInStatus: a build without the bridge runs the
// hub and says the bridge is unavailable; with one, the status follows the
// bridge process.
func TestBridgeUnavailableSaysSoInStatus(t *testing.T) {
	policytest.Set(t, nil)
	r := newDeskRig(t, shortDir(t))
	setMeta(t, r.dir, state.MetaEnabled, "1")
	r.start(r.options())
	r.waitStatus("bridge unavailable", func(s Status) bool {
		return s.State == StateRunning && s.Bridge == BridgeUnavailable
	})
	if err := r.stop(); err != nil {
		t.Fatal(err)
	}

	o := r.options()
	var pids []int
	o.Desktop.launch = func(context.Context) (*os.Process, error) {
		p, err := startStub(t, "sleep 30")
		if err == nil {
			pids = append(pids, p.Pid)
		}
		return p, err
	}
	r.start(o)
	r.waitStatus("bridge running", func(s Status) bool { return s.State == StateRunning && s.Bridge == BridgeRunning })
	if err := r.stop(); err != nil {
		t.Fatal(err)
	}
	for _, pid := range pids {
		if err := syscall.Kill(pid, 0); err == nil {
			t.Fatalf("the bridge %d outlived the hub", pid)
		}
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
	r := newDeskRig(t, shortDir(t))
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
	eventually(t, 10*time.Second, "the heartbeat published", func() bool {
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
