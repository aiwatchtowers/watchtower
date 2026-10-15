package cmd

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/gitbin"
)

// worktreeFixture is a git workbench folder with its row, the fake claude
// CLI recording every call, and a fixed watchtower binary path.
type worktreeFixture struct {
	folder string
	id     int64
	idArg  string
	mu     sync.Mutex
	calls  []string
}

func newWorktreeFixture(t *testing.T) *worktreeFixture {
	t.Helper()
	database := writeActionsConfig(t)
	folder := gitBranchRepo(t)
	id, err := database.CreateWorkbench("acme", folder)
	require.NoError(t, err)
	f := &worktreeFixture{folder: folder, id: id, idArg: strconv.FormatInt(id, 10)}
	fake := useFakeWorkbenchClaude(t)
	prevRun := workbenchCommandRunner
	workbenchCommandRunner = func(ctx context.Context, dir, name string, args ...string) ([]byte, error) {
		f.mu.Lock()
		f.calls = append(f.calls, dir+" :: "+name+" "+strings.Join(args, " "))
		f.mu.Unlock()
		return fake.run(ctx, dir, name, args...)
	}
	t.Cleanup(func() { workbenchCommandRunner = prevRun })
	prevExe := workbenchExecutable
	workbenchExecutable = func() (string, error) { return "/usr/local/bin/watchtower", nil }
	t.Cleanup(func() { workbenchExecutable = prevExe })
	return f
}

func (f *worktreeFixture) joinedCalls() string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return strings.Join(f.calls, "\n")
}

func runWorktree(t *testing.T, args ...string) (string, error) {
	t.Helper()
	stdout, _, err := runWorkbench(t, append([]string{"worktree"}, args...)...)
	resetSetFlags(workbenchWorktreeCmd.Commands()...)
	return stdout, err
}

func (f *worktreeFixture) create(t *testing.T, name string) worktreeEnvelope {
	t.Helper()
	out, err := runWorktree(t, "create", "--workbench", f.idArg, "--name", name, "--json")
	require.NoError(t, err, out)
	var env worktreeEnvelope
	require.NoError(t, json.Unmarshal([]byte(out), &env), out)
	return env
}

func readExclude(t *testing.T, folder string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(folder, ".git", "info", "exclude"))
	require.NoError(t, err)
	return string(b)
}

func TestWorkbenchWorktree_CreateInstallsTheIntegration(t *testing.T) {
	f := newWorktreeFixture(t)
	created := f.create(t, "s1")
	require.True(t, created.Created, "%+v", created)
	assert.Empty(t, created.IntegrationError)
	assert.Equal(t, f.id, created.WorkbenchID)
	assert.FileExists(t, filepath.Join(created.Cwd, ".claude", "settings.local.json"), "hooks and the cleanup permission installed in the worktree")
	assert.DirExists(t, filepath.Join(created.Cwd, ".claude", "skills", "watchtower-workbench"))
	assert.Contains(t, f.joinedCalls(), created.Cwd+" :: claude mcp add --scope local watchtower-workbench")
}

func TestWorkbenchWorktree_EnvelopeKeys(t *testing.T) {
	f := newWorktreeFixture(t)
	out, err := runWorktree(t, "create", "--workbench", f.idArg, "--name", "keys", "--json")
	require.NoError(t, err)
	var m map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &m))
	assert.Equal(t, sorted("workbench_id", "created", "path", "cwd", "branch", "base", "base_branch", "base_dirty",
		"included", "include_warnings", "refused", "refused_detail", "error", "warning", "integration_error"), keysOf(m))

	out, err = runWorktree(t, "forget", "--workbench", f.idArg, "--path", f.folder, "--json")
	require.NoError(t, err)
	m = nil
	require.NoError(t, json.Unmarshal([]byte(out), &m))
	assert.Equal(t, sorted("workbench_id", "forgot", "error"), keysOf(m))
}

