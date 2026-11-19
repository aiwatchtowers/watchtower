package inboxfeed

import (
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"

	"watchtower/internal/db"
)

// TestChangeTables_CoverEveryTableBuildReads: every table Build's SQL reads
// (FROM/JOIN in this package's non-test files, the inbox_artifact_folders
// view's tables and db.OpenInboxClause's) is in ChangeTables, so a write to
// it re-reads inbox.feed and wakes inbox.watch. The static list pins the
// set; the scan catches a new query that reads a table the list misses.
// The db readers Build calls (ReadNeedsApprovalTx, OpenInboxItemsTx,
// OwnerKnownTx, WatchmanJournalSummaryTx) are listed by hand: users and
// channels name a message's sender and channel, the account tables find the
// owner, the watchman tables make the journal's card.
func TestChangeTables_CoverEveryTableBuildReads(t *testing.T) {
	read := []string{
		"automation_outputs", "automation_runs", "automations", "agent_actions", "briefings",
		"builtin_migrations", "ideas", "inbox_folders", "inbox_folder_routes", "inbox_items",
		"jira_issues", "reminders", "tracks", "track_events", "day_plans", "day_plan_items",
		"targets", "projects", "users", "channels",
		"slack_accounts", "google_accounts", "jira_accounts", "linear_accounts", "email_accounts",
		"watchman_items", "watchman_workbenches",
	}
	views := map[string][]string{"inbox_artifact_folders": {"automation_outputs", "inbox_folder_routes", "inbox_folders"}}
	ref := regexp.MustCompile(`(?:FROM|JOIN)\s+([a-z_]+)`)
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	sources := []string{db.OpenInboxClause()}
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		sources = append(sources, string(b))
	}
	for _, src := range sources {
		for _, m := range ref.FindAllStringSubmatch(src, -1) {
			tables, isView := views[m[1]]
			if !isView {
				tables = []string{m[1]}
			}
			for _, table := range tables {
				if !slices.Contains(read, table) {
					t.Errorf("Build reads %s, which the test's list does not name", table)
				}
			}
		}
	}
	for _, table := range read {
		if !slices.Contains(ChangeTables, table) {
			t.Errorf("Build reads %s, but ChangeTables does not list it", table)
		}
	}
}
