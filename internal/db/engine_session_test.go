package db

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

// TestEngine_CancelledTxKeepsConnection pins that a transaction rolled back
// by its cancelled context keeps the pool's connection (the engine is a
// driver.SessionResetter and driver.Validator, as modernc's was): database/sql
// would otherwise discard it, and an in-memory database with it — the
// daemon test that cancels its run mid-transaction then found no tables.
func TestEngine_CancelledTxKeepsConnection(t *testing.T) {
	d, err := Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	_, err = d.Exec(`CREATE TABLE kept (x INTEGER)`)
	require.NoError(t, err)

	ctx, cancel := context.WithCancel(context.Background())
	tx, err := d.BeginTx(ctx, nil)
	require.NoError(t, err)
	_, err = tx.Exec(`INSERT INTO kept VALUES (1)`)
	require.NoError(t, err)
	cancel()
	require.Eventually(t, func() bool {
		return tx.Commit() != nil
	}, time.Second, 10*time.Millisecond, "the cancelled transaction must be done")

	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM kept`).Scan(&n))
	require.Equal(t, 0, n, "the cancelled insert rolled back")
}
