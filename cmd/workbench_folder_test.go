package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/devpack"
	"watchtower/internal/fsutil"
	"watchtower/internal/gitbin"
	"watchtower/internal/kb"
	"watchtower/internal/workbenchfolders"
)

const folderTestBin = "/usr/local/bin/watchtower"

// runFolder runs `workbench folder <args>` and resets the folder verbs'
// flags (runWorkbench resets only the direct children of workbench).
func runFolder(t *testing.T, args ...string) (stdout, stderr string, err error) {
	t.Helper()
	stdout, stderr, err = runWorkbench(t, append([]string{"folder"}, args...)...)
	resetSetFlags(workbenchFolderCmd.Commands()...)
	return stdout, stderr, err
}

// folderFixture is a workspace with fake claude, the watchtower path the
// hooks record stubbed, no session host asked, and bench "acme" on app.
type folderFixture struct {
	database *db.DB
	claude   *fakeWorkbenchClaude
	pid      int64
	app      string
}

func newFolderFixture(t *testing.T) folderFixture {
	t.Helper()
	database := writeActionsConfig(t)
	f := useFakeWorkbenchClaude(t)
	prevExe, prevLive := workbenchExecutable, folderLiveSessions
	workbenchExecutable = func() (string, error) { return folderTestBin, nil }
	folderLiveSessions = func(*config.Config, *db.DB) workbenchfolders.LiveSessions {
		return func(context.Context, int64) (int, error) { return 0, nil }
	}
	t.Cleanup(func() { workbenchExecutable, folderLiveSessions = prevExe, prevLive })
	app := repoDir(t, "app")
	pid, err := database.CreateWorkbench("acme", app)
	require.NoError(t, err)
	return folderFixture{database: database, claude: f, pid: pid, app: app}
}

// repoDir is a resolved folder named name with a .git/info (the install's
// exclude file lives there).
func repoDir(t *testing.T, name string) string {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	dir := filepath.Join(root, name)
	require.NoError(t, os.MkdirAll(filepath.Join(dir, ".git", "info"), 0o755))
	return dir
}

func (f folderFixture) id() string { return strconv.FormatInt(f.pid, 10) }

func decodeFolderResult(t *testing.T, out string) folderResultJSON {
	t.Helper()
	var res folderResultJSON
	require.NoError(t, json.Unmarshal([]byte(out), &res), out)
	return res
}

func (f folderFixture) add(t *testing.T, path string) folderResultJSON {
	t.Helper()
	out, errOut, err := runFolder(t, "add", "--workbench", f.id(), "--folder", path, "--json")
	require.NoError(t, err, errOut)
	return decodeFolderResult(t, out)
}

// The new folder's hooks carry this bench's id; the owner's own settings in
// it are kept (PROJ-04).
func TestFolderAddInstallsWithTheBenchID(t *testing.T) {
	f := newFolderFixture(t)
	hub := repoDir(t, "hub")
	settings := filepath.Join(hub, ".claude", "settings.local.json")
	require.NoError(t, os.MkdirAll(filepath.Dir(settings), 0o755))
	require.NoError(t, os.WriteFile(settings, []byte(`{"model":"sonnet","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}`), 0o644))

	res := f.add(t, hub)
	require.True(t, res.OK, res.Error)
	require.NotNil(t, res.Install)
	assert.True(t, res.Install.OK, res.Install.Error)
	require.NotNil(t, res.Folder)
	assert.Equal(t, folderJSON{ID: res.Folder.ID, Path: hub, Name: "hub", Position: 1, Installed: true}, *res.Folder)

	got, err := os.ReadFile(settings)
	require.NoError(t, err)
	assert.Contains(t, string(got), devpack.WorkbenchHookCommand(folderTestBin, f.pid), "the hook carries --workbench <id>")
	assert.Contains(t, string(got), `"sonnet"`, "PROJ-04: the owner's keys stay")
	assert.Contains(t, string(got), "echo mine", "PROJ-04: the owner's hook stays")
	assert.True(t, f.claude.registered[fakeRegistration(hub, devpack.WorkbenchMCPServerName)], "the MCP server is registered in the folder")

	var addedBy string
	require.NoError(t, f.database.QueryRow(`SELECT added_by FROM workbench_folders WHERE id = ?`, res.Folder.ID).Scan(&addedBy))
	assert.Equal(t, workbenchfolders.AddedByOwner, addedBy)
}

