package digest

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

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
// path of the same defect: the per-run batch budget drops batches after the
// cap, and with a global watermark those channels' messages fell below the next
// window start. With per-channel windows a capped channel simply has no digest
// yet, so its full backlog is still inside its next window.
func TestChannelWindow_CappedChannelsAreDeferredNotDropped(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()

	seedUser(t, database, "U1", "alice", "Alice")
	firstTS := time.Now().Add(-2 * time.Hour).Unix()

	// C_DIGESTED was digested up to now; C_DEFERRED never was, and its messages
	// are older than that digest's period_to.
	seedChannel(t, database, "C_DIGESTED", "digested")
	seedChannel(t, database, "C_DEFERRED", "deferred")
	for i := range 5 {
		ts := fmt.Sprintf("%d.%06d", firstTS+int64(i*10), i)
		seedMessage(t, database, "C_DEFERRED", ts, "U1", fmt.Sprintf("deferred msg %d", i))
	}
	_, err := database.UpsertDigest(db.Digest{
		ChannelID: "C_DIGESTED", Type: "channel",
		PeriodFrom: float64(firstTS), PeriodTo: float64(time.Now().Unix()),
		Summary: "covered", MessageCount: 5, Model: "haiku",
	})
	require.NoError(t, err)

	p := New(database, cfg, &mockGenerator{response: validDigestJSON()}, testLogger())

	assert.Less(t, windowFor(t, p, "C_DEFERRED"), float64(firstTS),
		"a channel that was never digested keeps its whole backlog inside its next window")
}
