package cmd

import (
	"errors"
	"os"
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/devpack"
)

// Spec 2026-11-03 §4.3: a resync renders the owner's overlay rows into the
// folder's pack skills, and the copy is not drift.
func TestWorkbenchResync_RendersPackOverlays(t *testing.T) {
	database := writeActionsConfig(t)
	useFakeWorkbenchClaude(t)
	folder := resyncFolder(t)
	pid, err := database.CreateWorkbench("acme", folder)
	require.NoError(t, err)
	_, err = database.EditSkillPackOverlays(devpack.WorkbenchSkillName, nil,
		[]db.SkillPackOverlay{{Text: "Be brief."}}, time.Date(2026, 11, 10, 9, 0, 0, 0, time.UTC))
	require.NoError(t, err)

	out, _, err := runResync(t, strconv.FormatInt(pid, 10), "--json")
	require.NoError(t, err, out)
	_, body := devpack.WorkbenchSkill()
	core, ok := devpack.PackSkill(devpack.WorkbenchSkillName)
	require.True(t, ok)
	require.Equal(t, string(body), core.Content)
	got, err := os.ReadFile(coreFileIn(folder))
	require.NoError(t, err)
	assert.Equal(t, devpack.Render(core, []string{"Be brief."}).Content, string(got))

	o, err := workbenchInstallOptions(&db.Workbench{ID: pid, FolderPath: folder})
	require.NoError(t, err)
	withInstallOverlays(&o)
	st, err := devpack.StatusWorkbench(t.Context(), o)
	require.NoError(t, err)
	assert.Equal(t, devpack.StateUnchanged, st.Skill.State)
}

// An unreadable overlay table keeps an existing rendered copy as it is.
func TestWorkbenchResync_OverlaysUnreadKeepsTheCopy(t *testing.T) {
	database := writeActionsConfig(t)
	useFakeWorkbenchClaude(t)
	folder := resyncFolder(t)
	pid, err := database.CreateWorkbench("acme", folder)
	require.NoError(t, err)
	_, err = database.EditSkillPackOverlays(devpack.WorkbenchSkillName, nil,
		[]db.SkillPackOverlay{{Text: "Be brief."}}, time.Date(2026, 11, 10, 9, 0, 0, 0, time.UTC))
	require.NoError(t, err)
	_, _, err = runResync(t, strconv.FormatInt(pid, 10), "--json")
	require.NoError(t, err)
	before, err := os.ReadFile(coreFileIn(folder))
	require.NoError(t, err)

	prev := installOverlays
	installOverlays = func() (devpack.Overlays, error) { return nil, errors.New("database is locked") }
	t.Cleanup(func() { installOverlays = prev })
	_, _, err = runResync(t, strconv.FormatInt(pid, 10), "--json")
	require.NoError(t, err)
	after, err := os.ReadFile(coreFileIn(folder))
	require.NoError(t, err)
	assert.Equal(t, string(before), string(after))
}
