package tools

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/devpack"
	"watchtower/internal/workbenchfiles"
)

// startWorld is the session host and the CLI as start_session sees them:
// runs are the sessions in the host; every start is recorded and answered
// with answer (default: a started row 99 in folder "hub").
type startWorld struct {
	runs   map[int64]bool
	args   [][]string
	briefs []string
	answer func() ([]byte, error)
}

func newStartWorld() *startWorld { return &startWorld{runs: map[int64]bool{}} }

func (w *startWorld) deps() SessionDeps {
	return SessionDeps{
		Runs: func(context.Context) (map[int64]bool, error) { return w.runs, nil },
		StartSession: func(_ context.Context, args []string, brief string) ([]byte, error) {
			w.args = append(w.args, args)
			w.briefs = append(w.briefs, brief)
			if w.answer != nil {
				return w.answer()
			}
			return []byte(`{"ok":true,"session_id":99,"state":"starting","folder_path":"/x","worktree_branch":"",` +
				`"folder_id":7,"folder":"hub","place":"auto","worktree":""}`), nil
		},
	}
}

func startRegistry(t *testing.T, d *db.DB, caller int64, deps SessionDeps) *Registry {
	t.Helper()
	reg := New(d)
	env := func() string { return strconv.FormatInt(caller, 10) }
	for _, tool := range workbenchTools(workbenchfiles.New(t.TempDir()), env, nil, deps) {
		require.NoError(t, reg.Register(tool))
	}
	return reg
}

// flag is the value after name in args, "" when absent.
func flag(args []string, name string) string {
	for i := 0; i+1 < len(args); i++ {
		if args[i] == name {
			return args[i+1]
		}
	}
	return ""
}

// childOf seeds a session of workbench wb under parent (0 = a root).
func childOf(t *testing.T, d *db.DB, wb, parent int64) int64 {
	t.Helper()
	id := seedTerminalSession(t, d, wb)
	if parent != 0 {
		_, err := d.Exec(`UPDATE terminal_sessions SET parent_session_id = ? WHERE id = ?`, parent, id)
		require.NoError(t, err)
	}
	// A session that reported once is past its start: live only in the host.
	_, err := d.Exec(`UPDATE terminal_sessions SET agent_state = 'working' WHERE id = ?`, id)
	require.NoError(t, err)
	return id
}

func TestStartSessionRunsInTheNamedFolder(t *testing.T) {
	fx := newWorkbenchFixture(t)
	hub := addBenchFolder(t, fx.d, fx.a, "hub")
	caller := childOf(t, fx.d, fx.a, 0)
	w := newStartWorld()
	reg := startRegistry(t, fx.d, caller, w.deps())

	out := mustApply(t, reg, fx.a, "start_session", `{"folder":"HUB","brief":"Write the tests.","reason":"parallel work"}`)
	assert.Equal(t, map[string]any{"session_id": float64(99), "folder": "hub", "place": "auto", "worktree": ""}, out)
	require.Len(t, w.args, 1)
	args := w.args[0]
	assert.Equal(t, strconv.FormatInt(hub.ID, 10), flag(args, "--folder"), "the folder goes by its id: %v", args)
	assert.Equal(t, strconv.FormatInt(caller, 10), flag(args, "--parent"))
	assert.Equal(t, strconv.FormatInt(fx.a, 10), flag(args, "--workbench"))
	assert.Contains(t, args, "--brief-stdin")
	assert.Contains(t, args, "--json")
	assert.Empty(t, flag(args, "--target"))

	// By path, with a title and a target of the board.
	mustApply(t, reg, fx.a, "start_session", fmt.Sprintf(`{"folder":%q,"brief":"b","title":"API tests","target_id":%d,"reason":"r"}`,
		hub.FolderPath, fx.aTarget))
	args = w.args[1]
	assert.Equal(t, strconv.FormatInt(hub.ID, 10), flag(args, "--folder"))
	assert.Equal(t, "API tests", flag(args, "--title"))
	assert.Equal(t, strconv.FormatInt(fx.aTarget, 10), flag(args, "--target"))

	// Refusals before any start: an unknown or removed folder, another
	// board's target, no calling session.
	_, err := fx.d.Exec(`UPDATE workbench_folders SET removed_at = '2026-11-18T00:00:00Z' WHERE id = ?`, hub.ID)
	require.NoError(t, err)
	for _, c := range []struct{ args, want string }{
		{`{"folder":"site","brief":"b","reason":"r"}`, "not_found: site is not a folder of workbench"},
		{fmt.Sprintf(`{"folder":%q,"brief":"b","reason":"r"}`, hub.FolderPath), "folder_removed: hub was removed from the bench."},
		{fmt.Sprintf(`{"folder":"%d","brief":"b","target_id":%d,"reason":"r"}`, hub.ID, fx.bTarget), "folder_removed: "},
		{`{"folder":"hub","brief":"  ","reason":"r"}`, "brief is required"},
		{`{"folder":"hub","brief":"b","agent":"gpt","reason":"r"}`, `invalid agent "gpt"`},
	} {
		_, err := proposeIn(t, reg, fx.a, "start_session", c.args)
		require.Error(t, err, c.args)
		assert.Contains(t, refusal(t, err), c.want, c.args)
	}
	home, err := fx.d.HomeFolder(context.Background(), fx.a)
	require.NoError(t, err)
	_, err = proposeIn(t, reg, fx.a, "start_session", fmt.Sprintf(`{"folder":%q,"brief":"b","target_id":%d,"reason":"r"}`,
		home.Name, fx.bTarget))
	assert.Contains(t, refusal(t, err), "is not in this workbench")
	outside := startRegistry(t, fx.d, 0, w.deps())
	_, err = proposeIn(t, outside, fx.a, "start_session", fmt.Sprintf(`{"folder":%q,"brief":"b","reason":"r"}`, home.Name))
	assert.Equal(t, "start_session needs a Watchtower terminal session", refusal(t, err))
	assert.Len(t, w.args, 2, "a refused call starts nothing")
}

