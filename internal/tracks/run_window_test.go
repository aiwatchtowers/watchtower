package tracks

import (
	"context"
	"errors"
	"fmt"
	"log"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/digest"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

var errBatchGenerator = errors.New("provider unavailable")

// failingGenerator fails the first failFirst calls and answers with response afterwards.
type failingGenerator struct {
	failFirst int
	calls     int
	response  string
}

func (g *failingGenerator) Generate(_ context.Context, _, _, _ string) (string, *digest.Usage, string, error) {
	g.calls++
	if g.calls <= g.failFirst {
		return "", nil, "", errBatchGenerator
	}
	return g.response, &digest.Usage{InputTokens: 100, OutputTokens: 50}, "mock-session", nil
}

// cancelingGenerator answers successfully and cancels the run's context, so the
// batch loop stops before the remaining batches.
type cancelingGenerator struct {
	cancel   context.CancelFunc
	calls    int
	response string
}

func (g *cancelingGenerator) Generate(_ context.Context, _, _, _ string) (string, *digest.Usage, string, error) {
	g.calls++
	g.cancel()
	return g.response, &digest.Usage{InputTokens: 100, OutputTokens: 50}, "mock-session", nil
}

// seedTrackWindow seeds a workspace, an owner, and n channels each carrying one
// digest topic with an action item assigned to the owner (so the relevance
// filter keeps every channel). Returns the AI batch response that stores one
// track for the first channel.
func seedTrackWindow(t *testing.T, database *db.DB, n int) string {
	t.Helper()

	require.NoError(t, database.UpsertWorkspace(db.Workspace{ID: "T1", Name: "test"}))
	_, acctErr := database.CreateSlackAccount(db.SlackAccount{CurrentUserID: "U1"})
	require.NoError(t, acctErr)
	require.NoError(t, database.UpsertUser(db.User{ID: "U1", Name: "alice", DisplayName: "Alice"}))
	require.NoError(t, database.UpsertUser(db.User{ID: "U2", Name: "bob", DisplayName: "Bob"}))

	now := time.Now()
	from := float64(now.Add(-2 * time.Hour).Unix())
	to := float64(now.Unix())

	for i := 1; i <= n; i++ {
		channelID := fmt.Sprintf("C%d", i)
		require.NoError(t, database.UpsertChannel(db.Channel{
			ID: channelID, Name: fmt.Sprintf("chan-%d", i), Type: "public",
		}))
		digestID, err := database.UpsertDigest(db.Digest{
			ChannelID: channelID, Type: "channel",
			PeriodFrom: from, PeriodTo: to,
			Summary: "Discussion about API PR review", MessageCount: 5, Model: "test",
		})
		require.NoError(t, err)
		_, err = database.Exec(`INSERT INTO digest_topics (digest_id, idx, title, summary, decisions, action_items, situations, key_messages)
			VALUES (?, 0, 'API PR Review', 'Bob asked Alice to review the API pull request.', '[]',
			'[{"text":"Review API PR","assignee":"@alice","status":"open"}]', '[]', '[]')`, digestID)
		require.NoError(t, err)
	}

	ts := fmt.Sprintf("%d.000000", now.Add(-30*time.Minute).Unix())
	return `[{
		"channel_id": "C1",
		"items": [{
			"text": "Review API PR",
			"context": "Bob asked Alice to review the API pull request.",
			"category": "code_review",
			"ownership": "mine",
			"priority": "medium",
			"requester": {"name": "@bob", "user_id": "U2"},
			"participants": [{"name":"Bob","user_id":"U2","stance":"requester"}],
			"source_refs": [{"ts":"` + ts + `","author":"@bob","text":"can you review the API PR?"}],
			"tags": ["api"]
		}]
	}]`
}

// A window in which every batch failed must surface an error, not a clean run:
// both tracks watermarks read pipeline_runs rows with status='done', so a nil
// here would stamp the failed window as processed and skip its digests forever.
func TestRunForWindow_AllBatchesFailedReturnsError(t *testing.T) {
	database := testDB(t)
	response := seedTrackWindow(t, database, 1)

	gen := &failingGenerator{failFirst: 1, response: response}
	cfg := testConfig()
	cfg.AI.Workers = 1
	pipe := New(database, cfg, gen, log.Default())

	created, _, err := pipe.Run(context.Background())
	require.Error(t, err)
	assert.ErrorIs(t, err, errBatchGenerator)
	assert.Contains(t, err.Error(), "all 1 track batch(es) failed")
	assert.Equal(t, 0, created)
	assert.Equal(t, 1, gen.calls)

	tracks, terr := database.GetAllActiveTracks()
	require.NoError(t, terr)
	assert.Empty(t, tracks)
}

// Partial success stays a success: one failed batch out of two must not freeze
// the watermark, because the surviving batch's digests were processed.
func TestRunForWindow_PartialBatchFailureStaysSuccess(t *testing.T) {
	database := testDB(t)
	// 16 channels exceed the 15-channel batch cap, so the run plans two batches.
	response := seedTrackWindow(t, database, 16)

	gen := &failingGenerator{failFirst: 1, response: response}
	cfg := testConfig()
	cfg.AI.Workers = 1
	pipe := New(database, cfg, gen, log.Default())

	created, _, err := pipe.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 2, gen.calls, "expected two batches so one can fail and one succeed")
	assert.Equal(t, 1, created)

	tracks, terr := database.GetAllActiveTracks()
	require.NoError(t, terr)
	assert.Len(t, tracks, 1)
}

