package ai

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

// The tracker section documents the neutral views and the issue links table;
// the Jira section no longer documents the retired jira_slack_links.
func TestTrackerPromptSection_DocumentsTheViews(t *testing.T) {
	got := TrackerPromptSection()
	for _, want := range []string{"tracker_issues", "tracker_comments", "tracker_history", "tracker_iterations",
		"tracker_people", "tracker_accounts", "issue_slack_links", "priority_rank"} {
		assert.Contains(t, got, want)
	}
	assert.NotContains(t, JiraPromptSection(), "jira_slack_links")
}
