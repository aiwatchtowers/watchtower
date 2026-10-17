package automations

import (
	"context"
	"reflect"
	"testing"

	"watchtower/internal/db"
)

// jiraIssue is a PAY issue on account acct; summary and description carry
// contentMarker.
func jiraIssue(acct int64, key string) db.JiraIssue {
	return db.JiraIssue{AccountID: acct, Key: key, ProjectKey: "PAY", Summary: contentMarker,
		DescriptionText: contentMarker, Status: "Open", StatusCategory: "new", AssigneeAccountID: "A1",
		Priority: "High", CreatedAt: "2026-10-01T00:00:00Z", UpdatedAt: "2026-10-02T00:00:00Z",
		SyncedAt: "2026-10-02T00:00:00Z"}
}

// jiraFixture seeds Jira account "work" (site acme) with PAY-1 and PAY-2.
func jiraFixture(t *testing.T) (*db.DB, int64) {
	t.Helper()
	d := openEventDB(t)
	acct, err := d.CreateJiraAccount(db.JiraAccount{CloudID: "c1", SiteURL: "https://acme.example.com", SiteName: "acme", Label: "work"})
	must(t, err)
	for _, k := range []string{"PAY-1", "PAY-2"} {
		must(t, d.UpsertJiraIssue(jiraIssue(acct, k)))
	}
	return d, acct
}

// jiraEvents runs the Jira source around phase.
func jiraEvents(t *testing.T, d *db.DB, phase func()) []Event {
	t.Helper()
	ctx := context.Background()
	src := JiraSource(d)
	if src.Type() != "jira.issue_changed" {
		t.Errorf("Type() = %q", src.Type())
	}
	diff, err := src.Before(ctx)
	must(t, err)
	phase()
	events, err := diff.After(ctx)
	must(t, err)
	return events
}

func jiraEvent(account, key, field string) Event {
	return Event{Type: "jira.issue_changed", Fields: map[string]any{"account": account, "key": key, "project": "PAY", "field": field}}
}

func TestJiraEvents_FieldPerChange(t *testing.T) {
	d, acct := jiraFixture(t)
	must(t, d.UpsertJiraIssue(jiraIssue(acct, "PAY-3")))
	must(t, d.UpsertJiraIssue(jiraIssue(acct, "PAY-4")))
	got := jiraEvents(t, d, func() {
		moved := jiraIssue(acct, "PAY-1")
		moved.Status, moved.AssigneeAccountID, moved.UpdatedAt = "Done", "A2", "2026-10-03T00:00:00Z"
		must(t, d.UpsertJiraIssue(moved))
		bumped := jiraIssue(acct, "PAY-2")
		bumped.Priority, bumped.UpdatedAt = "Low", "2026-10-03T00:00:00Z"
		must(t, d.UpsertJiraIssue(bumped))
		must(t, d.UpsertJiraComments([]db.JiraComment{{AccountID: acct, IssueKey: "PAY-3", ID: "10", BodyText: contentMarker}}))
		touched := jiraIssue(acct, "PAY-4")
		touched.UpdatedAt = "2026-10-03T00:00:00Z"
		must(t, d.UpsertJiraIssue(touched))
	})
	want := []Event{
		jiraEvent("work", "PAY-1", "status"),
		jiraEvent("work", "PAY-1", "assignee"),
		jiraEvent("work", "PAY-2", "priority"),
		jiraEvent("work", "PAY-3", "comment"),
		jiraEvent("work", "PAY-4", "other"),
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("events = %+v\nwant %+v", got, want)
	}
}

func TestJiraEvents_UnchangedIssueNoEvent(t *testing.T) {
	d, acct := jiraFixture(t)
	got := jiraEvents(t, d, func() {
		must(t, d.UpsertJiraIssue(jiraIssue(acct, "PAY-1"))) // re-synced as is
		gone := jiraIssue(acct, "PAY-2")
		gone.IsDeleted, gone.Status = true, "Done"
		must(t, d.UpsertJiraIssue(gone))
	})
	if len(got) != 0 {
		t.Errorf("unchanged/deleted issues published %+v", got)
	}
}

func TestJiraEvents_FirstSeenProjectPublishesNothing(t *testing.T) {
	d := openEventDB(t)
	acct, err := d.CreateJiraAccount(db.JiraAccount{CloudID: "c1", SiteName: "acme", Label: "work"})
	must(t, err)
	got := jiraEvents(t, d, func() {
		must(t, d.UpsertJiraIssue(jiraIssue(acct, "PAY-1")))
		must(t, d.UpsertJiraIssue(jiraIssue(acct, "PAY-2")))
	})
	if len(got) != 0 {
		t.Errorf("first sync of a project published %+v", got)
	}
	// A project new to a known account is a first sync too.
	got = jiraEvents(t, d, func() {
		ops := jiraIssue(acct, "OPS-1")
		ops.ProjectKey = "OPS"
		must(t, d.UpsertJiraIssue(ops))
	})
	if len(got) != 0 {
		t.Errorf("first sync of project OPS published %+v", got)
	}
}

func TestJiraEvents_NewIssueInKnownProjectIsOther(t *testing.T) {
	d, acct := jiraFixture(t)
	got := jiraEvents(t, d, func() {
		must(t, d.UpsertJiraIssue(jiraIssue(acct, "PAY-9")))
	})
	if want := []Event{jiraEvent("work", "PAY-9", "other")}; !reflect.DeepEqual(got, want) {
		t.Errorf("events = %+v, want %+v", got, want)
	}
}

func TestJiraEvents_AccountLabelFallback(t *testing.T) {
	d, acct := jiraFixture(t)
	_, err := d.Exec(`UPDATE jira_accounts SET label = '' WHERE id = ?`, acct)
	must(t, err)
	got := jiraEvents(t, d, func() {
		i := jiraIssue(acct, "PAY-1")
		i.Status = "Done"
		must(t, d.UpsertJiraIssue(i))
	})
	if want := []Event{jiraEvent("acme", "PAY-1", "status")}; !reflect.DeepEqual(got, want) {
		t.Errorf("events = %+v, want %+v", got, want)
	}
}

// jiraContentEvents builds Jira events from the contentMarker fixtures for
// TestBus_EventsCarryNoContent.
func jiraContentEvents(t *testing.T) []Event {
	d, acct := jiraFixture(t)
	events := jiraEvents(t, d, func() {
		i := jiraIssue(acct, "PAY-1")
		i.Status, i.Summary = "Done", contentMarker+" edited"
		must(t, d.UpsertJiraIssue(i))
		must(t, d.UpsertJiraComments([]db.JiraComment{{AccountID: acct, IssueKey: "PAY-2", ID: "10", BodyText: contentMarker}}))
		must(t, d.UpsertJiraIssue(jiraIssue(acct, "PAY-3")))
	})
	if len(events) != 3 {
		t.Fatalf("jira content fixture built %d events, want 3", len(events))
	}
	return events
}
