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
	"watchtower/internal/digest"
)

// stage1Gen answers stage-1 calls with one idea citing whatever gmail thread
// or jira issue tag the prompt carries, records each prompt, and fails a
// consolidator call loudly.
type stage1Gen struct {
	prompts []string
}

func (g *stage1Gen) Generate(_ context.Context, _, user, _ string) (string, *digest.Usage, string, error) {
	if strings.Contains(user, "=== REGISTRY ===") {
		return "", nil, "", fmt.Errorf("no consolidator call expected")
	}
	g.prompts = append(g.prompts, user)
	return `{"topics":[{"title":"t","summary":"s","ideas":[],"decisions":[{"text":"d","author":"Ann","ref":"x"}]}]}`, &digest.Usage{}, "", nil
}

func (g *stage1Gen) saw(s string) bool {
	for _, p := range g.prompts {
		if strings.Contains(p, s) {
			return true
		}
	}
	return false
}

// R28: only the given account's mail is digested, the other account's floor
// is untouched, and the account's floor is restored to max(saved, reached).
func TestBackfillEmail_ScopedToOneAccount(t *testing.T) {
	d := newTestDB(t)
	now := time.Now()
	from, to := now.Add(-72*time.Hour), now.Add(-24*time.Hour)
	saved := float64(now.Add(-time.Hour).Unix())

	a := seedGoogleAccount(t, d, float64(now.Unix()))
	b := seedGoogleAccount(t, d, float64(now.Unix()))
	setIdeasEmailFloorRaw(t, d, a, saved)
	bFloor := float64(from.Add(-time.Hour).Unix()) // B has pending mail of its own: an unscoped pass would mine it
	setIdeasEmailFloorRaw(t, d, b, bFloor)
	inWindow := from.Add(time.Hour).UTC().Format(time.RFC3339)
	seedGmailMessageIdeas(t, d, a, "ma", "thr-a", "x@example.com", "Ann", "Subj", "alpha mail", inWindow)
	seedGmailMessageIdeas(t, d, b, "mb", "thr-b", "y@example.com", "Bob", "Subj", "bravo mail", inWindow)

	gen := &stage1Gen{}
	p := New(d, backfillCfg(), gen, testLogger())
	complete, err := p.BackfillEmail(context.Background(), a, from, to)
	require.NoError(t, err)
	assert.True(t, complete)
	assert.True(t, gen.saw("alpha mail"), "account A's mail is digested")
	assert.False(t, gen.saw("bravo mail"), "account B's mail is not")

	fa, err := d.IdeasEmailFloor(a)
	require.NoError(t, err)
	assert.Equal(t, saved, fa, "A's floor is restored to max(saved, reached)")
	fb, err := d.IdeasEmailFloor(b)
	require.NoError(t, err)
	assert.Equal(t, bFloor, fb, "B's floor is untouched")

	// A second call over the same window re-renders A's mail: the floor is
	// lowered again, so the window is mined again (cost, not correctness —
	// IDEA-05 dedups the re-mined refs downstream).
	n := len(gen.prompts)
	_, err = p.BackfillEmail(context.Background(), a, from, to)
	require.NoError(t, err)
	assert.Equal(t, n+1, len(gen.prompts), "a repeat pays one stage-1 call for the window again")
}

// A floor already below the window is never raised: the mail between it and
// the window start stays minable.
func TestBackfillEmail_KeepsALowerFloor(t *testing.T) {
	d := newTestDB(t)
	now := time.Now()
	from, to := now.Add(-72*time.Hour), now.Add(-24*time.Hour)
	a := seedGoogleAccount(t, d, float64(now.Unix()))
	low := float64(from.Add(-48 * time.Hour).Unix())
	setIdeasEmailFloorRaw(t, d, a, low)
	seedGmailMessageIdeas(t, d, a, "m0", "thr-0", "x@example.com", "Ann", "Subj", "below the window",
		from.Add(-24*time.Hour).UTC().Format(time.RFC3339))

	gen := &stage1Gen{}
	p := New(d, backfillCfg(), gen, testLogger())
	_, err := p.BackfillEmail(context.Background(), a, from, to)
	require.NoError(t, err)
	assert.True(t, gen.saw("below the window"), "mined, not skipped")
}

// R29: only the given Jira account's issues are digested, the other
// account's floor is untouched, and the floor is restored.
func TestBackfillJira_ScopedToOneAccount(t *testing.T) {
	d := newTestDB(t)
	now := time.Now()
	from, to := now.Add(-72*time.Hour), now.Add(-24*time.Hour)
	saved := db.FormatJiraTime(now.Add(-time.Hour))

	a := seedJiraAccount(t, d)
	b := seedJiraAccount(t, d)
	setIdeasJiraFloorRaw(t, d, a, saved)
	bFloor := db.FormatJiraTime(from.Add(-time.Hour)) // B has pending issues of its own: an unscoped pass would mine them
	setIdeasJiraFloorRaw(t, d, b, bFloor)
	upd := db.FormatJiraTime(from.Add(2 * time.Hour))
	seedJiraIssueIdeas(t, d, a, "AA-1", "AA", "Alpha caching", "Open", "new", "alpha issue", upd)
	seedJiraIssueIdeas(t, d, b, "BB-1", "BB", "Bravo caching", "Open", "new", "bravo issue", upd)

	gen := &stage1Gen{}
	p := New(d, backfillCfg(), gen, testLogger())
	complete, err := p.BackfillJira(context.Background(), a, from, to)
	require.NoError(t, err)
	assert.True(t, complete)
	assert.True(t, gen.saw("AA-1"), "account A's issue is digested")
	assert.False(t, gen.saw("BB-1"), "account B's issue is not")

	fa, err := d.IdeasJiraFloor(a)
	require.NoError(t, err)
	assert.Equal(t, saved, fa, "A's floor is restored to max(saved, reached)")
	fb, err := d.IdeasJiraFloor(b)
	require.NoError(t, err)
	assert.Equal(t, bFloor, fb, "B's floor is untouched")
}

// An uninitialized Jira floor ends at the reached value, so the forward
// stage-1 pass continues from the window instead of re-initializing at now.
func TestBackfillJira_UninitializedFloorKeepsReached(t *testing.T) {
	d := newTestDB(t)
	now := time.Now()
	from, to := now.Add(-72*time.Hour), now.Add(-24*time.Hour)
	a := seedJiraAccount(t, d)
	upd := db.FormatJiraTime(from.Add(2 * time.Hour))
	seedJiraIssueIdeas(t, d, a, "AA-1", "AA", "Alpha", "Open", "new", "alpha issue", upd)

	p := New(d, backfillCfg(), &stage1Gen{}, testLogger())
	_, err := p.BackfillJira(context.Background(), a, from, to)
	require.NoError(t, err)
	fa, err := d.IdeasJiraFloor(a)
	require.NoError(t, err)
	assert.NotEmpty(t, fa)
}
