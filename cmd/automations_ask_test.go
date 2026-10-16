package cmd

import (
	"database/sql"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/db"
)

// Ruling R-P5-6: deleting a workbench automation withdraws its runs' open
// asks (a run that ended before the executor's sweep saw it), so no open ask
// of no run and no session is left behind.
func TestAutomationsCLI_DeleteWithdrawsOpenAsks(t *testing.T) {
	c := newAutoCLI(t)
	folder, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	wbID, err := c.d.CreateWorkbench("acme", folder)
	require.NoError(t, err)
	src := writeRecipe(t, t.TempDir(), "draft", autoCLIRecipeText(`return 1`))
	saved := runAutomationsJSON(t, "save", "--file", src, "--path", filepath.Join(automations.WorkbenchDir(folder), "wb.md"))
	a, err := c.d.GetAutomation(int64(saved["automation_id"].(float64)))
	require.NoError(t, err)

	now := time.Now().UTC()
	runID, _, err := c.d.EnqueueAutomationRun(db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerManual, Now: now})
	require.NoError(t, err)
	ok, err := c.d.ClaimAutomationRun(runID, "h", "snapshot", 50000, 5, now)
	require.NoError(t, err)
	require.True(t, ok)
	var askID int64
	require.NoError(t, c.d.WithTx(func(tx *sql.Tx) error {
		askID, _, err = c.d.InsertOwnerAsk(tx, db.OwnerAsk{WorkbenchID: wbID, Kind: "question", Title: "Ship it?",
			AutomationRunID: sql.NullInt64{Int64: runID, Valid: true}})
		return err
	}))
	ok, err = c.d.CancelAutomationRun(runID, now)
	require.NoError(t, err)
	require.True(t, ok)

	out, err := runAutomations(t, "delete", idArg(a.ID))
	require.NoError(t, err, out)
	ask, err := c.d.GetOwnerAsk(wbID, askID)
	require.NoError(t, err)
	assert.Equal(t, []string{"withdrawn", db.WithdrawnByAgent}, []string{ask.Status, ask.WithdrawnReason})
	assert.False(t, ask.AutomationRunID.Valid, "the run went with the automation")
}
