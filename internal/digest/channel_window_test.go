package digest

import (
	"bytes"
	"context"
	"fmt"
	"log"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

// channelKeyedGenerator fails every call whose prompt names failChannel and
// succeeds for every other call, so one channel's digest can fail inside a run
// that another channel's digest completes.
type channelKeyedGenerator struct {
	mu          sync.Mutex
	failChannel string
	response    string
	calls       int
}

func (g *channelKeyedGenerator) Generate(_ context.Context, systemPrompt, userMessage, _ string) (string, *Usage, string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.calls++
	if g.failChannel != "" && strings.Contains(systemPrompt+userMessage, g.failChannel) {
		return "", nil, "", fmt.Errorf("simulated AI failure for #%s", g.failChannel)
	}
	return g.response, &Usage{Model: "test-model", InputTokens: 10, OutputTokens: 5}, "mock-session", nil
}

func (g *channelKeyedGenerator) recover() {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.failChannel = ""
}

// TestChannelWindow_FailedChannelKeepsItsUndigestedMessages is the regression
// guard for the global digest watermark: one run-level "since" scalar meant a
// channel whose digest failed (or was capped out, or was skipped by the
// cooldown) had its messages skipped forever, because the next cycle's window
// started after the messages that the channels which DID succeed covered.
//
// Per channel, the window now starts at that channel's own digests.period_to.
// Without the fix the failed channel's next window would start at the healthy
// channel's period_to — past the messages it never digested — and the assertion
// on `failed.since` below fails.
func TestChannelWindow_FailedChannelKeepsItsUndigestedMessages(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()
	cfg.Digest.MinMessages = 5
	cfg.Digest.BatchMaxChannels = 1 // one AI call per channel, so one can fail alone

	seedChannel(t, database, "C_OK", "steady")
	seedChannel(t, database, "C_FAIL", "flaky")
	seedUser(t, database, "U1", "alice", "Alice")

	// Cycle one: both channels carry the same 35 messages (medium tier ≥30, so
	// BatchMaxChannels=1 forces an individual prompt each).
	firstTS := time.Now().Add(-2 * time.Hour).Unix()
	lastTS := firstTS
	for i := range 35 {
		lastTS = firstTS + int64(i*10)
		ts := fmt.Sprintf("%d.%06d", lastTS, i)
		seedMessage(t, database, "C_OK", ts, "U1", fmt.Sprintf("steady msg %d", i))
		seedMessage(t, database, "C_FAIL", ts, "U1", fmt.Sprintf("flaky msg %d", i))
	}

	gen := &channelKeyedGenerator{failChannel: "flaky", response: validDigestJSON()}
	p := New(database, cfg, gen, testLogger())

	n, _, err := p.RunChannelDigests(context.Background())
	require.NoError(t, err, "one failure next to one success is not a whole-run failure")
	require.Equal(t, 1, n, "only the healthy channel produced a digest")

	okDigest, err := database.GetLatestDigest("C_OK", "channel")
	require.NoError(t, err)
	require.NotNil(t, okDigest, "the healthy channel was digested")
	failDigest, err := database.GetLatestDigest("C_FAIL", "channel")
	require.NoError(t, err)
	require.Nil(t, failDigest, "the failing channel stored nothing")

	// Cycle two: one new message in each channel, so both are candidates again.
	newTS := time.Now().Add(-1 * time.Minute).Unix()
	seedMessage(t, database, "C_OK", fmt.Sprintf("%d.000000", newTS), "U1", "steady follow-up")
	seedMessage(t, database, "C_FAIL", fmt.Sprintf("%d.000000", newTS), "U1", "flaky follow-up")

	windows, err := p.resolveChannelWindows(float64(time.Now().Unix()))
	require.NoError(t, err)
	byChannel := make(map[string]float64, len(windows))
	for _, w := range windows {
		byChannel[w.channelID] = w.since
	}
	require.Contains(t, byChannel, "C_FAIL")
	require.Contains(t, byChannel, "C_OK")

	assert.Less(t, byChannel["C_FAIL"], float64(firstTS),
		"the failed channel's next window must still start before the messages it never digested")
	assert.Less(t, byChannel["C_FAIL"], okDigest.PeriodTo,
		"the healthy channel's success must not move the failed channel's window")
	assert.GreaterOrEqual(t, byChannel["C_OK"], float64(lastTS),
		"the healthy channel's window must start after the messages it already digested")

	// And the recovered run actually digests the lost messages.
	gen.recover()
	n, _, err = p.RunChannelDigests(context.Background())
	require.NoError(t, err)
	assert.GreaterOrEqual(t, n, 1)

	failDigest, err = database.GetLatestDigest("C_FAIL", "channel")
	require.NoError(t, err)
	require.NotNil(t, failDigest, "the previously failed channel is digested on the next cycle")
	assert.Equal(t, 36, failDigest.MessageCount,
		"the recovered digest covers the 35 messages of the failed cycle plus the new one")
}

// promptCapturingGenerator records every prompt it is handed and answers from a
// per-source response table, so a test can assert on what was actually rendered
// into each cycle's call rather than on a watermark column.
type promptCapturingGenerator struct {
	mu        sync.Mutex
	responses map[string]string // digest source → response
	prompts   []string
}

func (g *promptCapturingGenerator) Generate(ctx context.Context, systemPrompt, userMessage, _ string) (string, *Usage, string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.prompts = append(g.prompts, systemPrompt+userMessage)
	return g.responses[sourceFromContext(ctx)], &Usage{Model: "test-model", InputTokens: 10, OutputTokens: 5}, "mock-session", nil
}

func (g *promptCapturingGenerator) prompt(t *testing.T, i int) string {
	t.Helper()
	g.mu.Lock()
	defer g.mu.Unlock()
	require.Greater(t, len(g.prompts), i, "expected at least %d AI call(s)", i+1)
	return g.prompts[i]
}

// sawPrompt reports whether any prompt so far contained needle.
func (g *promptCapturingGenerator) sawPrompt(needle string) bool {
	return g.promptsContaining(needle) > 0
}

// promptsContaining counts how many prompts so far carried needle — one means
// rendered exactly once, more means re-rendered across cycles.
func (g *promptCapturingGenerator) promptsContaining(needle string) int {
	g.mu.Lock()
	defer g.mu.Unlock()
	n := 0
	for _, p := range g.prompts {
		if strings.Contains(p, needle) {
			n++
		}
	}
	return n
}

// TestChannelWindow_DeclinedChannelStillMovesOn pins the stall that a
// per-channel window derived from digests.period_to alone creates. The batch
// prompt tells the model to SKIP channels where nothing noteworthy happened, so
// a declined channel writes no digests row and its period_to never moves: it is
// re-offered every cycle with a widening window whose oldest part eventually
// cannot fit under the per-channel message cap, and the channel goes dark.
//
// channels.digest_considered_ts separates "digested through" from "considered
// through": material the model saw and declined still advances the window. The
// assertion is on the SECOND cycle's rendered prompt — a column-value check
// would not have caught the original defect.
func TestChannelWindow_DeclinedChannelStillMovesOn(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()
	cfg.Digest.MinMessages = 1 // keep the cooldown out of the way on cycle two

	seedChannel(t, database, "C_NOISY", "noisy")
	seedChannel(t, database, "C_REAL", "real")
	seedUser(t, database, "U1", "alice", "Alice")

	firstTS := time.Now().Add(-2 * time.Hour).Unix()
	for i := range 4 {
		ts := fmt.Sprintf("%d.%06d", firstTS+int64(i*10), i)
		seedMessage(t, database, "C_NOISY", ts, "U1", fmt.Sprintf("declined-chatter-%d", i))
		seedMessage(t, database, "C_REAL", ts, "U1", fmt.Sprintf("real-work-%d", i))
	}

	// The model answers for C_REAL only — C_NOISY is declined as unremarkable.
	gen := &promptCapturingGenerator{responses: map[string]string{
		"digest.channel_batch": `[{"channel_id":"C_REAL","summary":"Real work","topics":[{"title":"t","summary":"s","decisions":[],"action_items":[],"situations":[],"key_messages":[]}]}]`,
		"digest.channel":       validDigestJSON(),
	}}
	p := New(database, cfg, gen, testLogger())

	n, _, err := p.RunChannelDigests(context.Background())
	require.NoError(t, err)
	require.Equal(t, 1, n, "only C_REAL produced a digest")
	require.Contains(t, gen.prompt(t, 0), "declined-chatter-0", "cycle one rendered the noisy channel's messages")

	noisyDigest, err := database.GetLatestDigest("C_NOISY", "channel")
	require.NoError(t, err)
	require.Nil(t, noisyDigest, "a declined channel writes no digest row — that is why period_to alone stalls")

	// New traffic in both channels.
	newTS := time.Now().Add(-1 * time.Minute).Unix()
	seedMessage(t, database, "C_NOISY", fmt.Sprintf("%d.000000", newTS), "U1", "declined-chatter-fresh")
	seedMessage(t, database, "C_REAL", fmt.Sprintf("%d.000000", newTS), "U1", "real-work-fresh")

	before := len(gen.prompts)
	n, _, err = p.RunChannelDigests(context.Background())
	require.NoError(t, err)
	_ = n

	second := gen.prompt(t, before)
	assert.Contains(t, second, "declined-chatter-fresh",
		"cycle two must present the declined channel's NEW messages")
	assert.NotContains(t, second, "declined-chatter-0",
		"cycle two must not re-render what the model already declined — that is the stall")
}

// TestChannelWindow_BacklogBeyondMessageCapDrainsForward pins the other half of
// the same stall: the per-channel load is capped at db.DefaultTimeRangeLimit
// rows, so a backlog wider than the cap cannot reach one prompt. The load is
// oldest-first precisely so the remainder sits at the NEWER end, where the
// advancing watermark can reach it next cycle; a newest-first load would strand
// the older remainder below a watermark that never moves back.
func TestChannelWindow_BacklogBeyondMessageCapDrainsForward(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()

	seedChannel(t, database, "C_BACKLOG", "backlog")
	seedUser(t, database, "U1", "alice", "Alice")

	// One message per second, more than the cap, all inside the first-run window.
	const total = db.DefaultTimeRangeLimit + 100
	firstTS := time.Now().Add(-2 * time.Hour).Unix()
	for i := range total {
		ts := fmt.Sprintf("%d.000000", firstTS+int64(i))
		seedMessage(t, database, "C_BACKLOG", ts, "U1", fmt.Sprintf("backlog-msg-%d-end", i))
	}

	gen := &promptCapturingGenerator{responses: map[string]string{
		"digest.channel":       validDigestJSON(),
		"digest.channel_batch": `[]`,
	}}
	p := New(database, cfg, gen, testLogger())

	_, _, err := p.RunChannelDigests(context.Background())
	require.NoError(t, err)

	first := gen.prompt(t, 0)
	assert.Contains(t, first, "backlog-msg-0-end", "cycle one starts at the oldest message")
	assert.NotContains(t, first, fmt.Sprintf("backlog-msg-%d-end", total-1),
		"the newest messages cannot fit under the cap in cycle one")

	before := len(gen.prompts)
	_, _, err = p.RunChannelDigests(context.Background())
	require.NoError(t, err)

	second := gen.prompt(t, before)
	assert.Contains(t, second, fmt.Sprintf("backlog-msg-%d-end", total-1),
		"cycle two must reach the remainder the cap left behind")
	assert.NotContains(t, second, "backlog-msg-0-end",
		"cycle two must not re-render the part already digested")
}

// TestChannelWindow_CappedChannelsAreDeferredNotDropped covers the second loss
// path of the same defect, driving the real per-run batch budget: with more
// batches than config.DefaultMaxBatchesPerRun, planChannelBatches drops the
// smallest ones, and under a global watermark the successes of the batches that
// did run moved the next window start past the dropped channels' messages. The
// deferred channel must still be a CANDIDATE next cycle — asserting only that
// its window is wide would also pass if it had been dropped from the candidate
// set entirely, which is the failure being guarded against.
func TestChannelWindow_CappedChannelsAreDeferredNotDropped(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()
	cfg.Digest.MinMessages = 5
	cfg.Digest.BatchMaxChannels = 1 // one channel per batch, so channels == batches

	seedUser(t, database, "U1", "alice", "Alice")
	firstTS := time.Now().Add(-2 * time.Hour).Unix()

	// One channel more than the budget allows. The smallest sorts last in the
	// cap's by-message-count ordering, so it is deterministically the one
	// dropped; its newest message is older than every other channel's, so a
	// global watermark would bury it.
	const channels = config.DefaultMaxBatchesPerRun + 1
	const deferredID = "C_DEFERRED"
	for c := range channels - 1 {
		id := fmt.Sprintf("C%d", c)
		seedChannel(t, database, id, fmt.Sprintf("chan-%d", c))
		for i := range 35 {
			ts := fmt.Sprintf("%d.%06d", firstTS+int64(i*10), i)
			seedMessage(t, database, id, ts, "U1", fmt.Sprintf("msg %d", i))
		}
	}
	seedChannel(t, database, deferredID, "deferred")
	for i := range 30 {
		ts := fmt.Sprintf("%d.%06d", firstTS+int64(i*10), i)
		seedMessage(t, database, deferredID, ts, "U1", fmt.Sprintf("deferred msg %d", i))
	}

	gen := &threadSafeMockGenerator{response: validDigestJSON()}
	p := New(database, cfg, gen, testLogger())

	n, _, err := p.RunChannelDigests(context.Background())
	require.NoError(t, err)
	require.Equal(t, config.DefaultMaxBatchesPerRun, n, "the per-run batch budget caps the cycle")

	deferred, err := database.GetLatestDigest(deferredID, "channel")
	require.NoError(t, err)
	require.Nil(t, deferred, "the capped-out channel was not digested")

	since := windowFor(t, p, deferredID)
	require.GreaterOrEqual(t, since, 0.0, "the capped-out channel must still be a candidate next cycle")
	assert.Less(t, since, float64(firstTS), "its window must still cover the messages it never digested")

	n, _, err = p.RunChannelDigests(context.Background())
	require.NoError(t, err)
	assert.GreaterOrEqual(t, n, 1)

	deferred, err = database.GetLatestDigest(deferredID, "channel")
	require.NoError(t, err)
	require.NotNil(t, deferred, "the deferred channel is digested on the next cycle")
	assert.Equal(t, 30, deferred.MessageCount, "with all of its backlog, none of it dropped")
}

// TestChannelWindow_BotOnlyBacklogDoesNotLockOutLaterHumanMessages pins the
// mechanical-skip half of the considered-through mark. buildBatchEntry drops a
// bot-only or no-visible-text channel BEFORE any AI call, so without a stamp on
// those decisions the window never moves — and with an oldest-first load capped
// at db.DefaultTimeRangeLimit rows, a backlog wider than the cap pins the window
// at its head permanently: every later message, human ones included, is never
// even loaded. A mechanical skip is a decision code made over messages it fully
// read, so it counts as considered; only a failed load stamps nothing.
func TestChannelWindow_BotOnlyBacklogDoesNotLockOutLaterHumanMessages(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()

	seedChannel(t, database, "C_ALERTS", "alerts")
	require.NoError(t, database.UpsertUser(db.User{ID: "UBOT", Name: "alertbot", IsBot: true}))
	seedUser(t, database, "U1", "alice", "Alice")

	const bots = db.DefaultTimeRangeLimit + 50
	firstTS := time.Now().Add(-6 * time.Hour).Unix()
	for i := range bots {
		seedMessage(t, database, "C_ALERTS", fmt.Sprintf("%d.000000", firstTS+int64(i)), "UBOT", fmt.Sprintf("alert %d", i))
	}
	seedMessage(t, database, "C_ALERTS",
		fmt.Sprintf("%d.000000", firstTS+int64(bots)+60), "U1", "human-needs-this-digested")

	gen := &promptCapturingGenerator{responses: map[string]string{
		"digest.channel":       validDigestJSON(),
		"digest.channel_batch": `[]`,
	}}
	p := New(database, cfg, gen, testLogger())

	reached := false
	for range 5 {
		_, _, err := p.RunChannelDigests(context.Background())
		require.NoError(t, err)
		if gen.sawPrompt("human-needs-this-digested") {
			reached = true
			break
		}
	}
	assert.True(t, reached,
		"a bot-only backlog wider than the row cap must not lock the channel out of every later prompt")
}

// TestChannelWindow_WholeSecondBurstOvershootsTheRowCap covers the one load the
// cap must be allowed to exceed. When every row of a capped load shares one
// ts_unix second, trimming the partial boundary second would leave nothing to
// render — and because the next window starts AT that second, the load would
// refill with exactly those rows every cycle and never reach anything after
// them. Reloading past the cap keeps the channel moving; the overshoot is
// bounded by db.BoundarySecondRowLimit.
func TestChannelWindow_WholeSecondBurstOvershootsTheRowCap(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()
	cfg.Digest.MinMessages = 1 // keep the cooldown out of the way on cycle two

	seedChannel(t, database, "C_BURST", "burst")
	seedUser(t, database, "U1", "alice", "Alice")

	const inOneSecond = db.DefaultTimeRangeLimit + 20
	sec := time.Now().Add(-2 * time.Hour).Unix()
	for i := range inOneSecond {
		seedMessage(t, database, "C_BURST", fmt.Sprintf("%d.%06d", sec, i+1), "U1", fmt.Sprintf("burst-%d-end", i))
	}
	seedMessage(t, database, "C_BURST", fmt.Sprintf("%d.000000", sec+120), "U1", "after-the-burst")

	gen := &promptCapturingGenerator{responses: map[string]string{
		"digest.channel":       validDigestJSON(),
		"digest.channel_batch": `[]`,
	}}
	p := New(database, cfg, gen, testLogger())

	_, _, err := p.RunChannelDigests(context.Background())
	require.NoError(t, err)

	first := gen.prompt(t, 0)
	assert.Contains(t, first, fmt.Sprintf("burst-%d-end", inOneSecond-1),
		"the whole second must be rendered, over the row cap")
	assert.Contains(t, first, "after-the-burst",
		"the message after the burst must be reachable, not stranded behind a window that never moves")

	assert.Equal(t, float64(-1), windowFor(t, p, "C_BURST"),
		"with the burst consumed the channel has nothing left to offer")
}

// TestChannelWindow_CapSpanningTwoSecondsStillAdvances pins the progress
// invariant at the boundary trim. A capped load spanning exactly two seconds
// trims back to the first of them — which, from the second cycle on, IS the
// window's own start, so the mark restamps where it already was. Discovery
// keeps offering the channel, so it burns one AI call and one zero-width
// digests row every cycle while the later second never renders. Trimming to
// nothing and trimming back to the window start are the same dead end, and both
// must take the over-cap reload.
func TestChannelWindow_CapSpanningTwoSecondsStillAdvances(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()

	seedChannel(t, database, "C_BURSTY", "bursty")
	seedUser(t, database, "U1", "alice", "Alice")

	// A burst wider than the cap across exactly two seconds: the cap lands
	// inside the second one, and the trim backs off to the first.
	const firstSecond = 400
	const secondSecond = 200
	base := time.Now().Add(-6 * time.Hour).Unix()
	for i := range firstSecond {
		seedMessage(t, database, "C_BURSTY", fmt.Sprintf("%d.%06d", base, i+1), "U1", fmt.Sprintf("at-T-%d-end", i))
	}
	for i := range secondSecond {
		seedMessage(t, database, "C_BURSTY", fmt.Sprintf("%d.%06d", base+1, i+1), "U1", fmt.Sprintf("at-T1-%d-end", i))
	}

	gen := &promptCapturingGenerator{responses: map[string]string{
		"digest.channel":       validDigestJSON(),
		"digest.channel_batch": `[]`,
	}}
	p := New(database, cfg, gen, testLogger())

	for range 4 {
		_, _, err := p.RunChannelDigests(context.Background())
		require.NoError(t, err)
	}

	assert.True(t, gen.sawPrompt(fmt.Sprintf("at-T1-%d-end", secondSecond-1)),
		"the later second must reach a prompt — a trim back to the window start makes no progress")
	assert.Equal(t, float64(-1), windowFor(t, p, "C_BURSTY"),
		"with the burst consumed the channel has nothing left to offer")
}

// TestChannelWindow_FutureTimestampsDoNotKeepAChannelSpinning pins that
// discovery and the loader agree about which messages exist. Discovery tested
// `MAX(ts_unix) > mark` with no upper bound while the load is bounded by the
// nowUnix sampled at the top of the run, so a message whose Slack-assigned
// ts_unix sits ahead of the local clock — clock skew, or the narrow sync race —
// made a channel a candidate the load could not serve. Two shapes followed: a
// window that loads empty (one wasted load per cycle), or one that reloads the
// same second and writes a zero-width digest row after an AI call, every cycle.
// Self-healing once wall-clock passes the timestamp, but silent until then.
func TestChannelWindow_FutureTimestampsDoNotKeepAChannelSpinning(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()
	cfg.Digest.MinMessages = 1 // keep the cooldown out of the way after cycle one

	seedChannel(t, database, "C_AHEAD_ONLY", "ahead-only")
	seedChannel(t, database, "C_AHEAD_TAIL", "ahead-tail")
	seedUser(t, database, "U1", "alice", "Alice")

	// No volume needed: the defect is in a predicate, not a cap.
	future := time.Now().Add(1 * time.Hour).Unix()
	seedMessage(t, database, "C_AHEAD_ONLY", fmt.Sprintf("%d.000000", future), "U1", "from-the-future")

	// The second channel has loadable traffic in one second plus a future tail,
	// so after cycle one digests that second the future message is all that
	// would keep it a candidate.
	sec := time.Now().Add(-2 * time.Hour).Unix()
	for i := range 5 {
		seedMessage(t, database, "C_AHEAD_TAIL", fmt.Sprintf("%d.%06d", sec, i+1), "U1", fmt.Sprintf("loadable-%d-end", i))
	}
	seedMessage(t, database, "C_AHEAD_TAIL", fmt.Sprintf("%d.000000", future), "U1", "tail-from-the-future")

	gen := &promptCapturingGenerator{responses: map[string]string{
		"digest.channel":       validDigestJSON(),
		"digest.channel_batch": `[]`,
	}}
	p := New(database, cfg, gen, testLogger())

	assert.Equal(t, float64(-1), windowFor(t, p, "C_AHEAD_ONLY"),
		"a channel whose only message the load cannot serve must never be offered")

	for range 3 {
		_, _, err := p.RunChannelDigests(context.Background())
		require.NoError(t, err)
	}

	assert.Equal(t, 1, gen.promptsContaining("loadable-0-end"),
		"the loadable second is digested once, not re-rendered every cycle behind a future message")
	assert.Equal(t, float64(-1), windowFor(t, p, "C_AHEAD_TAIL"),
		"and the channel stops being offered once everything the load can serve is covered")

	digests, err := database.GetDigests(db.DigestFilter{ChannelID: "C_AHEAD_TAIL", Type: "channel"})
	require.NoError(t, err)
	require.Len(t, digests, 1, "exactly one digest row, not one zero-width row per cycle")
	assert.Greater(t, digests[0].PeriodTo, digests[0].PeriodFrom, "and it covers a real window")
}

// TestChannelWindow_CeilingBreachAdvancesLoudly pins the last place the
// progress invariant could have been broken rather than asserted: when even the
// BoundarySecondRowLimit reload cannot get past the second the window opens on,
// because that single second holds more rows than the ceiling.
//
// The disposition is to advance past that second anyway — losing what did not
// fit — and to say so with a counted ERROR naming the channel, the second and
// the number skipped. Freezing there would burn one AI call and one zero-width
// digest row every cycle forever, indistinguishable in the logs from a quiet
// channel. Unreachable through Slack; asserted so the invariant holds
// everywhere the code claims it does.
func TestChannelWindow_CeilingBreachAdvancesLoudly(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()
	cfg.Digest.MinMessages = 1 // keep the cooldown out of the way after cycle one

	seedChannel(t, database, "C_CEILING", "ceiling")
	seedUser(t, database, "U1", "alice", "Alice")

	// One row past the ceiling, all inside a single second, so not even the
	// over-cap reload can leave that second.
	//
	// Seeded in one statement, and all but the first few rows with empty text:
	// the messages_ai FTS trigger skips an empty message, and it is quadratic
	// otherwise (a full messages_fts scan per inserted row), which would cost
	// this test ~19s. The few visible rows are the oldest of the second, so the
	// load carries them and the channel takes the ordinary accepted path.
	const inOneSecond = db.BoundarySecondRowLimit + 1
	const visible = 5
	sec := time.Now().Add(-6 * time.Hour).Unix()
	for i := range visible {
		seedMessage(t, database, "C_CEILING", fmt.Sprintf("%d.%06d", sec, i+1), "U1", fmt.Sprintf("ceiling-%d-end", i))
	}
	_, err := database.Exec(`
		WITH RECURSIVE seq(n) AS (SELECT ? UNION ALL SELECT n + 1 FROM seq WHERE n < ?)
		INSERT INTO messages (channel_id, ts, user_id, text)
		SELECT 'C_CEILING', printf('%d.%06d', ?, n), 'U1', '' FROM seq`,
		visible+1, inOneSecond, sec)
	require.NoError(t, err)
	seedMessage(t, database, "C_CEILING", fmt.Sprintf("%d.000000", sec+120), "U1", "after-the-ceiling")

	var logBuf bytes.Buffer
	gen := &promptCapturingGenerator{responses: map[string]string{
		"digest.channel":       validDigestJSON(),
		"digest.channel_batch": `[]`,
	}}
	p := New(database, cfg, gen, log.New(&logBuf, "", 0))

	for range 3 {
		_, _, err := p.RunChannelDigests(context.Background())
		require.NoError(t, err)
	}

	assert.Contains(t, logBuf.String(), "ERROR: #ceiling",
		"a breach of the row ceiling must be loud, naming the channel")
	assert.Contains(t, logBuf.String(), fmt.Sprintf("in second %d", sec),
		"and naming the second it could not get past")
	assert.Contains(t, logBuf.String(), "leaving 1 unrendered",
		"and counting what it skipped")

	assert.True(t, gen.sawPrompt("after-the-ceiling"),
		"the window must advance past the stuck second, not freeze on it")
	assert.Equal(t, float64(-1), windowFor(t, p, "C_CEILING"),
		"and the channel must finish rather than re-offer the same second forever")
}

// TestChannelWindow_BotHeavyContextInsideTheOpeningSecondStillAdvances pins the
// same invariant on the accepted path. extractHumanContext keeps each human
// message plus a few neighbours; when the human replies and their neighbours
// all sit in the window's opening second, the rendered subset's newest message
// IS the window start and the mark does not move. The extraction read the whole
// load and dropped the rest as noise, so the mark records that instead.
func TestChannelWindow_BotHeavyContextInsideTheOpeningSecondStillAdvances(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()

	seedChannel(t, database, "C_ALERTS2", "alerts-two")
	require.NoError(t, database.UpsertUser(db.User{ID: "UBOT", Name: "alertbot", IsBot: true}))
	seedUser(t, database, "U1", "alice", "Alice")

	// One human reply buried in alerts, all inside a single second — wide
	// enough on both sides that the ±3 context window cannot escape it.
	base := time.Now().Add(-6 * time.Hour).Unix()
	seq := 0
	seedAt := func(sec int64, user, text string) {
		seq++
		seedMessage(t, database, "C_ALERTS2", fmt.Sprintf("%d.%06d", sec, seq), user, text)
	}
	for i := range 15 {
		seedAt(base, "UBOT", fmt.Sprintf("opening alert %d", i))
	}
	seedAt(base, "U1", "looking into this")
	for i := range 15 {
		seedAt(base, "UBOT", fmt.Sprintf("trailing alert %d", i))
	}
	// Bot-only traffic afterwards, which the extraction drops as noise.
	for i := range 50 {
		seedAt(base+10+int64(i), "UBOT", fmt.Sprintf("later alert %d", i))
	}

	gen := &promptCapturingGenerator{responses: map[string]string{
		"digest.channel":       validDigestJSON(),
		"digest.channel_batch": `[]`,
	}}
	p := New(database, cfg, gen, testLogger())

	for range 4 {
		_, _, err := p.RunChannelDigests(context.Background())
		require.NoError(t, err)
	}

	assert.Equal(t, float64(-1), windowFor(t, p, "C_ALERTS2"),
		"a bot-heavy channel whose context stays in the opening second must still finish its window")
}

// TestRenderBatchChannelBlocks_UnrenderedEntryIsNotConsidered pins the safety
// property its doc comment claims: an entry that contributes nothing to the
// prompt must not be reported back as rendered, because the caller stamps the
// considered-through mark for exactly that set. buildBatchEntry cannot produce
// such an entry today (it accepts only entries with visible messages), so this
// is asserted at the seam that would carry the claim if it ever could.
func TestRenderBatchChannelBlocks_UnrenderedEntryIsNotConsidered(t *testing.T) {
	database := testDB(t)
	seedChannel(t, database, "C_REAL", "real")
	seedChannel(t, database, "C_BLANK", "blank")
	seedUser(t, database, "U1", "alice", "Alice")

	p := New(database, testConfig(), &mockGenerator{}, testLogger())
	p.loadCaches()

	entries := []batchEntry{
		{channelID: "C_REAL", channelName: "real", since: 1000, msgs: []db.Message{
			{TS: "1100.000001", UserID: "U1", Text: "something to say", TSUnix: 1100},
		}, visibleCount: 1},
		{channelID: "C_BLANK", channelName: "blank", since: 1000, msgs: []db.Message{
			{TS: "1200.000001", UserID: "U1", Text: "", TSUnix: 1200},
			{TS: "1300.000001", UserID: "U1", Text: "deleted", IsDeleted: true, TSUnix: 1300},
		}, visibleCount: 1},
	}

	blocks, rendered := p.renderBatchChannelBlocks(entries, "2026-01-01 00:00")

	require.Len(t, rendered, 1, "only the entry that produced a block is reported")
	assert.Equal(t, "C_REAL", rendered[0].channelID)
	assert.Contains(t, blocks, "something to say")
	assert.NotContains(t, blocks, "C_BLANK", "an entry with nothing to render contributes no block")
}

// TestChannelWindow_MinMessagesAboveTheLoadCapStillAdvances pins the last
// mechanical skip. digest.min_messages has no upper clamp, so a value above
// db.DefaultTimeRangeLimit makes "0 visible and fewer than MinMessages of them"
// permanently true for a capped load: the channel takes batchEntrySkipBelowMin
// every cycle, and if that status did not stamp, the window would pin at the
// head of the backlog and the visible message behind it would never be loaded.
//
// The skip is safe to stamp because it is reachable only when every loaded
// message is empty or deleted — re-deciding next cycle over a superset returns
// the same verdict.
func TestChannelWindow_MinMessagesAboveTheLoadCapStillAdvances(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()
	cfg.Digest.MinMessages = db.DefaultTimeRangeLimit + 100 // no upper clamp exists

	seedChannel(t, database, "C_QUIET", "quiet")
	seedUser(t, database, "U1", "alice", "Alice")

	// An all-invisible backlog wider than the load cap, then the message that
	// matters sitting behind it.
	const invisible = db.DefaultTimeRangeLimit + 100
	firstTS := time.Now().Add(-6 * time.Hour).Unix()
	for i := range invisible {
		seedMessage(t, database, "C_QUIET", fmt.Sprintf("%d.000000", firstTS+int64(i)), "U1", "")
	}
	seedMessage(t, database, "C_QUIET",
		fmt.Sprintf("%d.000000", firstTS+int64(invisible)+60), "U1", "visible-behind-the-backlog")

	gen := &promptCapturingGenerator{responses: map[string]string{
		"digest.channel":       validDigestJSON(),
		"digest.channel_batch": `[]`,
	}}
	p := New(database, cfg, gen, testLogger())

	reached := false
	for range 5 {
		_, _, err := p.RunChannelDigests(context.Background())
		require.NoError(t, err)
		if gen.sawPrompt("visible-behind-the-backlog") {
			reached = true
			break
		}
	}
	assert.True(t, reached,
		"a min_messages above the load cap must not pin the window at the head of an invisible backlog")
}

// TestChannelWindow_CapInsideASecondLosesNothing pins trimPartialBoundarySecond
// itself. messages.ts_unix has whole-second resolution, so when the row cap
// lands part-way through a second, a mark stamped from the newest loaded
// message cannot express "part of second N" — and discovery's test is a strict
// `newest > mark`, so the siblings that did not fit fall out of the candidate
// set entirely. Trimming back to the last whole second costs re-rendering that
// second and loses nothing.
func TestChannelWindow_CapInsideASecondLosesNothing(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()
	cfg.Digest.MinMessages = 1

	seedChannel(t, database, "C_EDGE", "edge")
	seedUser(t, database, "U1", "alice", "Alice")

	// One message per second up to three short of the cap, then five sharing a
	// single second — so the cap falls inside that second, with two left over.
	const singles = db.DefaultTimeRangeLimit - 3
	const sharing = 5
	firstTS := time.Now().Add(-6 * time.Hour).Unix()
	texts := make([]string, 0, singles+sharing)
	for i := range singles {
		text := fmt.Sprintf("seq-%03d-end", i)
		texts = append(texts, text)
		seedMessage(t, database, "C_EDGE", fmt.Sprintf("%d.000000", firstTS+int64(i)), "U1", text)
	}
	for i := range sharing {
		text := fmt.Sprintf("shared-%d-end", i)
		texts = append(texts, text)
		seedMessage(t, database, "C_EDGE", fmt.Sprintf("%d.%06d", firstTS+int64(singles), i+1), "U1", text)
	}

	gen := &promptCapturingGenerator{responses: map[string]string{
		"digest.channel":       validDigestJSON(),
		"digest.channel_batch": `[]`,
	}}
	p := New(database, cfg, gen, testLogger())

	for range 3 {
		_, _, err := p.RunChannelDigests(context.Background())
		require.NoError(t, err)
	}

	duplicated := 0
	var missing []string
	for _, text := range texts {
		switch n := gen.promptsContaining(text); {
		case n == 0:
			missing = append(missing, text)
		case n > 1:
			duplicated++
		}
	}
	assert.Empty(t, missing, "every message must reach a prompt — the cap may defer, never drop")
	assert.Equal(t, 1, duplicated, "exactly one second is re-rendered: the boundary the trim backed off to")
}

// TestChannelWindow_StoreFailureLeavesTheChannelUnstamped pins the other half of
// the stamping rule: the AI call returned, but this channel's own digest never
// reached the database, so its window must not advance and the next cycle must
// re-render it.
func TestChannelWindow_StoreFailureLeavesTheChannelUnstamped(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()
	cfg.Digest.MinMessages = 1

	seedChannel(t, database, "C_OK", "stores-fine")
	seedChannel(t, database, "C_BROKEN", "store-fails")
	seedUser(t, database, "U1", "alice", "Alice")

	firstTS := time.Now().Add(-2 * time.Hour).Unix()
	for i := range 4 {
		ts := fmt.Sprintf("%d.%06d", firstTS+int64(i*10), i)
		seedMessage(t, database, "C_OK", ts, "U1", fmt.Sprintf("ok-msg-%d", i))
		seedMessage(t, database, "C_BROKEN", ts, "U1", fmt.Sprintf("broken-msg-%d", i))
	}

	// Fail the store of one channel's digest inside a batch whose AI call
	// succeeds for both channels.
	_, err := database.Exec(`CREATE TRIGGER fail_broken_digest BEFORE INSERT ON digests
		WHEN NEW.channel_id = 'C_BROKEN'
		BEGIN SELECT RAISE(ABORT, 'simulated store failure'); END`)
	require.NoError(t, err)

	topics := `"topics":[{"title":"t","summary":"s","decisions":[],"action_items":[],"situations":[],"key_messages":[]}]`
	gen := &promptCapturingGenerator{responses: map[string]string{
		"digest.channel_batch": fmt.Sprintf(
			`[{"channel_id":"C_OK","summary":"ok",%s},{"channel_id":"C_BROKEN","summary":"broken",%s}]`, topics, topics),
		"digest.channel": validDigestJSON(),
	}}
	p := New(database, cfg, gen, testLogger())

	n, _, err := p.RunChannelDigests(context.Background())
	require.NoError(t, err)
	require.Equal(t, 1, n, "only the channel whose store worked produced a digest")

	// The store recovers; the next cycle must re-render everything it lost.
	_, err = database.Exec(`DROP TRIGGER fail_broken_digest`)
	require.NoError(t, err)

	before := len(gen.prompts)
	_, _, err = p.RunChannelDigests(context.Background())
	require.NoError(t, err)

	second := gen.prompt(t, before)
	assert.Contains(t, second, "broken-msg-0",
		"a store failure must not advance the channel's mark — its messages are re-rendered")
	assert.NotContains(t, second, "ok-msg-0",
		"the channel that stored fine has moved on")

	broken, err := database.GetLatestDigest("C_BROKEN", "channel")
	require.NoError(t, err)
	require.NotNil(t, broken)
	assert.Equal(t, 4, broken.MessageCount, "all four messages survived the failed store")
}
