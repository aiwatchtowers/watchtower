package daemon

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// seedPageMention writes a Slack message linking a page on the seeded site.
func seedPageMention(t *testing.T, database *db.DB) {
	t.Helper()
	_, err := database.Exec(`INSERT INTO messages (channel_id, ts, text) VALUES ('1:C1', '1758000000.000100',
		'see <https://acme.atlassian.net/wiki/spaces/ENG/pages/1001/Design|Design>')`)
	require.NoError(t, err)
}

func countDocLinks(t *testing.T, database *db.DB) int {
	t.Helper()
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM doc_links`).Scan(&n))
	return n
}

// With the feature on and a space selected, the phase also detects page
// links (doclinks.ScanSources) after the engine.
func TestPhaseExternalSync_ScansDocLinks(t *testing.T) {
	d, database, fake := newExternalSyncTestDaemon(t)
	d.config.Knowledge.Connectors.Enabled = true
	seedConfluenceSource(t, database)
	seedPageMention(t, database)

	d.phaseExternalSync(context.Background())

	assert.Equal(t, 1, fake.calls)
	links, err := database.DocLinksTo("confluence_page", "c1:1001", 10)
	require.NoError(t, err)
	require.Len(t, links, 1)
	assert.Equal(t, "slack:day:1:C1:2025-09-16", links[0].FromRef)
}

// FEAT-01: the feature off, or no space selected, scans nothing and writes
// no cursor.
func TestPhaseExternalSync_NoDocLinkScanWhenGatedOff(t *testing.T) {
	t.Run("feature off", func(t *testing.T) {
		d, database, _ := newExternalSyncTestDaemon(t)
		d.config.Knowledge.Connectors.Enabled = false
		seedConfluenceSource(t, database)
		seedPageMention(t, database)
		d.phaseExternalSync(context.Background())
		assert.Zero(t, countDocLinks(t, database))
		assert.Zero(t, countLinkCursors(t, database))
	})
	t.Run("no space selected", func(t *testing.T) {
		d, database, _ := newExternalSyncTestDaemon(t)
		d.config.Knowledge.Connectors.Enabled = true
		_, err := database.Exec(`INSERT INTO jira_accounts (id, cloud_id, site_url) VALUES (1, 'c1', 'https://acme.atlassian.net/')`)
		require.NoError(t, err)
		seedPageMention(t, database)
		d.phaseExternalSync(context.Background())
		assert.Zero(t, countDocLinks(t, database))
		assert.Zero(t, countLinkCursors(t, database))
	})
}

func countLinkCursors(t *testing.T, database *db.DB) int {
	t.Helper()
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM ext_link_state`).Scan(&n))
	return n
}
