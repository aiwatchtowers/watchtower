package digest

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sync"
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
	seedChannel(t, database, "1:C1", "alpha")
	seedChannel(t, database, "1:C2", "beta")
	seedUser(t, database, "U1", "alice", "Alice")
	from, to := backfillRange()
	seedRangeMessages(t, database, "1:C1", "alpha", from+3600, 5)
	seedRangeMessages(t, database, "1:C2", "beta", from+7200, 5)

	gen := &promptCapturingGenerator{responses: map[string]string{
		"digest.channel_batch": batchAnswer("1:C1", "1:C2"),
		"digest.channel":       validDigestJSON(),
	}}
	p := backfillPipeline(t, database, gen)

	res, usage, err := p.RunBackfillWindow(context.Background(), 1, from, to)
	require.NoError(t, err)
	assert.True(t, res.Complete)
	assert.Equal(t, 2, res.Digests)
	require.NotNil(t, usage)
	assert.Positive(t, usage.InputTokens, "the call's own usage is returned")

	for _, ch := range []string{"1:C1", "1:C2"} {
		ds := channelDigests(t, database, ch)
		require.Len(t, ds, 1, ch)
		assert.GreaterOrEqual(t, ds[0].PeriodFrom, from, ch)
		assert.LessOrEqual(t, ds[0].PeriodTo, to, ch)
	}
}

// TestRunBackfillWindow_AccountScoped pins F1: a backfill row belongs to one
// Slack account, so its chunk digests only that account's channels — the
// other account's messages in the same range wait for that account's own
// row, and its forward digest is left alone.
func TestRunBackfillWindow_AccountScoped(t *testing.T) {
	database := testDB(t)
	seedChannel(t, database, "1:CA", "alpha")
	seedChannel(t, database, "2:CB", "beta")
	seedUser(t, database, "U1", "alice", "Alice")
	from, to := backfillRange()
	seedRangeMessages(t, database, "1:CA", "alpha", from+3600, 5)
	seedRangeMessages(t, database, "2:CB", "beta", from+3600, 5)
	now := float64(time.Now().Unix())
	_, err := database.UpsertDigest(db.Digest{
		ChannelID: "1:CA", Type: "channel", PeriodFrom: now - 7200, PeriodTo: now - 60,
		Summary: "forward A", MessageCount: 1, Model: "m",
	})
	require.NoError(t, err)

	gen := &promptCapturingGenerator{responses: map[string]string{
		"digest.channel_batch": batchAnswer("2:CB"),
		"digest.channel":       validDigestJSON(),
	}}
	p := backfillPipeline(t, database, gen)

	res, _, err := p.RunBackfillWindow(context.Background(), 2, from, to)
	require.NoError(t, err)
	assert.True(t, res.Complete)
	assert.Equal(t, 1, res.Digests)
	assert.Zero(t, gen.promptsContaining("alpha-0"), "account 1's messages are not in account 2's backfill")
	assert.Len(t, channelDigests(t, database, "2:CB"), 1)
	da := channelDigests(t, database, "1:CA")
	require.Len(t, da, 1, "account 1 keeps only its forward digest")
	assert.Equal(t, "forward A", da[0].Summary)
}

// apiTokenGenerator answers every call with a fixed usage that includes
// TotalAPITokens, so the summed usage of a multi-pass call can be checked.
type apiTokenGenerator struct {
	mu    sync.Mutex
	calls int
}

func (g *apiTokenGenerator) Generate(context.Context, string, string, string) (string, *Usage, string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.calls++
	return validDigestJSON(), &Usage{Model: "m", InputTokens: 100, OutputTokens: 50, TotalAPITokens: 150}, "s", nil
}

