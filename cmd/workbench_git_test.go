package cmd

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/gitbin"
	"watchtower/internal/workbenchgit"
)

// gitBranchRepo is a repository on main with a second branch "feature",
// git located through gitbin; the owner's git config stays out.
func gitBranchRepo(t *testing.T) string {
	t.Helper()
	bin, ok := gitbin.Locate()
	if !ok {
		t.Skip("git is not available")
	}
	for k, v := range map[string]string{
		"GIT_CONFIG_GLOBAL": os.DevNull, "GIT_CONFIG_NOSYSTEM": "1",
		"GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
		"GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
	} {
		t.Setenv(k, v)
	}
	dir, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	git := func(args ...string) {
		c := exec.Command(bin, args...)
		c.Dir = dir
		out, err := c.CombinedOutput()
		require.NoError(t, err, "git %v: %s", args, out)
	}
	require.NoError(t, os.WriteFile(filepath.Join(dir, "README.md"), []byte("hello\n"), 0o644))
	git("init", "-q", "-b", "main")
	git("add", "README.md")
	git("commit", "-q", "-m", "init")
	git("branch", "feature")
	return dir
}

// runWorkbenchGit runs `workbench git <args>` and resets the nested
// subcommands' flags, which runWorkbenchAs does not reach.
func runWorkbenchGit(t *testing.T, args ...string) (string, error) {
	t.Helper()
	stdout, _, err := runWorkbenchAs(t, "workbench", append([]string{"git"}, args...)...)
	resetSetFlags(workbenchGitCmd.Commands()...)
	return stdout, err
}

// gitJSON runs a subcommand with --json for workbench id and decodes the
// envelope.
func gitJSON(t *testing.T, id int64, args ...string) map[string]any {
	t.Helper()
	out, err := runWorkbenchGit(t, append(args, "--workbench", strconv.FormatInt(id, 10), "--json")...)
	require.NoError(t, err, "a resolved workbench always exits 0: %s", out)
	var got map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &got), out)
	return got
}

func keysOf(m any) []string {
	var keys []string
	for k := range m.(map[string]any) {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	return keys
}

func sorted(keys ...string) []string {
	slices.Sort(keys)
	return keys
}

var (
	gitStatusKeys = sorted("workbench_id", "git_available", "git", "note", "branch", "detached", "unborn", "head",
		"upstream", "ahead", "behind", "dirty", "changes", "operation", "top_level", "git_dir", "common_dir",
		"status_ok", "status_error", "folder_requested", "folder_scope", "folder_root", "worktree_name")
	gitBranchesKeys = sorted("workbench_id", "git_available", "git", "note", "current", "branches", "branches_ok", "branches_error",
		"refused", "refused_detail")
	gitBranchKeys   = sorted("name", "current", "head", "committed_at", "upstream", "upstream_gone", "ahead", "behind", "worktree", "worktree_name")
	gitSwitchKeys   = sorted("workbench_id", "branch", "switched", "already", "created", "needs_confirmation", "changes",
		"refused", "refused_detail", "stashed", "stash_message", "stash_restored", "stash_error", "error", "warning", "status")
)

// The key sets the Desktop's decoders read (WorkbenchGit.swift).
func TestWorkbenchGit_EnvelopeKeys(t *testing.T) {
	database := writeActionsConfig(t)
	dir := gitBranchRepo(t)
	id, err := database.CreateWorkbench("acme", dir)
	require.NoError(t, err)

	st := gitJSON(t, id, "status")
	assert.Equal(t, gitStatusKeys, keysOf(st))
	assert.Equal(t, float64(id), st["workbench_id"])
	assert.Equal(t, "main", st["branch"])

	br := gitJSON(t, id, "branches")
	assert.Equal(t, gitBranchesKeys, keysOf(br))
	branches := br["branches"].([]any)
	require.Len(t, branches, 2)
	assert.Equal(t, gitBranchKeys, keysOf(branches[0]))

	sw := gitJSON(t, id, "switch", "--branch", "main")
	assert.Equal(t, gitSwitchKeys, keysOf(sw))
	assert.Equal(t, true, sw["already"])
	assert.Equal(t, []any{}, sw["needs_confirmation"], "an empty list marshals as []")
	assert.Equal(t, gitStatusKeys, keysOf(sw["status"]))
	assert.Equal(t, float64(id), sw["status"].(map[string]any)["workbench_id"])

	cr := gitJSON(t, id, "create", "--name", "topic")
	assert.Equal(t, gitSwitchKeys, keysOf(cr))
	assert.Equal(t, true, cr["created"])
	assert.Equal(t, "topic", cr["status"].(map[string]any)["branch"])
}

func TestWorkbenchGit_SwitchGuardsAndFlags(t *testing.T) {
	database := writeActionsConfig(t)
	dir := gitBranchRepo(t)
	id, err := database.CreateWorkbench("acme", dir)
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(filepath.Join(dir, "README.md"), []byte("edited\n"), 0o644))

	sw := gitJSON(t, id, "switch", "--branch", "feature", "--agent-running")
	assert.Equal(t, []any{"uncommitted_changes", "agent_running"}, sw["needs_confirmation"], "a confirmation is an exit-0 envelope")
	assert.Equal(t, false, sw["switched"])

	sw = gitJSON(t, id, "switch", "--branch", "nope", "--stash", "--confirm-agent")
	assert.Equal(t, "unknown_branch", sw["refused"], "a refusal is an exit-0 envelope")

	sw = gitJSON(t, id, "switch", "--branch", "feature", "--stash", "--agent-running", "--confirm-agent")
	assert.Equal(t, true, sw["switched"], "%v", sw)
	assert.Regexp(t, `^watchtower: switching from main to feature \[[0-9a-f]+\]$`, sw["stash_message"])
	assert.Equal(t, "feature", sw["status"].(map[string]any)["branch"])

	cr := gitJSON(t, id, "create", "--name", "-x")
	assert.Equal(t, "invalid_name", cr["refused"])
}

