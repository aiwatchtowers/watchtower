package workbenchgit

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// writeSubcommands are the git subcommands that change a repository.
var writeSubcommands = []string{"switch", "stash", "checkout", "reset", "clean", "branch", "merge", "restore"}

// assertNoWrites: rec saw no git call that could change the repository.
func assertNoWrites(t *testing.T, rec *recorder) {
	t.Helper()
	for _, c := range rec.argv() {
		if len(c) > 0 && slices.Contains(writeSubcommands, c[0]) {
			t.Errorf("a refused switch ran a write: git %s", strings.Join(c, " "))
		}
	}
}

// dirty leaves a modified tracked file and an untracked one in dir.
func dirty(t *testing.T, dir string) {
	t.Helper()
	writeFile(t, dir, "README.md", "edited\n")
	writeFile(t, dir, "notes.txt", "untracked\n")
}

// snapshot is what a refused switch must leave untouched.
func snapshot(t *testing.T, dir string) string {
	t.Helper()
	notes, err := os.ReadFile(filepath.Join(dir, "notes.txt"))
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	return strings.Join([]string{
		gitIn(t, dir, "rev-parse", "HEAD"),
		gitIn(t, dir, "symbolic-ref", "-q", "HEAD"),
		gitIn(t, dir, "stash", "list"),
		readFile(t, dir, "README.md"),
		string(notes),
	}, "\x00")
}

func TestProj10_RefusesDirtyWithoutStash(t *testing.T) {
	dir := newRepo(t)
	dirty(t, dir)
	before := snapshot(t, dir)
	rec := &recorder{}
	res := Switch(context.Background(), options(dir, rec), SwitchRequest{Branch: "feature"})
	assert.Equal(t, []string{NeedUncommitted}, res.NeedsConfirmation)
	assert.Equal(t, 2, res.Changes)
	assert.False(t, res.Switched)
	assert.Empty(t, res.Refused)
	assert.Empty(t, res.Stashed)
	assertNoWrites(t, rec)
	assert.Equal(t, before, snapshot(t, dir), "HEAD, files and the stash list are untouched")
}

func TestProj10_RefusesAgentRunningWithoutConfirm(t *testing.T) {
	dir := newRepo(t)
	before := snapshot(t, dir)
	rec := &recorder{}
	res := Switch(context.Background(), options(dir, rec), SwitchRequest{Branch: "feature", AgentRunning: true})
	assert.Equal(t, []string{NeedAgent}, res.NeedsConfirmation)
	assert.False(t, res.Switched)
	assertNoWrites(t, rec)
	assert.Equal(t, before, snapshot(t, dir))

	// Stashing confirms the changes, never the agent.
	res = Switch(context.Background(), options(dir, rec), SwitchRequest{Branch: "feature", AgentRunning: true, Stash: true})
	assert.Equal(t, []string{NeedAgent}, res.NeedsConfirmation)
	assertNoWrites(t, rec)
}

func TestProj10_ListsBothConfirmations(t *testing.T) {
	dir := newRepo(t)
	dirty(t, dir)
	before := snapshot(t, dir)
	rec := &recorder{}
	res := Switch(context.Background(), options(dir, rec), SwitchRequest{Branch: "feature", AgentRunning: true})
	assert.Equal(t, []string{NeedUncommitted, NeedAgent}, res.NeedsConfirmation)
	assertNoWrites(t, rec)
	assert.Equal(t, before, snapshot(t, dir))
}

func TestProj10_StashAndSwitch(t *testing.T) {
	dir := newRepo(t)
	dirty(t, dir)
	res := Switch(context.Background(), options(dir, &recorder{}), SwitchRequest{Branch: "feature", Stash: true})
	require.True(t, res.Switched, "%+v", res)
	assert.Empty(t, res.Error)
	assert.Empty(t, res.NeedsConfirmation)
	assert.Regexp(t, `^watchtower: switching from main to feature \[[0-9a-f]{16}\]$`, res.StashMessage)
	assert.Equal(t, gitIn(t, dir, "rev-parse", "refs/stash"), res.Stashed, "stashed names the stash commit")
	assert.False(t, res.StashRestored)
	assert.Equal(t, "refs/heads/feature", gitIn(t, dir, "symbolic-ref", "HEAD"))
	assert.Equal(t, "feature", res.Status.Branch)
	assert.False(t, res.Status.Dirty, "the worktree is clean after the switch")
	assert.Equal(t, "hello\n", readFile(t, dir, "README.md"))
	assert.NoFileExists(t, filepath.Join(dir, "notes.txt"), "untracked files go into the stash")
	assert.Contains(t, gitIn(t, dir, "stash", "list"), res.StashMessage, "the stash stays; never popped after a switch")
}

