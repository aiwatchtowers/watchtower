package daemon

import (
	"log"
	"os"
	"testing"

	"watchtower/internal/db"
	"watchtower/internal/feed"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// phaseFeed publishes open situations into the feed index via the real
// (AI-free) feed pipeline, and never propagates errors (DASH-06).
func TestDaemon_FeedPhase(t *testing.T) {
	orch, cfg, _ := testDaemonWithTempHome(t)
	cfg.Feed.Enabled = true
	cfg.Feed.MeetingLeadMinutes = 30

	dir := t.TempDir()
	t.Setenv("HOME", dir)
	wsDir := dir + "/.local/share/watchtower/test-ws"
	require.NoError(t, os.MkdirAll(wsDir, 0o755))

	database, err := db.Open(wsDir + "/watchtower.db")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })

	_, err = database.Exec(`INSERT INTO situations (id, title, priority, status, updated_at)
		VALUES (1, 'release blocked', 'high', 'open', '2026-07-09T10:00:00Z')`)
	require.NoError(t, err)

	d := newDaemon(orch, cfg)
	d.SetLogger(log.New(os.Stderr, "[test-feed] ", 0))
	d.SetDB(database)
	d.SetFeedPipeline(feed.New(database, cfg, log.New(os.Stderr, "[test-feed-pipe] ", 0)))

	d.phaseFeed()

	item, err := database.GetFeedItem("situation", "1")
	require.NoError(t, err)
	require.NotNil(t, item, "phaseFeed should publish the open situation")
	assert.Equal(t, "2026-07-09T10:00:00Z", item.EventTS)
	assert.Equal(t, 90, item.Importance)
}

func TestDaemon_FeedPhaseNilPipeline(t *testing.T) {
	orch, cfg, _ := testDaemonWithTempHome(t)

	d := newDaemon(orch, cfg)
	d.SetLogger(log.New(os.Stderr, "[test-nil-feed] ", 0))

	// Should not panic when no feed pipeline is installed.
	d.phaseFeed()
}
