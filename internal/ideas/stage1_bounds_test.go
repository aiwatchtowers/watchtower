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

// --- IDEA-01: an affirmative "topics" key is required at stage 1 ----------

// TestIdeas01_EmailReplyWithoutTopicsKey_NoRowFloorUnchanged mirrors the
// consolidator's affirmative-field rule one level up: a reply that omits
// "topics" answered nothing, so no stream_digests row is written and the
// account's floor stays put for a retry.
func TestIdeas01_EmailReplyWithoutTopicsKey_NoRowFloorUnchanged(t *testing.T) {
	d := newTestDB(t)
	base := time.Now().Add(-time.Hour).Unix()
	acctID := seedGoogleAccount(t, d, float64(base))
	setIdeasEmailFloorRaw(t, d, acctID, float64(base-10))
	seedGmailMessageIdeas(t, d, acctID, "m1", "thr-1", "a@example.com", "Ann", "Subject", "Body",
		time.Unix(base+10, 0).UTC().Format(time.RFC3339))

	gen := &fakeGen{reply: func(string) (string, error) { return `{}`, nil }}
	p := New(d, testCfg(), gen, testLogger())
	require.Error(t, p.runEmailDigests(context.Background(), time.Time{}))

	digests, err := d.ListStreamDigestsAfter(0, "")
	require.NoError(t, err)
	assert.Empty(t, digests)

	floor, err := d.IdeasEmailFloor(acctID)
	require.NoError(t, err)
	assert.Equal(t, float64(base-10), floor)
}

// TestIdeas01_JiraReplyWithoutTopicsKey_NoRowFloorUnchanged is the Jira half
// of the same rule.
func TestIdeas01_JiraReplyWithoutTopicsKey_NoRowFloorUnchanged(t *testing.T) {
	d := newTestDB(t)
	acctID := seedJiraAccount(t, d)
	setIdeasJiraFloorRaw(t, d, acctID, "2026-08-01T00:00:00.000+0000")
	seedJiraIssueIdeas(t, d, acctID, "WT-1", "WT", "Summary", "Open", "new", "Description", "2026-08-02T00:00:00.000+0000")

	gen := &fakeGen{reply: func(string) (string, error) { return `{}`, nil }}
	p := New(d, testCfg(), gen, testLogger())
	require.Error(t, p.runJiraDigests(context.Background(), time.Time{}))

	digests, err := d.ListStreamDigestsAfter(0, "")
	require.NoError(t, err)
	assert.Empty(t, digests)

	floor, err := d.IdeasJiraFloor(acctID)
	require.NoError(t, err)
	assert.Equal(t, "2026-08-01T00:00:00.000+0000", floor)
}

// --- Stage-1 input bounds -------------------------------------------------

// TestRenderEmailBlock_BudgetDropsThreadFromBlockAndTags proves the email
// block is bounded and that a dropped thread also loses its tag: a candidate
// can never validate against a thread the model was never shown.
func TestRenderEmailBlock_BudgetDropsThreadFromBlockAndTags(t *testing.T) {
	threads := []emailThread{
		{threadID: "thr-1", subject: "First", participants: []string{"Ann"},
			messages: []db.GmailExtractMessage{{BodyText: "short body"}}},
		{threadID: "thr-2", subject: "Second", participants: []string{"Bob"},
			messages: []db.GmailExtractMessage{{BodyText: strings.Repeat("y ", 400)}}},
	}

	full, fullTags := renderEmailBlock(7, threads, 100000)
	require.Contains(t, full, "thr-1")
	require.Contains(t, full, "thr-2")
	require.Len(t, fullTags, 2)

	firstLineLen := strings.Index(full, "\n") + 1
	bounded, tags := renderEmailBlock(7, threads, firstLineLen)
	assert.Contains(t, bounded, "thr-1")
	assert.NotContains(t, bounded, "thr-2")
	assert.LessOrEqual(t, len(bounded), firstLineLen)
	assert.Equal(t, map[string]bool{"gmail:7:thr-1": true}, tags,
		"a thread that never made it into the block must not be citable")
}

