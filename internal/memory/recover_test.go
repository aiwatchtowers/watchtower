package memory

import (
	"os"
	"path/filepath"
	"testing"

	git "github.com/go-git/go-git/v5"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// headHash returns the vault's current HEAD commit hash as hex.
func headHash(t *testing.T, v *Vault) string {
	t.Helper()
	ref, err := v.repo.Head()
	require.NoError(t, err)
	return ref.Hash().String()
}

// nodeFileExists reports whether a node's file is present in the worktree.
func nodeFileExists(t *testing.T, v *Vault, id string) bool {
	t.Helper()
	rel, err := nodeRelPath(id)
	require.NoError(t, err)
	_, err = os.Stat(filepath.Join(v.path, filepath.FromSlash(rel)))
	return err == nil
}

// TestPlanResetCountsDiscardedCommitsAndFiles: the preview resolves the target,
// counts what the reset would throw away, and writes nothing.
func TestPlanResetCountsDiscardedCommitsAndFiles(t *testing.T) {
	v := newTestVault(t)
	a := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5RS1", "entity", "Alpha")
	writeNodes(t, v, a)
	target := headHash(t, v)

	b := vaultTestNode("ep_01ARZ3NDEKTSV4RRFFQ69G5RS2", "episode", "Beta")
	writeNodes(t, v, b)
	c := vaultTestNode("ep_01ARZ3NDEKTSV4RRFFQ69G5RS3", "episode", "Gamma")
	writeNodes(t, v, c)
	head := headHash(t, v)

	plan, err := PlanReset(v, target)
	require.NoError(t, err)
	assert.Equal(t, head, plan.Head)
	assert.Equal(t, target, plan.Target)
	assert.Equal(t, 2, plan.CommitsDropped)
	assert.Equal(t, 2, plan.FilesRemoved)
	assert.Zero(t, plan.DirtyCount)

	// Planning is a pure read: HEAD and both later files are untouched.
	assert.Equal(t, head, headHash(t, v))
	assert.True(t, nodeFileExists(t, v, b.ID))
	assert.True(t, nodeFileExists(t, v, c.ID))
}

// TestResetToRebuildsIndexEqualToFreshReindex is the reset's MEM-02 clause: a
// real reset leaves HEAD at the target, removes the files the discarded
// commits added, and leaves an index equal to the one a fresh reindex of the
// same vault produces (the TestMemory02_ReindexEquivalence comparison shape).
func TestResetToRebuildsIndexEqualToFreshReindex(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)

	a := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5RT1", "entity", "Alpha")
	a.Aliases = []string{"alpha", "C0AAAAAAA"}
	writeNodes(t, v, a)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)
	target := headHash(t, v)

	b := vaultTestNode("ep_01ARZ3NDEKTSV4RRFFQ69G5RT2", "episode", "Beta")
	b.Body = "# Beta\n\n## Story\nA thing happened.\n\n## Provenance\n- C0AAAAAAA 1700000000.000100\n"
	writeNodes(t, v, b)
	c := vaultTestNode("sum_01ARZ3NDEKTSV4RRFFQ69G5RT3", "rollup", "Q3 rollup")
	c.Body = "# Q3 rollup\n\nSee [[ent_01ARZ3NDEKTSV4RRFFQ69G5RT1]].\n"
	writeNodes(t, v, c)
	_, err = Reconcile(v, d, t.Logf)
	require.NoError(t, err)
	require.Len(t, dumpIndex(t, d).Nodes, 3, "sanity: all three are indexed before the reset")

	plan, err := PlanReset(v, target)
	require.NoError(t, err)
	_, err = ResetTo(v, d, plan, t.Logf)
	require.NoError(t, err)

	assert.Equal(t, target, headHash(t, v), "HEAD lands on the target commit")
	assert.True(t, nodeFileExists(t, v, a.ID))
	assert.False(t, nodeFileExists(t, v, b.ID), "a file added by a discarded commit is gone")
	assert.False(t, nodeFileExists(t, v, c.ID))

	afterReset := dumpIndex(t, d)
	require.Len(t, afterReset.Nodes, 1, "the index no longer carries the discarded nodes")

	_, err = Rebuild(v, d, t.Logf)
	require.NoError(t, err)
	assert.Equal(t, afterReset, dumpIndex(t, d), "the reset's index equals a fresh reindex of the same vault")
}

// TestPlanResetRejectsUnknownCommit: an unresolvable revision is refused
// before anything happens.
func TestPlanResetRejectsUnknownCommit(t *testing.T) {
	v := newTestVault(t)
	writeNodes(t, v, vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5RU1", "entity", "Alpha"))

	_, err := PlanReset(v, "0123456789abcdef0123456789abcdef01234567")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "not found")
}