func TestStartSessionBriefStartsWithTheHeader(t *testing.T) {
	fx := newWorkbenchFixture(t)
	addBenchFolder(t, fx.d, fx.a, "hub")
	caller := childOf(t, fx.d, fx.a, 0)
	_, err := fx.d.Exec(`UPDATE terminal_sessions SET title = 'API' WHERE id = ?`, caller)
	require.NoError(t, err)
	home, err := fx.d.HomeFolder(context.Background(), fx.a)
	require.NoError(t, err)
	w := newStartWorld()
	reg := startRegistry(t, fx.d, caller, w.deps())

	mustApply(t, reg, fx.a, "start_session", `{"folder":"hub","brief":"  Write the tests.\n","reason":"r"}`)
	require.Len(t, w.briefs, 1)
	id := strconv.FormatInt(caller, 10)
	assert.Equal(t, "You are a sub-session of #"+id+" “API” (folder "+home.Name+"). Message it with send_to_session("+id+
		", …). When done, call finish_session — your summary is sent to #"+id+".\n\nWrite the tests.", w.briefs[0])
}

func TestStartSessionDefaultsToTheCallersAgent(t *testing.T) {
	fx := newWorkbenchFixture(t)
	addBenchFolder(t, fx.d, fx.a, "hub")
	caller := childOf(t, fx.d, fx.a, 0)
	_, err := fx.d.Exec(`UPDATE terminal_sessions SET kind = 'codex' WHERE id = ?`, caller)
	require.NoError(t, err)
	w := newStartWorld()
	reg := startRegistry(t, fx.d, caller, w.deps())

	mustApply(t, reg, fx.a, "start_session", `{"folder":"hub","brief":"b","reason":"r"}`)
	mustApply(t, reg, fx.a, "start_session", `{"folder":"hub","brief":"b","agent":"claude","reason":"r"}`)
	require.Len(t, w.args, 2)
	assert.Equal(t, "codex", flag(w.args[0], "--agent"))
	assert.Equal(t, "claude", flag(w.args[1], "--agent"))
}

// Spec §6.5: sub-sessions nest at most three deep.
func TestLimitDepthThree(t *testing.T) {
	fx := newWorkbenchFixture(t)
	addBenchFolder(t, fx.d, fx.a, "hub")
	root := childOf(t, fx.d, fx.a, 0)
	c1 := childOf(t, fx.d, fx.a, root)
	c2 := childOf(t, fx.d, fx.a, c1)
	c3 := childOf(t, fx.d, fx.a, c2)
	w := newStartWorld()

	mustApply(t, startRegistry(t, fx.d, c2, w.deps()), fx.a, "start_session", `{"folder":"hub","brief":"b","reason":"r"}`)
	_, err := proposeIn(t, startRegistry(t, fx.d, c3, w.deps()), fx.a, "start_session", `{"folder":"hub","brief":"b","reason":"r"}`)
	require.Error(t, err)
	assert.Equal(t, fmt.Sprintf("limit: sub-sessions nest at most 3 deep; #%d is 3 deep under #%d.", c3, root), refusal(t, err))
	assert.Len(t, w.args, 1, "a refused start never reaches the CLI")
}

