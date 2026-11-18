package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// outsideFixture is bench "acme" on the repository app with a Desktop
// terminal row the hook runs in (WATCHTOWER_TERMINAL_SESSION_ID), every
// mount local and no skip dir — the fixtures live under the temp dir.
type outsideFixture struct {
	database *db.DB
	wb, row  int64
	app      string
}

func newOutsideFixture(t *testing.T) outsideFixture {
	t.Helper()
	database := writeActionsConfig(t)
	app := repoDir(t, "app")
	wb, err := database.CreateWorkbench("acme", app)
	require.NoError(t, err)
	res, err := database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
		VALUES (?, 'claude', 's', ?, ?)`, wb, app, briefLaunchID)
	require.NoError(t, err)
	row, err := res.LastInsertId()
	require.NoError(t, err)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	stubOutsideEnv(t, nil, func(string) bool { return true })
	return outsideFixture{database: database, wb: wb, row: row, app: app}
}

// stubOutsideEnv pins the hook's skip dirs and mount answer.
func stubOutsideEnv(t *testing.T, skip []string, local func(string) bool) {
	t.Helper()
	prevSkip, prevLocal := outsideSkipDirs, outsideLocalMount
	outsideSkipDirs = func() []string { return skip }
	outsideLocalMount = func() func(string) bool { return local }
	t.Cleanup(func() { outsideSkipDirs, outsideLocalMount = prevSkip, prevLocal })
}

// toolPayload is a PostToolUse input of tool with one path argument.
func toolPayload(tool, key, path string) string {
	in, _ := json.Marshal(map[string]any{
		"session_id": "c0ffee00-0000-4000-8000-000000000001", "hook_event_name": "PostToolUse", "cwd": "/",
		"tool_name": tool, "tool_input": map[string]any{key: path}, "tool_response": map[string]any{"ok": true},
	})
	return string(in)
}

// runOutsideHook runs `workbench outside-touch --workbench N` as the hook
// does; it must always exit 0.
func runOutsideHook(t *testing.T, wb int64, stdin string, extra ...string) (stdout, stderr string) {
	t.Helper()
	rootCmd.SetIn(strings.NewReader(stdin))
	t.Cleanup(func() { rootCmd.SetIn(nil) })
	out, errOut, err := runWorkbench(t, append([]string{"outside-touch", "--workbench", strconv.FormatInt(wb, 10)}, extra...)...)
	require.NoError(t, err, "the hook always exits 0")
	return out, errOut
}

// outsideCount is the stored count of the row's touches of root.
func outsideCount(t *testing.T, d *db.DB, row int64, root string) int {
	t.Helper()
	n, err := d.OutsideTouches(context.Background(), row, root)
	require.NoError(t, err)
	return n
}

func TestOutsideTouchNudgesOnTheThird(t *testing.T) {
	fx := newOutsideFixture(t)
	lib := repoDir(t, "lib")
	file := filepath.Join(lib, "src", "a.go")

	want := fmt.Sprintf(`{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":`+
		`"You keep working in %s, which is not on this workbench. If the task needs it, call suggest_workbench_folder(%s, why)."}}`+"\n",
		lib, lib)
	for i, tool := range []string{"Read", "Grep", "Edit", "Write"} {
		key := "file_path"
		path := file
		if tool == "Grep" {
			key, path = "path", filepath.Join(lib, "src")
		}
		out, errOut := runOutsideHook(t, fx.wb, toolPayload(tool, key, path))
		assert.Empty(t, errOut, tool)
		if i == 2 {
			assert.Equal(t, want, out, "the third touch nudges")
		} else {
			assert.Empty(t, out, "touch %d prints nothing", i+1)
		}
	}
	assert.Equal(t, 4, outsideCount(t, fx.database, fx.row, lib))
	var nudged bool
	require.NoError(t, fx.database.QueryRow(`SELECT nudged_at IS NOT NULL FROM session_outside_touches WHERE session_id = ?`, fx.row).Scan(&nudged))
	assert.True(t, nudged)

	// NotebookEdit's notebook_path and MultiEdit's file_path count too, for
	// another repository, apart.
	site := repoDir(t, "site")
	runOutsideHook(t, fx.wb, toolPayload("NotebookEdit", "notebook_path", filepath.Join(site, "n.ipynb")))
	runOutsideHook(t, fx.wb, toolPayload("MultiEdit", "file_path", filepath.Join(site, "m.go")))
	assert.Equal(t, 2, outsideCount(t, fx.database, fx.row, site))
}

