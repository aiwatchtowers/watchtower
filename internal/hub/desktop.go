package hub

// A desktop host's live mode (Go hub phase 3 Task 21, spec §6.2, §12.1): the
// hub runs in DefaultDir beside the Watchtower app on both transports — the
// CloudKit bridge and, when a relay origin is set, the hosted relay — once the
// Swift hub's state is adopted (or the Mac never had one and the owner turned
// Mobile on). Never two hubs: until then Run neither takes the hub lock (the
// adoption needs it) nor opens or creates the sidecar, and a MobileHub/ that
// shows up later is logged once and never read.

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/hub/adopt"
	"watchtower/internal/hub/hostkind"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/switcher"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/cloudkit"
	"watchtower/internal/hub/wire"
	"watchtower/internal/policy"
	"watchtower/internal/sessionhost"
)

// BridgeExecutable is the CloudKit bridge's executable inside the app
// bundle (scripts/build-app.sh embeds WatchtowerCloudBridge.app there).
const BridgeExecutable = "Contents/Helpers/WatchtowerCloudBridge.app/Contents/MacOS/WatchtowerCloudBridge"

// bridgeSocketName is the bridge's socket in the hub dir (spec §6.2).
const bridgeSocketName = "bridge.sock"

// hostCheckTimeout bounds the v1 session-host probe.
const hostCheckTimeout = 2 * time.Second

// Desktop is what a desktop host's live mode adds to Options (nil on every
// other hub).
type Desktop struct {
	// MobileHubDir is the Swift hub's MobileHub/: looked at (never opened)
	// for the never-two-hubs gate.
	MobileHubDir string
	// Keychain: a first start records the Keychain identity store
	// (identity.KeychainUsable); false records the file store.
	Keychain bool
	// Bridge is the bridge's executable; "" = this build has none, so the
	// CloudKit transport is unavailable (status bridge "unavailable").
	Bridge string

	// Test seams (nil = production).
	newCloudKit func(c cloudkit.Config) transport.Transport
	hostCheck   func(ctx context.Context) error // sessionhost.Dial's answer
	launch      func(ctx context.Context) (*os.Process, error)
}

// desktopOptions is Resolve's answer on a desktop host: live mode in
// DefaultDir with the recordings in <app support>/recordings, both
// transports (CloudKit only when no valid relay origin is set) and the
// bridge found beside the app. Nothing is created or opened here: Run holds
// the hub off until the gate opens (awaitDesktop, reconcile).
func desktopOptions(o Options, cfg *config.Config, p hostkind.Probe, support string) Options {
	o.RecordingsDir = filepath.Join(support, "recordings")
	o.Transports = []string{wire.TransportCloudKit}
	if origin := RelayOrigin(cfg); origin != "" {
		if err := CheckRelayOrigin(origin); err != nil {
			log.Printf("hub: the relay origin is not valid (%s): CloudKit only", errClass(err))
		} else {
			o.RelayOrigin = origin
			o.Transports = append(o.Transports, wire.TransportRelay)
		}
	}
	o.Desktop = &Desktop{
		MobileHubDir: filepath.Join(support, "MobileHub"),
		Keychain:     identity.KeychainUsable,
		Bridge:       findBridge(p, os.Executable),
	}
	return o
}

// findBridge is the bridge executable of the app this binary belongs to
// (when it runs from inside a bundle), else of the installed app in
// /Applications or ~/Applications; "" when none is there (a dev build
// without the helper).
func findBridge(p hostkind.Probe, exe func() (string, error)) string {
	var apps []string
	if path, err := exe(); err == nil {
		if i := strings.Index(path, ".app/Contents/MacOS/"); i >= 0 {
			apps = append(apps, path[:i+len(".app")])
		}
	}
	apps = append(apps, "/Applications/Watchtower.app")
	if p.Home != "" {
		apps = append(apps, filepath.Join(p.Home, "Applications", "Watchtower.app"))
	}
	for _, app := range apps {
		bin := filepath.Join(app, BridgeExecutable)
		if fi, err := p.Stat(bin); err == nil && fi.Mode().IsRegular() && fi.Mode().Perm()&0o111 != 0 {
			return bin
		}
	}
	return ""
}

// bridgeLauncher starts the bridge as `<exe> --socket <dir>/bridge.sock`,
// directly (never open(1)) and as its own process group's leader, so the
// daemon owns its lifetime and the Supervisor stops the whole group.
func bridgeLauncher(exe, dir string) func(ctx context.Context) (*os.Process, error) {
	return func(context.Context) (*os.Process, error) {
		cmd := exec.Command(exe, "--socket", filepath.Join(dir, bridgeSocketName))
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		if err := cmd.Start(); err != nil {
			return nil, err
		}
		return cmd.Process, nil
	}
}

