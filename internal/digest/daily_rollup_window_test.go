package digest

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// A channel digest's window opens on the channel's previous mark, which is
// usually before the day's midnight. The daily rollup must still fold it into
// the day it overlaps instead of excluding it by full containment.
func TestRunDailyRollup_IncludesDigestsStartingBeforeMidnight(t *testing.T) {
	database := testDB(t)
	seedChannel(t, database, "C1", "frontend")
	seedChannel(t, database, "C2", "backend")
	seedChannel(t, database, "C3", "ops")

	now := time.Now().UTC()
	dayStart := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC).AddDate(0, 0, -1)
	u := func(tm time.Time) float64 { return float64(tm.Unix()) }

	for _, d := range []db.Digest{
		// Opened on the previous day's mark, closed during the day.
		{ChannelID: "C1", PeriodFrom: u(dayStart.Add(-30 * time.Hour)), PeriodTo: u(dayStart.Add(3 * time.Hour)), Summary: "frontend-overnight"},
		{ChannelID: "C2", PeriodFrom: u(dayStart.Add(-2 * time.Hour)), PeriodTo: u(dayStart.Add(10 * time.Hour)), Summary: "backend-spanning"},
		// Wholly on the previous day: not this day's material.
		{ChannelID: "C3", PeriodFrom: u(dayStart.Add(-10 * time.Hour)), PeriodTo: u(dayStart.Add(-2 * time.Hour)), Summary: "ops-yesterday"},
	} {
		d.Type, d.MessageCount, d.Model = "channel", 5, "haiku"
		_, err := database.UpsertDigest(d)
		require.NoError(t, err)
	}

	gen := &capturingGenerator{response: `{"summary":"day","topics":[]}`}
	p := New(database, testConfig(), gen, testLogger())
	require.NoError(t, p.runDailyRollupForDate(context.Background(), dayStart))

	require.Equal(t, 1, gen.calls, "two overlapping channel digests are enough for a rollup")
	assert.Contains(t, gen.capturedPrompt, "frontend-overnight")
	assert.Contains(t, gen.capturedPrompt, "backend-spanning")
	assert.NotContains(t, gen.capturedPrompt, "ops-yesterday")

	daily, err := database.GetDigests(db.DigestFilter{Type: "daily"})
	require.NoError(t, err)
	require.Len(t, daily, 1)
	assert.Equal(t, u(dayStart), daily[0].PeriodFrom, "the rollup itself still covers exactly the day")
}