// Review Focus 5: the six-per-root limit counts every level of the tree,
// grandchildren included, and only live (or starting) sessions; a chain
// that lost its middle splits into two trees.
func TestLimitCountsTheWholeTree(t *testing.T) {
	fx := newWorkbenchFixture(t)
	addBenchFolder(t, fx.d, fx.a, "hub")
	root := childOf(t, fx.d, fx.a, 0)
	mid := childOf(t, fx.d, fx.a, root)
	sibling := childOf(t, fx.d, fx.a, root)
	g1 := childOf(t, fx.d, fx.a, mid)
	g2 := childOf(t, fx.d, fx.a, mid)
	g3 := childOf(t, fx.d, fx.a, mid)
	stopped := childOf(t, fx.d, fx.a, mid)
	starting := seedTerminalSession(t, fx.d, fx.a) // no state yet, created just now
	_, err := fx.d.Exec(`UPDATE terminal_sessions SET parent_session_id = ? WHERE id = ?`, g1, starting)
	require.NoError(t, err)
	w := newStartWorld()
	for _, id := range []int64{root, mid, sibling, g1, g2, g3} {
		w.runs[id] = true
	}
	_ = stopped // reported once, not in the host: not live

	want := fmt.Sprintf("limit: 6 sub-sessions are live under #%d", root)
	for _, caller := range []int64{root, sibling, g3} {
		_, err := proposeIn(t, startRegistry(t, fx.d, caller, w.deps()), fx.a, "start_session",
			`{"folder":"hub","brief":"b","reason":"r"}`)
		require.Error(t, err)
		assert.Equal(t, want, refusal(t, err), "caller #%d", caller)
	}
	assert.Empty(t, w.args)

	// A start that failed (its state written) or one long past its start
	// window is not live: five left, the next start passes.
	_, err = fx.d.Exec(`UPDATE terminal_sessions SET agent_state = 'waiting' WHERE id = ?`, starting)
	require.NoError(t, err)
	mustApply(t, startRegistry(t, fx.d, sibling, w.deps()), fx.a, "start_session", `{"folder":"hub","brief":"b","reason":"r"}`)

	// The middle is deleted: its children lose their parent (ON DELETE SET
	// NULL) and form trees of their own; root's tree is sibling alone.
	delete(w.runs, mid)
	_, err = fx.d.Exec(`UPDATE terminal_sessions SET parent_session_id = NULL WHERE parent_session_id = ?`, mid)
	require.NoError(t, err)
	_, err = fx.d.Exec(`DELETE FROM terminal_sessions WHERE id = ?`, mid)
	require.NoError(t, err)
	n, err := liveUnder(context.Background(), fx.d, w.runs, root)
	require.NoError(t, err)
	assert.Equal(t, 1, n)
	gotRoot, depth, err := rootOf(context.Background(), fx.d, starting)
	require.NoError(t, err)
	assert.Equal(t, g1, gotRoot, "a grandchild whose parent is gone counts under the new root, never the old one")
	assert.Equal(t, 1, depth)
}

// Spec §7 "sub-session start": a host that cannot be reached leaves no row
// and the tool's result carries the start's error; a refusal of the start
// (here not_installed) is the model-facing error as the CLI wrote it.
func TestStartSessionHostDownReturnsTheError(t *testing.T) {
	fx := newWorkbenchFixture(t)
	addBenchFolder(t, fx.d, fx.a, "hub")
	caller := childOf(t, fx.d, fx.a, 0)
	w := newStartWorld()
	reg := startRegistry(t, fx.d, caller, w.deps())

	w.answer = func() ([]byte, error) {
		return nil, errors.New("exit status 1: Error: the session host is not running: dial unix: no such file")
	}
	rc, err := proposeIn(t, reg, fx.a, "start_session", `{"folder":"hub","brief":"b","reason":"r"}`)
	require.NoError(t, err)
	assert.Equal(t, "failed", rc.Status)
	assert.Contains(t, rc.Error, "the session host is not running")

	// A refusal of the start is the receipt's error as the CLI wrote it.
	for _, c := range []struct{ out, want string }{
		{`{"ok":false,"error_code":"not_installed","error":"not_installed: Install Watchtower in hub first"}`,
			"not_installed: Install Watchtower in hub first"},
		{`{"error":"agent_not_found","agent":"codex"}`, "agent_not_found: codex is not installed on this Mac."},
	} {
		w.answer = func() ([]byte, error) { return []byte(c.out), errors.New("exit status 1") }
		rc, err := proposeIn(t, reg, fx.a, "start_session", `{"folder":"hub","brief":"b","reason":"r"}`)
		require.NoError(t, err)
		assert.Equal(t, "failed", rc.Status)
		assert.Equal(t, c.want, rc.Error)
	}

	// No session host in this process: refused before any start.
	_, err = proposeIn(t, startRegistry(t, fx.d, caller, SessionDeps{}), fx.a, "start_session",
		`{"folder":"hub","brief":"b","reason":"r"}`)
	require.Error(t, err)
	assert.Equal(t, "the session host cannot be reached from this process", err.Error())
	assert.Len(t, w.args, 3)
}