// TestRunBackfillWindow_UsageIsThisCallsOwn pins that the returned usage is the
// sum of this call's own passes — never the pipeline's shared counters, which
// the forward phase also feeds.
func TestRunBackfillWindow_UsageIsThisCallsOwn(t *testing.T) {
	database := testDB(t)
	seedChannel(t, database, "1:C1", "busy")
	seedUser(t, database, "U1", "alice", "Alice")
	from, to := backfillRange()
	for i := range db.DefaultTimeRangeLimit + 50 {
		seedMessage(t, database, "1:C1", fmt.Sprintf("%d.000000", int64(from)+600+int64(i)), "U1", fmt.Sprintf("busy-%d", i))
	}

	gen := &apiTokenGenerator{}
	p := backfillPipeline(t, database, gen)
	// The forward phase already accumulated usage on the shared pipeline.
	p.totalInputTokens.Store(1000)
	p.totalOutputTokens.Store(1000)
	p.totalAPITokens.Store(1000)

	res, usage, err := p.RunBackfillWindow(context.Background(), 1, from, to)
	require.NoError(t, err)
	require.Equal(t, 2, res.Digests, "two passes, two AI calls")
	require.Equal(t, 2, gen.calls)
	assert.Equal(t, 200, usage.InputTokens)
	assert.Equal(t, 100, usage.OutputTokens)
	assert.Equal(t, 300, usage.TotalAPITokens)
}

// TestRunBackfillWindow_FailedChannelNotReofferedInTheSameCall pins that a
// channel whose AI call failed is not re-sent on every later pass of the same
// call: the healthy channel finishes, the failing one is tried once, and the
// call then reports the failure so the chunk takes a strike.
func TestRunBackfillWindow_FailedChannelNotReofferedInTheSameCall(t *testing.T) {
	database := testDB(t)
	seedChannel(t, database, "1:C_OK", "steady")
	seedChannel(t, database, "1:C_FAIL", "flaky")
	seedUser(t, database, "U1", "alice", "Alice")
	from, to := backfillRange()
	// A backlog over the load cap, so the healthy channel needs a second pass.
	for i := range db.DefaultTimeRangeLimit + 50 {
		seedMessage(t, database, "1:C_OK", fmt.Sprintf("%d.000000", int64(from)+600+int64(i)), "U1", fmt.Sprintf("steady-%d", i))
	}
	seedRangeMessages(t, database, "1:C_FAIL", "flaky", from+3600, 5)

	gen := &channelKeyedGenerator{failChannel: "flaky", response: validDigestJSON()}
	p := backfillPipeline(t, database, gen)
	p.cfg.Digest.BatchMaxChannels = 1

	res, _, err := p.RunBackfillWindow(context.Background(), 1, from, to)
	require.Error(t, err, "a channel left failing is reported, not silently passed")
	assert.Contains(t, err.Error(), "simulated AI failure")
	assert.False(t, res.Complete)
	assert.Equal(t, 2, res.Digests, "the healthy channel still finished its two windows")
	assert.Len(t, channelDigests(t, database, "1:C_OK"), 2)
	assert.Equal(t, 3, gen.calls, "two healthy calls and exactly one call for the failing channel")
}

