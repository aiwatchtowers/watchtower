package workbenchmethod

import (
	"errors"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func openDB(t *testing.T) *db.DB {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "w.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	return d
}

func TestCombine_NoFileNoOverridesIsTodaysBehaviour(t *testing.T) {
	e := Combine(db.WorkbenchMethodology{}, File{})
	assert.Equal(t, Defaults(), e)
	assert.Equal(t, PresetFlow, e.Preset)
	assert.Equal(t, AskGuardStrict, e.AskGuard)
	assert.True(t, e.FinishOn())
}

func TestCombine_Precedence(t *testing.T) {
	file := File{Present: true, Preset: PresetNone, AskGuard: AskGuardSoft}
	e := Combine(db.WorkbenchMethodology{AskGuard: AskGuardOff}, file)
	assert.Equal(t, PresetNone, e.Preset)
	assert.Equal(t, SourceFile, e.Sources.Preset)
	assert.Equal(t, AskGuardOff, e.AskGuard)
	assert.Equal(t, SourcePersonal, e.Sources.AskGuard)
	assert.Equal(t, FinishOn, e.FinishCheck)
	assert.Equal(t, SourceDefault, e.Sources.FinishCheck)
	assert.Equal(t, "folder file", e.Sources.Preset.Label())
}

// Spec §5: a refused file never weakens a check — its keys are ignored, the
// personal settings still apply.
func TestCombine_RefusedFileFallsToDefaults(t *testing.T) {
	broken := File{Present: true, AskGuard: AskGuardOff, FinishCheck: FinishOff, Err: errors.New("unknown key")}
	e := Combine(db.WorkbenchMethodology{}, broken)
	assert.Equal(t, AskGuardStrict, e.AskGuard)
	assert.True(t, e.FinishOn())
	e = Combine(db.WorkbenchMethodology{AskGuard: AskGuardSoft}, broken)
	assert.Equal(t, AskGuardSoft, e.AskGuard)
	assert.Equal(t, SourcePersonal, e.Sources.AskGuard)
}

func TestResolve_ReadsTheDatabaseAndTheFolderFile(t *testing.T) {
	d := openDB(t)
	folder := t.TempDir()
	id, err := d.CreateWorkbench("acme", folder)
	require.NoError(t, err)
	writeWorkflow(t, folder, "---\nfinish_check: off\n---\n")
	require.NoError(t, d.SetWorkbenchMethodology(id, db.WorkbenchMethodology{AskGuard: AskGuardSoft}))

	e := Resolve(d, id, "")

	require.NoError(t, e.Err)
	assert.Equal(t, AskGuardSoft, e.AskGuard)
	assert.False(t, e.FinishOn())
	assert.Equal(t, SourceFile, e.Sources.FinishCheck)
}

// PROJ-13 (spec §7): a database that cannot be read — a schema a migration
// behind, a gone workbench — resolves to strict and on, whatever the file says.
func TestResolve_UnreadableDatabaseIsStrict(t *testing.T) {
	d := openDB(t)
	folder := t.TempDir()
	id, err := d.CreateWorkbench("acme", folder)
	require.NoError(t, err)
	writeWorkflow(t, folder, "---\nask_guard: off\nfinish_check: off\n---\n")
	_, err = d.Exec(`ALTER TABLE projects DROP COLUMN ask_guard_mode`)
	require.NoError(t, err)

	e := Resolve(d, id, "")
	require.Error(t, e.Err)
	assert.Equal(t, AskGuardStrict, e.AskGuard)
	assert.True(t, e.FinishOn())

	gone := Resolve(openDB(t), 999, folder)
	assert.ErrorIs(t, gone.Err, db.ErrWorkbenchNotFound)
	assert.Equal(t, AskGuardStrict, gone.AskGuard)
}

// Spec §5: in a session worktree the session row's own folder is read.
func TestResolveSession_ReadsTheSessionsFolder(t *testing.T) {
	d := openDB(t)
	main, worktree := t.TempDir(), t.TempDir()
	id, err := d.CreateWorkbench("acme", main)
	require.NoError(t, err)
	writeWorkflow(t, main, "---\nask_guard: soft\n---\n")
	writeWorkflow(t, worktree, "---\nask_guard: off\n---\n")
	res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id) VALUES (?, 'claude', 's', ?, 'sid-1')`, id, worktree)
	require.NoError(t, err)
	row, err := res.LastInsertId()
	require.NoError(t, err)
	other, err := d.CreateWorkbench("beta", t.TempDir())
	require.NoError(t, err)

	assert.Equal(t, AskGuardOff, ResolveSession(d, id, row).AskGuard, "the row's own folder")
	assert.Equal(t, AskGuardSoft, ResolveSession(d, id, 0).AskGuard, "no row: the workbench folder")
	assert.Equal(t, AskGuardSoft, ResolveSession(d, id, row+100).AskGuard, "a gone row: the workbench folder")
	assert.Equal(t, AskGuardStrict, ResolveSession(d, other, row).AskGuard, "another workbench's row is not its session")
}
