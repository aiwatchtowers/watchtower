package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestCreateTargetFromTrackerIssue_LinearDedup(t *testing.T) {
	d := openTestDB(t)
	issue := TrackerIssue{Tracker: TrackerLinear, Key: "ENG-1", Title: "Ship it", PriorityRank: 1, DueDate: "2026-11-01"}
	first, err := d.CreateTargetFromTrackerIssue(issue)
	require.NoError(t, err)
	assert.Equal(t, "linear", first.SourceType)
	assert.Equal(t, "ENG-1", first.SourceID)
	assert.Equal(t, "high", first.Priority)
	assert.Equal(t, "2026-11-01", first.DueDate)

	again, err := d.CreateTargetFromTrackerIssue(issue)
	require.NoError(t, err)
	assert.Equal(t, first.ID, again.ID, "one target per issue")

	// The same key on Jira is a different issue: its own target.
	jiraTarget, err := d.CreateTargetFromTrackerIssue(TrackerIssue{Tracker: TrackerJira, Key: "ENG-1", Title: "Jira twin"})
	require.NoError(t, err)
	assert.NotEqual(t, first.ID, jiraTarget.ID)
	assert.Equal(t, "medium", jiraTarget.Priority)

	_, err = d.CreateTargetFromTrackerIssue(TrackerIssue{Tracker: "github", Key: "X-1"})
	require.Error(t, err)
}

func TestRankToTargetPriority_MatchesJiraNames(t *testing.T) {
	for name, rank := range map[string]int{"Highest": 1, "High": 2, "Medium": 3, "Low": 4, "Lowest": 5, "Custom": 0} {
		assert.Equal(t, jiraPriorityToTargetPriority(name), rankToTargetPriority(rank), name)
	}
}

func TestSyncLinearTargetStatuses(t *testing.T) {
	d := openTestDB(t)
	la, err := d.CreateLinearAccount("")
	require.NoError(t, err)
	upsert := func(id, key, cat string, prev ...string) {
		require.NoError(t, d.UpsertLinearIssue(LinearIssue{AccountID: la, ID: id, Key: key, PreviousKeys: prev,
			StatusCategory: cat, UpdatedAt: "2026-10-03T00:00:00.000Z"}))
	}
	upsert("l-1", "ENG-1", "in_progress")
	upsert("l-2", "ENG-2", "todo")
	started, err := d.CreateTargetFromTrackerIssue(TrackerIssue{Tracker: TrackerLinear, Key: "ENG-1", Title: "a"})
	require.NoError(t, err)
	moved, err := d.CreateTargetFromTrackerIssue(TrackerIssue{Tracker: TrackerLinear, Key: "ENG-2", Title: "b"})
	require.NoError(t, err)
	jiraTwin, err := d.CreateTargetFromTrackerIssue(TrackerIssue{Tracker: TrackerJira, Key: "ENG-1", Title: "jira"})
	require.NoError(t, err)

	// ENG-2 moves team and is done under its new key.
	upsert("l-2", "OPS-5", "done", "ENG-2")

	n, err := d.SyncLinearTargetStatuses()
	require.NoError(t, err)
	assert.Equal(t, 2, n)
	for id, want := range map[int]string{started.ID: "in_progress", moved.ID: "done", jiraTwin.ID: "todo"} {
		got, err := d.GetTargetByID(id)
		require.NoError(t, err)
		assert.Equal(t, want, got.Status, "target %d", id)
	}
	n, err = d.SyncJiraTargetStatuses()
	require.NoError(t, err)
	assert.Equal(t, 0, n, "a Linear issue never moves a Jira target")
}