// A touch in the repository the session runs in (the input's cwd: the
// bench's own) is answered without opening the database; a touch elsewhere
// still opens it.
func TestOutsideTouchInTheSessionRepoOpensNoDatabase(t *testing.T) {
	fx := newOutsideFixture(t)
	opened := 0
	prev := outsideTouchOpenDB
	outsideTouchOpenDB = func() (*db.DB, error) {
		opened++
		return prev()
	}
	t.Cleanup(func() { outsideTouchOpenDB = prev })
	payload := func(path string) string {
		in, _ := json.Marshal(map[string]any{
			"hook_event_name": "PostToolUse", "cwd": fx.app,
			"tool_name": "Read", "tool_input": map[string]any{"file_path": path},
		})
		return string(in)
	}

	out, errOut := runOutsideHook(t, fx.wb, payload(filepath.Join(fx.app, "main.go")))
	assert.Empty(t, out)
	assert.Empty(t, errOut)
	assert.Zero(t, opened, "the session's own repository never opens the database")

	lib := repoDir(t, "lib")
	runOutsideHook(t, fx.wb, payload(filepath.Join(lib, "a.go")))
	assert.Equal(t, 1, opened)
	assert.Equal(t, 1, outsideCount(t, fx.database, fx.row, lib))
}

func TestOutsideTouchSkips(t *testing.T) {
	for _, tc := range []struct {
		name string
		// setup returns the touched path and the root that must stay uncounted.
		setup func(t *testing.T, fx outsideFixture) (path, root string)
		tool  string
		key   string
		quiet bool // counted, never nudged
	}{
		{name: "Bash", tool: "Bash", key: "command", setup: func(t *testing.T, _ outsideFixture) (string, string) {
			lib := repoDir(t, "lib")
			return "cat " + filepath.Join(lib, "a.go"), lib
		}},
		{name: "bench folder", setup: func(_ *testing.T, fx outsideFixture) (string, string) {
			return filepath.Join(fx.app, "main.go"), fx.app
		}},
		{name: "second bench folder", setup: func(t *testing.T, fx outsideFixture) (string, string) {
			hub := repoDir(t, "hub")
			_, err := fx.database.Exec(`INSERT INTO workbench_folders (workbench_id, folder_path, position, added_by, name)
				VALUES (?, ?, 1, 'owner', 'hub')`, fx.wb, hub)
			require.NoError(t, err)
			return filepath.Join(hub, "x.go"), hub
		}},
		{name: "worktree of a bench folder", setup: func(t *testing.T, fx outsideFixture) (string, string) {
			wt := filepath.Join(plainDir(t, "wt"), "feature")
			require.NoError(t, os.MkdirAll(wt, 0o755))
			require.NoError(t, os.WriteFile(filepath.Join(wt, ".git"),
				[]byte("gitdir: "+filepath.Join(fx.app, ".git", "worktrees", "feature")+"\n"), 0o600))
			return filepath.Join(wt, "x.go"), wt
		}},
		{name: "claude home", setup: func(t *testing.T, _ outsideFixture) (string, string) {
			home := repoDir(t, ".claude")
			stubOutsideEnv(t, []string{home}, func(string) bool { return true })
			return filepath.Join(home, "plans", "p.md"), home
		}},
		{name: "temp dir", setup: func(t *testing.T, _ outsideFixture) (string, string) {
			lib := repoDir(t, "lib")
			stubOutsideEnv(t, []string{filepath.Dir(filepath.Dir(lib))}, func(string) bool { return true })
			return filepath.Join(lib, "a.go"), lib
		}},
		{name: "non-local mount", setup: func(t *testing.T, _ outsideFixture) (string, string) {
			lib := repoDir(t, "lib")
			stubOutsideEnv(t, nil, func(string) bool { return false })
			return filepath.Join(lib, "a.go"), lib
		}},
		{name: "no repository", setup: func(t *testing.T, _ outsideFixture) (string, string) {
			dir := plainDir(t, "loose")
			return filepath.Join(dir, "a.txt"), dir
		}},
		{name: "declined", setup: func(t *testing.T, fx outsideFixture) (string, string) {
			lib := repoDir(t, "lib")
			require.NoError(t, fx.database.DeclineFolder(context.Background(), fx.wb, lib))
			return filepath.Join(lib, "a.go"), lib
		}},
		{name: "other bench", setup: func(t *testing.T, fx outsideFixture) (string, string) {
			lib := repoDir(t, "lib")
			_, err := fx.database.CreateWorkbench("beta", lib)
			require.NoError(t, err)
			return filepath.Join(lib, "a.go"), lib
		}},
		{name: "quiet", quiet: true, setup: func(t *testing.T, fx outsideFixture) (string, string) {
			lib := repoDir(t, "lib")
			require.NoError(t, fx.database.QuietOutsideRoot(context.Background(), fx.row, lib))
			return filepath.Join(lib, "a.go"), lib
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			fx := newOutsideFixture(t)
			path, root := tc.setup(t, fx)
			tool, key := tc.tool, tc.key
			if tool == "" {
				tool, key = "Read", "file_path"
			}
			for range 4 {
				out, errOut := runOutsideHook(t, fx.wb, toolPayload(tool, key, path))
				assert.Empty(t, out)
				assert.Empty(t, errOut)
			}
			if tc.quiet {
				assert.Equal(t, 4, outsideCount(t, fx.database, fx.row, root), "a quiet root still counts")
				return
			}
			var n int
			require.NoError(t, fx.database.QueryRow(`SELECT COUNT(*) FROM session_outside_touches`).Scan(&n))
			assert.Zero(t, n, "nothing counted")
		})
	}
}