// Shutdown is not a batch failure, but an interrupted window must not be
// stamped 'done' either — the batches that never ran would be skipped forever.
func TestRunForWindow_CancelledContextReportsInterruption(t *testing.T) {
	database := testDB(t)
	response := seedTrackWindow(t, database, 16)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	gen := &cancelingGenerator{cancel: cancel, response: response}
	cfg := testConfig()
	cfg.AI.Workers = 1
	pipe := New(database, cfg, gen, log.Default())

	created, _, err := pipe.Run(ctx)
	require.Error(t, err)
	assert.ErrorIs(t, err, context.Canceled)
	assert.Contains(t, err.Error(), "interrupted after 1 of 2 batch(es)")
	assert.Equal(t, 1, gen.calls)
	assert.Equal(t, 1, created, "tracks stored before the interruption are still returned")
}

// cancelThenFailGenerator cancels the run's context and then fails the call,
// the way a provider subprocess dies when the daemon is stopped mid-batch.
type cancelThenFailGenerator struct {
	cancel context.CancelFunc
	calls  int
}

func (g *cancelThenFailGenerator) Generate(_ context.Context, _, _, _ string) (string, *digest.Usage, string, error) {
	g.calls++
	g.cancel()
	return "", nil, "", errBatchGenerator
}

// A batch cut off mid-call by a shutdown must be reported as an interruption,
// not as "all N batch(es) failed": the outcome is the same frozen watermark
// either way, but blaming the provider for a clean Ctrl-C is exactly the kind
// of misleading operator signal this wave removes.
func TestRunForWindow_CancellationDuringLastBatchIsNotAnAllFailedError(t *testing.T) {
	database := testDB(t)
	seedTrackWindow(t, database, 1) // a single channel — one batch, so it is also the last

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	gen := &cancelThenFailGenerator{cancel: cancel}
	cfg := testConfig()
	cfg.AI.Workers = 1
	pipe := New(database, cfg, gen, log.Default())

	_, _, err := pipe.Run(ctx)
	require.Error(t, err)
	assert.Equal(t, 1, gen.calls)
	assert.ErrorIs(t, err, context.Canceled)
	assert.NotErrorIs(t, err, errBatchGenerator, "a cancelled batch must not be attributed to the provider")
	assert.Contains(t, err.Error(), "interrupted after 0 of 1 batch(es)")
	assert.NotContains(t, err.Error(), "batch(es) failed")
}

