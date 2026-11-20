package db

import (
	"context"
	"database/sql"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestDeclineFolder_NeverForThisFolder(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	other := newTestWorkbench(t, d)

	declined, err := d.FolderDeclined(ctx, d, wb, "/tmp/code/hub")
	require.NoError(t, err)
	assert.False(t, declined)

	require.NoError(t, d.DeclineFolder(ctx, wb, "/tmp/code/hub"))
	require.NoError(t, d.DeclineFolder(ctx, wb, "/TMP/code/hub"), "declining again is no error")
	declined, err = d.FolderDeclined(ctx, d, wb, "/tmp/CODE/hub")
	require.NoError(t, err)
	assert.True(t, declined, "compared NOCASE")
	require.NoError(t, d.WithTx(func(tx *sql.Tx) error {
		declined, err = d.FolderDeclined(ctx, tx, other, "/tmp/code/hub")
		return err
	}))
	assert.False(t, declined, "per workbench")

	require.NoError(t, d.DeleteWorkbench(wb))
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM workbench_folder_declines`).Scan(&n))
	assert.Zero(t, n)
}
