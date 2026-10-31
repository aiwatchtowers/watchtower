// Package hub is the Go hub's runtime (Go hub spec §4, §7.3): it joins the
// sidecar (state), the hub identity and keyring, a transport, linking (link),
// the action processor (actions) and the slice publisher (slices) into one
// running hub inside the watchtower daemon, and serves the local control
// socket the `watchtower hub …` CLI writes through.
//
// Phase 1 (spec §14 row 1): the daemon starts the hub only when FromEnv says
// so — WATCHTOWER_HUB_DIR (absolute, never the Swift hub's MobileHub dir),
// WATCHTOWER_RELAY_ORIGIN, and WATCHTOWER_HUB_TEST_WORKSPACE naming the
// daemon's own active workspace, which must be a hubtest-* one. A headless
// host runs relay-only.
//
// One hub per state dir: Run holds <dir>/hub.lock from before it opens the
// sidecar until it returns, so a second Run (or a CLI writing directly)
// never opens the sidecar for writing meanwhile. While it holds the lock Run
// serves <dir>/hub.sock and keeps the hub on or off as hub_meta.enabled and
// the managed MobileSync policy say (POLICY-03: off stops the hub and deletes
// what it published from the data zone, never the owner's setting;
// loosening never starts a hub the owner left off).
//
// E2E: everything that leaves the hub is a secure.Record from the Sealer
// (the transports refuse anything else); the identity is zeroed when the
// hub stops. Log lines carry ids, counts and classes only (FILES-01).
package hub

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/actions/handlers"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/slices"
	"watchtower/internal/hub/slices/sources"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/policy"
)

// The phase-1 environment.
const (
	EnvHubDir        = "WATCHTOWER_HUB_DIR"
	EnvRelayOrigin   = "WATCHTOWER_RELAY_ORIGIN"
	EnvTestWorkspace = "WATCHTOWER_HUB_TEST_WORKSPACE"
	// TestWorkspacePrefix starts every workspace a phase-1 hub may run in;
	// a live workspace is never named so.
	TestWorkspacePrefix = "hubtest-"
)

// Lock retry (a CLI write holds the lock for milliseconds).
const (
	lockRetry  = time.Second
	lockWindow = 30 * time.Second
	// checkEvery: how often Run re-reads the policy and the switch on its
	// own (a control request or a daemon cycle wakes it sooner).
	checkEvery = 5 * time.Second
	// controlWriteTimeout: one control-socket line must go out within it,
	// or the client is dropped.
	controlWriteTimeout = 5 * time.Second
	// startBackoffMax caps the wait between failed hub starts.
	startBackoffMax = time.Minute
)

// Why the hub does not start.
var (
	ErrDirNotAbsolute    = errors.New("hub: WATCHTOWER_HUB_DIR is not an absolute path")
	ErrSwiftHubDir       = errors.New("hub: the hub dir is the Swift hub's MobileHub dir")
	ErrNotTestWorkspace  = errors.New("hub: not a hubtest-* test workspace named by WATCHTOWER_HUB_TEST_WORKSPACE")
	ErrNoRelayOrigin     = errors.New("hub: WATCHTOWER_RELAY_ORIGIN is not set to an http(s) origin")
	ErrSidecarUnreadable = errors.New("hub: the hub state is unreadable")
	// ErrStartFailed: a start step other than reading the sidecar failed
	// (the identity file, a first-start write, the asset dir); retried.
	ErrStartFailed = errors.New("hub: the hub could not start")
)

// Refusal is the class of a FromEnv or Run error for a log line, never its
// text.
func Refusal(err error) string {
	switch {
	case err == nil:
		return ""
	case errors.Is(err, ErrNotTestWorkspace):
		return ReasonNotTestWorkspace
	case errors.Is(err, ErrSidecarUnreadable):
		return ReasonSidecarUnreadable
	case errors.Is(err, ErrStartFailed):
		return ReasonStartFailed
	case errors.Is(err, ErrDirNotAbsolute):
		return "dir_not_absolute"
	case errors.Is(err, ErrSwiftHubDir):
		return "swift_hub_dir"
	case errors.Is(err, ErrNoRelayOrigin):
		return "no_relay_origin"
	case errors.Is(err, context.Canceled):
		return "stopped"
	default:
		return "error"
	}
}