func TestProj10_ConfirmedAgentSwitches(t *testing.T) {
	dir := newRepo(t)
	res := Switch(context.Background(), options(dir, &recorder{}), SwitchRequest{Branch: "feature", AgentRunning: true, ConfirmAgent: true})
	require.True(t, res.Switched, "%+v", res)
	assert.Empty(t, res.Stashed, "a clean worktree is never stashed")
	assert.Equal(t, "refs/heads/feature", gitIn(t, dir, "symbolic-ref", "HEAD"))
}

func TestProj10_CheckedOutElsewhereIsRefusedWithAllFlags(t *testing.T) {
	dir := newRepo(t)
	linked := filepath.Join(filepath.Dir(dir), filepath.Base(dir)+"-wt")
	t.Cleanup(func() { _ = os.RemoveAll(linked) })
	gitIn(t, dir, "worktree", "add", "-q", linked, "feature")
	dirty(t, dir)
	before := snapshot(t, dir)
	rec := &recorder{}
	res := Switch(context.Background(), options(dir, rec),
		SwitchRequest{Branch: "feature", Stash: true, AgentRunning: true, ConfirmAgent: true})
	assert.Equal(t, RefusedCheckedOutElsewhere, res.Refused)
	assert.True(t, sameDir(t, linked, res.RefusedDetail), res.RefusedDetail)
	assert.False(t, res.Switched)
	assertNoWrites(t, rec)
	assert.Equal(t, before, snapshot(t, dir))
}

func TestProj10_UnknownOrOptionLikeBranchIsRefused(t *testing.T) {
	dir := newRepo(t)
	gitIn(t, dir, "update-ref", "refs/remotes/origin/main", "HEAD")
	before := snapshot(t, dir)
	for _, name := range []string{"-f", "--force", "origin/main", "HEAD~1", "HEAD", "nonexistent", ""} {
		rec := &recorder{}
		res := Switch(context.Background(), options(dir, rec),
			SwitchRequest{Branch: name, Stash: true, AgentRunning: true, ConfirmAgent: true})
		assert.Equal(t, RefusedUnknownBranch, res.Refused, "%q", name)
		assert.False(t, res.Switched, "%q", name)
		assertNoWrites(t, rec)
	}
	assert.Equal(t, before, snapshot(t, dir))
}

func TestProj10_OperationInProgressIsRefused(t *testing.T) {
	dir := newRepo(t)
	gitIn(t, dir, "branch", "other")
	commit(t, dir, "feature.txt", "main side\n", "main side")
	_, _, err := execRunner(context.Background(), dir, nil, gitBin(t), "merge", "feature")
	require.Error(t, err, "the merge must conflict")
	rec := &recorder{}
	res := Switch(context.Background(), options(dir, rec),
		SwitchRequest{Branch: "other", Stash: true, AgentRunning: true, ConfirmAgent: true})
	assert.Equal(t, RefusedOperationInProgress, res.Refused)
	assert.Equal(t, "merge", res.RefusedDetail)
	assertNoWrites(t, rec)
	assert.Equal(t, "refs/heads/main", gitIn(t, dir, "symbolic-ref", "HEAD"))
}

func TestProj10_FailedSwitchRestoresTheStash(t *testing.T) {
	dir := newRepo(t)
	dirty(t, dir)
	rec := &recorder{fail: "switch"}
	res := Switch(context.Background(), options(dir, rec), SwitchRequest{Branch: "feature", Stash: true})
	assert.False(t, res.Switched)
	assert.Contains(t, res.Error, "simulated switch failure")
	assert.NotEmpty(t, res.Stashed)
	assert.True(t, res.StashRestored, res.StashError)
	assert.Empty(t, res.StashError)
	assert.Equal(t, "edited\n", readFile(t, dir, "README.md"), "the tracked change is back")
	assert.Equal(t, "untracked\n", readFile(t, dir, "notes.txt"), "the untracked file is back")
	assert.Equal(t, map[string]string{res.Stashed: res.StashMessage}, stashes(t, dir), "applied, never popped or dropped")
	assert.Equal(t, "refs/heads/main", gitIn(t, dir, "symbolic-ref", "HEAD"))
	assert.True(t, res.Status.Dirty)
}

func TestProj10_AlreadyOnBranchIsANoOp(t *testing.T) {
	dir := newRepo(t)
	dirty(t, dir)
	before := snapshot(t, dir)
	rec := &recorder{}
	res := Switch(context.Background(), options(dir, rec), SwitchRequest{Branch: "main", AgentRunning: true})
	assert.True(t, res.Already)
	assert.False(t, res.Switched)
	assert.Empty(t, res.NeedsConfirmation)
	assertNoWrites(t, rec)
	assert.Equal(t, before, snapshot(t, dir))
}

