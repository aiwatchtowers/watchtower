package inbox

import (
	"bytes"
	"context"
	"log"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// TestOwner01_InboxRunsForGoogleOnlyOwner: an install with only a Google
// account has an owner (the resolver's Google rung), so Run must not skip —
// the Calendar detector matches the owner's email. Before the resolver the
// whole Run was gated on a Slack user id and produced nothing here.
func TestOwner01_InboxRunsForGoogleOnlyOwner(t *testing.T) {
	d := newTestDB(t)
	_, err := d.CreateGoogleAccount(db.GoogleAccount{Email: "me@x.com", CalendarEnabled: true})
	require.NoError(t, err)
	seedCalendarEvent(t, d, "evt-g", "Planning", `[{"email":"me@x.com","rsvp_status":"needsAction"}]`, "confirmed",
		time.Now().Add(-10*time.Minute), time.Now().Add(-10*time.Minute))

	p := New(d, testConfig(), nil, log.Default())
	created, _, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, created)
	assert.Len(t, queryInboxByTrigger(t, d, "calendar_invite"), 1,
		"a Google-only owner's pending RSVP must reach the inbox")
}

// TestOwner01_InboxJiraMentionFromOwnerJiraAccountID: a Jira-only owner (the
// connecting person's /myself id on jira_accounts, no jira_user_map row and
// no Slack account) must still get comment-mention detection and the
// INBOX-02 auto-resolve, both keyed on Owner.JiraAccountID.
func TestOwner01_InboxJiraMentionFromOwnerJiraAccountID(t *testing.T) {
	d := newTestDB(t)
	acct := db.SeedTestJiraAccount(t, d)
	require.NoError(t, d.SetJiraAccountOwner(acct, "acc-9", "me@x.com", "Me"))
	seedJiraIssue(t, d, "WT-9", "acc-bob", time.Now().Add(-1*time.Hour))
	seedJiraComment(t, d, "WT-9", "acc-bob", "hey [~acc-9] please look", time.Now().Add(-30*time.Minute))

	p := New(d, testConfig(), nil, log.Default())
	created, _, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, created)
	got := queryInboxByTrigger(t, d, "jira_comment_mention")
	require.Len(t, got, 1, "the mention of the owner's own Atlassian id must be detected")
	assert.Equal(t, "WT-9", got[0].ChannelID)

	seedJiraComment(t, d, "WT-9", "acc-9", "on it", time.Now())
	_, resolved, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, resolved, "the owner's own comment must auto-resolve the mention (INBOX-02)")
}

// TestOwner01_InboxSkipsWithoutOwner: no connected account at all → Run is a
// clean (0, 0, nil) skip that logs why, and no detector runs (a detector
// that ran would fail on the dropped jira_issues table).
func TestOwner01_InboxSkipsWithoutOwner(t *testing.T) {
	d := newTestDB(t)
	_, err := d.Exec(`DROP TABLE jira_issues`)
	require.NoError(t, err)

	var buf bytes.Buffer
	p := New(d, testConfig(), nil, log.New(&buf, "", 0))
	created, resolved, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 0, created)
	assert.Equal(t, 0, resolved)
	assert.Contains(t, buf.String(), "inbox: no owner identity, skipping")
}

// TestOwner01_AutoResolveJiraKeepsEveryMappedID: auto-resolve (INBOX-02)
// counts a comment by any Atlassian id mapped to the owner's Slack id, not
// only Owner.JiraAccountID — an item detected before the resolver existed may
// have been matched through any mapped id, and narrowing to one id would stop
// it from ever auto-resolving.
func TestOwner01_AutoResolveJiraKeepsEveryMappedID(t *testing.T) {
	d := newTestDB(t)
	seedJiraIssue(t, d, "WT-5", "acc-bob", time.Now().Add(-1*time.Hour))
	require.NoError(t, d.UpsertJiraUserMap(db.JiraUserMap{JiraAccountID: "acc-old", SlackUserID: "1:U_ME", DisplayName: "Me"}))
	_, err := d.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, status, priority, item_class, created_at, updated_at)
		VALUES ('WT-5', '1.0', 'WT-5', 'jira_comment_mention', 'pending', 'medium', 'actionable', ?, ?)`,
		time.Now().Add(-10*time.Minute).UTC().Format(time.RFC3339), time.Now().Add(-10*time.Minute).UTC().Format(time.RFC3339))
	require.NoError(t, err)
	seedJiraComment(t, d, "WT-5", "acc-old", "done", time.Now())

	p := New(d, testConfig(), nil, log.Default())
	p.SetOwner(db.Owner{ID: "1:U_ME", SlackUserID: "1:U_ME", JiraAccountID: "acc-new"})
	_, resolved, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, resolved, "a comment by a mapped id other than Owner.JiraAccountID still resolves the item")
}

// TestOwner01_JiraMentionOfAnyMappedIDDetected: detection matches every
// Atlassian id that is the owner — Owner.JiraAccountID plus every id
// jira_user_map maps to the owner's Slack id — not only the resolver's one id.
func TestOwner01_JiraMentionOfAnyMappedIDDetected(t *testing.T) {
	d := newTestDB(t)
	seedJiraIssue(t, d, "WT-6", "acc-bob", time.Now().Add(-1*time.Hour))
	require.NoError(t, d.UpsertJiraUserMap(db.JiraUserMap{JiraAccountID: "acc-a", SlackUserID: "1:U_ME"}))
	require.NoError(t, d.UpsertJiraUserMap(db.JiraUserMap{JiraAccountID: "acc-b", SlackUserID: "1:U_ME"}))
	seedJiraComment(t, d, "WT-6", "acc-bob", "ping [~acc-b]", time.Now().Add(-30*time.Minute))

	n, err := DetectJira(context.Background(), d, db.Owner{ID: "1:U_ME", SlackUserID: "1:U_ME", JiraAccountID: "acc-a"}, time.Now().Add(-2*time.Hour))
	require.NoError(t, err)
	assert.Equal(t, 1, n)
	assert.Len(t, queryInboxByTrigger(t, d, "jira_comment_mention"), 1,
		"a mention of a mapped id other than Owner.JiraAccountID must be detected")
}
