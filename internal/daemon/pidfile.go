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
// actual test binary being named that. SetIdentityReaderForTest exposes
// this same seam to another package's tests (cmd's signalling-refusal
// tests), which cannot reach this unexported var directly.
var readProcessIdentity = readProcessIdentityOS

// ProcessIdentity is the exported shape of a live process's identity, for
// SetIdentityReaderForTest only. Production code never constructs this
// type — internal/daemon's own tests use the private processIdentity type
// and the readProcessIdentity var directly.
type ProcessIdentity struct {
	StartTime time.Time
	Comm      string
}

// SetIdentityReaderForTest overrides how FindProcess/FindConfirmedProcess
// read a pid's OS-recorded identity. TEST-ONLY: no production code calls
// this. It exists because readProcessIdentity itself is unexported, so a
// test in another package (cmd's tests, which need a REAL subprocess whose
// identity read can be made to fail or match deterministically, to
// exercise FindConfirmedProcess's refusal end-to-end) cannot reach it
// directly. Returns a restore func the caller must invoke (typically via
// t.Cleanup) to put the real, GOOS-specific reader back.
func SetIdentityReaderForTest(fn func(pid int) (ProcessIdentity, error)) (restore func()) {
	old := readProcessIdentity
	readProcessIdentity = func(pid int) (processIdentity, error) {
		ident, err := fn(pid)
		if err != nil {
			return processIdentity{}, err
		}
		return processIdentity{startTime: ident.StartTime, comm: ident.Comm}, nil
	}
	return func() { readProcessIdentity = old }
}

// pidFileFormatTag marks a pid file's start-time field as an accurate
// kernel-recorded value — WritePID's normal path, where readProcessIdentity
// on the daemon's own pid succeeded — rather than merely a wall-clock stamp
// taken sometime after the process actually forked (every build before this
// tag existed, and WritePID's own rare fallback when the identity read
// itself fails at write time). identifyProcess uses a tight, symmetric
// tolerance for a tagged file and a looser, one-sided one for an untagged
// two-field file — see identifyProcess's doc comment for why conflating the
// two broke upgrades (an old daemon's pid file judged "reused" and deleted
// out from under it, because its stored value could legitimately be tens of
// seconds AFTER its real fork time, which a symmetric check can't tell
// apart from actual reuse).
const pidFileFormatTag = "kstart"

// PidFileFormatTag is pidFileFormatTag, exported so a test in another
// package (cmd's signalling-refusal tests, alongside
// SetIdentityReaderForTest) can construct a validly-tagged pid file without
// duplicating the literal. TEST-ONLY in practice: production code always
// goes through WritePID, never spells this out itself.
const PidFileFormatTag = pidFileFormatTag

// WritePID atomically writes the current process ID and its own OS-recorded
// start time to path, tagged (see pidFileFormatTag) when that start time is
// known to be accurate. It creates parent directories as needed. The start
// time enables stale PID detection even when the OS reuses the PID for an
// unrelated process: it is deliberately this process's own actual start
// time (read back via readProcessIdentity), not the wall-clock moment this
// function runs — the two can differ by however long config/DB setup takes
// before Daemon.Run calls WritePID. Falls back to an untagged, wall-clock
// timestamp if the identity read itself fails, so a transient read failure
// never blocks writing the PID file at all — an untagged value gets the
// looser compatibility check on read, which is the conservative choice for
// a value this function isn't confident about.
func WritePID(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("creating pid directory: %w", err)
	}

	pid := os.Getpid()
	startUnix := time.Now().Unix()
	tag := ""
	if ident, err := readProcessIdentity(pid); err == nil {
		startUnix = ident.startTime.Unix()
		tag = pidFileFormatTag
	}

	content := fmt.Sprintf("%d %d", pid, startUnix)
	if tag != "" {
		content = fmt.Sprintf("%s %s", content, tag)
	}
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
// Supports both legacy "PID" and new "PID TIMESTAMP [TAG]" formats.
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