func TestWorkbenchGit_NonGitFolderIsAnEnvelope(t *testing.T) {
	database := writeActionsConfig(t)
	dir, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	id, err := database.CreateWorkbench("acme", dir)
	require.NoError(t, err)

	st := gitJSON(t, id, "status")
	assert.Equal(t, false, st["git"])
	assert.NotEmpty(t, st["note"])
	br := gitJSON(t, id, "branches")
	assert.Equal(t, []any{}, br["branches"], "no branches marshals as []")
	sw := gitJSON(t, id, "switch", "--branch", "main")
	assert.Contains(t, []any{"not_git", "git_unavailable"}, sw["refused"])

	out, err := runWorkbenchGit(t, "status", "--workbench", strconv.FormatInt(id, 10))
	require.NoError(t, err)
	assert.Contains(t, out, "git: false")
}

func TestWorkbenchGit_UnresolvedWorkbenchFails(t *testing.T) {
	database := writeActionsConfig(t)
	dir := gitBranchRepo(t)
	id, err := database.CreateWorkbench("acme", dir)
	require.NoError(t, err)
	for _, sub := range []string{"status", "branches", "switch", "create"} {
		_, err := runWorkbenchGit(t, sub, "--workbench", "999", "--json")
		assert.Error(t, err, "%s: an unknown workbench", sub)
		_, err = runWorkbenchGit(t, sub, "--json")
		assert.Error(t, err, "%s: no id", sub)
	}
	require.NoError(t, os.RemoveAll(dir))
	_, err = runWorkbenchGit(t, "status", "--workbench", strconv.FormatInt(id, 10), "--json")
	assert.ErrorContains(t, err, "missing")
}

func TestWorkbenchGit_EverySubcommandTakesWorkbenchAndJSON(t *testing.T) {
	subs := workbenchGitCmd.Commands()
	require.Len(t, subs, 4)
	for _, c := range subs {
		assert.NotNil(t, c.Flags().Lookup("workbench"), c.Name())
		assert.NotNil(t, c.Flags().Lookup("json"), c.Name())
	}
	for _, c := range subs {
		assert.NotNil(t, c.Flags().Lookup("folder"), c.Name())
	}
	for _, f := range []string{"branch", "stash", "agent-running", "confirm-agent"} {
		assert.NotNil(t, workbenchGitSwitchCmd.Flags().Lookup(f), f)
	}
	assert.NotNil(t, workbenchGitCreateCmd.Flags().Lookup("name"))
}

func TestWorkbenchGit_TextStatusLeadsWithTheError(t *testing.T) {
	var b strings.Builder
	printGitStatus(&b, workbenchgit.Status{GitAvailable: true, Git: true, StatusError: "git status timed out"})
	assert.Equal(t, "git: true\nstatus error: git status timed out\n", b.String(), "no clean-looking fields after a failed status")
}

// gitWorktree adds a linked worktree of repo on a new branch from main and
// returns its symlink-resolved path.
func gitWorktree(t *testing.T, repo, branch string) string {
	t.Helper()
	bin, _ := gitbin.Locate()
	parent, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	dir := filepath.Join(parent, branch)
	c := exec.Command(bin, "worktree", "add", "-q", "-b", branch, dir, "main")
	c.Dir = repo
	out, err := c.CombinedOutput()
	require.NoError(t, err, "git worktree add: %s", out)
	return dir
}

