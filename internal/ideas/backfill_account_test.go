package ideas

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
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

// floorWatchGen answers stage-1 calls like stage1Gen and, at each call,
// records what the account's stored floors read — what a process killed at
// that moment would leave behind for the forward run.
type floorWatchGen struct {
	stage1Gen
	d         *db.DB
	acct      int64
	emailSeen []float64
	jiraSeen  []string
}

func (g *floorWatchGen) Generate(ctx context.Context, sys, user, model string) (string, *digest.Usage, string, error) {
	if f, err := g.d.IdeasEmailFloor(g.acct); err == nil {
		g.emailSeen = append(g.emailSeen, f)
	}
	if f, err := g.d.IdeasJiraFloor(g.acct); err == nil {
		g.jiraSeen = append(g.jiraSeen, f)
	}
	return g.stage1Gen.Generate(ctx, sys, user, model)
}

// C6: the drain never lowers the stored forward floor, so a process killed
// mid-drain does not leave the forward run weeks back to re-mine everything.
func TestBackfillEmail_NeverLowersTheStoredFloor(t *testing.T) {
	d := newTestDB(t)
	now := time.Now()
	from, to := now.Add(-72*time.Hour), now.Add(-24*time.Hour)
	a := seedGoogleAccount(t, d, float64(now.Unix()))
	saved := float64(now.Add(-time.Hour).Unix())
	setIdeasEmailFloorRaw(t, d, a, saved)
	seedGmailMessageIdeas(t, d, a, "m1", "thr-1", "x@example.com", "Ann", "Subj", "in window",
		from.Add(time.Hour).UTC().Format(time.RFC3339))

	gen := &floorWatchGen{d: d, acct: a}
	_, complete, err := New(d, backfillCfg(), gen, testLogger()).BackfillEmail(context.Background(), a, from, to)
	require.NoError(t, err)
	require.True(t, complete)
	require.True(t, gen.saw("in window"), "the window is mined")
	require.NotEmpty(t, gen.emailSeen)
	for _, f := range gen.emailSeen {
		assert.Equal(t, saved, f, "the stored floor stays put during the drain")
	}
}

// C6: BackfillJira's counterpart.
func TestBackfillJira_NeverLowersTheStoredFloor(t *testing.T) {
	d := newTestDB(t)
	now := time.Now()
	from, to := now.Add(-72*time.Hour), now.Add(-24*time.Hour)
	a := seedJiraAccount(t, d)
	saved := db.FormatJiraTime(now.Add(-time.Hour))
	setIdeasJiraFloorRaw(t, d, a, saved)
	seedJiraIssueIdeas(t, d, a, "AA-1", "AA", "Alpha", "Open", "new", "alpha issue",
		db.FormatJiraTime(from.Add(2*time.Hour)))

	gen := &floorWatchGen{d: d, acct: a}
	_, complete, err := New(d, backfillCfg(), gen, testLogger()).BackfillJira(context.Background(), a, from, to)
	require.NoError(t, err)
	require.True(t, complete)
	require.True(t, gen.saw("AA-1"), "the window is mined")
	require.NotEmpty(t, gen.jiraSeen)
	for _, f := range gen.jiraSeen {
		assert.Equal(t, saved, f, "the stored floor stays put during the drain")
	}
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
	_, complete, err := p.BackfillEmail(context.Background(), a, from, to)
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
	_, _, err = p.BackfillEmail(context.Background(), a, from, to)
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
	_, _, err := p.BackfillEmail(context.Background(), a, from, to)
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
	_, complete, err := p.BackfillJira(context.Background(), a, from, to)
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
	_, _, err := p.BackfillJira(context.Background(), a, from, to)
	require.NoError(t, err)
	fa, err := d.IdeasJiraFloor(a)
	require.NoError(t, err)
	assert.NotEmpty(t, fa)
}

// cuttingGen answers stage-1 calls like stage1Gen, counts the calls that
// succeeded, and cancels the drain's context once cutAfter calls succeeded
// (0 = never): the next call sees the cancelled context, as a budget deadline
// would.
type cuttingGen struct {
	cutAfter int
	cancel   context.CancelFunc
	ok       int
}

