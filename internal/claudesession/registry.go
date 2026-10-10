// Package claudesession reads Claude Code's local session registry (pure
// reads: no DB, no network). It is a Claude Code internal, not a documented
// API: an entry it cannot match degrades to "not found", and callers treat
// not found as gone; a registry or process table that cannot answer at all is
// an error.
package claudesession

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
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

// FindSessionWith returns the registry entry of sessionID under configDir,
// checking liveness against the process table p. Only regular *.json files
// are read (the <pid>.<hash>.key beside each entry never is); an unreadable
// or undecodable file is skipped, but when every *.json file is, the registry
// is unreadable and that is an error, not "not found". No match, or no
// sessions dir, is (_, false, nil). Several entries can carry one session id
// (a stale file left by a crash, then a --resume under a new pid): a live one
// wins over a dead one, then the newest statusUpdatedAt.
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
	jsonFiles, decoded := 0, 0
	for _, f := range files {
		if !f.Type().IsRegular() || !strings.HasSuffix(f.Name(), ".json") {
			continue
		}
		jsonFiles++
		e, ok := readEntry(filepath.Join(dir, f.Name()))
		if !ok {
			continue
		}
		decoded++
		if e.SessionID == sessionID {
			matches = append(matches, e)
		}
	}
	if jsonFiles > 0 && decoded == 0 {
		return Entry{}, false, fmt.Errorf("none of the %d registry files in %s could be read", jsonFiles, dir)
	}
	switch len(matches) {
	case 0:
		return Entry{}, false, nil
	case 1:
		return matches[0], true, nil
	}
	best := matches[0]
	bestAlive, err := AliveWith(best, p)
	if err != nil {
		return Entry{}, false, err
	}
	for _, e := range matches[1:] {
		eAlive, err := AliveWith(e, p)
		if err != nil {
			return Entry{}, false, err
		}
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
	// An error means the table could not answer (a timeout, a failed fork,
	// a non-zero exit), never that the process is gone.
	Start(pid int) (string, error)
}

// AliveWith reports whether the entry's process still runs in the process
// table p. When the entry carries a procStart, the live process's start time
// must match it, so a reused pid is not alive. An error means liveness is
// unknown: callers must not read it as dead.
func AliveWith(e Entry, p ProcInfo) (bool, error) {
	if e.PID <= 0 || !p.Exists(e.PID) {
		return false, nil
	}
	if e.ProcStart == "" {
		return true, nil
	}
	started, err := p.Start(e.PID)
	if err != nil {
		return false, err
	}
	return sameStart(started, e.ProcStart), nil
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

// Start runs ps. A pid that exited after Exists makes ps exit non-zero too:
// that is an error here, and the caller's next probe sees it gone.
func (SystemProcs) Start(pid int) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), psTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "ps", "-o", "lstart=", "-p", strconv.Itoa(pid))
	// Claude Code writes procStart as ps prints it in UTC and the C locale
	// (checked against live entries on 2.1.295): the local zone would never
	// match on a machine outside UTC.
	cmd.Env = append(os.Environ(), "TZ=UTC", "LC_ALL=C")
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("ps -p %d: %w", pid, err)
	}
	return strings.TrimSpace(string(out)), nil
}