// The default skip dirs hold ~/.claude and the temp roots.
func TestOutsideSkipDirsHoldClaudeHomeAndTemp(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	dirs := outsideSkipDirs()
	assert.Contains(t, dirs, filepath.Join(home, ".claude"))
	assert.Contains(t, dirs, filepath.Clean(os.TempDir()))
	assert.Contains(t, dirs, "/tmp")
}

// Spec §7 "hook" row: the walk up for .git stops after 64 levels, and a
// path on a non-local mount is never walked.
func TestOutsideTouchWalkIsCapped(t *testing.T) {
	repo := repoDir(t, "deep")
	local := func(string) bool { return true }
	below := func(levels int) string {
		return filepath.Join(append([]string{repo}, strings.Split(strings.Repeat("d/", levels), "/")...)...)
	}
	_, root, ok := outsideRoot(below(63), nil, local)
	assert.True(t, ok, "63 levels below the root: found")
	assert.Equal(t, repo, root)
	_, _, ok = outsideRoot(below(64), nil, local)
	assert.False(t, ok, "64 levels below: past the cap")

	// A spelled path on a non-local mount: refused at its first component on
	// that mount, before anything there is probed.
	share := filepath.Dir(repo)
	var asked []string
	onShare := func(p string) bool { asked = append(asked, p); return p != share && !pathWithin(p, share) }
	_, _, ok = outsideRoot(filepath.Join(repo, "a.go"), nil, onShare)
	assert.False(t, ok, "a non-local mount is never walked")
	assert.Equal(t, share, asked[len(asked)-1], "the walk stops at the share's mount point")

	_, _, ok = outsideRoot("relative/a.go", nil, local)
	assert.False(t, ok)
}

