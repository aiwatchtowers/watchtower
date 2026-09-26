package jira

import (
	"testing"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func withoutJiraTestDB(t *testing.T) *db.DB {
	t.Helper()
	d, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { d.Close() })
	return d
}

func withoutJiraConfig(enabled bool) *config.Config {
	return &config.Config{
		Jira: config.JiraConfig{
			Enabled: true,
			Features: config.JiraFeatureToggles{
				WithoutJiraDetection: enabled,
			},
		},
	}
}

// seedChannel inserts a channel row.
func seedChannel(t *testing.T, d *db.DB, id, name string) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO channels (id, name, type) VALUES (?, ?, 'public')`, id, name)
	require.NoError(t, err)
}

// seedDigest inserts a channel digest with the given parameters.
// createdAt is an ISO8601 timestamp, periodFrom is a Unix timestamp.
func seedDigest(t *testing.T, d *db.DB, channelID string, periodFrom float64, messageCount int, createdAt string) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO digests (channel_id, type, period_from, period_to, summary, message_count, created_at)
		VALUES (?, 'channel', ?, ?, 'test summary', ?, ?)`,
		channelID, periodFrom, periodFrom+86400, messageCount, createdAt)
	require.NoError(t, err)
}

// seedJiraSlackLink inserts a jira_slack_link row.
func seedJiraSlackLink(t *testing.T, d *db.DB, issueKey, channelID, detectedAt string) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO jira_slack_links (issue_key, channel_id, message_ts, link_type, detected_at)
		VALUES (?, ?, '100.001', 'mention', ?)`,
		issueKey, channelID, detectedAt)
	require.NoError(t, err)
}

func TestWithoutJira_ToggleOff(t *testing.T) {
	d := withoutJiraTestDB(t)
	cfg := withoutJiraConfig(false)

	result, err := DetectWithoutJira(d, cfg, time.Now().AddDate(0, 0, -7))
	assert.NoError(t, err)
	assert.Nil(t, result)
}

func TestWithoutJira_JiraDisabled(t *testing.T) {
	d := withoutJiraTestDB(t)
	cfg := &config.Config{
		Jira: config.JiraConfig{
			Enabled:  false,
			Features: config.JiraFeatureToggles{WithoutJiraDetection: true},
		},
	}

	result, err := DetectWithoutJira(d, cfg, time.Now().AddDate(0, 0, -7))
	assert.NoError(t, err)
	assert.Nil(t, result)
}

func TestWithoutJira_DetectsChannelWithoutLinks(t *testing.T) {
	d := withoutJiraTestDB(t)
	cfg := withoutJiraConfig(true)

	seedChannel(t, d, "C1", "general")

	// 4 digests on different days with enough messages.
	base := time.Date(2026, 4, 1, 0, 0, 0, 0, time.UTC)
	for i := 0; i < 4; i++ {
		day := base.AddDate(0, 0, i)
		seedDigest(t, d, "C1",
			float64(day.Unix()),
			5,
			day.Format(time.RFC3339),
		)
	}

	since := base.AddDate(0, 0, -1) // one day before first digest
	result, err := DetectWithoutJira(d, cfg, since)
	require.NoError(t, err)
	require.Len(t, result, 1)

	assert.Equal(t, "C1", result[0].ChannelID)
	assert.Equal(t, "general", result[0].ChannelName)
	assert.Equal(t, "general", result[0].TopicTitle)
	assert.Equal(t, 4, result[0].DaysDiscussed)
	assert.Equal(t, 20, result[0].MessageCount) // 4 * 5
	assert.Equal(t, "2026-04-01", result[0].FirstSeen)
	assert.Equal(t, "2026-04-04", result[0].LastSeen)
}

func TestWithoutJira_FiltersChannelWithLinks(t *testing.T) {
	d := withoutJiraTestDB(t)
	cfg := withoutJiraConfig(true)

	seedChannel(t, d, "C1", "general")
	seedChannel(t, d, "C2", "engineering")

	base := time.Date(2026, 4, 1, 0, 0, 0, 0, time.UTC)

	// Both channels have enough digests.
	for i := 0; i < 4; i++ {
		day := base.AddDate(0, 0, i)
		seedDigest(t, d, "C1", float64(day.Unix()), 5, day.Format(time.RFC3339))
		seedDigest(t, d, "C2", float64(day.Unix()), 5, day.Format(time.RFC3339))
	}

	// C2 has a jira link in the period.
	seedJiraSlackLink(t, d, "PROJ-100", "C2", base.AddDate(0, 0, 1).Format(time.RFC3339))

	since := base.AddDate(0, 0, -1)
	result, err := DetectWithoutJira(d, cfg, since)
	require.NoError(t, err)
	require.Len(t, result, 1, "C2 should be filtered out because it has a Jira link")
	assert.Equal(t, "C1", result[0].ChannelID)
}

func TestWithoutJira_ThresholdFiltering(t *testing.T) {
	d := withoutJiraTestDB(t)
	cfg := withoutJiraConfig(true)

	seedChannel(t, d, "C1", "low-activity")

	base := time.Date(2026, 4, 1, 0, 0, 0, 0, time.UTC)

	// Only 2 days of digests — below minDaysDiscussed threshold (3).
	for i := 0; i < 2; i++ {
		day := base.AddDate(0, 0, i)
		seedDigest(t, d, "C1", float64(day.Unix()), 10, day.Format(time.RFC3339))
	}

	since := base.AddDate(0, 0, -1)
	result, err := DetectWithoutJira(d, cfg, since)
	assert.NoError(t, err)
	assert.Nil(t, result, "channel with < 3 days should be filtered out")
}

func TestWithoutJira_ThresholdFiltering_LowMessages(t *testing.T) {
	d := withoutJiraTestDB(t)
	cfg := withoutJiraConfig(true)

	seedChannel(t, d, "C1", "quiet-channel")

	base := time.Date(2026, 4, 1, 0, 0, 0, 0, time.UTC)

	// 4 days but only 2 messages each = 8 total — below minMessageCount (10).
	for i := 0; i < 4; i++ {
		day := base.AddDate(0, 0, i)
		seedDigest(t, d, "C1", float64(day.Unix()), 2, day.Format(time.RFC3339))
	}

	since := base.AddDate(0, 0, -1)
	result, err := DetectWithoutJira(d, cfg, since)
	assert.NoError(t, err)
	assert.Nil(t, result, "channel with < 10 total messages should be filtered out")
}

func TestWithoutJira_SortOrder(t *testing.T) {
	d := withoutJiraTestDB(t)
	cfg := withoutJiraConfig(true)

	seedChannel(t, d, "C1", "less-active")
	seedChannel(t, d, "C2", "more-active")

	base := time.Date(2026, 4, 1, 0, 0, 0, 0, time.UTC)

	// C1: 3 days, 15 messages.
	for i := 0; i < 3; i++ {
		day := base.AddDate(0, 0, i)
		seedDigest(t, d, "C1", float64(day.Unix()), 5, day.Format(time.RFC3339))
	}

	// C2: 5 days, 25 messages.
	for i := 0; i < 5; i++ {
		day := base.AddDate(0, 0, i)
		seedDigest(t, d, "C2", float64(day.Unix()), 5, day.Format(time.RFC3339))
	}

	since := base.AddDate(0, 0, -1)
	result, err := DetectWithoutJira(d, cfg, since)
	require.NoError(t, err)
	require.Len(t, result, 2)

	// C2 first (more days).
	assert.Equal(t, "C2", result[0].ChannelID)
	assert.Equal(t, "C1", result[1].ChannelID)
}

func TestWithoutJira_NoDigests(t *testing.T) {
	d := withoutJiraTestDB(t)
	cfg := withoutJiraConfig(true)

	result, err := DetectWithoutJira(d, cfg, time.Now().AddDate(0, 0, -7))
	assert.NoError(t, err)
	assert.Nil(t, result)
}

func TestWithoutJira_ChannelNameFallback(t *testing.T) {
	d := withoutJiraTestDB(t)
	cfg := withoutJiraConfig(true)

	// No channel row inserted — name should fall back to channel ID.
	base := time.Date(2026, 4, 1, 0, 0, 0, 0, time.UTC)
	for i := 0; i < 4; i++ {
		day := base.AddDate(0, 0, i)
		seedDigest(t, d, "C_UNKNOWN", float64(day.Unix()), 5, day.Format(time.RFC3339))
	}

	since := base.AddDate(0, 0, -1)
	result, err := DetectWithoutJira(d, cfg, since)
	require.NoError(t, err)
	require.Len(t, result, 1)
	assert.Equal(t, "C_UNKNOWN", result[0].ChannelName, "should fall back to channel ID")
}

func TestWithoutJira_OldLinksDoNotExclude(t *testing.T) {
	d := withoutJiraTestDB(t)
	cfg := withoutJiraConfig(true)

	seedChannel(t, d, "C1", "general")

	base := time.Date(2026, 4, 1, 0, 0, 0, 0, time.UTC)
	for i := 0; i < 4; i++ {
		day := base.AddDate(0, 0, i)
		seedDigest(t, d, "C1", float64(day.Unix()), 5, day.Format(time.RFC3339))
	}

	// Link detected BEFORE the since period — should NOT exclude the channel.
	seedJiraSlackLink(t, d, "PROJ-1", "C1", base.AddDate(0, 0, -10).Format(time.RFC3339))

	since := base.AddDate(0, 0, -1)
	result, err := DetectWithoutJira(d, cfg, since)
	require.NoError(t, err)
	require.Len(t, result, 1, "old links before period should not exclude channel")
	assert.Equal(t, "C1", result[0].ChannelID)
}
