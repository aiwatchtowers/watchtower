package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// seedMappedJiraUser records a resolved Jira→Slack mapping.
func seedMappedJiraUser(t *testing.T, d *DB, jiraAccountID, slackUserID string) {
	t.Helper()
	require.NoError(t, d.UpsertJiraUserMap(JiraUserMap{
		JiraAccountID:   jiraAccountID,
		Email:           jiraAccountID + "@example.com",
		SlackUserID:     slackUserID,
		MatchMethod:     "email",
		MatchConfidence: 1.0,
		ResolvedAt:      "2026-09-13T00:00:00Z",
	}))
}

// seedIssueWithPeople writes one issue carrying the given stored Slack ids.
func seedIssueWithPeople(t *testing.T, d *DB, accountID int64, key, assigneeJiraID, assigneeSlackID, reporterJiraID, reporterSlackID string) {
	t.Helper()
	require.NoError(t, d.UpsertJiraIssue(JiraIssue{
		AccountID:         accountID,
		Key:               key,
		ID:                key,
		ProjectKey:        "PROJ",
		Summary:           key,
		AssigneeAccountID: assigneeJiraID,
		AssigneeSlackID:   assigneeSlackID,
		ReporterAccountID: reporterJiraID,
		ReporterSlackID:   reporterSlackID,
		SyncedAt:          "2026-09-13T00:00:00Z",
	}))
}

func issueSlackIDs(t *testing.T, d *DB, accountID int64, key string) (assignee, reporter string) {
	t.Helper()
	err := d.QueryRow(`SELECT assignee_slack_id, reporter_slack_id FROM jira_issues WHERE account_id = ? AND key = ?`,
		accountID, key).Scan(&assignee, &reporter)
	require.NoError(t, err)
	return assignee, reporter
}

// runBackfill runs the repair and returns how many rows each statement
// rewrote, so a test can assert on the write itself and not only on the value
// left behind — an implementation that rewrites a row to the value it already
// holds is invisible to the latter.
func runBackfill(t *testing.T, d *DB) (assignees, reporters int64) {
	t.Helper()
	assignees, reporters, err := d.BackfillJiraSlackIDs()
	require.NoError(t, err)
	return assignees, reporters
}

// TestBackfillJiraSlackIDs_CorrectsStaleBareIDs is the repair migration 00048
// never made. 00048 namespaced jira_user_map.slack_user_id and users.id but
// left the denormalized copies on jira_issues alone, so every issue last
// upserted before it still carries a bare "U..." that no namespaced reader can
// ever match. The old backfill guarded on the column being empty, so it filled
// empty cells only, which is precisely why those rows survived it.
//
// Both columns are asserted: 00048 missed the pair, and a repair that fixes
// only the assignee leaves "AWAITING MY INPUT" (reporter_slack_id) broken.
func TestBackfillJiraSlackIDs_CorrectsStaleBareIDs(t *testing.T) {
	d := openTestDB(t)
	acct := SeedTestJiraAccount(t, d)

	seedMappedJiraUser(t, d, "jira-alice", "1:UALICE")
	seedMappedJiraUser(t, d, "jira-bob", "1:UBOB")
	seedIssueWithPeople(t, d, acct, "PROJ-1", "jira-alice", "UALICE", "jira-bob", "UBOB")

	runBackfill(t, d)

	assignee, reporter := issueSlackIDs(t, d, acct, "PROJ-1")
	assert.Equal(t, "1:UALICE", assignee, "a bare assignee id must be re-derived from the map")
	assert.Equal(t, "1:UBOB", reporter, "a bare reporter id must be re-derived from the map")
}

// TestBackfillJiraSlackIDs_FillsEmptyCells keeps the behaviour the relaxed
// guard must not lose: an issue synced before its user was resolved still gets
// its Slack ids on the next pass.
func TestBackfillJiraSlackIDs_FillsEmptyCells(t *testing.T) {
	d := openTestDB(t)
	acct := SeedTestJiraAccount(t, d)

	seedMappedJiraUser(t, d, "jira-alice", "1:UALICE")
	seedIssueWithPeople(t, d, acct, "PROJ-1", "jira-alice", "", "jira-alice", "")

	runBackfill(t, d)

	assignee, reporter := issueSlackIDs(t, d, acct, "PROJ-1")
	assert.Equal(t, "1:UALICE", assignee)
	assert.Equal(t, "1:UALICE", reporter)
}

