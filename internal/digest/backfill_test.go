package digest

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// backfillRange is a two-day chunk well below every forward window the tests
// seed: [20 days ago, 18 days ago].
func backfillRange() (from, to float64) {
	start := utcDayStart(time.Now().AddDate(0, 0, -20))
	return float64(start.Unix()), float64(start.Add(48 * time.Hour).Unix())
}

// backfillPipeline isolates the digest lock under a temp HOME so a live daemon
// on the developer's machine cannot contend with the test.
func backfillPipeline(t *testing.T, database *db.DB, gen Generator) *Pipeline {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	cfg := testConfig()
	return New(database, cfg, gen, testLogger())
}

func seedRangeMessages(t *testing.T, database *db.DB, channelID, prefix string, start float64, n int) {
	t.Helper()
	for i := range n {
		ts := fmt.Sprintf("%d.%06d", int64(start)+int64(i*60), i)
		seedMessage(t, database, channelID, ts, "U1", fmt.Sprintf("%s-%d", prefix, i))
	}
}

func channelDigests(t *testing.T, database *db.DB, channelID string) []db.Digest {
	t.Helper()
	ds, err := database.GetDigests(db.DigestFilter{ChannelID: channelID, Type: "channel"})
	require.NoError(t, err)
	return ds
}

func batchAnswer(channelIDs ...string) string {
	out := "["
	for i, id := range channelIDs {
		if i > 0 {
			out += ","
		}
		out += fmt.Sprintf(`{"channel_id":%q,"summary":"Work in %s","topics":[{"title":"t","summary":"s","decisions":[],"action_items":[],"situations":[],"key_messages":[]}]}`, id, id)
	}
	return out + "]"
}

func TestRunBackfillWindow_DigestsChunk(t *testing.T) {
	database := testDB(t)
	seedChannel(t, database, "C1", "alpha")
	seedChannel(t, database, "C2", "beta")
	seedUser(t, database, "U1", "alice", "Alice")
	from, to := backfillRange()
	seedRangeMessages(t, database, "C1", "alpha", from+3600, 5)
	seedRangeMessages(t, database, "C2", "beta", from+7200, 5)

	gen := &promptCapturingGenerator{responses: map[string]string{
		"digest.channel_batch": batchAnswer("C1", "C2"),
		"digest.channel":       validDigestJSON(),
	}}
	p := backfillPipeline(t, database, gen)

	res, usage, err := p.RunBackfillWindow(context.Background(), from, to)
	require.NoError(t, err)
	assert.True(t, res.Complete)
	assert.Equal(t, 2, res.Digests)
	require.NotNil(t, usage)
	assert.Positive(t, usage.InputTokens, "the call's own usage is returned")

	for _, ch := range []string{"C1", "C2"} {
		ds := channelDigests(t, database, ch)
		require.Len(t, ds, 1, ch)
		assert.GreaterOrEqual(t, ds[0].PeriodFrom, from, ch)
		assert.LessOrEqual(t, ds[0].PeriodTo, to, ch)
	}
}

func TestRunBackfillWindow_UsageIsThisCallsDeltaOnly(t *testing.T) {
	database := testDB(t)
	seedChannel(t, database, "C1", "alpha")
	seedUser(t, database, "U1", "alice", "Alice")
	from, to := backfillRange()
	seedRangeMessages(t, database, "C1", "alpha", from+3600, 5)

	gen := &mockGenerator{response: validDigestJSON()}
	p := backfillPipeline(t, database, gen)
	// The forward phase already accumulated usage on the shared pipeline.
	p.totalInputTokens.Store(1000)
	p.totalOutputTokens.Store(1000)

	_, usage, err := p.RunBackfillWindow(context.Background(), from, to)
	require.NoError(t, err)
	assert.Equal(t, 100, usage.InputTokens)
	assert.Equal(t, 50, usage.OutputTokens)
}

func TestRunBackfillWindow_OverLoadCap(t *testing.T) {
	database := testDB(t)
	seedChannel(t, database, "C1", "busy")
	seedUser(t, database, "U1", "alice", "Alice")
	from, to := backfillRange()
	for i := range db.DefaultTimeRangeLimit + 50 {
		seedMessage(t, database, "C1", fmt.Sprintf("%d.000000", int64(from)+600+int64(i)), "U1", fmt.Sprintf("busy-%d", i))
	}

	gen := &mockGenerator{response: validDigestJSON()}
	p := backfillPipeline(t, database, gen)

	res, _, err := p.RunBackfillWindow(context.Background(), from, to)
	require.NoError(t, err)
	assert.True(t, res.Complete)
	assert.Equal(t, 2, res.Digests)
	assert.Len(t, channelDigests(t, database, "C1"), 2)
}

