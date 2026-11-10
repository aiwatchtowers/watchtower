package reviewmap

import (
	"database/sql"
	"errors"
	"net/http"
	"reflect"
	"testing"

	"watchtower/internal/db"
)

// failTransport fails the test on any HTTP request: DBTitles reads the
// local database only.
type failTransport struct{ t *testing.T }

func (f failTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	f.t.Errorf("DBTitles made an HTTP request to %s", r.URL.Host)
	return nil, errors.New("no network in this test")
}

func TestDBTitles_LocalDatabaseOnly(t *testing.T) {
	old := http.DefaultTransport
	http.DefaultTransport = failTransport{t}
	t.Cleanup(func() { http.DefaultTransport = old })

	d, err := db.Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.Close() })
	wb, err := d.CreateWorkbench("acme", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	other, err := d.CreateWorkbench("other", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	branchTarget := db.SeedTestWorkbenchTarget(t, d, wb, sql.NullInt64{}, "Lane by branch")
	// An older writer stored the branch untrimmed.
	if _, err := d.Exec(`UPDATE targets SET branch = ? WHERE id = ?`, "feature/ABC-1-x ", branchTarget); err != nil {
		t.Fatal(err)
	}
	ref := db.SeedTestWorkbenchTarget(t, d, wb, sql.NullInt64{}, "Board ref")
	foreign := db.SeedTestWorkbenchTarget(t, d, other, sql.NullInt64{}, "Foreign ref")
	acct, err := d.CreateJiraAccount(db.JiraAccount{CloudID: "cloud", SiteURL: "https://acme.example.com", SiteName: "acme"})
	if err != nil {
		t.Fatal(err)
	}
	if err := d.UpsertJiraIssue(db.JiraIssue{
		AccountID: acct, Key: "ABC-1", ID: "10001", ProjectKey: "ABC", Summary: "Issue summary",
		Status: "To Do", StatusCategory: "new", Labels: "[]", Components: "[]", FixVersions: "[]",
		CreatedAt: "2026-01-01T00:00:00Z", UpdatedAt: "2026-01-01T00:00:00Z", SyncedAt: "2026-01-01T00:00:00Z",
	}); err != nil {
		t.Fatal(err)
	}
	if err := d.UpdateJiraSyncState(acct, "ABC", "2026-01-01T00:00:00Z", 1); err != nil {
		t.Fatal(err)
	}

	got, err := DBTitles{DB: d, ProjectID: wb}.Titles(
		[]string{"feature/ABC-1-x", "feature/none"}, []string{"ABC-1", "ABC-2", "ZZ-9"}, []int64{ref, foreign, 99999})
	if err != nil {
		t.Fatal(err)
	}
	want := LaneTitles{
		BranchTargets: map[string]TargetTitle{"feature/ABC-1-x": {ID: branchTarget, Text: "Lane by branch"}},
		Jira:          map[string]string{"ABC-1": "Issue summary"},
		JiraProjects:  map[string]bool{"ABC": true},
		BoardRefs:     map[int64]TargetTitle{ref: {ID: ref, Text: "Board ref"}},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("titles = %+v\nwant %+v", got, want)
	}
}
