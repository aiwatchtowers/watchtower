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
// aggregation: all three stages must each get their turn — including the
// consolidator, which now always runs regardless of a stage-1 failure (fix
// round 1 Finding — Run must not starve consolidation of every source just
// because one Jira account is broken) — and a jira-pass failure must surface
// through Run's return value even though the email pass completed
// successfully and its row landed (round-1 review Finding 2).
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
		switch {
		case strings.Contains(user, "=== PROJECT"):
			return "", fmt.Errorf("jira boom")
		case strings.Contains(user, "=== NEW MATERIAL ==="):
			return `{"ops":[]}`, nil // the consolidate call — nothing to propose in this test
		default:
			return fmt.Sprintf(`{"topics":[{"title":"t","summary":"s","ideas":[{"text":"idea","author":"Ann","ref":%q}],"decisions":[]}]}`, emailTag), nil
		}
	}}
	cfg := testCfg()
	cfg.Ideas.Enabled = true
	p := New(d, cfg, gen, testLogger())

	proposed, err := p.Run(context.Background())
	require.Error(t, err)
	assert.Contains(t, err.Error(), "jira boom")
	assert.Zero(t, proposed)
	assert.Equal(t, 3, gen.calls, "email, jira, and consolidate must all have made their Generate call")

	// The email pass's success is not rolled back by the jira pass's failure.
	digests, derr := d.ListStreamDigestsAfter(0)
	require.NoError(t, derr)
	require.Len(t, digests, 1)
	assert.Equal(t, "gmail", digests[0].Source)
}

// TestRun_ConsolidateRunsDespiteStage1Error_ConsumesHealthySourceMaterial
// covers the fix round 1 finding directly: a persistent Jira failure must
// never starve consolidation of a DIFFERENT, healthy source's material — the
// consolidator still runs this cycle and still consumes the gmail stream
// digest that the (successful) email pass just produced, advancing only the
// stream-digest floor (IDEA-01: each source's floor is honest on its own).
func TestRun_ConsolidateRunsDespiteStage1Error_ConsumesHealthySourceMaterial(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)

	base := time.Now().Add(-time.Hour).Unix()
	acctID := seedGoogleAccount(t, d, float64(base))
	setIdeasEmailFloorRaw(t, d, acctID, float64(base-10))
	iso1 := time.Unix(base+10, 0).UTC().Format(time.RFC3339)
	seedGmailMessageIdeas(t, d, acctID, "m1", "thr-1", "a@example.com", "Ann", "Subj", "an idea about X", iso1)
	emailTag := fmt.Sprintf("gmail:%d:thr-1", acctID)

	jiraAcctID := seedJiraAccount(t, d)
	jbase := time.Now().Add(-time.Hour)
	setIdeasJiraFloorRaw(t, d, jiraAcctID, jbase.Format(jiraFloorInitLayout))
	seedJiraIssueIdeas(t, d, jiraAcctID, "WT-1", "WT", "Issue", "Open", "new", "desc", jbase.Add(10*time.Second).Format(jiraFloorInitLayout))

	gen := &fakeGen{reply: func(user string) (string, error) {
		switch {
		case strings.Contains(user, "=== PROJECT"):
			return "", fmt.Errorf("jira boom")
		case strings.Contains(user, "=== NEW MATERIAL ==="):
			return fmt.Sprintf(`{"ops":[{"op":"new_idea","title":"Idea from email","essence":"e",
				"mentions":[{"source":"gmail","ref":%q,"quote":"idea","author":"Ann","said_at":"2026-08-01T00:00:00Z"}]}]}`, emailTag), nil
		default:
			return fmt.Sprintf(`{"topics":[{"title":"t","summary":"s","ideas":[{"text":"idea","author":"Ann","ref":%q}],"decisions":[]}]}`, emailTag), nil
		}
	}}
	cfg := testCfg()
	cfg.Ideas.Enabled = true
	p := New(d, cfg, gen, testLogger())

	proposed, err := p.Run(context.Background())
	require.Error(t, err)
	assert.Contains(t, err.Error(), "jira boom")
	assert.Equal(t, 1, proposed, "consolidate must still run and consume the healthy email material")
	assert.Equal(t, 3, gen.calls)

	dFloor, sFloor, tFloor, ferr := d.GetIdeasFloors()
	require.NoError(t, ferr)
	assert.Zero(t, dFloor)
	assert.Zero(t, tFloor)

	digests, derr := d.ListStreamDigestsAfter(0)
	require.NoError(t, derr)
	require.Len(t, digests, 1)
	assert.Equal(t, digests[0].ID, sFloor, "the stream-digest floor must advance past the healthy gmail material")
}