func TestFolderAddRecordsAnAcceptedSuggestion(t *testing.T) {
	f := newFolderFixture(t)
	out, errOut, err := runFolder(t, "add", "--workbench", f.id(), "--folder", repoDir(t, "hub"), "--added-by", "agent_suggestion", "--json")
	require.NoError(t, err, errOut)
	res := decodeFolderResult(t, out)
	require.True(t, res.OK, res.Error)
	var addedBy string
	require.NoError(t, f.database.QueryRow(`SELECT added_by FROM workbench_folders WHERE id = ?`, res.Folder.ID).Scan(&addedBy))
	assert.Equal(t, workbenchfolders.AddedByAgentSuggestion, addedBy)
}

// Spec §7 row 2: a failed install keeps the folder on the bench.
func TestFolderAddInstallFailureKeepsTheFolder(t *testing.T) {
	f := newFolderFixture(t)
	prev := folderInstall
	folderInstall = func(context.Context, *db.Workbench) error { return errors.New("disk full") }
	t.Cleanup(func() { folderInstall = prev })

	hub := repoDir(t, "hub")
	res := f.add(t, hub)
	assert.True(t, res.OK)
	require.NotNil(t, res.Install)
	assert.False(t, res.Install.OK)
	assert.Contains(t, res.Install.Error, "disk full")
	assert.False(t, res.Folder.Installed)
	_, err := f.database.LiveFolderByPath(context.Background(), f.database, hub)
	assert.NoError(t, err, "the row stays")
}

// A refusal is an ok:false result with its code (exit 0); its message
// starts with the code (D42); other_bench names the bench.
func TestFolderAddRefusalsAreResults(t *testing.T) {
	f := newFolderFixture(t)
	web := repoDir(t, "web")
	other, err := f.database.CreateWorkbench("beta", web)
	require.NoError(t, err)

	res := f.add(t, web)
	assert.False(t, res.OK)
	assert.Equal(t, workbenchfolders.CodeOtherBench, res.ErrorCode)
	assert.Regexp(t, `^other_bench: `, res.Error)
	require.NotNil(t, res.OtherBench)
	assert.Equal(t, folderBenchJSON{ID: other, Name: "beta"}, *res.OtherBench)

	res = f.add(t, f.app)
	assert.Equal(t, workbenchfolders.CodeAlreadyHere, res.ErrorCode)
	require.NotNil(t, res.Folder)
	assert.True(t, res.Folder.Home)

	res = f.add(t, filepath.Join(t.TempDir(), "gone"))
	assert.Equal(t, workbenchfolders.CodeNotFound, res.ErrorCode)

	_, _, err = runFolder(t, "add", "--workbench", f.id(), "--folder", web)
	assert.ErrorContains(t, err, "other_bench: ", "without --json the refusal is the error")
}

func TestFolderListEmptyIsAnArray(t *testing.T) {
	f := newFolderFixture(t)
	_, err := f.database.Exec(`DELETE FROM workbench_folders WHERE workbench_id = ?`, f.pid)
	require.NoError(t, err)
	out, _, err := runFolder(t, "list", "--workbench", f.id(), "--json")
	require.NoError(t, err)
	assert.JSONEq(t, `{"folders":[]}`, out)
}

func TestFolderListInPositionOrder(t *testing.T) {
	f := newFolderFixture(t)
	hub := f.add(t, repoDir(t, "hub"))
	site := f.add(t, repoDir(t, "site"))
	out, errOut, err := runFolder(t, "remove", "--workbench", f.id(), "--folder", "site", "--json")
	require.NoError(t, err, errOut)
	require.True(t, decodeFolderResult(t, out).OK, out)

	out, _, err = runFolder(t, "list", "--workbench", f.id(), "--json")
	require.NoError(t, err)
	var list folderListJSON
	require.NoError(t, json.Unmarshal([]byte(out), &list))
	require.Len(t, list.Folders, 2)
	assert.Equal(t, "app", list.Folders[0].Name)
	assert.True(t, list.Folders[0].Home)
	assert.Equal(t, hub.Folder.ID, list.Folders[1].ID)

	out, _, err = runFolder(t, "list", "--workbench", f.id(), "--with-removed", "--json")
	require.NoError(t, err)
	require.NoError(t, json.Unmarshal([]byte(out), &list))
	require.Len(t, list.Folders, 3)
	assert.Equal(t, site.Folder.ID, list.Folders[2].ID)
	assert.True(t, list.Folders[2].Removed)
}

