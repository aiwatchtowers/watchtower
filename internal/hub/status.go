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
	// StatePaused: a headless hub with no paying phone (spec §7.3) keeps
	// its state and local work, publishes nothing and applies no action;
	// pairing goes on.
	StatePaused = "paused"
)

// The reasons a status carries (empty when there is nothing to say).
const (
	ReasonDisabled          = "disabled"
	ReasonPolicyOff         = "policy_off"
	ReasonLocked            = "locked"
	ReasonNotTestWorkspace  = "not_test_workspace"
	ReasonSidecarUnreadable = "sidecar_unreadable"
	// ReasonNotAdmitted: in a slot, but no phone holding the hub pays.
	ReasonNotAdmitted = "not_admitted"
	// ReasonNotVouched: in no phone's slot yet; only pairing goes on.
	ReasonNotVouched = "not_vouched"
	// ReasonVouchRevoked: in no slot any more after an admission.
	ReasonVouchRevoked     = "vouch_revoked"
	ReasonRelayUnreachable = "relay_unreachable"
	// ReasonNeedsRelay: paused, no phone holding the hub in a slot pays
	// (the phone shows "This hub needs Relay").
	ReasonNeedsRelay = "needs_relay"
	// ReasonStartFailed: a start step failed that is neither the sidecar
	// nor the relay (state starting, retried with backoff).
	ReasonStartFailed = "start_failed"
	// ReasonNoRelayOrigin: no (valid) relay origin is set.
	ReasonNoRelayOrigin = "no_relay_origin"
	// ReasonRunDirUnusable: the session-host socket folder is unusable.
	ReasonRunDirUnusable = "run_dir_unusable"
	// ReasonAwaitingAdoption: a desktop host whose Swift hub state is not
	// adopted yet (or whose keys are not handed over): no Go hub runs
	// beside it (spec §12.1, never two hubs).
	ReasonAwaitingAdoption = "awaiting_adoption"
	// ReasonAdoptionFailed: the adoption stopped with an error class
	// (hub_meta.adopt_error); Desktop retries it.
	ReasonAdoptionFailed = "adoption_failed"
	// ReasonSessionHostV1: a v1 session host (an older app's) still runs
	// the sessions; the hub waits for the v2 host.
	ReasonSessionHostV1 = "session_host_v1"
	// ReasonBridgeUnavailable: a desktop host whose build has no CloudKit
	// bridge and which has no relay origin either: no transport to run.
	ReasonBridgeUnavailable = "bridge_unavailable"
	// ReasonSwiftBesideGo: a Go hub ran first (its sidecar never adopted)
	// and a Swift hub's state appeared beside it; the adoption refuses that
	// state, and no hub runs until the owner chooses (ask #949, pending).
	ReasonSwiftBesideGo = "swift_beside_go"
)

// Status.Adoption values: where the Swift hub's adoption stands.
const (
	AdoptionNone       = "none"
	AdoptionInProgress = "in_progress"
	AdoptionFailed     = "failed"
	AdoptionDone       = "done"
)

// Status.Bridge values on a desktop host ("" elsewhere): the CloudKit
// bridge runs, is being (re)started, or this build has none.
const (
	BridgeRunning     = "running"
	BridgeRestarting  = "restarting"
	BridgeUnavailable = "unavailable"
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
	// Host is the host kind (desktop, headless; "" when not known) and
	// Mode the hub's mode (test, live; "" = off).
	Host string `json:"host"`
	Mode string `json:"mode"`
	// Adoption is where the Swift hub's adoption stands (Adoption*), Bridge
	// the CloudKit bridge on a desktop host (Bridge*, "" elsewhere),
	// Identity the identity store (keychain|file; "" when not known), and
	// SwitchedAt (RFC 3339, "" = never) / SwitchedBy the last transport
	// switch (a device id or entitlement_expired).
	Adoption   string `json:"adoption"`
	Bridge     string `json:"bridge"`
	Identity   string `json:"identity"`
	SwitchedAt string `json:"switched_at"`
	SwitchedBy string `json:"switched_by"`
	// CloudKit is the iCloud facts on a desktop host (desktop_facts.go).
	CloudKit CloudKitStatus `json:"cloudkit"`
	// OffDelete is the owner's off wipe while the switch is off (off_delete.go).
	OffDelete OffDeleteStatus `json:"off_delete"`
	// Relay is the hosted relay's indicators (relayhealth.go), absent when
	// the hub has no relay.
	Relay *RelayHealth `json:"relay,omitempty"`
	// PayingPhones is the linked phones (device ids) the relay lists as
	// paying; empty unless the active transport is the relay, and null when
	// it is not known (no hub runs, no account state read yet, or forgotten
	// after HUB_NOT_VOUCHED): unknown is never "not paying".
	PayingPhones []string `json:"paying_phones"`
	// MailboxFullPhones is the linked phones (device ids) whose relay mailbox
	// refused a write as over quota, each until a write to that phone's
	// mailbox succeeds or it is unlinked (kept in hub_meta across restarts).
	MailboxFullPhones []string `json:"mailbox_full_phones"`
}

// RelayHealth is the hosted relay's indicators in the status (RC §10).
type RelayHealth struct {
	// State is connected | connecting (no connection for less than 60 s) |
	// unavailable (60 s or more); Since (RFC 3339) when it began.
	State string `json:"state"`
	Since string `json:"since"`
	// QuotaHub: the hub's data zone refused a save as over quota; cleared by
	// its next successful save.
	QuotaHub bool `json:"quota_hub"`
	// PushOff: the newest relay answer to send_alert that tells the push
	// configuration said pushes are off (state.Store.PushOff).
	PushOff bool `json:"push_off"`
	// LastSavedAt is the last successful data-zone save (RFC 3339, "" = none
	// since the hub started).
	LastSavedAt string `json:"last_saved_at"`
}

// withLists gives s's mailbox list its empty value, so it shows as [] and
// compares equal (PayingPhones keeps nil: unknown).
func (s Status) withLists() Status {
	if s.MailboxFullPhones == nil {
		s.MailboxFullPhones = []string{}
	}
	return s
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
		return Status{State: StateOff, Dir: dir}.withLists(), nil
	}
	if err != nil {
		return Status{}, err
	}
	f.Dir = dir
	if f.State != StateOff && !processAlive(f.PID) {
		// The runtime's live facts went with it.
		f.State, f.Reason, f.Relay, f.PayingPhones, f.MailboxFullPhones = StateOff, "", nil, nil, nil
	}
	return f.withLists(), nil
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
