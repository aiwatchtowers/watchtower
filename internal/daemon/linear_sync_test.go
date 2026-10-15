package daemon

import (
	"context"
	"fmt"
	"log"
	"os"
	"testing"

	"watchtower/internal/db"
	"watchtower/internal/linear"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

type fakeLinearSyncer struct {
	id  int64
	err error
	n   int
	ran *int
}

func (f fakeLinearSyncer) Sync(context.Context) (int, error) { *f.ran++; return f.n, f.err }
func (f fakeLinearSyncer) AccountID() int64                  { return f.id }

func newLinearTestDaemon(t *testing.T) (*Daemon, *db.DB) {
	t.Helper()
	orch, cfg, _ := testDaemonWithTempHome(t)
	database := db.OpenTestDB(t)
	d := newDaemon(orch, cfg)
	d.SetLogger(log.New(os.Stderr, "[test-linear] ", 0))
	d.SetDB(database)
	return d, database
}

func TestLinear03_RevokedMarksAccount(t *testing.T) {
	d, database := newLinearTestDaemon(t)
	a1, err := database.CreateLinearAccount("")
	require.NoError(t, err)
	a2, err := database.CreateLinearAccount("")
	require.NoError(t, err)
	ran := 0
	d.linearSyncers = []linearAccountSyncer{
		fakeLinearSyncer{id: a1, err: fmt.Errorf("refresh: %w", linear.ErrAuthRevoked), ran: &ran},
		fakeLinearSyncer{id: a2, n: 3, ran: &ran},
	}
	d.phaseLinearSync(context.Background())
	assert.Equal(t, 2, ran)
	acc, err := database.GetLinearAccount(a1)
	require.NoError(t, err)
	assert.Equal(t, "revoked", acc.Status)
	acc2, err := database.GetLinearAccount(a2)
	require.NoError(t, err)
	assert.Equal(t, "ok", acc2.Status)
}

func TestPhaseLinearSync_OtherErrorLeavesState(t *testing.T) {
	d, database := newLinearTestDaemon(t)
	a1, err := database.CreateLinearAccount("")
	require.NoError(t, err)
	ran := 0
	d.linearSyncers = []linearAccountSyncer{fakeLinearSyncer{id: a1, err: linear.ErrRateLimited, ran: &ran}}
	d.phaseLinearSync(context.Background())
	acc, err := database.GetLinearAccount(a1)
	require.NoError(t, err)
	assert.Equal(t, "ok", acc.Status)
}

func TestPhaseLinearSync_IntervalGate(t *testing.T) {
	d, database := newLinearTestDaemon(t)
	a1, err := database.CreateLinearAccount("")
	require.NoError(t, err)
	ran := 0
	d.linearSyncers = []linearAccountSyncer{fakeLinearSyncer{id: a1, ran: &ran}}
	d.phaseLinearSync(context.Background())
	d.phaseLinearSync(context.Background())
	assert.Equal(t, 1, ran)
}

// A cancelled context is daemon shutdown: even when the syncer's error wraps
// ErrAuthRevoked (a request cut off mid-refresh), the account is not marked
// revoked.
func TestLinear03_CancelledContextLeavesAuthState(t *testing.T) {
	d, database := newLinearTestDaemon(t)
	a1, err := database.CreateLinearAccount("")
	require.NoError(t, err)
	ran := 0
	d.linearSyncers = []linearAccountSyncer{
		fakeLinearSyncer{id: a1, err: fmt.Errorf("refresh: %w", linear.ErrAuthRevoked), ran: &ran},
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	d.phaseLinearSync(ctx)
	assert.Equal(t, 1, ran)
	acc, err := database.GetLinearAccount(a1)
	require.NoError(t, err)
	assert.Equal(t, "ok", acc.Status)
}
