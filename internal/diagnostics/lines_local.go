package diagnostics

import (
	"context"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/daemon"
	"watchtower/internal/policy"
	"watchtower/internal/sync"
)

// The lines built from local files, flags and syscalls (spec "Inputs, and
// what each does when it fails"). Each returns its value without the line
// label (the Slot adds it) and never an error text, name or path (DIAG-01).

// Flavor maps the build flavor to what the report may print: `default` for
// an empty or exactly "dev" flavor, `corp` for anything else — the rule of
// HubIdentity.flavor(buildFlavor:), pinned by testdata/
// report_problem_flavor_cases.json on both sides.
func Flavor(buildFlavor string) string {
	if buildFlavor == "" || buildFlavor == "dev" {
		return FlavorDefault
	}
	return FlavorCorp
}

// Build is the binary's build info plus the app's --app-version ("" from a
// terminal). Flavor is the raw build flavor; it is never printed.
type Build struct{ Version, Commit, Flavor, AppVersion string }

// VersionLine is the first line and the JSON `flavor`.
func VersionLine(b Build) (text, flavor string) {
	flavor = Flavor(b.Flavor)
	return Version(b.Version, b.Commit, flavor, b.AppVersion), flavor
}

var (
	// macOSVersionRe accepts only a dotted number, so nothing else a
	// sysctl could return reaches the report.
	macOSVersionRe = regexp.MustCompile(`^\d+(\.\d+){0,2}$`)
	// appleChipRe is the brand of an Apple silicon Mac; Pro/Max/Ultra are
	// dropped because the form's options are `Apple M1`…`Apple M5`.
	appleChipRe = regexp.MustCompile(`^Apple M([1-5])(?: (?:Pro|Max|Ultra))?$`)
)

// MachineLine is `macOS <x.y> · <chip>` plus the JSON `macos` and `chip`.
// sysctl reads one string key (unix.Sysctl in production); a failed or
// unexpected value prints `macOS unknown` / `Other`.
func MachineLine(sysctl func(string) (string, error)) (text, macos, chip string) {
	macos = MacOSUnknown
	if v, err := sysctl("kern.osproductversion"); err == nil {
		if v = strings.TrimSpace(v); macOSVersionRe.MatchString(v) {
			macos = MacOS(v)
		}
	}
	chip = ChipOther
	if v, err := sysctl("machdep.cpu.brand_string"); err == nil {
		if m := appleChipRe.FindStringSubmatch(strings.TrimSpace(v)); m != nil {
			n, _ := strconv.Atoi(m[1])
			chip = ChipApple(n)
		}
	}
	return JoinParts(macos, chip), macos, chip
}

// syncProgressFile is the daemon's live heartbeat beside last_sync.json.
const syncProgressFile = "sync_progress.json"

// DaemonLine is `<process state> · <last cycle>`. peek is
// daemon.PeekProcess in production (it never removes or writes the pid
// file). The last cycle comes from last_sync.json; it is `running` instead
// of done/error while the daemon is confirmed running and its live
// heartbeat (sync_progress.json in the same folder) says a sync is in
// progress, with the age counted from that sync's start.
func DaemonLine(pidPath, lastSyncPath string, now time.Time,
	peek func(string) (int, daemon.PeekState, error),
) string {
	_, state, err := peek(pidPath)
	return JoinParts(daemonState(state, err), lastCycle(lastSyncPath, now, state == daemon.PeekRunning && err == nil))
}

func daemonState(state daemon.PeekState, err error) string {
	switch {
	case err != nil && errors.Is(err, fs.ErrPermission):
		return DaemonPIDUnreadablePermission
	case err != nil && strings.HasPrefix(err.Error(), "parsing pid file"):
		return DaemonPIDCorrupt
	case err != nil:
		return DaemonPIDUnreadableOther
	}
	switch state {
	case daemon.PeekNone:
		return DaemonStopped
	case daemon.PeekRunning:
		return DaemonRunning
	case daemon.PeekGone, daemon.PeekReused:
		return DaemonStalePIDFile
	default: // daemon.PeekUnknown
		return DaemonNotConfirmed
	}
}