// A local-looking symlink onto a non-local mount is refused at the link: its
// target's mount is checked before anything behind the link is probed. A
// link onto a local repository resolves to it.
func TestOutsideTouchSymlinkOntoANetworkMountIsNeverWalked(t *testing.T) {
	repo := repoDir(t, "remote")
	links := plainDir(t, "links")
	link := filepath.Join(links, "work")
	require.NoError(t, os.Symlink(repo, link))
	share := repo
	var asked []string
	shareIsRemote := func(p string) bool {
		asked = append(asked, p)
		return p != share && !pathWithin(p, share)
	}
	_, _, ok := outsideRoot(filepath.Join(link, "src", "a.go"), nil, shareIsRemote)
	assert.False(t, ok, "the link's target is on the share")
	assert.Equal(t, repo, asked[len(asked)-1], "refused at the link's target, before any probe behind it")
	for _, p := range asked {
		assert.False(t, pathWithin(p, share), "nothing inside the share was asked about: %s", p)
	}

	resolved, root, ok := outsideRoot(filepath.Join(link, "src", "a.go"), nil, func(string) bool { return true })
	assert.True(t, ok)
	assert.Equal(t, repo, root)
	assert.Equal(t, filepath.Join(repo, "src", "a.go"), resolved)

	// A link loop ends at the hop limit.
	loop := filepath.Join(links, "loop")
	require.NoError(t, os.Symlink(loop, loop))
	_, _, ok = outsideRoot(filepath.Join(loop, "a.go"), nil, func(string) bool { return true })
	assert.False(t, ok)

	mounts := []mountEntry{{"/", true}, {"/Volumes/share", false}}
	assert.False(t, mountIsLocal(mounts, "/Volumes/share/x"))
	assert.False(t, mountIsLocal(mounts, "/Volumes/share"))
	assert.True(t, mountIsLocal(mounts, "/Volumes/sharex/y"))
	assert.True(t, mountIsLocal(mounts, "/Users/acme"))
	assert.False(t, mountIsLocal(nil, "/Users/acme"), "no table: not walked")
}

func TestOutsideTouchExitsZeroOnEveryError(t *testing.T) {
	orig := sessionStateInputWait
	sessionStateInputWait = 50 * time.Millisecond
	t.Cleanup(func() { sessionStateInputWait = orig })
	fx := newOutsideFixture(t)
	lib := repoDir(t, "lib")
	touch := toolPayload("Read", "file_path", filepath.Join(lib, "a.go"))

	out, errOut := runOutsideHook(t, fx.wb, `{"tool_name":`)
	assert.Empty(t, out)
	assert.Contains(t, errOut, "outside touch not counted: reading the hook input")

	out, errOut = runOutsideHook(t, fx.wb, `{"tool_name":"Read","tool_input":{"file_path":7}}`)
	assert.Empty(t, out)
	assert.Contains(t, errOut, "reading the hook input")

	out, errOut = runOutsideHook(t, 0, touch)
	assert.Empty(t, out)
	assert.Contains(t, errOut, "invalid --workbench")

	out, errOut = runOutsideHook(t, fx.wb, touch, "--future-flag")
	assert.Empty(t, out)
	assert.Empty(t, errOut, "an unknown flag is ignored")

	// The database locked by another writer: the count gives up, no stdout.
	prevLock := outsideTouchLockWait
	outsideTouchLockWait = hookLockWait{wait: time.Millisecond}
	t.Cleanup(func() { outsideTouchLockWait = prevLock })
	tx, err := fx.database.Begin() // BEGIN IMMEDIATE: holds the write lock
	require.NoError(t, err)
	out, errOut = runOutsideHook(t, fx.wb, touch)
	require.NoError(t, tx.Rollback())
	assert.Empty(t, out)
	assert.Contains(t, errOut, "outside touch not counted")

	// A row of another workbench is never counted.
	t.Setenv(terminalSessionEnv, "999999")
	out, errOut = runOutsideHook(t, fx.wb, touch)
	assert.Empty(t, out)
	assert.Empty(t, errOut)
	// No row in the environment: stdin unread, nothing printed.
	t.Setenv(terminalSessionEnv, "row-1")
	out, errOut = runOutsideHook(t, fx.wb, touch)
	assert.Empty(t, out)
	assert.Contains(t, errOut, "invalid "+terminalSessionEnv)
}

// The hook's writes share one budget from its start (the state hooks'
// helper): a write past it is not tried, nothing is printed.
func TestOutsideTouchStaysInTheHookBudget(t *testing.T) {
	fx := newOutsideFixture(t)
	lib := repoDir(t, "lib")
	base := time.Now()
	reads := 0
	lockClock(t, func() time.Time {
		reads++
		if reads == 1 {
			return base // the budget starts here
		}
		return base.Add(outsideTouchBudget) // spent by the time of the write
	})
	out, errOut := runOutsideHook(t, fx.wb, toolPayload("Read", "file_path", filepath.Join(lib, "a.go")))
	assert.Empty(t, out)
	assert.Contains(t, errOut, errHookOutOfTime.Error())
	assert.Zero(t, outsideCount(t, fx.database, fx.row, lib), "no write past the budget")
}
