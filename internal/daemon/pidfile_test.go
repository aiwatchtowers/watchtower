package daemon

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
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

	// New format: PID + timestamp
	require.NoError(t, os.WriteFile(path, []byte("12345 1700000000"), 0o600))

	pid, startTime, err := readPIDWithStart(path)
	require.NoError(t, err)
	assert.Equal(t, 12345, pid)
	assert.False(t, startTime.IsZero())
	assert.Equal(t, int64(1700000000), startTime.Unix())
}

func TestReadPIDWithStart_LegacyFormat(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.pid")

	// Legacy format: just PID
	require.NoError(t, os.WriteFile(path, []byte("12345"), 0o600))

	pid, startTime, err := readPIDWithStart(path)
	require.NoError(t, err)
	assert.Equal(t, 12345, pid)
	assert.True(t, startTime.IsZero())
}

func TestReadPIDWithStart_MissingFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nonexistent.pid")

	pid, startTime, err := readPIDWithStart(path)
	require.NoError(t, err)
	assert.Equal(t, 0, pid)
	assert.True(t, startTime.IsZero())
}

func TestReadPIDWithStart_InvalidPID(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.pid")
	require.NoError(t, os.WriteFile(path, []byte("abc"), 0o600))

	_, _, err := readPIDWithStart(path)
	assert.Error(t, err)
}

func TestReadPIDWithStart_EmptyFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.pid")
	require.NoError(t, os.WriteFile(path, []byte("   "), 0o600))

	_, _, err := readPIDWithStart(path)
	assert.Error(t, err)
}

func TestWritePID_AtomicWrite(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "daemon.pid")

	err := WritePID(path)
	require.NoError(t, err)

	// Verify content format: "PID TIMESTAMP"
	data, err := os.ReadFile(path)
	require.NoError(t, err)

	parts := strings.Fields(string(data))
	require.Len(t, parts, 2)

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
	require.Len(t, parts, 2)
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

	assert.Equal(t, processConfirmedSame, identifyProcess(os.Getpid(), stored))
}

func TestIdentifyProcess_EmptyCommSkipsCommFactor(t *testing.T) {
	// A reader that legitimately can't supply a comm (the ps-fallback path
	// on a ps failure) should not turn an otherwise-matching start time
	// into a false "reused".
	stored := time.Now()
	stubProcessIdentity(t, func(pid int) (processIdentity, error) {
		return processIdentity{startTime: stored, comm: ""}, nil
	})

	assert.Equal(t, processConfirmedSame, identifyProcess(os.Getpid(), stored))
}

func TestIdentifyProcess_MismatchedStartTime(t *testing.T) {
	stubProcessIdentity(t, func(pid int) (processIdentity, error) {
		return processIdentity{startTime: time.Now(), comm: "watchtower"}, nil
	})

	stale := time.Now().Add(-24 * time.Hour)
	assert.Equal(t, processReused, identifyProcess(os.Getpid(), stale))
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

	assert.Equal(t, processReused, identifyProcess(os.Getpid(), stored))
}

func TestIdentifyProcess_ReaderErrorIsUnknownNotReused(t *testing.T) {
	stubProcessIdentity(t, func(pid int) (processIdentity, error) {
		return processIdentity{}, errors.New("simulated ps/sysctl failure")
	})

	assert.Equal(t, processUnknown, identifyProcess(os.Getpid(), time.Now()))
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
	writeTimestampedPID(t, path, os.Getpid(), stored.Unix())
	stubProcessIdentity(t, func(pid int) (processIdentity, error) {
		return processIdentity{startTime: stored, comm: "watchtower"}, nil
	})

	pid, err := FindProcess(path)
	require.NoError(t, err)
	assert.Equal(t, os.Getpid(), pid)
}

func TestFindProcess_Reused(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.pid")
	writeTimestampedPID(t, path, os.Getpid(), time.Now().Add(-24*time.Hour).Unix())
	// No stub needed: a 24h-old stored start time mismatches this
	// process's real recent start regardless of comm.

	pid, err := FindProcess(path)
	require.NoError(t, err)
	assert.Equal(t, 0, pid, "mismatched start time should be treated as PID reuse")

	_, statErr := os.Stat(path)
	assert.True(t, os.IsNotExist(statErr), "reused PID file should be removed")
}

func TestFindProcess_UnknownIsLenient(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.pid")
	writeTimestampedPID(t, path, os.Getpid(), time.Now().Unix())
	stubProcessIdentity(t, func(pid int) (processIdentity, error) {
		return processIdentity{}, errors.New("simulated read failure")
	})

	// FindProcess is the lenient reader (status/kb/"already running"
	// checks): an unconfirmable identity still resolves to the pid.
	pid, err := FindProcess(path)
	require.NoError(t, err)
	assert.Equal(t, os.Getpid(), pid)

	_, statErr := os.Stat(path)
	assert.NoError(t, statErr, "an unconfirmable identity must not have its pid file removed")
}

func TestFindConfirmedProcess_ConfirmedSame(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.pid")
	stored := time.Now()
	writeTimestampedPID(t, path, os.Getpid(), stored.Unix())
	stubProcessIdentity(t, func(pid int) (processIdentity, error) {
		return processIdentity{startTime: stored, comm: "watchtower"}, nil
	})

	pid, err := FindConfirmedProcess(path)
	require.NoError(t, err)
	assert.Equal(t, os.Getpid(), pid)
}

func TestFindConfirmedProcess_Gone(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.pid")
	writeTimestampedPID(t, path, 999999999, time.Now().Unix())

	pid, err := FindConfirmedProcess(path)
	require.NoError(t, err)
	assert.Equal(t, 0, pid)
}

func TestFindConfirmedProcess_Reused(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.pid")
	writeTimestampedPID(t, path, os.Getpid(), time.Now().Add(-24*time.Hour).Unix())

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
	path := filepath.Join(t.TempDir(), "daemon.pid")
	writeTimestampedPID(t, path, os.Getpid(), time.Now().Unix())
	stubProcessIdentity(t, func(pid int) (processIdentity, error) {
		return processIdentity{}, errors.New("simulated ps/sysctl failure")
	})

	pid, err := FindConfirmedProcess(path)
	assert.ErrorIs(t, err, ErrIdentityUnconfirmed)
	assert.Equal(t, os.Getpid(), pid, "pid is still reported for a caller's error message, even though it must not be signalled")

	_, statErr := os.Stat(path)
	assert.NoError(t, statErr, "an unconfirmable identity must not have its pid file removed")
}

func TestFindProcess_EmptyPIDFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.pid")
	require.NoError(t, os.WriteFile(path, []byte(""), 0o600))

	_, err := FindProcess(path)
	assert.Error(t, err)
}

func writeTimestampedPID(t *testing.T, path string, pid int, startUnix int64) {
	t.Helper()
	content := fmt.Sprintf("%d %d", pid, startUnix)
	require.NoError(t, os.WriteFile(path, []byte(content), 0o600))
}
