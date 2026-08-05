package daemon

import (
	"context"
	"errors"
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

// TestPhaseJiraSyncCancelledContextLeavesAuthStateUntouched pins the shutdown
// guard: a cancelled context means the daemon is stopping, not that the grant
// went bad. Persisting "context canceled" as the account's auth error would
// strand a red badge in Settings that nothing but a re-login could clear.
//
// Fails on the pre-fix code: without the ctx.Err() branch the account is
// stamped status='error' with a context-cancellation message.
func TestPhaseJiraSyncCancelledContextLeavesAuthStateUntouched(t *testing.T) {
	d, database, wsDir := newJiraTestDaemon(t)

	acct := seedJiraAccountWithBoard(t, database, "c1", "OPS")
	require.NoError(t, database.SetJiraAccountAuthState(acct, "ok", ""))
	d.SetJiraSyncers([]*jira.Syncer{jiraSyncerFor(t, database, wsDir, acct)})

	// Shutdown shape: the context is cancelled AND Sync fails, because the DB
	// is going away underneath it. Sync swallows per-project API errors, so a
	// failing boards read is what actually reaches the error branch — and
	// "sql: no such table" is exactly the kind of shutdown noise that must not
	// be persisted as this account's auth error.
	_, err := database.Exec(`DROP TABLE jira_boards`)
	require.NoError(t, err)

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	d.phaseJiraSync(ctx)

	got, err := database.GetJiraAccount(acct)
	require.NoError(t, err)
	assert.Equal(t, "ok", got.Status, "a daemon shutdown must not be recorded as an auth failure")
	assert.Empty(t, got.Error, "no cancellation message may leak into the account's auth error")
}

// TestPhaseJiraSyncGenericFailureLeavesAuthStateUntouched pins the other half
// of the auth-state rule: only a revoked grant is an auth problem. A broken
// local read, a rate limit or a dropped connection says nothing about the
// account's grant, and stamping it would strand a red badge in Settings that
// only a re-login could clear — the sticky-error ratchet, since nothing in a
// daemon pass ever writes "ok" back.
//
// The failure is forced by dropping jira_boards, which makes Sync's
// GetJiraSelectedBoards read fail — a deterministic, offline way to get a
// non-nil, non-revoked error out of the real Syncer.
//
// Fails on the pre-fix code: it stamped status='error' for EVERY sync error.
func TestPhaseJiraSyncGenericFailureLeavesAuthStateUntouched(t *testing.T) {
	d, database, wsDir := newJiraTestDaemon(t)

	acct := seedJiraAccountWithBoard(t, database, "c1", "OPS")
	require.NoError(t, database.SetJiraAccountAuthState(acct, "ok", ""))
	d.SetJiraSyncers([]*jira.Syncer{jiraSyncerFor(t, database, wsDir, acct)})

	_, err := database.Exec(`DROP TABLE jira_boards`)
	require.NoError(t, err)

	d.phaseJiraSync(context.Background())

	got, err := database.GetJiraAccount(acct)
	require.NoError(t, err)
	assert.Equal(t, "ok", got.Status, "a non-auth sync failure must not be recorded as an auth failure")
	assert.Empty(t, got.Error, "no transient sync error may leak into the account's auth error")
}

// stubJiraSyncer is a phaseJiraSync-shaped syncer with a scripted outcome. The
// real *jira.Syncer only produces jira.ErrAuthRevoked after a live 401 from
// Atlassian, so the branch that matters most here is unreachable offline
// without it.
type stubJiraSyncer struct {
	accountID int64
	issues    int
	err       error
	inTok     int
	outTok    int
	apiTok    int
}

func (s *stubJiraSyncer) Sync(context.Context) (int, error) { return s.issues, s.err }
func (s *stubJiraSyncer) AccountID() int64                  { return s.accountID }
func (s *stubJiraSyncer) BoardAnalyzerUsage() (int, int, int) {
	return s.inTok, s.outTok, s.apiTok
}

// revokedErr is shaped like the error client.do returns for a 401 that survives
// a token refresh.
func revokedErr() error {
	return fmt.Errorf("%w: GET /rest/api/3/search/jql returned 401 after token refresh", jira.ErrAuthRevoked)
}

// TestPhaseJiraSyncRecordsRevokedGrant is the converse of the two "leave it
// alone" guards: the one failure that IS the account's problem must reach its
// row, otherwise Settings shows a green account that syncs nothing and never
// offers Re-login.
//
// Fails on the pre-fix code: it stamped status='error', not 'revoked', so the
// Swift Re-login affordance (keyed on 'revoked') never appeared.
func TestPhaseJiraSyncRecordsRevokedGrant(t *testing.T) {
	d, database, _ := newJiraTestDaemon(t)

	acct, err := database.CreateJiraAccount(db.JiraAccount{CloudID: "c1"})
	require.NoError(t, err)
	require.NoError(t, database.SetJiraAccountAuthState(acct, "ok", ""))

	d.jiraSyncers = []jiraAccountSyncer{&stubJiraSyncer{accountID: acct, err: revokedErr()}}

	d.phaseJiraSync(context.Background())

	got, err := database.GetJiraAccount(acct)
	require.NoError(t, err)
	assert.Equal(t, "revoked", got.Status, "a revoked grant must reach the account row")
	assert.Contains(t, got.Error, "401", "the recorded error must describe the revoked grant")
}

// A cancelled context wins over the revoked branch: during shutdown an
// in-flight request can fail any way at all, and a re-login prompt raised by a
// daemon stop is a lie the owner cannot clear except by re-consenting.
func TestPhaseJiraSyncCancelledRevokedGrantLeavesAuthStateUntouched(t *testing.T) {
	d, database, _ := newJiraTestDaemon(t)

	acct, err := database.CreateJiraAccount(db.JiraAccount{CloudID: "c1"})
	require.NoError(t, err)
	require.NoError(t, database.SetJiraAccountAuthState(acct, "ok", ""))

	d.jiraSyncers = []jiraAccountSyncer{&stubJiraSyncer{accountID: acct, err: revokedErr()}}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	d.phaseJiraSync(ctx)

	got, err := database.GetJiraAccount(acct)
	require.NoError(t, err)
	assert.Equal(t, "ok", got.Status, "shutdown must not be recorded as a revoked grant")
	assert.Empty(t, got.Error)
}

// A failure that never touches the account row must still reach the run
// telemetry — dropping the auth-state stamp must not make failed passes look
// clean in pipeline_runs.
func TestPhaseJiraSyncGenericFailureStillRecordsTelemetry(t *testing.T) {
	d, database, _ := newJiraTestDaemon(t)

	acct, err := database.CreateJiraAccount(db.JiraAccount{CloudID: "c1"})
	require.NoError(t, err)

	d.jiraSyncers = []jiraAccountSyncer{
		&stubJiraSyncer{accountID: acct, err: errors.New("jira api 503"), inTok: 100, outTok: 20, apiTok: 120},
	}

	d.phaseJiraSync(context.Background())

	var status, errMsg string
	require.NoError(t, database.QueryRow(
		`SELECT status, error_msg FROM pipeline_runs WHERE pipeline = 'jira-boards' ORDER BY id DESC LIMIT 1`,
	).Scan(&status, &errMsg))
	assert.Equal(t, "error", status)
	assert.Contains(t, errMsg, "jira api 503", "the pass's first error must still land in pipeline_runs")
}

// TestPhaseJiraSyncTargetStatusesSurviveOneAccountFailure is the fan-out
// isolation guard for the target-status reflection: one broken account must not
// freeze every other account's targets in a stale status. The healthy account
// synced fine, so its done issue must still flip its target.
//
// Fails on the pre-fix code: the reflection was gated on firstErr == nil, so
// the failing account suppressed it and the target stayed "todo" forever.
func TestPhaseJiraSyncTargetStatusesSurviveOneAccountFailure(t *testing.T) {
	d, database, _ := newJiraTestDaemon(t)

	broken, err := database.CreateJiraAccount(db.JiraAccount{CloudID: "c1"})
	require.NoError(t, err)
	healthy, err := database.CreateJiraAccount(db.JiraAccount{CloudID: "c2"})
	require.NoError(t, err)

	// A done issue on the HEALTHY account only — a key present on both sites is
	// ambiguous and deliberately left alone by SyncJiraTargetStatuses.
	require.NoError(t, database.UpsertJiraIssue(db.JiraIssue{
		AccountID: healthy,
		Key:       "OPS-1", ProjectKey: "OPS", Summary: "Shipped",
		Status: "Done", StatusCategory: "done",
		Labels: `[]`, Components: `[]`, CreatedAt: "now", UpdatedAt: "now", SyncedAt: "now",
	}))
	target, err := database.CreateTargetFromJiraIssue(db.JiraIssue{AccountID: healthy, Key: "OPS-1", Summary: "Shipped"})
	require.NoError(t, err)
	require.Equal(t, "todo", target.Status)

	d.jiraSyncers = []jiraAccountSyncer{
		&stubJiraSyncer{accountID: broken, err: errors.New("jira api 503")},
		&stubJiraSyncer{accountID: healthy, issues: 1},
	}

	d.phaseJiraSync(context.Background())

	got, err := database.GetTargetByID(target.ID)
	require.NoError(t, err)
	assert.Equal(t, "done", got.Status, "a healthy account's targets must reflect Jira even when another account failed")
}
