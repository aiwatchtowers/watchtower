package inbox

import (
	"context"
	"log"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// TestE2E_JiraMentionFlow verifies the full Jira-mention → inbox item path.
//
// Flow:
//  1. Seed a Jira issue and a jira_comment that mentions the current user.
//  2. Run the pipeline — expects a jira_comment_mention inbox item to be created.
func TestE2E_JiraMentionFlow(t *testing.T) {
	d := newTestDB(t)

	const (
		userID   = "alice"
		issueKey = "WT-42"
	)
	const senderID = "bob"

	seedWorkspaceAndUser(t, d, userID)

	// Seed the Jira issue assigned to alice so the jira_assigned detector fires.
	seedJiraIssue(t, d, issueKey, userID, time.Now().Add(-2*time.Hour))

	// Map alice's Slack id to her Atlassian account id — a [~mention] embeds
	// the Atlassian id, not the Slack id (see INBOX-02 reconciliation).
	require.NoError(t, d.UpsertJiraUserMap(db.JiraUserMap{JiraAccountID: "alice", SlackUserID: userID, DisplayName: "Alice"}))

	// Seed a Jira comment by bob mentioning alice ([~alice]).
	seedJiraComment(t, d, issueKey, senderID, "hey [~alice] please review", time.Now().Add(-30*time.Minute))

	p := New(d, testConfig(), nil, log.Default())
	p.SetOwner(db.Owner{ID: userID, SlackUserID: userID, Email: "alice@x.com"})

	created, _, err := p.Run(context.Background())
	require.NoError(t, err)
	// At minimum the jira_comment_mention item must have been created.
	require.Greater(t, created, 0, "expected at least one inbox item created")

	// Note: the Jira detector sets sender_user_id = issue key (routing/display convention).
	var senderUserID string
	err = d.QueryRow(`SELECT sender_user_id FROM inbox_items WHERE trigger_type='jira_comment_mention' LIMIT 1`).
		Scan(&senderUserID)
	require.NoError(t, err, "jira_comment_mention item should exist")
	assert.Equal(t, issueKey, senderUserID)
}