func TestWorkbenchGitStatusWithoutFolderIsUnchanged(t *testing.T) {
	database := writeActionsConfig(t)
	dir := gitBranchRepo(t)
	id, err := database.CreateWorkbench("acme", dir)
	require.NoError(t, err)

	st := gitJSON(t, id, "status")
	assert.Equal(t, gitStatusKeys, keysOf(st))
	assert.Equal(t, "main", st["branch"])
	assert.Equal(t, "", st["folder_requested"])
	assert.Equal(t, "main", st["folder_scope"])
	assert.Equal(t, dir, st["folder_root"])
	assert.Equal(t, "", st["worktree_name"])
	br := gitJSON(t, id, "branches")
	assert.Equal(t, "", br["refused"])
	assert.Len(t, br["branches"], 2)
}

// PROJ-10 (2026-10-12): --folder runs the command in the session's
// worktree; a folder outside the repository's worktrees is refused with
// nothing written, and status reports it over the workbench folder's status.
func TestProj10_FolderFlagEnvelopeAndRefusal(t *testing.T) {
	database := writeActionsConfig(t)
	dir := gitBranchRepo(t)
	id, err := database.CreateWorkbench("acme", dir)
	require.NoError(t, err)
	wt := gitWorktree(t, dir, "mobile-a")
	outside, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	missing := filepath.Join(outside, "gone")

	st := gitJSON(t, id, "status", "--folder", wt)
	assert.Equal(t, gitStatusKeys, keysOf(st))
	assert.Equal(t, "mobile-a", st["branch"], "the worktree's own branch")
	assert.Equal(t, "worktree", st["folder_scope"])
	assert.Equal(t, wt, st["folder_root"])
	assert.Equal(t, "mobile-a", st["worktree_name"])
	assert.Equal(t, wt, st["folder_requested"])

	st = gitJSON(t, id, "status", "--folder", missing)
	assert.Equal(t, "missing", st["folder_scope"])
	assert.Equal(t, "main", st["branch"], "the page falls back to the workbench folder")
	assert.Equal(t, dir, st["folder_root"])
	assert.Equal(t, "outside", gitJSON(t, id, "status", "--folder", outside)["folder_scope"])

	sw := gitJSON(t, id, "switch", "--folder", missing, "--branch", "feature", "--stash", "--confirm-agent")
	assert.Equal(t, gitSwitchKeys, keysOf(sw))
	assert.Equal(t, "folder_not_a_worktree", sw["refused"], "a refusal is an exit-0 envelope")
	assert.Equal(t, "missing", sw["refused_detail"])
	assert.Equal(t, false, sw["switched"])
	assert.Equal(t, "missing", sw["status"].(map[string]any)["folder_scope"])
	cr := gitJSON(t, id, "create", "--folder", outside, "--name", "topic")
	assert.Equal(t, "folder_not_a_worktree", cr["refused"])
	assert.Equal(t, "outside", cr["refused_detail"])
	br := gitJSON(t, id, "branches", "--folder", outside)
	assert.Equal(t, gitBranchesKeys, keysOf(br))
	assert.Equal(t, "folder_not_a_worktree", br["refused"])
	assert.Equal(t, []any{}, br["branches"])
	plain := gitJSON(t, id, "status")
	assert.Equal(t, "main", plain["branch"], "nothing was written")
	assert.Equal(t, "main", plain["folder_scope"])
	assert.Len(t, gitJSON(t, id, "branches")["branches"], 3, "no branch topic was created")

	sw = gitJSON(t, id, "switch", "--folder", wt, "--branch", "main")
	assert.Equal(t, "checked_out_elsewhere", sw["refused"], "main is checked out in the workbench folder")
	cr = gitJSON(t, id, "create", "--folder", wt, "--name", "topic")
	assert.Equal(t, true, cr["created"])
	assert.Equal(t, "topic", cr["status"].(map[string]any)["branch"])
	assert.Equal(t, "worktree", cr["status"].(map[string]any)["folder_scope"])
	assert.Equal(t, "main", gitJSON(t, id, "status")["branch"], "the workbench folder stayed on main")

	out, err := runWorkbenchGit(t, "switch", "--folder", missing, "--branch", "feature", "--workbench", strconv.FormatInt(id, 10))
	require.NoError(t, err)
	assert.Contains(t, out, "refused: folder_not_a_worktree missing")
	assert.NotContains(t, out, "git: false", "a refused folder read no status")
}