func TestListSessionsShowsOnlyLiveOnesOfTheBench(t *testing.T) {
	fx := newWorkbenchFixture(t)
	hub := addBenchFolder(t, fx.d, fx.a, "hub")
	home, err := fx.d.HomeFolder(context.Background(), fx.a)
	require.NoError(t, err)
	w := newStartWorld()
	reg := startRegistry(t, fx.d, 0, w.deps())

	assert.Equal(t, "[]", callReadIn(t, reg, fx.a, "list_sessions", `{}`), "none live: an empty list, never null")

	parent := childOf(t, fx.d, fx.a, 0)
	child := childOf(t, fx.d, fx.a, parent)
	_, err = fx.d.Exec(`UPDATE terminal_sessions SET workbench_folder_id = ?, title = 'Hub work' WHERE id = ?`, hub.ID, child)
	require.NoError(t, err)
	starting := seedTerminalSession(t, fx.d, fx.a)
	stopped := childOf(t, fx.d, fx.a, 0)
	shell := childOf(t, fx.d, fx.a, 0)
	_, err = fx.d.Exec(`UPDATE terminal_sessions SET kind = 'shell', claude_session_id = NULL WHERE id = ?`, shell)
	require.NoError(t, err)
	deleting := childOf(t, fx.d, fx.a, 0)
	_, err = fx.d.Exec(`UPDATE terminal_sessions SET delete_requested_at = '2026-11-18T00:00:00Z' WHERE id = ?`, deleting)
	require.NoError(t, err)
	other := childOf(t, fx.d, fx.b, 0)
	for _, id := range []int64{parent, child, shell, deleting, other} {
		w.runs[id] = true
	}
	_ = stopped

	var got []map[string]any
	require.NoError(t, json.Unmarshal([]byte(callReadIn(t, reg, fx.a, "list_sessions", `{}`)), &got))
	assert.Equal(t, []map[string]any{
		{"session_id": float64(parent), "title": "New session", "folder": home.Name, "state": "working",
			"parent_session_id": nil, "live": true},
		{"session_id": float64(child), "title": "Hub work", "folder": "hub", "state": "working",
			"parent_session_id": float64(parent), "live": true},
		{"session_id": float64(starting), "title": "New session", "folder": home.Name, "state": "starting",
			"parent_session_id": nil, "live": false},
	}, got)
}

func TestWorkbenchInfoListsFolders(t *testing.T) {
	fx := newWorkbenchFixture(t)
	hub := addBenchFolder(t, fx.d, fx.a, "hub")
	_, err := devpack.InstallStateHooks(hub.FolderPath, "/usr/local/bin/watchtower", fx.a)
	require.NoError(t, err)
	home, err := fx.d.HomeFolder(context.Background(), fx.a)
	require.NoError(t, err)
	reg := workbenchRegistry(t, fx.d)

	var info struct {
		Folders []folderView `json:"folders"`
	}
	require.NoError(t, json.Unmarshal([]byte(callReadIn(t, reg, fx.a, "workbench_info", `{}`)), &info))
	assert.Equal(t, []folderView{
		{Name: home.Name, Path: home.FolderPath, Home: true, Installed: false},
		{Name: "hub", Path: hub.FolderPath, Home: false, Installed: true},
	}, info.Folders)

	// No folder on the bench: an empty list on the wire, never null.
	_, err = fx.d.Exec(`UPDATE workbench_folders SET removed_at = '2026-11-18T00:00:00Z' WHERE workbench_id = ?`, fx.a)
	require.NoError(t, err)
	assert.Contains(t, callReadIn(t, reg, fx.a, "workbench_info", `{}`), `"folders":[]`)
}
