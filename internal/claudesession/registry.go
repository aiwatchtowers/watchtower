// Package claudesession reads Claude Code's local session registry (pure
// reads: no DB, no network). It is a Claude Code internal, not a documented
// API: the reader degrades to "not found" rather than an error, and callers
// treat not found as gone.
package claudesession

import (
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Entry is one running Claude Code process's registry entry
// (<config dir>/sessions/<pid>.json). Status is raw: "busy", "idle", or
// anything else; "" means the entry predates its first status update, which is
// neither busy nor idle. StatusUpdatedAt is zero in that case.
type Entry struct {
	PID             int
	SessionID       string
	Status          string
	Version         string
	ProcStart       string
	StatusUpdatedAt time.Time
}

type entryJSON struct {
	PID             int    `json:"pid"`
	SessionID       string `json:"sessionId"`
	Status          string `json:"status"`
	Version         string `json:"version"`
	ProcStart       string `json:"procStart"`
	StatusUpdatedAt int64  `json:"statusUpdatedAt"` // epoch ms
}

// FindSession returns the registry entry of sessionID. Only regular *.json files are
// read (the <pid>.<hash>.key beside each entry never is); an unreadable or
// undecodable file is skipped. No match, or no sessions dir, is (_, false, nil).
// Several entries can carry one session id (a stale file left by a crash, then
// a --resume under a new pid): a live one wins over a dead one, then the
// newest statusUpdatedAt.
func FindSession(configDir, sessionID string) (Entry, bool, error) {
	return FindSessionWith(configDir, sessionID, SystemProcs{})
}

// FindSessionWith is FindSession over the process table p.
func FindSessionWith(configDir, sessionID string, p ProcInfo) (Entry, bool, error) {
	if sessionID == "" {
		return Entry{}, false, nil
	}
	// ReadDir, not Glob: the config dir is a path, not a pattern, and a `[`
	// in it must not change what is read.
	dir := filepath.Join(configDir, "sessions")
	files, err := os.ReadDir(dir)
	if errors.Is(err, fs.ErrNotExist) {
		return Entry{}, false, nil
	}
	if err != nil {
		return Entry{}, false, err
	}
	var matches []Entry
	for _, f := range files {
		if f.IsDir() || !strings.HasSuffix(f.Name(), ".json") {
			continue
		}
		if e, ok := readEntry(filepath.Join(dir, f.Name())); ok && e.SessionID == sessionID {
			matches = append(matches, e)
		}
	}
	switch len(matches) {
	case 0:
		return Entry{}, false, nil
	case 1:
		return matches[0], true, nil
	}
	best, bestAlive := matches[0], AliveWith(matches[0], p)
	for _, e := range matches[1:] {
		eAlive := AliveWith(e, p)
		if (eAlive && !bestAlive) || (eAlive == bestAlive && e.StatusUpdatedAt.After(best.StatusUpdatedAt)) {
			best, bestAlive = e, eAlive
		}
	}
	return best, true, nil
}

func readEntry(path string) (Entry, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Entry{}, false
	}
	var raw entryJSON
	if json.Unmarshal(data, &raw) != nil {
		return Entry{}, false
	}
	e := Entry{
		PID:       raw.PID,
		SessionID: raw.SessionID,
		Status:    raw.Status,
		Version:   raw.Version,
		ProcStart: raw.ProcStart,
	}
	if raw.StatusUpdatedAt > 0 {
		e.StatusUpdatedAt = time.UnixMilli(raw.StatusUpdatedAt)
	}
	return e, true
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