func TestProj10_DetachedSwitchesAwayWithTheDirtyGuard(t *testing.T) {
	dir := newRepo(t)
	gitIn(t, dir, "switch", "-q", "--detach", "feature")
	head := gitIn(t, dir, "rev-parse", "--short=7", "HEAD")
	dirty(t, dir)
	res := Switch(context.Background(), options(dir, &recorder{}), SwitchRequest{Branch: "feature"})
	assert.Equal(t, []string{NeedUncommitted}, res.NeedsConfirmation, "detached on feature's commit is not 'already' on feature")
	res = Switch(context.Background(), options(dir, &recorder{}), SwitchRequest{Branch: "main", Stash: true})
	require.True(t, res.Switched, "%+v", res)
	assert.True(t, strings.HasPrefix(res.StashMessage, "watchtower: switching from "+head+" to main ["), res.StashMessage)
}

func TestProj10_NoGitIsRefused(t *testing.T) {
	gitBin(t)
	rec := &recorder{}
	res := Switch(context.Background(), options(t.TempDir(), rec), SwitchRequest{Branch: "main", Stash: true, ConfirmAgent: true})
	assert.Equal(t, RefusedNotGit, res.Refused)
	o := options(newRepo(t), rec)
	o.Locate = func() (string, bool) { return "", false }
	res = Switch(context.Background(), o, SwitchRequest{Branch: "feature"})
	assert.Equal(t, RefusedGitUnavailable, res.Refused)
	assert.False(t, res.Status.GitAvailable)
	res = Create(context.Background(), o, "topic")
	assert.Equal(t, RefusedGitUnavailable, res.Refused)
	assert.Empty(t, rec.argv(), "no git process without git or outside a repository")
}

// No git call this package makes, on any path, forces, discards, resets,
// cleans, checks out or drops a stash.
func TestProj10_NeverForcesOrDiscards(t *testing.T) {
	dir := newRepo(t)
	rec := &recorder{}
	o := options(dir, rec)
	ctx := context.Background()
	dirty(t, dir)
	Switch(ctx, o, SwitchRequest{Branch: "feature"})
	Switch(ctx, o, SwitchRequest{Branch: "-f", Stash: true})
	rec.fail = "switch"
	Switch(ctx, o, SwitchRequest{Branch: "feature", Stash: true, AgentRunning: true, ConfirmAgent: true})
	rec.fail = ""
	Switch(ctx, o, SwitchRequest{Branch: "feature", Stash: true, AgentRunning: true, ConfirmAgent: true})
	Create(ctx, o, "topic")
	Create(ctx, o, "feature")
	Create(ctx, o, "-f")
	ReadStatus(ctx, o)
	ListBranches(ctx, o)

	forbidden := []string{"--force", "-f", "--discard-changes", "-C", "--force-create", "--hard", "reset", "clean", "checkout", "pop", "drop", "clear"}
	require.NotEmpty(t, rec.argv())
	for _, c := range rec.argv() {
		for _, a := range c {
			assert.NotContains(t, forbidden, a, "git %s", strings.Join(c, " "))
		}
	}
	assert.True(t, rec.ran("stash") && rec.ran("switch"), "the scenario reached the writes")
}

func TestProj10_CreateCarriesTheChanges(t *testing.T) {
	dir := newRepo(t)
	dirty(t, dir)
	res := Create(context.Background(), options(dir, &recorder{}), "topic/new")
	require.True(t, res.Created, "%+v", res)
	assert.True(t, res.Switched)
	assert.Empty(t, res.Stashed, "a create never stashes")
	assert.Equal(t, "topic/new", res.Status.Branch)
	assert.Equal(t, 2, res.Status.Changes, "the changes come along")
	assert.Equal(t, "edited\n", readFile(t, dir, "README.md"))
	assert.Equal(t, gitIn(t, dir, "rev-parse", "main"), gitIn(t, dir, "rev-parse", "HEAD"), "cut from HEAD")
}

func TestProj10_CreateRefusesAnExistingBranch(t *testing.T) {
	dir := newRepo(t)
	rec := &recorder{}
	res := Create(context.Background(), options(dir, rec), "feature")
	assert.Equal(t, RefusedExists, res.Refused)
	assert.False(t, res.Created)
	assertNoWrites(t, rec)
}

