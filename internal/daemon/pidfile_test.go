package daemon

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// stubProcessIdentity replaces readProcessIdentity for the duration of a
// test, restoring the real (GOOS-specific) reader in t.Cleanup. Used to pin
// identifyProcess/resolveProcess behavior deterministically — including
// cases (a real "watchtower"-named comm, an unparseable/unavailable read)
// that don't depend on what this test binary itself happens to be named or
// on the developer's locale.
func stubProcessIdentity(t *testing.T, fn func(pid int) (processIdentity, error)) {
	t.Helper()
	old := readProcessIdentity
	readProcessIdentity = fn
	t.Cleanup(func() { readProcessIdentity = old })
}

func TestWriteAndReadPID(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.pid")

	err := WritePID(path)
	require.NoError(t, err)

	pid, err := ReadPID(path)
	require.NoError(t, err)
	assert.Equal(t, os.Getpid(), pid)
}

func TestWritePID_CreatesDirectories(t *testing.T) {
	path := filepath.Join(t.TempDir(), "a", "b", "daemon.pid")

	err := WritePID(path)
	require.NoError(t, err)

	pid, err := ReadPID(path)
	require.NoError(t, err)
	assert.Equal(t, os.Getpid(), pid)
}

func TestReadPID_MissingFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nonexistent.pid")

	pid, err := ReadPID(path)
	require.NoError(t, err)
	assert.Equal(t, 0, pid)
}

func TestReadPID_InvalidContent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.pid")
	require.NoError(t, os.WriteFile(path, []byte("not-a-number"), 0o600))

	_, err := ReadPID(path)
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "parsing pid file")
}

func TestFindProcess_LiveProcess(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.pid")

	// Write our own PID — we know this process is alive.
	require.NoError(t, os.WriteFile(path, []byte(strconv.Itoa(os.Getpid())), 0o600))

	pid, err := FindProcess(path)
	require.NoError(t, err)
	assert.Equal(t, os.Getpid(), pid)
}

func TestFindProcess_StalePID(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.pid")

	// Use a PID that almost certainly doesn't exist.
	require.NoError(t, os.WriteFile(path, []byte("999999999"), 0o600))

	pid, err := FindProcess(path)
	require.NoError(t, err)
	assert.Equal(t, 0, pid, "stale PID should return 0")

	// Stale file should be cleaned up.
	_, statErr := os.Stat(path)
	assert.True(t, os.IsNotExist(statErr), "stale PID file should be removed")
}

func TestFindProcess_MissingFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nonexistent.pid")

	pid, err := FindProcess(path)
	require.NoError(t, err)
	assert.Equal(t, 0, pid)
}

func TestRemovePID(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.pid")
	require.NoError(t, os.WriteFile(path, []byte("12345"), 0o600))

	RemovePID(path)

	_, err := os.Stat(path)
	assert.True(t, os.IsNotExist(err))
}

func TestRemovePID_MissingFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nonexistent.pid")
	// Should not panic or error.
	RemovePID(path)
}

func TestReadPID_EmptyFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.pid")
	require.NoError(t, os.WriteFile(path, []byte(""), 0o600))

	_, err := ReadPID(path)
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "empty")
}

func TestReadPIDWithStart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.pid")

	// Untagged two-field format: PID + timestamp
	require.NoError(t, os.WriteFile(path, []byte("12345 1700000000"), 0o600))

	pid, startTime, tagged, err := readPIDWithStart(path)
	require.NoError(t, err)
	assert.Equal(t, 12345, pid)
	assert.False(t, startTime.IsZero())
	assert.Equal(t, int64(1700000000), startTime.Unix())
	assert.False(t, tagged)
}

func TestReadPIDWithStart_Tagged(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.pid")
	require.NoError(t, os.WriteFile(path, []byte("12345 1700000000 kstart"), 0o600))

	pid, startTime, tagged, err := readPIDWithStart(path)
	require.NoError(t, err)
	assert.Equal(t, 12345, pid)
	assert.Equal(t, int64(1700000000), startTime.Unix())
	assert.True(t, tagged)
}

