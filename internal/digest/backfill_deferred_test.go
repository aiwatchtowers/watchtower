package digest

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"
	"watchtower/internal/db"

	"github.com/stretchr/testify/require"
)

type historyDecliningGenerator struct {
	mu      sync.Mutex
	prompts []string
	quota   bool
	waiting bool
}

func (g *historyDecliningGenerator) RoutingPreflight(context.Context) error {
	if g.waiting {
		return testProviderWait{}
	}
	return nil
}
func (g *historyDecliningGenerator) Generate(_ context.Context, system, user, _ string) (string, *Usage, string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.prompts = append(g.prompts, system+user)
	if g.quota {
		return "", nil, "", testProviderWait{}
	}
	if strings.Contains(system+user, "missing-0") {
		return validDigestJSON(), &Usage{}, "", nil
	}
	return `[]`, &Usage{}, "", nil
}

func TestBackfillDeferredDeclinedPrefixSurvivesRestart(t *testing.T) {
	d := testDB(t)
	seedUser(t, d, "U1", "alice", "Alice")
	from, to := backfillRange()
	for _, id := range []string{"1:C1", "1:C2"} {
		seedChannel(t, d, id, id)
		seedRangeMessages(t, d, id, "declined", from+3600, 4)
	}
	g := &historyDecliningGenerator{}
	p := backfillPipeline(t, d, g)
	g.waiting = true
	_, _, err := p.RunBackfillWindow(context.Background(), 1, from, to)
	require.True(t, ProviderDeferred(err))
	require.Empty(t, g.prompts)
	g.waiting = false
	result, _, err := p.RunBackfillWindow(context.Background(), 1, from, to)
	require.NoError(t, err)
	require.True(t, result.Complete)
	require.Len(t, g.prompts, 1)
	seedChannel(t, d, "1:C3", "flaky")
	seedRangeMessages(t, d, "1:C3", "missing", from+7200, 4)
	g.quota = true
	p = backfillPipeline(t, d, g)
	_, _, err = p.RunBackfillWindow(context.Background(), 1, from, to)
	require.True(t, ProviderDeferred(err), "%v", err)
	require.Len(t, g.prompts, 2)
	require.False(t, strings.Contains(g.prompts[1], "declined-0"), "committed declined prefix was replayed")
	g.quota = false
	p = backfillPipeline(t, d, g)
	result, _, err = p.RunBackfillWindow(context.Background(), 1, from, to)
	require.NoError(t, err)
	require.True(t, result.Complete)
	require.Len(t, g.prompts, 3)
	p = backfillPipeline(t, d, g)
	result, _, err = p.RunBackfillWindow(context.Background(), 1, from, to)
	require.NoError(t, err)
	require.True(t, result.Complete)
	require.Len(t, g.prompts, 3)
	var marks int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM channels WHERE digest_considered_ts IS NOT NULL`).Scan(&marks))
	require.Zero(t, marks)
}

type historyDailyGenerator struct {
	calls       int
	quotaSecond bool
}

func (g *historyDailyGenerator) RoutingPreflight(context.Context) error { return nil }
func (g *historyDailyGenerator) Generate(context.Context, string, string, string) (string, *Usage, string, error) {
	g.calls++
	if g.quotaSecond && g.calls == 2 {
		return "", nil, "", testProviderWait{}
	}
	return validDigestJSON(), &Usage{}, "", nil
}
func TestBackfillDailyDeferredDoesNotReplaySavedDayOnNewData(t *testing.T) {
	d := testDB(t)
	from, to := backfillRange()
	for _, day := range []float64{from, from + 86400} {
		for _, channel := range []string{"1:C1", "1:C2"} {
			_, err := d.UpsertDigest(db.Digest{ChannelID: channel, Type: "channel", PeriodFrom: day + 100, PeriodTo: day + 200, Summary: "saved", MessageCount: 3})
			require.NoError(t, err)
		}
	}
	g := &historyDailyGenerator{quotaSecond: true}
	p := backfillPipeline(t, d, g)
	require.True(t, ProviderDeferred(p.RunBackfillRollups(context.Background(), from, to)))
	require.Equal(t, 2, g.calls)
	// A forward/new channel output arrives after the first historical day committed.
	_, err := d.Exec(`UPDATE digests SET created_at='2099-01-01T00:00:00Z' WHERE type='channel' AND period_from=?`, from+100)
	require.NoError(t, err)
	g.quotaSecond = false
	p = backfillPipeline(t, d, g)
	require.NoError(t, p.RunBackfillRollups(context.Background(), from, to))
	require.Equal(t, 3, g.calls, "only the missing day should make a model call")
	require.NoError(t, p.RunBackfillRollups(context.Background(), from, to))
	require.Equal(t, 3, g.calls, "same claim is complete despite new input")
	require.NoError(t, p.RunBackfillRollupsForAccount(context.Background(), 2, from, to))
	require.Equal(t, 4, g.calls, "another source account owns a distinct claim")
	_, err = d.StartHistoryBackfill("slack", 0, from, to, time.Now())
	require.NoError(t, err)
	_, err = d.Exec(`DELETE FROM history_backfill WHERE source_kind='slack' AND account_id=0`)
	require.NoError(t, err)
	require.NoError(t, p.RunBackfillRollups(context.Background(), from, to))
	require.Equal(t, 5, g.calls, "explicit reset permits recomputation for identical bounds")
}
