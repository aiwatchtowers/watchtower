package db

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func trackerPeopleQueryPlan(t *testing.T, d *DB, query string, args ...any) string {
	t.Helper()
	rows, err := d.Query(`EXPLAIN QUERY PLAN `+query, args...)
	require.NoError(t, err)
	defer rows.Close()
	var plan []string
	for rows.Next() {
		var id, parent, notused int
		var detail string
		require.NoError(t, rows.Scan(&id, &parent, &notused, &detail))
		plan = append(plan, detail)
	}
	require.NoError(t, rows.Err())
	return strings.Join(plan, "\n")
}

// The people-card delivery queries filter tracker_issues by one person: the
// filter must reach both branches' assignee indexes (spec §4.2 plan pins).
func TestTrackerDeliveryQueriesUseAssigneeIndexes(t *testing.T) {
	d := openTestDB(t)
	for _, q := range []string{
		`SELECT COUNT(*) FROM tracker_issues WHERE assignee_slack_id = ? AND status_category = 'done' AND resolved_at >= ? AND resolved_at <= ? AND is_deleted = 0`,
		`SELECT tracker, key, title, resolved_at FROM tracker_issues WHERE assignee_slack_id = ? AND status_category = 'done' AND is_deleted = 0 AND resolved_at >= ? AND resolved_at <= ?`,
	} {
		plan := trackerPeopleQueryPlan(t, d, q, "1:U1", "a", "b")
		assert.Contains(t, plan, "SEARCH ji USING INDEX idx_jira_issues_assignee", plan)
		assert.Contains(t, plan, "SEARCH li USING INDEX idx_linear_issues_assignee_status", plan)
	}
}
