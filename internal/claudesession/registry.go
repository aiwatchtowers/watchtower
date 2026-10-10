// Package claudesession reads Claude Code's local session registry and the
// subagent transcripts of a session (pure reads: no DB, no network). Both are
// Claude Code internals, not a documented API: every reader here degrades to
// "not found" rather than an error, and callers treat not found as gone.
package claudesession

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// ConfigDir is Claude Code's config dir: $CLAUDE_CONFIG_DIR when set, else
// ~/.claude ("" when the home dir is unknown).
func ConfigDir(env func(string) string) string {
	if dir := env("CLAUDE_CONFIG_DIR"); dir != "" {
		return dir
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".claude")
}

// Entry is one running Claude Code process's registry entry
// (<config dir>/sessions/<pid>.json). Status is raw: "busy", "idle", or
// anything else; "" means the entry predates its first status update, which is
// neither busy nor idle. StatusUpdatedAt is zero in that case.
type Entry struct {
	PID                 int
	SessionID           string
	Status              string
	Version             string
	MessagingSocketPath string
	ProcStart           string
	PeerProtocol        int
	PeerFeatures        []string
	StatusUpdatedAt     time.Time
}

type entryJSON struct {
	PID                 int      `json:"pid"`
	SessionID           string   `json:"sessionId"`
	Status              string   `json:"status"`
	Version             string   `json:"version"`
	MessagingSocketPath string   `json:"messagingSocketPath"`
	ProcStart           string   `json:"procStart"`
	PeerProtocol        int      `json:"peerProtocol"`
	PeerFeatures        []string `json:"peerFeatures"`
	StatusUpdatedAt     int64    `json:"statusUpdatedAt"` // epoch ms
}

// FindSession returns the registry entry of sessionID. Only *.json files are
// read (the <pid>.<hash>.key beside each entry never is); an unreadable or
// undecodable file is skipped. No match, or no sessions dir, is (_, false, nil).
func FindSession(configDir, sessionID string) (Entry, bool, error) {
	if sessionID == "" {
		return Entry{}, false, nil
	}
	matches, err := filepath.Glob(filepath.Join(configDir, "sessions", "*.json"))
	if err != nil {
		return Entry{}, false, err
	}
	for _, path := range matches {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var raw entryJSON
		if json.Unmarshal(data, &raw) != nil || raw.SessionID != sessionID {
			continue
		}
		e := Entry{
			PID:                 raw.PID,
			SessionID:           raw.SessionID,
			Status:              raw.Status,
			Version:             raw.Version,
			MessagingSocketPath: raw.MessagingSocketPath,
			ProcStart:           raw.ProcStart,
			PeerProtocol:        raw.PeerProtocol,
			PeerFeatures:        raw.PeerFeatures,
		}
		if raw.StatusUpdatedAt > 0 {
			e.StatusUpdatedAt = time.UnixMilli(raw.StatusUpdatedAt)
		}
		return e, true, nil
	}
	return Entry{}, false, nil
}

// ProcInfo is the process table seam for AliveWith: SystemProcs in
// production, a fake in tests (callers outside this package included).
type ProcInfo interface {
	Exists(pid int) bool
	// Start is the process's start time as `ps -o lstart=` prints it in UTC.
	Start(pid int) (string, bool)
}

// Alive reports whether the entry's process still runs. When the entry
// carries a procStart, the live process's start time must match it, so a
// reused pid is not alive.
func Alive(e Entry) bool { return AliveWith(e, SystemProcs{}) }

// AliveWith is Alive over the process table p.
func AliveWith(e Entry, p ProcInfo) bool {
	if e.PID <= 0 || !p.Exists(e.PID) {
		return false
	}
	if e.ProcStart == "" {
		return true
	}
	started, ok := p.Start(e.PID)
	return ok && sameStart(started, e.ProcStart)
}

// sameStart compares two lstart strings ignoring whitespace runs (ps pads the
// day of month with a space).
func sameStart(a, b string) bool {
	return strings.Join(strings.Fields(a), " ") == strings.Join(strings.Fields(b), " ")
}

// psTimeout bounds one ps call.
const psTimeout = 2 * time.Second

// SystemProcs is the live process table: kill(pid, 0) and ps.
type SystemProcs struct{}

func (SystemProcs) Exists(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

func (SystemProcs) Start(pid int) (string, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), psTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "ps", "-o", "lstart=", "-p", strconv.Itoa(pid))
	// Claude Code writes procStart as ps prints it in UTC and the C locale
	// (checked against live entries on 2.1.295): the local zone would never
	// match on a machine outside UTC.
	cmd.Env = append(os.Environ(), "TZ=UTC", "LC_ALL=C")
	out, err := cmd.Output()
	if err != nil {
		return "", false
	}
	started := strings.TrimSpace(string(out))
	return started, started != ""
}
