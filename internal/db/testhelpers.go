package db

import (
	"database/sql"
	"testing"
)

// OpenTestDB opens an in-memory database for use by tests in other packages
// (e.g. internal/catchup). It registers cleanup on the test. The unexported
// openTestDB in this package's own tests does the same; this is the exported
// wrapper so cross-package tests don't duplicate setup.
func OpenTestDB(t *testing.T) *DB {
	t.Helper()
	d, err := Open(":memory:")
	if err != nil {
		t.Fatalf("opening in-memory test db: %v", err)
	}
	t.Cleanup(func() { _ = d.Close() })
	return d
}

// SeedTestJiraAccount inserts a jira_accounts row and returns its id, so
// tests can write into the account-scoped jira_* tables (their account_id
// FK requires a parent row). Each call mints a NEW account — call it once per
// account a test needs, twice to exercise cross-site behaviour.
func SeedTestJiraAccount(t *testing.T, d *DB) int64 {
	t.Helper()
	id, err := d.CreateJiraAccount(JiraAccount{
		CloudID:  "test-cloud",
		SiteURL:  "https://test.atlassian.net",
		SiteName: "Test",
	})
	if err != nil {
		t.Fatalf("seeding test jira account: %v", err)
	}
	return id
}

// SeedTestWorkbenchTarget creates one target on project projectID's board (the
// board defaults, via CreateWorkbenchTargetsTx) and returns its id.
func SeedTestWorkbenchTarget(t *testing.T, d *DB, projectID int64, parent sql.NullInt64, title string) int64 {
	t.Helper()
	var ids []int64
	err := d.WithTx(func(tx *sql.Tx) error {
		var err error
		ids, err = d.CreateWorkbenchTargetsTx(tx, projectID, ActorAgent, []WorkbenchTargetInput{{Title: title, ParentID: parent}})
		return err
	})
	if err != nil {
		t.Fatalf("seeding project target %q: %v", title, err)
	}
	return ids[0]
}
