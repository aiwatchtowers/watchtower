package cmd

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/gitbin"
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
		"status_ok", "status_error")
	gitBranchesKeys = sorted("workbench_id", "git_available", "git", "current", "branches", "branches_ok", "branches_error")
	gitBranchKeys   = sorted("name", "current", "head", "committed_at", "upstream", "ahead", "behind", "worktree", "worktree_name")
	gitSwitchKeys   = sorted("workbench_id", "branch", "switched", "already", "created", "needs_confirmation", "changes",
		"refused", "refused_detail", "stashed", "stash_message", "stash_restored", "error", "status")
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
	assert.Equal(t, "watchtower: switching from main to feature", sw["stash_message"])
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
	for _, f := range []string{"branch", "stash", "agent-running", "confirm-agent"} {
		assert.NotNil(t, workbenchGitSwitchCmd.Flags().Lookup(f), f)
	}
	assert.NotNil(t, workbenchGitCreateCmd.Flags().Lookup("name"))
}