func TestRunBackfillWindow_DeclinedChannelDoesNotLoop(t *testing.T) {
	database := testDB(t)
	seedChannel(t, database, "C_REAL", "real")
	seedChannel(t, database, "C_NOISY", "noisy")
	seedUser(t, database, "U1", "alice", "Alice")
	from, to := backfillRange()
	seedRangeMessages(t, database, "C_REAL", "real", from+3600, 4)
	seedRangeMessages(t, database, "C_NOISY", "noisy", from+3600, 4)

	gen := &promptCapturingGenerator{responses: map[string]string{
		"digest.channel_batch": batchAnswer("C_REAL"),
		"digest.channel":       validDigestJSON(),
	}}
	p := backfillPipeline(t, database, gen)

	res, _, err := p.RunBackfillWindow(context.Background(), from, to)
	require.NoError(t, err)
	assert.True(t, res.Complete, "the declined channel is passed by the in-memory considered mark")
	assert.Equal(t, 1, res.Digests)
	assert.Equal(t, 1, gen.promptsContaining("noisy-0"), "the declined channel is rendered once, not re-offered")

	var considered any
	require.NoError(t, database.QueryRow(`SELECT digest_considered_ts FROM channels WHERE id = 'C_NOISY'`).Scan(&considered))
	assert.Nil(t, considered, "a backfill never writes the forward considered mark")
	require.NoError(t, database.QueryRow(`SELECT digest_considered_ts FROM channels WHERE id = 'C_REAL'`).Scan(&considered))
	assert.Nil(t, considered)
	assert.Nil(t, p.backfill, "the backfill scope is cleared after the call")
}

func TestRunBackfillWindow_LowActivityChannelNotCooledDown(t *testing.T) {
	database := testDB(t)
	seedChannel(t, database, "C1", "trickle")
	seedUser(t, database, "U1", "alice", "Alice")
	from, to := backfillRange()
	seedRangeMessages(t, database, "C1", "trickle", from+3600, 2)

	// A forward digest written a moment ago (created_at = now).
	now := float64(time.Now().Unix())
	_, err := database.UpsertDigest(db.Digest{
		ChannelID: "C1", Type: "channel", PeriodFrom: now - 7200, PeriodTo: now - 60,
		Summary: "forward", MessageCount: 1, Model: "m",
	})
	require.NoError(t, err)

	gen := &mockGenerator{response: validDigestJSON()}
	p := backfillPipeline(t, database, gen)

	res, _, err := p.RunBackfillWindow(context.Background(), from, to)
	require.NoError(t, err)
	assert.True(t, res.Complete)
	assert.Equal(t, 1, res.Digests, "the live-edge cooldown does not apply below every forward mark")
}

func TestRunBackfillWindow_ForwardWindowUnaffected(t *testing.T) {
	database := testDB(t)
	seedChannel(t, database, "C1", "alpha")
	seedUser(t, database, "U1", "alice", "Alice")
	for _, ts := range []string{"600.000000", "700.000000", "800.000000", "2500.000000"} {
		seedMessage(t, database, "C1", ts, "U1", "msg "+ts)
	}
	_, err := database.UpsertDigest(db.Digest{
		ChannelID: "C1", Type: "channel", PeriodFrom: 1000, PeriodTo: 2000,
		Summary: "forward", MessageCount: 1, Model: "m",
	})
	require.NoError(t, err)

	gen := &mockGenerator{response: validDigestJSON()}
	p := backfillPipeline(t, database, gen)

	res, _, err := p.RunBackfillWindow(context.Background(), 500, 1000)
	require.NoError(t, err)
	assert.True(t, res.Complete)
	assert.Equal(t, 1, res.Digests)

	windows, err := p.resolveChannelWindows(3000)
	require.NoError(t, err)
	require.Len(t, windows, 1)
	assert.Equal(t, 2000.0, windows[0].since, "the forward window still starts at the forward mark")
}

func TestRunBackfillWindow_MutedAndDMChannelsDoNotStall(t *testing.T) {
	database := testDB(t)
	require.NoError(t, database.UpsertChannel(db.Channel{ID: "D1", Name: "dm", Type: "dm"}))
	seedChannel(t, database, "C_MUTED", "muted")
	require.NoError(t, database.SetMuteForLLM("C_MUTED", true))
	seedUser(t, database, "U1", "alice", "Alice")
	from, to := backfillRange()
	seedRangeMessages(t, database, "D1", "dm", from+3600, 5)
	seedRangeMessages(t, database, "C_MUTED", "muted", from+3600, 5)

	gen := &mockGenerator{response: validDigestJSON()}
	p := backfillPipeline(t, database, gen)

	res, _, err := p.RunBackfillWindow(context.Background(), from, to)
	require.NoError(t, err, "channels the digest never covers are not a stall")
	assert.True(t, res.Complete)
	assert.Equal(t, 0, gen.calls)
}