// TestPlanResetRejectsNonAncestorCommit: a commit that exists as an object but
// is no longer reachable from HEAD (an earlier reset orphaned it) is refused —
// resetting to it would rewrite unrelated history rather than rewind this one.
func TestPlanResetRejectsNonAncestorCommit(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	a := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5RV1", "entity", "Alpha")
	writeNodes(t, v, a)
	base := headHash(t, v)

	b := vaultTestNode("ep_01ARZ3NDEKTSV4RRFFQ69G5RV2", "episode", "Beta")
	writeNodes(t, v, b)
	orphaned := headHash(t, v)

	plan, err := PlanReset(v, base)
	require.NoError(t, err)
	_, err = ResetTo(v, d, plan, t.Logf)
	require.NoError(t, err)

	writeNodes(t, v, vaultTestNode("ep_01ARZ3NDEKTSV4RRFFQ69G5RV3", "episode", "Gamma"))

	_, err = PlanReset(v, orphaned)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "not an ancestor")
}

// TestResetToRefusesDirtyWorktree: a hard reset discards uncommitted worktree
// changes, so an uncommitted owner edit (MEM-03) blocks the reset instead of
// being destroyed by it.
func TestResetToRefusesDirtyWorktree(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	a := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5RW1", "entity", "Alpha")
	writeNodes(t, v, a)
	target := headHash(t, v)
	writeNodes(t, v, vaultTestNode("ep_01ARZ3NDEKTSV4RRFFQ69G5RW2", "episode", "Beta"))
	head := headHash(t, v)

	rel, err := nodeRelPath(a.ID)
	require.NoError(t, err)
	edited := a
	edited.Body = "# Alpha\n\nOwner's own unsaved edit.\n"
	require.NoError(t, os.WriteFile(filepath.Join(v.path, filepath.FromSlash(rel)), edited.Render(), vaultFileMode))

	plan, err := PlanReset(v, target)
	require.NoError(t, err)
	assert.Equal(t, 1, plan.DirtyCount)
	assert.Contains(t, plan.Dirty, rel)

	_, err = ResetTo(v, d, plan, t.Logf)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "uncommitted")
	assert.Equal(t, head, headHash(t, v), "a refused reset leaves HEAD where it was")
}

// TestLockHolderPIDNamesTheHolder: the memory lock records its holder's pid so
// a refusing CLI command can name the process to stop.
func TestLockHolderPIDNamesTheHolder(t *testing.T) {
	v := newTestVault(t)
	_, ok := v.LockHolderPID()
	assert.False(t, ok, "no lock file yet — no holder to name")

	unlock, err := v.Lock()
	require.NoError(t, err)
	pid, ok := v.LockHolderPID()
	assert.True(t, ok)
	assert.Equal(t, os.Getpid(), pid)
	unlock()
}

// TestResetToPreservesIgnoredFiles: go-git's hard reset deletes every worktree
// path missing from the index, INCLUDING the ones .gitignore covers — which in
// this vault is the owner's Obsidian configuration. The reset must carry them
// across untouched.
func TestResetToPreservesIgnoredFiles(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	a := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5RX1", "entity", "Alpha")
	writeNodes(t, v, a)
	target := headHash(t, v)
	writeNodes(t, v, vaultTestNode("ep_01ARZ3NDEKTSV4RRFFQ69G5RX2", "episode", "Beta"))

	require.NoError(t, os.MkdirAll(filepath.Join(v.path, ".obsidian"), 0o700))
	workspace := filepath.Join(v.path, ".obsidian", "workspace.json")
	require.NoError(t, os.WriteFile(workspace, []byte(`{"main":"layout"}`), 0o600))
	scratch := filepath.Join(v.path, "scratch.tmp")
	require.NoError(t, os.WriteFile(scratch, []byte("scratch"), 0o600))

	plan, err := PlanReset(v, target)
	require.NoError(t, err)
	assert.Zero(t, plan.DirtyCount, "gitignored files are not worktree dirt")
	assert.Equal(t, 2, plan.IgnoredFiles)

	_, err = ResetTo(v, d, plan, t.Logf)
	require.NoError(t, err)

	got, err := os.ReadFile(workspace)
	require.NoError(t, err, "the owner's Obsidian config must survive the reset")
	assert.Equal(t, `{"main":"layout"}`, string(got))
	gotScratch, err := os.ReadFile(scratch)
	require.NoError(t, err)
	assert.Equal(t, "scratch", string(gotScratch))
}

// TestPlanResetTargetIsHead: resetting to the commit HEAD already points at is
// a no-op the plan reports as such (the CLI stops there).
func TestPlanResetTargetIsHead(t *testing.T) {
	v := newTestVault(t)
	writeNodes(t, v, vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5RY1", "entity", "Alpha"))
	head := headHash(t, v)

	plan, err := PlanReset(v, head)
	require.NoError(t, err)
	assert.Equal(t, head, plan.Head)
	assert.Equal(t, head, plan.Target)
	assert.Zero(t, plan.CommitsDropped)
	assert.Zero(t, plan.FilesRemoved)
}

// TestPlanResetEmptyHistory: a repository with no commit yet has no HEAD to
// rewind — refused cleanly, not panicked through.
func TestPlanResetEmptyHistory(t *testing.T) {
	dir := t.TempDir()
	_, err := git.PlainInit(dir, false)
	require.NoError(t, err)
	v, err := OpenExistingVault(dir)
	require.NoError(t, err)

	_, err = PlanReset(v, "HEAD")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "HEAD")
}