// TestRenderJiraBlock_CapsCommentsPerIssue keeps one hot ticket from
// dominating the prompt: only the newest maxCommentsPerIssue comments render.
func TestRenderJiraBlock_CapsCommentsPerIssue(t *testing.T) {
	issues := []db.JiraIssue{{Key: "WT-1", ProjectKey: "WT", Summary: "s", Status: "Open"}}
	var comments []db.JiraComment
	for i := 0; i < maxCommentsPerIssue+10; i++ {
		comments = append(comments, db.JiraComment{IssueKey: "WT-1", Author: "Ann", BodyText: fmt.Sprintf("comment-%02d", i)})
	}

	block, tags := renderJiraBlock(issues, map[string][]db.JiraComment{"WT-1": comments}, 100000)
	assert.Equal(t, maxCommentsPerIssue, strings.Count(block, "  - Ann: "))
	assert.NotContains(t, block, "comment-00", "the oldest comments are the ones dropped")
	assert.Contains(t, block, fmt.Sprintf("comment-%02d", maxCommentsPerIssue+9), "the newest comment survives")
	assert.Equal(t, map[string]bool{"WT-1": true}, tags)
}

// TestRenderJiraBlock_BudgetDropsIssueFromBlockAndTags is the Jira twin of the
// email bound: an issue left out for budget is left out of the tag set too.
func TestRenderJiraBlock_BudgetDropsIssueFromBlockAndTags(t *testing.T) {
	issues := []db.JiraIssue{
		{Key: "WT-1", ProjectKey: "WT", Summary: "small", Status: "Open"},
		{Key: "WT-2", ProjectKey: "WT", Summary: strings.Repeat("z", 400), Status: "Open"},
	}

	full, fullTags := renderJiraBlock(issues, nil, 100000)
	require.Contains(t, full, "WT-2")
	require.Len(t, fullTags, 2)

	bounded, tags := renderJiraBlock(issues, nil, len(full)-100)
	assert.Contains(t, bounded, "WT-1")
	assert.NotContains(t, bounded, "WT-2")
	assert.Equal(t, map[string]bool{"WT-1": true}, tags)
}

// --- Owner preferences ----------------------------------------------------

// TestBuildPreferencesBlock_NegativeRatingOutranksActiveStatus covers the
// bucket order: an explicit thumbs-down is the owner speaking, so it decides
// the bucket even when the idea is still 'active'. Filing it under
// LIKED/APPROVED would teach the consolidator the exact opposite of what the
// owner said.
func TestBuildPreferencesBlock_NegativeRatingOutranksActiveStatus(t *testing.T) {
	d := newTestDB(t)
	seedIdeaRow(t, d, db.Idea{
		Kind: "idea", Title: "Weekly metrics email", Essence: "e", Status: "active",
		OwnerRating: -1, RatingComment: "too noisy",
	})

	block := buildPreferencesBlock(d)
	require.Contains(t, block, "DISLIKED/REJECTED:")
	assert.NotContains(t, block, "LIKED/APPROVED:")
	assert.Contains(t, block, "Weekly metrics email (too noisy)")
}

// TestBuildPreferencesBlock_PositiveRatingOutranksRejectedStatus is the
// symmetric case, so the rule is pinned in both directions.
func TestBuildPreferencesBlock_PositiveRatingOutranksRejectedStatus(t *testing.T) {
	d := newTestDB(t)
	seedIdeaRow(t, d, db.Idea{
		Kind: "idea", Title: "Vendor switch", Essence: "e", Status: "rejected", OwnerRating: 1,
	})

	block := buildPreferencesBlock(d)
	require.Contains(t, block, "LIKED/APPROVED:")
	assert.NotContains(t, block, "DISLIKED/REJECTED:")
}
