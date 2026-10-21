package daemon

import (
	"context"
	"errors"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/db"
)

// seedDeletableJiraIssue stores one PROJ issue on a fresh account and returns
// the account id.
func seedDeletableJiraIssue(t *testing.T, database *db.DB) int64 {
	t.Helper()
	acct, err := database.CreateJiraAccount(db.JiraAccount{CloudID: "c1", SiteURL: "https://acme.example.com", SiteName: "acme", Label: "work"})
	require.NoError(t, err)
	require.NoError(t, database.UpsertJiraIssue(db.JiraIssue{AccountID: acct, Key: "PROJ-1", ProjectKey: "PROJ",
		Summary: "s", Status: "Open", StatusCategory: "new", CreatedAt: "2026-10-01T00:00:00Z",
		UpdatedAt: "2026-10-02T00:00:00Z", SyncedAt: "2026-10-02T00:00:00Z"}))
	return acct
}

// deletingCheck removes PROJ-1 the way jira.Syncer.CheckDeletedIssues does
// once Jira confirms it is gone.
func deletingCheck(t *testing.T, database *db.DB, acct int64) func() (int, error) {
	return func() (int, error) {
		n, err := database.DeleteJiraIssues(acct, []string{"PROJ-1"})
		require.NoError(t, err)
		return n, nil
	}
}

func jiraIssueCount(t *testing.T, database *db.DB) int {
	t.Helper()
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM jira_issues`).Scan(&n))
	return n
}

func TestPhaseJiraSync_ChecksDeletionsAfterCleanSync(t *testing.T) {
	d, database, logs := newEventsTestDaemon(t, nil)
	acct := seedDeletableJiraIssue(t, database)
	stub := &stubJiraSyncer{accountID: acct}
	stub.check = deletingCheck(t, database, acct)
	d.jiraSyncers = []jiraAccountSyncer{stub}

	d.phaseJiraSync(context.Background())
	assert.Equal(t, 1, stub.checkCalls)
	assert.Equal(t, 0, jiraIssueCount(t, database))
	assert.Contains(t, logs.String(), "1 deleted issues removed")
}

func TestPhaseJiraSync_DeletionCheckErrorIsLogged(t *testing.T) {
	d, database, logs := newEventsTestDaemon(t, nil)
	acct := seedDeletableJiraIssue(t, database)
	stub := &stubJiraSyncer{accountID: acct, check: func() (int, error) { return 0, errors.New("boom") }}
	d.jiraSyncers = []jiraAccountSyncer{stub}

	d.phaseJiraSync(context.Background())
	assert.Equal(t, 1, stub.checkCalls)
	assert.Contains(t, logs.String(), "deletion check: boom")
	var status string
	require.NoError(t, database.QueryRow(`SELECT status FROM jira_accounts WHERE id = ?`, acct).Scan(&status))
	assert.NotEqual(t, "revoked", status, "the check writes no auth state; the next Sync records a revoked grant")
}

func TestPhaseJiraSync_NoDeletionCheckAfterFailedSync(t *testing.T) {
	d, database, _ := newEventsTestDaemon(t, nil)
	acct := seedDeletableJiraIssue(t, database)
	stub := &stubJiraSyncer{accountID: acct, err: errors.New("sync failed")}
	stub.check = deletingCheck(t, database, acct)
	d.jiraSyncers = []jiraAccountSyncer{stub}

	d.phaseJiraSync(context.Background())
	assert.Equal(t, 0, stub.checkCalls)
	assert.Equal(t, 1, jiraIssueCount(t, database))
}

// The check runs inside observePhase(JiraSource): a removed issue is absent
// from the post-phase rows, so it publishes nothing.
func TestPhaseJiraSync_DeletedIssuePublishesNoEvent(t *testing.T) {
	ev := newRecordingEvents("jira.issue_changed")
	d, database, _ := newEventsTestDaemon(t, ev)
	acct := seedDeletableJiraIssue(t, database)
	stub := &stubJiraSyncer{accountID: acct}
	stub.check = deletingCheck(t, database, acct)
	d.jiraSyncers = []jiraAccountSyncer{stub}

	d.observePhase(context.Background(), automations.JiraSource(database), func() { d.phaseJiraSync(context.Background()) })
	assert.Equal(t, 1, stub.checkCalls)
	assert.Equal(t, 0, jiraIssueCount(t, database))
	assert.Empty(t, ev.published)
}
