package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/workbenchfolders"
)

// addBenchFolder puts a second folder named name on workbench wb, as the
// owner's Put on the Bench writes it.
func addBenchFolder(t *testing.T, d *db.DB, wb int64, name string) db.WorkbenchFolder {
	t.Helper()
	dir := filepath.Join(t.TempDir(), name)
	require.NoError(t, os.Mkdir(dir, 0o755))
	path, err := db.ResolveWorkbenchFolder(dir, nil)
	require.NoError(t, err)
	res, err := d.Exec(`INSERT INTO workbench_folders (workbench_id, folder_path, position, added_by, name)
		VALUES (?, ?, 1, 'owner', ?)`, wb, path, name)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	f, err := d.WorkbenchFolderByID(context.Background(), id)
	require.NoError(t, err)
	return *f
}

// seedFolderSession is a terminal session of workbench wb started in folder.
func seedFolderSession(t *testing.T, d *db.DB, wb, folder int64) string {
	t.Helper()
	id := seedTerminalSession(t, d, wb)
	_, err := d.Exec(`UPDATE terminal_sessions SET workbench_folder_id = ? WHERE id = ?`, folder, id)
	require.NoError(t, err)
	return strconv.FormatInt(id, 10)
}

func targetFolderID(t *testing.T, d *db.DB, id int64) sql.NullInt64 {
	t.Helper()
	tg, err := d.GetTargetByID(int(id))
	require.NoError(t, err)
	return tg.WorkbenchFolderID
}

// Spec 2026-11-18 §6.10: a target carrying git work stores the bench folder
// that work is in — the folder named, else the calling session's; a target
// with no branch or PR stores none (the home folder).
func TestCreateTargetsStoresTheCallersFolder(t *testing.T) {
	fx := newWorkbenchFixture(t)
	hub := addBenchFolder(t, fx.d, fx.a, "hub")
	home, err := fx.d.HomeFolderID(context.Background(), fx.a)
	require.NoError(t, err)
	reg := askRegistry(t, fx.d, seedFolderSession(t, fx.d, fx.a, hub.ID))

	out := mustApply(t, reg, fx.a, "create_targets", `{"items":[
		{"text":"On a branch","branch":"feature/x"},
		{"text":"With a PR","pr":"#12"},
		{"text":"Named folder","branch":"feature/y","folder":"`+strconv.FormatInt(home, 10)+`"},
		{"text":"No git work"}
	],"reason":"plan"}`)
	ids := createdIDs(t, out)
	require.Len(t, ids, 4)
	assert.Equal(t, sql.NullInt64{Int64: hub.ID, Valid: true}, targetFolderID(t, fx.d, ids[0]), "a branch takes the session's folder")
	assert.Equal(t, sql.NullInt64{Int64: hub.ID, Valid: true}, targetFolderID(t, fx.d, ids[1]), "a PR takes the session's folder")
	assert.Equal(t, sql.NullInt64{Int64: home, Valid: true}, targetFolderID(t, fx.d, ids[2]), "a named folder wins (here by id)")
	assert.False(t, targetFolderID(t, fx.d, ids[3]).Valid, "no git work: no folder")

	// Outside a session (or a session with no folder) nothing is stored.
	out = mustApply(t, askRegistry(t, fx.d, ""), fx.a, "create_targets", `{"items":[{"text":"CLI","branch":"feature/z"}],"reason":"r"}`)
	assert.False(t, targetFolderID(t, fx.d, createdIDs(t, out)[0]).Valid)

	// By name and by path.
	out = mustApply(t, reg, fx.a, "create_targets", fmt.Sprintf(`{"items":[{"text":"By name","folder":"HUB"},{"text":"By path","folder":%q}],"reason":"r"}`,
		hub.FolderPath))
	for _, id := range createdIDs(t, out) {
		assert.Equal(t, sql.NullInt64{Int64: hub.ID, Valid: true}, targetFolderID(t, fx.d, id))
	}
}

func TestUpdateTargetFolderByName(t *testing.T) {
	fx := newWorkbenchFixture(t)
	hub := addBenchFolder(t, fx.d, fx.a, "hub")
	reg := askRegistry(t, fx.d, "")

	mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"folder":"hub","reason":"r"}`, fx.aTarget))
	assert.Equal(t, sql.NullInt64{Int64: hub.ID, Valid: true}, targetFolderID(t, fx.d, fx.aTarget), "folder alone is an update")

	// A status change leaves the folder alone.
	mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"status":"in_progress","reason":"r"}`, fx.aTarget))
	assert.Equal(t, hub.ID, targetFolderID(t, fx.d, fx.aTarget).Int64)

	// A branch set from a session without folder stores the session's folder.
	home, err := fx.d.HomeFolderID(context.Background(), fx.a)
	require.NoError(t, err)
	inHome := askRegistry(t, fx.d, seedFolderSession(t, fx.d, fx.a, home))
	mustApply(t, inHome, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"branch":"feature/x","reason":"r"}`, fx.aTarget))
	assert.Equal(t, home, targetFolderID(t, fx.d, fx.aTarget).Int64, "last write wins, as for branch")
	// Clearing the branch does not move it.
	mustApply(t, inHome, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"branch":"","folder":"hub","reason":"r"}`, fx.aTarget))
	assert.Equal(t, hub.ID, targetFolderID(t, fx.d, fx.aTarget).Int64)
}

func TestUpdateTargetUnknownFolderIsRefused(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := askRegistry(t, fx.d, "")
	otherBench := addBenchFolder(t, fx.d, fx.b, "beta-hub")
	removed := addBenchFolder(t, fx.d, fx.a, "old")
	_, err := fx.d.Exec(`UPDATE workbench_folders SET removed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?`, removed.ID)
	require.NoError(t, err)

	for ref, code := range map[string]string{
		"nowhere":             workbenchfolders.CodeNotFound,
		otherBench.FolderPath: workbenchfolders.CodeNotFound, // another bench's folder is not this one's
		"beta-hub":            workbenchfolders.CodeNotFound,
		removed.FolderPath:    workbenchfolders.CodeFolderRemoved,
	} {
		for _, call := range []struct{ tool, args string }{
			{"update_target", fmt.Sprintf(`{"target_id":%d,"folder":%q,"reason":"r"}`, fx.aTarget, ref)},
			{"create_targets", fmt.Sprintf(`{"items":[{"text":"x","folder":%q}],"reason":"r"}`, ref)},
		} {
			before := countWorkbenchTargets(t, fx.d, fx.a)
			_, err := reg.Propose(context.Background(), call.tool, json.RawMessage(call.args), directBinding(fx.a))
			var verr *ValidationError
			require.ErrorAs(t, err, &verr, "%s %s", call.tool, ref)
			assert.Contains(t, verr.Error(), code+": ", "<code>: <sentence> (D42)")
			assert.Equal(t, before, countWorkbenchTargets(t, fx.d, fx.a), "nothing is created")
		}
	}
	assert.False(t, targetFolderID(t, fx.d, fx.aTarget).Valid, "nothing is written")
}
