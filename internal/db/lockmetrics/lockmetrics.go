// Package lockmetrics records slow SQLite write-lock waits and holds, busy
// errors and WAL samples as JSON lines in <workspace>/dblock.jsonl, next to
// the DB file. Every Watchtower process (daemon, MCP server, hooks, CLI
// commands) appends to the same file; the Desktop app writes the same format
// from Swift, and `watchtower db lockstats` reads it.
//
// The sink is best effort: it never returns an error, never panics and warns
// at most once per process, so a metrics failure can never break a DB write.
package lockmetrics

import (
	"encoding/json"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
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
	// DefaultThreshold is the wait/hold at or above which a tx/exec is slow.
	DefaultThreshold = 200 * time.Millisecond
	// MaxFileBytes is the size past which the sink rotates to FileName+".1".
	MaxFileBytes = 10 << 20

	thresholdEnv = "WATCHTOWER_DBLOCK_THRESHOLD_MS"
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
		case raw == "":
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
	if dbPath == "" || dbPath == ":memory:" {
		sinkPath.Store(nil)
		return
	}
	p := filepath.Join(filepath.Dir(dbPath), FileName)
	sinkPath.Store(&p)
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

// appendLine opens the sink per call, so a file another process rotated
// away is never written again, and rotates it once it grows past the cap.
func appendLine(path string, line []byte) {
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		warn("open", path, err)
		return
	}
	// One write per line: O_APPEND keeps concurrent writers' lines whole.
	_, werr := f.Write(line)
	fi, serr := f.Stat()
	cerr := f.Close()
	switch {
	case werr != nil:
		warn("write", path, werr)
		return
	case cerr != nil:
		warn("close", path, cerr)
		return
	case serr != nil:
		warn("stat", path, serr)
		return
	}
	if fi.Size() > maxFileBytes {
		// Racing processes may each rename; the loser moves a fresh, small
		// file over .1 and a few lines are lost — never a torn one.
		// ENOENT means another process rotated first.
		if err := os.Rename(path, path+".1"); err != nil && !os.IsNotExist(err) {
			warn("rotate", path, err)
		}
	}
}

func warn(op, path string, err error) {
	warnOnce.Do(func() {
		slog.Warn("lockmetrics: "+op+" failed; further sink errors in this process are dropped",
			"path", path, "err", err)
	})
}
