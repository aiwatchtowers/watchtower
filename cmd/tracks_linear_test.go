package cmd

import (
	"bytes"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

// A track's detail view lists its linked Linear issues on a Linear-only
// install (track_linking governs both trackers), and nothing when the toggle
// is off.
func TestPrintTrackLinkedLinearIssues(t *testing.T) {
	d := db.OpenTestDB(t)
	acct := db.SeedLinearTestAccount(t, d)
	require.NoError(t, d.UpsertLinearIssue(db.LinearIssue{AccountID: acct, ID: "u1", Key: "ENG-5", Title: "Importer",
		StateName: "In Progress", StatusCategory: "in_progress", AssigneeDisplayName: "Ann", DueDate: "2020-01-01",
		UpdatedAt: "2026-10-01T00:00:00.000Z"}))
	tid := 7
	require.NoError(t, d.UpsertIssueSlackLink(db.IssueSlackLink{Tracker: "linear", IssueKey: "ENG-5", TrackID: &tid, LinkType: "track"}))

	cfg := &config.Config{}
	cfg.Linear.Enabled = true
	cfg.Jira.Features.TrackJiraLinking = true
	var out bytes.Buffer
	printTrackLinkedLinearIssues(&out, d, cfg, &db.Track{ID: tid})
	assert.Contains(t, out.String(), "Linked Linear Issues:")
	assert.Contains(t, out.String(), "[ENG-5 In Progress] Importer (Ann) *** OVERDUE ***")

	cfg.Jira.Features.TrackJiraLinking = false
	out.Reset()
	printTrackLinkedLinearIssues(&out, d, cfg, &db.Track{ID: tid})
	assert.Empty(t, out.String())
}