func TestProj10_CreateRefusesAnInvalidName(t *testing.T) {
	dir := newRepo(t)
	gitIn(t, dir, "switch", "-q", "feature")
	gitIn(t, dir, "switch", "-q", "main")
	for _, name := range []string{"a..b", "-x", "", "foo.lock", "@{-1}", "has space", "HEAD"} {
		rec := &recorder{}
		res := Create(context.Background(), options(dir, rec), name)
		assert.Equal(t, RefusedInvalidName, res.Refused, "%q", name)
		assert.False(t, res.Created, "%q", name)
		assertNoWrites(t, rec)
	}
	assert.Equal(t, "refs/heads/main", gitIn(t, dir, "symbolic-ref", "HEAD"))
}

// stashes maps each stash entry's commit id to its message (the reflog
// subject without git's "On <branch>: " prefix).
func stashes(t *testing.T, dir string) map[string]string {
	t.Helper()
	m := map[string]string{}
	for _, line := range strings.Split(gitIn(t, dir, "stash", "list", "--format=%H %gs"), "\n") {
		if line == "" {
			continue
		}
		sha, subject, _ := strings.Cut(line, " ")
		_, msg, _ := strings.Cut(subject, ": ")
		m[sha] = msg
	}
	return m
}

// pushForeignStash stashes an untracked file the way another session would.
func pushForeignStash(t *testing.T, dir string) string {
	t.Helper()
	writeFile(t, dir, "foreign.txt", "another session\n")
	gitIn(t, dir, "stash", "push", "-q", "--include-untracked", "-m", "another session's work")
	return gitIn(t, dir, "rev-parse", "refs/stash")
}

func TestProj10_FailedSwitchLeavesAForeignStashAlone(t *testing.T) {
	dir := newRepo(t)
	foreign := pushForeignStash(t, dir)
	dirty(t, dir)
	res := Switch(context.Background(), options(dir, &recorder{fail: "switch"}), SwitchRequest{Branch: "feature", Stash: true})
	assert.False(t, res.Switched)
	require.True(t, res.StashRestored, res.StashError)
	assert.Equal(t, map[string]string{foreign: "another session's work", res.Stashed: res.StashMessage}, stashes(t, dir))
	assert.Equal(t, "edited\n", readFile(t, dir, "README.md"))
	assert.NoFileExists(t, filepath.Join(dir, "foreign.txt"), "the foreign stash is not applied")
}

func TestProj10_FailedSwitchRestoresOursPastAConcurrentStash(t *testing.T) {
	dir := newRepo(t)
	dirty(t, dir)
	var foreign string
	rec := &recorder{fail: "switch"}
	rec.before = func(args []string) {
		if len(args) > 0 && args[0] == "switch" {
			foreign = pushForeignStash(t, dir) // another session stashes while the switch runs
		}
	}
	res := Switch(context.Background(), options(dir, rec), SwitchRequest{Branch: "feature", Stash: true})
	assert.False(t, res.Switched)
	require.NotEmpty(t, foreign)
	require.True(t, res.StashRestored, res.StashError)
	assert.NotEqual(t, foreign, res.Stashed)
	assert.Equal(t, map[string]string{foreign: "another session's work", res.Stashed: res.StashMessage}, stashes(t, dir),
		"both entries stay on the stack")
	assert.Equal(t, "edited\n", readFile(t, dir, "README.md"), "our tracked change is back")
	assert.Equal(t, "untracked\n", readFile(t, dir, "notes.txt"), "our untracked file is back")
	assert.NoFileExists(t, filepath.Join(dir, "foreign.txt"), "the other session's change stays in its stash")
	for _, c := range rec.argv() {
		assert.NotContains(t, c, "pop", "git %s", strings.Join(c, " "))
	}
}

func TestProj10_FailedStashPushReportsTheStashItMade(t *testing.T) {
	dir := newRepo(t)
	dirty(t, dir)
	rec := &recorder{failAfter: "stash push"}
	res := Switch(context.Background(), options(dir, rec), SwitchRequest{Branch: "feature", Stash: true})
	assert.False(t, res.Switched)
	assert.False(t, rec.ran("switch"), "no switch after a failed stash")
	require.NotEmpty(t, res.Stashed, "%+v", res)
	assert.Equal(t, map[string]string{res.Stashed: res.StashMessage}, stashes(t, dir))
	assert.Contains(t, res.Error, "a stash was created")
	assert.Contains(t, res.Error, "simulated stash push failure")
	assert.Equal(t, "refs/heads/main", gitIn(t, dir, "symbolic-ref", "HEAD"))
}

