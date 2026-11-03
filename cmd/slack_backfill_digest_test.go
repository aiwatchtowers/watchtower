package cmd

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log"
	"os"
	gosync "sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/sync"
)

// backfillGen answers every digest and rollup call with one small topic and
// records the prompts it was sent.
type backfillGen struct {
	mu      gosync.Mutex
	prompts []string
}

func (g *backfillGen) Generate(_ context.Context, _, user, _ string) (string, *digest.Usage, string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.prompts = append(g.prompts, user)
	return `{"summary":"s","topics":[{"title":"t","summary":"s","decisions":[],"action_items":[],"situations":[],"key_messages":[]}]}`,
		&digest.Usage{Model: "m", InputTokens: 1, OutputTokens: 1}, "", nil
}

func newBackfillDigestFixture(t *testing.T) (*db.DB, *digest.Pipeline, *backfillGen) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	cfg := &config.Config{ActiveWorkspace: "test", Digest: config.DigestConfig{Enabled: true, MinMessages: 1}}
	require.NoError(t, os.MkdirAll(cfg.WorkspaceDir(), 0o700))
	database := db.OpenTestDB(t)
	gen := &backfillGen{}
	return database, digest.New(database, cfg, gen, log.New(io.Discard, "", 0)), gen
}

func seedBackfillMessage(t *testing.T, database *db.DB, channel string, at time.Time, text string) {
	t.Helper()
	require.NoError(t, database.UpsertChannel(db.Channel{ID: channel, Name: channel, Type: "public"}))
	require.NoError(t, database.UpsertMessage(db.Message{
		ChannelID: channel, TS: fmt.Sprintf("%d.000100", at.Unix()), UserID: "1:U1", Text: text,
	}))
}

