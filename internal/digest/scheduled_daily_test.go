package digest

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"watchtower/internal/db"

	"github.com/stretchr/testify/require"
)

type dailyDeferredGenerator struct {
	wait    bool
	err     error
	calls   int
	prompts []string
}

func (g *dailyDeferredGenerator) RoutingPreflight(context.Context) error {
	if g.wait {
		return testProviderWait{}
	}
	return nil
}
func (g *dailyDeferredGenerator) Generate(_ context.Context, system, user, _ string) (string, *Usage, string, error) {
	g.calls++
	g.prompts = append(g.prompts, system+user)
	if g.err != nil {
		return "", nil, "", g.err
	}
	return validDigestJSON(), nil, "", nil
}
func TestScheduledDailyDeferredRestartPinsUTCDateAndSkipsCommitted(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()
	t.Setenv("HOME", t.TempDir())
	require.NoError(t, os.MkdirAll(cfg.WorkspaceDir(), 0o700))
	today := utcDayStart(time.Now())
	previous := today.AddDate(0, 0, -1)
	for _, day := range []time.Time{previous, today} {
		for _, id := range []string{"C1", "C2"} {
			seedChannel(t, database, id, id)
			_, err := database.UpsertDigest(db.Digest{ChannelID: id, Type: "channel", PeriodFrom: float64(day.Unix()), PeriodTo: float64(day.Add(24*time.Hour - time.Second).Unix()), Summary: "discussion", Topics: "[]", MessageCount: 5})
			require.NoError(t, err)
		}
	}
	_, err := database.Exec("UPDATE digests SET created_at=? WHERE type='channel'", previous.Format("2006-01-02T15:04:05Z"))
	require.NoError(t, err)
	path := filepath.Join(cfg.WorkspaceDir(), "digest_pending_daily.json")
	data, err := json.Marshal(dailyWindow{DayUnix: previous.Unix()})
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(path, data, 0o600))
	quota := &dailyDeferredGenerator{err: testProviderWait{}}
	p := New(database, cfg, quota, testLogger())
	p.DeferredSchedule = true
	err = p.RunRollups(context.Background())
	require.True(t, ProviderDeferred(err))
	require.Equal(t, 1, quota.calls)
	after, err := os.ReadFile(path)
	require.NoError(t, err)
	require.Equal(t, data, after)
	success := &dailyDeferredGenerator{}
	restarted := New(database, cfg, success, testLogger())
	restarted.DeferredSchedule = true
	require.NoError(t, restarted.RunRollups(context.Background()))
	require.Equal(t, 1, success.calls)
	require.Equal(t, quota.prompts, success.prompts, "retry keeps the same UTC input window")
	daily, err := database.GetDigests(db.DigestFilter{Type: "daily"})
	require.NoError(t, err)
	require.Len(t, daily, 1)
	require.Equal(t, float64(previous.Unix()), daily[0].PeriodFrom)
	// Durable state at a crash after the daily row committed, before descriptor
	// removal: recreate precisely the old descriptor beside the committed row.
	require.NoError(t, os.WriteFile(path, data, 0o600))
	covered := &dailyDeferredGenerator{}
	crashed := New(database, cfg, covered, testLogger())
	crashed.DeferredSchedule = true
	require.NoError(t, crashed.RunRollups(context.Background()))
	require.Zero(t, covered.calls)
	_, err = os.Stat(path)
	require.ErrorIs(t, err, os.ErrNotExist)
	require.NoError(t, crashed.RunRollups(context.Background()))
	require.Equal(t, 1, covered.calls, "the next ordinary schedule can process today's window")
	daily, err = database.GetDigests(db.DigestFilter{Type: "daily"})
	require.NoError(t, err)
	require.Len(t, daily, 2)
}
func TestScheduledDailyKnownQuotaClaimsNoDescriptor(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()
	t.Setenv("HOME", t.TempDir())
	require.NoError(t, os.MkdirAll(cfg.WorkspaceDir(), 0o700))
	gen := &dailyDeferredGenerator{wait: true}
	p := New(database, cfg, gen, testLogger())
	p.DeferredSchedule = true
	require.True(t, ProviderDeferred(p.RunRollups(context.Background())))
	require.Zero(t, gen.calls)
	entries, err := os.ReadDir(cfg.WorkspaceDir())
	require.NoError(t, err)
	require.Empty(t, entries)
}