// TestRunBackfillWindow_PromptCarriesNoPresentDayContext pins that a backfill
// channel digest — on both the single-channel and the batch path — is written
// without the channel's current running summary: a digest of weeks ago must
// not skip decisions today's summary holds, or claim continuity backwards.
func TestRunBackfillWindow_PromptCarriesNoPresentDayContext(t *testing.T) {
	for _, tc := range []struct {
		name     string
		channels []string
	}{
		{"single", []string{"1:C1"}},
		{"batch", []string{"1:C1", "1:C2"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			database := testDB(t)
			seedUser(t, database, "U1", "alice", "Alice")
			from, to := backfillRange()
			now := float64(time.Now().Unix())
			for _, ch := range tc.channels {
				seedChannel(t, database, ch, "chan-"+ch)
				// Medium activity: enough visible messages that the forward
				// path would load the running summary.
				seedRangeMessages(t, database, ch, "old-"+ch, from+3600, 35)
				_, err := database.UpsertDigest(db.Digest{
					ChannelID: ch, Type: "channel", PeriodFrom: now - 7200, PeriodTo: now - 60,
					Summary: "forward", MessageCount: 1, Model: "m",
					RunningSummary: `{"note":"PRESENT-DAY-SUMMARY"}`,
				})
				require.NoError(t, err)
			}

			gen := &promptCapturingGenerator{responses: map[string]string{
				"digest.channel_batch": batchAnswer(tc.channels...),
				"digest.channel":       validDigestJSON(),
			}}
			p := backfillPipeline(t, database, gen)
			p.TrackContext = "TRACK-CONTEXT-TODAY"

			res, _, err := p.RunBackfillWindow(context.Background(), 1, from, to)
			require.NoError(t, err)
			require.Equal(t, len(tc.channels), res.Digests)
			require.Positive(t, gen.promptsContaining("old-1:C1-0"), "the backfill prompt was rendered")
			assert.Zero(t, gen.promptsContaining("PRESENT-DAY-SUMMARY"))
			assert.Zero(t, gen.promptsContaining("PREVIOUS CONTEXT"))
			assert.Zero(t, gen.promptsContaining("TRACK-CONTEXT-TODAY"))

			// The forward path still loads it.
			assert.Contains(t, p.loadPreviousContext("1:C1", "channel"), "PRESENT-DAY-SUMMARY",
				"outside a backfill the running summary is still offered")
		})
	}
}

// TestRunBackfillRollups_PromptCarriesNoPresentDayContext pins the same rule
// for the daily rollup of a backfilled day — no latest daily running summary
// and no current track context — while the forward rollup keeps both.
func TestRunBackfillRollups_PromptCarriesNoPresentDayContext(t *testing.T) {
	database := testDB(t)
	seedChannel(t, database, "1:C1", "alpha")
	seedChannel(t, database, "1:C2", "beta")
	from, _ := backfillRange()
	yesterday := float64(utcDayStart(time.Now().AddDate(0, 0, -1)).Unix())
	for _, day := range []float64{from, yesterday} {
		for _, ch := range []string{"1:C1", "1:C2"} {
			_, err := database.UpsertDigest(db.Digest{
				ChannelID: ch, Type: "channel", PeriodFrom: day + 3600, PeriodTo: day + 7200,
				Summary: "s " + ch, MessageCount: 3, Model: "m",
			})
			require.NoError(t, err)
		}
	}
	// The newest daily rollup, two days ago, carries today's running summary.
	twoDaysAgo := float64(utcDayStart(time.Now().AddDate(0, 0, -2)).Unix())
	_, err := database.UpsertDigest(db.Digest{
		Type: "daily", PeriodFrom: twoDaysAgo, PeriodTo: twoDaysAgo + 86399,
		Summary: "recent daily", MessageCount: 3, Model: "m",
		RunningSummary: `{"note":"PRESENT-DAILY-SUMMARY"}`,
	})
	require.NoError(t, err)

	gen := &promptCapturingGenerator{responses: map[string]string{"digest.daily": validDigestJSON()}}
	p := backfillPipeline(t, database, gen)
	p.TrackContext = "TRACK-CONTEXT-TODAY"

	require.NoError(t, p.RunBackfillRollups(context.Background(), from, from+86400))
	backfillPrompt := gen.prompt(t, 0)
	assert.NotContains(t, backfillPrompt, "PRESENT-DAILY-SUMMARY")
	assert.NotContains(t, backfillPrompt, "PREVIOUS CONTEXT")
	assert.NotContains(t, backfillPrompt, "TRACK-CONTEXT-TODAY")

	// The forward rollup still carries both.
	require.NoError(t, p.runDailyRollupForDate(context.Background(), utcDayStart(time.Now().AddDate(0, 0, -1))))
	forwardPrompt := gen.prompt(t, 1)
	assert.Contains(t, forwardPrompt, "PRESENT-DAILY-SUMMARY")
	assert.Contains(t, forwardPrompt, "TRACK-CONTEXT-TODAY")
}

