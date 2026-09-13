package jira

import (
	"testing"

	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func openTestDB(t *testing.T) *db.DB {
	t.Helper()
	database, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })
	db.SeedTestJiraAccount(t, database)
	return database
}

// seedProjectKey makes one project key known to the detector.
func seedProjectKey(t *testing.T, database *db.DB, projectKey string) {
	t.Helper()
	require.NoError(t, database.UpsertJiraIssue(db.JiraIssue{
		AccountID: 1,
		Key:       projectKey + "-1", ProjectKey: projectKey, Summary: "S", Status: "O", StatusCategory: "todo",
		CreatedAt: "now", UpdatedAt: "now", SyncedAt: "now",
	}))
}

func TestKeyDetector_DetectKeys(t *testing.T) {
	database := openTestDB(t)

	// Seed known project keys.
	seedProjectKey(t, database, "PROJ")

	d := NewKeyDetector(database)

	tests := []struct {
		name     string
		text     string
		expected []string
	}{
		{"single key", "Check out PROJ-123", []string{"PROJ-123"}},
		{"multiple keys", "PROJ-1 and PROJ-2 are related", []string{"PROJ-1", "PROJ-2"}},
		{"deduplication", "PROJ-1 mentioned again PROJ-1", []string{"PROJ-1"}},
		{"no keys", "no jira keys here", nil},
		{"unknown project", "UNKNOWN-123 should not match", nil},
		{"mixed", "PROJ-10 is good, UNKNOWN-5 is not", []string{"PROJ-10"}},
		{"in URL", "https://jira.example.com/browse/PROJ-99", []string{"PROJ-99"}},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := d.DetectKeys(tt.text)
			assert.Equal(t, tt.expected, result)
		})
	}
}

// TestKeyDetector_DetectKeys_NoKnownKeysDetectsNothing replaces the former
// TestKeyDetector_DetectKeys_NoKnownKeys, which pinned the opposite rule: with
// no project keys known, every match used to be accepted. That fallback turned
// UTF-8, COVID-19, SHA-256 and RFC-9728 into "Jira keys" the moment the
// detector got a caller. Unknown now means no.
func TestKeyDetector_DetectKeys_NoKnownKeysDetectsNothing(t *testing.T) {
	database := openTestDB(t)
	d := NewKeyDetector(database)

	assert.Nil(t, d.DetectKeys("ABC-1 and DEF-2"))
	assert.Nil(t, d.DetectKeys("UTF-8, COVID-19, SHA-256 and RFC-9728 are not Jira keys"))
}

// A project key that lands after the first detection is picked up without a
// process restart: an empty key set is never memoized, so a daemon that started
// before the first Jira sync is not deaf for its whole lifetime.
func TestKeyDetector_DetectKeys_PicksUpProjectKeysSyncedLater(t *testing.T) {
	database := openTestDB(t)
	d := NewKeyDetector(database)

	require.Nil(t, d.DetectKeys("LATE-7"), "nothing is known yet")

	seedProjectKey(t, database, "LATE")

	assert.Equal(t, []string{"LATE-7"}, d.DetectKeys("LATE-7"), "no ResetCache, no restart")
}

func TestKeyDetector_ProcessMessage(t *testing.T) {
	database := openTestDB(t)
	seedProjectKey(t, database, "PROJ")
	d := NewKeyDetector(database)

	count, err := d.ProcessMessage("1:C1", "1000.001", "Fixing PROJ-123 now")
	require.NoError(t, err)
	assert.Equal(t, 1, count)

	links, err := database.GetJiraSlackLinksByIssue("PROJ-123")
	require.NoError(t, err)
	assert.Len(t, links, 1)
	assert.Equal(t, "mention", links[0].LinkType)
	assert.Equal(t, "1:C1", links[0].ChannelID)
}

// ProcessMessageBatch writes exactly the links ProcessMessage would write per
// message — same kind, same namespaced channel id, same raw Slack ts — and does
// it in one transaction rather than one Exec per detected key.
func TestKeyDetector_ProcessMessageBatch_WritesOneMentionPerDetectedKey(t *testing.T) {
	database := openTestDB(t)
	seedProjectKey(t, database, "PROJ")
	d := NewKeyDetector(database)

	count, err := d.ProcessMessageBatch([]db.Message{
		{ChannelID: "1:C1", TS: "1000.001", Text: "Fixing PROJ-123 now"},
		{ChannelID: "1:C1", TS: "1000.002", Text: "no keys here"},
		{ChannelID: "1:C2", TS: "1000.003", Text: "PROJ-123 and PROJ-9 both"},
	})
	require.NoError(t, err)
	assert.Equal(t, 3, count)

	links, err := database.GetJiraSlackLinksByIssue("PROJ-123")
	require.NoError(t, err)
	require.Len(t, links, 2, "one mention per message, not one per issue key")
	for _, l := range links {
		assert.Equal(t, "mention", l.LinkType)
	}

	byMessage, err := database.GetJiraSlackLinksByMessage("1:C2", "1000.003")
	require.NoError(t, err)
	assert.Len(t, byMessage, 2, "both keys in one message are linked to that message")
}

