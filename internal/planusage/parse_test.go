package planusage

import (
	"math"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/claude"
)

// testClaudeSnapshot is a get_usage answer with the 5-hour, weekly and a
// Fable weekly window; pct is the Fable window's percent (clamped by the
// reader, so 100 means hit).
func testClaudeSnapshot(plan string, pct float64) claude.UsageSnapshot {
	session := time.Date(2026, 10, 15, 11, 0, 0, 250_000_000, time.UTC)
	weekly := time.Date(2026, 10, 19, 16, 0, 0, 0, time.UTC)
	return claude.UsageSnapshot{Plan: plan, Windows: []claude.UsageWindow{
		{Key: "session", Label: "5-hour", Group: "session", Percent: 12, ResetsAt: &session},
		{Key: "weekly_all", Label: "Weekly", Group: "weekly", Percent: 40, ResetsAt: &weekly},
		{Key: "weekly_scoped:fable", Label: "Weekly · Fable", Group: "weekly", Percent: pct, ResetsAt: &weekly},
	}}
}

func TestUsageFromSnapshot_ConvertsWindows(t *testing.T) {
	u, err := usageFromSnapshot(testClaudeSnapshot("max", 100))
	require.NoError(t, err)
	require.Len(t, u.Limits, 3)
	assert.Equal(t, "session", u.Limits[0].Key)
	assert.Equal(t, "5-hour", u.Limits[0].Label)
	assert.Equal(t, "session", u.Limits[0].Group)
	assert.Equal(t, 12.0, u.Limits[0].Percent)
	require.NotNil(t, u.Limits[0].ResetsAt)
	assert.Equal(t, 250_000_000, u.Limits[0].ResetsAt.Nanosecond())
	assert.Equal(t, "weekly_all", u.Limits[1].Key)
	assert.Equal(t, "Weekly", u.Limits[1].Label)
	assert.Equal(t, "weekly", u.Limits[1].Group)
	assert.Equal(t, "weekly_scoped:fable", u.Limits[2].Key)
	assert.Equal(t, "Weekly · Fable", u.Limits[2].Label)
	assert.Equal(t, 100.0, u.Limits[2].Percent)
	assert.Nil(t, u.Breakdown)
}

func TestUsageFromSnapshot_ReclampsAndDropsNonFinite(t *testing.T) {
	s := testClaudeSnapshot("max", 140)
	s.Windows[0].Percent = math.NaN()
	s.Windows[1].Percent = -3
	s.Breakdown = []claude.BreakdownRow{
		{Key: "claude_code", Label: "Claude Code", Percent: 180},
		{Key: "chat", Label: "Chats", Percent: math.Inf(1)},
		{Key: "claude_code", Label: "Again", Percent: 5},
		{Key: "", Label: "Empty", Percent: 5},
		{Key: "design", Label: "Design", Percent: -1},
	}
	u, err := usageFromSnapshot(s)
	require.NoError(t, err)
	require.Len(t, u.Limits, 2)
	assert.Equal(t, "weekly_all", u.Limits[0].Key)
	assert.Equal(t, 0.0, u.Limits[0].Percent)
	assert.Equal(t, 100.0, u.Limits[1].Percent)
	assert.Equal(t, []BreakdownRow{{Key: "claude_code", Label: "Claude Code", Percent: 100}, {Key: "design", Label: "Design", Percent: 0}}, u.Breakdown)
}

// Review Focus 3: two windows of one key (or an empty key/slug) must not put
// duplicate ids into limits_json.
func TestUsageFromSnapshot_DuplicateKeysFirstWins(t *testing.T) {
	s := claude.UsageSnapshot{Windows: []claude.UsageWindow{
		{Key: "weekly_scoped:fable", Label: "Weekly · Fable", Group: "weekly", Percent: 30},
		{Key: "weekly_scoped:fable", Label: "Weekly · Fable", Group: "weekly", Percent: 70},
		{Key: "", Label: "Weekly", Group: "weekly", Percent: 50},
		{Key: "weekly_scoped:", Label: "Weekly · ", Group: "weekly", Percent: 50},
	}}
	u, err := usageFromSnapshot(s)
	require.NoError(t, err)
	require.Len(t, u.Limits, 1)
	assert.Equal(t, "weekly_scoped:fable", u.Limits[0].Key)
	assert.Equal(t, 30.0, u.Limits[0].Percent)
}

func TestUsageFromSnapshot_NoWindowIsParse(t *testing.T) {
	_, err := usageFromSnapshot(claude.UsageSnapshot{Plan: "max"})
	require.ErrorIs(t, err, errNoLimits)
	_, err = usageFromSnapshot(claude.UsageSnapshot{Windows: []claude.UsageWindow{{Key: "session", Percent: math.NaN()}}})
	require.ErrorIs(t, err, errNoLimits)
}