// failPostCheckout installs a post-checkout hook that complains and fails;
// git has already moved HEAD and the files when it runs.
func failPostCheckout(t *testing.T, dir string) {
	t.Helper()
	hooks := filepath.Join(dir, gitIn(t, dir, "rev-parse", "--git-path", "hooks"))
	require.NoError(t, os.MkdirAll(hooks, 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(hooks, "post-checkout"),
		[]byte("#!/bin/sh\necho 'hook says no' >&2\nexit 3\n"), 0o755))
}

func TestProj10_FailingHookAfterTheSwitchCountsAsSwitched(t *testing.T) {
	dir := newRepo(t)
	failPostCheckout(t, dir)
	dirty(t, dir)
	res := Switch(context.Background(), options(dir, &recorder{}), SwitchRequest{Branch: "feature", Stash: true})
	assert.True(t, res.Switched, "%+v", res)
	assert.Empty(t, res.Error)
	assert.Contains(t, res.Warning, "hook says no")
	assert.Equal(t, "refs/heads/feature", gitIn(t, dir, "symbolic-ref", "HEAD"))
	assert.False(t, res.StashRestored, "the stash is not applied onto the new branch")
	assert.Equal(t, "hello\n", readFile(t, dir, "README.md"))
	assert.Equal(t, map[string]string{res.Stashed: res.StashMessage}, stashes(t, dir))
	assert.Equal(t, "feature", res.Status.Branch)

	res = Create(context.Background(), options(dir, &recorder{}), "topic")
	assert.True(t, res.Created, "%+v", res)
	assert.True(t, res.Switched)
	assert.Empty(t, res.Error)
	assert.Contains(t, res.Warning, "hook says no")
	assert.Equal(t, "refs/heads/topic", gitIn(t, dir, "symbolic-ref", "HEAD"))
}

// An ignored file the target branch tracks is the owner's: the switch
// refuses to overwrite it instead of silently replacing its content.
func TestProj10_SwitchNeverOverwritesAnIgnoredFile(t *testing.T) {
	dir := newRepo(t)
	gitIn(t, dir, "switch", "-q", "feature")
	commit(t, dir, ".env", "SECRET=feature\n", "track .env")
	gitIn(t, dir, "switch", "-q", "main")
	commit(t, dir, ".gitignore", ".env\n", "ignore .env")
	writeFile(t, dir, ".env", "SECRET=owner\n")
	require.False(t, ReadStatus(context.Background(), options(dir, &recorder{})).Dirty, "an ignored file is not a change")

	res := Switch(context.Background(), options(dir, &recorder{}), SwitchRequest{Branch: "feature"})
	assert.False(t, res.Switched, "%+v", res)
	assert.Contains(t, res.Error, ".env")
	assert.Equal(t, "SECRET=owner\n", readFile(t, dir, ".env"), "the owner's file is untouched")
	assert.Equal(t, "refs/heads/main", gitIn(t, dir, "symbolic-ref", "HEAD"))
}

func TestProj10_GitFailureIsRefusedAsGitFailed(t *testing.T) {
	dir := newRepo(t)
	rec := &recorder{}
	o := options(filepath.Join(dir, ".git"), rec)
	res := Switch(context.Background(), o, SwitchRequest{Branch: "feature", Stash: true, ConfirmAgent: true})
	assert.Equal(t, RefusedGitFailed, res.Refused)
	assert.Contains(t, res.RefusedDetail, "work tree")
	res = Create(context.Background(), o, "topic")
	assert.Equal(t, RefusedGitFailed, res.Refused)
	assertNoWrites(t, rec)
}

func TestProj10_CanceledSwitchStillReadsTheStatusAfter(t *testing.T) {
	dir := newRepo(t)
	dirty(t, dir)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	rec := &recorder{}
	rec.before = func(args []string) {
		if len(args) > 0 && args[0] == "switch" {
			cancel()
		}
	}
	res := Switch(ctx, options(dir, rec), SwitchRequest{Branch: "feature", Stash: true})
	assert.False(t, res.Switched)
	assert.Equal(t, "git switch was canceled", res.Error)
	assert.True(t, res.StashRestored, res.StashError)
	assert.True(t, res.Status.StatusOK, "the status after is read on its own budget: %s", res.Status.StatusError)
	assert.True(t, res.Status.Dirty)
}

func TestProj10_CheckRefFormatFailureIsNotAnInvalidName(t *testing.T) {
	dir := newRepo(t)
	rec := &recorder{fail: "check-ref-format"}
	res := Create(context.Background(), options(dir, rec), "topic")
	assert.Empty(t, res.Refused)
	assert.False(t, res.Created)
	assert.Contains(t, res.Error, "simulated check-ref-format failure")
	assertNoWrites(t, rec)
}
