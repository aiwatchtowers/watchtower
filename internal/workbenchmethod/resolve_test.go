package workbenchmethod

import (
	"errors"
	"path/filepath"
	"testing"
	"time"

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

// Spec §5: a refused file contributes nothing — its keys are ignored, the
// personal settings still apply (since board #558 no file weakens a check).
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
	writeWorkflow(t, folder, "---\npreset: none\nfinish_check: off\n---\n")
	require.NoError(t, d.SetWorkbenchMethodology(id, db.WorkbenchMethodology{AskGuard: AskGuardSoft}))

	e := Resolve(d, id, "")

	require.NoError(t, e.Err)
	assert.Equal(t, AskGuardSoft, e.AskGuard)
	assert.Equal(t, PresetNone, e.Preset)
	assert.Equal(t, SourceFile, e.Sources.Preset)
	assert.True(t, e.FinishOn(), "the file never turns a check down (board #558)")
	assert.Equal(t, SourceDefault, e.Sources.FinishCheck)
	assert.Equal(t, []string{"finish_check: off"}, e.FileIgnored())
}

// Board #558: the folder file is repo content (a clone, a pulled branch, the
// agent's own worktree edit), so it never weakens a check — its preset and
// body apply, its ask_guard and finish_check do not; only the owner's
// personal setting turns a check down. FileIgnored names what it asked for.
func TestCombine_FileNeverWeakensTheChecks(t *testing.T) {
	file := File{Present: true, Preset: PresetNone, AskGuard: AskGuardOff, FinishCheck: FinishOff, Body: "Team rules."}
	e := Combine(db.WorkbenchMethodology{}, file)
	assert.Equal(t, AskGuardStrict, e.AskGuard)
	assert.Equal(t, SourceDefault, e.Sources.AskGuard)
	assert.True(t, e.FinishOn())
	assert.Equal(t, SourceDefault, e.Sources.FinishCheck)
	assert.Equal(t, PresetNone, e.Preset, "the preset still comes from the file")
	assert.Equal(t, []string{"ask_guard: off", "finish_check: off"}, e.FileIgnored())

	soft := Combine(db.WorkbenchMethodology{}, File{Present: true, AskGuard: AskGuardSoft})
	assert.Equal(t, AskGuardStrict, soft.AskGuard)
	assert.Equal(t, []string{"ask_guard: soft"}, soft.FileIgnored())

	mine := Combine(db.WorkbenchMethodology{AskGuard: AskGuardOff, FinishCheck: FinishOff}, File{Present: true})
	assert.Equal(t, AskGuardOff, mine.AskGuard, "the owner's own setting still weakens")
	assert.False(t, mine.FinishOn())

	assert.Equal(t, []string{}, Combine(db.WorkbenchMethodology{},
		File{Present: true, AskGuard: AskGuardStrict, FinishCheck: FinishOn}).FileIgnored(), "never nil")
	assert.Empty(t, Combine(db.WorkbenchMethodology{},
		File{Present: true, AskGuard: AskGuardOff, Err: errors.New("unknown key")}).FileIgnored(), "a refused file asks for nothing")
	// With a personal value the file would not have applied anyway: not listed.
	assert.Equal(t, []string{"finish_check: off"}, Combine(db.WorkbenchMethodology{AskGuard: AskGuardSoft},
		File{Present: true, AskGuard: AskGuardOff, FinishCheck: FinishOff}).FileIgnored())
}

