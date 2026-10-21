package daemon

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/linear"
)

func setPurge(d *Daemon, on bool) { d.config.Privacy.PurgeRevokedData = &on }

// seedRevokedLinear creates a Linear account revoked `ago` with one team,
// issue and comment.
func seedRevokedLinear(t *testing.T, database *db.DB, ago time.Duration) int64 {
	t.Helper()
	id, err := database.CreateLinearAccount("")
	require.NoError(t, err)
	revokedAt := time.Now().Add(-ago).UTC().Format(time.RFC3339)
	for _, q := range []string{
		fmt.Sprintf(`UPDATE linear_accounts SET status = 'revoked', error = 'gone', revoked_at = '%s' WHERE id = %d`, revokedAt, id),
		fmt.Sprintf(`INSERT INTO linear_teams (account_id, id, key, name) VALUES (%d, 't1', 'ENG', 'Eng')`, id),
		fmt.Sprintf(`INSERT INTO linear_issues (account_id, id, key, team_id, title, created_at, updated_at, synced_at) VALUES (%d, 'i1', 'ENG-1', 't1', 'x', '2026-01-01', '2026-01-01', '2026-01-01')`, id),
		fmt.Sprintf(`INSERT INTO linear_comments (account_id, id, issue_id, issue_key, created_at, updated_at, synced_at) VALUES (%d, 'c1', 'i1', 'ENG-1', '2026-01-01', '2026-01-01', '2026-01-01')`, id),
	} {
		_, err := database.Exec(q)
		require.NoError(t, err, q)
	}
	return id
}

func linearRowCount(t *testing.T, database *db.DB, id int64) int {
	t.Helper()
	var n int
	require.NoError(t, database.QueryRow(`SELECT
		(SELECT COUNT(*) FROM linear_teams WHERE account_id = ?) +
		(SELECT COUNT(*) FROM linear_issues WHERE account_id = ?) +
		(SELECT COUNT(*) FROM linear_comments WHERE account_id = ?)`, id, id, id).Scan(&n))
	return n
}

// LINEAR-03 (amended, #601): with the purge off, a revoked account keeps
// every linear_* row however long it has been revoked, and nothing is
// scheduled.
func TestLinear03_PurgeOffKeepsData(t *testing.T) {
	d, database := newLinearTestDaemon(t)
	setPurge(d, false)
	id := seedRevokedLinear(t, database, 10*24*time.Hour)

	d.phaseAccountPurge(context.Background())

	assert.Equal(t, 3, linearRowCount(t, database, id), "purge off: data is kept")
	rows, err := database.ListAccountPurges(false)
	require.NoError(t, err)
	assert.Empty(t, rows, "purge off: nothing is scheduled")
	acc, err := database.GetLinearAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "revoked", acc.Status)
}

// LINEAR-03 (amended, #601): a scheduled purge of a revoked account is
// cancelled by a login, and the data stays.
func TestLinear03_PurgeScheduledCancelledByReconnect(t *testing.T) {
	d, database := newLinearTestDaemon(t)
	setPurge(d, true)
	id := seedRevokedLinear(t, database, time.Hour)

	d.phaseAccountPurge(context.Background())
	open, err := database.ListAccountPurges(true)
	require.NoError(t, err)
	require.Len(t, open, 1, "a revoked account is scheduled at once, for the notice")
	assert.Equal(t, "scheduled", open[0].State)
	assert.Equal(t, 3, linearRowCount(t, database, id), "within the grace period nothing is deleted")

	require.NoError(t, database.SetLinearAccountAuthState(id, "ok", "")) // the login
	d.phaseAccountPurge(context.Background())

	open, err = database.ListAccountPurges(true)
	require.NoError(t, err)
	assert.Empty(t, open)
	all, err := database.ListAccountPurges(false)
	require.NoError(t, err)
	require.Len(t, all, 1)
	assert.Equal(t, "cancelled", all[0].State)
	assert.Equal(t, 3, linearRowCount(t, database, id))
}

// With the purge on, a due revoked account is purged and its syncer skipped
// on the same cycle; another account syncs as usual.
func TestPhaseAccountPurge_DueRevokedPurgedAndSyncerSkipped(t *testing.T) {
	d, database := newLinearTestDaemon(t)
	setPurge(d, true)
	id := seedRevokedLinear(t, database, 10*24*time.Hour)
	other, err := database.CreateLinearAccount("")
	require.NoError(t, err)
	// Scheduled earlier and now due.
	_, err = database.ScheduleAccountPurge("linear", id, "revoked", time.Now().Add(-time.Minute).UTC().Format(time.RFC3339))
	require.NoError(t, err)

	purgedRan, otherRan := 0, 0
	d.linearSyncers = []linearAccountSyncer{
		fakeLinearSyncer{id: id, err: fmt.Errorf("refresh: %w", linear.ErrAuthRevoked), ran: &purgedRan},
		fakeLinearSyncer{id: other, ran: &otherRan},
	}
	d.phaseAccountPurge(context.Background())
	d.phaseLinearSync(context.Background())

	assert.Equal(t, 0, linearRowCount(t, database, id), "the purged account's rows are gone")
	acc, err := database.GetLinearAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "purged", acc.Status, "the revoked write of a skipped syncer cannot reach the row")
	assert.Equal(t, 0, purgedRan, "a purged account's syncer is skipped")
	assert.Equal(t, 1, otherRan)
	all, err := database.ListAccountPurges(false)
	require.NoError(t, err)
	require.Len(t, all, 1)
	assert.Equal(t, "done", all[0].State)
	assert.Equal(t, int64(3), all[0].RowsDeleted)
}

// Turning the purge off cancels a scheduled row and writes nothing else.
func TestPhaseAccountPurge_OffCancelsScheduled(t *testing.T) {
	d, database := newLinearTestDaemon(t)
	setPurge(d, true)
	id := seedRevokedLinear(t, database, time.Hour)
	d.phaseAccountPurge(context.Background())
	setPurge(d, false)
	d.phaseAccountPurge(context.Background())

	all, err := database.ListAccountPurges(false)
	require.NoError(t, err)
	require.Len(t, all, 1)
	assert.Equal(t, "cancelled", all[0].State)
	assert.Equal(t, 3, linearRowCount(t, database, id))
}