// Options configures Run. RecordingsDir is <Dir>/recordings in phase 1 (used
// by Plan 1b). DB is the daemon's watchtower.db (the heartbeat's accounts;
// nil = none). CycleTick fires once per daemon cycle (nil = never). Register
// adds Plan 1b's action handlers after the probe; Sources adds its slices.
type Options struct {
	Dir, RelayOrigin, RecordingsDir string
	DB                              *db.DB
	CycleTick                       <-chan struct{}
	Clock                           func() time.Time
	Register                        func(*actions.Dispatcher)
	Sources                         func(*state.Store) []slices.Source
	// Sessions is the session-host port of the handlers; nil answers no
	// session live (the real port is Plan 1b Task 15).
	Sessions handlers.SessionPort

	// Test seams (zero = production).
	newTransport func(ctx context.Context, id identity.Identity, st *state.Store, zones []string) (transport.Transport, error)
	openStore    func(dir string) (*state.Store, error)
	report       func(Status)
	peerUID      func(*net.UnixConn) (int, error)
	mobileSync   func() string
	lockRetry    time.Duration
	lockWindow   time.Duration
	checkEvery   time.Duration
	passEvery    time.Duration
	writeTimeout time.Duration
	pairQueue    int // events one pairing stream may have waiting (0 = pairQueue)
	trace        func(step string)
	reportFetch  sources.ReportFetch // nil = the in-process report
	gitFetch     sources.GitFetch    // nil = the in-process git status
	laneBackstop time.Duration       // 0 = laneBackstop
	runnerGap    time.Duration       // 0 = the runners' standard 5 s
	sendBuffer   int                 // SO_SNDBUF of each accepted control connection (0 = the OS default)
}

func (o Options) withDefaults() Options {
	if o.Clock == nil {
		o.Clock = time.Now
	}
	if o.openStore == nil {
		o.openStore = state.Open
	}
	if o.peerUID == nil {
		o.peerUID = socketPeerUID
	}
	if o.mobileSync == nil {
		o.mobileSync = policy.MobileSync
	}
	if o.newTransport == nil {
		o.newTransport = o.relayTransport
	}
	if o.lockRetry <= 0 {
		o.lockRetry = lockRetry
	}
	if o.lockWindow <= 0 {
		o.lockWindow = lockWindow
	}
	if o.checkEvery <= 0 {
		o.checkEvery = checkEvery
	}
	if o.passEvery <= 0 {
		o.passEvery = passEvery
	}
	if o.writeTimeout <= 0 {
		o.writeTimeout = controlWriteTimeout
	}
	if o.pairQueue <= 0 {
		o.pairQueue = pairQueue
	}
	return o
}

// FromEnv reads the phase-1 switch. ok is false with a nil error when
// WATCHTOWER_HUB_DIR is unset (the hub is simply not configured). Every
// refusal is an error and leaves the dir untouched: a relative dir, the
// Swift hub's dir or anything below it, a workspace that is not the
// daemon's active one or not named hubtest-*, or no relay origin.
func FromEnv(cfg *config.Config, database *db.DB) (Options, bool, error) {
	dir := os.Getenv(EnvHubDir)
	if dir == "" {
		return Options{}, false, nil
	}
	if err := checkDir(dir); err != nil {
		return Options{}, false, err
	}
	ws := os.Getenv(EnvTestWorkspace)
	if cfg == nil || ws == "" || ws != cfg.ActiveWorkspace || !strings.HasPrefix(ws, TestWorkspacePrefix) {
		return Options{}, false, ErrNotTestWorkspace
	}
	origin := os.Getenv(EnvRelayOrigin)
	if u, err := url.Parse(origin); origin == "" || err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" {
		return Options{}, false, ErrNoRelayOrigin
	}
	dir = filepath.Clean(dir)
	return Options{Dir: dir, RelayOrigin: origin, RecordingsDir: filepath.Join(dir, "recordings"), DB: database}, true, nil
}

