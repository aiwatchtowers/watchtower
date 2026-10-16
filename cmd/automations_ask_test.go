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

// Ruling R-P5-6: deleting a workbench automation deletes its runs' asks —
// open (a run that ended before the executor's sweep saw it), answered and
// delivered — so none is left behind with no run, looking like an external
// terminal's ask that every session would see.
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
	var askIDs []int64
	for _, title := range []string{"Ship it?", "Answered", "Delivered"} {
		require.NoError(t, c.d.WithTx(func(tx *sql.Tx) error {
			id, _, err := c.d.InsertOwnerAsk(tx, db.OwnerAsk{WorkbenchID: wbID, Kind: "question", Title: title,
				AutomationRunID: sql.NullInt64{Int64: runID, Valid: true}})
			askIDs = append(askIDs, id)
			return err
		}))
	}
	_, err = c.d.Exec(`UPDATE owner_asks SET status = 'answered', answer = '{"note":"ok"}' WHERE id IN (?, ?)`, askIDs[1], askIDs[2])
	require.NoError(t, err)
	delivered, err := c.d.MarkOwnerAskDelivered(wbID, askIDs[2])
	require.NoError(t, err)
	require.True(t, delivered)
	ok, err = c.d.CancelAutomationRun(runID, now)
	require.NoError(t, err)
	require.True(t, ok)

	out, err := runAutomations(t, "delete", idArg(a.ID))
	require.NoError(t, err, out)
	for _, id := range askIDs {
		_, err := c.d.GetOwnerAsk(wbID, id)
		assert.ErrorIs(t, err, db.ErrAskNotFound, "ask %d went with the automation", id)
	}
}
