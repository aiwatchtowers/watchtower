package catchup

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestResolveWindow_AutoFromLastAck(t *testing.T) {
	now := time.Date(2026, 9, 4, 18, 30, 0, 0, time.Local)
	w, err := ResolveWindow(WindowSpec{}, now, float64(now.Add(-30*time.Hour).Unix()))
	require.NoError(t, err)
	assert.Equal(t, now.Add(-30*time.Hour).Unix(), w.From.Unix())
	assert.Equal(t, now, w.To)
	assert.Equal(t, "auto", w.Source)
}

func TestResolveWindow_AutoFallback24h(t *testing.T) {
	now := time.Date(2026, 9, 4, 18, 30, 0, 0, time.Local)
	w, err := ResolveWindow(WindowSpec{}, now, 0)
	require.NoError(t, err)
	assert.Equal(t, now.Add(-24*time.Hour), w.From)
}

// An acknowledged window ending in the future (a custom window built ahead of
// the clock, or a host clock that moved back) must not brick the auto window:
// it falls back to the 24h default rather than erroring on every run.
func TestResolveWindow_AutoIgnoresFutureAck(t *testing.T) {
	now := time.Date(2026, 9, 4, 18, 30, 0, 0, time.Local)
	w, err := ResolveWindow(WindowSpec{}, now, float64(now.Add(6*time.Hour).Unix()))
	require.NoError(t, err)
	assert.Equal(t, now.Add(-24*time.Hour), w.From, "a future ack falls back to the 24h default")
	assert.Equal(t, now, w.To)

	// An ack landing exactly on now is the same case: from must precede to.
	w, err = ResolveWindow(WindowSpec{}, now, float64(now.Unix()))
	require.NoError(t, err)
	assert.Equal(t, now.Add(-24*time.Hour), w.From)
}

// A custom window may not reach past now: `to` is clamped (nothing happened
// there yet), `from` in the future is rejected outright.
func TestResolveWindow_CustomFutureToClampsToNow(t *testing.T) {
	now := time.Date(2026, 9, 4, 18, 30, 0, 0, time.Local)
	from := now.Add(-2 * time.Hour)

	w, err := ResolveWindow(WindowSpec{From: from, To: now.Add(48 * time.Hour)}, now, 0)
	require.NoError(t, err)
	assert.Equal(t, from, w.From)
	assert.Equal(t, now, w.To, "a --to past now is clamped to now")

	_, err = ResolveWindow(WindowSpec{From: now.Add(time.Hour)}, now, 0)
	assert.ErrorIs(t, err, ErrWindow, "a --from in the future is an error")
	_, err = ResolveWindow(WindowSpec{From: now.Add(time.Hour), To: now.Add(2 * time.Hour)}, now, 0)
	assert.ErrorIs(t, err, ErrWindow, "a wholly future window is an error, not an empty recap")
}

func TestResolveWindow_Presets(t *testing.T) {
	now := time.Date(2026, 9, 4, 18, 30, 0, 0, time.Local)
	midnight := time.Date(2026, 9, 4, 0, 0, 0, 0, time.Local)
	cases := map[string][2]time.Time{
		"today":     {midnight, now},
		"yesterday": {midnight.AddDate(0, 0, -1), midnight},
		"3d":        {now.Add(-72 * time.Hour), now},
		"week":      {now.Add(-7 * 24 * time.Hour), now},
	}
	for preset, want := range cases {
		w, err := ResolveWindow(WindowSpec{Preset: preset}, now, 12345)
		require.NoError(t, err, preset)
		assert.Equal(t, want[0], w.From, preset)
		assert.Equal(t, want[1], w.To, preset)
		assert.Equal(t, "preset:"+preset, w.Source)
	}
	_, err := ResolveWindow(WindowSpec{Preset: "fortnight"}, now, 0)
	assert.ErrorIs(t, err, ErrWindow)
}

func TestResolveWindow_CustomAndValidation(t *testing.T) {
	now := time.Date(2026, 9, 4, 18, 30, 0, 0, time.Local)
	from := now.Add(-48 * time.Hour)
	w, err := ResolveWindow(WindowSpec{From: from}, now, 0)
	require.NoError(t, err)
	assert.Equal(t, from, w.From)
	assert.Equal(t, now, w.To, "custom To defaults to now")
	assert.Equal(t, "custom", w.Source)

	_, err = ResolveWindow(WindowSpec{From: now, To: now.Add(-time.Hour)}, now, 0)
	assert.ErrorIs(t, err, ErrWindow, "from must precede to")
	_, err = ResolveWindow(WindowSpec{From: now.AddDate(0, 0, -40)}, now, 0)
	assert.ErrorIs(t, err, ErrWindow, "31-day cap")
	_, err = ResolveWindow(WindowSpec{Preset: "today", From: from}, now, 0)
	assert.ErrorIs(t, err, ErrWindow, "preset and custom are exclusive")
}

func TestParseWindowTime(t *testing.T) {
	d, err := ParseWindowTime("2026-09-03", time.Local)
	require.NoError(t, err)
	assert.Equal(t, time.Date(2026, 9, 3, 0, 0, 0, 0, time.Local), d)
	r, err := ParseWindowTime("2026-09-03T10:15:00Z", time.Local)
	require.NoError(t, err)
	assert.Equal(t, int64(1788430500), r.Unix())
	_, err = ParseWindowTime("yesterday", time.Local)
	assert.Error(t, err)
}