func TestReadPIDWithStart_UnknownThirdFieldIsNotTagged(t *testing.T) {
	// A third field that isn't exactly pidFileFormatTag must not be
	// mistaken for the tag — forward compatibility with a hypothetical
	// future field, not a reason to trust an untagged value as accurate.
	path := filepath.Join(t.TempDir(), "daemon.pid")
	require.NoError(t, os.WriteFile(path, []byte("12345 1700000000 somethingelse"), 0o600))

	_, _, tagged, err := readPIDWithStart(path)
	require.NoError(t, err)
	assert.False(t, tagged)
}

func TestReadPIDWithStart_LegacyFormat(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.pid")

	// Oldest legacy format: just PID
	require.NoError(t, os.WriteFile(path, []byte("12345"), 0o600))

	pid, startTime, tagged, err := readPIDWithStart(path)
	require.NoError(t, err)
	assert.Equal(t, 12345, pid)
	assert.True(t, startTime.IsZero())
	assert.False(t, tagged)
}

func TestReadPIDWithStart_MissingFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nonexistent.pid")

	pid, startTime, tagged, err := readPIDWithStart(path)
	require.NoError(t, err)
	assert.Equal(t, 0, pid)
	assert.True(t, startTime.IsZero())
	assert.False(t, tagged)
}

func TestReadPIDWithStart_InvalidPID(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.pid")
	require.NoError(t, os.WriteFile(path, []byte("abc"), 0o600))

	_, _, _, err := readPIDWithStart(path)
	assert.Error(t, err)
}

func TestReadPIDWithStart_EmptyFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.pid")
	require.NoError(t, os.WriteFile(path, []byte("   "), 0o600))

	_, _, _, err := readPIDWithStart(path)
	assert.Error(t, err)
}

func TestWritePID_AtomicWrite(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "daemon.pid")

	err := WritePID(path)
	require.NoError(t, err)

	// Verify content format: "PID TIMESTAMP TAG"
	data, err := os.ReadFile(path)
	require.NoError(t, err)

	parts := strings.Fields(string(data))
	require.Len(t, parts, 3, "a successful identity read must tag the pid file (pidFileFormatTag)")

	pid, err := strconv.Atoi(parts[0])
	require.NoError(t, err)
	assert.Equal(t, os.Getpid(), pid)

	ts, err := strconv.ParseInt(parts[1], 10, 64)
	require.NoError(t, err)

	// WritePID now records THIS process's own real OS start time (see its
	// doc comment), not the wall-clock moment it's called — which, in a
	// long test run, could be arbitrarily later than the process's actual
	// start. So the correct pin is "matches what the identity reader
	// itself reports," not "close to time.Now()".
	ident, identErr := readProcessIdentity(os.Getpid())
	require.NoError(t, identErr)
	assert.Equal(t, ident.startTime.Unix(), ts)

	assert.Equal(t, pidFileFormatTag, parts[2])

	// Temp file should not remain
	_, err = os.Stat(path + ".tmp")
	assert.True(t, os.IsNotExist(err))
}

func TestWritePID_FallsBackToWallClockOnIdentityReadFailure(t *testing.T) {
	stubProcessIdentity(t, func(pid int) (processIdentity, error) {
		return processIdentity{}, errors.New("simulated read failure")
	})

	path := filepath.Join(t.TempDir(), "daemon.pid")
	before := time.Now().Unix()
	require.NoError(t, WritePID(path))
	after := time.Now().Unix()

	data, err := os.ReadFile(path)
	require.NoError(t, err)
	parts := strings.Fields(string(data))
	require.Len(t, parts, 2, "an identity-read failure must not tag the fallback value as accurate")
	ts, err := strconv.ParseInt(parts[1], 10, 64)
	require.NoError(t, err)
	assert.GreaterOrEqual(t, ts, before)
	assert.LessOrEqual(t, ts, after)
}

func TestReadProcessIdentityOS_ReturnsPlausibleData(t *testing.T) {
	// Exercises the REAL, unstubbed GOOS-specific reader directly (the
	// darwin sysctl path or the non-darwin ps-fallback path), so a bug in
	// either implementation shows up here even though every behavioral
	// test below stubs readProcessIdentity for determinism.
	ident, err := readProcessIdentityOS(os.Getpid())
	require.NoError(t, err)
	assert.False(t, ident.startTime.IsZero())
	assert.WithinDuration(t, time.Now(), ident.startTime, 10*time.Minute,
		"this test process should have started recently")
}