func retryDigestCount(t *testing.T, database *db.DB) int {
	t.Helper()
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM track_retry_digests`).Scan(&n))
	return n
}

// futureWatermark is a digestsSinceISO past every seeded digest, so a run sees
// no new digests — only what the retry set re-offers (the state right after a
// partially failed run advanced the watermark).
func futureWatermark() string {
	return time.Now().Add(time.Hour).UTC().Format(time.RFC3339)
}

// A partially failed run advances the watermark, so the failed batch's
// digests must be re-offered by the next run through the retry set, and leave
// it once their batch succeeds. 16 channels → two batches, one fails.
func TestRunForWindow_PartialFailureReoffersFailedBatchDigests(t *testing.T) {
	database := testDB(t)
	response := seedTrackWindow(t, database, 16)
	owner, err := database.ResolveOwner()
	require.NoError(t, err)
	now := time.Now()
	from, to := float64(now.Add(-3*time.Hour).Unix()), float64(now.Unix())

	gen := &failingGenerator{failFirst: 1, response: response}
	cfg := testConfig()
	cfg.AI.Workers = 1
	pipe := New(database, cfg, gen, log.Default())

	_, err = pipe.RunForWindow(context.Background(), owner, from, to)
	require.NoError(t, err, "a partial failure stays a success")
	require.Equal(t, 2, gen.calls)
	owed := retryDigestCount(t, database)
	require.Greater(t, owed, 0, "the failed batch's digests must be kept for retry")
	require.Less(t, owed, 16, "the succeeded batch's digests must not be kept")

	_, err = pipe.RunForWindow(context.Background(), owner, from, to, futureWatermark())
	require.NoError(t, err)
	assert.Equal(t, 3, gen.calls, "the next run re-offers the failed batch even with no new digests")
	assert.Equal(t, 0, retryDigestCount(t, database), "a succeeded retry leaves the set")
}

// A batch that keeps failing is re-offered at most maxBatchRetryAttempts
// times, then given up on — never re-sent forever.
func TestRunForWindow_RetryGivesUpAfterMaxAttempts(t *testing.T) {
	database := testDB(t)
	seedTrackWindow(t, database, 2)
	owner, err := database.ResolveOwner()
	require.NoError(t, err)
	now := time.Now()
	from, to := float64(now.Add(-3*time.Hour).Unix()), float64(now.Unix())

	gen := &failingGenerator{failFirst: 1 << 30}
	cfg := testConfig()
	cfg.AI.Workers = 1
	pipe := New(database, cfg, gen, log.Default())

	_, err = pipe.RunForWindow(context.Background(), owner, from, to)
	require.Error(t, err)
	assert.Equal(t, 2, retryDigestCount(t, database))
	for i := 1; i < maxBatchRetryAttempts+2; i++ {
		_, _ = pipe.RunForWindow(context.Background(), owner, from, to, futureWatermark())
	}
	assert.Equal(t, maxBatchRetryAttempts, gen.calls, "one call per attempt, then no more")
	assert.Equal(t, 0, retryDigestCount(t, database))
}

// A shutdown is not a batch failure: an interrupted run charges nothing to
// the retry set, whether the cut came between batches or mid-call.
func TestRunForWindow_ShutdownIsNotChargedToRetrySet(t *testing.T) {
	for name, mk := range map[string]func(context.CancelFunc, string) digest.Generator{
		"between batches": func(c context.CancelFunc, r string) digest.Generator {
			return &cancelingGenerator{cancel: c, response: r}
		},
		"mid-call": func(c context.CancelFunc, _ string) digest.Generator {
			return &cancelThenFailGenerator{cancel: c}
		},
	} {
		t.Run(name, func(t *testing.T) {
			database := testDB(t)
			response := seedTrackWindow(t, database, 16)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			cfg := testConfig()
			cfg.AI.Workers = 1
			pipe := New(database, cfg, mk(cancel, response), log.Default())

			_, _, err := pipe.Run(ctx)
			require.ErrorIs(t, err, context.Canceled)
			assert.Equal(t, 0, retryDigestCount(t, database))
		})
	}
}
