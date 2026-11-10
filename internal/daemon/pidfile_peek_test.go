package daemon

import (
	"bytes"
	"errors"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// exitedChildPID starts a short-lived child, waits for it and returns its
// pid: a pid that no longer names a live process.
func exitedChildPID(t *testing.T) int {
	t.Helper()
	cmd := exec.Command("true")
	require.NoError(t, cmd.Run())
	return cmd.Process.Pid
}

// ownStartTime reads this test process's real OS start time through the
// GOOS-specific reader, not the package seam.
func ownStartTime(t *testing.T) time.Time {
	t.Helper()
	ident, err := readProcessIdentityOS(os.Getpid())
	require.NoError(t, err)
	return ident.startTime
}

func TestPeekProcess_States(t *testing.T) {
	type tc struct {
		name      string
		setup     func(t *testing.T, path string) // nil = no pid file
		wantState PeekState
		wantPID   func() int
		wantErr   func(t *testing.T, err error)
	}
	parsing := func(t *testing.T, err error) {
		t.Helper()
		require.Error(t, err)
		assert.Contains(t, err.Error(), "parsing pid file")
	}
	cases := []tc{
		{
			name:      "no_file",
			wantState: PeekNone,
		},
		{
			name: "tagged_exited_child",
			setup: func(t *testing.T, path string) {
				writeTaggedPID(t, path, exitedChildPID(t), time.Now().Unix())
			},
			wantState: PeekGone,
		},
		{
			name: "untagged_old_mtime_live_pid",
			setup: func(t *testing.T, path string) {
				require.NoError(t, os.WriteFile(path, []byte(strconv.Itoa(os.Getpid())), 0o600))
				old := time.Now().Add(-31 * 24 * time.Hour)
				require.NoError(t, os.Chtimes(path, old, old))
			},
			wantState: PeekGone,
		},
		{
			name: "own_pid_real_start",
			setup: func(t *testing.T, path string) {
				start := ownStartTime(t)
				writeTaggedPID(t, path, os.Getpid(), start.Unix())
				stubProcessIdentity(t, func(int) (processIdentity, error) {
					return processIdentity{startTime: start, comm: "watchtower"}, nil
				})
			},
			wantState: PeekRunning,
			wantPID:   os.Getpid,
		},
		{
			name: "own_pid_start_one_hour_off",
			setup: func(t *testing.T, path string) {
				start := ownStartTime(t)
				writeTaggedPID(t, path, os.Getpid(), start.Add(-time.Hour).Unix())
				stubProcessIdentity(t, func(int) (processIdentity, error) {
					return processIdentity{startTime: start, comm: "watchtower"}, nil
				})
			},
			wantState: PeekReused,
		},
		{
			name: "identity_read_fails",
			setup: func(t *testing.T, path string) {
				writeTaggedPID(t, path, os.Getpid(), time.Now().Unix())
				stubProcessIdentity(t, func(int) (processIdentity, error) {
					return processIdentity{}, errors.New("simulated identity read failure")
				})
			},
			wantState: PeekUnknown,
			wantPID:   os.Getpid,
		},
		{
			name: "empty_file",
			setup: func(t *testing.T, path string) {
				require.NoError(t, os.WriteFile(path, nil, 0o600))
			},
			wantErr: parsing,
		},
		{
			name: "garbage_file",
			setup: func(t *testing.T, path string) {
				require.NoError(t, os.WriteFile(path, []byte("garbage"), 0o600))
			},
			wantErr: parsing,
		},
		{
			name: "permission_denied",
			setup: func(t *testing.T, path string) {
				if os.Geteuid() == 0 {
					t.Skip("root reads a mode-000 file")
				}
				require.NoError(t, os.WriteFile(path, []byte(strconv.Itoa(os.Getpid())), 0o600))
				require.NoError(t, os.Chmod(path, 0o000))
				t.Cleanup(func() { _ = os.Chmod(path, 0o600) })
			},
			wantErr: func(t *testing.T, err error) {
				t.Helper()
				require.Error(t, err)
				assert.True(t, errors.Is(err, fs.ErrPermission), "got %v", err)
			},
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "daemon.pid")
			if c.setup != nil {
				c.setup(t, path)
			}

			pid, state, err := PeekProcess(path)
			if c.wantErr != nil {
				c.wantErr(t, err)
			} else {
				require.NoError(t, err)
				assert.Equal(t, c.wantState, state)
				if c.wantPID != nil {
					assert.Equal(t, c.wantPID(), pid)
				}
			}

			_, statErr := os.Lstat(path)
			if c.setup == nil {
				assert.True(t, os.IsNotExist(statErr), "PeekProcess must not create a pid file")
			} else {
				assert.NoError(t, statErr, "PeekProcess must never remove the pid file")
			}
		})
	}
}

func TestPeekProcess_LeavesStalePIDFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.pid")
	writeTaggedPID(t, path, exitedChildPID(t), time.Now().Unix())
	old := time.Now().Add(-time.Hour).Truncate(time.Second)
	require.NoError(t, os.Chtimes(path, old, old))
	before, err := os.ReadFile(path)
	require.NoError(t, err)

	_, state, err := PeekProcess(path)
	require.NoError(t, err)
	assert.Equal(t, PeekGone, state)

	after, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.True(t, bytes.Equal(before, after), "pid file bytes changed")
	info, err := os.Stat(path)
	require.NoError(t, err)
	assert.True(t, info.ModTime().Equal(old), "pid file mtime changed: %v", info.ModTime())
}
