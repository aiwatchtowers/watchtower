package inbox

import (
	"context"
	"fmt"
	"testing"
	"time"

	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// linearTestAccount returns the test Linear account, creating it once.
func linearTestAccount(t *testing.T, d *db.DB) int64 {
	t.Helper()
	var id int64
	if err := d.QueryRow(`SELECT id FROM linear_accounts ORDER BY id LIMIT 1`).Scan(&id); err == nil {
		return id
	}
	id, err := d.CreateLinearAccount("")
	require.NoError(t, err)
	return id
}

// seedLinearIssue stores a Linear issue assigned to assigneeID, updated at
// updated (the connector's fixed-width UTC form).
func seedLinearIssue(t *testing.T, d *db.DB, key, assigneeID string, updated time.Time) {
	t.Helper()
	require.NoError(t, d.UpsertLinearIssue(db.LinearIssue{AccountID: linearTestAccount(t, d), ID: "id-" + key, Key: key,
		TeamKey: "ENG", Title: "Linear " + key, StatusCategory: "in_progress", AssigneeID: assigneeID,
		UpdatedAt: db.FormatJiraTime(updated.UTC())}))
}

// seedLinearComment stores a comment on key by authorID mentioning mentioned.
func seedLinearComment(t *testing.T, d *db.DB, key, authorID, body string, created time.Time, mentioned ...string) {
	t.Helper()
	ts := db.FormatJiraTime(created.UTC())
	require.NoError(t, d.UpsertLinearComment(db.LinearComment{AccountID: linearTestAccount(t, d),
		ID: fmt.Sprintf("%s-%s-%d", key, authorID, created.UnixNano()), IssueID: "id-" + key, IssueKey: key,
		AuthorID: authorID, BodyText: body, MentionedUserIDs: mentioned, CreatedAt: ts, UpdatedAt: ts}))
}

func newLinearPipeline(t *testing.T, d *db.DB) *Pipeline {
	t.Helper()
	p := newPipelineForTest(t, d, "U_ME", "me@x.com")
	p.SetOwner(db.Owner{ID: "U_ME", SlackUserID: "U_ME", Email: "me@x.com", LinearUserIDs: []string{"lin-me"}})
	return p
}

func TestLinearDetector_AssignedAndMention(t *testing.T) {
	d := newTestDB(t)
	p := newLinearPipeline(t, d)
	seedLinearIssue(t, d, "ENG-1", "lin-me", time.Now().Add(-1*time.Hour))
	seedLinearIssue(t, d, "ENG-2", "lin-other", time.Now().Add(-1*time.Hour))
	seedLinearComment(t, d, "ENG-2", "lin-bob", "can you look", time.Now().Add(-30*time.Minute), "lin-me")
	seedLinearComment(t, d, "ENG-2", "lin-bob", "not you", time.Now().Add(-20*time.Minute), "lin-x")

	_, _, err := p.Run(context.Background())
	require.NoError(t, err)

	assigned := queryInboxByTrigger(t, d, "linear_assigned")
	require.Len(t, assigned, 1)
	assert.Equal(t, "ENG-1", assigned[0].ChannelID)
	assert.Equal(t, "Linear ENG-1", assigned[0].Snippet)
	assert.Equal(t, "actionable", assigned[0].ItemClass)
	mentions := queryInboxByTrigger(t, d, "linear_comment_mention")
	require.Len(t, mentions, 1)
	assert.Equal(t, "ENG-2", mentions[0].ChannelID)
	assert.Equal(t, "can you look", mentions[0].Snippet)

	// A re-run mints nothing new: one pending item per issue, one per comment.
	_, _, err = p.Run(context.Background())
	require.NoError(t, err)
	assert.Len(t, queryInboxByTrigger(t, d, "linear_assigned"), 1)
	assert.Len(t, queryInboxByTrigger(t, d, "linear_comment_mention"), 1)
}

// The owner's own comment bumps the issue's updated_at; that bump is not a
// new assignment signal (the Jira rule).
func TestLinearDetector_OwnCommentBumpIsNotNews(t *testing.T) {
	d := newTestDB(t)
	p := newLinearPipeline(t, d)
	now := time.Now().Add(-10 * time.Minute)
	seedLinearIssue(t, d, "ENG-3", "lin-me", now.Add(5*time.Second))
	seedLinearComment(t, d, "ENG-3", "lin-me", "done on my side", now)

	_, _, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Empty(t, queryInboxByTrigger(t, d, "linear_assigned"))
}

// Without a Linear id the owner is recognised through the Slack bridge
// (assignee_slack_id) and the Linear user map.
func TestLinearDetector_SlackBridgeAndUserMap(t *testing.T) {
	d := newTestDB(t)
	p := newPipelineForTest(t, d, "U_ME", "me@x.com")
	_, err := d.Exec(`INSERT INTO linear_user_map (linear_user_id, email, slack_user_id, match_method)
		VALUES ('lin-mapped', 'me@x.com', 'U_ME', 'email')`)
	require.NoError(t, err)
	seedLinearIssue(t, d, "ENG-4", "lin-mapped", time.Now().Add(-1*time.Hour))
	seedLinearComment(t, d, "ENG-4", "lin-bob", "ping", time.Now().Add(-30*time.Minute), "lin-mapped")

	_, _, err = p.Run(context.Background())
	require.NoError(t, err)
	assert.Len(t, queryInboxByTrigger(t, d, "linear_assigned"), 1)
	assert.Len(t, queryInboxByTrigger(t, d, "linear_comment_mention"), 1)
}

func TestInbox02_AutoResolveLinearOnUserComment(t *testing.T) {
	// BEHAVIOR INBOX-02 — see docs/inventory/inbox-pulse.md
	// User comments on a Linear issue → linear_comment_mention and
	// linear_assigned auto-resolve (the Jira rule, extended to Linear).
	// Do not weaken or remove without explicit owner approval.
	d := newTestDB(t)
	p := newLinearPipeline(t, d)
	seedLinearIssue(t, d, "ENG-5", "lin-me", time.Now().Add(-2*time.Hour))
	seedLinearComment(t, d, "ENG-5", "lin-bob", "hey", time.Now().Add(-30*time.Minute), "lin-me")
	_, _, err := p.Run(context.Background())
	require.NoError(t, err)
	require.Len(t, queryInboxByTrigger(t, d, "linear_comment_mention"), 1)
	require.Len(t, queryInboxByTrigger(t, d, "linear_assigned"), 1)

	seedLinearComment(t, d, "ENG-5", "lin-me", "got it", time.Now().Add(time.Minute))
	_, _, err = p.Run(context.Background())
	require.NoError(t, err)
	for _, trigger := range []string{"linear_comment_mention", "linear_assigned"} {
		items := queryInboxByTrigger(t, d, trigger)
		require.Len(t, items, 1, trigger)
		assert.Equal(t, "resolved", items[0].Status, trigger)
		assert.Equal(t, "User commented on issue", items[0].ResolvedReason, trigger)
	}
}

// TestInbox09_LinearReadErrorFreezesWatermark: a failed Linear read — the
// mention scan, the owner's own comments, or the owner's Linear ids — or a
// failed insert of a Linear item is a detector error and freezes the
// watermark; the Jira detector still runs.
func TestInbox09_LinearReadErrorFreezesWatermark(t *testing.T) {
	// BEHAVIOR INBOX-09 — see docs/inventory/inbox-pulse.md
	// Do not weaken or remove without explicit owner approval.
	cases := map[string]struct {
		breakIt string
		wantErr string
	}{
		"mention read":  {`DROP VIEW tracker_comments`, "linear comment mentions"},
		"own comments":  {`DROP INDEX idx_linear_comments_issue_author; ALTER TABLE linear_comments RENAME COLUMN author_id TO author_gone`, "linear"},
		"identity read": {`DROP TABLE linear_user_map`, "linear ids"},
		"assigned write": {`CREATE TRIGGER fail_linear BEFORE INSERT ON inbox_items WHEN NEW.trigger_type = 'linear_assigned'
			BEGIN SELECT RAISE(ABORT, 'disk I/O error'); END`, "linear_assigned"},
		"mention write": {`CREATE TRIGGER fail_linear BEFORE INSERT ON inbox_items WHEN NEW.trigger_type = 'linear_comment_mention'
			BEGIN SELECT RAISE(ABORT, 'disk I/O error'); END`, "linear_comment_mention"},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			d := newTestDB(t)
			p := newLinearPipeline(t, d)
			p.SetOwner(db.Owner{ID: "U_ME", SlackUserID: "U_ME", Email: "me@x.com", JiraAccountID: "acc-me", LinearUserIDs: []string{"lin-me"}})
			seedLinearIssue(t, d, "ENG-6", "lin-me", time.Now().Add(-1*time.Hour))
			seedLinearComment(t, d, "ENG-7", "lin-bob", "ping", time.Now().Add(-30*time.Minute), "lin-me")
			seedJiraIssue(t, d, "WT-6", "acc-me", time.Now().Add(-1*time.Hour))
			const frozen = 1000.0
			require.NoError(t, d.SetInboxLastProcessedTS(frozen))
			_, err := d.Exec(tc.breakIt)
			require.NoError(t, err)

			_, _, err = p.Run(context.Background())
			require.Error(t, err)
			assert.Contains(t, err.Error(), tc.wantErr)
			ts, err := d.GetInboxLastProcessedTS()
			require.NoError(t, err)
			assert.Equal(t, frozen, ts)
			assert.Len(t, queryInboxByTrigger(t, d, "jira_assigned"), 1, "the Jira detector still surfaces")
		})
	}
}