// checkDir refuses a relative dir and the Swift hub's <AppSupportDir>/MobileHub
// or anything below it (symlinks resolved as far as the path exists).
func checkDir(dir string) error {
	if !filepath.IsAbs(dir) {
		return ErrDirNotAbsolute
	}
	support, err := config.AppSupportDir()
	if err != nil {
		return fmt.Errorf("hub: locating the app support dir: %w", err)
	}
	swift := resolvePath(filepath.Join(support, "MobileHub"))
	d := resolvePath(dir)
	if d == swift || strings.HasPrefix(d, swift+string(filepath.Separator)) {
		return ErrSwiftHubDir
	}
	return nil
}

// resolvePath cleans p and resolves symlinks in its longest existing prefix.
func resolvePath(p string) string {
	p = filepath.Clean(p)
	rest := ""
	for cur := p; ; {
		if r, err := filepath.EvalSymlinks(cur); err == nil {
			return filepath.Join(r, rest)
		}
		parent := filepath.Dir(cur)
		if parent == cur {
			return p
		}
		rest = filepath.Join(filepath.Base(cur), rest)
		cur = parent
	}
}

// Run is the hub until ctx ends: lock → state → (when on) identity →
// keyring → transport → link, processor and publisher. The lock is retried
// every second for 30 s, then once per CycleTick; meanwhile the status reads
// starting/locked. An unreadable sidecar keeps the hub off, says so in the
// status and returns ErrSidecarUnreadable. Run releases the lock when it
// returns; on ctx's end it returns nil.
func Run(ctx context.Context, o Options) error {
	o = o.withDefaults()
	if err := checkDir(o.Dir); err != nil {
		return err
	}
	s := &supervisor{o: o, run: newRunID(), wake: make(chan struct{}, 1), pairs: map[*pairListener]bool{}}
	lock, err := s.acquire(ctx)
	if err != nil {
		if errors.Is(err, context.Canceled) {
			return nil
		}
		return err
	}
	defer func() { _ = lock.Release() }()
	s.locked = true
	st, err := o.openStore(o.Dir)
	if err != nil {
		s.setStatus(Status{State: StateOff, Reason: ReasonSidecarUnreadable})
		log.Printf("hub: off (%s)", ReasonSidecarUnreadable)
		return fmt.Errorf("%w: %w", ErrSidecarUnreadable, err)
	}
	defer func() { _ = st.Close() }()
	s.st = st
	if err := s.markImpl(); err != nil {
		s.setStatus(Status{State: StateOff, Reason: ReasonSidecarUnreadable})
		log.Printf("hub: off (%s)", ReasonSidecarUnreadable)
		return fmt.Errorf("%w: %w", ErrSidecarUnreadable, err)
	}
	stopControl := s.serveControl(ctx)
	defer stopControl()
	defer s.setStatus(Status{State: StateOff})

	tick := time.NewTicker(o.checkEvery)
	defer tick.Stop()
	for {
		s.reconcile(ctx)
		select {
		case <-ctx.Done():
			s.stopHub(nil)
			return nil
		case <-s.wake:
		case <-tick.C:
		case <-o.CycleTick:
			s.cycle()
		}
	}
}

// supervisor is one Run: the lock, the store, the running hub (nil while
// off) and the control socket's pairing listeners.
type supervisor struct {
	o      Options
	run    string
	st     *state.Store
	locked bool
	wake   chan struct{}

	// hubMu: the control handlers hold it for reading while they use the
	// running hub; starting and stopping take it for writing.
	hubMu sync.RWMutex
	hub   *hubRuntime
	// offlineMu runs the offline link decisions (no hub runs) one at a
	// time, as the running hub's center does.
	offlineMu sync.Mutex

	// Only Run's goroutine touches these.
	nextStart time.Time
	backoff   time.Duration
	failure   string

	statusMu sync.Mutex
	status   Status

	pairMu sync.Mutex
	pairs  map[*pairListener]bool
}

