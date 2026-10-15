package planusage

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func load(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", name))
	require.NoError(t, err)
	return b
}

func TestParse_LimitsArray(t *testing.T) {
	u, err := Parse(load(t, "usage_full.json"))
	require.NoError(t, err)
	require.Len(t, u.Limits, 3)
	assert.Equal(t, "session", u.Limits[0].Key)
	assert.Equal(t, "5-hour", u.Limits[0].Label)
	assert.Equal(t, "weekly_all", u.Limits[1].Key)
	assert.Equal(t, "Weekly", u.Limits[1].Label)
	assert.Equal(t, "weekly_scoped:fable", u.Limits[2].Key)
	assert.Equal(t, "Weekly · Fable", u.Limits[2].Label)
	assert.Equal(t, 100.0, u.Limits[2].Percent, "clamped")
	require.NotNil(t, u.Limits[0].ResetsAt)
	assert.Equal(t, 11, u.Limits[0].ResetsAt.UTC().Hour())
	assert.Equal(t, 250_000_000, u.Limits[0].ResetsAt.Nanosecond(), "fractional seconds parse")
	require.Len(t, u.Breakdown, 2)
	assert.Equal(t, BreakdownRow{Key: "claude_code", Label: "Claude Code", Percent: 80}, u.Breakdown[0])
}

func TestParse_LegacyFallback(t *testing.T) {
	u, err := Parse(load(t, "usage_legacy.json"))
	require.NoError(t, err)
	keys := []string{}
	for _, l := range u.Limits {
		keys = append(keys, l.Key)
	}
	assert.Equal(t, []string{"session", "weekly_all", "weekly_scoped:opus"}, keys)
	assert.Equal(t, 12.5, u.Limits[0].Percent)
	assert.Nil(t, u.Limits[0].ResetsAt)
	assert.Equal(t, "Weekly · Opus", u.Limits[2].Label)
}

func TestParse_IdleWindowHasNilReset(t *testing.T) {
	u, err := Parse(load(t, "usage_idle.json"))
	require.NoError(t, err)
	assert.Nil(t, u.Limits[0].ResetsAt)
	assert.Equal(t, 0.0, u.Limits[0].Percent)
}

func TestParse_Errors(t *testing.T) {
	for name, body := range map[string]string{
		"garbage": "not json",
		"empty":   "{}",
		"nulls":   `{"five_hour": null, "seven_day": null, "limits": null}`,
	} {
		t.Run(name, func(t *testing.T) {
			_, err := Parse([]byte(body))
			assert.Error(t, err)
		})
	}
	_, err := Parse([]byte("{}"))
	assert.ErrorIs(t, err, ErrNoLimits)
}
