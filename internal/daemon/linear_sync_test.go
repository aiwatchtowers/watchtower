package daemon

import (
	"context"
	"fmt"
	"log"
	"os"
	"testing"
	"time"

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
	// #601: the revoked account's revoked_at is stamped for the purge
	// scheduler (PURGE-01).
	var revokedAt string
	require.NoError(t, database.QueryRow(`SELECT revoked_at FROM linear_accounts WHERE id = ?`, a1).Scan(&revokedAt))
	assert.NotEmpty(t, revokedAt, "a revoked account records when it turned revoked")
}

// A clean Linear pass stamps access_ok_at and never writes status (#601;
// LINEAR-03's "a nil error never writes a blanket ok" still holds).
func TestPhaseLinearSync_CleanPassStampsAccessOnly(t *testing.T) {
	d, database := newLinearTestDaemon(t)
	a1, err := database.CreateLinearAccount("")
	require.NoError(t, err)
	_, err = database.Exec(`UPDATE linear_accounts SET status = 'error', error = 'old', access_ok_at = '' WHERE id = ?`, a1)
	require.NoError(t, err)
	ran := 0
	d.linearSyncers = []linearAccountSyncer{fakeLinearSyncer{id: a1, n: 1, ran: &ran}}
	d.phaseLinearSync(context.Background())
	var status, okAt string
	require.NoError(t, database.QueryRow(`SELECT status, access_ok_at FROM linear_accounts WHERE id = ?`, a1).Scan(&status, &okAt))
	assert.Equal(t, "error", status)
	assert.NotEmpty(t, okAt)
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

// A clean Linear pass reflects Linear issue statuses onto their targets; a
// pass where every account failed leaves them alone.
func TestPhaseLinearSync_SyncsLinearTargets(t *testing.T) {
	d, database := newLinearTestDaemon(t)
	a1, err := database.CreateLinearAccount("")
	require.NoError(t, err)
	require.NoError(t, database.UpsertLinearIssue(db.LinearIssue{AccountID: a1, ID: "l-1", Key: "ENG-1",
		Title: "Ship", StatusCategory: "done", UpdatedAt: "2026-10-03T00:00:00.000Z"}))
	issues, err := database.ListTrackerIssues(db.TrackerIssueFilter{Tracker: db.TrackerLinear, Key: "ENG-1"})
	require.NoError(t, err)
	require.Len(t, issues, 1)
	target, err := database.CreateTargetFromTrackerIssue(issues[0])
	require.NoError(t, err)

	ran := 0
	d.linearSyncers = []linearAccountSyncer{fakeLinearSyncer{id: a1, err: linear.ErrRateLimited, ran: &ran}}
	d.phaseLinearSync(context.Background())
	got, err := database.GetTargetByID(target.ID)
	require.NoError(t, err)
	assert.Equal(t, "todo", got.Status, "no clean pass: targets untouched")

	d.lastLinear = time.Time{}
	d.linearSyncers = []linearAccountSyncer{fakeLinearSyncer{id: a1, ran: &ran}}
	d.phaseLinearSync(context.Background())
	got, err = database.GetTargetByID(target.ID)
	require.NoError(t, err)
	assert.Equal(t, "done", got.Status)
}
