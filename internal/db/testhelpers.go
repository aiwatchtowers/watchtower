package db

import (
	"database/sql"
	"encoding/json"
	"maps"
	"os"
	"slices"
	"strings"
	"testing"
	"time"
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

// SeedTestWorkbenchTarget creates one target on workbench workbenchID's board (the
// board defaults, via CreateWorkbenchTargetsTx) and returns its id.
func SeedTestWorkbenchTarget(t *testing.T, d *DB, workbenchID int64, parent sql.NullInt64, title string) int64 {
	t.Helper()
	var ids []int64
	err := d.WithTx(func(tx *sql.Tx) error {
		var err error
		ids, err = d.CreateWorkbenchTargetsTx(tx, workbenchID, ActorAgent, []WorkbenchTargetInput{{Title: title, ParentID: parent}})
		return err
	})
	if err != nil {
		t.Fatalf("seeding project target %q: %v", title, err)
	}
	return ids[0]
}

// OpenItemsFixture is the shared open-items fixture
// (internal/inbox/testdata/open_items.json): its now and the open ids,
// newest first.
type OpenItemsFixture struct {
	Now     time.Time
	OpenIDs []int64
}

// SeedTestOpenItemsFixture loads the open-items fixture at path into d —
// its users, channels, Jira issues (under one new Jira account) and inbox
// items, each object key but note a column — and returns its now and
// expected open ids.
func SeedTestOpenItemsFixture(t *testing.T, d *DB, path string) OpenItemsFixture {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var fx struct {
		Now        time.Time        `json:"now"`
		Users      []map[string]any `json:"users"`
		Channels   []map[string]any `json:"channels"`
		JiraIssues []map[string]any `json:"jira_issues"`
		Items      []map[string]any `json:"items"`
		OpenIDs    []int64          `json:"expected_open_ids"`
	}
	if err := json.Unmarshal(data, &fx); err != nil {
		t.Fatalf("decoding %s: %v", path, err)
	}
	insert := func(table string, row map[string]any) {
		t.Helper()
		cols := slices.Sorted(maps.Keys(row))
		cols = slices.DeleteFunc(cols, func(c string) bool { return c == "note" })
		args := make([]any, len(cols))
		for i, c := range cols {
			args[i] = row[c]
		}
		q := "INSERT INTO " + table + " (" + strings.Join(cols, ", ") + ") VALUES (?" + strings.Repeat(", ?", len(cols)-1) + ")"
		if _, err := d.Exec(q, args...); err != nil {
			t.Fatalf("seeding %s %v: %v", table, row, err)
		}
	}
	for _, u := range fx.Users {
		insert("users", u)
	}
	for _, c := range fx.Channels {
		insert("channels", c)
	}
	account := SeedTestJiraAccount(t, d)
	for _, j := range fx.JiraIssues {
		key, _ := j["key"].(string)
		row := map[string]any{"account_id": account, "project_key": strings.Split(key, "-")[0], "summary": key,
			"status": "To Do", "status_category": "new", "created_at": fx.Now.Format(time.RFC3339),
			"updated_at": fx.Now.Format(time.RFC3339), "synced_at": fx.Now.Format(time.RFC3339)}
		maps.Copy(row, j)
		insert("jira_issues", row)
	}
	for _, it := range fx.Items {
		insert("inbox_items", it)
	}
	return OpenItemsFixture{Now: fx.Now, OpenIDs: fx.OpenIDs}
}
