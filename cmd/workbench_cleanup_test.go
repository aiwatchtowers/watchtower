package cmd

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/gitbin"
	"watchtower/internal/sessioncleanup"
)

// cleanupFixture is a workbench bound to a repository on main, pushed to a
// bare "origin" (origin/HEAD set), and one claude session of it that
// started an hour ago. The process scan is faked empty and LaunchServices
// is off; git, the database and sizes are real.
type cleanupFixture struct {
	t        *testing.T
	database *db.DB
	base     string
	repo     string
	wb       int64
	session  int64
	git      string
	// results replaces the result store when set.
	results sessioncleanup.ResultStore
}

type noCleanupProcs struct{}

func (noCleanupProcs) Scan(context.Context) ([]sessioncleanup.Proc, error) { return nil, nil }
func (noCleanupProcs) Terminate(sessioncleanup.Proc) error                 { return nil }

type failingCleanupResults struct{}

func (failingCleanupResults) SaveCleanupResult(context.Context, int64, string, string) error {
	return errors.New("database is locked")
}

// mtimeBirth stands in for the filesystem birth time (darwin-only): a
// fixture's worktree admin dir is fresh, so its mtime is its birth.
func mtimeBirth(adminDir string) (time.Time, bool) {
	fi, err := os.Stat(adminDir)
	if err != nil {
		return time.Time{}, false
	}
	return fi.ModTime(), true
}

func newCleanupFixture(t *testing.T) *cleanupFixture {
	t.Helper()
	bin, ok := gitbin.Locate()
	if !ok {
		t.Skip("git is not available")
	}
	for k, v := range map[string]string{
		"GIT_CONFIG_GLOBAL": os.DevNull, "GIT_CONFIG_NOSYSTEM": "1",
		"GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
		"GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
		"GIT_CONFIG_COUNT": "2", "GIT_CONFIG_KEY_0": "maintenance.auto", "GIT_CONFIG_VALUE_0": "false",
		"GIT_CONFIG_KEY_1": "gc.auto", "GIT_CONFIG_VALUE_1": "0",
		terminalSessionEnv: "",
	} {
		t.Setenv(k, v)
	}
	f := &cleanupFixture{t: t, database: writeActionsConfig(t), git: bin}
	base, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	f.base, f.repo = base, filepath.Join(base, "repo")
	f.gitIn(base, "init", "-q", "--bare", "-b", "main", "remote.git")
	f.gitIn(base, "init", "-q", "-b", "main", "repo")
	f.commit(f.repo, "README.md")
	f.gitIn(f.repo, "remote", "add", "origin", filepath.Join(base, "remote.git"))
	f.gitIn(f.repo, "push", "-q", "-u", "origin", "main")
	f.gitIn(f.repo, "remote", "set-head", "origin", "main")
	f.wb, err = f.database.CreateWorkbench("acme", f.repo)
	require.NoError(t, err)
	f.session = f.addSession(f.wb)
	orig := cleanupDeps
	cleanupDeps = func(d *db.DB) sessioncleanup.Deps {
		deps := orig(d)
		deps.Procs, deps.LS, deps.WorktreeBirth = noCleanupProcs{}, nil, mtimeBirth
		if f.results != nil {
			deps.Results = f.results
		}
		return deps
	}
	t.Cleanup(func() { cleanupDeps = orig })
	return f
}

