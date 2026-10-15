package cmd

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/devpack"
	"watchtower/internal/workbenchmethod"
)

func flowFileIn(folder string) string {
	return filepath.Join(folder, ".claude", "skills", devpack.FlowSkillName, "SKILL.md")
}

func coreFileIn(folder string) string {
	return filepath.Join(folder, ".claude", "skills", devpack.WorkbenchSkillName, "SKILL.md")
}

// Spec §4.3: resync installs the preset by the effective setting, and takes
// it out again once the owner sets none.
func TestWorkbenchResync_FollowsThePreset(t *testing.T) {
	database := writeActionsConfig(t)
	useFakeWorkbenchClaude(t)
	folder := resyncFolder(t)
	pid, err := database.CreateWorkbench("acme", folder)
	require.NoError(t, err)
	id := strconv.FormatInt(pid, 10)

	out, _, err := runResync(t, id, "--json")
	require.NoError(t, err)
	assert.Equal(t, "installed", decodeResync(t, out).Flow)
	assert.FileExists(t, flowFileIn(folder))

	require.NoError(t, database.SetWorkbenchMethodology(pid, db.WorkbenchMethodology{Preset: workbenchmethod.PresetNone}))
	out, _, err = runResync(t, id, "--json")
	require.NoError(t, err)
	assert.Equal(t, "removed", decodeResync(t, out).Flow)
	assert.NoFileExists(t, flowFileIn(folder))
	assert.FileExists(t, coreFileIn(folder))
}

// Spec §4.3: an edited single-file skill is kept, and resync says so once.
func TestWorkbenchResync_ReportsASingleFileLayout(t *testing.T) {
	database := writeActionsConfig(t)
	useFakeWorkbenchClaude(t)
	folder := resyncFolder(t)
	pid, err := database.CreateWorkbench("acme", folder)
	require.NoError(t, err)
	v8, err := os.ReadFile(filepath.Join("..", "internal", "devpack", "testdata", "watchtower-workbench-v8.md"))
	require.NoError(t, err)
	edited := string(v8) + "\nMy own note.\n"
	require.NoError(t, os.MkdirAll(filepath.Dir(coreFileIn(folder)), 0o755))
	require.NoError(t, os.WriteFile(coreFileIn(folder), []byte(edited), 0o644))

	out, _, err := runResync(t, strconv.FormatInt(pid, 10), "--json")

	require.NoError(t, err)
	res := decodeResync(t, out)
	assert.True(t, res.SingleFileLayout)
	assert.Contains(t, res.Suggestions, singleFileLayoutNote)
	assert.NoFileExists(t, flowFileIn(folder))
	got, err := os.ReadFile(coreFileIn(folder))
	require.NoError(t, err)
	assert.Equal(t, edited, string(got))
}

// Spec §8: a preset change runs the install right after the write; another
// setting does not.
func TestWorkbenchMethodology_PresetChangeRunsTheInstall(t *testing.T) {
	database := writeActionsConfig(t)
	useFakeWorkbenchClaude(t)
	folder := resyncFolder(t)
	pid, err := database.CreateWorkbench("acme", folder)
	require.NoError(t, err)
	id := strconv.FormatInt(pid, 10)
	_, _, err = runResync(t, id, "--json")
	require.NoError(t, err)

	out, _, err := runMethodology(t, id, "--preset", "none", "--json")
	require.NoError(t, err)
	res := decodeMethodology(t, out)
	assert.True(t, res.InstallRan)
	assert.True(t, res.InstallOK, res.InstallError)
	assert.NoFileExists(t, flowFileIn(folder))

	out, _, err = runMethodology(t, id, "--ask-guard", "soft", "--json")
	require.NoError(t, err)
	assert.False(t, decodeMethodology(t, out).InstallRan, "no preset change, no install")

	out, _, err = runMethodology(t, id, "--preset", "file", "--json")
	require.NoError(t, err)
	assert.True(t, decodeMethodology(t, out).InstallRan)
	assert.FileExists(t, flowFileIn(folder))
}

// A new session worktree gets the skills by the workbench's setting.
func TestInstallWorktreeIntegration_UsesTheWorkbenchPreset(t *testing.T) {
	database := writeActionsConfig(t)
	useFakeWorkbenchClaude(t)
	pid, err := database.CreateWorkbench("acme", resyncFolder(t))
	require.NoError(t, err)
	require.NoError(t, database.SetWorkbenchMethodology(pid, db.WorkbenchMethodology{Preset: workbenchmethod.PresetNone}))
	worktree := resyncFolder(t)

	require.NoError(t, installWorktreeIntegration(context.Background(), pid, worktree))

	assert.FileExists(t, coreFileIn(worktree))
	assert.NoFileExists(t, flowFileIn(worktree))
}

// Spec §6: the mismatch line names what to run; nothing when the folder has
// no core skill, or when it agrees.
func TestBriefPresetMismatch(t *testing.T) {
	folder := t.TempDir()
	flow := workbenchmethod.Defaults()
	none := workbenchmethod.Combine(db.WorkbenchMethodology{Preset: workbenchmethod.PresetNone}, workbenchmethod.File{})
	assert.Empty(t, briefPresetMismatch(flow, folder, 7), "nothing installed: nothing to say")

	_, core := devpack.WorkbenchSkill()
	require.NoError(t, os.MkdirAll(filepath.Dir(coreFileIn(folder)), 0o755))
	require.NoError(t, os.WriteFile(coreFileIn(folder), core, 0o644))
	assert.Equal(t, "Methodology preset: watchtower-flow is set, but it is not installed — run 'watchtower workbench resync 7'.",
		briefPresetMismatch(flow, folder, 7))
	assert.Empty(t, briefPresetMismatch(none, folder, 7))

	_, body := devpack.FlowSkill()
	require.NoError(t, os.MkdirAll(filepath.Dir(flowFileIn(folder)), 0o755))
	require.NoError(t, os.WriteFile(flowFileIn(folder), body, 0o644))
	assert.Empty(t, briefPresetMismatch(flow, folder, 7))
	assert.Equal(t, "Methodology preset: none is set, but watchtower-flow is still installed — run 'watchtower workbench resync 7'.",
		briefPresetMismatch(none, folder, 7))

	// An owner-edited preset counts as installed: resync keeps it, so the
	// line would never clear. With none it is the owner's file, not ours.
	require.NoError(t, os.WriteFile(flowFileIn(folder), append(body, []byte("\nMy own step.\n")...), 0o644))
	assert.Empty(t, briefPresetMismatch(flow, folder, 7))
	assert.Empty(t, briefPresetMismatch(none, folder, 7))
}
