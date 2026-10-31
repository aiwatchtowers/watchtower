package hub

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/db/lockmetrics"
	"watchtower/internal/hub/hostkind"
	"watchtower/internal/hub/state"
	"watchtower/internal/policy"
	"watchtower/internal/sessionhost"
	"watchtower/internal/sessionstart"
)

// Mode is how a hub runs: the phase-1 test mode (WATCHTOWER_HUB_DIR in a
// hubtest-* workspace), the live mode of a headless host, or off.
type Mode string

// The modes.
const (
	ModeOff  Mode = ""
	ModeTest Mode = "test"
	ModeLive Mode = "live"
)

// Why a live hub does not start (each also a Refusal class).
var (
	// ErrDesktopHost: the Watchtower app (or the Swift hub's state) is on
	// this Mac; its mobile link is the app's, never a second hub's.
	ErrDesktopHost = errors.New("hub: mobile on this Mac is run by the Watchtower app")
	// ErrHubDisabled: the owner has not turned the live hub on (hub enable).
	ErrHubDisabled = errors.New("hub: the hub is turned off")
	// ErrPolicyOff: the managed MobileSync policy is off.
	ErrPolicyOff = errors.New("hub: the MobileSync policy is off")
)

// Resolve is the daemon's only way to a hub: the Options to Run and the mode,
// or ModeOff and the reason (Refusal(err)) the hub stays off.
//
// WATCHTOWER_HUB_DIR set: the phase-1 test mode through FromEnv, exactly as
// before (a set dir never falls back to live). Else the host kind decides,
// once, here (no re-check while the hub runs, ask #827): a desktop host gets
// no live hub and nothing under the live dir or MobileHub/ is created or
// opened. On a headless host the live hub in DefaultDir starts only when its
// sidecar exists with hub_meta.enabled = 1 (read-only; the dir is never
// created here), the MobileSync policy is not off, a valid relay origin is
// set and the session-host socket folder is usable.
func Resolve(cfg *config.Config, d *db.DB, p hostkind.Probe) (Options, Mode, error) {
	kind, _ := hostkind.Detect(p)
	if os.Getenv(EnvHubDir) != "" {
		o, _, err := FromEnv(cfg, d)
		if err != nil {
			return Options{}, ModeOff, err
		}
		o.Mode, o.Host = ModeTest, kind
		return o, ModeTest, nil
	}
	if kind == hostkind.Desktop {
		return Options{}, ModeOff, ErrDesktopHost
	}
	dir, origin, err := liveGate(cfg)
	if d != nil {
		// Reading the switch pointed this process's lock-metrics sink at
		// the hub dir (state.OpenReadOnly); the daemon's stays its database's.
		repointLockMetrics(d)
	}
	if err != nil {
		return Options{}, ModeOff, err
	}
	sock, err := sessionhost.DefaultSocket()
	if err != nil {
		return Options{}, ModeOff, fmt.Errorf("%w: %w", sessionhost.ErrRunDirUnusable, err)
	}
	o := Options{
		Dir: dir, RelayOrigin: origin, RecordingsDir: filepath.Join(dir, "recordings"), DB: d,
		SessionStart: sessionstart.Deps{Socket: sock}, Mode: ModeLive, Host: kind,
	}
	// Task 7: set RelayOnlyRules = true here
	return o, ModeLive, nil
}

// liveGate is the live hub's start rule on a headless host: its dir and
// relay origin, or why it stays off (ErrHubDisabled, ErrPolicyOff,
// ErrNoRelayOrigin). Nothing is created.
func liveGate(cfg *config.Config) (dir, origin string, err error) {
	dir, err = DefaultDir()
	if err != nil {
		return "", "", err
	}
	on, err := liveEnabled(dir)
	if err != nil {
		return "", "", err
	}
	if !on {
		return "", "", ErrHubDisabled
	}
	if policy.MobileSync() == policy.MobileOff {
		return "", "", ErrPolicyOff
	}
	origin = RelayOrigin(cfg)
	if origin == "" {
		return "", "", ErrNoRelayOrigin
	}
	if err := CheckRelayOrigin(origin); err != nil {
		return "", "", fmt.Errorf("%w: %w", ErrNoRelayOrigin, err)
	}
	return dir, origin, nil
}

// liveEnabled reads hub_meta.enabled from dir's sidecar, read-only; no
// sidecar (or no dir) reads as off.
func liveEnabled(dir string) (bool, error) {
	st, err := state.OpenReadOnly(dir)
	if errors.Is(err, fs.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("%w: %w", ErrSidecarUnreadable, err)
	}
	defer func() { _ = st.Close() }()
	v, _, err := st.Meta(state.MetaEnabled)
	if err != nil {
		return false, fmt.Errorf("%w: %w", ErrSidecarUnreadable, err)
	}
	return v == "1", nil
}

// repointLockMetrics points the lock-metrics sink back at d's file.
func repointLockMetrics(d *db.DB) {
	if path, err := mainFile(context.Background(), d); err == nil {
		lockmetrics.Configure(path)
	}
}

// Dir is the hub dir the `hub …` CLI works in: WATCHTOWER_HUB_DIR when set
// (test mode), else DefaultDir on a headless host (live mode), else
// ErrDesktopHost. Nothing is created.
func Dir(p hostkind.Probe) (dir string, mode Mode, err error) {
	if dir := os.Getenv(EnvHubDir); dir != "" {
		return dir, ModeTest, nil
	}
	if k, _ := hostkind.Detect(p); k == hostkind.Desktop {
		return "", ModeOff, ErrDesktopHost
	}
	dir, err = DefaultDir()
	if err != nil {
		return "", ModeOff, err
	}
	return dir, ModeLive, nil
}

// OffReason is the reason the daemon's hub in mode would stay off before it
// writes any status ("" = none): not_test_workspace in test mode; disabled,
// policy_off, no_relay_origin (or sidecar_unreadable) in live mode. `hub
// status` shows it for a hub that is off.
func OffReason(cfg *config.Config, mode Mode) string {
	switch mode {
	case ModeTest:
		if _, _, err := FromEnv(cfg, nil); errors.Is(err, ErrNotTestWorkspace) {
			return ReasonNotTestWorkspace
		}
	case ModeLive:
		if _, _, err := liveGate(cfg); err != nil {
			return Refusal(err)
		}
	case ModeOff: // no hub dir: nothing to add
	}
	return ""
}
