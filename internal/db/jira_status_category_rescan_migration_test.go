package db

import (
	"testing"
	"time"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestMigration00090_ResetsWatermarksForMissingStatusCategoryDate: a project
// still holding a live issue without status_category_changed_at gets its
// watermark blanked so the next sync re-fetches it in full; a project whose
// issues all carry the value, and one only missing it on deleted issues,
// keep theirs.
func TestMigration00090_ResetsWatermarksForMissingStatusCategoryDate(t *testing.T) {
	raw := rawDBAt(t, 89)
	_, err := raw.Exec(`INSERT INTO jira_accounts (id, cloud_id) VALUES (1, 'c1')`)
	require.NoError(t, err)

	watermark := time.Now().Add(-time.Hour).UTC().Format(time.RFC3339)
	changed := time.Now().AddDate(0, 0, -3).UTC().Format(time.RFC3339)
	for _, p := range []string{"MISS", "FULL", "GONE"} {
		_, err := raw.Exec(`INSERT INTO jira_sync_state (account_id, project_key, last_synced_at, issues_synced, last_error)
			VALUES (1, ?, ?, 42, 'boom')`, p, watermark)
		require.NoError(t, err)
	}
	issue := func(key, project, changedAt string, deleted int) {
		t.Helper()
		_, err := raw.Exec(`INSERT INTO jira_issues (account_id, key, id, project_key, summary, status, status_category,
			status_category_changed_at, created_at, updated_at, synced_at, is_deleted)
			VALUES (1, ?, ?, ?, 's', 'Open', 'todo', ?, ?, ?, ?, ?)`,
			key, key, project, changedAt, changed, changed, changed, deleted)
		require.NoError(t, err)
	}
	issue("MISS-1", "MISS", changed, 0)
	issue("MISS-2", "MISS", "", 0)
	issue("FULL-1", "FULL", changed, 0)
	issue("GONE-1", "GONE", changed, 0)
	issue("GONE-2", "GONE", "", 1)

	require.NoError(t, goose.Up(raw, "migrations"))

	state := func(project string) (lastSynced string, issuesSynced int, lastError string) {
		t.Helper()
		require.NoError(t, raw.QueryRow(`SELECT last_synced_at, issues_synced, last_error FROM jira_sync_state
			WHERE account_id = 1 AND project_key = ?`, project).Scan(&lastSynced, &issuesSynced, &lastError))
		return
	}
	got, n, lastErr := state("MISS")
	assert.Empty(t, got, "a project with a live issue missing the date is re-scanned in full")
	assert.Zero(t, n, "issues_synced restarts so the full scan does not double it")
	assert.Equal(t, "boom", lastErr, "last_error is left alone")
	got, n, _ = state("FULL")
	assert.Equal(t, watermark, got)
	assert.Equal(t, 42, n, "an untouched project keeps its count")
	got, _, _ = state("GONE")
	assert.Equal(t, watermark, got, "a deleted issue never comes back from the search, so it does not force a scan")
}