func newRunID() string {
	var b [8]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

// poke wakes Run's loop.
func (s *supervisor) poke() {
	select {
	case s.wake <- struct{}{}:
	default:
	}
}

// acquire takes the hub lock, retrying every lockRetry within lockWindow,
// then once per CycleTick.
func (s *supervisor) acquire(ctx context.Context) (*state.Lock, error) {
	started := time.Now()
	waiting := false
	for {
		l, err := state.AcquireLock(s.o.Dir)
		if err == nil {
			return l, nil
		}
		if !errors.Is(err, state.ErrLocked) {
			return nil, fmt.Errorf("hub: taking the hub lock: %w", err)
		}
		if !waiting {
			waiting = true
			s.setStatus(Status{State: StateStarting, Reason: ReasonLocked})
			log.Printf("hub: starting (%s)", ReasonLocked)
		}
		var (
			retry <-chan time.Time
			timer *time.Timer
		)
		if time.Since(started) < s.o.lockWindow {
			timer = time.NewTimer(s.o.lockRetry)
			retry = timer.C
		}
		select {
		case <-ctx.Done():
		case <-retry:
		case <-s.o.CycleTick:
		}
		if timer != nil {
			timer.Stop()
		}
		if err := ctx.Err(); err != nil {
			return nil, err
		}
	}
}

// markImpl records hub_impl = go on the first start.
func (s *supervisor) markImpl() error {
	if _, ok, err := s.st.Meta(state.MetaHubImpl); err != nil || ok {
		return err
	}
	return s.st.SetMeta(state.MetaHubImpl, "go")
}

// enabled reads the owner's switch.
func (s *supervisor) enabled() (bool, error) {
	v, _, err := s.st.Meta(state.MetaEnabled)
	return v == "1", err
}

// reconcile brings the hub in line with the switch and the policy.
func (s *supervisor) reconcile(ctx context.Context) {
	mode := s.o.mobileSync()
	on, err := s.enabled()
	if err != nil {
		log.Printf("hub: reading the switch failed (%s)", errClass(err))
		return
	}
	name := s.hostName()
	want := on && mode != policy.MobileOff
	if h := s.hub; h != nil && (!want || h.mode != mode || h.name != name) {
		switch {
		case mode == policy.MobileOff:
			s.stopHub(func(slices.Kind) bool { return false })
		case mode == policy.MobileWorkbenchOnly && h.mode != mode:
			s.stopHub(workbenchOnly)
		default:
			s.stopHub(nil)
		}
	}
	if s.hub == nil && on && mode == policy.MobileOff {
		s.wipeStopped(ctx)
	}
	if want && s.hub == nil && !time.Now().Before(s.nextStart) {
		s.startHub(ctx, mode, name)
	}
	s.refreshStatus(mode, on)
}

// cycle is the daemon cycle's tick: the running hub does its housekeeping.
func (s *supervisor) cycle() {
	if h := s.hub; h != nil {
		h.kick(h.houseKick)
	}
}

// startHub starts the hub; a failure is retried after a growing backoff.
func (s *supervisor) startHub(ctx context.Context, mode, name string) {
	h, err := newHubRuntime(ctx, s, mode, name)
	if err != nil {
		s.failure = startFailure(err)
		s.backoff = min(max(2*s.backoff, time.Second), startBackoffMax)
		s.nextStart = time.Now().Add(s.backoff)
		log.Printf("hub: start failed (%s), retried in %s", s.failure, s.backoff)
		return
	}
	s.failure, s.backoff, s.nextStart = "", 0, time.Time{}
	s.hubMu.Lock()
	s.hub = h
	s.hubMu.Unlock()
	log.Printf("hub: running (hub %s, %s)", h.kr.HubID(), h.tr.Kind())
}

// stopHub stops the running hub; with keep set it first deletes from the
// data zone every published record whose kind keep refuses.
func (s *supervisor) stopHub(keep func(slices.Kind) bool) {
	s.hubMu.Lock()
	h := s.hub
	s.hub = nil
	s.hubMu.Unlock()
	if h != nil {
		h.stop(keep)
		log.Printf("hub: stopped")
	}
}

// wipeStopped deletes what an earlier run published while the policy is off
// and the owner's switch on: once, since a wipe leaves no published record.
func (s *supervisor) wipeStopped(ctx context.Context) {
	published, err := publishedRecords(s.st, func(slices.Kind) bool { return false })
	if err != nil {
		log.Printf("hub: policy off: reading what was published failed (%s)", errClass(err))
		return
	}
	if len(published) == 0 {
		return
	}
	id, err := loadIdentity(s.o.Dir)
	if err != nil {
		log.Printf("hub: policy off: wipe skipped (%s)", errClass(err))
		return
	}
	defer id.Zero()
	tr, err := s.o.newTransport(ctx, id, s.st, nil)
	if err != nil {
		log.Printf("hub: policy off: wipe deferred (%s)", startFailure(err))
		return
	}
	defer closeTransport(tr)
	wipe(ctx, s.st, tr, dataZoneOf(id), published)
}

// hostName is the name the hub shows phones: hub_meta.display_name, else
// the host name.
func (s *supervisor) hostName() string {
	v, ok, err := s.st.Meta(state.MetaDisplayName)
	if err != nil {
		log.Printf("hub: reading the display name failed (%s): the host name is used", errClass(err))
	}
	if ok && v != "" {
		return v
	}
	n, err := os.Hostname()
	if err != nil {
		return "Watchtower hub"
	}
	return n
}

// refreshStatus writes the status from the switch, the policy and the hub.
func (s *supervisor) refreshStatus(mode string, on bool) {
	st := Status{State: StateOff}
	impl, _, implErr := s.st.Meta(state.MetaHubImpl)
	hubID, _, idErr := s.st.Meta(state.MetaHubID)
	devices, devErr := s.st.Devices()
	if err := errors.Join(implErr, idErr, devErr); err != nil {
		log.Printf("hub: reading the status facts failed (%s)", errClass(err))
	}
	st.Impl, st.HubID, st.Phones = impl, hubID, len(devices)
	switch h := s.hub; {
	case mode == policy.MobileOff:
		st.Reason = ReasonPolicyOff
	case !on:
		st.Reason = ReasonDisabled
	case h == nil && s.failure == ReasonSidecarUnreadable:
		st.Reason = s.failure
	case h == nil:
		st.State, st.Reason = StateStarting, s.failure
	default:
		st.State, st.Reason = StateRunning, h.reason()
		st.RelayDeviceID, st.Transport = h.relayID, string(h.tr.Kind())
	}
	s.setStatus(st)
}

// setStatus records the status: the report hook sees every one; the file
// gets it unless this Run waits for the lock while another live run's
// status is there.
func (s *supervisor) setStatus(st Status) {
	st.Dir = s.o.Dir
	s.statusMu.Lock()
	defer s.statusMu.Unlock()
	if st == s.status {
		return
	}
	s.status = st
	if s.o.report != nil {
		s.o.report(st)
	}
	if !s.locked && s.otherLiveStatus() {
		return
	}
	if err := writeStatusRun(s.o.Dir, st, s.run); err != nil {
		log.Printf("hub: writing the status failed (%s)", errClass(err))
	}
}

// otherLiveStatus: the status file holds a live status of another run.
func (s *supervisor) otherLiveStatus() bool {
	f, err := readStatusFile(s.o.Dir)
	return err == nil && f.State != StateOff && f.Run != s.run && processAlive(f.PID)
}

// errClass is an error's class for a log line, never its text.
func errClass(err error) string {
	for _, c := range []struct {
		err   error
		class string
	}{
		{context.Canceled, "canceled"}, {context.DeadlineExceeded, "timeout"},
		{transport.ErrUnavailable, "unavailable"}, {transport.ErrForbidden, "forbidden"},
		{transport.ErrEntitlementInactive, "entitlement_inactive"}, {transport.ErrRateLimited, "rate_limited"},
		{transport.ErrTokenExpired, "token_expired"}, {transport.ErrUnsupportedVersion, "unsupported_version"},
		{identity.ErrSealedKeyUnreadable, "sealed_key_unreadable"}, {identity.ErrInsecureMode, "insecure_mode"},
		{identity.ErrKeysUnavailable, "keys_unavailable"}, {state.ErrNoDevice, "no_device"},
	} {
		if errors.Is(err, c.err) {
			return c.class
		}
	}
	return "other"
}

// startFailure is the status reason of a failed start.
func startFailure(err error) string {
	switch {
	case errors.Is(err, ErrSidecarUnreadable):
		return ReasonSidecarUnreadable
	case errors.Is(err, ErrStartFailed):
		return ReasonStartFailed
	case errors.Is(err, transport.ErrForbidden), errors.Is(err, transport.ErrEntitlementInactive):
		return ReasonNotAdmitted
	default:
		return ReasonRelayUnreachable
	}
}
