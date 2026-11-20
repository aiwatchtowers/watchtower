package daemon

import (
	"context"
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/jira"
)

// TestJiraRefresh_InvalidClientIsErrorNotRevoked (#1887 P5): a refresh
// Atlassian refuses for the client is the company's app changing, not the
// person revoking access. The account gets status 'error' — invalid_client
// when tied to a company ("your company changed its app"), unknown_client
// when not ("open your company's link") — and never 'revoked', so with the
// purge on PURGE-01 schedules nothing for it.
func TestJiraRefresh_InvalidClientIsErrorNotRevoked(t *testing.T) {
	for _, tc := range []struct {
		name, slug, want string
	}{
		{"tied to a company", "acme", "invalid_client"},
		{"on no company", "", "unknown_client"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			d, database, _ := newJiraTestDaemon(t)
			setPurge(d, true)
			id, err := database.CreateJiraAccount(db.JiraAccount{CloudID: "c1", CompanySlug: tc.slug})
			require.NoError(t, err)
			require.NoError(t, database.SetJiraAccountAuthState(id, "ok", ""))

			rejected := fmt.Errorf("syncing project OPS: %w (401): {\"error\":\"invalid_client\"}", jira.ErrClientRejected)
			d.jiraSyncers = []jiraAccountSyncer{&stubJiraSyncer{accountID: id, err: rejected}}
			d.phaseJiraSync(context.Background())
			d.phaseAccountPurge(context.Background())

			got, err := database.GetJiraAccount(id)
			require.NoError(t, err)
			assert.Equal(t, "error", got.Status)
			assert.Equal(t, tc.want, got.Error)
			purges, err := database.ListAccountPurges(false)
			require.NoError(t, err)
			assert.Empty(t, purges, "a rejected client schedules no purge")
		})
	}
}

// A grant already revoked stays revoked: a later client refusal must not
// turn it into an 'error' and so reset its purge notice.
func TestJiraRefresh_InvalidClientKeepsRevoked(t *testing.T) {
	d, database, _ := newJiraTestDaemon(t)
	id, err := database.CreateJiraAccount(db.JiraAccount{CloudID: "c1", CompanySlug: "acme"})
	require.NoError(t, err)
	require.NoError(t, database.SetJiraAccountAuthState(id, "revoked", "grant revoked"))

	d.jiraSyncers = []jiraAccountSyncer{&stubJiraSyncer{accountID: id, err: fmt.Errorf("%w", jira.ErrClientRejected)}}
	d.phaseJiraSync(context.Background())

	got, err := database.GetJiraAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "revoked", got.Status)
	assert.Equal(t, "grant revoked", got.Error)
}