// desktopGate is the never-two-hubs rule (spec §12.1), read-only: the reason
// the hub stays off ("" = it may start), the adoption's state for the
// status, and later = a MobileHub/ sidecar beside a Go hub that already has
// its own state (never read). No Go sidecar: awaiting_adoption while the
// Swift one is there, else disabled (the owner never turned Mobile on). A Go
// sidecar that never adopted, or whose adoption and key hand-over finished
// (adopt.HubMayStart), may start; one mid-adoption waits, or says
// adoption_failed with its error class.
func desktopGate(dir, mobile string) (reason, adoption string, later bool, err error) {
	swift := fileExists(filepath.Join(mobile, state.FileName))
	if !fileExists(filepath.Join(dir, state.FileName)) {
		if swift {
			return ReasonAwaitingAdoption, AdoptionNone, false, nil
		}
		return ReasonDisabled, AdoptionNone, false, nil
	}
	st, err := state.OpenReadOnly(dir)
	if err != nil {
		return "", "", false, fmt.Errorf("%w: %w", ErrSidecarUnreadable, err)
	}
	defer func() { _ = st.Close() }()
	adoption, err = adoptionOf(st)
	if err != nil {
		return "", "", false, fmt.Errorf("%w: %w", ErrSidecarUnreadable, err)
	}
	may, err := adopt.HubMayStart(st)
	if err != nil {
		return "", "", false, fmt.Errorf("%w: %w", ErrSidecarUnreadable, err)
	}
	switch {
	case may:
		return "", adoption, swift, nil
	case adoption == AdoptionFailed:
		return ReasonAdoptionFailed, adoption, false, nil
	}
	return ReasonAwaitingAdoption, adoption, false, nil
}

// adoptionOf is the adoption's state in st: none (never adopted), done
// (adopted and the keys handed over), failed (stopped with an error class),
// else in_progress.
func adoptionOf(st *state.Store) (string, error) {
	step, _, err := st.Meta(adopt.MetaAdoptStep)
	if err != nil || step == "" {
		return AdoptionNone, err
	}
	may, err := adopt.HubMayStart(st)
	if err != nil {
		return "", err
	}
	if may {
		return AdoptionDone, nil
	}
	if e, _, err := st.Meta(adopt.MetaAdoptError); err != nil || e != "" {
		return AdoptionFailed, err
	}
	return AdoptionInProgress, nil
}

// statusFacts are the status fields read from the sidecar: the adoption,
// the identity store (a headless or test hub's is the file) and the last
// transport switch.
func statusFacts(st *state.Store, desktop bool) (adoption, ident, switchedAt, switchedBy string, err error) {
	if adoption, err = adoptionOf(st); err != nil {
		return "", "", "", "", err
	}
	ident = identity.IdentityStoreFile
	if desktop {
		if ident, _, err = st.Meta(identity.MetaIdentityStore); err != nil {
			return "", "", "", "", err
		}
	}
	raw, ok, err := st.Meta(switcher.MetaSwitchedAt)
	if err != nil {
		return "", "", "", "", err
	}
	if ok && raw != "" {
		if secs, perr := strconv.ParseFloat(raw, 64); perr == nil {
			switchedAt = time.Unix(0, int64(secs*1e9)).UTC().Format(time.RFC3339)
		}
	}
	if switchedBy, _, err = st.Meta(switcher.MetaSwitchedBy); err != nil {
		return "", "", "", "", err
	}
	return adoption, ident, switchedAt, switchedBy, nil
}

func fileExists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil || !errors.Is(err, fs.ErrNotExist)
}

// DesktopOffReason is `hub status`' reason for a desktop host's hub that is
// off before the daemon wrote one ("" = none to add): the gate's, else
// disabled or policy_off.
func DesktopOffReason(dir, mobile string) string {
	reason, _, _, err := desktopGate(dir, mobile)
	if err != nil {
		return Refusal(err)
	}
	if reason != "" {
		return reason
	}
	on, err := liveEnabled(dir)
	switch {
	case err != nil:
		return Refusal(err)
	case !on:
		return ReasonDisabled
	case policy.MobileSync() == policy.MobileOff:
		return ReasonPolicyOff
	}
	return ""
}

// FillOffFacts fills an off status' empty sidecar facts (adoption, identity
// store, last switch) from dir's sidecar, read-only; no sidecar (or an
// unreadable one) leaves the adoption none and the rest empty.
func FillOffFacts(s *Status, dir string, desktop bool) {
	if s.Adoption != "" {
		return
	}
	s.Adoption = AdoptionNone
	st, err := state.OpenReadOnly(dir)
	if err != nil {
		return
	}
	defer func() { _ = st.Close() }()
	if a, ident, at, by, err := statusFacts(st, desktop); err == nil {
		s.Adoption, s.Identity, s.SwitchedAt, s.SwitchedBy = a, ident, at, by
	}
}

