package daemon

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// DetachEnvKey is set in the child process to prevent re-exec loops.
const DetachEnvKey = "WATCHTOWER_DAEMON_DETACHED"

// processIdentity is a live process's OS-recorded start time and command
// name, as read by readProcessIdentity. comm is empty when the reader
// cannot determine it (the ps-based fallback reader treats that as
// best-effort, not fatal) — identifyProcess then skips the comm factor
// rather than failing an otherwise-matching identity over missing data.
type processIdentity struct {
	startTime time.Time
	comm      string
}

// readProcessIdentity reads pid's actual identity from the OS. A package
// var (not a plain function) — pointing at the GOOS-specific
// readProcessIdentityOS by default — so tests can stub an
// unavailable/unparseable read deterministically, and so a same-identity
// pin can supply a real "watchtower"-shaped comm without depending on the
// actual test binary being named that.
var readProcessIdentity = readProcessIdentityOS

// WritePID atomically writes the current process ID and its own OS-recorded
// start time to path. It creates parent directories as needed. The start
// time enables stale PID detection even when the OS reuses the PID for an
// unrelated process: it is deliberately this process's own actual start
// time (read back via readProcessIdentity), not the wall-clock moment this
// function runs — the two can differ by however long config/DB setup takes
// before Daemon.Run calls WritePID — so a later comparison against the
// same process's real start time needs only a small, precision-driven
// tolerance rather than betting on a bounded startup duration. Falls back
// to the wall-clock time if the identity read itself fails, so a transient
// read failure never blocks writing the PID file at all.
func WritePID(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("creating pid directory: %w", err)
	}

	pid := os.Getpid()
	startUnix := time.Now().Unix()
	if ident, err := readProcessIdentity(pid); err == nil {
		startUnix = ident.startTime.Unix()
	}

	content := fmt.Sprintf("%d %d", pid, startUnix)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(content), 0o600); err != nil {
		return fmt.Errorf("writing pid temp file: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("renaming pid file: %w", err)
	}
	return nil
}

// ReadPID reads the PID from path. Returns 0, nil if the file does not exist.
// Supports both legacy "PID" and new "PID TIMESTAMP" formats.
func ReadPID(path string) (int, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return 0, nil
		}
		return 0, fmt.Errorf("reading pid file: %w", err)
	}
	fields := strings.Fields(string(data))
	if len(fields) == 0 {
		return 0, fmt.Errorf("parsing pid file: empty")
	}
	pid, err := strconv.Atoi(fields[0])
	if err != nil {
		return 0, fmt.Errorf("parsing pid file: %w", err)
	}
	return pid, nil
}

// readPIDWithStart reads both PID and start timestamp. Returns 0 startTime if
// the file uses the legacy format (no timestamp).
func readPIDWithStart(path string) (int, time.Time, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return 0, time.Time{}, nil
		}
		return 0, time.Time{}, fmt.Errorf("reading pid file: %w", err)
	}
	fields := strings.Fields(string(data))
	if len(fields) == 0 {
		return 0, time.Time{}, fmt.Errorf("parsing pid file: empty")
	}
	pid, err := strconv.Atoi(fields[0])
	if err != nil {
		return 0, time.Time{}, fmt.Errorf("parsing pid file: %w", err)
	}
	var startTime time.Time
	if len(fields) >= 2 {
		if ts, err := strconv.ParseInt(fields[1], 10, 64); err == nil {
			startTime = time.Unix(ts, 0)
		}
	}
	return pid, startTime, nil
}

// processState classifies what resolveProcess concluded about a pid file's
// target process.
type processState int

const (
	// processGone: no process exists at the stored pid (or no pid file at
	// all). Safe to have removed the file, and resolveProcess already did.
	processGone processState = iota
	// processReused: a live process exists at the stored pid, but its
	// identity provably does not match what was recorded — the OS has
	// handed this pid to an unrelated process. resolveProcess already
	// removed the stale file.
	processReused
	// processConfirmedSame: a live process exists at the stored pid, and
	// its identity was positively verified against what was recorded (or
	// no identity signal was ever available to check, for a legacy
	// pre-timestamp pid file — kept for compatibility with an in-flight
	// upgrade, a narrower trust level than a verified match).
	processConfirmedSame
	// processUnknown: a live process exists at the stored pid, but its
	// identity could not be verified either way (the OS-level read failed
	// or returned something unparseable). Neither confirmed-same nor
	// confirmed-reused — resolveProcess does NOT remove the file for this
	// state, and a signalling caller must not act on the pid either.
	processUnknown
)

// pidReuseTolerance bounds the (now small) allowed gap between the stored
// start time and the live process's own OS-recorded start time. Both sides
// are the OS's own timestamp for the very same process at the very same
// moment in its life (WritePID records its own real start time, not a
// later wall-clock read — see WritePID's doc comment), so any real gap here
// is rounding/precision noise between the write and this later read, not
// daemon-startup slack.
const pidReuseTolerance = 5 * time.Second

