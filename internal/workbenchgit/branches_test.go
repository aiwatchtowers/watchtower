package workbenchgit

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// forEachRef renders records as for-each-ref prints branchFormat.
func forEachRef(records ...[branchFields]string) []byte {
	var b strings.Builder
	for _, r := range records {
		for _, f := range r {
			b.WriteString(f + "\x00")
		}
		b.WriteString("\n")
	}
	return []byte(b.String())
}

func TestParseBranches(t *testing.T) {
	out := forEachRef(
		[branchFields]string{"refs/heads/feature/x", "a1b2c3d", "1790000000", "origin/feature/x", "ahead 2, behind 1", "/work/acme"},
		[branchFields]string{"refs/heads/main", "b2c3d4e", "1780000000", "origin/main", "behind 3", "/work/acme-main"},
		[branchFields]string{"refs/heads/old", "c3d4e5f", "1770000000", "origin/old", "gone", ""},
		[branchFields]string{"refs/heads/wip", "d4e5f60", "1760000000", "", "", ""},
	)
	got, err := ParseBranches(out, "/work/acme/")
	require.NoError(t, err)
	require.Len(t, got, 4)
	assert.Equal(t, []string{"feature/x", "main", "old", "wip"}, []string{got[0].Name, got[1].Name, got[2].Name, got[3].Name}, "order as given")

	assert.Equal(t, Branch{Name: "feature/x", Current: true, Head: "a1b2c3d", CommittedAt: time.Unix(1790000000, 0).UTC(),
		Upstream: "origin/feature/x", Ahead: 2, Behind: 1}, got[0], "own worktree: current, no worktree")
	assert.Equal(t, "/work/acme-main", got[1].Worktree)
	assert.Equal(t, "acme-main", got[1].WorktreeName)
	assert.False(t, got[1].Current)
	assert.Equal(t, 3, got[1].Behind)
	assert.Equal(t, 0, got[2].Ahead+got[2].Behind, "a gone upstream counts nothing")
	assert.True(t, got[2].UpstreamGone)
	assert.False(t, got[0].UpstreamGone || got[1].UpstreamGone || got[3].UpstreamGone)
	assert.Empty(t, got[3].Upstream)
	assert.Equal(t, time.UTC, got[3].CommittedAt.Location())
}

func TestParseBranches_EmptyAndMalformed(t *testing.T) {
	got, err := ParseBranches(nil, "/work/acme")
	require.NoError(t, err)
	assert.NotNil(t, got)
	assert.Empty(t, got)

	_, err = ParseBranches([]byte("refs/heads/main\x00abc\x00\n"), "/work/acme")
	assert.Error(t, err, "a cut record")
	_, err = ParseBranches(forEachRef([branchFields]string{"refs/tags/v1", "a", "1", "", "", ""}), "/work/acme")
	assert.Error(t, err, "not a branch")
	_, err = ParseBranches(forEachRef([branchFields]string{"refs/heads/x", "a", "soon", "", "", ""}), "/work/acme")
	assert.Error(t, err, "bad time")
	for _, track := range []string{"ahead lots", "sideways 2", "ahead 1; behind 2", "gone, ahead 1"} {
		_, err = ParseBranches(forEachRef([branchFields]string{"refs/heads/x", "a", "1", "origin/x", track, ""}), "/work/acme")
		assert.Error(t, err, "track %q", track)
	}
}

func TestListBranches_RealRepository(t *testing.T) {
	dir := newRepo(t)
	l := ListBranches(context.Background(), options(dir, &recorder{}))
	require.True(t, l.BranchesOK, l.BranchesError)
	assert.True(t, l.GitAvailable)
	assert.True(t, l.Git)
	assert.Equal(t, "main", l.Current)
	names := map[string]Branch{}
	for _, b := range l.Branches {
		names[b.Name] = b
	}
	require.Contains(t, names, "main")
	require.Contains(t, names, "feature")
	assert.True(t, names["main"].Current)
	assert.False(t, names["feature"].Current)
	assert.Empty(t, names["main"].Worktree, "the folder's own checkout is not 'elsewhere'")
	assert.Len(t, names["feature"].Head, shortHash)
	assert.False(t, names["feature"].CommittedAt.IsZero())
}

func TestListBranches_DetachedHasNoCurrent(t *testing.T) {
	dir := newRepo(t)
	gitIn(t, dir, "switch", "-q", "--detach", "feature")
	l := ListBranches(context.Background(), options(dir, &recorder{}))
	require.True(t, l.BranchesOK, l.BranchesError)
	assert.Empty(t, l.Current)
	for _, b := range l.Branches {
		assert.False(t, b.Current, b.Name)
		assert.Empty(t, b.Worktree, b.Name)
	}
	st := ReadStatus(context.Background(), options(dir, &recorder{}))
	assert.True(t, st.Detached)
	assert.Empty(t, st.Branch)
	assert.Len(t, st.Head, shortHash)
}

// The branch list and the status show the same short commit id, whatever
// the repository's core.abbrev.
func TestListBranches_HeadMatchesTheStatus(t *testing.T) {
	dir := newRepo(t)
	gitIn(t, dir, "config", "core.abbrev", "12")
	l := ListBranches(context.Background(), options(dir, &recorder{}))
	require.True(t, l.BranchesOK, l.BranchesError)
	st := ReadStatus(context.Background(), options(dir, &recorder{}))
	require.True(t, st.StatusOK, st.StatusError)
	for _, b := range l.Branches {
		if b.Current {
			assert.Equal(t, st.Head, b.Head)
		}
		assert.Len(t, b.Head, shortHash, b.Name)
	}
}
