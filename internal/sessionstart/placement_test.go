package sessionstart

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/gittest"
	"watchtower/internal/workbenchcheck"
	"watchtower/internal/workbenchgit"
)

// TestMain keeps git's background maintenance out of the test repositories.
func TestMain(m *testing.M) {
	gittest.DisableBackgroundGit()
	os.Exit(m.Run())
}

// placementCase is one entry of testdata/placement_cases.json, written from
// the Swift SessionStartPlacement by SessionStartPlacementFixtureTests.
type placementCase struct {
	Name     string `json:"name"`
	Choice   Choice `json:"choice"`
	Occupied bool   `json:"occupied"`
	Git      *struct {
		GitAvailable bool `json:"git_available"`
		Git          bool `json:"git"`
		Unborn       bool `json:"unborn"`
		StatusOK     bool `json:"status_ok"`
	} `json:"git"`
	Want struct {
		Worktree bool    `json:"worktree"`
		Note     *string `json:"note"`
	} `json:"want"`
}

func TestPlacementFixtures(t *testing.T) {
	cases := readCases[placementCase](t, "placement_cases.json")
	assert.Len(t, cases, 36)
	for _, c := range cases {
		var st *workbenchgit.Status
		if c.Git != nil {
			st = &workbenchgit.Status{GitAvailable: c.Git.GitAvailable, Git: c.Git.Git, StatusOK: c.Git.StatusOK}
			st.Unborn = c.Git.Unborn
		}
		got := Place(c.Occupied, c.Choice, st)
		want := Placement{Worktree: c.Want.Worktree}
		if c.Want.Note != nil {
			want.Note = *c.Want.Note
		}
		assert.Equal(t, want, got, c.Name)
	}
}

func TestPlaceWantsAStatusOnlyForAWorktree(t *testing.T) {
	assert.False(t, WantsWorktree(false, ChoiceAuto))
	assert.True(t, WantsWorktree(true, ChoiceAuto))
	assert.False(t, WantsWorktree(true, ChoiceFolder))
	assert.True(t, WantsWorktree(false, ChoiceWorktree))
	assert.False(t, WantsWorktree(true, Choice("bogus")), "an unknown choice never makes a worktree")
}

// recorder runs git for real and keeps every argv.
type recorder struct {
	mu    sync.Mutex
	calls [][]string
}

func (r *recorder) run(ctx context.Context, dir string, stdin []byte, name string, args ...string) ([]byte, int, error) {
	r.mu.Lock()
	r.calls = append(r.calls, append([]string(nil), args...))
	r.mu.Unlock()
	return workbenchcheck.ExecRunner(ctx, dir, stdin, name, args...)
}

func newRepo(t *testing.T, commit bool) string {
	t.Helper()
	dir := t.TempDir()
	git := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1")
		out, err := cmd.CombinedOutput()
		require.NoError(t, err, "git %v: %s", args, out)
	}
	git("init", "-q", "-b", "main")
	git("config", "user.email", "test@example.com")
	git("config", "user.name", "Test")
	if commit {
		require.NoError(t, os.WriteFile(filepath.Join(dir, "README.md"), []byte("hi\n"), 0o600))
		require.NoError(t, os.WriteFile(filepath.Join(dir, ".gitignore"), []byte(".env\n"), 0o600))
		require.NoError(t, os.WriteFile(filepath.Join(dir, ".worktreeinclude"), []byte(".env\n"), 0o600))
		require.NoError(t, os.WriteFile(filepath.Join(dir, ".env"), []byte("K=v\n"), 0o600))
		git("add", "README.md", ".gitignore", ".worktreeinclude")
		git("commit", "-q", "-m", "init")
	}
	return dir
}

// TestPlacementNeverForcesOrDiscards is the twin, at this layer, of
// workbenchgit's TestProj18_PlacementNeverForcesOrDiscards: placing sessions
// (a second worktree beside one with the owner's changes, a refused start)
// runs no git command that forces, removes or discards, and leaves every
// worktree it made, with its changes, where it is.
func TestPlacementNeverForcesOrDiscards(t *testing.T) {
	dir := newRepo(t, true)
	rec := &recorder{}
	o := workbenchgit.Options{Folder: dir, Run: rec.run}
	ctx := context.Background()
	place := Placement{Worktree: true}

	a := Prepare(ctx, o, place, workbenchgit.WorktreeRequest{Slug: "s"})
	require.NotNil(t, a.Worktree, a.Notice)
	assert.Equal(t, a.Worktree.Cwd, a.Dir)
	assert.FileExists(t, filepath.Join(a.Dir, ".env"), ".worktreeinclude paths are cloned")
	require.NoError(t, os.WriteFile(filepath.Join(a.Dir, "README.md"), []byte("owner's work\n"), 0o600))

	b := Prepare(ctx, o, place, workbenchgit.WorktreeRequest{Slug: "s"})
	require.NotNil(t, b.Worktree, b.Notice)
	assert.NotEqual(t, a.Dir, b.Dir, "a taken name gets the next one, never the same worktree")

	refused := Prepare(ctx, o, place, workbenchgit.WorktreeRequest{Slug: "Not A Slug"})
	assert.Nil(t, refused.Worktree)
	assert.Equal(t, dir, refused.Dir)
	assert.True(t, strings.HasPrefix(refused.Notice, "Started in the folder: "), refused.Notice)

	forbidden := []string{"remove", "prune", "--force", "-f", "-D", "-d", "--hard", "reset", "clean", "checkout",
		"restore", "stash", "--discard-changes"}
	require.NotEmpty(t, rec.calls)
	for _, c := range rec.calls {
		for _, arg := range c {
			assert.NotContains(t, forbidden, arg, "git %s", strings.Join(c, " "))
		}
	}
	got, err := os.ReadFile(filepath.Join(a.Dir, "README.md"))
	require.NoError(t, err)
	assert.Equal(t, "owner's work\n", string(got), "an existing worktree's changes are untouched")
	assert.DirExists(t, b.Dir)
}

func TestPrepareInTheFolder(t *testing.T) {
	dir := newRepo(t, false)
	o := workbenchgit.Options{Folder: dir}
	got := Prepare(context.Background(), o, Placement{Note: "Started in the folder: git is not available."},
		workbenchgit.WorktreeRequest{Slug: "s"})
	assert.Equal(t, Prepared{Dir: dir, Notice: "Started in the folder: git is not available."}, got)

	unborn := Prepare(context.Background(), o, Placement{Worktree: true}, workbenchgit.WorktreeRequest{Slug: "s"})
	assert.Nil(t, unborn.Worktree)
	assert.Equal(t, dir, unborn.Dir)
	assert.Equal(t, "Started in the folder: unborn", unborn.Notice, "the refusal word when there is no detail")
}

func TestWorktreeNotice(t *testing.T) {
	assert.Empty(t, WorktreeNotice(workbenchgit.WorktreeResult{}, ""))
	assert.Equal(t,
		"The new worktree does not have the folder's uncommitted changes. Worktree: copying .env failed",
		WorktreeNotice(workbenchgit.WorktreeResult{BaseDirty: true, IncludeWarnings: []string{"", "copying .env failed"},
			Warning: "exclude"}, "install"))
	assert.Equal(t, "Worktree: exclude", WorktreeNotice(workbenchgit.WorktreeResult{Warning: "exclude"}, "install"))
	assert.Equal(t, "Worktree: install", WorktreeNotice(workbenchgit.WorktreeResult{}, "install"))
}
