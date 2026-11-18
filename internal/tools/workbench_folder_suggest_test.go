package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// outsideRepo is a resolved repository folder outside every bench.
func outsideRepo(t *testing.T, name string) string {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	dir := filepath.Join(root, name)
	require.NoError(t, os.MkdirAll(filepath.Join(dir, ".git"), 0o755))
	return dir
}

func folderPayload(t *testing.T, d *db.DB, wb, id int64) db.FolderAskPayload {
	t.Helper()
	a := storedAsk(t, d, wb, id)
	assert.Equal(t, db.AskKindFolder, a.Kind)
	var p db.FolderAskPayload
	require.NoError(t, json.Unmarshal([]byte(a.Payload), &p))
	return p
}

func TestSuggestCreatesOneOpenAskPerPath(t *testing.T) {
	fx := newWorkbenchFixture(t)
	caller := seedTerminalSession(t, fx.d, fx.a)
	reg := startRegistry(t, fx.d, caller, SessionDeps{})
	lib := outsideRepo(t, "lib")
	for range 3 {
		_, _, _, err := fx.d.CountOutsideTouch(context.Background(), caller, lib)
		require.NoError(t, err)
	}

	args := fmt.Sprintf(`{"path":%q,"why":"The API client lives there.","reason":"the task edits it"}`, lib)
	out := mustApply(t, reg, fx.a, SuggestWorkbenchFolderTool, args)
	id := askID(t, out)
	assert.Equal(t, "open", out["status"])
	assert.Equal(t, lib, out["path"])
	assert.Equal(t, lib, out["repo_root"])
	assert.NotContains(t, out, "existing")
	assert.NotContains(t, out, "other_bench")
	a := storedAsk(t, fx.d, fx.a, id)
	assert.Equal(t, "Put lib on the bench?", a.Title)
	assert.Equal(t, "The API client lives there.", a.Summary)
	assert.Equal(t, caller, a.SessionID.Int64)
	assert.Equal(t, db.FolderAskPayload{Path: lib, RepoRoot: lib, Touches: 3, Why: "The API client lives there."},
		folderPayload(t, fx.d, fx.a, id))

	// A second call for the same folder, any spelling, answers the open ask.
	again := mustApply(t, reg, fx.a, SuggestWorkbenchFolderTool,
		fmt.Sprintf(`{"path":%q,"why":"again","reason":"r"}`, filepath.Join(lib, "src", "..")))
	assert.Equal(t, float64(id), again["ask_id"])
	assert.Equal(t, true, again["existing"])

	// A subfolder maps to its repository; another bench files its own ask.
	sub := filepath.Join(lib, "pkg")
	require.NoError(t, os.Mkdir(sub, 0o755))
	nested := mustApply(t, reg, fx.a, SuggestWorkbenchFolderTool, fmt.Sprintf(`{"path":%q,"why":"w","reason":"r"}`, sub))
	assert.NotEqual(t, float64(id), nested["ask_id"])
	assert.Equal(t, lib, nested["repo_root"])
	other := mustApply(t, reg, fx.b, SuggestWorkbenchFolderTool, args)
	assert.NotEqual(t, float64(id), other["ask_id"])

	// Answered, the next suggestion files a new ask.
	_, err := fx.d.Exec(`UPDATE owner_asks SET status = 'answered', answer = '{}' WHERE id = ?`, id)
	require.NoError(t, err)
	next := mustApply(t, reg, fx.a, SuggestWorkbenchFolderTool, args)
	assert.NotEqual(t, float64(id), next["ask_id"])

	// Refusals as putting it on the bench would refuse it, nothing filed.
	home, err := fx.d.HomeFolder(context.Background(), fx.a)
	require.NoError(t, err)
	for _, c := range []struct{ args, want string }{
		{fmt.Sprintf(`{"path":%q,"why":"w","reason":"r"}`, filepath.Join(lib, "missing")), "not_found: "},
		{fmt.Sprintf(`{"path":%q,"why":"w","reason":"r"}`, home.FolderPath), "already_here: "},
		{fmt.Sprintf(`{"path":%q,"why":" ","reason":"r"}`, lib), "why is required"},
		{`{"path":"","why":"w","reason":"r"}`, "path is required"},
	} {
		_, err := proposeIn(t, reg, fx.a, SuggestWorkbenchFolderTool, c.args)
		require.Error(t, err, c.args)
		assert.Contains(t, refusal(t, err), c.want, c.args)
	}
}