func (g *cuttingGen) Generate(ctx context.Context, _, user, _ string) (string, *digest.Usage, string, error) {
	if err := ctx.Err(); err != nil {
		return "", nil, "", err
	}
	if strings.Contains(user, "=== REGISTRY ===") {
		return "", nil, "", fmt.Errorf("no consolidator call expected")
	}
	g.ok++
	if g.cutAfter > 0 && g.ok == g.cutAfter && g.cancel != nil {
		g.cancel()
	}
	return `{"topics":[{"title":"t","summary":"s","ideas":[],"decisions":[{"text":"d","author":"Ann","ref":"x"}]}]}`, &digest.Usage{}, "", nil
}

// smallWindowCfg makes every stage-1 window hold one thread, so a drain over
// several threads takes several passes.
func smallWindowCfg() *config.Config {
	cfg := backfillCfg()
	cfg.Ideas.MaxPromptChars = 1
	return cfg
}

// F2: a drain cut mid-way reports the floor it reached; the next call started
// there finishes the window, and both calls together pay exactly the AI calls
// of one uninterrupted drain.
func TestBackfillEmail_ResumeFromReached(t *testing.T) {
	now := time.Now()
	from, to := now.Add(-72*time.Hour), now.Add(-24*time.Hour)
	seed := func(t *testing.T) (*db.DB, int64) {
		d := newTestDB(t)
		a := seedGoogleAccount(t, d, float64(now.Unix()))
		setIdeasEmailFloorRaw(t, d, a, float64(now.Add(-time.Hour).Unix()))
		for i := range 4 {
			at := from.Add(time.Duration(i+1) * time.Hour).UTC().Format(time.RFC3339)
			seedGmailMessageIdeas(t, d, a, fmt.Sprintf("m%d", i), fmt.Sprintf("thr-%d", i),
				"x@example.com", "Ann", "Subj", fmt.Sprintf("mail %d", i), at)
		}
		return d, a
	}

	d, a := seed(t)
	whole := &cuttingGen{}
	_, complete, err := New(d, smallWindowCfg(), whole, testLogger()).BackfillEmail(context.Background(), a, from, to)
	require.NoError(t, err)
	require.True(t, complete)
	require.Greater(t, whole.ok, 2, "the window takes several passes")

	d, a = seed(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	cut := &cuttingGen{cutAfter: 2, cancel: cancel}
	p := New(d, smallWindowCfg(), cut, testLogger())
	reached, complete, err := p.BackfillEmail(ctx, a, from, to)
	require.ErrorIs(t, err, context.Canceled)
	assert.False(t, complete)
	assert.True(t, reached.After(from), "the cut drain reports how far it got")
	assert.True(t, reached.Before(to))

	cut.cutAfter = 0
	_, complete, err = p.BackfillEmail(context.Background(), a, reached, to)
	require.NoError(t, err)
	assert.True(t, complete)
	assert.Equal(t, whole.ok, cut.ok, "resuming pays no stage-1 call twice")
}

// F2: BackfillJira's counterpart.
func TestBackfillJira_ResumeFromReached(t *testing.T) {
	now := time.Now()
	from, to := now.Add(-72*time.Hour), now.Add(-24*time.Hour)
	seed := func(t *testing.T) (*db.DB, int64) {
		d := newTestDB(t)
		a := seedJiraAccount(t, d)
		setIdeasJiraFloorRaw(t, d, a, db.FormatJiraTime(now.Add(-time.Hour)))
		for i := range 4 {
			key := fmt.Sprintf("AA-%d", i+1)
			upd := db.FormatJiraTime(from.Add(time.Duration(i+1) * time.Hour))
			seedJiraIssueIdeas(t, d, a, key, "AA", "Issue "+key, "Open", "new", "issue "+key, upd)
		}
		return d, a
	}

	d, a := seed(t)
	whole := &cuttingGen{}
	_, complete, err := New(d, smallWindowCfg(), whole, testLogger()).BackfillJira(context.Background(), a, from, to)
	require.NoError(t, err)
	require.True(t, complete)
	require.Greater(t, whole.ok, 2, "the window takes several passes")

	d, a = seed(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	cut := &cuttingGen{cutAfter: 2, cancel: cancel}
	p := New(d, smallWindowCfg(), cut, testLogger())
	reached, complete, err := p.BackfillJira(ctx, a, from, to)
	require.ErrorIs(t, err, context.Canceled)
	assert.False(t, complete)
	assert.True(t, reached.After(from), "the cut drain reports how far it got")

	cut.cutAfter = 0
	_, complete, err = p.BackfillJira(context.Background(), a, reached, to)
	require.NoError(t, err)
	assert.True(t, complete)
	assert.Equal(t, whole.ok, cut.ok, "resuming pays no stage-1 call twice")
}
