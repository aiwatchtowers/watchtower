package dayplan

import (
	"context"
	"testing"

	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func seedDayPlanLinear(t *testing.T, d *db.DB) {
	t.Helper()
	la, err := d.CreateLinearAccount("")
	require.NoError(t, err)
	for id, assignee := range map[string]string{"ENG-7": "lin-me", "ENG-8": "lin-other"} {
		require.NoError(t, d.UpsertLinearIssue(db.LinearIssue{AccountID: la, ID: "id-" + id, Key: id, TeamKey: "ENG",
			Title: "Linear " + id, StateName: "In Progress", StatusCategory: "in_progress", Priority: 2,
			AssigneeID: assignee, UpdatedAt: "2026-04-01T12:00:00.000Z"}))
	}
}

// A Linear owner's open assigned issues reach the prompt's issues section
// when linear.enabled, never someone else's; with Linear off they do not.
func TestRun_LinearOwnerGathersOwnAssignedIssue(t *testing.T) {
	d := gatherTestDB(t)
	seedDayPlanLinear(t, d)
	owner := db.Owner{ID: "linear:lin-me", Source: db.OwnerSourceLinear, LinearUserIDs: []string{"lin-me"}}

	gen := &promptCapturingGenerator{response: validResponse()}
	p := newTestPipeline(d, gen)
	p.cfg.Linear.Enabled = true
	_, err := p.Run(context.Background(), RunOptions{UserID: owner.ID, Owner: owner, Date: "2026-04-23"})
	require.NoError(t, err)
	assert.Contains(t, gen.prompt, "- [ENG-7 High] Linear ENG-7 (status: In Progress)")
	assert.NotContains(t, gen.prompt, "ENG-8")

	p.cfg.Linear.Enabled = false
	assert.Empty(t, p.gatherJira(owner))
}

// The model names an issue item "jira" (the template predates Linear); the
// item is stored under the tracker its key belongs to. A key both trackers
// carry keeps the model's choice; an unknown key is dropped.
func TestBuildItems_StampsIssueTracker(t *testing.T) {
	keys := issueKeyTrackers([]db.TrackerIssue{
		{Tracker: db.TrackerJira, Key: "ABC-1"},
		{Tracker: db.TrackerLinear, Key: "ENG-1"},
		{Tracker: db.TrackerJira, Key: "DUP-1"},
		{Tracker: db.TrackerLinear, Key: "DUP-1"},
	})
	r := &GenerateResult{Backlog: []AIItem{
		{SourceType: "jira", SourceID: "ABC-1", Title: "a", Priority: "medium"},
		{SourceType: "jira", SourceID: "ENG-1", Title: "b", Priority: "medium"},
		{SourceType: "linear", SourceID: "ENG-1", Title: "c", Priority: "medium"},
		{SourceType: "linear", SourceID: "DUP-1", Title: "d", Priority: "medium"},
		{SourceType: "jira", SourceID: "DUP-1", Title: "e", Priority: "medium"},
		{SourceType: "linear", SourceID: "NOPE-1", Title: "f", Priority: "medium"},
	}}
	items, dropped, invalid := buildItems(r, "2026-04-23", nil, nil, keys)
	require.Len(t, items, 5)
	got := map[string]string{}
	for _, it := range items {
		got[it.Title] = it.SourceType
	}
	assert.Equal(t, map[string]string{"a": "jira", "b": "linear", "c": "linear", "d": "linear", "e": "jira"}, got)
	assert.Equal(t, 1, invalid)
	assert.Equal(t, []string{`unknown linear source_id "NOPE-1" for "f"`}, dropped)
}
