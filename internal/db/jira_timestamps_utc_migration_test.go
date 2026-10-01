package db

import (
	"testing"
	"time"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// jiraWire renders t the way Jira Cloud returns a timestamp, in zone.
func jiraWire(t time.Time, zone *time.Location) string {
	return t.In(zone).Format("2006-01-02T15:04:05.000-0700")
}

// TestMigration00091_RewritesJiraTimestampsToUTC: every Jira timestamp column
// and every copy of one (ideas floor, jira inbox items, Jira stream digests)
// is rewritten to RFC3339 UTC; values already canonical, values without a
// zone, unparseable values and non-Jira rows are left alone.
func TestMigration00091_RewritesJiraTimestampsToUTC(t *testing.T) {
	raw := rawDBAt(t, 90)
	now := time.Now().UTC().Truncate(time.Second)
	msk := time.FixedZone("", 3*3600)
	cet := time.FixedZone("", 2*3600)
	ny := time.FixedZone("", -4*3600)
	utc := func(tm time.Time) string { return tm.UTC().Format(time.RFC3339) }

	created, resolved := now.Add(-50*time.Hour), now.Add(-2*time.Hour)
	// The DST fall-back case from the backlog: the floor is a +0300 string, a
	// later change is stored in +0200 and sorts below it as raw strings.
	floor, later := now.Add(-3*time.Hour), now.Add(-3*time.Hour+20*time.Minute)
	require.Less(t, jiraWire(later, cet), jiraWire(floor, msk), "the raw strings misorder the instants")

	_, err := raw.Exec(`INSERT INTO jira_accounts (id, cloud_id, ideas_jira_floor) VALUES (1, 'c1', ?)`, jiraWire(floor, msk))
	require.NoError(t, err)
	issue := func(key, createdAt, updatedAt, resolvedAt, catChanged string) {
		t.Helper()
		_, err := raw.Exec(`INSERT INTO jira_issues (account_id, key, id, project_key, summary, status, status_category,
			status_category_changed_at, created_at, updated_at, resolved_at, synced_at)
			VALUES (1, ?, ?, 'WT', 's', 'Done', 'done', ?, ?, ?, ?, ?)`,
			key, key, catChanged, createdAt, updatedAt, resolvedAt, utc(now))
		require.NoError(t, err)
	}
	issue("WT-1", jiraWire(created, ny), jiraWire(later, cet), jiraWire(resolved, msk), utc(resolved))
	issue("WT-2", utc(created), utc(floor), "", "")
	noZone := now.Format("2006-01-02T15:04:05")
	issue("WT-3", "garbage", noZone, created.In(msk).Format(time.RFC3339Nano), "")

	_, err = raw.Exec(`INSERT INTO jira_comments (account_id, issue_key, id, body_text, created_at, updated_at)
		VALUES (1, 'WT-1', 'c1', 'b', ?, ?)`, jiraWire(created, ny), jiraWire(later, cet))
	require.NoError(t, err)

	inbox := func(channel, ts, trigger string) {
		t.Helper()
		_, err := raw.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type)
			VALUES (?, ?, ?, ?)`, channel, ts, channel, trigger)
		require.NoError(t, err)
	}
	inbox("WT-1", jiraWire(later, cet), "jira_assigned")
	inbox("WT-9", jiraWire(later, cet), "jira_comment_mention")
	inbox("C1", "1700000000.000100", "mention")

	_, err = raw.Exec(`INSERT INTO stream_digests (source, account_id, period_from, period_to) VALUES
		('jira', 1, ?, ?), ('gmail', 1, ?, ?)`,
		jiraWire(floor, msk), jiraWire(later, cet), jiraWire(floor, msk), jiraWire(later, cet))
	require.NoError(t, err)

	require.NoError(t, goose.Up(raw, "migrations"))

	col := func(query string, args ...any) string {
		t.Helper()
		var v string
		require.NoError(t, raw.QueryRow(query, args...).Scan(&v))
		return v
	}
	issueCols := func(key string) (createdAt, updatedAt, resolvedAt, catChanged string) {
		t.Helper()
		require.NoError(t, raw.QueryRow(`SELECT created_at, updated_at, resolved_at, status_category_changed_at
			FROM jira_issues WHERE key = ?`, key).Scan(&createdAt, &updatedAt, &resolvedAt, &catChanged))
		return
	}

	c, u, r, sc := issueCols("WT-1")
	assert.Equal(t, utc(created), c)
	assert.Equal(t, utc(later), u)
	assert.Equal(t, utc(resolved), r)
	assert.Equal(t, utc(resolved), sc, "an already canonical value is kept")
	c, u, r, _ = issueCols("WT-2")
	assert.Equal(t, utc(created), c)
	assert.Equal(t, utc(floor), u)
	assert.Empty(t, r, "an absent value stays empty")
	c, u, r, _ = issueCols("WT-3")
	assert.Equal(t, "garbage", c, "an unparseable value is kept verbatim")
	assert.Equal(t, noZone, u, "a value without a zone is not guessed at")
	assert.Equal(t, utc(created), r, "an RFC3339 value in another offset is converted")

	assert.Equal(t, utc(created), col(`SELECT created_at FROM jira_comments WHERE id = 'c1'`))
	assert.Equal(t, utc(later), col(`SELECT updated_at FROM jira_comments WHERE id = 'c1'`))

	assert.Equal(t, utc(floor), col(`SELECT ideas_jira_floor FROM jira_accounts WHERE id = 1`))
	assert.Equal(t, "WT-1", col(`SELECT key FROM jira_issues WHERE account_id = 1 AND updated_at > ?
		ORDER BY updated_at LIMIT 1`, utc(floor)), "the later change now sorts above the floor")

	assert.Equal(t, utc(later), col(`SELECT message_ts FROM inbox_items WHERE channel_id = 'WT-1'`))
	assert.Equal(t, utc(later), col(`SELECT message_ts FROM inbox_items WHERE channel_id = 'WT-9'`))
	assert.Equal(t, "1700000000.000100", col(`SELECT message_ts FROM inbox_items WHERE channel_id = 'C1'`))

	assert.Equal(t, utc(floor), col(`SELECT period_from FROM stream_digests WHERE source = 'jira'`))
	assert.Equal(t, utc(later), col(`SELECT period_to FROM stream_digests WHERE source = 'jira'`))
	assert.Equal(t, jiraWire(floor, msk), col(`SELECT period_from FROM stream_digests WHERE source = 'gmail'`),
		"a non-Jira digest is not touched")

	var days float64
	require.NoError(t, raw.QueryRow(`SELECT julianday(resolved_at) - julianday(created_at) FROM jira_issues
		WHERE key = 'WT-1'`).Scan(&days))
	assert.InDelta(t, resolved.Sub(created).Hours()/24, days, 1e-6, "julianday reads the rewritten values")
}
