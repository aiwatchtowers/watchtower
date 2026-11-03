package slackbackfill

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func TestUncovered(t *testing.T) {
	day := span{0, 100}
	cases := []struct {
		name     string
		limit    float64
		covering []span
		times    []float64
		want     []span
	}{
		{"no digest: the whole day", 1000, nil, []float64{50}, []span{{0, 100}}},
		{"no message: nothing", 1000, nil, nil, nil},
		{"a message on period_to is covered", 1000, []span{{10, 50}}, []float64{50}, nil},
		{"a message on period_from is not", 1000, []span{{10, 50}}, []float64{10}, []span{{0, 10}}},
		{"partly covered day", 1000, []span{{0, 40}, {60, 70}}, []float64{20, 45, 65, 90},
			[]span{{40, 60}, {70, 100}}},
		{"overlapping digests merge", 1000, []span{{30, 60}, {10, 40}}, []float64{35, 61}, []span{{60, 100}}},
		{"a digest past the day covers its tail", 1000, []span{{80, 500}}, []float64{90, 70}[1:], []span{{0, 80}}},
		{"cut at the forward mark", 55, nil, []float64{50, 60}, []span{{0, 55}}},
		{"a mark below the day: nothing", -1, nil, []float64{50}, nil},
		{"a message on the mark is kept", 50, nil, []float64{50}, []span{{0, 50}}},
	}
	for _, c := range cases {
		assert.Equal(t, c.want, uncovered(day, c.limit, c.covering, c.times), c.name)
	}
}

func TestExcludedDigests(t *testing.T) {
	day := span{100, 200}
	digests := []db.ChannelDigestPeriod{
		{ID: 1, ChannelID: "1:C1", From: 50, To: 150},  // saw 120
		{ID: 2, ChannelID: "1:C1", From: 150, To: 300}, // 120 is before it: excluded
		{ID: 3, ChannelID: "1:C2", From: 0, To: 100},   // ends on the day start: no day message
		{ID: 4, ChannelID: "1:C2", From: 90, To: 110},  // sees 110 (period_to inclusive)
	}
	times := map[string][]float64{"1:C1": {120}, "1:C2": {110}}
	assert.Equal(t, []int64{2, 3}, excludedDigests(day, digests, times))
	assert.Equal(t, []int64{}, excludedDigests(day, nil, times))
}

func TestParseRange(t *testing.T) {
	now := time.Date(2026, 3, 20, 10, 0, 0, 0, time.Local)
	floor, upper, err := ParseRange("2026-03-10", "2026-03-14", now)
	require.NoError(t, err)
	assert.Equal(t, time.Date(2026, 3, 10, 0, 0, 0, 0, time.Local), floor)
	assert.Equal(t, time.Date(2026, 3, 15, 0, 0, 0, 0, time.Local), upper, "--to is included")

	for _, c := range [][2]string{
		{"2026-03-14", "2026-03-10"}, // reversed
		{"2026-03-10", "2026-03-21"}, // future
		{"2026-01-01", "2026-03-01"}, // too long
		{"03/10/2026", "2026-03-14"}, // bad format
	} {
		_, _, err := ParseRange(c[0], c[1], now)
		assert.Error(t, err, c)
	}
	_, _, err = ParseRange("2026-02-17", "2026-03-19", now)
	assert.NoError(t, err, "31 days is allowed")
}

func TestLoadLedger(t *testing.T) {
	dir := t.TempDir()
	l, err := LoadLedger(dir)
	require.NoError(t, err)
	assert.Empty(t, l.Days, "a missing file is an empty ledger")

	require.NoError(t, os.WriteFile(filepath.Join(dir, LedgerFile), []byte(`{"days":null}`), 0o600))
	l, err = LoadLedger(dir)
	require.NoError(t, err)
	require.NotNil(t, l.Days)
	l.Days["1:2026-03-10"] = &ledgerDay{Excluded: []int64{7}, RollupPending: true, DecidedAt: "2026-03-11T00:00:00Z"}
	require.NoError(t, l.save())
	again, err := LoadLedger(dir)
	require.NoError(t, err)
	assert.Equal(t, l.Days, again.Days)
	info, err := os.Stat(filepath.Join(dir, LedgerFile))
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), info.Mode().Perm())

	require.NoError(t, os.WriteFile(filepath.Join(dir, LedgerFile), []byte(`{"days":`), 0o600))
	_, err = LoadLedger(dir)
	require.Error(t, err)
	assert.Contains(t, err.Error(), filepath.Join(dir, LedgerFile), "the error names the file")
	assert.Contains(t, err.Error(), "deleting it lets the next run decide its days again")
}

// Two runs in one workspace would overwrite each other's ledger.
func TestLockLedger_OneRunAtATime(t *testing.T) {
	dir := t.TempDir()
	release, err := LockLedger(dir)
	require.NoError(t, err)
	_, err = LockLedger(dir)
	require.ErrorIs(t, err, ErrRunning)
	release()
	again, err := LockLedger(dir)
	require.NoError(t, err)
	again()

	_, err = LockLedger(filepath.Join(dir, "missing"))
	require.Error(t, err)
	assert.NotErrorIs(t, err, ErrRunning, "a real lock error is returned as itself")
}
