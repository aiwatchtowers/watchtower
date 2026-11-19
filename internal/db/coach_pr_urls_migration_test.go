package db

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestMigration00198_CoachPRURLs: coach_proposals gains pr_url and
// revert_pr_url, both defaulting to ”; Down drops them.
func TestMigration00198_CoachPRURLs(t *testing.T) {
	d := openTestDB(t)
	id, err := d.InsertCoachProposal(coachFixture("m1"), time.Date(2026, 11, 19, 9, 0, 0, 0, time.UTC))
	require.NoError(t, err)
	var pr, revert string
	require.NoError(t, d.QueryRow(`SELECT pr_url, revert_pr_url FROM coach_proposals WHERE id = ?`, id).Scan(&pr, &revert))
	assert.Empty(t, pr)
	assert.Empty(t, revert)

	require.NoError(t, gooseDownTo(d.DB, "migrations", 197))
	assert.Zero(t, countWhere(t, d, `SELECT COUNT(*) FROM pragma_table_info('coach_proposals') WHERE name IN ('pr_url','revert_pr_url')`))
}
