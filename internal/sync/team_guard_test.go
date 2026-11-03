package sync

import (
	"context"
	"errors"
	"net/http"
	gosync "sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/logcanary"
)

// teamGuardMux is searchAuditMux whose team.info answers teamID and whose
// search calls are counted.
func teamGuardMux(teamID string, searches *int, mu *gosync.Mutex) *http.ServeMux {
	inner := searchAuditMux(func(w http.ResponseWriter, _ *http.Request) {
		mu.Lock()
		*searches++
		mu.Unlock()
		jsonOK(w, map[string]any{"ok": true, "messages": map[string]any{
			"matches": []any{}, "paging": map[string]any{"count": 100, "total": 0, "page": 1, "pages": 1}, "total": 0,
		}})
	})
	// searchAuditMux already registers /team.info; route it around.
	mux := http.NewServeMux()
	mux.Handle("/", inner)
	mux.HandleFunc("/team.info", func(w http.ResponseWriter, _ *http.Request) {
		jsonOK(w, map[string]any{"ok": true, "team": map[string]any{"id": teamID, "name": "other-team", "domain": "other"}})
	})
	return mux
}

// A row a pre-#915 Re-login moved to another team: the legacy workspace
// still names the home team, the row (and the token) name the other one.
func seedMovedAccountOne(t *testing.T, ts *testSetup) {
	t.Helper()
	require.Equal(t, int64(1), ts.accountID)
	require.NoError(t, ts.db.UpsertWorkspace(db.Workspace{ID: "T_HOME", Name: "home-team"}))
	require.NoError(t, ts.db.UpdateSlackAccountConnection(ts.accountID, "T_OTHER", "other-team", "other", "1:U001"))
	require.NoError(t, ts.db.SetSlackAccountSearchWatermark(ts.accountID, "2026-03-01"))
}

func TestTeamGuard_MovedAccountSkipsSyncAndKeepsWatermark(t *testing.T) {
	var searches int
	var mu gosync.Mutex
	ts := newTestSetup(t, teamGuardMux("T_OTHER", &searches, &mu))
	sink := logcanary.Capture(t)
	ts.orch.SetLogger(sink.Logger())
	seedMovedAccountOne(t, ts)

	runErr := ts.orch.Run(context.Background(), SyncOptions{})
	require.ErrorIs(t, runErr, ErrSlackTeamMismatch)
	require.Zero(t, searches, "no search may run for another team's token")

	acct, err := ts.db.GetSlackAccount(ts.accountID)
	require.NoError(t, err)
	require.Equal(t, "error", acct.Status)
	require.Equal(t, "Signed in to a different Slack workspace (other-team) — Re-login to home-team", acct.Error)
	require.Equal(t, "2026-03-01", acct.SearchLastDate, "the search watermark must not move")
	require.Equal(t, "T_OTHER", acct.TeamID, "the guard writes no team fields")

	// FILES-01: the error the daemon logs names ids, never team names.
	require.NotContains(t, sink.String(), "home-team")
	require.NotContains(t, sink.String(), "other-team")
	require.NotContains(t, runErr.Error(), "home-team")
	require.NotContains(t, runErr.Error(), "other-team")
	require.Contains(t, runErr.Error(), "T_HOME")
}

func TestTeamGuard_FullSyncRefusesTeamInfoOfAnotherTeam(t *testing.T) {
	var searches int
	var mu gosync.Mutex
	// The row is on the home team, but the token answers for another team:
	// the full sync's team.info must not move the row.
	ts := newTestSetup(t, teamGuardMux("T_OTHER", &searches, &mu))
	require.NoError(t, ts.db.UpdateSlackAccountConnection(ts.accountID, "T_HOME", "home-team", "home", "1:U001"))

	err := ts.orch.Run(context.Background(), SyncOptions{Full: true})
	require.ErrorIs(t, err, ErrSlackTeamMismatch)
	acct, err := ts.db.GetSlackAccount(ts.accountID)
	require.NoError(t, err)
	require.Equal(t, "T_HOME", acct.TeamID)
	require.Equal(t, "home-team", acct.TeamName)
	require.Equal(t, "error", acct.Status)
}

func TestTeamGuard_FirstRunRefusesTeamInfoOfAnotherTeam(t *testing.T) {
	var searches int
	var mu gosync.Mutex
	// Account #1 with no cached team on an install whose legacy workspace
	// names the home team: team.info for another team is refused before the
	// row is written.
	ts := newTestSetup(t, teamGuardMux("T_OTHER", &searches, &mu))
	require.NoError(t, ts.db.UpsertWorkspace(db.Workspace{ID: "T_HOME", Name: "home-team"}))

	err := ts.orch.Run(context.Background(), SyncOptions{})
	require.ErrorIs(t, err, ErrSlackTeamMismatch)
	require.Zero(t, searches)
	acct, err := ts.db.GetSlackAccount(ts.accountID)
	require.NoError(t, err)
	require.Empty(t, acct.TeamID)
}

func TestTeamGuard_HomeTeamSyncsAsUsual(t *testing.T) {
	var searches int
	var mu gosync.Mutex
	ts := newTestSetup(t, teamGuardMux("T_HOME", &searches, &mu))
	require.NoError(t, ts.db.UpsertWorkspace(db.Workspace{ID: "T_HOME", Name: "home-team"}))
	require.NoError(t, ts.db.UpdateSlackAccountConnection(ts.accountID, "T_HOME", "home-team", "home", "1:U001"))

	// The empty search falls back to a full sync the mux cannot serve; only
	// the guard's verdict matters here.
	err := ts.orch.Run(context.Background(), SyncOptions{})
	require.NotErrorIs(t, err, ErrSlackTeamMismatch)
	require.Equal(t, 1, searches)
}

func TestTeamGuard_BackfillSearchHoldsOnMovedAccount(t *testing.T) {
	var searches int
	var mu gosync.Mutex
	ts := newTestSetup(t, teamGuardMux("T_OTHER", &searches, &mu))
	seedMovedAccountOne(t, ts)

	to := time.Now()
	_, err := ts.orch.BackfillSearch(context.Background(), to.Add(-48*time.Hour), to)
	require.ErrorIs(t, err, ErrSlackTeamMismatch)
	require.ErrorIs(t, err, ErrBackfillIncomplete, "a moved account holds the chunk, never strikes it")
	require.Zero(t, searches)
}

func TestTeamGuard_UsersOnlyRecordsMismatch(t *testing.T) {
	var searches int
	var mu gosync.Mutex
	ts := newTestSetup(t, teamGuardMux("T_OTHER", &searches, &mu))
	seedMovedAccountOne(t, ts)

	err := ts.orch.RunUsersOnly(context.Background())
	var mismatch *TeamMismatchError
	require.True(t, errors.As(err, &mismatch))
	acct, err := ts.db.GetSlackAccount(ts.accountID)
	require.NoError(t, err)
	require.Equal(t, "error", acct.Status)
}