func TestIdentifyProcess_MatchingTimeAndComm(t *testing.T) {
	stored := time.Now().Add(-3 * time.Second)
	stubProcessIdentity(t, func(pid int) (processIdentity, error) {
		return processIdentity{startTime: stored, comm: "watchtower"}, nil
	})

	assert.Equal(t, processConfirmedSame, identifyProcess(os.Getpid(), stored, true))
}

func TestIdentifyProcess_EmptyCommSkipsCommFactor(t *testing.T) {
	// A reader that legitimately can't supply a comm (the ps-fallback path
	// on a ps failure) should not turn an otherwise-matching start time
	// into a false "reused".
	stored := time.Now()
	stubProcessIdentity(t, func(pid int) (processIdentity, error) {
		return processIdentity{startTime: stored, comm: ""}, nil
	})

	assert.Equal(t, processConfirmedSame, identifyProcess(os.Getpid(), stored, true))
}

func TestIdentifyProcess_MismatchedStartTime(t *testing.T) {
	stubProcessIdentity(t, func(pid int) (processIdentity, error) {
		return processIdentity{startTime: time.Now(), comm: "watchtower"}, nil
	})

	stale := time.Now().Add(-24 * time.Hour)
	assert.Equal(t, processReused, identifyProcess(os.Getpid(), stale, true))
}

func TestIdentifyProcess_MismatchedComm(t *testing.T) {
	// Start time matches exactly, but the live process's name doesn't look
	// like watchtower at all — the second factor alone must be enough to
	// call this reused (this is what the pre-fix, comm-only check got
	// right and a time-only check would have missed).
	stored := time.Now()
	stubProcessIdentity(t, func(pid int) (processIdentity, error) {
		return processIdentity{startTime: stored, comm: "some-other-process"}, nil
	})

	assert.Equal(t, processReused, identifyProcess(os.Getpid(), stored, true))
}

func TestIdentifyProcess_ReaderErrorIsUnknownNotReused(t *testing.T) {
	stubProcessIdentity(t, func(pid int) (processIdentity, error) {
		return processIdentity{}, errors.New("simulated ps/sysctl failure")
	})

	assert.Equal(t, processUnknown, identifyProcess(os.Getpid(), time.Now(), true))
}

// TestIdentifyProcess_Tagged_WithinToleranceEitherDirection pins the
// tagged/new-format path's symmetric ±pidReuseTolerance behavior: the
// stored value came from the SAME reader (WritePID's own read-back), so a
// small gap in either direction is just clock/read jitter.
func TestIdentifyProcess_Tagged_WithinToleranceEitherDirection(t *testing.T) {
	base := time.Now()
	for _, actual := range []time.Time{base.Add(4 * time.Second), base.Add(-4 * time.Second)} {
		stubProcessIdentity(t, func(pid int) (processIdentity, error) {
			return processIdentity{startTime: actual, comm: "watchtower"}, nil
		})
		assert.Equal(t, processConfirmedSame, identifyProcess(os.Getpid(), base, true))
	}
}

func TestIdentifyProcess_Tagged_BeyondToleranceEitherDirection(t *testing.T) {
	base := time.Now()
	for _, actual := range []time.Time{base.Add(6 * time.Second), base.Add(-6 * time.Second)} {
		stubProcessIdentity(t, func(pid int) (processIdentity, error) {
			return processIdentity{startTime: actual, comm: "watchtower"}, nil
		})
		assert.Equal(t, processReused, identifyProcess(os.Getpid(), base, true))
	}
}