// readPIDWithStart reads the PID, start timestamp, and format tag. Returns
// a zero startTime if the file uses the oldest (timestamp-less) legacy
// format; tagged is true only when a third field exactly matching
// pidFileFormatTag follows the timestamp (see WritePID/identifyProcess).
func readPIDWithStart(path string) (pid int, startTime time.Time, tagged bool, err error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return 0, time.Time{}, false, nil
		}
		return 0, time.Time{}, false, fmt.Errorf("reading pid file: %w", err)
	}
	fields := strings.Fields(string(data))
	if len(fields) == 0 {
		return 0, time.Time{}, false, fmt.Errorf("parsing pid file: empty")
	}
	pid, err = strconv.Atoi(fields[0])
	if err != nil {
		return 0, time.Time{}, false, fmt.Errorf("parsing pid file: %w", err)
	}
	if len(fields) >= 2 {
		if ts, parseErr := strconv.ParseInt(fields[1], 10, 64); parseErr == nil {
			startTime = time.Unix(ts, 0)
		}
	}
	if len(fields) >= 3 && fields[2] == pidFileFormatTag {
		tagged = true
	}
	return pid, startTime, tagged, nil
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
	// no identity signal was ever available to check, for the oldest
	// pre-timestamp pid file — kept for compatibility with an in-flight
	// upgrade, a narrower trust level than a verified match).
	processConfirmedSame
	// processUnknown: a live process exists at the stored pid, but its
	// identity could not be verified either way (the OS-level read failed
	// or returned something unparseable, and the process did not turn out
	// to be gone on a liveness re-check either). Neither confirmed-same
	// nor confirmed-reused — resolveProcess does NOT remove the file for
	// this state, and a signalling caller must not act on the pid either.
	processUnknown
)

// pidReuseTolerance bounds the allowed gap between a TAGGED pid file's
// stored start time and the live process's own OS-recorded start time.
// Both sides are the OS's own timestamp for the very same process at the
// very same moment in its life (WritePID records its own real start time
// for a tagged file — see WritePID's doc comment), so any real gap here is
// rounding/precision noise between the write and this later read, not
// daemon-startup slack. Symmetric (the process could be read either
// fractionally before or after the stored value, depending on which side
// of a second boundary each read landed on).
const pidReuseTolerance = 5 * time.Second

// legacyStartTolerance absorbs truncation for an UNTAGGED (pre-tag-format,
// or WritePID's rare identity-read-failure fallback) pid file's stored
// value: a whole-second wall-clock timestamp, floored, taken sometime AFTER
// the process's real fork — never before it. A genuinely same process's
// kernel start time can therefore appear up to just under 1s AFTER that
// floored value purely from the flooring itself; this adds a little more
// margin for read/clock jitter. It is deliberately one-sided (see
// identifyProcess): unlike pidReuseTolerance, there is no there-or-back
// symmetry to allow for here.
const legacyStartTolerance = 2 * time.Second