// TestBackfillJiraSlackIDs_LeavesUnmappedRowsAlone pins the other half of
// "re-derive from the map": a Jira user with no resolved mapping carries no
// evidence about the stored value, so the row is left exactly as it is. The
// obvious wrong implementation — generalising the old COALESCE-to-empty to
// every row — would blank a perfectly good id here the moment the mapping is
// missing, which on a fresh install is every row.
func TestBackfillJiraSlackIDs_LeavesUnmappedRowsAlone(t *testing.T) {
	d := openTestDB(t)
	acct := SeedTestJiraAccount(t, d)

	// Mapped, but with an empty slack id — a shell row, the shape ensureUserMap
	// creates for every Jira user the resolver has not matched yet.
	require.NoError(t, d.UpsertJiraUserMap(JiraUserMap{JiraAccountID: "jira-shell", Email: "shell@example.com"}))
	seedIssueWithPeople(t, d, acct, "PROJ-1", "jira-shell", "1:USHELL", "jira-absent", "1:UABSENT")

	runBackfill(t, d)

	assignee, reporter := issueSlackIDs(t, d, acct, "PROJ-1")
	assert.Equal(t, "1:USHELL", assignee, "a shell map row must not blank a stored id")
	assert.Equal(t, "1:UABSENT", reporter, "an unmapped Jira user must not blank a stored id")
}

// TestBackfillJiraSlackIDs_IgnoresIssuesWithoutJiraUser is the degenerate case:
// an unassigned issue has no Atlassian account id to key the map by, so there
// is nothing to derive and nothing to write.
func TestBackfillJiraSlackIDs_IgnoresIssuesWithoutJiraUser(t *testing.T) {
	d := openTestDB(t)
	acct := SeedTestJiraAccount(t, d)

	seedMappedJiraUser(t, d, "jira-alice", "1:UALICE")
	seedIssueWithPeople(t, d, acct, "PROJ-1", "", "", "", "")

	runBackfill(t, d)

	assignee, reporter := issueSlackIDs(t, d, acct, "PROJ-1")
	assert.Empty(t, assignee)
	assert.Empty(t, reporter)
}

// TestBackfillJiraSlackIDs_IsIdempotent: a row already agreeing with the map is
// untouched, so repeated daemon passes converge instead of churning.
//
// Asserted on the row COUNTS, not on the values left behind. An implementation
// that drops the disagreement clause and rewrites every mapped row to the value
// it already holds leaves both columns reading exactly the same, so a
// value-only assertion cannot see it — while the daemon rewrites every mapped
// row in jira_issues twice a pass, per account, every 15 minutes. The seed is
// deliberately stale so the first pass must report 1, 1: a test where both
// passes report 0 would also pass against a backfill that does nothing at all.
func TestBackfillJiraSlackIDs_IsIdempotent(t *testing.T) {
	d := openTestDB(t)
	acct := SeedTestJiraAccount(t, d)

	seedMappedJiraUser(t, d, "jira-alice", "1:UALICE")
	seedIssueWithPeople(t, d, acct, "PROJ-1", "jira-alice", "UALICE", "jira-alice", "UALICE")

	assignees, reporters := runBackfill(t, d)
	assert.Equal(t, int64(1), assignees, "the stale assignee must be repaired on the first pass")
	assert.Equal(t, int64(1), reporters, "the stale reporter must be repaired on the first pass")

	assignees, reporters = runBackfill(t, d)
	assert.Zero(t, assignees, "a row already agreeing with the map must not be rewritten again")
	assert.Zero(t, reporters, "a row already agreeing with the map must not be rewritten again")

	assignee, reporter := issueSlackIDs(t, d, acct, "PROJ-1")
	assert.Equal(t, "1:UALICE", assignee)
	assert.Equal(t, "1:UALICE", reporter)
}

// TestBackfillJiraSlackIDs_CountsOnlyRewrittenRows pins what the returned
// counts mean, since they are now the only observable signal that the repair
// converged: rows left alone are not counted, so a pass over an install with
// one stale row and one healthy row reports one, not two.
func TestBackfillJiraSlackIDs_CountsOnlyRewrittenRows(t *testing.T) {
	d := openTestDB(t)
	acct := SeedTestJiraAccount(t, d)

	seedMappedJiraUser(t, d, "jira-alice", "1:UALICE")
	seedIssueWithPeople(t, d, acct, "PROJ-1", "jira-alice", "UALICE", "jira-alice", "1:UALICE")
	seedIssueWithPeople(t, d, acct, "PROJ-2", "jira-alice", "1:UALICE", "jira-alice", "1:UALICE")

	assignees, reporters := runBackfill(t, d)
	assert.Equal(t, int64(1), assignees, "only PROJ-1's stale assignee needed rewriting")
	assert.Zero(t, reporters, "both reporters already agreed with the map")
}
