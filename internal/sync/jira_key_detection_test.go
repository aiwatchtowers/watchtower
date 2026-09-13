package sync

import (
	"context"
	"net/http"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/jira"
)

// recordingKeyDetector captures every page handed to the sync's Jira hook.
type recordingKeyDetector struct {
	pages [][]db.Message
}

func (r *recordingKeyDetector) ProcessMessageBatch(msgs []db.Message) (int, error) {
	page := make([]db.Message, len(msgs))
	copy(page, msgs)
	r.pages = append(r.pages, page)
	return 0, nil
}

// jiraMentionMux serves one channel whose single message mentions a Jira key.
func jiraMentionMux() *http.ServeMux {
	return messageMux(map[string][]map[string]any{
		"C001": {
			{"ts": "1700000001.000000", "user": "U001", "text": "shipping PROJ-42 today", "type": "message"},
		},
	})
}

// The detector must be fed the very ids that land in the messages table: a
// namespaced channel id and the raw Slack ts. Every reader of a mention link
// joins channel_id/message_ts straight back against messages, so a bare id here
// would produce rows no reader can ever resolve.
func TestSyncMessages_JiraDetectorSeesTheIDsThatLandInMessages(t *testing.T) {
	ts := newTestSetup(t, jiraMentionMux())
	rec := &recordingKeyDetector{}
	ts.orch.SetJiraKeyDetector(rec)

	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{Full: true}))

	stored, err := ts.db.GetMessagesByChannel(ts.ns("C001"), 100)
	require.NoError(t, err)
	require.Len(t, stored, 1)

	var seen []db.Message
	for _, page := range rec.pages {
		seen = append(seen, page...)
	}
	require.NotEmpty(t, seen, "the sync must hand its synced messages to the detector")

	var match *db.Message
	for i := range seen {
		if seen[i].TS == stored[0].TS {
			match = &seen[i]
			break
		}
	}
	require.NotNil(t, match, "the detector must see the message that was stored")
	assert.Equal(t, ts.ns("C001"), match.ChannelID, "the detector must be given the namespaced channel id")
	assert.Equal(t, stored[0].ChannelID, match.ChannelID, "detector id and messages.channel_id must be the same value")
	assert.Equal(t, stored[0].TS, match.TS, "detector ts and messages.ts must be the same value")
	assert.Equal(t, "shipping PROJ-42 today", match.Text)
}

// End to end with the real detector: a synced message mentioning a known
// project key produces a mention row carrying the namespaced channel id and the
// real message ts — the pair the four flagship readers require and that the
// track/decision link kinds (message_ts = "") can never supply.
func TestSyncMessages_ProducesMentionLinksForKnownProjectKeys(t *testing.T) {
	ts := newTestSetup(t, jiraMentionMux())
	db.SeedTestJiraAccount(t, ts.db)
	require.NoError(t, ts.db.UpsertJiraIssue(db.JiraIssue{
		AccountID: 1,
		Key:       "PROJ-1", ProjectKey: "PROJ", Summary: "S", Status: "O", StatusCategory: "todo",
		CreatedAt: "now", UpdatedAt: "now", SyncedAt: "now",
	}))
	ts.orch.SetJiraKeyDetector(jira.NewKeyDetector(ts.db))

	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{Full: true}))

	links, err := ts.db.GetJiraSlackLinksByIssue("PROJ-42")
	require.NoError(t, err)
	require.Len(t, links, 1)
	assert.Equal(t, "mention", links[0].LinkType)
	assert.Equal(t, ts.ns("C001"), links[0].ChannelID)
	assert.Equal(t, "1700000001.000000", links[0].MessageTS)

	// The link resolves back to a real message — which is the whole point of a
	// mention link, and what a bare channel id or an empty ts would break.
	byMessage, err := ts.db.GetJiraSlackLinksByMessage(links[0].ChannelID, links[0].MessageTS)
	require.NoError(t, err)
	assert.Len(t, byMessage, 1)
	msgs, err := ts.db.GetMessagesByTS(links[0].ChannelID, []string{links[0].MessageTS})
	require.NoError(t, err)
	assert.Len(t, msgs, 1, "the mention link must point at a message that exists")
}

// The search path is what an ordinary incremental sync runs — the per-channel
// history path only runs under --full/--channels — so the hook must fire there
// too, or the detector stays dead on the daemon's normal cycle.
func TestSyncViaSearch_JiraDetectorSeesTheIDsThatLandInMessages(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/search.messages", func(w http.ResponseWriter, _ *http.Request) {
		jsonOK(w, map[string]any{
			"ok": true,
			"messages": map[string]any{
				"matches": []map[string]any{{
					"ts":      "1700000001.000000",
					"user":    "U001",
					"text":    "shipping PROJ-42 today",
					"channel": map[string]any{"id": "C001", "name": "general"},
				}},
				"paging": map[string]any{"count": 100, "total": 1, "page": 1, "pages": 1},
				"total":  1,
			},
		})
	})

	ts := newTestSetup(t, mux)
	rec := &recordingKeyDetector{}
	ts.orch.SetJiraKeyDetector(rec)

	require.NoError(t, ts.orch.syncViaSearch(context.Background()))

	var seen []db.Message
	for _, page := range rec.pages {
		seen = append(seen, page...)
	}
	require.Len(t, seen, 1, "the search path must hand its messages to the detector")
	assert.Equal(t, ts.ns("C001"), seen[0].ChannelID)
	assert.Equal(t, "1700000001.000000", seen[0].TS)

	stored, err := ts.db.GetMessagesByChannel(ts.ns("C001"), 100)
	require.NoError(t, err)
	require.Len(t, stored, 1)
	assert.Equal(t, stored[0].ChannelID, seen[0].ChannelID)
	assert.Equal(t, stored[0].TS, seen[0].TS)
}

// An unwired orchestrator is byte-identical to the pre-wiring behaviour: no
// detector, no links, no panic on the nil hook.
func TestSyncMessages_WithoutDetectorWritesNoLinks(t *testing.T) {
	ts := newTestSetup(t, jiraMentionMux())
	db.SeedTestJiraAccount(t, ts.db)

	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{Full: true}))

	links, err := ts.db.GetJiraSlackLinksByIssue("PROJ-42")
	require.NoError(t, err)
	assert.Empty(t, links)
}