// addSession adds a claude session of workbench wb that started an hour
// ago, before anything the test creates.
func (f *cleanupFixture) addSession(wb int64) int64 {
	f.t.Helper()
	start := time.Now().Add(-time.Hour).UTC().Format(time.RFC3339)
	res, err := f.database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id, created_at)
		VALUES (?, 'claude', 'cleanup test', ?, ?, ?)`, wb, f.repo, "c-"+start+strconv.FormatInt(wb, 10), start)
	require.NoError(f.t, err)
	id, err := res.LastInsertId()
	require.NoError(f.t, err)
	return id
}

func (f *cleanupFixture) gitIn(dir string, args ...string) {
	f.t.Helper()
	c := exec.Command(f.git, args...)
	c.Dir = dir
	out, err := c.CombinedOutput()
	require.NoError(f.t, err, "git %v: %s", args, out)
}

func (f *cleanupFixture) commit(dir, name string) {
	f.t.Helper()
	require.NoError(f.t, os.WriteFile(filepath.Join(dir, name), []byte("work\n"), 0o644))
	f.gitIn(dir, "add", name)
	f.gitIn(dir, "commit", "-q", "-m", "change "+name)
}

// pushedWorktree adds a worktree on a new branch carrying one pushed
// commit, recorded in the session's ledger: nothing in it is at risk.
func (f *cleanupFixture) pushedWorktree(name, branch string) string {
	f.t.Helper()
	root := filepath.Join(f.base, name)
	f.gitIn(f.repo, "worktree", "add", "-q", "-b", branch, root, "main")
	f.commit(root, name+".txt")
	f.gitIn(root, "push", "-q", "origin", branch)
	_, err := f.database.RecordSessionWorktree(context.Background(), nil, f.session, root, branch,
		db.AgentStateStamp(time.Now()))
	require.NoError(f.t, err)
	return root
}

func (f *cleanupFixture) sessionArg() string { return strconv.FormatInt(f.session, 10) }

func runCleanupCmd(t *testing.T, args ...string) (string, error) {
	t.Helper()
	out, errOut, err := runWorkbenchAs(t, "workbench", append([]string{"cleanup"}, args...)...)
	return out + errOut, err
}

func decodeCleanup(t *testing.T, out string) sessioncleanup.Result {
	t.Helper()
	var res sessioncleanup.Result
	require.NoError(t, json.Unmarshal([]byte(out), &res), out)
	return res
}

func cleanupItem(t *testing.T, res sessioncleanup.Result, key string) sessioncleanup.Item {
	t.Helper()
	for _, it := range res.Items {
		if it.Key == key {
			return it
		}
	}
	t.Fatalf("no item %s in %+v", key, res.Items)
	return sessioncleanup.Item{}
}

func requireExitCode(t *testing.T, err error, code int) {
	t.Helper()
	var ec *exitCodeError
	require.ErrorAs(t, err, &ec)
	assert.Equal(t, code, ec.code, "%v", err)
}

func (f *cleanupFixture) storedResult() sql.NullString {
	f.t.Helper()
	var stored sql.NullString
	require.NoError(f.t, f.database.QueryRow(`SELECT cleanup_result FROM terminal_sessions WHERE id = ?`, f.session).Scan(&stored))
	return stored
}

func TestCleanupCmd_PlanIsDefaultAndJSONShape(t *testing.T) {
	f := newCleanupFixture(t)
	root := f.pushedWorktree("wt", "feat/x")

	out, err := runCleanupCmd(t, "--session", f.sessionArg(), "--json")
	require.NoError(t, err, out)

	var raw map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &raw), out)
	for _, k := range []string{"session_id", "workbench_id", "mode", "sweep", "items", "removed_bytes",
		"removed_bytes_known", "summary", "result_saved", "result_error"} {
		assert.Contains(t, raw, k)
	}
	items, ok := raw["items"].([]any)
	require.True(t, ok, "items is an array: %s", out)
	require.NotEmpty(t, items)
	for _, k := range []string{"key", "kind", "name", "branch", "bytes", "bytes_known", "action", "reason",
		"detail", "done", "error"} {
		assert.Contains(t, items[0], k)
	}

	res := decodeCleanup(t, out)
	assert.Equal(t, sessioncleanup.ModePlan, res.Mode)
	assert.Equal(t, f.session, res.SessionID)
	assert.Equal(t, f.wb, res.WorkbenchID)
	assert.False(t, res.Sweep)
	assert.True(t, res.RemovedBytesKnown)
	assert.False(t, res.ResultSaved)
	wt := cleanupItem(t, res, "worktree:"+root)
	assert.Equal(t, sessioncleanup.ActionRemove, wt.Action, "%+v", wt)
	assert.False(t, wt.Done)
	assert.Equal(t, sessioncleanup.ActionRemove, cleanupItem(t, res, "branch:feat/x").Action)
	assert.Contains(t, res.Summary, "to remove")
	// A plan writes nothing.
	assert.DirExists(t, root)
	assert.False(t, f.storedResult().Valid)
}

func TestCleanupJSON_EmptyPlanHasEmptyItems(t *testing.T) {
	f := newCleanupFixture(t)

	out, err := runCleanupCmd(t, "--session", f.sessionArg(), "--json")
	require.NoError(t, err, out)
	assert.Contains(t, out, `"items": []`)
	assert.NotContains(t, out, `"items": null`)
	res := decodeCleanup(t, out)
	assert.Equal(t, "nothing to clean up", res.Summary)
}

func TestCleanupCmd_SessionFromEnv(t *testing.T) {
	f := newCleanupFixture(t)
	t.Setenv(terminalSessionEnv, f.sessionArg())

	out, err := runCleanupCmd(t, "--json")
	require.NoError(t, err, out)
	res := decodeCleanup(t, out)
	assert.Equal(t, f.session, res.SessionID)
	assert.Equal(t, f.wb, res.WorkbenchID)
}

// Every refused invocation is exit 2 and does nothing.
func TestCleanupCmd_NoSessionIsUsageError(t *testing.T) {
	f := newCleanupFixture(t)
	root := f.pushedWorktree("wt", "feat/x")
	wb := strconv.FormatInt(f.wb, 10)
	cases := []struct {
		name string
		env  string
		args []string
	}{
		{"no session", "", []string{"--apply"}},
		{"env not an id", "abc", []string{"--apply"}},
		{"sweep without workbench", "", []string{"--sweep"}},
		{"sweep with session", "", []string{"--sweep", "--workbench", wb, "--session", f.sessionArg()}},
		{"sweep apply without items", "", []string{"--sweep", "--workbench", wb, "--apply"}},
		{"sweep with declared worktree", "", []string{"--sweep", "--workbench", wb, "--worktree", root}},
		{"item without apply", "", []string{"--session", f.sessionArg(), "--item", "worktree:" + root}},
		{"unknown session", "", []string{"--session", "999999", "--apply"}},
		{"unknown workbench", "", []string{"--sweep", "--workbench", "999999"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Setenv(terminalSessionEnv, c.env)
			out, err := runCleanupCmd(t, c.args...)
			requireExitCode(t, err, 2)
			assert.Empty(t, out)
		})
	}
	assert.DirExists(t, root)
	assert.False(t, f.storedResult().Valid)
}

func TestCleanupCmd_SessionOfAnotherWorkbenchRefused(t *testing.T) {
	f := newCleanupFixture(t)
	root := f.pushedWorktree("wt", "feat/x")
	otherFolder, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	other, err := f.database.CreateWorkbench("other", otherFolder)
	require.NoError(t, err)

	_, err = runCleanupCmd(t, "--session", f.sessionArg(), "--workbench", strconv.FormatInt(other, 10), "--apply")
	requireExitCode(t, err, 2)
	assert.Contains(t, err.Error(), "belongs to workbench")
	assert.DirExists(t, root)
	assert.False(t, f.storedResult().Valid)
}

func TestCleanupCmd_ApplySavesTheResult(t *testing.T) {
	f := newCleanupFixture(t)
	root := f.pushedWorktree("wt", "feat/x")

	out, err := runCleanupCmd(t, "--session", f.sessionArg(), "--workbench", strconv.FormatInt(f.wb, 10),
		"--apply", "--json")
	require.NoError(t, err, out)
	res := decodeCleanup(t, out)
	assert.Equal(t, sessioncleanup.ModeApply, res.Mode)
	assert.True(t, cleanupItem(t, res, "worktree:"+root).Done, out)
	assert.True(t, cleanupItem(t, res, "branch:feat/x").Done, out)
	assert.NoDirExists(t, root)
	assert.True(t, res.ResultSaved, res.ResultError)
	assert.Empty(t, res.ResultError)

	stored := f.storedResult()
	require.True(t, stored.Valid)
	saved := decodeCleanup(t, stored.String)
	assert.Equal(t, sessioncleanup.ModeApply, saved.Mode)
	assert.True(t, saved.ResultSaved)
	assert.Len(t, saved.Items, len(res.Items))
}

// A failed write of cleanup_result does not fail the command: the removal
// happened, and the envelope says the result was not saved.
func TestCleanupCmd_ResultSaveFailureIsReportedNotFatal(t *testing.T) {
	f := newCleanupFixture(t)
	f.results = failingCleanupResults{}
	root := f.pushedWorktree("wt", "feat/x")

	out, err := runCleanupCmd(t, "--session", f.sessionArg(), "--apply", "--json")
	require.NoError(t, err, out)
	res := decodeCleanup(t, out)
	assert.True(t, cleanupItem(t, res, "worktree:"+root).Done)
	assert.False(t, res.ResultSaved)
	assert.Contains(t, res.ResultError, "database is locked")

	text, err := runCleanupCmd(t, "--session", f.sessionArg(), "--apply")
	require.NoError(t, err, text)
	assert.Contains(t, text, "result not saved: database is locked")
}

func TestCleanupCmd_TextModePrintsSummaryAndReasons(t *testing.T) {
	f := newCleanupFixture(t)
	root := f.pushedWorktree("wt", "feat/x")
	require.NoError(t, os.WriteFile(filepath.Join(root, "draft.txt"), []byte("unsaved\n"), 0o644))

	out, err := runCleanupCmd(t, "--session", f.sessionArg())
	require.NoError(t, err, out)
	assert.Contains(t, out, "Cleanup plan: session "+f.sessionArg())
	assert.Contains(t, out, "keep    worktree wt [feat/x]")
	assert.Contains(t, out, "— uncommitted changes")
	assert.Contains(t, out, "kept 1 worktree")
	assert.NotContains(t, out, "result")
	assert.True(t, strings.HasSuffix(strings.TrimSpace(out), sessioncleanup.Summarize(f.planItems(t))), out)
}

// planItems is the session's plan as JSON reports it.
func (f *cleanupFixture) planItems(t *testing.T) []sessioncleanup.Item {
	t.Helper()
	out, err := runCleanupCmd(t, "--session", f.sessionArg(), "--json")
	require.NoError(t, err, out)
	return decodeCleanup(t, out).Items
}