func TestSuggestDeclinedPath(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := startRegistry(t, fx.d, 0, SessionDeps{})
	lib := outsideRepo(t, "lib")
	require.NoError(t, fx.d.DeclineFolder(context.Background(), fx.a, lib))
	before := countActions(t, fx.d)

	_, err := proposeIn(t, reg, fx.a, SuggestWorkbenchFolderTool, fmt.Sprintf(`{"path":%q,"why":"w","reason":"r"}`, lib))
	require.Error(t, err)
	assert.Equal(t, "declined: The owner does not want lib on this bench.", refusal(t, err))
	// A folder inside the declined repository is declined with it.
	sub := filepath.Join(lib, "pkg")
	require.NoError(t, os.Mkdir(sub, 0o755))
	_, err = proposeIn(t, reg, fx.a, SuggestWorkbenchFolderTool, fmt.Sprintf(`{"path":%q,"why":"w","reason":"r"}`, sub))
	assert.Contains(t, refusal(t, err), "declined: ")
	assert.Equal(t, before, countActions(t, fx.d), "a refusal records nothing")

	// The decline is this bench's only: another bench may still be asked.
	out := mustApply(t, reg, fx.b, SuggestWorkbenchFolderTool, fmt.Sprintf(`{"path":%q,"why":"w","reason":"r"}`, lib))
	assert.Equal(t, "open", out["status"])
	assert.False(t, storedAsk(t, fx.d, fx.b, askID(t, out)).SessionID.Valid, "no calling session: none bound")
}

// Watchtower's own state dirs are refused as `workbench folder add` refuses
// them (one shared list), and a linked worktree of a bench folder is
// already on the bench — no ask is filed for either.
func TestSuggestRefusesStateDirsAndBenchWorktrees(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := startRegistry(t, fx.d, 0, SessionDeps{})
	home, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	t.Setenv("HOME", home)
	state := filepath.Join(home, ".config", "watchtower", "repo")
	require.NoError(t, os.MkdirAll(filepath.Join(state, ".git"), 0o755))

	_, err = proposeIn(t, reg, fx.a, SuggestWorkbenchFolderTool, fmt.Sprintf(`{"path":%q,"why":"w","reason":"r"}`, state))
	require.Error(t, err)
	assert.Contains(t, refusal(t, err), "not_allowed: ")

	bench := outsideRepo(t, "app")
	_, err = fx.d.Exec(`INSERT INTO workbench_folders (workbench_id, folder_path, position, added_by, name)
		VALUES (?, ?, 1, 'owner', 'app')`, fx.a, bench)
	require.NoError(t, err)
	wt := outsideRepo(t, "wt")
	require.NoError(t, os.RemoveAll(filepath.Join(wt, ".git")))
	require.NoError(t, os.WriteFile(filepath.Join(wt, ".git"),
		[]byte("gitdir: "+filepath.Join(bench, ".git", "worktrees", "wt")+"\n"), 0o600))
	_, err = proposeIn(t, reg, fx.a, SuggestWorkbenchFolderTool, fmt.Sprintf(`{"path":%q,"why":"w","reason":"r"}`, wt))
	require.Error(t, err)
	assert.Equal(t, fmt.Sprintf("already_here: %s is a worktree of %s, already on this bench as app.", wt, bench), refusal(t, err))

	var n int
	require.NoError(t, fx.d.QueryRow(`SELECT COUNT(*) FROM owner_asks WHERE kind = 'folder'`).Scan(&n))
	assert.Zero(t, n, "no ask filed")
}

// Spec §6.13: a folder on another bench is no refusal — the ask carries
// that bench, so the card offers the merge.
func TestSuggestOtherBenchCarriesTheBench(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := startRegistry(t, fx.d, 0, SessionDeps{})
	lib := outsideRepo(t, "lib")
	_, err := fx.d.Exec(`INSERT INTO workbench_folders (workbench_id, folder_path, position, added_by, name)
		VALUES (?, ?, 1, 'owner', 'lib')`, fx.b, lib)
	require.NoError(t, err)

	out := mustApply(t, reg, fx.a, SuggestWorkbenchFolderTool, fmt.Sprintf(`{"path":%q,"why":"w","reason":"r"}`, lib))
	assert.Equal(t, map[string]any{"id": float64(fx.b), "name": "beta"}, out["other_bench"])
	p := folderPayload(t, fx.d, fx.a, askID(t, out))
	require.NotNil(t, p.OtherBench)
	assert.Equal(t, db.FolderAskOthers{ID: fx.b, Name: "beta"}, *p.OtherBench)
	raw := storedAsk(t, fx.d, fx.a, askID(t, out)).Payload
	assert.Contains(t, raw, `"other_bench":{"id":`)
}
