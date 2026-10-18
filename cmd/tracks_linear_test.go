package cmd

import (
	"bytes"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

// seedTrackLinkedOnBothTrackers stores a track linked to Jira PROJ-1 and to
// Linear ENG-5 (overdue), and returns its id.
func seedTrackLinkedOnBothTrackers(t *testing.T, d *db.DB) int {
	t.Helper()
	jiraAcct := db.SeedTestJiraAccount(t, d)
	require.NoError(t, d.UpsertJiraIssue(db.JiraIssue{AccountID: jiraAcct, Key: "PROJ-1", ProjectKey: "PROJ", Summary: "Jira side",
		Status: "Open", StatusCategory: "todo", CreatedAt: "2026-10-01T00:00:00.000Z", UpdatedAt: "2026-10-01T00:00:00.000Z", SyncedAt: "2026-10-01T00:00:00Z"}))
	acct := db.SeedLinearTestAccount(t, d)
	require.NoError(t, d.UpsertLinearIssue(db.LinearIssue{AccountID: acct, ID: "u1", Key: "ENG-5", Title: "Importer",
		StateName: "In Progress", StatusCategory: "in_progress", AssigneeDisplayName: "Ann", DueDate: "2020-01-01",
		UpdatedAt: "2026-10-01T00:00:00.000Z"}))
	id, err := d.UpsertTrack(db.Track{Text: "Payments", ChannelIDs: `[]`})
	require.NoError(t, err)
	tid := int(id)
	require.NoError(t, d.UpsertIssueSlackLink(db.IssueSlackLink{Tracker: "jira", IssueKey: "PROJ-1", TrackID: &tid, LinkType: "track"}))
	require.NoError(t, d.UpsertIssueSlackLink(db.IssueSlackLink{Tracker: "linear", IssueKey: "ENG-5", TrackID: &tid, LinkType: "track"}))
	return tid
}

func linkingCfg(jira, linear, toggle bool) *config.Config {
	cfg := &config.Config{}
	cfg.Jira.Enabled, cfg.Linear.Enabled = jira, linear
	cfg.Jira.Features.TrackJiraLinking = toggle
	return cfg
}

// The detail view lists linked Linear issues only while Linear is enabled and
// track_linking is on — a Jira-only install sees no Linear section.
func TestPrintTrackLinkedLinearIssues(t *testing.T) {
	d := db.OpenTestDB(t)
	tid := seedTrackLinkedOnBothTrackers(t, d)
	show := func(cfg *config.Config) string {
		var out bytes.Buffer
		printTrackLinkedLinearIssues(&out, d, cfg, &db.Track{ID: tid})
		return out.String()
	}
	got := show(linkingCfg(false, true, true))
	assert.Contains(t, got, "Linked Linear Issues:")
	assert.Contains(t, got, "[ENG-5 In Progress] Importer (Ann) *** OVERDUE ***")
	assert.Empty(t, show(linkingCfg(false, true, false)), "the toggle governs both trackers")
	assert.Empty(t, show(linkingCfg(true, false, true)), "Linear off: no Linear section")

	var jiraOut bytes.Buffer
	printTrackLinkedJiraIssues(&jiraOut, d, linkingCfg(false, true, true), &db.Track{ID: tid})
	assert.Empty(t, jiraOut.String(), "Jira off: no Jira section")
}

// List badges come only from enabled trackers.
func TestPrintTracks_BadgesPerEnabledTracker(t *testing.T) {
	d := db.OpenTestDB(t)
	seedTrackLinkedOnBothTrackers(t, d)
	items, err := d.GetTracks(db.TrackFilter{})
	require.NoError(t, err)
	render := func(jiraLinks, linearLinks bool) string {
		var b strings.Builder
		printTracks(&b, items, d, jiraLinks, linearLinks)
		return b.String()
	}
	linearOnly := render(false, true)
	assert.Contains(t, linearOnly, "[ENG-5 In Progress]")
	assert.NotContains(t, linearOnly, "PROJ-1")
	jiraOnly := render(true, false)
	assert.Contains(t, jiraOnly, "PROJ-1")
	assert.NotContains(t, jiraOnly, "ENG-5")
}
