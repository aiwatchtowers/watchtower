package daemon

import (
	"context"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"testing"
	"time"

	"github.com/slack-go/slack"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/linear"
	"watchtower/internal/reactioncmd"
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

// PURGE-01 (review #601): a revoked Jira or Linear account whose next pass
// is clean ends cancelled. Neither pass writes ok (LINEAR-03); the stamped
// access_ok_at, newer than revoked_at, is what cancels the row.
func TestPurge01_CleanPassAfterRevocationCancels(t *testing.T) {
	revokedAt := time.Now().Add(-time.Hour).UTC().Format(time.RFC3339)
	due := time.Now().Add(-time.Minute).UTC().Format(time.RFC3339) // already due

	t.Run("jira", func(t *testing.T) {
		d, database, _ := newJiraTestDaemon(t)
		setPurge(d, true)
		id, err := database.CreateJiraAccount(db.JiraAccount{CloudID: "c1"})
		require.NoError(t, err)
		_, err = database.Exec(`UPDATE jira_accounts SET status = 'revoked', revoked_at = ?, access_ok_at = '' WHERE id = ?`, revokedAt, id)
		require.NoError(t, err)
		_, err = database.ScheduleAccountPurge("jira", id, "revoked", due)
		require.NoError(t, err)

		d.jiraSyncers = []jiraAccountSyncer{&stubJiraSyncer{accountID: id}}
		d.phaseJiraSync(context.Background())
		d.phaseAccountPurge(context.Background())

		all, err := database.ListAccountPurges(false)
		require.NoError(t, err)
		require.Len(t, all, 1)
		assert.Equal(t, "cancelled", all[0].State, "a clean pass after the revocation cancels the purge")
		open, err := database.ListAccountPurges(true)
		require.NoError(t, err)
		assert.Empty(t, open, "and schedules no new one")
	})

	t.Run("linear", func(t *testing.T) {
		d, database := newLinearTestDaemon(t)
		setPurge(d, true)
		id := seedRevokedLinear(t, database, time.Hour)
		_, err := database.Exec(`UPDATE linear_accounts SET access_ok_at = '' WHERE id = ?`, id)
		require.NoError(t, err)
		_, err = database.ScheduleAccountPurge("linear", id, "revoked", due)
		require.NoError(t, err)

		ran := 0
		d.linearSyncers = []linearAccountSyncer{fakeLinearSyncer{id: id, ran: &ran}}
		d.phaseLinearSync(context.Background())
		d.phaseAccountPurge(context.Background())

		all, err := database.ListAccountPurges(false)
		require.NoError(t, err)
		require.Len(t, all, 1)
		assert.Equal(t, "cancelled", all[0].State)
		assert.Equal(t, 3, linearRowCount(t, database, id), "nothing deleted")
	})
}

// PURGE-01 (review #601): a Mac back after a long absence gets no false
// lease notice. The start-of-cycle pass schedules no lease; the pass after
// the syncs sees this cycle's fresh access and schedules nothing either. A
// source that stays unreached is scheduled by that later pass.
func TestPurge01_NoLeaseBeforeTheCyclesSyncs(t *testing.T) {
	d, database := newLinearTestDaemon(t)
	setPurge(d, true)
	reached, err := database.CreateLinearAccount("")
	require.NoError(t, err)
	stale := time.Now().Add(-29 * 24 * time.Hour).UTC().Format(time.RFC3339)
	_, err = database.Exec(`UPDATE linear_accounts SET access_ok_at = ?`, stale)
	require.NoError(t, err)

	d.phaseAccountPurge(context.Background())
	open, err := database.ListAccountPurges(true)
	require.NoError(t, err)
	assert.Empty(t, open, "no lease before the cycle's syncs")

	ran := 0
	d.linearSyncers = []linearAccountSyncer{fakeLinearSyncer{id: reached, ran: &ran}}
	d.phaseLinearSync(context.Background())
	d.phaseAccountPurgeLeases(context.Background())
	open, err = database.ListAccountPurges(true)
	require.NoError(t, err)
	assert.Empty(t, open, "the sync proved access: no lease")

	// Unreached: the later pass schedules it.
	_, err = database.Exec(`UPDATE linear_accounts SET access_ok_at = ?`, stale)
	require.NoError(t, err)
	d.phaseAccountPurgeLeases(context.Background())
	open, err = database.ListAccountPurges(true)
	require.NoError(t, err)
	require.Len(t, open, 1)
	assert.Equal(t, "lease", open[0].Reason)
}

// The lease pass runs after every source sync of runSync (static, the
// TestDaemon_RunSync_PollsReactionsBeforeAIPipelines precedent), and Run
// refreshes the purge hold before the startup calendar sync.
func TestDaemon_PurgePhaseOrder(t *testing.T) {
	file, err := parser.ParseFile(token.NewFileSet(), "daemon.go", nil, 0)
	require.NoError(t, err)

	run := topLevelCallOrder(daemonFunc(t, file, "Run", true))
	hold, ok := run["refreshPurgeHold"]
	require.True(t, ok, "Run must refresh the purge hold")
	assert.Less(t, hold, run["startupCalendarSync"], "the hold must be known before the startup calendar sync")

	sync := map[string]int{}
	fn := daemonFunc(t, file, "runSync", true)
	for i, stmt := range fn.Body.List {
		ast.Inspect(stmt, func(n ast.Node) bool {
			if call, ok := n.(*ast.CallExpr); ok {
				if sel, ok := call.Fun.(*ast.SelectorExpr); ok {
					if _, seen := sync[sel.Sel.Name]; !seen {
						sync[sel.Sel.Name] = i
					}
				}
			}
			return true
		})
	}
	leases, ok := sync["phaseAccountPurgeLeases"]
	require.True(t, ok, "runSync must schedule leases")
	for _, phase := range []string{"phaseSlackSync", "phaseCalendarSync", "phaseGmailSync", "phaseJiraSync", "phaseLinearSync", "phaseExternalSync"} {
		at, ok := sync[phase]
		require.True(t, ok, phase)
		assert.Greater(t, leases, at, "leases are scheduled after %s", phase)
	}
	assert.Less(t, sync["phaseAccountPurge"], sync["phaseSlackSync"], "due purges still run first")
}

// countingReactionLister counts reactions.list calls.
type countingReactionLister struct{ calls *int }

func (l countingReactionLister) ListUserReactions(context.Context, string) ([]slack.ReactedItem, error) {
	*l.calls++
	return nil, nil
}

// The reaction poll skips an account being purged (review #601): a running
// purge must not see the account's reactions written back.
func TestPhaseReactionCommands_SkipsPurgeHeldAccount(t *testing.T) {
	cfg := &config.Config{ReactionCommands: config.ReactionCommandsConfig{Enabled: true}}
	d, _ := newReactionTestDaemon(t, cfg)
	_, err := d.db.Exec(`INSERT INTO slack_accounts (id, team_id, team_name, current_user_id) VALUES (2, 'T2', 'other', '2:UOWNER')`)
	require.NoError(t, err)
	held, other := 0, 0
	accountsFn := func(context.Context) ([]reactioncmd.Account, error) {
		return []reactioncmd.Account{
			{AccountID: 1, OwnerID: "1:UOWNER", Lister: countingReactionLister{&held}},
			{AccountID: 2, OwnerID: "2:UOWNER", Lister: countingReactionLister{&other}},
		}, nil
	}
	d.SetReactionCommandsPipeline(reactioncmd.New(d.db, cfg, nil, nil, accountsFn, nil))
	_, err = d.db.Exec(`INSERT INTO account_purges (source, account_id, reason, due_at, state) VALUES ('slack', 1, 'revoked', '2026-01-01T00:00:00Z', 'running')`)
	require.NoError(t, err)
	d.refreshPurgeHold()

	d.phaseReactionCommands(context.Background())

	assert.Zero(t, held, "a purge-held account is not polled")
	assert.Positive(t, other, "another account still is")
}

// PURGE-02 (review #601): a failed purge releases its account — the sync
// phases run it again — while a running one holds it.
func TestRefreshPurgeHold_FailedReleases(t *testing.T) {
	d, database := newLinearTestDaemon(t)
	id := seedRevokedLinear(t, database, time.Hour)
	_, err := database.Exec(`INSERT INTO account_purges (source, account_id, reason, due_at, state) VALUES ('linear', ?, 'revoked', '2026-01-01T00:00:00Z', 'running')`, id)
	require.NoError(t, err)
	d.refreshPurgeHold()
	assert.True(t, d.purgeHeld("linear", id), "a running purge holds its account")
	_, err = database.Exec(`UPDATE account_purges SET state = 'failed'`)
	require.NoError(t, err)
	d.refreshPurgeHold()
	assert.False(t, d.purgeHeld("linear", id), "a failed purge releases it")
}
