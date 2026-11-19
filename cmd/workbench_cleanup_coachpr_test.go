package cmd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// coachScratchFolders makes <workspace>/coach-pr/41, two days old, and
// <workspace>/coach-pr/42, made now (an Accept may be running in it).
func coachScratchFolders(t *testing.T) (old, fresh string) {
	t.Helper()
	cfg, err := loadWorkbenchCLIConfig()
	require.NoError(t, err)
	dir := filepath.Join(cfg.WorkspaceDir(), coachScratchDir)
	old, fresh = filepath.Join(dir, "41"), filepath.Join(dir, "42")
	for _, p := range []string{old, fresh} {
		require.NoError(t, os.MkdirAll(filepath.Join(p, "sub"), 0o755))
	}
	past := time.Now().Add(-48 * time.Hour)
	require.NoError(t, os.Chtimes(old, past, past))
	return old, fresh
}

func cleanupCoachScratch(t *testing.T, out string) []coachScratchItem {
	t.Helper()
	var res cleanupJSON
	require.NoError(t, json.Unmarshal([]byte(out), &res), out)
	return res.CoachScratch
}

// Spec §5: `workbench cleanup` lists the coach's scratch folders older than
// a day; a whole --apply removes them, a younger one is never listed, and
// inside an agent's terminal session they are only listed.
func TestCleanupCmd_CoachScratchFolders(t *testing.T) {
	f := newCleanupFixture(t)
	old, fresh := coachScratchFolders(t)

	out, err := runCleanupCmd(t, "--session", f.sessionArg(), "--json")
	require.NoError(t, err, out)
	items := cleanupCoachScratch(t, out)
	require.Len(t, items, 1)
	assert.Equal(t, old, items[0].Path)
	assert.False(t, items[0].Removed)
	assert.DirExists(t, old, "a plan removes nothing")

	out, err = runCleanupCmd(t, "--session", f.sessionArg())
	require.NoError(t, err, out)
	assert.Contains(t, out, "remove  coach-pr "+old)

	// Inside the agent's own terminal session: listed, kept.
	t.Setenv(terminalSessionEnv, f.sessionArg())
	out, err = runCleanupCmd(t, "--apply", "--json")
	require.NoError(t, err, out)
	items = cleanupCoachScratch(t, out)
	require.Len(t, items, 1)
	assert.False(t, items[0].Removed)
	assert.DirExists(t, old)
	unsetTerminalSessionEnv(t)

	out, err = runCleanupCmd(t, "--session", f.sessionArg(), "--apply")
	require.NoError(t, err, out)
	assert.Contains(t, out, "removed coach-pr "+old)
	assert.NoDirExists(t, old)
	assert.DirExists(t, fresh, "a folder under a day old is never touched")

	out, err = runCleanupCmd(t, "--session", f.sessionArg(), "--json")
	require.NoError(t, err, out)
	var top map[string]json.RawMessage
	require.NoError(t, json.Unmarshal([]byte(out), &top))
	assert.NotContains(t, top, "coach_scratch", "no key when nothing is left over")
}

// No link is followed (spec §5, review): a symlinked coach-pr folder is not
// listed or emptied, a symlinked entry is never listed, and only folders
// named like a proposal id count. The links' targets survive --apply.
func TestCleanupCmd_CoachScratchNeverFollowsLinks(t *testing.T) {
	f := newCleanupFixture(t)
	old, _ := coachScratchFolders(t)
	dir := filepath.Dir(old)
	past := time.Now().Add(-48 * time.Hour)
	target := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(target, "keep.txt"), []byte("x"), 0o644))
	require.NoError(t, os.Symlink(target, filepath.Join(dir, "43")))
	other := filepath.Join(dir, "notes")
	require.NoError(t, os.Mkdir(other, 0o755))
	require.NoError(t, os.Chtimes(other, past, past))

	out, err := runCleanupCmd(t, "--session", f.sessionArg(), "--apply", "--json")
	require.NoError(t, err, out)
	items := cleanupCoachScratch(t, out)
	require.Len(t, items, 1, out)
	assert.Equal(t, old, items[0].Path)
	assert.FileExists(t, filepath.Join(target, "keep.txt"))
	assert.DirExists(t, other, "a folder Publish did not make is not touched")

	// The whole coach-pr folder a symlink: nothing listed, nothing removed.
	moved := filepath.Join(t.TempDir(), "elsewhere")
	require.NoError(t, os.Rename(dir, moved))
	require.NoError(t, os.Symlink(moved, dir))
	require.NoError(t, os.Mkdir(filepath.Join(moved, "44"), 0o755))
	require.NoError(t, os.Chtimes(filepath.Join(moved, "44"), past, past))
	out, errOut, err := runWorkbench(t, "cleanup", "--session", f.sessionArg(), "--apply", "--json")
	require.NoError(t, err, out)
	assert.Empty(t, cleanupCoachScratch(t, out))
	assert.Contains(t, errOut, "a link is not followed")
	assert.DirExists(t, filepath.Join(moved, "44"))
	assert.FileExists(t, filepath.Join(target, "keep.txt"))
}

// A sweep (one workbench's repository) does not list the workspace's
// scratch folders.
func TestCleanupCmd_CoachScratchNotInASweep(t *testing.T) {
	f := newCleanupFixture(t)
	coachScratchFolders(t)
	out, err := runCleanupCmd(t, "--sweep", "--workbench", strconv.FormatInt(f.wb, 10), "--json")
	require.NoError(t, err, out)
	assert.Empty(t, cleanupCoachScratch(t, out))
}
