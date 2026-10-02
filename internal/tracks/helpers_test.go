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

func TestExtractFingerprint_GenericTicketKeys(t *testing.T) {
	fp := extractFingerprint("Ship ACME-123 and OPS_2-7", "see also ACME-123 and QA1-42")
	assert.Equal(t, []string{"ACME-123", "OPS_2-7", "QA1-42"}, fp, "any Jira-shaped key counts, deduplicated")
}

func TestExtractFingerprint_StandardNamesAreNotTickets(t *testing.T) {
	fp := extractFingerprint("Encode as UTF-8, hash with SHA-256, dates in ISO-8601 per RFC-3339", "")
	assert.Empty(t, fp)

	fp = extractFingerprint("Patch CVE-2024-12345 before ACME-9", "")
	assert.Equal(t, []string{"ACME-9", "CVE-2024-12345"}, fp, "a CVE id is taken whole, its head is not a ticket")
}

func TestExtractFingerprint_LowercaseIsNotATicket(t *testing.T) {
	assert.Empty(t, extractFingerprint("acme-123 is prose, not a key", ""))
}