func TestRunBackfillWindow_OverLoadCap(t *testing.T) {
	database := testDB(t)
	seedChannel(t, database, "1:C1", "busy")
	seedUser(t, database, "U1", "alice", "Alice")
	from, to := backfillRange()
	for i := range db.DefaultTimeRangeLimit + 50 {
		seedMessage(t, database, "1:C1", fmt.Sprintf("%d.000000", int64(from)+600+int64(i)), "U1", fmt.Sprintf("busy-%d", i))
	}

	gen := &mockGenerator{response: validDigestJSON()}
	p := backfillPipeline(t, database, gen)

	res, _, err := p.RunBackfillWindow(context.Background(), 1, from, to)
	require.NoError(t, err)
	assert.True(t, res.Complete)
	assert.Equal(t, 2, res.Digests)
	assert.Len(t, channelDigests(t, database, "1:C1"), 2)
}

func TestRunBackfillWindow_DeclinedChannelDoesNotLoop(t *testing.T) {
	database := testDB(t)
	seedChannel(t, database, "1:C_REAL", "real")
	seedChannel(t, database, "1:C_NOISY", "noisy")
	seedUser(t, database, "U1", "alice", "Alice")
	from, to := backfillRange()
	seedRangeMessages(t, database, "1:C_REAL", "real", from+3600, 4)
	seedRangeMessages(t, database, "1:C_NOISY", "noisy", from+3600, 4)

	gen := &promptCapturingGenerator{responses: map[string]string{
		"digest.channel_batch": batchAnswer("1:C_REAL"),
		"digest.channel":       validDigestJSON(),
	}}
	p := backfillPipeline(t, database, gen)

	res, _, err := p.RunBackfillWindow(context.Background(), 1, from, to)
	require.NoError(t, err)
	assert.True(t, res.Complete, "the declined channel is passed by the in-memory considered mark")
	assert.Equal(t, 1, res.Digests)
	assert.Equal(t, 1, gen.promptsContaining("noisy-0"), "the declined channel is rendered once, not re-offered")

	var considered any
	require.NoError(t, database.QueryRow(`SELECT digest_considered_ts FROM channels WHERE id = '1:C_NOISY'`).Scan(&considered))
	assert.Nil(t, considered, "a backfill never writes the forward considered mark")
	require.NoError(t, database.QueryRow(`SELECT digest_considered_ts FROM channels WHERE id = '1:C_REAL'`).Scan(&considered))
	assert.Nil(t, considered)
	assert.Nil(t, p.backfill, "the backfill scope is cleared after the call")
}

func TestRunBackfillWindow_LowActivityChannelNotCooledDown(t *testing.T) {
	database := testDB(t)
	seedChannel(t, database, "1:C1", "trickle")
	seedUser(t, database, "U1", "alice", "Alice")
	from, to := backfillRange()
	seedRangeMessages(t, database, "1:C1", "trickle", from+3600, 2)

	// A forward digest written a moment ago (created_at = now).
	now := float64(time.Now().Unix())
	_, err := database.UpsertDigest(db.Digest{
		ChannelID: "1:C1", Type: "channel", PeriodFrom: now - 7200, PeriodTo: now - 60,
		Summary: "forward", MessageCount: 1, Model: "m",
	})
	require.NoError(t, err)

	gen := &mockGenerator{response: validDigestJSON()}
	p := backfillPipeline(t, database, gen)

	res, _, err := p.RunBackfillWindow(context.Background(), 1, from, to)
	require.NoError(t, err)
	assert.True(t, res.Complete)
	assert.Equal(t, 1, res.Digests, "the live-edge cooldown does not apply below every forward mark")
}

