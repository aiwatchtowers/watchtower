// Package lockmetrics records slow SQLite write-lock waits and holds, busy
// errors and WAL samples as JSON lines in <workspace>/dblock.jsonl, next to
// the DB file. Every Watchtower process (daemon, MCP server, hooks, CLI
// commands) appends to the same file; the Desktop app writes the same format
// from Swift, and `watchtower db lockstats` reads it.
//
// The sink is best effort: it never returns an error, never panics and warns
// at most once per process, so a metrics failure can never break a DB write.
//
// Write protocol, shared with the Swift writer (any writer must follow it):
//   - Each line is one JSON object plus "\n", written with a single write()
//     on a file opened O_APPEND|O_CREAT|O_WRONLY, mode 0600, so concurrent
//     processes never interleave. "ts" is UTC with exactly three fractional
//     digits ("2026-10-15T10:00:00.123Z").
//   - A writer that keeps the file open stats the path before each write and
//     re-opens when the path is gone or names another inode.
//   - Rotation: once the file is over MaxFileBytes, a writer takes a
//     non-blocking exclusive flock on LockFileName (0600, same directory;
//     never deleted). Holding it, it re-stats the path and renames it to
//     FileName+".1" (replacing the previous generation) only if the path is
//     still the inode it saw over the cap and still over the cap. A writer
//     that cannot get the lock skips rotation and just appends. The re-check
//     under the lock is what keeps a second rotator from moving a fresh,
//     small file over the full generation another one just rotated.
package lockmetrics

