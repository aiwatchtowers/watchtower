package db

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestCountOutsideTouch_Upserts(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	sid := newTestSession(t, d, wb)
	const root = "/tmp/code/hub"

	for want := 1; want <= 3; want++ {
		n, nudged, quiet, err := d.CountOutsideTouch(ctx, sid, root)
		require.NoError(t, err)
		assert.Equal(t, want, n)
		assert.False(t, nudged)
		assert.False(t, quiet)
	}
	n, _, _, err := d.CountOutsideTouch(ctx, sid, "/tmp/code/site")
	require.NoError(t, err)
	assert.Equal(t, 1, n, "each repo root counts apart")

	require.NoError(t, d.MarkOutsideNudged(ctx, sid, root))
	require.NoError(t, d.QuietOutsideRoot(ctx, sid, root))
	n, nudged, quiet, err := d.CountOutsideTouch(ctx, sid, root)
	require.NoError(t, err)
	assert.Equal(t, 4, n)
	assert.True(t, nudged)
	assert.True(t, quiet)

	require.NoError(t, d.QuietOutsideRoot(ctx, sid, "/tmp/code/never-counted"))
	_, _, quiet, err = d.CountOutsideTouch(ctx, sid, "/tmp/code/never-counted")
	require.NoError(t, err)
	assert.True(t, quiet, "Not Now before any count still quiets the root")

	_, err = d.Exec(`DELETE FROM terminal_sessions WHERE id = ?`, sid)
	require.NoError(t, err)
	var rows int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM session_outside_touches`).Scan(&rows))
	assert.Zero(t, rows, "the rows go with the session")
}
