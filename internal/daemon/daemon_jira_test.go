package daemon

import (
	"context"
	"fmt"
	"log"
	"os"
	"testing"

	"watchtower/internal/db"
	"watchtower/internal/jira"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// newJiraTestDaemon builds a Daemon with a test DB, suitable for calling
// phaseJiraSync directly (the newCleanupTestDaemon shape).
func newJiraTestDaemon(t *testing.T) (*Daemon, *db.DB, string) {
	t.Helper()
	orch, cfg, wsDir := testDaemonWithTempHome(t)

	database, err := db.Open(wsDir + "/watchtower.db")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })

	d := newDaemon(orch, cfg)
	d.SetLogger(log.New(os.Stderr, "[test-jira-fanout] ", 0))
	d.SetDB(database)
	return d, database, wsDir
}

// jiraSyncerFor builds a per-account syncer the way wireJiraSyncers does, minus
// the board analyzer. With no token file on disk the client cannot mint an
// access token, so a syncer that reaches the API fails locally — no network
// involved.
func jiraSyncerFor(t *testing.T, database *db.DB, wsDir string, accountID int64) *jira.Syncer {
	t.Helper()
	store := jira.NewTokenStore(wsDir, accountID)
	client := jira.NewClient(fmt.Sprintf("cloud-%d", accountID), jira.JiraOAuthConfig{}, store)
	syncer := jira.NewSyncer(client, database, jira.NewUserMapper(client, database), nil, accountID)
	syncer.SetLogger(log.New(os.Stderr, "[test-jira-syncer] ", 0))
	return syncer
}

// seedJiraAccountWithBoard mints an account with one selected board, so its
// syncer actually reaches the (unreachable) API during a phase pass.
func seedJiraAccountWithBoard(t *testing.T, database *db.DB, cloudID, projectKey string) int64 {
	t.Helper()
	id, err := database.CreateJiraAccount(db.JiraAccount{CloudID: cloudID})
	require.NoError(t, err)
	require.NoError(t, database.UpsertJiraBoard(db.JiraBoard{
		AccountID: id, ID: 7, Name: "Board", ProjectKey: projectKey, IsSelected: true, SyncedAt: "now",
	}))
	return id
}

// TestPhaseJiraSyncFanOutRunsEveryAccount is the Jira analog of
// TestPhaseSlackSyncAggregatesAcrossAccounts: one phase pass runs EVERY
// connected account's syncer, and each account's sync state lands on its own
// rows. Both accounts here use the same project key, so the per-account
// jira_sync_state rows also pin the composite-PK scoping (migration 00049) —
// pre-00049 the second account's watermark row would have clobbered the first.
func TestPhaseJiraSyncFanOutRunsEveryAccount(t *testing.T) {
	d, database, wsDir := newJiraTestDaemon(t)

	acct1 := seedJiraAccountWithBoard(t, database, "c1", "OPS")
	acct2 := seedJiraAccountWithBoard(t, database, "c2", "OPS")

	d.SetJiraSyncers([]*jira.Syncer{
		jiraSyncerFor(t, database, wsDir, acct1),
		jiraSyncerFor(t, database, wsDir, acct2),
	})

	d.phaseJiraSync(context.Background())

	// Each account attempted its own project — proving the loop covered both
	// and that their state is kept apart.
	for _, acct := range []int64{acct1, acct2} {
		state, err := database.GetJiraSyncState(acct, "OPS")
		require.NoError(t, err)
		require.NotNil(t, state, "account %d never attempted its project", acct)
		assert.Equal(t, acct, state.AccountID)
	}
}

// TestPhaseJiraSyncNeverPaintsAccountGreen is the false-green guard: Sync()
// keeps going across projects and returns nil even when every project failed,
// so a pass must never write "ok" back over an account already flagged
// error/revoked — that would hide the Re-login button in Settings while the
// account syncs nothing.
func TestPhaseJiraSyncNeverPaintsAccountGreen(t *testing.T) {
	d, database, wsDir := newJiraTestDaemon(t)

	// No selected boards → Sync() is a clean no-op returning nil.
	acct, err := database.CreateJiraAccount(db.JiraAccount{CloudID: "c1"})
	require.NoError(t, err)
	require.NoError(t, database.SetJiraAccountAuthState(acct, "revoked", "token revoked"))

	d.SetJiraSyncers([]*jira.Syncer{jiraSyncerFor(t, database, wsDir, acct)})
	d.phaseJiraSync(context.Background())

	got, err := database.GetJiraAccount(acct)
	require.NoError(t, err)
	assert.Equal(t, "revoked", got.Status, "a nil Sync() error must not clear a recorded auth failure")
	assert.Equal(t, "token revoked", got.Error)
}

// TestPhaseJiraSyncEmptySlice is the degenerate case: no connected accounts →
// phaseJiraSync returns immediately, matching the retired d.jiraSyncer == nil
// early-return (the TestPhaseSlackSyncEmptySlice precedent).
func TestPhaseJiraSyncEmptySlice(t *testing.T) {
	d := newQuietDaemon(t)
	d.SetJiraSyncers(nil)
	d.phaseJiraSync(context.Background())
	assert.True(t, d.lastJira.IsZero(), "an empty fan-out must not stamp the interval clock")
}

// TestPhaseJiraSyncRespectsInterval pins the throttle: a pass that just ran
// does not re-run before jira.sync_interval_mins elapses.
func TestPhaseJiraSyncRespectsInterval(t *testing.T) {
	d, database, wsDir := newJiraTestDaemon(t)
	d.config.Jira.SyncIntervalMins = 60

	acct := seedJiraAccountWithBoard(t, database, "c1", "OPS")
	d.SetJiraSyncers([]*jira.Syncer{jiraSyncerFor(t, database, wsDir, acct)})

	d.phaseJiraSync(context.Background())
	require.False(t, d.lastJira.IsZero(), "the first pass must stamp the interval clock")

	// Wipe the evidence of the first pass; a throttled second pass must not
	// recreate it.
	_, err := database.Exec(`DELETE FROM jira_sync_state`)
	require.NoError(t, err)

	d.phaseJiraSync(context.Background())

	state, err := database.GetJiraSyncState(acct, "OPS")
	require.NoError(t, err)
	assert.Nil(t, state, "a throttled pass must not run the syncers again")
}
