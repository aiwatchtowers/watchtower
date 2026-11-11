package workbenchgit

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// porcelain joins entries as `git status --porcelain=v2 -z` prints them.
func porcelain(entries ...string) []byte {
	return []byte(strings.Join(entries, "\x00") + "\x00")
}

const oid = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"

func TestParseStatus(t *testing.T) {
	cases := []struct {
		name string
		in   []byte
		want StatusFields
	}{
		{"clean on main", porcelain("# branch.oid "+oid, "# branch.head main", "# branch.upstream origin/main", "# branch.ab +0 -0"),
			StatusFields{Branch: "main", Head: "a1b2c3d", Upstream: "origin/main"}},
		{"ahead and behind", porcelain("# branch.oid "+oid, "# branch.head main", "# branch.upstream origin/main", "# branch.ab +2 -1"),
			StatusFields{Branch: "main", Head: "a1b2c3d", Upstream: "origin/main", Ahead: 2, Behind: 1}},
		{"no upstream", porcelain("# branch.oid "+oid, "# branch.head topic"),
			StatusFields{Branch: "topic", Head: "a1b2c3d"}},
		{"detached", porcelain("# branch.oid "+oid, "# branch.head (detached)"),
			StatusFields{Detached: true, Head: "a1b2c3d"}},
		{"unborn", porcelain("# branch.oid (initial)", "# branch.head main"),
			StatusFields{Branch: "main", Unborn: true}},
		{"dirty: modified, staged, renamed, untracked", porcelain("# branch.oid "+oid, "# branch.head main",
			"1 .M N... 100644 100644 100644 "+oid+" "+oid+" a.txt",
			"1 A. N... 000000 100644 100644 "+oid+" "+oid+" b.txt",
			"2 R. N... 100644 100644 100644 "+oid+" "+oid+" R100 new name.txt", "old name.txt",
			"? untracked.txt"),
			StatusFields{Branch: "main", Head: "a1b2c3d", Changes: 4}},
		{"unmerged", porcelain("# branch.oid "+oid, "# branch.head main",
			"u UU N... 100644 100644 100644 100644 "+oid+" "+oid+" "+oid+" c.txt"),
			StatusFields{Branch: "main", Head: "a1b2c3d", Changes: 1, Unmerged: 1}},
		{"ignored entries are not changes", porcelain("# branch.oid "+oid, "# branch.head main", "! build/"),
			StatusFields{Branch: "main", Head: "a1b2c3d"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := parseStatus(tc.in)
			require.NoError(t, err)
			assert.Equal(t, tc.want, got)
		})
	}
}

func TestParseStatus_Malformed(t *testing.T) {
	for _, in := range [][]byte{
		porcelain("# branch.ab two -1"),
		[]byte("2 R. N... 100644 100644 100644 " + oid + " " + oid + " R100 new"),
		porcelain("X what"),
		porcelain("# branch.head main"),
		nil,
	} {
		_, err := parseStatus(in)
		assert.Error(t, err, "%q", in)
	}
}

func TestReadStatus_RealRepository(t *testing.T) {
	dir := newRepo(t)
	rec := &recorder{}
	st := ReadStatus(context.Background(), options(dir, rec))
	require.True(t, st.StatusOK, st.StatusError)
	assert.True(t, st.GitAvailable)
	assert.True(t, st.Git)
	assert.Equal(t, "main", st.Branch)
	assert.False(t, st.Dirty)
	assert.Len(t, st.Head, shortHash)
	assert.True(t, sameDir(t, dir, st.TopLevel))
	assert.True(t, sameDir(t, filepath.Join(dir, ".git"), st.GitDir))
	assert.True(t, sameDir(t, filepath.Join(dir, ".git"), st.CommonDir))

	writeFile(t, dir, "README.md", "changed\n")
	writeFile(t, dir, "new.txt", "new\n")
	st = ReadStatus(context.Background(), options(dir, rec))
	assert.True(t, st.Dirty)
	assert.Equal(t, 2, st.Changes)
}

func TestReadStatus_RepositorySubdirectory(t *testing.T) {
	dir := newRepo(t)
	sub := filepath.Join(dir, "a", "b")
	require.NoError(t, os.MkdirAll(sub, 0o755))
	st := ReadStatus(context.Background(), options(sub, &recorder{}))
	require.True(t, st.StatusOK, st.StatusError)
	assert.Equal(t, "main", st.Branch)
	assert.True(t, sameDir(t, dir, st.TopLevel))
	assert.True(t, sameDir(t, filepath.Join(dir, ".git"), st.CommonDir), "the common dir resolves from a subdirectory: %s", st.CommonDir)
}