// TestIdentifyProcess_Legacy_SlowStartupWithinOneSidedTolerance pins the
// N1 fix directly: an untagged (pre-tag-format) pid file's stored value is
// a wall-clock stamp taken sometime AFTER the real fork — for an old build
// with a slow startup (DB migrations, an OAuth/HTTP call before the
// network is up, ...) that gap can legitimately be tens of seconds. The
// one-sided check must still confirm this as the same process; a
// symmetric check (the earlier, reverted version of this fix) would
// wrongly call it reused and delete a live old-build daemon's pid file.
func TestIdentifyProcess_Legacy_SlowStartupWithinOneSidedTolerance(t *testing.T) {
	realStart := time.Now()
	stored := realStart.Add(30 * time.Second)
	stubProcessIdentity(t, func(pid int) (processIdentity, error) {
		return processIdentity{startTime: realStart, comm: "watchtower"}, nil
	})

	assert.Equal(t, processConfirmedSame, identifyProcess(os.Getpid(), stored, false))
}

// TestIdentifyProcess_Legacy_ReusedAfterFileWasWritten pins the other side:
// a live process whose real kernel start is AFTER the untagged file's
// stored value can only be a later, unrelated process — the file's author
// could not have recorded a value before its own fork.
func TestIdentifyProcess_Legacy_ReusedAfterFileWasWritten(t *testing.T) {
	stored := time.Now()
	realStart := stored.Add(60 * time.Second)
	stubProcessIdentity(t, func(pid int) (processIdentity, error) {
		return processIdentity{startTime: realStart, comm: "watchtower"}, nil
	})

	assert.Equal(t, processReused, identifyProcess(os.Getpid(), stored, false))
}

func TestIdentifyProcess_Legacy_CommMismatchIsReusedRegardlessOfTiming(t *testing.T) {
	// Otherwise-confirming timing (well within the one-sided rule), but a
	// comm that doesn't look like watchtower at all — the comm factor
	// applies to legacy files exactly as it does to tagged ones.
	stored := time.Now().Add(30 * time.Second)
	stubProcessIdentity(t, func(pid int) (processIdentity, error) {
		return processIdentity{startTime: time.Now(), comm: "some-other-process"}, nil
	})

	assert.Equal(t, processReused, identifyProcess(os.Getpid(), stored, false))
}

func TestResolveProcess_LegacyFormatRecentFileIsConfirmed(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.pid")
	require.NoError(t, os.WriteFile(path, []byte(strconv.Itoa(os.Getpid())), 0o600))

	pid, state, err := resolveProcess(path)
	require.NoError(t, err)
	assert.Equal(t, os.Getpid(), pid)
	assert.Equal(t, processConfirmedSame, state)
}

func TestResolveProcess_LegacyFormatStaleFileIsGone(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.pid")
	require.NoError(t, os.WriteFile(path, []byte("999999999"), 0o600))

	pid, state, err := resolveProcess(path)
	require.NoError(t, err)
	assert.Equal(t, 0, pid)
	assert.Equal(t, processGone, state)
}

func TestResolveProcess_DeadProcessIsGoneAndFileRemoved(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.pid")
	require.NoError(t, os.WriteFile(path, []byte("999999999 1700000000"), 0o600))

	pid, state, err := resolveProcess(path)
	require.NoError(t, err)
	assert.Equal(t, 0, pid)
	assert.Equal(t, processGone, state)

	_, statErr := os.Stat(path)
	assert.True(t, os.IsNotExist(statErr))
}

func TestFindProcess_ConfirmedSame(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.pid")
	stored := time.Now().Add(-2 * time.Second)
	writeTaggedPID(t, path, os.Getpid(), stored.Unix())
	stubProcessIdentity(t, func(pid int) (processIdentity, error) {
		return processIdentity{startTime: stored, comm: "watchtower"}, nil
	})

	pid, err := FindProcess(path)
	require.NoError(t, err)
	assert.Equal(t, os.Getpid(), pid)
}

func TestFindProcess_Reused(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.pid")
	writeTaggedPID(t, path, os.Getpid(), time.Now().Add(-24*time.Hour).Unix())
	// No stub needed: a 24h-old stored start time mismatches this
	// process's real recent start regardless of comm.

	pid, err := FindProcess(path)
	require.NoError(t, err)
	assert.Equal(t, 0, pid, "mismatched start time should be treated as PID reuse")

	_, statErr := os.Stat(path)
	assert.True(t, os.IsNotExist(statErr), "reused PID file should be removed")
}

