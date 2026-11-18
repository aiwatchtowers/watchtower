package daemon

import (
	"context"
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/jira"
	"watchtower/internal/policy/policytest"
)

// TestJiraAPIToken401IsErrorNotRevoked (#1887 D22): a 401 on an API-token
// account is an expired or revoked token — status 'error' with
// api_token_dead (its client records it at the 401: the stub stands in for
// that write), data kept, never 'revoked', so the purge (on) schedules
// nothing for it, and the refused pass proves no access.
func TestJiraAPIToken401IsErrorNotRevoked(t *testing.T) {
	d, database, _ := newJiraTestDaemon(t)
	setPurge(d, true)
	id, err := database.CreateJiraAccount(db.JiraAccount{CloudID: "c1", AuthKind: jira.AuthKindAPIToken})
	require.NoError(t, err)
	require.NoError(t, database.SetJiraAccountAuthState(id, "ok", ""))
	before, err := database.GetJiraAccount(id)
	require.NoError(t, err)
	_, err = database.Exec(`UPDATE jira_accounts SET access_ok_at = '2026-01-01T00:00:00Z' WHERE id = ?`, id)
	require.NoError(t, err)

	require.NoError(t, database.SetJiraAccountAuthState(id, "error", jira.CodeAPITokenDead)) // the client's hook
	dead := fmt.Errorf("syncing project OPS: %w: GET /rest/api/3/search/jql returned 401", jira.ErrAPITokenDead)
	d.jiraSyncers = []jiraAccountSyncer{&stubJiraSyncer{accountID: id, err: dead, reachedErr: true}}
	d.phaseJiraSync(context.Background())
	d.phaseAccountPurge(context.Background())

	got, err := database.GetJiraAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "error", got.Status)
	assert.Equal(t, jira.CodeAPITokenDead, got.Error)
	assert.Equal(t, before.CloudID, got.CloudID)
	var okAt, revokedAt string
	require.NoError(t, database.QueryRow(`SELECT access_ok_at, revoked_at FROM jira_accounts WHERE id = ?`, id).Scan(&okAt, &revokedAt))
	assert.Equal(t, "2026-01-01T00:00:00Z", okAt, "a refused token proves no access")
	assert.Empty(t, revokedAt)
	purges, err := database.ListAccountPurges(false)
	require.NoError(t, err)
	assert.Empty(t, purges, "a dead API token schedules no revoked purge")
}

// TestJiraAPIToken_PolicyStopHoldsLease (POLICY-03, D24): an API-token
// account the policy stops keeps its data — the daemon's purge rules hold
// its lease like a forbidden source's; an OAuth account is not held.
func TestJiraAPIToken_PolicyStopHoldsLease(t *testing.T) {
	token := db.PurgeAccount{Source: "jira", AuthKind: jira.AuthKindAPIToken}
	oauth := db.PurgeAccount{Source: "jira", AuthKind: "oauth"}
	assert.True(t, accountSyncAllowed(token))

	policytest.Set(t, map[string]any{"AllowAtlassianAPIToken": false})
	assert.False(t, accountSyncAllowed(token))
	assert.True(t, accountSyncAllowed(oauth))

	policytest.Set(t, map[string]any{"AllowedSources": []any{"slack"}})
	assert.False(t, accountSyncAllowed(oauth), "a forbidden source still holds every account")
}
