package db

import (
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func seedLinearWindowIssue(t *testing.T, d *DB, acct int64, id, updatedAt string, deleted bool) {
	t.Helper()
	require.NoError(t, d.UpsertLinearIssue(LinearIssue{
		AccountID: acct, ID: id, Key: "ENG-" + id, TeamKey: "ENG", UpdatedAt: updatedAt, IsDeleted: deleted,
	}))
}

// IDEA-01 (Linear stream): a LIMIT cut inside a group of issues sharing one
// updated_at is extended to the whole group, so the strict-> reload never
// buries a tie-mate.
func TestIdeas01_LinearWindowBoundaryDrainKeepsSameTimestampIssues(t *testing.T) {
	d := openTestDB(t)
	acct := SeedLinearTestAccount(t, d)
	seedLinearWindowIssue(t, d, acct, "a", "2026-10-01T10:00:00.000Z", false)
	for i := range 4 {
		seedLinearWindowIssue(t, d, acct, fmt.Sprintf("t%d", i), "2026-10-01T11:00:00.000Z", false)
	}
	seedLinearWindowIssue(t, d, acct, "z", "2026-10-01T12:00:00.000Z", false)
	seedLinearWindowIssue(t, d, acct, "gone", "2026-10-01T10:30:00.000Z", true)

	got, err := d.ListLinearIssuesUpdatedSince(acct, "2026-10-01T09:00:00.000Z", "", 2)
	require.NoError(t, err)
	require.Len(t, got, 5, "limit 2 cut inside the 11:00 group, which is drained whole")
	assert.Equal(t, "a", got[0].ID)
	for _, is := range got[1:] {
		assert.Equal(t, "2026-10-01T11:00:00.000Z", is.UpdatedAt)
	}

	bounded, err := d.ListLinearIssuesUpdatedSince(acct, "2026-10-01T09:00:00.000Z", "2026-10-01T10:00:00.000Z", 0)
	require.NoError(t, err)
	require.Len(t, bounded, 1, "beforeISO bounds the window; deleted issues never count")
}

// The memory extract window drains its boundary second the same way and skips
// deleted issues.
func TestListLinearIssuesForExtract_DrainsBoundarySecond(t *testing.T) {
	d := openTestDB(t)
	acct := SeedLinearTestAccount(t, d)
	seedLinearWindowIssue(t, d, acct, "a", "2026-10-01T10:00:00.000Z", false)
	seedLinearWindowIssue(t, d, acct, "b", "2026-10-01T11:00:00.000Z", false)
	seedLinearWindowIssue(t, d, acct, "c", "2026-10-01T11:00:00.000Z", false)
	seedLinearWindowIssue(t, d, acct, "x", "2026-10-01T12:00:00.000Z", true)

	got, err := d.ListLinearIssuesForExtract(acct, 0, 2)
	require.NoError(t, err)
	require.Len(t, got, 3)
	assert.Equal(t, []string{"a", "b", "c"}, []string{got[0].ID, got[1].ID, got[2].ID})

	maxU, err := d.MaxLinearUpdatedUnix(acct)
	require.NoError(t, err)
	u, _ := ParseJiraTime("2026-10-01T11:00:00.000Z")
	assert.Equal(t, u, maxU, "a deleted issue does not raise the init bound")
}

// LinearIssueExists resolves the current key and a previous key, and never a
// deleted issue.
func TestLinearIssueExists_CurrentAndPreviousKeysNotDeleted(t *testing.T) {
	d := openTestDB(t)
	acct := SeedLinearTestAccount(t, d)
	require.NoError(t, d.UpsertLinearIssue(LinearIssue{AccountID: acct, ID: "u1", Key: "OPS-3", PreviousKeys: []string{"ENG-7"}}))
	require.NoError(t, d.UpsertLinearIssue(LinearIssue{AccountID: acct, ID: "u2", Key: "ENG-9", IsDeleted: true}))

	for key, want := range map[string]bool{"OPS-3": true, "ENG-7": true, "ENG-9": false, "ENG-404": false} {
		got, err := d.LinearIssueExists(key)
		require.NoError(t, err)
		assert.Equal(t, want, got, key)
	}
}

// A failing selected team is reported by its last successful sync; an
// unselected or never-synced one is not.
func TestOldestFailingLinearTeamSync(t *testing.T) {
	d := openTestDB(t)
	acct := SeedLinearTestAccount(t, d)
	require.NoError(t, d.UpsertLinearTeams(acct, []LinearTeam{{ID: "a", Key: "A"}, {ID: "b", Key: "B"}, {ID: "c", Key: "C"}},
		map[string]bool{"a": true, "c": true}))
	got, err := d.OldestFailingLinearTeamSync(acct)
	require.NoError(t, err)
	assert.Empty(t, got)

	require.NoError(t, d.RecordLinearSyncSuccess(acct, "a", "", "2026-10-01T10:00:00.000Z"))
	require.NoError(t, d.RecordLinearSyncError(acct, "a", "boom"))
	require.NoError(t, d.RecordLinearSyncSuccess(acct, "b", "", "2026-10-01T08:00:00.000Z"))
	require.NoError(t, d.RecordLinearSyncError(acct, "b", "boom")) // not selected
	require.NoError(t, d.RecordLinearSyncError(acct, "c", "boom")) // never synced

	got, err = d.OldestFailingLinearTeamSync(acct)
	require.NoError(t, err)
	assert.Equal(t, "2026-10-01T10:00:00.000Z", got)
}