import (
	"encoding/json"
	"errors"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// Event is one line of dblock.jsonl. The JSON keys are a contract shared
// with the Swift writer and `db lockstats`; do not rename them.
type Event struct {
	TS            time.Time `json:"ts"`   // UTC; filled by Record if zero
	PID           int       `json:"pid"`  // filled by Record
	Proc          string    `json:"proc"` // filled by Record from SetProcessRole
	Kind          string    `json:"kind"` // KindTx|KindExec|KindBusy|KindPoolWait|KindWAL
	WaitMS        int64     `json:"wait_ms,omitempty"`
	HoldMS        int64     `json:"hold_ms,omitempty"`
	Site          string    `json:"site,omitempty"`
	Err           string    `json:"err,omitempty"`
	BusyTimeoutMS int64     `json:"busy_timeout_ms,omitempty"`
	WALBytes      int64     `json:"wal_bytes,omitempty"`
	Checkpoint    string    `json:"checkpoint,omitempty"` // "busy=0 log=12 ckpt=12" for KindWAL
}

// MarshalJSON pins "ts" to UTC with exactly three fractional digits; the
// default time encoding drops a zero fraction, which a strict
// fractional-seconds parser (Swift's ISO8601DateFormatter) rejects.
func (e Event) MarshalJSON() ([]byte, error) {
	type plain Event // no methods: avoids recursing into MarshalJSON
	return json.Marshal(struct {
		TS string `json:"ts"`
		plain
	}{TS: e.TS.UTC().Format(tsLayout), plain: plain(e)})
}

// Event kinds.
const (
	KindTx       = "tx"
	KindExec     = "exec"
	KindBusy     = "busy"
	KindPoolWait = "pool_wait"
	KindWAL      = "wal"
)

const (
	// FileName is the sink's name; it lives next to the DB file.
	FileName = "dblock.jsonl"
	// LockFileName is the sidecar every writer flocks to rotate the sink.
	LockFileName = FileName + ".lock"
	// DefaultThreshold is the wait/hold at or above which a tx/exec is slow.
	DefaultThreshold = 200 * time.Millisecond
	// MaxFileBytes is the size past which the sink rotates to FileName+".1".
	MaxFileBytes = 10 << 20

	thresholdEnv = "WATCHTOWER_DBLOCK_THRESHOLD_MS"
	tsLayout     = "2006-01-02T15:04:05.000Z07:00" // fixed width; UTC renders "Z"
	defaultRole  = "cli"
)

type config struct {
	off       bool
	threshold time.Duration
}

var (
	settingsOnce sync.Once
	settings     config

	sinkPath atomic.Pointer[string] // nil = no sink configured
	role     atomic.Pointer[string] // nil = defaultRole

	// writeMu serializes this process's writes so two goroutines never both
	// rotate the same full file (the second rename would drop the first's
	// fresh file into .1). Other processes are covered by O_APPEND.
	writeMu      sync.Mutex
	maxFileBytes int64 = MaxFileBytes // guarded by writeMu; lowered by tests
	// The sink stays open between records (an open+close costs ~70 µs on
	// macOS, a stat ~2 µs). Guarded by writeMu.
	held     *os.File
	heldPath string
	heldFi   os.FileInfo

	warnOnce sync.Once
)

// loadSettings reads WATCHTOWER_DBLOCK_THRESHOLD_MS once per process: unset
// or empty → DefaultThreshold, an integer ≥ 0 → that many ms (0 logs every
// tx/exec), "off" → disabled; anything else → DefaultThreshold and a warning.
func loadSettings() config {
	settingsOnce.Do(func() {
		settings = config{threshold: DefaultThreshold}
		raw := strings.TrimSpace(os.Getenv(thresholdEnv))
		switch {
		case raw == "": // default
		case strings.EqualFold(raw, "off"):
			settings.off = true
		default:
			ms, err := strconv.ParseInt(raw, 10, 64)
			if err != nil || ms < 0 {
				slog.Warn("lockmetrics: invalid "+thresholdEnv+", using the default",
					"value", raw, "default_ms", DefaultThreshold.Milliseconds())
				return
			}
			settings.threshold = time.Duration(ms) * time.Millisecond
		}
	})
	return settings
}

// SetProcessRole names this process in every event: "daemon", "mcp",
// "hook:<subcommand>", "cli:<subcommand>". Unset, the role is "cli".
func SetProcessRole(r string) { role.Store(&r) }

// Configure points the sink at FileName in dbPath's directory. ":memory:" or
// "" disables it. Safe to call repeatedly; the last call wins.
func Configure(dbPath string) {
	writeMu.Lock()
	defer writeMu.Unlock()
	if dbPath == "" || dbPath == ":memory:" {
		sinkPath.Store(nil)
		closeHeld()
		return
	}
	p := filepath.Join(filepath.Dir(dbPath), FileName)
	sinkPath.Store(&p)
	if heldPath != p {
		closeHeld()
	}
}

// Enabled reports whether Record writes anything: a sink is configured and
// the env threshold is not "off".
func Enabled() bool {
	return !loadSettings().off && sinkPath.Load() != nil
}

// Threshold is the wait/hold at or above which a tx/exec event is recorded.
func Threshold() time.Duration { return loadSettings().threshold }

// Slow reports whether a tx/exec with this wait and hold should be recorded.
// It is false whenever the sink is disabled.
func Slow(wait, hold time.Duration) bool {
	if !Enabled() {
		return false
	}
	t := Threshold()
	return wait >= t || hold >= t
}

// Record appends e as one JSON line, filling TS (UTC), PID and Proc. It does
// not apply the threshold — callers check Slow first for tx/exec events. It
// never returns an error and never panics; the first failure in a process is
// logged once and later ones are dropped silently.
func Record(e Event) {
	if !Enabled() {
		return
	}
	path := sinkPath.Load()
	if path == nil { // reconfigured since Enabled
		return
	}
	if e.TS.IsZero() {
		e.TS = time.Now()
	}
	e.TS = e.TS.UTC()
	e.PID = os.Getpid()
	e.Proc = defaultRole
	if r := role.Load(); r != nil {
		e.Proc = *r
	}
	line, err := json.Marshal(e)
	if err != nil {
		warn("encode", *path, err)
		return
	}
	line = append(line, '\n')

	writeMu.Lock()
	defer writeMu.Unlock()
	appendLine(*path, line)
}

// appendLine writes one line through the held handle. Before each write it
// stats the path: a file another process rotated away (or deleted) is
// closed and the path re-opened, so a stale inode never keeps receiving
// lines; a file past the cap is rotated to .1 first.
func appendLine(path string, line []byte) {
	pfi, err := os.Stat(path)
	if held != nil && (heldPath != path || err != nil || !os.SameFile(heldFi, pfi)) {
		closeHeld()
	}
	if err == nil && pfi.Size() > maxFileBytes {
		rotate(path, pfi)
		closeHeld()
	}
	if held == nil {
		f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
		if err != nil {
			warn("open", path, err)
			return
		}
		fi, err := f.Stat()
		if err != nil {
			_ = f.Close() // the stat error is the one reported
			warn("stat", path, err)
			return
		}
		held, heldPath, heldFi = f, path, fi
	}
	// One write per line: O_APPEND keeps concurrent writers' lines whole.
	if _, err := held.Write(line); err != nil {
		warn("write", path, err)
		closeHeld()
	}
}

// rotate moves the full sink at path to .1 under the sidecar flock (see the
// package doc). seen is the stat that found it over the cap; the rename runs
// only if the path still names that inode and is still over the cap, so a
// process that lost the race never moves the fresh file over the generation
// the winner just rotated. A held lock means another writer is rotating:
// skip, never wait.
func rotate(path string, seen os.FileInfo) {
	lockPath := filepath.Join(filepath.Dir(path), LockFileName)
	lf, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		warn("open rotation lock", lockPath, err)
		return
	}
	defer func() { _ = lf.Close() }() // closing releases the flock
	if err := syscall.Flock(int(lf.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		if !errors.Is(err, syscall.EWOULDBLOCK) && !errors.Is(err, syscall.EINTR) {
			warn("lock for rotation", lockPath, err)
		}
		return
	}
	cur, err := os.Stat(path)
	if err != nil || !os.SameFile(cur, seen) || cur.Size() <= maxFileBytes {
		return // another writer rotated (or removed) it first
	}
	if err := os.Rename(path, path+".1"); err != nil {
		warn("rotate", path, err)
	}
}

// closeHeld drops the held handle; the next write re-opens the path.
// Caller holds writeMu.
func closeHeld() {
	if held == nil {
		return
	}
	if err := held.Close(); err != nil {
		warn("close", heldPath, err)
	}
	held, heldPath, heldFi = nil, "", nil
}

func warn(op, path string, err error) {
	warnOnce.Do(func() {
		slog.Warn("lockmetrics: "+op+" failed; further sink errors in this process are dropped",
			"path", path, "err", err)
	})
}
