package kb

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func seedJira(t *testing.T, d *db.DB) {
	t.Helper()
	exec(t, d, `INSERT INTO jira_accounts (id, cloud_id, site_url) VALUES (1, 'c1', 'https://acme.atlassian.net/')`)
	exec(t, d, `INSERT INTO jira_issues (account_id, key, project_key, summary, description_text, status, status_category, assignee_display_name, labels, created_at, updated_at, synced_at)
		VALUES (1,'PROJ-123','PROJ','Stage environment','Нужен второй стейдж','In Progress','indeterminate','Anna','["infra"]','2026-04-01T09:00:00.000+0100','2026-04-20T09:37:38.027+0100','2026-04-20T11:00:01Z')`)
	exec(t, d, `INSERT INTO jira_comments (account_id, issue_key, id, author, body_text, created_at, updated_at, synced_at)
		VALUES (1,'PROJ-123','c2','Bob','second','2026-04-21T10:00:00.000+0000','2026-04-21T10:00:00.000+0000','2026-04-21T11:00:00Z'),
		       (1,'PROJ-123','c1','Anna','first','2026-04-20T10:00:00.000+0000','2026-04-20T10:00:00.000+0000','2026-04-21T11:00:00Z')`)
}

func TestJira_Build(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedJira(t, d)
	doc, err := jiraSource{}.Build(ctx, d, "jira:1:PROJ-123")
	require.NoError(t, err)
	require.NotNil(t, doc)
	assert.Equal(t, "PROJ-123 Stage environment", doc.Title)
	require.Len(t, doc.Sections, 4)
	assert.Equal(t, "Stage environment\nStatus: In Progress · Assignee: Anna", doc.Sections[0].Text, "summary + status/assignee always leads")
	assert.Equal(t, "Anna: first", doc.Sections[2].Text, "comments ordered by created_at")
	assert.Equal(t, "https://acme.atlassian.net/browse/PROJ-123", doc.Link)
	assert.Contains(t, doc.Meta, "infra")
	assert.Equal(t, "2026-04-21T10:00:00Z", doc.Time.Format("2006-01-02T15:04:05Z"))
	keys, next, done, err := jiraSource{}.Changed(ctx, d, "2026-04-21T00:00:00Z", testNow())
	require.NoError(t, err)
	assert.True(t, done)
	assert.Equal(t, []string{"jira:1:PROJ-123"}, keys, "a comment sync alone marks the issue changed")
	assert.Equal(t, "2026-04-21T11:00:00Z", next)
}

// Fix: an issue with no description and no comments (common in real Jira
// data) must still render a section, or writeDoc drops it as empty and it
// becomes unsearchable.
func TestJira_SummaryOnlyIssueStillIndexes(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	exec(t, d, `INSERT INTO jira_accounts (id, cloud_id, site_url) VALUES (1, 'c1', 'https://acme.atlassian.net/')`)
	exec(t, d, `INSERT INTO jira_issues (account_id, key, project_key, summary, status, status_category, created_at, updated_at, synced_at)
		VALUES (1,'PROJ-999','PROJ','Fix flaky test','To Do','new','2026-04-01T09:00:00.000+0100','2026-04-01T09:00:00.000+0100','2026-04-01T11:00:01Z')`)
	doc, err := jiraSource{}.Build(ctx, d, "jira:1:PROJ-999")
	require.NoError(t, err)
	require.NotNil(t, doc)
	require.Len(t, doc.Sections, 1)
	assert.Equal(t, "Fix flaky test\nStatus: To Do", doc.Sections[0].Text, "empty assignee omitted")
	assert.Equal(t, "PROJ-999", doc.Sections[0].Anchor)

	w, err := writeDoc(ctx, d, doc)
	require.NoError(t, err)
	assert.True(t, w)
	var n int
	require.NoError(t, d.QueryRow(`SELECT count(*) FROM kb_documents WHERE id = ?`, doc.ID).Scan(&n))
	assert.Equal(t, 1, n, "a summary-only issue must still be written")
}

func TestJira_DeletedIssueIsNil(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedJira(t, d)
	exec(t, d, `UPDATE jira_issues SET is_deleted = 1`)
	doc, err := jiraSource{}.Build(ctx, d, "jira:1:PROJ-123")
	require.NoError(t, err)
	assert.Nil(t, doc)
}

// Review focus #5: unparsable dates and null attendees still index.
func TestCalendar_BuildToleratesNullAttendees(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	exec(t, d, `INSERT INTO calendar_calendars (id, name) VALUES ('cal1','Work')`)
	exec(t, d, `INSERT INTO calendar_events (id, calendar_id, title, description, location, start_time, end_time, organizer_email, attendees, html_link)
		VALUES ('e1','cal1','Release sync','Обсудить стейдж','Room 1','2026-09-11T10:00:00Z','2026-09-11T11:00:00Z','boss@x.io','null','https://cal/e1'),
		       ('e2','cal1','Obj attendees','','','not-a-date','','','[{"email":"a@x.io","displayName":"Anna"},"b@x.io"]','')`)
	doc, err := calendarSource{}.Build(ctx, d, "calendar:e1")
	require.NoError(t, err)
	require.NotNil(t, doc)
	assert.Contains(t, doc.Sections[0].Text, "Organizer: boss@x.io")
	assert.Contains(t, doc.Sections[0].Text, "Обсудить стейдж")
	assert.NotContains(t, doc.Sections[0].Text, "Attendees:")
	doc2, err := calendarSource{}.Build(ctx, d, "calendar:e2")
	require.NoError(t, err)
	require.NotNil(t, doc2)
	assert.True(t, doc2.Time.IsZero())
	assert.Contains(t, doc2.Sections[0].Text, "Anna")
	assert.Contains(t, doc2.Sections[0].Text, "b@x.io")
}