// Board #558's one-time carry-over: a carry-pending workbench (one that
// existed at migration 00133) gets its file's weaker checks as the owner's
// personal values where none is set, once; a set value, a strict or refused
// file and a workbench that is not pending (created later, or a fresh
// install) are left alone, and a second run changes nothing.
func TestCarryOverFileChecks(t *testing.T) {
	d := openDB(t)
	off, mine, strict, broken, fresh := t.TempDir(), t.TempDir(), t.TempDir(), t.TempDir(), t.TempDir()
	ids := map[string]int64{}
	for name, folder := range map[string]string{"off": off, "mine": mine, "strict": strict, "broken": broken, "fresh": fresh} {
		id, err := d.CreateWorkbench(name, folder)
		require.NoError(t, err)
		ids[name] = id
	}
	writeWorkflow(t, off, "---\npreset: none\nask_guard: off\nfinish_check: off\n---\n")
	writeWorkflow(t, mine, "---\nask_guard: off\nfinish_check: off\n---\n")
	writeWorkflow(t, strict, "---\nask_guard: strict\n---\n")
	writeWorkflow(t, broken, "---\nask_guard: off\nmode: x\n---\n")
	writeWorkflow(t, fresh, "---\nask_guard: off\nfinish_check: off\n---\n")
	require.NoError(t, d.SetWorkbenchMethodology(ids["mine"], db.WorkbenchMethodology{AskGuard: AskGuardSoft}))
	// What migration 00133 does to the rows that exist at the upgrade.
	_, err := d.Exec(`UPDATE projects SET methodology_carry_pending = 1 WHERE id IN (?, ?, ?, ?)`,
		ids["off"], ids["mine"], ids["strict"], ids["broken"])
	require.NoError(t, err)
	now := time.Date(2026, 10, 17, 9, 0, 0, 0, time.UTC)

	done, err := CarryOverFileChecks(d, now)

	require.NoError(t, err)
	assert.ElementsMatch(t, []int64{ids["off"], ids["mine"], ids["strict"], ids["broken"]}, done)
	got := func(name string) db.WorkbenchMethodology {
		m, err := d.GetWorkbenchMethodology(ids[name])
		require.NoError(t, err)
		return m
	}
	assert.Equal(t, db.WorkbenchMethodology{AskGuard: AskGuardOff, FinishCheck: FinishOff}, got("off"), "the preset is not carried")
	assert.Equal(t, db.WorkbenchMethodology{AskGuard: AskGuardSoft, FinishCheck: FinishOff}, got("mine"), "a set value wins")
	assert.Equal(t, db.WorkbenchMethodology{}, got("strict"))
	assert.Equal(t, db.WorkbenchMethodology{}, got("broken"))
	assert.Equal(t, db.WorkbenchMethodology{}, got("fresh"), "not pending: never carried")
	carried, err := d.GetWorkbenchChecksCarried(ids["off"])
	require.NoError(t, err)
	assert.Equal(t, db.WorkbenchChecksCarried{AskGuard: "2026-10-17T09:00:00Z", FinishCheck: "2026-10-17T09:00:00Z"}, carried)

	again, err := CarryOverFileChecks(d, now)
	require.NoError(t, err)
	assert.Empty(t, again)
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
	writeWorkflow(t, main, "---\npreset: watchtower-flow\n---\n")
	writeWorkflow(t, worktree, "---\npreset: none\n---\n")
	res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id) VALUES (?, 'claude', 's', ?, 'sid-1')`, id, worktree)
	require.NoError(t, err)
	row, err := res.LastInsertId()
	require.NoError(t, err)
	other, err := d.CreateWorkbench("beta", t.TempDir())
	require.NoError(t, err)

	assert.Equal(t, PresetNone, ResolveSession(d, id, row).Preset, "the row's own folder")
	assert.Equal(t, SourceFile, ResolveSession(d, id, 0).Sources.Preset, "no row: the workbench folder")
	assert.Equal(t, PresetFlow, ResolveSession(d, id, 0).Preset, "no row: the workbench folder")
	assert.Equal(t, PresetFlow, ResolveSession(d, id, row+100).Preset, "a gone row: the workbench folder")
	assert.Equal(t, SourceDefault, ResolveSession(d, other, row).Sources.Preset, "another workbench's row is not its session")
}

// A session read that fails (not a missing row) must not fall back to the
// workbench folder's file: strict and on, Err set.
func TestResolveSession_UnreadableSessionIsStrict(t *testing.T) {
	d := openDB(t)
	folder := t.TempDir()
	id, err := d.CreateWorkbench("acme", folder)
	require.NoError(t, err)
	writeWorkflow(t, folder, "---\nask_guard: off\nfinish_check: off\n---\n")
	_, err = d.Exec(`ALTER TABLE terminal_sessions DROP COLUMN worktree_branch`)
	require.NoError(t, err)

	e := ResolveSession(d, id, 1)

	require.Error(t, e.Err)
	assert.Equal(t, AskGuardStrict, e.AskGuard)
	assert.True(t, e.FinishOn())
}
