package adopt

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/hub/state"
	"watchtower/internal/hub/state/swiftfixture"
)

func setAsideFixture(t *testing.T) (mobile, hub string) {
	t.Helper()
	root := t.TempDir()
	mobile, hub = filepath.Join(root, "MobileHub"), filepath.Join(root, "hub")
	require.NoError(t, os.MkdirAll(mobile, 0o700))
	require.NoError(t, os.MkdirAll(hub, 0o700))
	db, err := swiftfixture.Create(filepath.Join(mobile, state.FileName), "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", swiftfixture.Schema)
	require.NoError(t, err)
	require.NoError(t, db.Close())
	require.NoError(t, os.WriteFile(filepath.Join(mobile, transportFile), []byte("transport"), 0o600))
	require.NoError(t, os.MkdirAll(filepath.Join(mobile, swiftAssetsDir), 0o700))
	return mobile, hub
}

func leftOriginals(t *testing.T, mobile string) []string {
	t.Helper()
	var left []string
	for _, name := range swiftOriginals {
		if _, err := os.Lstat(filepath.Join(mobile, name)); err == nil {
			left = append(left, name)
		}
	}
	return left
}

// A rename failing part-way leaves the sidecar in place (Status still says
// present, so the owner can retry), and the next call finishes the move into
// the same folder: done only when no original is left.
func TestSetAsideFinishesAMoveThatFailedPartWay(t *testing.T) {
	mobile, hub := setAsideFixture(t)
	fail := errors.New("disk said no")
	setAsideRename = func(from, to string) error {
		if filepath.Base(from) == swiftAssetsDir {
			return fail
		}
		return os.Rename(from, to)
	}
	t.Cleanup(func() { setAsideRename = os.Rename })
	now := func() time.Time { return time.Date(2026, 11, 2, 10, 0, 0, 0, time.UTC) }

	err := SetAside(mobile, hub, now)
	require.ErrorIs(t, err, fail)
	assert.Contains(t, leftOriginals(t, mobile), state.FileName, "the sidecar moves last")
	assert.Contains(t, leftOriginals(t, mobile), swiftAssetsDir)
	rep, err := Status(mobile, hub)
	require.NoError(t, err)
	assert.Equal(t, swiftPresent, rep.SwiftState, "still offered: the owner can press again")

	setAsideRename = os.Rename
	later := func() time.Time { return now().Add(time.Hour) }
	require.NoError(t, SetAside(mobile, hub, later))
	assert.Empty(t, leftOriginals(t, mobile), "every original moved")
	asides, err := filepath.Glob(filepath.Join(mobile, setAsideDirPrefix+"*"))
	require.NoError(t, err)
	require.Len(t, asides, 1, "finished into the same folder")
	for _, name := range []string{state.FileName, transportFile, swiftAssetsDir} {
		_, err := os.Lstat(filepath.Join(asides[0], name))
		assert.NoError(t, err, name)
	}
	rep, err = Status(mobile, hub)
	require.NoError(t, err)
	assert.Equal(t, swiftAbsent, rep.SwiftState)
}

// The sidecar gone but another original left (an older partial move) is not
// "done": the rest is moved.
func TestSetAsideIsDoneOnlyWhenEveryOriginalIsGone(t *testing.T) {
	mobile, hub := setAsideFixture(t)
	require.NoError(t, os.Remove(filepath.Join(mobile, state.FileName)))
	require.NoError(t, SetAside(mobile, hub, nil))
	assert.Empty(t, leftOriginals(t, mobile))
	_, err := os.Stat(filepath.Join(mobile, MovedName))
	assert.NoError(t, err)
	require.NoError(t, SetAside(mobile, hub, nil), "nothing left: no error")
}
