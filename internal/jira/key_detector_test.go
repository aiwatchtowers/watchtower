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
	return database
}

func TestKeyDetector_DetectKeys(t *testing.T) {
	database := openTestDB(t)

	// Seed known project keys.
	require.NoError(t, database.UpsertJiraIssue(db.JiraIssue{
		Key: "PROJ-1", ProjectKey: "PROJ", Summary: "S", Status: "O", StatusCategory: "todo",
		CreatedAt: "now", UpdatedAt: "now", SyncedAt: "now",
	}))

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

func TestKeyDetector_DetectKeys_NoKnownKeys(t *testing.T) {
	database := openTestDB(t)
	d := NewKeyDetector(database)

	// With no known keys in DB, all matches should be accepted.
	result := d.DetectKeys("ABC-1 and DEF-2")
	assert.Equal(t, []string{"ABC-1", "DEF-2"}, result)
}

func TestKeyDetector_ProcessMessage(t *testing.T) {
	database := openTestDB(t)
	d := NewKeyDetector(database)

	count, err := d.ProcessMessage("C1", "1000.001", "Fixing PROJ-123 now")
	require.NoError(t, err)
	assert.Equal(t, 1, count)

	links, err := database.GetJiraSlackLinksByIssue("PROJ-123")
	require.NoError(t, err)
	assert.Len(t, links, 1)
	assert.Equal(t, "mention", links[0].LinkType)
	assert.Equal(t, "C1", links[0].ChannelID)
}

func TestKeyDetector_ProcessTrack(t *testing.T) {
	database := openTestDB(t)
	d := NewKeyDetector(database)

	count, err := d.ProcessTrack(42, "Follow up on PROJ-10", `[{"ts":"1","text":"re PROJ-20"}]`, `["C1"]`)
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
	d := NewKeyDetector(database)

	count, err := d.ProcessDigestDecision(10, "C1", "Decided to close PROJ-5")
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
	d := NewKeyDetector(database)

	// First call initializes cache.
	_ = d.DetectKeys("ABC-1")

	// Add a project key.
	require.NoError(t, database.UpsertJiraIssue(db.JiraIssue{
		Key: "NEW-1", ProjectKey: "NEW", Summary: "S", Status: "O", StatusCategory: "todo",
		CreatedAt: "now", UpdatedAt: "now", SyncedAt: "now",
	}))

	// Before reset, NEW is not known.
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
	assert.Equal(t, "C1", extractFirstFromJSONArray(`["C1","C2"]`))
	assert.Equal(t, "ABC", extractFirstFromJSONArray(`["ABC"]`))
	assert.Equal(t, "", extractFirstFromJSONArray(`[]`))
	assert.Equal(t, "", extractFirstFromJSONArray(""))
}