func TestFindProcess_UnknownIsLenient(t *testing.T) {
	// A real, still-alive subprocess: the second (N3) liveness re-check
	// inside resolveProcess must find it alive and NOT downgrade this to
	// processGone, so the test can tell "genuinely unknown" apart from
	// "the re-check itself is broken and always reports gone".
	helper := startAlwaysAliveHelper(t)

	path := filepath.Join(t.TempDir(), "daemon.pid")
	writeTaggedPID(t, path, helper.Process.Pid, time.Now().Unix())
	stubProcessIdentity(t, func(pid int) (processIdentity, error) {
		return processIdentity{}, errors.New("simulated read failure")
	})

	// FindProcess is the lenient reader (status/kb/"already running"
	// checks): an unconfirmable identity still resolves to the pid.
	pid, err := FindProcess(path)
	require.NoError(t, err)
	assert.Equal(t, helper.Process.Pid, pid)

	_, statErr := os.Stat(path)
	assert.NoError(t, statErr, "an unconfirmable identity must not have its pid file removed")
}

func TestFindConfirmedProcess_ConfirmedSame(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.pid")
	stored := time.Now()
	writeTaggedPID(t, path, os.Getpid(), stored.Unix())
	stubProcessIdentity(t, func(pid int) (processIdentity, error) {
		return processIdentity{startTime: stored, comm: "watchtower"}, nil
	})

	pid, err := FindConfirmedProcess(path)
	require.NoError(t, err)
	assert.Equal(t, os.Getpid(), pid)
}

func TestFindConfirmedProcess_Gone(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.pid")
	writeTaggedPID(t, path, 999999999, time.Now().Unix())

	pid, err := FindConfirmedProcess(path)
	require.NoError(t, err)
	assert.Equal(t, 0, pid)
}

func TestFindConfirmedProcess_Reused(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.pid")
	writeTaggedPID(t, path, os.Getpid(), time.Now().Add(-24*time.Hour).Unix())

	pid, err := FindConfirmedProcess(path)
	require.NoError(t, err)
	assert.Equal(t, 0, pid)

	_, statErr := os.Stat(path)
	assert.True(t, os.IsNotExist(statErr))
}

// TestFindConfirmedProcess_UnavailableIdentityRefusesToConfirm pins the
// controller's explicit requirement: a caller about to signal the daemon
// must refuse when identity cannot be positively confirmed, not fall open.
func TestFindConfirmedProcess_UnavailableIdentityRefusesToConfirm(t *testing.T) {
	helper := startAlwaysAliveHelper(t)

	path := filepath.Join(t.TempDir(), "daemon.pid")
	writeTaggedPID(t, path, helper.Process.Pid, time.Now().Unix())
	stubProcessIdentity(t, func(pid int) (processIdentity, error) {
		return processIdentity{}, errors.New("simulated ps/sysctl failure")
	})

	pid, err := FindConfirmedProcess(path)
	assert.ErrorIs(t, err, ErrIdentityUnconfirmed)
	assert.Equal(t, helper.Process.Pid, pid, "pid is still reported for a caller's error message, even though it must not be signalled")

	_, statErr := os.Stat(path)
	assert.NoError(t, statErr, "an unconfirmable identity must not have its pid file removed")
}

// TestResolveProcess_LegacyUntaggedSlowStartupIsConfirmed is the N1
// regression pin end-to-end (not just at identifyProcess): an untagged pid
// file (the shape every pre-this-fix build wrote, and still readable
// today) whose stored value trails the real fork by well more than
// pidReuseTolerance must still resolve as confirmed, not be judged reused
// and deleted out from under a live, legitimately slow-starting daemon.
func TestResolveProcess_LegacyUntaggedSlowStartupIsConfirmed(t *testing.T) {
	helper := startAlwaysAliveHelper(t)
	realStart := time.Now()
	stored := realStart.Add(30 * time.Second) // old-build-shaped slow startup lag
	stubProcessIdentity(t, func(pid int) (processIdentity, error) {
		return processIdentity{startTime: realStart, comm: "watchtower"}, nil
	})

	path := filepath.Join(t.TempDir(), "daemon.pid")
	writeTimestampedPID(t, path, helper.Process.Pid, stored.Unix()) // untagged

	pid, state, err := resolveProcess(path)
	require.NoError(t, err)
	assert.Equal(t, helper.Process.Pid, pid)
	assert.Equal(t, processConfirmedSame, state)

	_, statErr := os.Stat(path)
	assert.NoError(t, statErr, "a confirmed-same process's pid file must not be removed")
}

