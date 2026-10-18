package db

import "testing"

// SeedLinearTestAccount inserts an enabled linear_accounts row and returns its
// id, so tests in other packages can write into the account-scoped linear_*
// tables. Each call mints a NEW account (the SeedTestJiraAccount twin).
func SeedLinearTestAccount(t *testing.T, d *DB) int64 {
	t.Helper()
	id, err := d.CreateLinearAccount("Test")
	if err != nil {
		t.Fatalf("seeding test linear account: %v", err)
	}
	return id
}

// SeedLinearTestIssue upserts one Linear issue and stamps its assignee and
// creator Slack ids (which UpsertLinearIssue never writes), for consumer tests.
func SeedLinearTestIssue(t *testing.T, d *DB, i LinearIssue, assigneeSlackID, creatorSlackID string) {
	t.Helper()
	if err := d.UpsertLinearIssue(i); err != nil {
		t.Fatalf("seeding linear issue %s: %v", i.Key, err)
	}
	if _, err := d.Exec(`UPDATE linear_issues SET assignee_slack_id = ?, creator_slack_id = ? WHERE account_id = ? AND id = ?`,
		assigneeSlackID, creatorSlackID, i.AccountID, i.ID); err != nil {
		t.Fatalf("stamping slack ids on linear issue %s: %v", i.Key, err)
	}
}
