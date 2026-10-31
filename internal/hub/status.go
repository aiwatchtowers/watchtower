package hub

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"syscall"
)

// statusFileName is the runtime's status file in the hub dir, rewritten
// whole (0600) on every change, so a reader never opens the sidecar.
const statusFileName = "status.json"

// The hub's states.
const (
	StateOff      = "off"
	StateStarting = "starting"
	StateRunning  = "running"
)

// The reasons a status carries (empty when there is nothing to say).
const (
	ReasonDisabled          = "disabled"
	ReasonPolicyOff         = "policy_off"
	ReasonLocked            = "locked"
	ReasonNotTestWorkspace  = "not_test_workspace"
	ReasonSidecarUnreadable = "sidecar_unreadable"
	ReasonNotAdmitted       = "not_admitted"
	ReasonRelayUnreachable  = "relay_unreachable"
	// ReasonStartFailed: a start step failed that is neither the sidecar
	// nor the relay (state starting, retried with backoff).
	ReasonStartFailed = "start_failed"
)

// Status is what `hub status` shows. Its JSON keys are the CLI's pinned keys.
type Status struct {
	State         string `json:"state"`
	Reason        string `json:"reason"`
	HubID         string `json:"hub_id"`
	RelayDeviceID string `json:"relay_device_id"`
	Transport     string `json:"transport"`
	Impl          string `json:"impl"`
	Dir           string `json:"dir"`
	Phones        int    `json:"phones"`
}

// statusFile is the status as the runtime writes it, with its pid so a
// reader can tell a status left behind by a process that died.
type statusFile struct {
	Status
	PID int    `json:"pid"`
	Run string `json:"run"`
}

// ReadStatus reads the runtime's status for dir without touching the sidecar
// or the lock. No status file reads as off with no reason (no hub ever ran
// there); a status written by a process that is gone reads as off too, its
// identity fields kept.
func ReadStatus(dir string) (Status, error) {
	if !filepath.IsAbs(dir) {
		return Status{}, ErrDirNotAbsolute
	}
	f, err := readStatusFile(dir)
	if errors.Is(err, fs.ErrNotExist) {
		return Status{State: StateOff, Dir: dir}, nil
	}
	if err != nil {
		return Status{}, err
	}
	f.Dir = dir
	if f.State != StateOff && !processAlive(f.PID) {
		f.State, f.Reason = StateOff, ""
	}
	return f.Status, nil
}

// readStatusFile reads dir's status file as written.
func readStatusFile(dir string) (statusFile, error) {
	raw, err := os.ReadFile(filepath.Join(dir, statusFileName))
	if err != nil {
		return statusFile{}, fmt.Errorf("hub: reading the status: %w", err)
	}
	var f statusFile
	if err := json.Unmarshal(raw, &f); err != nil {
		return statusFile{}, fmt.Errorf("hub: reading the status: %w", err)
	}
	return f, nil
}

// processAlive reports whether pid names a live process (EPERM: alive, not
// ours to signal).
func processAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

// writeStatusRun replaces dir's status file atomically (a 0600 temp file in
// the same dir, renamed over it), stamped with this process and run.
func writeStatusRun(dir string, s Status, run string) error {
	b, err := json.Marshal(statusFile{Status: s, PID: os.Getpid(), Run: run})
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".status-*")
	if err != nil {
		return fmt.Errorf("hub: writing the status: %w", err)
	}
	name := tmp.Name()
	defer func() { _ = os.Remove(name) }()
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("hub: writing the status: %w", err)
	}
	if _, err := tmp.Write(b); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("hub: writing the status: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("hub: writing the status: %w", err)
	}
	if err := os.Rename(name, filepath.Join(dir, statusFileName)); err != nil {
		return fmt.Errorf("hub: writing the status: %w", err)
	}
	return nil
}