func TestReadStatus_LinkedWorktree(t *testing.T) {
	dir := newRepo(t)
	linked := filepath.Join(filepath.Dir(dir), filepath.Base(dir)+"-wt")
	t.Cleanup(func() { _ = os.RemoveAll(linked) })
	gitIn(t, dir, "worktree", "add", "-q", linked, "feature")

	st := ReadStatus(context.Background(), options(linked, &recorder{}))
	require.True(t, st.StatusOK, st.StatusError)
	assert.Equal(t, "feature", st.Branch)
	assert.True(t, strings.HasSuffix(st.GitDir, filepath.Join("worktrees", filepath.Base(linked))), st.GitDir)
	assert.True(t, sameDir(t, filepath.Join(dir, ".git"), st.CommonDir), st.CommonDir)
	assert.True(t, sameDir(t, linked, st.TopLevel))

	l := ListBranches(context.Background(), options(linked, &recorder{}))
	require.True(t, l.BranchesOK, l.BranchesError)
	assert.Equal(t, "feature", l.Current)
	byName := map[string]Branch{}
	for _, b := range l.Branches {
		byName[b.Name] = b
	}
	assert.True(t, byName["feature"].Current)
	assert.Empty(t, byName["feature"].Worktree)
	assert.True(t, sameDir(t, dir, byName["main"].Worktree), "the main checkout's branch is open elsewhere: %+v", byName["main"])
	assert.Equal(t, filepath.Base(dir), byName["main"].WorktreeName)
	assert.False(t, byName["main"].Current)
}

func TestReadStatus_NoGitOutsideARepository(t *testing.T) {
	gitBin(t)
	rec := &recorder{}
	st := ReadStatus(context.Background(), options(t.TempDir(), rec))
	assert.True(t, st.GitAvailable)
	assert.False(t, st.Git)
	assert.NotEmpty(t, st.Note)
	l := ListBranches(context.Background(), options(t.TempDir(), rec))
	assert.False(t, l.Git)
	assert.NotNil(t, l.Branches)
	assert.Empty(t, rec.argv(), "no git process outside a repository")
}

func TestReadStatus_GitUnavailableRunsNothing(t *testing.T) {
	dir := newRepo(t)
	rec := &recorder{}
	o := options(dir, rec)
	o.Locate = func() (string, bool) { return "", false }
	st := ReadStatus(context.Background(), o)
	assert.False(t, st.GitAvailable)
	assert.False(t, st.Git)
	assert.Contains(t, st.Note, "not available")
	l := ListBranches(context.Background(), o)
	assert.False(t, l.GitAvailable)
	assert.Contains(t, l.Note, "not available")
	assert.Empty(t, rec.argv(), "no git process without a located git")
}

func TestReadStatus_RunsTheLocatedBinary(t *testing.T) {
	dir := newRepo(t)
	var names []string
	o := Options{Folder: dir, Locate: func() (string, bool) { return "/opt/acme/bin/git", true },
		Run: func(_ context.Context, _ string, _ []byte, name string, _ ...string) ([]byte, int, error) {
			names = append(names, name)
			return nil, 1, os.ErrNotExist
		}}
	st := ReadStatus(context.Background(), o)
	assert.True(t, st.Git, "a failed git call inside a repository is not 'not git'")
	assert.False(t, st.StatusOK)
	assert.Equal(t, []string{"/opt/acme/bin/git"}, names)
}

func TestReadStatus_Operation(t *testing.T) {
	dir := newRepo(t)
	commit(t, dir, "feature.txt", "main side\n", "main side")
	rec := &recorder{}
	_, _, err := execRunner(context.Background(), dir, nil, gitBin(t), "merge", "feature")
	require.Error(t, err, "the merge must conflict")
	st := ReadStatus(context.Background(), options(dir, rec))
	assert.Equal(t, "merge", st.Operation)
	assert.Equal(t, 1, st.Unmerged)
}

// Inside a repository a failing git is a failure, never "not git": the
// .git directory itself has no work tree, so rev-parse fails there.
func TestReadStatus_GitFailureInsideARepository(t *testing.T) {
	dir := newRepo(t)
	gitDir := filepath.Join(dir, ".git")
	st := ReadStatus(context.Background(), options(gitDir, &recorder{}))
	assert.True(t, st.GitAvailable)
	assert.True(t, st.Git)
	assert.Empty(t, st.Note)
	assert.False(t, st.StatusOK)
	assert.Contains(t, st.StatusError, "work tree")

	l := ListBranches(context.Background(), options(gitDir, &recorder{}))
	assert.True(t, l.Git)
	assert.False(t, l.BranchesOK)
	assert.Contains(t, l.BranchesError, "work tree")
	assert.NotNil(t, l.Branches)
}

