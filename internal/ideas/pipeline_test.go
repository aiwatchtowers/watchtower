package ideas

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
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
	setIdeasJiraFloorRaw(t, d, jiraAcctID, db.FormatJiraTime(jbase))
	seedJiraIssueIdeas(t, d, jiraAcctID, "WT-1", "WT", "Issue", "Open", "new", "desc", db.FormatJiraTime(jbase.Add(10*time.Second)))

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

	digests, derr := d.ListStreamDigestsAfter(0, "")
	require.NoError(t, derr)
	assert.Empty(t, digests)
}

// TestRunStreamDigests_RunsEvenWhenIdeasDisabled covers the pipeline split:
// RunStreamDigests is stage 1 only (Gmail + Jira pre-digests) and is
// deliberately NOT gated on cfg.Ideas.Enabled — the stream digests feed the
// Desktop Digests tab on their own, independent of whether the consolidator
// is turned on.
func TestRunStreamDigests_RunsEvenWhenIdeasDisabled(t *testing.T) {
	d := newTestDB(t)

	base := time.Now().Add(-time.Hour).Unix()
	acctID := seedGoogleAccount(t, d, float64(base))
	setIdeasEmailFloorRaw(t, d, acctID, float64(base-10))
	iso1 := time.Unix(base+10, 0).UTC().Format(time.RFC3339)
	seedGmailMessageIdeas(t, d, acctID, "m1", "thr-1", "a@example.com", "Ann", "Subj", "an idea about X", iso1)
	emailTag := fmt.Sprintf("gmail:%d:thr-1", acctID)

	jiraAcctID := seedJiraAccount(t, d)
	jbase := time.Now().Add(-time.Hour)
	setIdeasJiraFloorRaw(t, d, jiraAcctID, db.FormatJiraTime(jbase))
	seedJiraIssueIdeas(t, d, jiraAcctID, "WT-1", "WT", "Issue", "Open", "new", "desc", db.FormatJiraTime(jbase.Add(10*time.Second)))
	jiraTag := "jira:WT-1"

	gen := &fakeGen{reply: func(user string) (string, error) {
		if strings.Contains(user, "=== PROJECT") {
			return fmt.Sprintf(`{"topics":[{"title":"t","summary":"s","ideas":[],"decisions":[{"text":"dec","author":"Ann","ref":%q}]}]}`, jiraTag), nil
		}
		return fmt.Sprintf(`{"topics":[{"title":"t","summary":"s","ideas":[{"text":"idea","author":"Ann","ref":%q}],"decisions":[]}]}`, emailTag), nil
	}}
	cfg := testCfg()
	cfg.Ideas.Enabled = false
	p := New(d, cfg, gen, testLogger())

	err := p.RunStreamDigests(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 2, gen.calls, "email and jira stage-1 passes must both run despite the registry being disabled")

	digests, derr := d.ListStreamDigestsAfter(0, "")
	require.NoError(t, derr)
	require.Len(t, digests, 2)
}

// TestRunStreamDigests_JiraErrorSurfaces_EvenWhenEmailSucceeded covers
// RunStreamDigests' own error handling (moved off Run by the pipeline
// split): the jira pass's failure surfaces through RunStreamDigests' return
// value even though the email pass ran first and completed successfully,
// with its row landed.
func TestRunStreamDigests_JiraErrorSurfaces_EvenWhenEmailSucceeded(t *testing.T) {
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
	setIdeasJiraFloorRaw(t, d, jiraAcctID, db.FormatJiraTime(jbase))
	seedJiraIssueIdeas(t, d, jiraAcctID, "WT-1", "WT", "Issue", "Open", "new", "desc", db.FormatJiraTime(jbase.Add(10*time.Second)))

	gen := &fakeGen{reply: func(user string) (string, error) {
		if strings.Contains(user, "=== PROJECT") {
			return "", fmt.Errorf("jira boom")
		}
		return fmt.Sprintf(`{"topics":[{"title":"t","summary":"s","ideas":[{"text":"idea","author":"Ann","ref":%q}],"decisions":[]}]}`, emailTag), nil
	}}
	cfg := testCfg()
	cfg.Ideas.Enabled = true
	p := New(d, cfg, gen, testLogger())

	err := p.RunStreamDigests(context.Background())
	require.Error(t, err)
	assert.Contains(t, err.Error(), "jira boom")
	assert.Equal(t, 2, gen.calls, "email must run before jira's failure surfaces")

	// The email pass's success is not rolled back by the jira pass's failure.
	digests, derr := d.ListStreamDigestsAfter(0, "")
	require.NoError(t, derr)
	require.Len(t, digests, 1)
	assert.Equal(t, "gmail", digests[0].Source)
}

