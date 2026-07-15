package memory

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing/object"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// vaultTestNode builds a minimal valid node whose Title matches the body H1,
// so ParseNode(Render(n)) == n holds and round-trip assertions can use
// assert.Equal on the whole struct.
func vaultTestNode(id, typ, title string) Node {
	return Node{
		ID:     id,
		Type:   typ,
		Tier:   "long",
		Status: "active",
		Title:  title,
		Body:   "# " + title + "\n\nBody of " + id + ".\n",
	}
}

func openTestRepo(t *testing.T, path string) *git.Repository {
	t.Helper()
	repo, err := git.PlainOpen(path)
	require.NoError(t, err)
	return repo
}

func headCommit(t *testing.T, repo *git.Repository) *object.Commit {
	t.Helper()
	ref, err := repo.Head()
	require.NoError(t, err)
	commit, err := repo.CommitObject(ref.Hash())
	require.NoError(t, err)
	return commit
}

func commitCount(t *testing.T, repo *git.Repository) int {
	t.Helper()
	iter, err := repo.Log(&git.LogOptions{})
	require.NoError(t, err)
	n := 0
	require.NoError(t, iter.ForEach(func(*object.Commit) error { n++; return nil }))
	return n
}

// commitFiles returns the paths touched by a commit (diff against its parent,
// or against the empty tree for the initial commit).
func commitFiles(t *testing.T, commit *object.Commit) []string {
	t.Helper()
	stats, err := commit.Stats()
	require.NoError(t, err)
	names := make([]string, len(stats))
	for i, s := range stats {
		names[i] = s.Name
	}
	return names
}

func TestOpenVaultInitializesRepo(t *testing.T) {
	dir := t.TempDir()

	v, err := OpenVault(dir)
	require.NoError(t, err)
	require.NotNil(t, v)

	// Repo and layout exist on disk.
	assert.DirExists(t, filepath.Join(dir, ".git"))
	assert.FileExists(t, filepath.Join(dir, "map.md"))
	for _, sub := range []string{"entities", "episodes", "rollups", "beliefs"} {
		assert.DirExists(t, filepath.Join(dir, sub))
	}

	// Exactly one initial commit, containing map.md, by the daemon author.
	repo := openTestRepo(t, dir)
	assert.Equal(t, 1, commitCount(t, repo))
	commit := headCommit(t, repo)
	assert.Equal(t, []string{"map.md"}, commitFiles(t, commit))
	assert.Equal(t, "watchtower", commit.Author.Name)
	assert.Equal(t, "daemon@local", commit.Author.Email)
	assert.True(t, strings.HasPrefix(commit.Message, "memory(init): "), "message %q", commit.Message)

	dirty, err := v.DirtyWorktree()
	require.NoError(t, err)
	assert.False(t, dirty)
}

func TestOpenVaultReopensExistingRepo(t *testing.T) {
	dir := t.TempDir()

	_, err := OpenVault(dir)
	require.NoError(t, err)
	v2, err := OpenVault(dir)
	require.NoError(t, err)
	require.NotNil(t, v2)

	// Reopen must not create a second initial commit.
	repo := openTestRepo(t, dir)
	assert.Equal(t, 1, commitCount(t, repo))
}

func TestVaultWriteNodesSingleCommit(t *testing.T) {
	dir := t.TempDir()
	v, err := OpenVault(dir)
	require.NoError(t, err)

	a := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5FA1", "entity", "Alpha")
	b := vaultTestNode("ep_01ARZ3NDEKTSV4RRFFQ69G5FA2", "episode", "Beta")
	hash, err := v.WriteNodes([]Node{a, b}, CommitMsg{
		Op:      "seed",
		Summary: "seed initial nodes",
		Cause:   "run:42",
		NodeIDs: []string{a.ID, b.ID},
	})
	require.NoError(t, err)
	require.NotEmpty(t, hash)

	repo := openTestRepo(t, dir)
	assert.Equal(t, 2, commitCount(t, repo), "init + exactly one machine commit")

	commit := headCommit(t, repo)
	assert.Equal(t, hash, commit.Hash.String())
	assert.Equal(t, "watchtower", commit.Author.Name)
	assert.Equal(t, "daemon@local", commit.Author.Email)

	wantMsg := "memory(seed): seed initial nodes\n\n" +
		"Nodes: ent_01ARZ3NDEKTSV4RRFFQ69G5FA1 ep_01ARZ3NDEKTSV4RRFFQ69G5FA2\n" +
		"Cause: run:42\n"
	assert.Equal(t, wantMsg, commit.Message)

	assert.ElementsMatch(t,
		[]string{"entities/ent_01ARZ3NDEKTSV4RRFFQ69G5FA1.md", "episodes/ep_01ARZ3NDEKTSV4RRFFQ69G5FA2.md"},
		commitFiles(t, commit))

	dirty, err := v.DirtyWorktree()
	require.NoError(t, err)
	assert.False(t, dirty, "machine write leaves a clean worktree")
}