func lastCycle(lastSyncPath string, now time.Time, daemonRunning bool) string {
	if daemonRunning {
		p, err := sync.ReadSyncProgress(filepath.Join(filepath.Dir(lastSyncPath), syncProgressFile))
		if err == nil && p.IsSyncing(now) && !p.StartedAt.IsZero() {
			return LastCycle(Age(now.Sub(p.StartedAt)), CycleRunning)
		}
	}
	r, err := sync.ReadSyncResult(lastSyncPath)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return NoCycleYet
	case err != nil || r.FinishedAt.IsZero():
		return LastCycleUnknown
	case r.Error != "":
		return LastCycle(Age(now.Sub(r.FinishedAt)), CycleError)
	default:
		return LastCycle(Age(now.Sub(r.FinishedAt)), CycleDone)
	}
}

// SyncRow is the Recent errors row for the last sync in last_sync.json:
// `  <time>  sync  <class>` when it failed, `  sync result unknown` when the
// file cannot be read or parsed; ok is false (no row) when the file is
// missing or the last sync succeeded. The error text is only classified.
func SyncRow(lastSyncPath string) (row string, ok bool) {
	r, err := sync.ReadSyncResult(lastSyncPath)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return "", false
	case err != nil:
		return SyncResultUnknown, true
	case r.Error == "":
		return "", false
	case r.FinishedAt.IsZero():
		return SyncResultUnknown, true
	default:
		return RecentErrorRow(r.FinishedAt, RecentErrorPhaseSync, ErrorClass(r.Error)), true
	}
}

// LogsLine is `watchtower.log <size> · daemon.log <size> (not attached)`
// from os.Stat of the files in the workspace folder dir: a missing file
// prints `missing`, any other failure or a non-regular file `unreadable`.
func LogsLine(dir string) string {
	return JoinParts(logSize(dir, LogWatchtower), logSize(dir, LogDaemon)) + LogsNotAttached
}

func logSize(dir, name string) string {
	st, err := os.Stat(filepath.Join(dir, name))
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return LogSize(name, LogMissing)
	case err != nil || !st.Mode().IsRegular():
		return LogSize(name, LogUnreadable)
	default:
		return LogSize(name, Size(st.Size()))
	}
}

// CrashLine is the Crash line's value and its reason: ReasonLogScan when
// the scan stopped at its budget (the MB count is shown only then).
func CrashLine(c CrashScan) (text, reason string) {
	if c.NoLogs {
		return UnknownNoLogs, ""
	}
	if c.Stopped {
		reason = ReasonLogScan
	}
	if c.Count == 0 {
		if c.Stopped {
			return CrashNoneScanStopped(c.ScannedMB), reason
		}
		return CrashNone, ""
	}
	place := c.Place
	if place == "" {
		place = CrashLocationUnknown
	}
	if c.TimeKnown {
		text = CrashFound(c.Count, FormatTime(c.Time), place)
	} else {
		text = CrashFoundTimeUnknown(c.Count, place)
	}
	if c.Stopped {
		text += CrashScanStopped(c.ScannedMB)
	}
	return text, reason
}

// crashLogFiles are the scanned logs in ScanCrashes' tie order.
var crashLogFiles = []string{LogWatchtower, LogWatchtower + ".1", LogDaemon}

// CrashPart scans the workspace folder dir's logs under b.LogScan, counted
// from the part's start, and prints CrashLine. now is time.Now in
// production.
func CrashPart(dir string, b Budgets, now func() time.Time) Part {
	return func(context.Context) (string, string) {
		files := make([]string, len(crashLogFiles))
		for i, name := range crashLogFiles {
			files[i] = filepath.Join(dir, name)
		}
		return CrashLine(ScanCrashes(files, now().Add(b.LogScan), now, time.Local))
	}
}

// PolicyPart is `managed by organization: yes|yes (with errors)|no` from
// a policy snapshot (policy.Current()).
func PolicyPart(p policy.Policy) string {
	switch {
	case !p.Managed:
		return Managed(ManagedNo)
	case len(p.Errors) > 0:
		return Managed(ManagedYesWithErrors)
	default:
		return Managed(ManagedYes)
	}
}

// IPhonePart is `iPhone companion on|off` from the Desktop's --iphone
// flag; "" (part left out) when the flag is absent or not on/off.
func IPhonePart(flag string) string {
	switch flag {
	case OptionOn, OptionOff:
		return IPhone(flag)
	default:
		return ""
	}
}
