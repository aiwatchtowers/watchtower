package kb

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// lockProbe wraps a real source; before every Build it writes through a
// SECOND connection with no busy wait, recording any failure. A render that
// runs while the indexer holds the write lock makes that write fail with
// SQLITE_BUSY.
type lockProbe struct {
	Source
	other  *sql.DB
	errs   *[]error
	builds *int
}

func (p lockProbe) Build(ctx context.Context, q Queryer, key string) (*Doc, error) {
	*p.builds++
	if _, err := p.other.ExecContext(ctx, `INSERT INTO lock_probe (k) VALUES (?)`, key); err != nil {
		*p.errs = append(*p.errs, err)
	}
	return p.Source.Build(ctx, q, key)
}

// Backlog 2026-09-30 (approving a chat proposal fails with SQLITE_BUSY): the
// indexer renders documents outside its write transaction, so another
// process's write — an owner's Approve — never waits on a batch of renders.
// Before the fix, every Build after a batch's first write ran under the
// write lock and this probe's writes failed.
func TestRun_RendersOutsideTheWriteLock(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "watchtower.db")
	d, err := db.Open(path)
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	seedThreads(t, d, 5)
	exec(t, d, `CREATE TABLE lock_probe (k TEXT)`)

	other, err := sql.Open("sqlite", path)
	require.NoError(t, err)
	t.Cleanup(func() { _ = other.Close() })
	other.SetMaxOpenConns(1)
	_, err = other.Exec(`PRAGMA busy_timeout=0`)
	require.NoError(t, err)

	var errs []error
	builds := 0
	r := testRunner(lockProbe{Source: newSlackSource(), other: other, errs: &errs, builds: &builds})
	_, err = r.run(ctx, d, Options{Now: testNow()})
	require.NoError(t, err)
	require.GreaterOrEqual(t, builds, 5, "every thread was rendered")
	require.Empty(t, errs, "a concurrent writer never hit the indexer's write lock")
}