func TestVaultReadNodeRoundTrip(t *testing.T) {
	dir := t.TempDir()
	v, err := OpenVault(dir)
	require.NoError(t, err)

	n := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5FB1", "entity", "Billing v2")
	n.Aliases = []string{"billing-v2", "C0123ABC"}
	n.Refs.PeopleCard = 42
	n.Refs.Targets = []int64{7, 13}

	_, err = v.WriteNodes([]Node{n}, CommitMsg{Op: "seed", Summary: "one entity", Cause: "seed", NodeIDs: []string{n.ID}})
	require.NoError(t, err)

	got, err := v.ReadNode(n.ID)
	require.NoError(t, err)
	assert.Equal(t, n, got)
}

func TestVaultReadNodeErrors(t *testing.T) {
	dir := t.TempDir()
	v, err := OpenVault(dir)
	require.NoError(t, err)

	_, err = v.ReadNode("bogus_01ARZ3NDEKTSV4RRFFQ69G5FC1")
	assert.Error(t, err, "unknown id prefix")

	_, err = v.ReadNode("ent_01ARZ3NDEKTSV4RRFFQ69G5FC2")
	assert.Error(t, err, "node file does not exist")
}

func TestVaultDirtyWorktree(t *testing.T) {
	dir := t.TempDir()
	v, err := OpenVault(dir)
	require.NoError(t, err)

	dirty, err := v.DirtyWorktree()
	require.NoError(t, err)
	assert.False(t, dirty)

	require.NoError(t, os.WriteFile(filepath.Join(dir, "map.md"), []byte("# Edited by owner\n"), 0o644))
	dirty, err = v.DirtyWorktree()
	require.NoError(t, err)
	assert.True(t, dirty)
}

// WriteNodes stages only the node paths it wrote: owner dirt (modified or
// untracked files) stays in the worktree, never swept into a machine commit.
func TestVaultWriteNodesStagingIsolation(t *testing.T) {
	dir := t.TempDir()
	v, err := OpenVault(dir)
	require.NoError(t, err)

	// Owner dirt: a modified tracked file and a stray untracked file.
	require.NoError(t, os.WriteFile(filepath.Join(dir, "map.md"), []byte("# Owner edit\n"), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "notes.md"), []byte("scratch\n"), 0o644))

	n := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5FD1", "entity", "Gamma")
	_, err = v.WriteNodes([]Node{n}, CommitMsg{Op: "seed", Summary: "one entity", Cause: "seed", NodeIDs: []string{n.ID}})
	require.NoError(t, err)

	repo := openTestRepo(t, dir)
	commit := headCommit(t, repo)
	assert.Equal(t, []string{"entities/ent_01ARZ3NDEKTSV4RRFFQ69G5FD1.md"}, commitFiles(t, commit))

	// Owner dirt is still uncommitted in the worktree.
	dirty, err := v.DirtyWorktree()
	require.NoError(t, err)
	assert.True(t, dirty)
}

// MEM-03: manual vault edits are committed as a separate memory(owner-edit)
// commit; a subsequent machine commit contains only machine paths.
func TestMemory03_OwnerEditsSeparateCommit(t *testing.T) {
	dir := t.TempDir()
	v, err := OpenVault(dir)
	require.NoError(t, err)

	a := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5FE1", "entity", "Delta")
	_, err = v.WriteNodes([]Node{a}, CommitMsg{Op: "seed", Summary: "one entity", Cause: "seed", NodeIDs: []string{a.ID}})
	require.NoError(t, err)

	// Clean tree: no owner-edit commit is made.
	made, err := v.CommitOwnerEdits()
	require.NoError(t, err)
	assert.False(t, made)

	// Hand-edit the node file the way an owner would (plain file write).
	aPath := filepath.Join(dir, "entities", a.ID+".md")
	raw, err := os.ReadFile(aPath)
	require.NoError(t, err)
	edited := string(raw) + "\nOwner note.\n"
	require.NoError(t, os.WriteFile(aPath, []byte(edited), 0o644))

	made, err = v.CommitOwnerEdits()
	require.NoError(t, err)
	assert.True(t, made)

	repo := openTestRepo(t, dir)
	ownerCommit := headCommit(t, repo)
	wantMsg := "memory(owner-edit): manual changes\n\nCause: owner-edit\n"
	assert.Equal(t, wantMsg, ownerCommit.Message)
	assert.Equal(t, []string{"entities/" + a.ID + ".md"}, commitFiles(t, ownerCommit))

	// The owner-edit commit actually contains the edit.
	file, err := ownerCommit.File("entities/" + a.ID + ".md")
	require.NoError(t, err)
	contents, err := file.Contents()
	require.NoError(t, err)
	assert.Equal(t, edited, contents)

	dirty, err := v.DirtyWorktree()
	require.NoError(t, err)
	assert.False(t, dirty)

	// A machine write of a different node lands in its own commit whose tree
	// diff contains only the machine path.
	b := vaultTestNode("ep_01ARZ3NDEKTSV4RRFFQ69G5FE2", "episode", "Epsilon")
	hash, err := v.WriteNodes([]Node{b}, CommitMsg{Op: "extract", Summary: "one episode", Cause: "run:7", NodeIDs: []string{b.ID}})
	require.NoError(t, err)

	machineCommit := headCommit(t, repo)
	assert.Equal(t, hash, machineCommit.Hash.String())
	assert.Equal(t, []string{"episodes/" + b.ID + ".md"}, commitFiles(t, machineCommit))
	assert.NotEqual(t, ownerCommit.Hash, machineCommit.Hash)
}