func TestReadStatus_TimeoutReadsAsATimeout(t *testing.T) {
	dir := newRepo(t)
	ctx, cancel := context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
	defer cancel()
	st := ReadStatus(ctx, options(dir, &recorder{}))
	assert.True(t, st.Git)
	assert.False(t, st.StatusOK)
	assert.Equal(t, "git rev-parse timed out", st.StatusError)
}

func TestRunError_Message(t *testing.T) {
	cases := []struct {
		e    runError
		want string
	}{
		{runError{args: []string{"status", "-z"}, err: errors.New("exit status 128"), stderr: "fatal: no"}, "git status -z: exit status 128: fatal: no"},
		{runError{args: []string{"status", "-z"}, err: errors.New("exit status 1")}, "git status -z: exit status 1"},
		{runError{args: []string{"status", "-z"}, err: context.DeadlineExceeded}, "git status timed out"},
		{runError{args: []string{"switch", "x"}, err: context.Canceled}, "git switch was canceled"},
	}
	for _, tc := range cases {
		assert.Equal(t, tc.want, tc.e.Error())
	}
}

func TestOperationIn_UnreadableGitDirIsAnError(t *testing.T) {
	dir := t.TempDir()
	notADir := filepath.Join(dir, "file")
	require.NoError(t, os.WriteFile(notADir, nil, 0o644))
	_, err := operationIn(notADir)
	assert.Error(t, err, "a marker that cannot be checked is not 'no operation'")
	op, err := operationIn(dir)
	require.NoError(t, err)
	assert.Empty(t, op)
}

// An inherited GIT_DIR or GIT_WORK_TREE (a git hook, another tool's shell)
// must not point the folder's git calls at another repository.
func TestReadStatus_IgnoresInheritedRepositoryEnvironment(t *testing.T) {
	dir := newRepo(t)
	other := newRepo(t)
	gitIn(t, other, "switch", "-q", "-c", "elsewhere")
	t.Setenv("GIT_DIR", filepath.Join(other, ".git"))
	t.Setenv("GIT_WORK_TREE", other)
	t.Setenv("GIT_INDEX_FILE", filepath.Join(other, ".git", "index"))
	st := ReadStatus(context.Background(), options(dir, &recorder{}))
	require.True(t, st.StatusOK, st.StatusError)
	assert.Equal(t, "main", st.Branch)
	assert.True(t, sameDir(t, dir, st.TopLevel), st.TopLevel)
	l := ListBranches(context.Background(), options(dir, &recorder{}))
	assert.Equal(t, "main", l.Current)
}

func pathState(t *testing.T, dir, rel string) (PathState, *recorder) {
	t.Helper()
	rec := &recorder{}
	st, err := PathStatus(context.Background(), options(dir, rec), rel)
	require.NoError(t, err)
	return st, rec
}

func TestPathStatus_Clean(t *testing.T) {
	dir := newRepo(t)
	st, _ := pathState(t, dir, "README.md")
	assert.Equal(t, PathState{Git: true}, st)
}

func TestPathStatus_DirtyKinds(t *testing.T) {
	cases := map[string]func(t *testing.T, dir string){
		"unstaged edit": func(t *testing.T, dir string) { writeFile(t, dir, "README.md", "changed\n") },
		"staged edit": func(t *testing.T, dir string) {
			writeFile(t, dir, "README.md", "changed\n")
			gitIn(t, dir, "add", "README.md")
		},
		"untracked": func(t *testing.T, dir string) { writeFile(t, dir, "NEW.md", "x\n") },
		"deleted":   func(t *testing.T, dir string) { require.NoError(t, os.Remove(filepath.Join(dir, "README.md"))) },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			dir := newRepo(t)
			mutate(t, dir)
			rel := "README.md"
			if name == "untracked" {
				rel = "NEW.md"
			}
			st, _ := pathState(t, dir, rel)
			assert.Equal(t, PathState{Git: true, Dirty: true}, st)
		})
	}
}

func TestPathStatus_OtherPathDirty(t *testing.T) {
	dir := newRepo(t)
	writeFile(t, dir, "other.md", "x\n")
	st, _ := pathState(t, dir, "README.md")
	assert.Equal(t, PathState{Git: true}, st)
}

func TestPathStatus_IgnoredIsClean(t *testing.T) {
	dir := newRepo(t)
	commit(t, dir, ".gitignore", "secret.md\n", "ignore")
	writeFile(t, dir, "secret.md", "x\n")
	st, _ := pathState(t, dir, "secret.md")
	assert.Equal(t, PathState{Git: true}, st)
}

func TestPathStatus_MissingFile(t *testing.T) {
	dir := newRepo(t)
	st, _ := pathState(t, dir, "CLAUDE.md")
	assert.Equal(t, PathState{Git: true}, st)
}

