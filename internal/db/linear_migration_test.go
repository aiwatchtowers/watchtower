package db

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestMigration00116_LinearTablesDownUp(t *testing.T) {
	d := openTestDB(t)
	for _, tbl := range []string{"linear_accounts", "linear_teams", "linear_sync_state", "linear_issues",
		"linear_comments", "linear_issue_history", "linear_cycles", "linear_projects",
		"linear_relations", "linear_user_map"} {
		var n int
		require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?`, tbl).Scan(&n))
		require.Equal(t, 1, n, tbl)
	}
	// Composite keys: the same Linear id on two workspaces is two rows.
	_, err := d.Exec(`INSERT INTO linear_accounts (org_id) VALUES ('org-a'), ('org-b')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO linear_issues (account_id, id, key, team_id, title) VALUES (1,'i-1','ENG-1','t-1','a'), (2,'i-1','ENG-1','t-1','b')`)
	require.NoError(t, err)
	// org_id is unique: one row per workspace.
	_, err = d.Exec(`INSERT INTO linear_accounts (org_id) VALUES ('org-a')`)
	require.Error(t, err)
}