// resolveProcess reads the pid file, checks the process's liveness, and —
// when a start time was recorded — verifies identity via identifyProcess.
// It removes the pid file itself whenever it concludes processGone or
// processReused; it never removes it for processConfirmedSame or
// processUnknown, both of which leave "should this pid file be touched?"
// to the caller (FindProcess is lenient about processUnknown; a caller
// about to SIGNAL a process must not be — see FindConfirmedProcess).
func resolveProcess(path string) (int, processState, error) {
	pid, startTime, tagged, err := readPIDWithStart(path)
	if err != nil {
		return 0, processGone, err
	}
	if pid == 0 {
		return 0, processGone, nil
	}

	// Signal 0 checks process existence without sending a real signal. Its
	// error, if any, IS the answer ("no such process", or EPERM for a live
	// process now owned by another user — i.e. this pid was reused) rather
	// than a failure to propagate — the process being gone is not itself
	// an error condition for resolveProcess's caller.
	if killErr := syscall.Kill(pid, 0); killErr != nil {
		removeStalePIDFile(path)
		return 0, processGone, nil //nolint:nilerr // killErr ("no such process", or EPERM for a reused pid now owned by another user) IS the "gone" answer, not a failure to report
	}

	if startTime.IsZero() {
		// Oldest legacy PID file, with no stored start time at all: no
		// identity signal is available to check, so fall back to the
		// pre-existing 30-day mtime heuristic and otherwise trust it —
		// compatibility with an in-flight upgrade, not a claim that this
		// is as strong a check as the timestamped path below.
		info, statErr := os.Stat(path)
		if statErr == nil && time.Since(info.ModTime()) > 30*24*time.Hour {
			removeStalePIDFile(path)
			return 0, processGone, nil
		}
		return pid, processConfirmedSame, nil
	}

	switch identifyProcess(pid, startTime, tagged) {
	case processReused:
		removeStalePIDFile(path)
		return 0, processReused, nil
	case processUnknown:
		// The identity read failed. Re-check liveness before settling for
		// "unknown": the process may simply have exited in the narrow
		// window between the kill(pid, 0) call above and the identity
		// read — "gone" is both a more useful and a more correct answer
		// than "unknown" whenever it's actually true, and unlike the first
		// liveness check, getting this one wrong means a caller about to
		// signal the daemon refuses when it didn't need to.
		if killErr := syscall.Kill(pid, 0); killErr != nil {
			removeStalePIDFile(path)
			return 0, processGone, nil //nolint:nilerr // killErr here means the process exited between the identity read and this re-check — "gone", not a failure to report
		}
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
// two factors: its actual OS start time and, when the reader supplies one,
// its command name (must contain "watchtower"). Both are checked because
// either alone has a known gap: a start-time-only check cannot
// special-case an empty/unavailable comm without also going blind on real
// reuse when a reader can't supply a name, and a comm-only check (the
// original, pre-this-whole-fix implementation) flags ANY non-watchtower-
// named process as reused — including this very process during a test
// run — while missing true reuse by another watchtower process.
//
// The start-time check itself is NOT symmetric for every pid file: tagged
// (see pidFileFormatTag) means storedStart is the kernel's own start time
// for THIS process, recorded by a WritePID that could read it back
// immediately — any gap from a fresh read is just clock/read jitter in
// either direction, so pidReuseTolerance applies symmetrically. An
// untagged file's storedStart is a wall-clock stamp taken sometime AFTER
// the real fork (every build before the tag existed, and WritePID's own
// rare identity-read-failure fallback) — it can legitimately be tens of
// seconds or more LATER than the true start (a slow daemon startup: db
// migrations, OAuth/HTTP calls before the network is up, ...), so a
// symmetric check on an untagged file would misjudge a slow-starting but
// perfectly legitimate daemon as reused and delete its pid file out from
// under it — exactly the bug an earlier version of this fix introduced.
// The correct check for an untagged file is one-sided: the SAME process's
// kernel start can only be AT OR BEFORE storedStart (never after, plus a
// little slack for the wall-clock value's own flooring); a truly reused
// pid's new occupant, by definition, can only have forked AFTER
// storedStart was written (which is itself after the ORIGINAL process's
// fork) — so a kernel start meaningfully AFTER storedStart is reuse, and
// one at or before it never is. This ordering argument assumes the wall
// clock does not step backward between the write and a later reuse of the
// same pid by more than legacyStartTolerance (a manual clock set, or a
// large NTP correction after a long sleep): if it does, a since-reused pid
// whose new occupant happens to be comm-named "watchtower" too could be
// misjudged confirmed-same. The exposure is narrow (needs an untagged
// file, a backward step, AND a watchtower-named new occupant, all at
// once) and a tagged file has none of it at all, since it compares the
// same process's kernel start against itself rather than against a
// wall-clock write time.
//
// Returns processUnknown, never a guess, when the identity read itself
// fails — the read failing is a different kind of "I don't know" than "I
// looked and it doesn't match" (resolveProcess re-checks liveness before
// trusting this verdict — see its own doc comment).
func identifyProcess(pid int, storedStart time.Time, tagged bool) processState {
	ident, err := readProcessIdentity(pid)
	if err != nil {
		return processUnknown
	}

	commMatches := ident.comm == "" || strings.Contains(ident.comm, "watchtower")
	if !commMatches {
		return processReused
	}

	if tagged {
		diff := ident.startTime.Sub(storedStart)
		if diff < 0 {
			diff = -diff
		}
		if diff <= pidReuseTolerance {
			return processConfirmedSame
		}
		return processReused
	}

	// Untagged: one-sided. ident.startTime meaningfully AFTER storedStart
	// means this pid's current occupant forked later than the file's
	// author possibly could have — reuse. At or before it (including any
	// negative gap, the ordinary case) is exactly what a genuinely
	// slow-starting same process looks like.
	if ident.startTime.Sub(storedStart) <= legacyStartTolerance {
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