// resolveProcess reads the pid file, checks the process's liveness, and —
// when a start time was recorded — verifies identity via identifyProcess.
// It removes the pid file itself whenever it concludes processGone or
// processReused; it never removes it for processConfirmedSame or
// processUnknown, both of which leave "should this pid file be touched?"
// to the caller (FindProcess is lenient about processUnknown;pidfile
// callers that are about to SIGNAL a process must not be — see
// FindConfirmedProcess).
func resolveProcess(path string) (int, processState, error) {
	pid, startTime, err := readPIDWithStart(path)
	if err != nil {
		return 0, processGone, err
	}
	if pid == 0 {
		return 0, processGone, nil
	}

	// Signal 0 checks process existence without sending a real signal. Its
	// error, if any, IS the answer ("no such process") rather than a
	// failure to propagate — the process being gone is not itself an
	// error condition for resolveProcess's caller.
	if killErr := syscall.Kill(pid, 0); killErr != nil {
		removeStalePIDFile(path)
		return 0, processGone, nil //nolint:nilerr // killErr just means "no such process" — not a failure to report
	}

	if startTime.IsZero() {
		// Legacy PID file without a stored start time: no identity signal
		// is available at all, so fall back to the pre-existing 30-day
		// mtime heuristic and otherwise trust it — compatibility with an
		// in-flight upgrade, not a claim that this is as strong a check as
		// the timestamped path below.
		info, statErr := os.Stat(path)
		if statErr == nil && time.Since(info.ModTime()) > 30*24*time.Hour {
			removeStalePIDFile(path)
			return 0, processGone, nil
		}
		return pid, processConfirmedSame, nil
	}

	switch identifyProcess(pid, startTime) {
	case processReused:
		removeStalePIDFile(path)
		return 0, processReused, nil
	case processUnknown:
		return pid, processUnknown, nil
	default:
		return pid, processConfirmedSame, nil
	}
}

func removeStalePIDFile(path string) {
	if rmErr := os.Remove(path); rmErr != nil && !errors.Is(rmErr, os.ErrNotExist) {
		fmt.Fprintf(os.Stderr, "warning: removing stale pid file: %v\n", rmErr)
	}
}

// identifyProcess compares pid's live identity against storedStart using
// two factors: its actual OS start time (matched within pidReuseTolerance)
// and, when the reader supplies one, its command name (must contain
// "watchtower"). Both are checked because either alone has a known gap: a
// start-time-only check cannot special-case an empty/unavailable comm
// without also going blind on real reuse when a reader can't supply a
// name, and a comm-only check (the pre-fix implementation) flags ANY
// non-watchtower-named process as reused — including this very process
// during a test run — while missing true reuse by another watchtower
// process. Returns processUnknown, never a guess, when the identity read
// itself fails — the read failing is a different kind of "I don't know"
// than "I looked and it doesn't match."
func identifyProcess(pid int, storedStart time.Time) processState {
	ident, err := readProcessIdentity(pid)
	if err != nil {
		return processUnknown
	}

	diff := ident.startTime.Sub(storedStart)
	if diff < 0 {
		diff = -diff
	}
	timeMatches := diff <= pidReuseTolerance
	commMatches := ident.comm == "" || strings.Contains(ident.comm, "watchtower")

	if timeMatches && commMatches {
		return processConfirmedSame
	}
	return processReused
}

// FindProcess reads the PID file and checks whether the process is alive.
// Returns the PID if the process exists, or 0 if no daemon is running.
// Stale PID files (process dead or PID confirmed reused by an unrelated
// process) are automatically removed. FindProcess is the LENIENT reader:
// when identity can't be positively verified either way
// (processUnknown — e.g. a transient identity-read failure), it still
// returns the pid, matching this function's long-standing contract for its
// read-only callers (status, kb, the "is a daemon already running" check
// before starting a new one). A caller about to SIGNAL the process must use
// FindConfirmedProcess instead, which fails safe on exactly this case.
func FindProcess(path string) (int, error) {
	pid, state, err := resolveProcess(path)
	if err != nil {
		return 0, err
	}
	if state == processGone || state == processReused {
		return 0, nil
	}
	return pid, nil
}

// ErrIdentityUnconfirmed is returned by FindConfirmedProcess when a pid
// file names a live process whose identity could not be positively
// verified (processUnknown) — e.g. a transient failure reading its actual
// OS start time. This is distinct from "no daemon is running": the pid
// names SOMETHING alive and inspectable with `ps -p <pid>`, it just isn't
// safe to conclude it is (or isn't) the watchtower daemon. Callers about to
// signal a process must treat this as "refuse and report clearly," not
// silently fall back to either "assume it's ours" or "assume nothing is
// running."
var ErrIdentityUnconfirmed = errors.New("process identity could not be confirmed")

// FindConfirmedProcess is FindProcess for a caller about to SIGNAL the
// daemon. It returns a pid only for processConfirmedSame; for
// processUnknown it returns (pid, ErrIdentityUnconfirmed) — the pid is
// still handed back so a caller can name it in an error message, but
// receiving a non-nil error here means "do not act on this pid." For
// processGone/processReused it returns (0, nil), same as FindProcess.
func FindConfirmedProcess(path string) (int, error) {
	pid, state, err := resolveProcess(path)
	if err != nil {
		return 0, err
	}
	switch state {
	case processConfirmedSame:
		return pid, nil
	case processUnknown:
		return pid, ErrIdentityUnconfirmed
	default:
		return 0, nil
	}
}

// RemovePID removes the PID file. It is a no-op if the file does not exist.
//
// The warnings here and in resolveProcess write to stderr directly rather
// than through a logger: both are shared with CLI commands (sync stop,
// status, kb) that have no daemon logger, they fire only on a failed
// remove, and the daemon process itself reaches only RemovePID, once at
// shutdown — so the few lines that land in daemon.log for a detached child
// cannot grow it.
func RemovePID(path string) {
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		fmt.Fprintf(os.Stderr, "warning: removing pid file: %v\n", err)
	}
}