func TestRunBackfillWindow_FastForwardFloorApplies(t *testing.T) {
	database := testDB(t)
	seedChannel(t, database, "C1", "alpha")
	seedUser(t, database, "U1", "alice", "Alice")
	from, to := backfillRange()
	seedRangeMessages(t, database, "C1", "alpha", from+3600, 5)
	require.NoError(t, database.UpsertWorkspace(db.Workspace{ID: "T1", Name: "acme", Domain: "acme"}))
	require.NoError(t, database.SetDigestFastForwardTS(to))

	gen := &mockGenerator{response: validDigestJSON()}
	p := backfillPipeline(t, database, gen)

	res, _, err := p.RunBackfillWindow(context.Background(), from, to)
	require.NoError(t, err)
	assert.True(t, res.Complete)
	assert.Equal(t, 0, gen.calls, "FEAT-03: history below the fast-forward floor stays undigested")
}

func TestRunBackfillWindow_DisabledIsComplete(t *testing.T) {
	database := testDB(t)
	seedChannel(t, database, "C1", "alpha")
	seedUser(t, database, "U1", "alice", "Alice")
	from, to := backfillRange()
	seedRangeMessages(t, database, "C1", "alpha", from+3600, 5)

	gen := &mockGenerator{response: validDigestJSON()}
	p := backfillPipeline(t, database, gen)
	p.cfg.Digest.Enabled = false

	res, _, err := p.RunBackfillWindow(context.Background(), from, to)
	require.NoError(t, err)
	assert.Equal(t, BackfillWindowResult{Digests: 0, Complete: true}, res)
	assert.Equal(t, 0, gen.calls)
}

func TestRunBackfillWindow_LockContentionIsIncomplete(t *testing.T) {
	database := testDB(t)
	seedChannel(t, database, "C1", "alpha")
	seedUser(t, database, "U1", "alice", "Alice")
	from, to := backfillRange()
	seedRangeMessages(t, database, "C1", "alpha", from+3600, 5)

	gen := &mockGenerator{response: validDigestJSON()}
	p := backfillPipeline(t, database, gen)
	_, unlock, err := p.acquireDigestLock()
	require.NoError(t, err)
	defer unlock()

	res, _, err := p.RunBackfillWindow(context.Background(), from, to)
	require.NoError(t, err)
	assert.Equal(t, BackfillWindowResult{Digests: 0, Complete: false}, res)
	assert.Equal(t, 0, gen.calls)
}

func TestRunBackfillWindow_CancelledContext(t *testing.T) {
	database := testDB(t)
	seedChannel(t, database, "C1", "alpha")
	seedUser(t, database, "U1", "alice", "Alice")
	from, to := backfillRange()
	seedRangeMessages(t, database, "C1", "alpha", from+3600, 5)

	gen := &mockGenerator{response: validDigestJSON()}
	p := backfillPipeline(t, database, gen)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	res, _, err := p.RunBackfillWindow(ctx, from, to)
	require.ErrorIs(t, err, context.Canceled)
	assert.False(t, res.Complete)
}

func TestRunBackfillRollups_EachUTCDay(t *testing.T) {
	database := testDB(t)
	seedChannel(t, database, "C1", "alpha")
	seedChannel(t, database, "C2", "beta")
	from, to := backfillRange()
	for _, day := range []float64{from, from + 86400} {
		for _, ch := range []string{"C1", "C2"} {
			_, err := database.UpsertDigest(db.Digest{
				ChannelID: ch, Type: "channel", PeriodFrom: day + 3600, PeriodTo: day + 7200,
				Summary: "s " + ch, MessageCount: 3, Model: "m",
			})
			require.NoError(t, err)
		}
	}

	gen := &mockGenerator{response: validDigestJSON()}
	p := backfillPipeline(t, database, gen)

	require.NoError(t, p.RunBackfillRollups(context.Background(), from, to))
	daily, err := database.GetDigests(db.DigestFilter{Type: "daily"})
	require.NoError(t, err)
	assert.Len(t, daily, 2, "one daily rollup per UTC day of the chunk")
}