func TestWorkbenchWorktree_EnsureReinstallsAndReportsTheCwd(t *testing.T) {
	f := newWorktreeFixture(t)
	c := f.create(t, "s2")
	require.True(t, c.Created)
	bin, ok := gitbin.Locate()
	require.True(t, ok)
	rm := exec.Command(bin, "worktree", "remove", "--force", c.Path)
	rm.Dir = f.folder
	rmOut, rmErr := rm.CombinedOutput()
	require.NoError(t, rmErr, string(rmOut))
	require.NoDirExists(t, c.Path)

	out, err := runWorktree(t, "ensure", "--workbench", f.idArg, "--path", c.Path, "--branch", c.Branch, "--json")
	require.NoError(t, err, out)
	var e worktreeEnvelope
	require.NoError(t, json.Unmarshal([]byte(out), &e), out)
	require.True(t, e.Created, "%s", out)
	assert.Equal(t, c.Cwd, e.Cwd)
	assert.Empty(t, e.IntegrationError)
	assert.FileExists(t, filepath.Join(c.Cwd, ".claude", "settings.local.json"))
}

func TestWorkbenchWorktree_ForgetUnregistersOnlyAndKeepsSharedExcludeLines(t *testing.T) {
	f := newWorktreeFixture(t)
	_, _, err := runRootCmd(t, []*cobra.Command{integrateClaudeCodeCmd}, "integrate", "claude-code", "--workbench", f.idArg)
	require.NoError(t, err)
	before := readExclude(t, f.folder)
	c := f.create(t, "s3")
	require.True(t, c.Created)
	f.mu.Lock()
	f.calls = nil
	f.mu.Unlock()

	out, err := runWorktree(t, "forget", "--workbench", f.idArg, "--path", c.Path, "--json")
	require.NoError(t, err, out)
	assert.Contains(t, out, `"forgot": true`)
	joined := f.joinedCalls()
	assert.Contains(t, joined, c.Cwd+" :: claude mcp remove --scope local watchtower-workbench")
	for _, line := range strings.Split(joined, "\n") {
		assert.Contains(t, line, " :: claude ", "forget runs only claude calls")
		assert.Contains(t, line, "mcp ", "forget runs only claude mcp calls")
	}
	assert.DirExists(t, c.Path, "forget never removes the worktree")
	after := readExclude(t, f.folder)
	for _, line := range strings.Split(strings.TrimSpace(before), "\n") {
		assert.Contains(t, after, line, "a line the main folder needs survives")
	}
}

func TestWorkbenchWorktree_ForgetRefusesAPathOutsideTheWorktreesDir(t *testing.T) {
	f := newWorktreeFixture(t)
	out, err := runWorktree(t, "forget", "--workbench", f.idArg, "--path", f.folder, "--json")
	require.NoError(t, err)
	assert.Contains(t, out, `"forgot": false`)
	assert.Contains(t, out, "not a session worktree")
	assert.Empty(t, f.joinedCalls())
}

func TestWorkbenchWorktree_UnknownWorkbenchExitsNonZero(t *testing.T) {
	writeActionsConfig(t)
	_, err := runWorktree(t, "create", "--workbench", "999", "--name", "x", "--json")
	require.Error(t, err)
}

func TestWorkbenchWorktree_CreateSkipsANameASessionRowHolds(t *testing.T) {
	f := newWorktreeFixture(t)
	_, database, err := openJiraCmdDB()
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	other, err := database.CreateWorkbench("other", t.TempDir())
	require.NoError(t, err)
	// A row of another workbench still names wt/held; its worktree and
	// branch were cleaned up, so only the row keeps the name taken.
	_, err = database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id, created_at, worktree_branch, worktree_base)
		VALUES (?, 'claude', 'gone', '/nowhere', 'uuid-gone', '2026-10-14T00:00:00Z', 'wt/held', 'abc')`, other)
	require.NoError(t, err)

	created := f.create(t, "held")
	require.True(t, created.Created, "%+v", created)
	assert.Equal(t, "wt/held-2", created.Branch)
	assert.Equal(t, filepath.Join(f.folder, ".claude", "worktrees", "held-2"), created.Path)
}