func TestRunBackfillWindow_ForwardWindowUnaffected(t *testing.T) {
	database := testDB(t)
	seedChannel(t, database, "1:C1", "alpha")
	seedUser(t, database, "U1", "alice", "Alice")
	for _, ts := range []string{"600.000000", "700.000000", "800.000000", "2500.000000"} {
		seedMessage(t, database, "1:C1", ts, "U1", "msg "+ts)
	}
	_, err := database.UpsertDigest(db.Digest{
		ChannelID: "1:C1", Type: "channel", PeriodFrom: 1000, PeriodTo: 2000,
		Summary: "forward", MessageCount: 1, Model: "m",
	})
	require.NoError(t, err)

	gen := &mockGenerator{response: validDigestJSON()}
	p := backfillPipeline(t, database, gen)

	res, _, err := p.RunBackfillWindow(context.Background(), 1, 500, 1000)
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
	require.NoError(t, database.UpsertChannel(db.Channel{ID: "1:D1", Name: "dm", Type: "dm"}))
	seedChannel(t, database, "1:C_MUTED", "muted")
	require.NoError(t, database.SetMuteForLLM("1:C_MUTED", true))
	seedUser(t, database, "U1", "alice", "Alice")
	from, to := backfillRange()
	seedRangeMessages(t, database, "1:D1", "dm", from+3600, 5)
	seedRangeMessages(t, database, "1:C_MUTED", "muted", from+3600, 5)

	gen := &mockGenerator{response: validDigestJSON()}
	p := backfillPipeline(t, database, gen)

	res, _, err := p.RunBackfillWindow(context.Background(), 1, from, to)
	require.NoError(t, err, "channels the digest never covers are not a stall")
	assert.True(t, res.Complete)
	assert.Equal(t, 0, gen.calls)
}

func TestRunBackfillWindow_FastForwardFloorApplies(t *testing.T) {
	database := testDB(t)
	seedChannel(t, database, "1:C1", "alpha")
	seedUser(t, database, "U1", "alice", "Alice")
	from, to := backfillRange()
	seedRangeMessages(t, database, "1:C1", "alpha", from+3600, 5)
	require.NoError(t, database.UpsertWorkspace(db.Workspace{ID: "T1", Name: "acme", Domain: "acme"}))
	require.NoError(t, database.SetDigestFastForwardTS(to))

	gen := &mockGenerator{response: validDigestJSON()}
	p := backfillPipeline(t, database, gen)

	res, _, err := p.RunBackfillWindow(context.Background(), 1, from, to)
	require.NoError(t, err)
	assert.True(t, res.Complete)
	assert.Equal(t, 0, gen.calls, "FEAT-03: history below the fast-forward floor stays undigested")
}

func TestRunBackfillWindow_DisabledIsComplete(t *testing.T) {
	database := testDB(t)
	seedChannel(t, database, "1:C1", "alpha")
	seedUser(t, database, "U1", "alice", "Alice")
	from, to := backfillRange()
	seedRangeMessages(t, database, "1:C1", "alpha", from+3600, 5)

	gen := &mockGenerator{response: validDigestJSON()}
	p := backfillPipeline(t, database, gen)
	p.cfg.Digest.Enabled = false

	res, _, err := p.RunBackfillWindow(context.Background(), 1, from, to)
	require.NoError(t, err)
	assert.Equal(t, BackfillWindowResult{Digests: 0, Complete: true}, res)
	assert.Equal(t, 0, gen.calls)
}

func TestRunBackfillWindow_LockContentionIsIncomplete(t *testing.T) {
	database := testDB(t)
	seedChannel(t, database, "1:C1", "alpha")
	seedUser(t, database, "U1", "alice", "Alice")
	from, to := backfillRange()
	seedRangeMessages(t, database, "1:C1", "alpha", from+3600, 5)

	gen := &mockGenerator{response: validDigestJSON()}
	p := backfillPipeline(t, database, gen)
	_, unlock, err := p.acquireDigestLock()
	require.NoError(t, err)
	defer unlock()

	res, _, err := p.RunBackfillWindow(context.Background(), 1, from, to)
	require.NoError(t, err)
	assert.Equal(t, BackfillWindowResult{Digests: 0, Complete: false}, res)
	assert.Equal(t, 0, gen.calls)
}