// TestRun_DoesNotInvokeStage1 covers the other half of the pipeline split:
// Run no longer touches the Gmail/Jira stage-1 passes at all — only the
// stage-2 consolidator. A generator that would fail loudly if a stage-1 pass
// called it proves the point: with stage-1 material queued but no
// consolidate-stage material (nothing in stream_digests/digest_topics/
// transcripts yet, since stage 1 never ran), Run must succeed with the
// generator never invoked.
func TestRun_DoesNotInvokeStage1(t *testing.T) {
	d := newTestDB(t)

	base := time.Now().Add(-time.Hour).Unix()
	acctID := seedGoogleAccount(t, d, float64(base))
	setIdeasEmailFloorRaw(t, d, acctID, float64(base-10))
	iso1 := time.Unix(base+10, 0).UTC().Format(time.RFC3339)
	seedGmailMessageIdeas(t, d, acctID, "m1", "thr-1", "a@example.com", "Ann", "Subj", "an idea about X", iso1)

	gen := &fakeGen{reply: func(string) (string, error) {
		t.Fatal("Run must not invoke the stage-1 email/jira generator")
		return "", nil
	}}
	cfg := testCfg()
	cfg.Ideas.Enabled = true
	p := New(d, cfg, gen, testLogger())

	proposed, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Zero(t, proposed)
	assert.Zero(t, gen.calls)

	digests, derr := d.ListStreamDigestsAfter(0, "")
	require.NoError(t, derr)
	assert.Empty(t, digests, "Run must not have produced any stage-1 rows")
}

// TestRunStreamDigestsThenRun_ConsolidatesStage1Material is the end-to-end
// composition check for the split: a RunStreamDigests call (stage 1, its own
// schedule) followed by a separate Run call (stage 2, gated on
// cfg.Ideas.Enabled) still consolidates the material stage 1 produced — the
// two entry points are decoupled but still feed the same registry.
func TestRunStreamDigestsThenRun_ConsolidatesStage1Material(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)

	base := time.Now().Add(-time.Hour).Unix()
	acctID := seedGoogleAccount(t, d, float64(base))
	setIdeasEmailFloorRaw(t, d, acctID, float64(base-10))
	iso1 := time.Unix(base+10, 0).UTC().Format(time.RFC3339)
	seedGmailMessageIdeas(t, d, acctID, "m1", "thr-1", "a@example.com", "Ann", "Subj", "an idea about X", iso1)
	emailTag := fmt.Sprintf("gmail:%d:thr-1", acctID)

	gen := &fakeGen{reply: func(user string) (string, error) {
		switch {
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

	require.NoError(t, p.RunStreamDigests(context.Background()))
	digests, derr := d.ListStreamDigestsAfter(0, "")
	require.NoError(t, derr)
	require.Len(t, digests, 1)

	proposed, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, proposed, "Run's consolidator must consume the material RunStreamDigests just produced")

	_, sFloor, _, ferr := d.GetIdeasFloors()
	require.NoError(t, ferr)
	assert.Equal(t, digests[0].ID, sFloor, "the stream-digest floor must advance past the consolidated material")
}