func TestPathStatus_NotARepo(t *testing.T) {
	newRepo(t) // skips without git
	st, rec := pathState(t, t.TempDir(), "CLAUDE.md")
	assert.Equal(t, PathState{}, st)
	assert.Empty(t, rec.argv())
}

func TestPathStatus_RefusesEscapingPath(t *testing.T) {
	dir := newRepo(t)
	for _, rel := range []string{"../x", "/etc/x", "a/../../x", ""} {
		rec := &recorder{}
		_, err := PathStatus(context.Background(), options(dir, rec), rel)
		require.Error(t, err, rel)
		assert.Empty(t, rec.argv(), rel)
	}
}

func TestPathStatus_RunsOnlyStatus(t *testing.T) {
	dir := newRepo(t)
	_, rec := pathState(t, dir, "sub/CLAUDE.md")
	assert.Equal(t, [][]string{
		{"rev-parse", "--absolute-git-dir", "--git-common-dir", "--show-toplevel"},
		{"status", "--porcelain=v1", "-z", "--", "sub/CLAUDE.md"},
	}, rec.argv())
}

// ReadStatus, the coach's branch read (COACH-01: TestCOACH01_NoGitWrites),
// runs only the probe's rev-parse and one porcelain v2 status.
func TestReadStatus_RunsOnlyReadVerbs(t *testing.T) {
	dir := newRepo(t)
	writeFile(t, dir, "README.md", "changed\n")
	rec := &recorder{}
	st := ReadStatus(context.Background(), options(dir, rec))
	require.True(t, st.StatusOK, st.StatusError)
	assert.Equal(t, [][]string{
		{"rev-parse", "--absolute-git-dir", "--git-common-dir", "--show-toplevel"},
		{"status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal", "--ignore-submodules=all"},
	}, rec.argv())
}

// FileAtHead, the coach's commit check (COACH-01: TestCOACH01_NoGitWrites),
// runs only the probe's rev-parse and one `git show HEAD:./<rel>`.
func TestFileAtHead(t *testing.T) {
	dir := newRepo(t)
	writeFile(t, dir, "README.md", "changed, not committed\n")
	rec := &recorder{}
	text, ok, err := FileAtHead(context.Background(), options(dir, rec), "README.md")
	require.NoError(t, err)
	assert.True(t, ok)
	assert.Equal(t, "hello\n", text, "the committed text, not the work tree's")
	assert.Equal(t, [][]string{
		{"rev-parse", "--absolute-git-dir", "--git-common-dir", "--show-toplevel"},
		{"show", "HEAD:./README.md"},
	}, rec.argv())

	for _, rel := range []string{"CLAUDE.md", "feature.txt"} { // absent; only on another branch
		writeFile(t, dir, "CLAUDE.md", "on disk only\n")
		text, ok, err = FileAtHead(context.Background(), options(dir, &recorder{}), rel)
		require.NoError(t, err, rel)
		assert.False(t, ok, rel)
		assert.Empty(t, text, rel)
	}

	for _, rel := range []string{"../x", "/etc/x", "a/../../x", ""} {
		rec := &recorder{}
		_, _, err := FileAtHead(context.Background(), options(dir, rec), rel)
		require.Error(t, err, rel)
		assert.Empty(t, rec.argv(), rel)
	}
}

func TestFileAtHead_Subdirectory(t *testing.T) {
	dir := newRepo(t)
	require.NoError(t, os.MkdirAll(filepath.Join(dir, "sub"), 0o755))
	commit(t, dir, "sub/CLAUDE.md", "sub rules\n", "sub")
	commit(t, dir, "CLAUDE.md", "top rules\n", "top")
	text, ok, err := FileAtHead(context.Background(), options(filepath.Join(dir, "sub"), &recorder{}), "CLAUDE.md")
	require.NoError(t, err)
	assert.True(t, ok)
	assert.Equal(t, "sub rules\n", text, "relative to the folder, not the top level")
}

func TestFileAtHead_UnbornAndNotARepo(t *testing.T) {
	gitBin(t)
	dir, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	gitIn(t, dir, "init", "-q", "-b", "main")
	writeFile(t, dir, "CLAUDE.md", "x\n")
	_, ok, err := FileAtHead(context.Background(), options(dir, &recorder{}), "CLAUDE.md")
	require.NoError(t, err)
	assert.False(t, ok, "no commit yet")

	rec := &recorder{}
	_, _, err = FileAtHead(context.Background(), options(t.TempDir(), rec), "CLAUDE.md")
	require.Error(t, err)
	assert.Empty(t, rec.argv())
}

func TestFileAtHead_GitFailureIsAnError(t *testing.T) {
	dir := newRepo(t)
	_, _, err := FileAtHead(context.Background(), options(dir, &recorder{fail: "show"}), "README.md")
	require.Error(t, err)
}