// Spec §6.3: the refusals' sentences, and the last folder.
func TestFolderRemoveRefusals(t *testing.T) {
	f := newFolderFixture(t)
	hub := f.add(t, repoDir(t, "hub"))
	for range 2 {
		_, err := f.database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id, workbench_folder_id)
			VALUES (?, 'claude', 'w', ?, 's', ?)`, f.pid, hub.Folder.Path, hub.Folder.ID)
		require.NoError(t, err)
	}
	out, _, err := runFolder(t, "remove", "--workbench", f.id(), "--folder", "hub", "--json")
	require.NoError(t, err)
	res := decodeFolderResult(t, out)
	assert.Equal(t, workbenchfolders.CodeSessionsRunning, res.ErrorCode)
	assert.Equal(t, "sessions_running: 2 sessions are running in hub. Finish them first.", res.Error)

	_, err = f.database.Exec(`DELETE FROM terminal_sessions`)
	require.NoError(t, err)
	out, _, err = runFolder(t, "remove", "--workbench", f.id(), "--folder", "hub", "--json")
	require.NoError(t, err)
	require.True(t, decodeFolderResult(t, out).OK, out)
	out, _, err = runFolder(t, "remove", "--workbench", f.id(), "--folder", "app", "--json")
	require.NoError(t, err)
	res = decodeFolderResult(t, out)
	assert.Equal(t, "last_folder: A workbench needs at least one folder.", res.Error)
}

// Spec §7 Writers: an agent never writes a bench's folders, even its own
// session's bench; listing stays open.
func TestFolderWritesRefuseAnAgentCaller(t *testing.T) {
	f := newFolderFixture(t)
	t.Setenv("WATCHTOWER_TERMINAL_SESSION_ID", "5")
	for _, args := range [][]string{
		{"add", "--workbench", f.id(), "--folder", repoDir(t, "hub")},
		{"remove", "--workbench", f.id(), "--folder", "app"},
		{"locate", "--workbench", f.id(), "--folder", "app", "--to", repoDir(t, "x")},
	} {
		_, _, err := runFolder(t, args...)
		assert.ErrorContains(t, err, "only the owner and the Desktop", args[0])
	}
	_, _, err := runFolder(t, "list", "--workbench", f.id())
	assert.NoError(t, err)
}

func TestFolderLocateReinstallsAtTheNewPath(t *testing.T) {
	f := newFolderFixture(t)
	hub := f.add(t, repoDir(t, "hub"))
	moved := repoDir(t, "hub-moved")
	require.NoError(t, os.RemoveAll(hub.Folder.Path))

	out, errOut, err := runFolder(t, "locate", "--workbench", f.id(), "--folder", hub.Folder.Path, "--to", moved, "--json")
	require.NoError(t, err, errOut)
	res := decodeFolderResult(t, out)
	require.True(t, res.OK, res.Error)
	assert.Equal(t, moved, res.Folder.Path)
	assert.Equal(t, "hub", res.Folder.Name)
	assert.True(t, res.Folder.Installed, "reinstalled at the new path")
}

// PROJ-02, every folder: delete leaves nothing of Watchtower in any of them.
func TestProj02_DeleteRemovesEveryFolderInstall(t *testing.T) {
	f := newFolderFixture(t)
	p, err := f.database.GetWorkbench(f.pid)
	require.NoError(t, err)
	require.NoError(t, folderInstall(context.Background(), p))
	hub := repoDir(t, "hub")
	require.True(t, f.add(t, hub).Install.OK)

	_, errOut, err := runWorkbench(t, "delete", f.id())
	require.NoError(t, err, errOut)
	for _, dir := range []string{f.app, hub} {
		for _, path := range []string{
			filepath.Join(dir, ".claude", "skills", devpack.WorkbenchSkillName),
			filepath.Join(dir, ".claude", "settings.local.json"),
			filepath.Join(dir, ".claude"),
		} {
			_, err := os.Stat(path)
			assert.True(t, os.IsNotExist(err), "PROJ-02: %s survived the delete", path)
		}
		assert.False(t, f.claude.registered[fakeRegistration(dir, devpack.WorkbenchMCPServerName)], "PROJ-02: %s's MCP registration survived", dir)
	}
}

// `workbench resync` sets up every live folder; the home folder's fields
// stay where they were, the others are listed in folders.
func TestResyncInstallsEveryFolder(t *testing.T) {
	f := newFolderFixture(t)
	prev := folderInstall
	folderInstall = func(context.Context, *db.Workbench) error { return nil } // add installs nothing
	hub := repoDir(t, "hub")
	res := f.add(t, hub)
	folderInstall = prev
	t.Cleanup(func() { folderInstall = prev })
	installed, _ := devpack.HasCoreStateHooks(hub, f.pid)
	require.False(t, installed)

	out, _, err := runWorkbench(t, "resync", f.id(), "--json")
	require.NoError(t, err)
	resynced := decodeResync(t, out)
	assert.True(t, resynced.IntegrationOK, resynced.IntegrationError)
	assert.Equal(t, []resyncFolderJSON{{ID: res.Folder.ID, Name: "hub", Path: hub, OK: true}}, resynced.Folders)
	for _, dir := range []string{f.app, hub} {
		installed, err := devpack.HasCoreStateHooks(dir, f.pid)
		require.NoError(t, err)
		assert.True(t, installed, dir)
	}

	// Another folder failing is told in its entry; integration_ok stays the
	// home folder's. Without --json the run fails.
	folderInstall = func(context.Context, *db.Workbench) error { return errors.New("read-only") }
	out, _, err = runWorkbench(t, "resync", f.id(), "--json")
	require.NoError(t, err)
	resynced = decodeResync(t, out)
	assert.True(t, resynced.IntegrationOK, resynced.IntegrationError)
	assert.Empty(t, resynced.IntegrationError)
	require.Len(t, resynced.Folders, 1)
	assert.False(t, resynced.Folders[0].OK)
	assert.Equal(t, "read-only", resynced.Folders[0].Error)
	out, _, err = runWorkbench(t, "resync", f.id())
	assert.ErrorContains(t, err, "installing in hub: read-only")
	assert.Contains(t, out, "hub ("+hub+"): FAILED — read-only")
}

// A one-folder bench resyncs with an empty folders list, never null.
func TestResyncFoldersIsAnEmptyArray(t *testing.T) {
	f := newFolderFixture(t)
	out, _, err := runWorkbench(t, "resync", f.id(), "--json")
	require.NoError(t, err)
	var raw map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &raw))
	assert.Equal(t, []any{}, raw["folders"])
}

// D25: create on a folder that is on a bench, home or not, names that
// bench in the refusal the Desktop already matches.
func TestCreateOnABenchFolderNamesItsBench(t *testing.T) {
	f := newFolderFixture(t)
	hub := repoDir(t, "hub")
	require.True(t, f.add(t, hub).OK)
	for _, dir := range []string{hub, f.app} {
		_, _, err := runWorkbench(t, "create", "--folder", dir)
		require.ErrorIs(t, err, db.ErrWorkbenchFolderTaken, dir)
		assert.Contains(t, err.Error(), "folder is already bound to a workbench")
		assert.Contains(t, err.Error(), `(workbench `+f.id()+` "acme")`, dir)
	}
}

// PROJ-24: taking a folder off the bench touches nothing but Watchtower's
// install — the owner's files byte-identical, git status, stash and
// exclude file as they were (PROJ-02's removal assertions for that folder).
func TestProj24_RemoveTouchesNothingButTheInstall(t *testing.T) {
	gitBin, ok := gitbin.Locate()
	if !ok {
		t.Skip("git not installed")
	}
	f := newFolderFixture(t)
	root, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	hub := filepath.Join(root, "hub")
	require.NoError(t, os.MkdirAll(hub, 0o755))
	git := func(args ...string) string {
		t.Helper()
		c := exec.Command(gitBin, args...)
		c.Dir = hub
		c.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1",
			"GIT_AUTHOR_NAME=a", "GIT_AUTHOR_EMAIL=a@example.com", "GIT_COMMITTER_NAME=a", "GIT_COMMITTER_EMAIL=a@example.com")
		out, err := c.CombinedOutput()
		require.NoError(t, err, "git %v: %s", args, out)
		return string(out)
	}
	git("init", "-q")
	require.NoError(t, os.WriteFile(filepath.Join(hub, "main.go"), []byte("package main\n"), 0o644))
	git("add", "main.go")
	git("commit", "-qm", "init")
	require.NoError(t, os.WriteFile(filepath.Join(hub, "main.go"), []byte("package main // stashed\n"), 0o644))
	git("stash", "-q")
	require.NoError(t, os.WriteFile(filepath.Join(hub, "main.go"), []byte("package main // uncommitted\n"), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(hub, "notes.md"), []byte("# owner notes\n"), 0o644))
	exclude := filepath.Join(hub, ".git", "info", "exclude")
	require.NoError(t, os.WriteFile(exclude, []byte("*.swp\n"), 0o644))
	ownerFiles := map[string][]byte{}
	for _, name := range []string{"main.go", "notes.md"} {
		b, err := os.ReadFile(filepath.Join(hub, name))
		require.NoError(t, err)
		ownerFiles[name] = b
	}
	status := func() string { return git("status", "--porcelain", "--untracked-files=all") }
	before, stashes := status(), git("stash", "list")

	res := f.add(t, hub)
	require.True(t, res.OK && res.Install.OK, "%+v", res)
	require.True(t, res.Folder.Installed)

	out, errOut, err := runFolder(t, "remove", "--workbench", f.id(), "--folder", "hub", "--json")
	require.NoError(t, err, errOut)
	removed := decodeFolderResult(t, out)
	require.True(t, removed.OK, removed.Error)
	assert.True(t, removed.Install.OK, removed.Install.Error)
	assert.True(t, removed.Folder.Removed)

	assert.Equal(t, before, status(), "git status is as it was")
	assert.Equal(t, stashes, git("stash", "list"), "the stash is as it was")
	for name, want := range ownerFiles {
		got, err := os.ReadFile(filepath.Join(hub, name))
		require.NoError(t, err)
		assert.Equal(t, want, got, "the owner's %s is byte-identical", name)
	}
	got, err := os.ReadFile(exclude)
	require.NoError(t, err)
	assert.Equal(t, "*.swp\n", string(got), "PROJ-02: the exclude file is exactly the owner's again")
	for _, path := range []string{filepath.Join(hub, ".claude", "skills", devpack.WorkbenchSkillName), filepath.Join(hub, ".claude")} {
		_, err := os.Stat(path)
		assert.True(t, os.IsNotExist(err), "PROJ-02: %s survived the removal", path)
	}
	assert.False(t, f.claude.registered[fakeRegistration(hub, devpack.WorkbenchMCPServerName)], "PROJ-02: the MCP registration survived")
	installed, err := devpack.HasCoreStateHooks(f.app, f.pid)
	require.NoError(t, err)
	assert.False(t, installed, "the home folder was never installed here, and is untouched")
}

// Spec §6.3: Locate… is for a missing folder; one still at its path is
// refused (its install is there; Remove takes it out).
func TestFolderLocateRefusesAFolderStillThere(t *testing.T) {
	f := newFolderFixture(t)
	hub := f.add(t, repoDir(t, "hub"))
	out, _, err := runFolder(t, "locate", "--workbench", f.id(), "--folder", "hub", "--to", repoDir(t, "elsewhere"), "--json")
	require.NoError(t, err)
	res := decodeFolderResult(t, out)
	assert.False(t, res.OK)
	assert.Equal(t, workbenchfolders.CodeFolderPresent, res.ErrorCode)
	assert.Equal(t, "folder_present: hub is still at "+hub.Folder.Path+". Remove it from the bench instead.", res.Error)
	installed, err := devpack.HasCoreStateHooks(hub.Folder.Path, f.pid)
	require.NoError(t, err)
	assert.True(t, installed, "the folder and its install stay as they were")
}

// A literal `~` path (as the Desktop or a quoted shell argument passes it)
// gets the protected-dir check on its expanded, stored form; under --json
// that refusal and a bad --added-by are ok:false results.
func TestFolderAddJSONRefusesProtectedAndBadArgs(t *testing.T) {
	f := newFolderFixture(t)
	home := os.Getenv("HOME") // writeActionsConfig's temp HOME
	require.NoError(t, os.MkdirAll(filepath.Join(home, "Library", "Application Support", "Watchtower", "recordings"), 0o755))
	before := 0
	require.NoError(t, f.database.QueryRow(`SELECT COUNT(*) FROM workbench_folders`).Scan(&before))

	res := f.add(t, "~/Library/Application Support/Watchtower/recordings")
	assert.False(t, res.OK)
	assert.Equal(t, "not_allowed", res.ErrorCode)
	assert.Regexp(t, `^not_allowed: `, res.Error)
	after := 0
	require.NoError(t, f.database.QueryRow(`SELECT COUNT(*) FROM workbench_folders`).Scan(&after))
	assert.Equal(t, before, after, "nothing written")

	out, _, err := runFolder(t, "add", "--workbench", f.id(), "--folder", repoDir(t, "hub"), "--added-by", "someone", "--json")
	require.NoError(t, err)
	res = decodeFolderResult(t, out)
	assert.False(t, res.OK)
	assert.Equal(t, "bad_args", res.ErrorCode)
	_, _, err = runFolder(t, "add", "--workbench", f.id(), "--folder", repoDir(t, "hub"), "--added-by", "someone")
	assert.ErrorContains(t, err, "bad_args: ")
}

// Membership changes hold the workspace's folder lock from before their
// transaction through the install or uninstall after it, so a remove's
// uninstall can never strip a re-add's fresh install (another process
// waits on the lock); remove then re-add ends installed.
func TestFolderChangesHoldTheLockThroughTheirFilesystemWork(t *testing.T) {
	f := newFolderFixture(t)
	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	lock := workbenchfolders.LockPath(cfg.WorkspaceDir())
	held := func(step string) {
		t.Helper()
		unlock, free, err := fsutil.TryLockFile(lock)
		require.NoError(t, err)
		if free {
			unlock()
		}
		assert.False(t, free, "%s runs under the folder lock", step)
	}
	prevInstall, prevRemove := folderInstall, workbenchRemoveInstall
	t.Cleanup(func() { folderInstall, workbenchRemoveInstall = prevInstall, prevRemove })
	var steps []string
	folderInstall = func(ctx context.Context, p *db.Workbench) error {
		held("the install")
		steps = append(steps, "install")
		return prevInstall(ctx, p)
	}
	workbenchRemoveInstall = func(ctx context.Context, cfg *config.Config, p *db.Workbench) error {
		held("the uninstall")
		steps = append(steps, "uninstall")
		return prevRemove(ctx, cfg, p)
	}

	hub := repoDir(t, "hub")
	require.True(t, f.add(t, hub).Install.OK)
	out, _, err := runFolder(t, "remove", "--workbench", f.id(), "--folder", "hub", "--json")
	require.NoError(t, err)
	require.True(t, decodeFolderResult(t, out).OK, out)
	res := f.add(t, hub)
	require.True(t, res.OK && res.Install.OK, "%+v", res)

	assert.Equal(t, []string{"install", "uninstall", "install"}, steps)
	assert.True(t, res.Folder.Installed, "remove then re-add ends installed")
	installed, err := devpack.HasCoreStateHooks(hub, f.pid)
	require.NoError(t, err)
	assert.True(t, installed)
	unlock, free, err := fsutil.TryLockFile(lock)
	require.NoError(t, err)
	require.True(t, free, "the lock is released when the command ends")
	unlock()
}

// queueBehindLock runs the workbench command args while the test holds the
// folder lock: once the command is about to wait for it, whileHeld runs
// (another process's change), then the lock is released and the command's
// outcome returned. A command that read the bench before the lock acts on
// what whileHeld changed.
func queueBehindLock(t *testing.T, whileHeld func(), args ...string) (string, error) {
	t.Helper()
	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	unlock, err := fsutil.LockFile(context.Background(), workbenchfolders.LockPath(cfg.WorkspaceDir()))
	require.NoError(t, err)
	release := sync.OnceFunc(unlock)
	waiting := make(chan struct{})
	var once sync.Once
	prev := folderLockWait
	folderLockWait = func() { once.Do(func() { close(waiting) }) }
	type result struct {
		out string
		err error
	}
	done := make(chan result, 1)
	joined := make(chan struct{})
	reset := func() {
		rootCmd.SetArgs(nil)
		resetSetFlags(append(append(workbenchCmd.Commands(), workbenchFolderCmd.Commands()...), workbenchCmd, rootCmd)...)
		workbenchFlagJSON = false
	}
	// Whatever happens below — a failed require in whileHeld included —
	// the lock is released and the command joined before the test ends.
	t.Cleanup(func() {
		release()
		<-joined
		folderLockWait = prev
		reset()
	})
	go func() {
		defer close(joined)
		var out, errOut bytes.Buffer
		rootCmd.SetOut(&out)
		rootCmd.SetErr(&errOut)
		rootCmd.SetArgs(append([]string{"workbench"}, args...))
		err := rootCmd.Execute()
		done <- result{out.String(), err}
	}()
	select {
	case <-waiting:
	case r := <-done:
		require.FailNowf(t, "the command ended before it waited for the folder lock", "err=%v out=%s", r.err, r.out)
	}
	whileHeld()
	release()
	r := <-done
	reset()
	return r.out, r.err
}

// A resync queued behind a delete reads the bench under the lock: the bench
// is gone, so it installs nothing anywhere.
func TestResyncQueuedBehindADeleteDoesNothing(t *testing.T) {
	f := newFolderFixture(t)
	hub := repoDir(t, "hub")
	require.True(t, f.add(t, hub).Install.OK)

	_, err := queueBehindLock(t, func() {
		for _, dir := range []string{f.app, hub} {
			require.NoError(t, workbenchRemoveInstall(context.Background(), nil, &db.Workbench{ID: f.pid, FolderPath: dir}))
		}
		require.NoError(t, f.database.DeleteWorkbench(f.pid))
	}, "resync", f.id(), "--json")
	require.ErrorIs(t, err, db.ErrWorkbenchNotFound)
	for _, dir := range []string{f.app, hub} {
		_, statErr := os.Stat(filepath.Join(dir, ".claude"))
		assert.True(t, os.IsNotExist(statErr), "nothing installed in %s for the deleted bench", dir)
	}
}

// A remove queued behind the home folder's removal reads the bench under
// the lock: it sees the promoted home, so removing that folder re-points
// the index at the next one (the documents only it listed leave search).
func TestFolderRemoveQueuedBehindAHomeRemovalSeesTheNewHome(t *testing.T) {
	f := newFolderFixture(t)
	hub := plainDir(t, "hub")
	require.NoError(t, os.WriteFile(filepath.Join(hub, "README.md"), []byte("# hub\nzebrafinch\n"), 0o644))
	require.True(t, f.add(t, hub).OK)
	site := plainDir(t, "site")
	require.True(t, f.add(t, site).OK)
	ctx := context.Background()
	search := func() int {
		t.Helper()
		res, err := kb.Search(ctx, f.database, kb.Request{Queries: []string{"zebrafinch"}, WorkbenchID: f.pid})
		require.NoError(t, err)
		return len(res.Hits)
	}

	out, err := queueBehindLock(t, func() {
		home, err := f.database.HomeFolder(ctx, f.pid)
		require.NoError(t, err)
		_, err = workbenchfolders.Remove(ctx, f.database, home.ID, nil)
		require.NoError(t, err)
		_, _, err = kb.IndexWorkbenchDocs(ctx, f.database, f.pid) // hub is home now: its README is indexed
		require.NoError(t, err)
		require.Equal(t, 1, search())
	}, "folder", "remove", "--workbench", f.id(), "--folder", "hub", "--json")
	require.NoError(t, err)
	require.True(t, decodeFolderResult(t, out).OK, out)

	wb, err := f.database.GetWorkbench(f.pid)
	require.NoError(t, err)
	assert.Equal(t, site, wb.FolderPath, "site is home now")
	assert.Zero(t, search(), "the removed home's documents left the index")
}

// plainDir is a resolved folder named name outside git (the docs listing
// walks it).
func plainDir(t *testing.T, name string) string {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	dir := filepath.Join(root, name)
	require.NoError(t, os.MkdirAll(dir, 0o755))
	return dir
}