// The batch shares the empty-key-set rule with DetectKeys: with nothing synced
// from Jira it writes nothing at all, so wiring it onto the message-sync path
// cannot fill the table with UTF-8 and COVID-19.
func TestKeyDetector_ProcessMessageBatch_NoKnownKeysWritesNothing(t *testing.T) {
	database := openTestDB(t)
	d := NewKeyDetector(database)

	count, err := d.ProcessMessageBatch([]db.Message{
		{ChannelID: "1:C1", TS: "1000.001", Text: "UTF-8 and COVID-19 and SHA-256"},
	})
	require.NoError(t, err)
	assert.Equal(t, 0, count)

	links, err := database.GetJiraSlackLinksByIssue("UTF-8")
	require.NoError(t, err)
	assert.Empty(t, links)
}

// Re-syncing a page re-processes its messages (the sync has no per-message
// watermark), so the batch must be idempotent for the same (key, channel, ts).
func TestKeyDetector_ProcessMessageBatch_IsIdempotent(t *testing.T) {
	database := openTestDB(t)
	seedProjectKey(t, database, "PROJ")
	d := NewKeyDetector(database)

	page := []db.Message{{ChannelID: "1:C1", TS: "1000.001", Text: "PROJ-7 again"}}
	for range 2 {
		_, err := d.ProcessMessageBatch(page)
		require.NoError(t, err)
	}

	links, err := database.GetJiraSlackLinksByIssue("PROJ-7")
	require.NoError(t, err)
	assert.Len(t, links, 1)
}

func TestKeyDetector_ProcessTrack(t *testing.T) {
	database := openTestDB(t)
	seedProjectKey(t, database, "PROJ")
	d := NewKeyDetector(database)

	count, err := d.ProcessTrack(42, "Follow up on PROJ-10", `[{"ts":"1","text":"re PROJ-20"}]`, `["1:C1"]`)
	require.NoError(t, err)
	assert.Equal(t, 2, count)

	links, err := database.GetJiraSlackLinksByIssue("PROJ-10")
	require.NoError(t, err)
	assert.Len(t, links, 1)
	assert.Equal(t, "track", links[0].LinkType)
	require.NotNil(t, links[0].TrackID)
	assert.Equal(t, 42, *links[0].TrackID)
}

func TestKeyDetector_ProcessDigestDecision(t *testing.T) {
	database := openTestDB(t)
	seedProjectKey(t, database, "PROJ")
	d := NewKeyDetector(database)

	count, err := d.ProcessDigestDecision(10, "1:C1", "Decided to close PROJ-5")
	require.NoError(t, err)
	assert.Equal(t, 1, count)

	links, err := database.GetJiraSlackLinksByIssue("PROJ-5")
	require.NoError(t, err)
	assert.Len(t, links, 1)
	assert.Equal(t, "decision", links[0].LinkType)
	require.NotNil(t, links[0].DigestID)
	assert.Equal(t, 10, *links[0].DigestID)
}

func TestKeyDetector_ResetCache(t *testing.T) {
	database := openTestDB(t)
	seedProjectKey(t, database, "PROJ")
	d := NewKeyDetector(database)

	// First call memoizes a non-empty key set.
	require.Equal(t, []string{"PROJ-1"}, d.DetectKeys("PROJ-1"))

	// Add a project key.
	seedProjectKey(t, database, "NEW")

	// Before reset, NEW is not known — a non-empty set is cached.
	assert.Nil(t, d.DetectKeys("NEW-42"))

	d.ResetCache()

	result := d.DetectKeys("NEW-42")
	assert.Equal(t, []string{"NEW-42"}, result)
}

func TestExtractProjectKey(t *testing.T) {
	assert.Equal(t, "PROJ", extractProjectKey("PROJ-123"))
	assert.Equal(t, "A", extractProjectKey("A-1"))
	assert.Equal(t, "noidea", extractProjectKey("noidea"))
}

func TestExtractFirstFromJSONArray(t *testing.T) {
	assert.Equal(t, "1:C1", extractFirstFromJSONArray(`["1:C1","1:C2"]`))
	assert.Equal(t, "ABC", extractFirstFromJSONArray(`["ABC"]`))
	assert.Equal(t, "", extractFirstFromJSONArray(`[]`))
	assert.Equal(t, "", extractFirstFromJSONArray(""))
}

// A failed key load is deliberately fail-closed and non-propagating: it detects
// nothing (never accept-all) and reports a clean "nothing found" rather than an
// error, so a transient DB failure can never fail the caller that is merely
// looking for Jira keys in a message.
func TestKeyDetector_KeyLoadFailureDetectsNothing(t *testing.T) {
	database := openTestDB(t)
	seedProjectKey(t, database, "PROJ")
	_, err := database.Exec(`DROP TABLE jira_issues`)
	require.NoError(t, err)

	d := NewKeyDetector(database)

	assert.Nil(t, d.DetectKeys("Fixing PROJ-123 now"))

	count, err := d.ProcessMessage("1:C1", "1000.001", "Fixing PROJ-123 now")
	require.NoError(t, err, "a key-load failure must not fail the caller")
	assert.Equal(t, 0, count)

	links, err := database.GetJiraSlackLinksByIssue("PROJ-123")
	require.NoError(t, err)
	assert.Empty(t, links, "nothing is written when the known-key set cannot be loaded")
}
