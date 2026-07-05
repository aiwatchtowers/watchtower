package tracks

import (
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
)

func TestTruncate(t *testing.T) {
	assert.Equal(t, "hello", truncate("hello", 10))
	assert.Equal(t, "hello", truncate("hello", 5))
	assert.Equal(t, "hel...", truncate("hello", 3))

	// Multi-byte runes are counted as one rune each (not bytes).
	assert.Equal(t, "пр...", truncate("привет", 2))
}

func TestTruncate_Empty(t *testing.T) {
	assert.Equal(t, "", truncate("", 10))
}

func TestDayWindow_24hSpan(t *testing.T) {
	now := time.Date(2026, 4, 2, 12, 0, 0, 0, time.UTC)
	from, to := DayWindow(now)

	assert.Equal(t, float64(now.Unix()), to)
	assert.Equal(t, float64(now.Add(-DefaultWindowHours*time.Hour).Unix()), from)
	assert.Less(t, from, to, "window must be ordered")
}

func TestDayWindow_SizeIsConfigured(t *testing.T) {
	now := time.Now()
	from, to := DayWindow(now)
	assert.InDelta(t, float64(DefaultWindowHours*3600), to-from, 1)
}

func TestSetJiraKeyDetector_Assigns(t *testing.T) {
	p := &Pipeline{}

	detector := &fakeKeyDetector{}
	p.SetJiraKeyDetector(detector)
	assert.NotNil(t, p.jiraKeyDetector)
}

type fakeKeyDetector struct{}

func (f *fakeKeyDetector) ProcessTrack(_ int, _ string, _ string, _ string) (int, error) {
	return 0, nil
}

func TestSanitize_StripsNewlines(t *testing.T) {
	got := sanitize("line1\nline2\rline3")
	// sanitize collapses newlines/carriage returns into spaces.
	assert.NotContains(t, got, "\n")
	assert.NotContains(t, got, "\r")
	assert.True(t, strings.Contains(got, "line1") && strings.Contains(got, "line3"))
}
