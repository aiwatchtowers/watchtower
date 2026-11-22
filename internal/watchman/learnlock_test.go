package watchman

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// One holder per workbench: a second take skips until the first unlocks;
// another workbench's lock is its own.
func TestTryLearnLock_OnePerWorkbench(t *testing.T) {
	dir := t.TempDir()
	unlock, ok, err := TryLearnLock(dir, 7)
	require.NoError(t, err)
	require.True(t, ok)
	assert.FileExists(t, LearnLockPath(dir, 7))

	_, ok, err = TryLearnLock(dir, 7)
	require.NoError(t, err)
	assert.False(t, ok, "held: the second learner skips")

	other, ok, err := TryLearnLock(dir, 8)
	require.NoError(t, err)
	assert.True(t, ok, "another workbench")
	other()

	unlock()
	again, ok, err := TryLearnLock(dir, 7)
	require.NoError(t, err)
	assert.True(t, ok, "free after unlock")
	again()
}