func countDigests(t *testing.T, database *db.DB, where string, args ...any) int {
	t.Helper()
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM digests WHERE `+where, args...).Scan(&n))
	return n
}

// slack backfill never digests anything again (#915 owner decision): a
// channel day a digest already covered keeps its digest and gets only its
// messages; a channel day no digest saw is digested — including a day inside
// the period of a forward digest that spans a sync gap without having seen a
// message of it; a daily rollup is rebuilt only for a day that got a new
// digest.
func TestBackfillSlackDigests_OnlyWhatNoDigestCovered(t *testing.T) {
	database, pipe, gen := newBackfillDigestFixture(t)
	day1 := time.Now().UTC().AddDate(0, 0, -20).Truncate(24 * time.Hour)
	day2 := day1.Add(24 * time.Hour)
	day3 := day2.Add(24 * time.Hour)
	from, to := day1, day3.Add(24*time.Hour)
	dailyOn := func(day time.Time) int {
		return countDigests(t, database, `type = 'daily' AND period_from >= ? AND period_from < ?`,
			float64(day.Unix()), float64(day.Add(24*time.Hour).Unix()))
	}

	// C1: digested on day 1 before the backfill.
	seedBackfillMessage(t, database, "1:C1", day1.Add(time.Hour), "c1-old")
	_, err := database.UpsertDigest(db.Digest{ChannelID: "1:C1", Type: "channel",
		PeriodFrom: float64(day1.Unix()), PeriodTo: float64(day1.Add(2 * time.Hour).Unix()), Summary: "old", Model: "m"})
	require.NoError(t, err)
	// C2: a forward digest whose period spans every day, with no message of
	// them stored when it ran (the first digest after a sync gap).
	_, err = database.UpsertDigest(db.Digest{ChannelID: "1:C2", Type: "channel",
		PeriodFrom: float64(day1.Add(-24 * time.Hour).Unix()), PeriodTo: float64(to.Add(24 * time.Hour).Unix()), Summary: "fwd", Model: "m"})
	require.NoError(t, err)
	// C3: a message on day 3 that no digest covers.
	seedBackfillMessage(t, database, "1:C3", day3.Add(3*time.Hour), "c3-old")

	covered, err := digestedChannelDays(database, 1, from, to)
	require.NoError(t, err)
	// The fetch brings day 1 news for C1 and day 2 news for C2.
	seedBackfillMessage(t, database, "1:C1", day1.Add(5*time.Hour), "c1-new")
	seedBackfillMessage(t, database, "1:C2", day2.Add(4*time.Hour), "c2-new")

	digests, rolled, err := backfillSlackDigests(context.Background(), database, pipe, 1, from, to, covered)
	require.NoError(t, err)
	assert.Equal(t, 2, digests, "C2 on day 2, C3 on day 3")
	assert.Equal(t, 2, rolled, "days 2 and 3 got a new digest")

	assert.Equal(t, 1, countDigests(t, database, `channel_id = '1:C1'`), "C1's day 1 is not digested again")
	assert.Equal(t, 2, countDigests(t, database, `channel_id = '1:C2'`))
	assert.Equal(t, 1, countDigests(t, database, `channel_id = '1:C3'`))
	assert.Zero(t, dailyOn(day1), "no rollup for a day without a new digest")
	assert.Equal(t, 1, dailyOn(day2))
	assert.Equal(t, 1, dailyOn(day3))
	for _, p := range gen.prompts {
		assert.NotContains(t, p, "c1-new", "a covered channel day never reaches a prompt")
	}

	// Run again: everything is covered now; nothing is digested or rolled up.
	covered, err = digestedChannelDays(database, 1, from, to)
	require.NoError(t, err)
	calls := len(gen.prompts)
	digests, rolled, err = backfillSlackDigests(context.Background(), database, pipe, 1, from, to, covered)
	require.NoError(t, err)
	assert.Zero(t, digests)
	assert.Zero(t, rolled)
	assert.Len(t, gen.prompts, calls, "no AI call on a second run")
}

func TestBackfillDays_SplitsOnUTCDaysClippedToTheChunk(t *testing.T) {
	from := time.Date(2026, 3, 10, 22, 0, 0, 0, time.UTC)
	to := from.Add(48 * time.Hour)
	days := backfillDays(from, to)
	require.Len(t, days, 3)
	assert.Equal(t, from, days[0][0])
	assert.Equal(t, time.Date(2026, 3, 11, 0, 0, 0, 0, time.UTC), days[0][1])
	assert.Equal(t, to, days[2][1])
}

// The whole command path with digests on: fetch, then the chunk's digest and
// its day's rollup; a second run fetches again but digests nothing.
func TestBackfillSlackRange_WithDigests(t *testing.T) {
	database, _ := slackBackfillEnv(t, "T_HOME")
	cfg, err := workspaceConfigFromFlags()
	require.NoError(t, err)
	cfg.Digest = config.DigestConfig{Enabled: true, MinMessages: 1}
	gen := &backfillGen{}
	pipe := digest.New(database, cfg, gen, log.New(io.Discard, "", 0))
	orch := sync.NewOrchestrator(database, newSlackClientForToken("xoxp-test"), cfg, 1)
	orch.SetLogger(log.New(io.Discard, "", 0))
	// The stub's one message is at 2026-03-13 12:00 UTC.
	floor := time.Date(2026, 3, 13, 0, 0, 0, 0, time.UTC)
	upper := floor.Add(24 * time.Hour)

	var out bytes.Buffer
	require.NoError(t, backfillSlackRange(context.Background(), &out, database, orch, pipe, floor, upper))
	assert.Contains(t, out.String(), "1 messages, 1 digests, daily rollups run for 1 days")
	assert.Equal(t, 1, countDigests(t, database, `type = 'channel' AND channel_id = '1:C001'`))

	out.Reset()
	calls := len(gen.prompts)
	require.NoError(t, backfillSlackRange(context.Background(), &out, database, orch, pipe, floor, upper))
	assert.Contains(t, out.String(), "1 messages, 0 digests, daily rollups run for 0 days")
	assert.Len(t, gen.prompts, calls, "the second run digests nothing")
}