// blockDigestLockDir makes the digest lock's directory unusable: a regular
// file sits where the workspace dir should be, so MkdirAll fails.
func blockDigestLockDir(t *testing.T, p *Pipeline) {
	t.Helper()
	dir := p.cfg.WorkspaceDir()
	require.NoError(t, os.MkdirAll(filepath.Dir(dir), 0o700))
	require.NoError(t, os.RemoveAll(dir))
	require.NoError(t, os.WriteFile(dir, []byte("x"), 0o600))
}

// F8: only flock contention is a hold; any other lock error is a failure.
func TestRunBackfillWindow_LockSetupErrorIsAFailure(t *testing.T) {
	database := testDB(t)
	gen := &mockGenerator{response: validDigestJSON()}
	p := backfillPipeline(t, database, gen)
	blockDigestLockDir(t, p)
	from, to := backfillRange()

	res, _, err := p.RunBackfillWindow(context.Background(), 1, from, to)
	require.Error(t, err)
	assert.NotErrorIs(t, err, ErrDigestLocked)
	assert.False(t, res.Complete)
}

func TestRunBackfillRollups_LockErrors(t *testing.T) {
	database := testDB(t)
	gen := &mockGenerator{response: validDigestJSON()}
	p := backfillPipeline(t, database, gen)
	from, to := backfillRange()

	_, unlock, err := p.acquireDigestLock()
	require.NoError(t, err)
	err = p.RunBackfillRollups(context.Background(), from, to)
	unlock()
	require.ErrorIs(t, err, ErrDigestLocked, "contention is recognisable, so the caller can hold")

	blockDigestLockDir(t, p)
	err = p.RunBackfillRollups(context.Background(), from, to)
	require.Error(t, err)
	assert.NotErrorIs(t, err, ErrDigestLocked)
}

func TestRunBackfillWindow_CancelledContext(t *testing.T) {
	database := testDB(t)
	seedChannel(t, database, "1:C1", "alpha")
	seedUser(t, database, "U1", "alice", "Alice")
	from, to := backfillRange()
	seedRangeMessages(t, database, "1:C1", "alpha", from+3600, 5)

	gen := &mockGenerator{response: validDigestJSON()}
	p := backfillPipeline(t, database, gen)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	res, _, err := p.RunBackfillWindow(ctx, 1, from, to)
	require.ErrorIs(t, err, context.Canceled)
	assert.False(t, res.Complete)
}

func TestRunBackfillRollups_EachUTCDay(t *testing.T) {
	database := testDB(t)
	seedChannel(t, database, "1:C1", "alpha")
	seedChannel(t, database, "2:C2", "beta")
	from, to := backfillRange()
	for _, day := range []float64{from, from + 86400} {
		for _, ch := range []string{"1:C1", "2:C2"} {
			_, err := database.UpsertDigest(db.Digest{
				ChannelID: ch, Type: "channel", PeriodFrom: day + 3600, PeriodTo: day + 7200,
				Summary: "s " + ch, MessageCount: 3, Model: "m",
			})
			require.NoError(t, err)
		}
	}

	gen := &promptCapturingGenerator{responses: map[string]string{"digest.daily": validDigestJSON()}}
	p := backfillPipeline(t, database, gen)

	require.NoError(t, p.RunBackfillRollups(context.Background(), from, to))
	daily, err := database.GetDigests(db.DigestFilter{Type: "daily"})
	require.NoError(t, err)
	assert.Len(t, daily, 2, "one daily rollup per UTC day of the chunk")
	// Daily rollups stay workspace-global (F1): one rollup covers every
	// Slack account's channel digests of the day.
	assert.Contains(t, gen.prompt(t, 0), "s 1:C1")
	assert.Contains(t, gen.prompt(t, 0), "s 2:C2")
}
