package ideas

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestRun_IdeasDisabled_ShortCircuits covers Run's cfg.Ideas.Enabled gate:
// with material queued for both the email and jira passes, a disabled
// registry must make zero Generate calls and write zero rows (round-1
// review Finding 2 — Run itself previously had no test coverage at all).
func TestRun_IdeasDisabled_ShortCircuits(t *testing.T) {
	d := newTestDB(t)
	base := time.Now().Add(-time.Hour).Unix()
	acctID := seedGoogleAccount(t, d, float64(base))
	setIdeasEmailFloorRaw(t, d, acctID, float64(base-10))
	iso1 := time.Unix(base+10, 0).UTC().Format(time.RFC3339)
	seedGmailMessageIdeas(t, d, acctID, "m1", "thr-1", "a@example.com", "Ann", "Subj", "body", iso1)

	jiraAcctID := seedJiraAccount(t, d)
	jbase := time.Now().Add(-time.Hour)
	setIdeasJiraFloorRaw(t, d, jiraAcctID, jbase.Format(jiraFloorInitLayout))
	seedJiraIssueIdeas(t, d, jiraAcctID, "WT-1", "WT", "Issue", "Open", "new", "desc", jbase.Add(10*time.Second).Format(jiraFloorInitLayout))

	gen := &fakeGen{reply: func(string) (string, error) {
		t.Fatal("generator must not be called when the ideas registry is disabled")
		return "", nil
	}}
	cfg := testCfg()
	cfg.Ideas.Enabled = false
	p := New(d, cfg, gen, testLogger())

	proposed, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Zero(t, proposed)
	assert.Zero(t, gen.calls)

	digests, derr := d.ListStreamDigestsAfter(0)
	require.NoError(t, derr)
	assert.Empty(t, digests)
}

// TestRun_JiraErrorSurfaces_EvenWhenEmailSucceeded covers Run's error
// aggregation: both passes must each get their turn, and a jira-pass failure
// must surface through Run's return value even though the email pass
// completed successfully and its row landed (round-1 review Finding 2).
func TestRun_JiraErrorSurfaces_EvenWhenEmailSucceeded(t *testing.T) {
	d := newTestDB(t)

	// Email side: fully set up to succeed for real.
	base := time.Now().Add(-time.Hour).Unix()
	acctID := seedGoogleAccount(t, d, float64(base))
	setIdeasEmailFloorRaw(t, d, acctID, float64(base-10))
	iso1 := time.Unix(base+10, 0).UTC().Format(time.RFC3339)
	seedGmailMessageIdeas(t, d, acctID, "m1", "thr-1", "a@example.com", "Ann", "Subj", "an idea about X", iso1)
	emailTag := fmt.Sprintf("gmail:%d:thr-1", acctID)

	// Jira side: set up to fail.
	jiraAcctID := seedJiraAccount(t, d)
	jbase := time.Now().Add(-time.Hour)
	setIdeasJiraFloorRaw(t, d, jiraAcctID, jbase.Format(jiraFloorInitLayout))
	seedJiraIssueIdeas(t, d, jiraAcctID, "WT-1", "WT", "Issue", "Open", "new", "desc", jbase.Add(10*time.Second).Format(jiraFloorInitLayout))

	gen := &fakeGen{reply: func(user string) (string, error) {
		if strings.Contains(user, "=== PROJECT") {
			return "", fmt.Errorf("jira boom")
		}
		return fmt.Sprintf(`{"topics":[{"title":"t","summary":"s","ideas":[{"text":"idea","author":"Ann","ref":%q}],"decisions":[]}]}`, emailTag), nil
	}}
	cfg := testCfg()
	cfg.Ideas.Enabled = true
	p := New(d, cfg, gen, testLogger())

	proposed, err := p.Run(context.Background())
	require.Error(t, err)
	assert.Contains(t, err.Error(), "jira boom")
	assert.Zero(t, proposed)
	assert.Equal(t, 2, gen.calls, "both passes must have made their Generate call")

	// The email pass's success is not rolled back by the jira pass's failure.
	digests, derr := d.ListStreamDigestsAfter(0)
	require.NoError(t, derr)
	require.Len(t, digests, 1)
	assert.Equal(t, "gmail", digests[0].Source)
}