// AwaitingAdoption reports whether a desktop host's Go hub dir must not be
// written yet: the Swift hub's state waits for its adoption (a direct CLI
// write would create a sidecar the adoption then refuses as its own).
func AwaitingAdoption(dir, mobile string) (bool, error) {
	reason, _, _, err := desktopGate(dir, mobile)
	if err != nil {
		return false, err
	}
	return reason == ReasonAwaitingAdoption || reason == ReasonAdoptionFailed, nil
}

// awaitDesktop holds a desktop host's Run before the hub lock until the gate
// opens, re-checking every checkEvery and every daemon cycle; meanwhile the
// status says off with the gate's reason. false: ctx ended.
func (s *supervisor) awaitDesktop(ctx context.Context) bool {
	tick := time.NewTicker(s.o.checkEvery)
	defer tick.Stop()
	for {
		reason, adoption, later, err := desktopGate(s.o.Dir, s.o.Desktop.MobileHubDir)
		if err != nil {
			reason = Refusal(err)
		}
		s.noteLaterMobileHub(later)
		if reason == "" {
			return true
		}
		if err := os.MkdirAll(s.o.Dir, 0o700); err != nil {
			log.Printf("hub: creating the hub dir failed (%s)", errClass(err))
		} else {
			s.setStatus(Status{State: StateOff, Reason: reason, Adoption: adoption})
		}
		select {
		case <-ctx.Done():
			return false
		case <-tick.C:
		case <-s.o.CycleTick:
		}
	}
}

// noteLaterMobileHub logs a later MobileHub/ once per Run (spec §12.1: it is
// never read, imported or deleted).
func (s *supervisor) noteLaterMobileHub(later bool) {
	if later && !s.laterLogged {
		s.laterLogged = true
		log.Print(adopt.LaterMobileHubLog)
	}
}

// laterMobileHub re-checks for a later MobileHub/ while the hub holds its
// dir (the Swift sidecar only: nothing in it is opened).
func (s *supervisor) laterMobileHub() {
	if s.o.Desktop != nil && !s.laterLogged {
		s.noteLaterMobileHub(fileExists(filepath.Join(s.o.Desktop.MobileHubDir, state.FileName)))
	}
}

// v1HostAnswers reports whether a v1 session host (an older app's) answers
// on the session-host socket: the hub waits for the v2 host then, and starts
// none of its own. Nothing listening, or a v2 host, is no reason to wait.
func (s *supervisor) v1HostAnswers(ctx context.Context) bool {
	d := s.o.Desktop
	ctx, cancel := context.WithTimeout(ctx, hostCheckTimeout)
	defer cancel()
	var err error
	switch {
	case d.hostCheck != nil:
		err = d.hostCheck(ctx)
	case s.o.SessionStart.Socket == "":
		return false
	default:
		var c *sessionhost.Client
		if c, err = sessionhost.Dial(ctx, s.o.SessionStart.Socket); err == nil {
			_ = c.Close()
		}
	}
	return errors.Is(err, sessionhost.ErrHostV1)
}

// desktopIdentity is a desktop host's identity from its recorded store
// (identity.ForDesktopHost). A hub that never adopted creates one on its
// first start; an adopted hub never does — its identity is the Swift hub's,
// handed over before the gate opened.
func (o Options) desktopIdentity(st *state.Store) (identity.Identity, error) {
	store, err := identity.ForDesktopHost(st, o.Dir, o.Desktop.Keychain)
	if err != nil {
		return identity.Identity{}, fmt.Errorf("%w: %w", ErrStartFailed, err)
	}
	id, err := store.Load()
	if errors.Is(err, identity.ErrNoIdentity) {
		step, _, merr := st.Meta(adopt.MetaAdoptStep)
		if merr != nil || step != "" {
			return identity.Identity{}, fmt.Errorf("%w: %w", ErrStartFailed, errors.Join(err, merr))
		}
		if id, err = identity.New(); err != nil {
			return identity.Identity{}, fmt.Errorf("%w: %w", ErrStartFailed, err)
		}
		if err := store.Save(id); err != nil {
			id.Zero()
			return identity.Identity{}, fmt.Errorf("%w: %w", ErrStartFailed, err)
		}
		return id, nil
	}
	if err != nil {
		return identity.Identity{}, fmt.Errorf("%w: %w", ErrStartFailed, err)
	}
	return id, nil
}