// TestResolveProcess_ReaderErrorButProcessGoneOnRecheckIsGone pins N3: an
// identity-read failure alone is processUnknown, but if the process ALSO
// turns out to be gone on a fresh liveness re-check (the narrow race where
// it exited between resolveProcess's first kill(pid, 0) and the identity
// read), that re-check must win — "gone", not "unknown". A real subprocess
// is used because the two kill(pid, 0) calls this exercises are real
// syscalls, not stubbable; the identity stub itself kills the process (so
// the timing is exact, not a sleep-and-hope race) and waits for the kernel
// to actually reflect that before returning its error.
func TestResolveProcess_ReaderErrorButProcessGoneOnRecheckIsGone(t *testing.T) {
	helper := exec.Command("sleep", "30")
	require.NoError(t, helper.Start())
	pid := helper.Process.Pid
	t.Cleanup(func() {
		_ = helper.Process.Kill()
		_, _ = helper.Process.Wait()
	})

	path := filepath.Join(t.TempDir(), "daemon.pid")
	writeTaggedPID(t, path, pid, time.Now().Unix())

	stubProcessIdentity(t, func(p int) (processIdentity, error) {
		_ = helper.Process.Kill()
		_, _ = helper.Process.Wait()
		for i := 0; i < 100 && syscall.Kill(pid, 0) == nil; i++ {
			time.Sleep(10 * time.Millisecond)
		}
		require.NotNil(t, syscall.Kill(pid, 0), "test setup: helper should be confirmed dead before the stub returns")
		return processIdentity{}, errors.New("simulated read failure mid-race")
	})

	gotPid, state, err := resolveProcess(path)
	require.NoError(t, err)
	assert.Equal(t, 0, gotPid)
	assert.Equal(t, processGone, state)

	_, statErr := os.Stat(path)
	assert.True(t, os.IsNotExist(statErr), "a confirmed-gone process's pid file must be removed")
}

func TestFindProcess_EmptyPIDFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.pid")
	require.NoError(t, os.WriteFile(path, []byte(""), 0o600))

	_, err := FindProcess(path)
	assert.Error(t, err)
}

// startAlwaysAliveHelper starts a real subprocess that stays alive until
// killed, for a test that needs a genuinely live (not merely "this test
// process, which the OS could reuse into a different identity by the time
// a later assertion runs") pid — in particular anything exercising
// resolveProcess's N3 liveness re-check, which must see the process as
// actually alive to prove it ISN'T mistakenly downgrading a live-but-
// unconfirmable process to processGone. Reaped via t.Cleanup.
func startAlwaysAliveHelper(t *testing.T) *exec.Cmd {
	t.Helper()
	cmd := exec.Command("sleep", "30")
	require.NoError(t, cmd.Start())
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_, _ = cmd.Process.Wait()
	})
	return cmd
}

func writeTimestampedPID(t *testing.T, path string, pid int, startUnix int64) {
	t.Helper()
	content := fmt.Sprintf("%d %d", pid, startUnix)
	require.NoError(t, os.WriteFile(path, []byte(content), 0o600))
}

// writeTaggedPID writes the current three-field format: pid, start
// timestamp, and pidFileFormatTag — the shape WritePID produces when its
// own identity read succeeds, subject to the tight symmetric
// pidReuseTolerance check on read (see identifyProcess).
func writeTaggedPID(t *testing.T, path string, pid int, startUnix int64) {
	t.Helper()
	content := fmt.Sprintf("%d %d %s", pid, startUnix, pidFileFormatTag)
	require.NoError(t, os.WriteFile(path, []byte(content), 0o600))
}
