package sync

import (
	"context"
	"fmt"
	"net/http"
	gosync "sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// liveDiffNow is the fixed clock of the live-diff tests: the window it gives
// is [2026-09-22T00:00Z, 13:00Z).
var liveDiffNow = time.Date(2026, 9, 22, 15, 0, 0, 0, time.UTC)

func TestLiveDiffWindow(t *testing.T) {
	from, to := liveDiffWindow(liveDiffNow)
	assert.Equal(t, time.Date(2026, 9, 22, 0, 0, 0, 0, time.UTC), from)
	assert.Equal(t, time.Date(2026, 9, 22, 13, 0, 0, 0, time.UTC), to)

	from, to = liveDiffWindow(time.Date(2026, 9, 22, 1, 30, 0, 0, time.UTC))
	assert.False(t, to.After(from), "the first 2 h of a UTC day give an empty window")
}

// dayTS is a Slack ts at h:m UTC on 2026-09-22 (+ day offset).
func dayTS(dayOffset, h, m int) string {
	at := time.Date(2026, 9, 22+dayOffset, h, m, 0, 0, time.UTC)
	return fmt.Sprintf("%d.000100", at.Unix())
}

// liveDiffMatch is one search.messages match in channel C001.
func liveDiffMatch(ts string) map[string]any {
	return map[string]any{"user": "U001", "username": "alice", "ts": ts, "text": "msg " + ts,
		"channel": map[string]any{"id": "C001", "name": "general"}}
}

// liveDiffSearch serves the returned ts list as one page reporting total.
type liveDiffSearch struct {
	mu       gosync.Mutex
	returned []string
	total    int // -1 = len(returned)
	pages    int // 0 = 1
	calls    int
}

func (s *liveDiffSearch) set(returned []string, total int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.returned, s.total, s.pages = returned, total, 0
}

func (s *liveDiffSearch) handle(w http.ResponseWriter, _ *http.Request) {
	s.mu.Lock()
	s.calls++
	n := s.calls
	returned, total, pages := s.returned, s.total, s.pages
	s.mu.Unlock()
	if pages == 0 {
		pages = 1
	}
	if n > 1 && pages > 1 {
		jsonOK(w, map[string]any{"ok": false, "error": "missing_scope"})
		return
	}
	if total < 0 {
		total = len(returned)
	}
	matches := make([]map[string]any, 0, len(returned))
	for _, ts := range returned {
		matches = append(matches, liveDiffMatch(ts))
	}
	jsonOK(w, map[string]any{"ok": true, "messages": map[string]any{
		"matches": matches,
		"paging":  map[string]any{"count": 100, "total": total, "page": 1, "pages": pages},
		"total":   total,
	}})
}

// newLiveDiffSetup builds a search-path orchestrator with its clock at
// liveDiffNow and a watermark so Run takes the search path.
func newLiveDiffSetup(t *testing.T) (*testSetup, *liveDiffSearch) {
	t.Helper()
	s := &liveDiffSearch{total: -1}
	ts := newTestSetup(t, searchAuditMux(s.handle))
	require.NoError(t, ts.db.UpsertWorkspace(db.Workspace{ID: "T001", Name: "test", Domain: "test"}))
	require.NoError(t, ts.db.SetSlackAccountSearchWatermark(ts.accountID, "2026-09-20"))
	ts.orch.now = func() time.Time { return liveDiffNow }
	return ts, s
}

// seedLive stores n plain messages in C001 at 08:00Z + 20 min steps and returns their ts.
func seedLive(t *testing.T, ts *testSetup, n int) []string {
	t.Helper()
	out := make([]string, n)
	for i := range n {
		out[i] = dayTS(0, 8, 20*i) // time.Date normalises the minutes
		require.NoError(t, ts.db.UpsertMessage(db.Message{ChannelID: ts.ns("C001"), TS: out[i], UserID: ts.ns("U001"),
			Text: "msg " + out[i]}))
	}
	return out
}

func isTombstone(t *testing.T, d *db.DB, channelID, msgTS string) bool {
	t.Helper()
	var deleted int
	var text string
	require.NoError(t, d.QueryRow(`SELECT is_deleted, text FROM messages WHERE channel_id = ? AND ts = ?`,
		channelID, msgTS).Scan(&deleted, &text))
	if deleted == 1 {
		assert.Empty(t, text, "a tombstone has no text")
	}
	return deleted == 1
}

func countTombstones(t *testing.T, d *db.DB) int {
	t.Helper()
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM messages WHERE is_deleted = 1`).Scan(&n))
	return n
}

func TestLiveDiff_TombstonesMissingRow(t *testing.T) {
	ts, s := newLiveDiffSetup(t)
	stored := seedLive(t, ts, 10)
	s.set(append([]string{}, stored[:9]...), -1)
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))

	assert.True(t, isTombstone(t, ts.db, ts.ns("C001"), stored[9]))
	assert.Equal(t, 1, countTombstones(t, ts.db))
	var n int
	require.NoError(t, ts.db.QueryRow(`SELECT COUNT(*) FROM kb_dirty WHERE source = 'slack' AND key = ?`,
		"slack:day:"+ts.ns("C001")+":2026-09-22").Scan(&n))
	assert.Equal(t, 1, n)
}

func TestLiveDiff_SkipsWhenListingEmpty(t *testing.T) {
	ts, s := newLiveDiffSetup(t)
	seedLive(t, ts, 6)
	s.set(nil, -1)
	// Zero channels discovered sends Run on to a full sync this mux does not
	// serve; its error is beside the point, the live diff has already run.
	_ = ts.orch.Run(context.Background(), SyncOptions{})
	assert.Equal(t, 0, countTombstones(t, ts.db))
}

func TestLiveDiff_SkipsOverHalf(t *testing.T) {
	ts, s := newLiveDiffSetup(t)
	stored := seedLive(t, ts, 10)
	s.set(append([]string{}, stored[:4]...), -1)
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	assert.Equal(t, 0, countTombstones(t, ts.db))
}

// Slack caps search at 100 pages: a "completed" listing whose matches fall
// short of the reported total is truncated and proves nothing.
func TestLiveDiff_SkipsWhenTotalExceedsMatched(t *testing.T) {
	ts, s := newLiveDiffSetup(t)
	stored := seedLive(t, ts, 10)
	s.set(append([]string{}, stored[:9]...), 500)
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	assert.Equal(t, 0, countTombstones(t, ts.db))
}

func TestLiveDiff_SkipsIncompletePages(t *testing.T) {
	ts, s := newLiveDiffSetup(t)
	stored := seedLive(t, ts, 10)
	s.set(append([]string{}, stored[:9]...), -1)
	s.mu.Lock()
	s.pages = 2
	s.mu.Unlock()
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	assert.True(t, ts.orch.SearchIncomplete())
	assert.Equal(t, 0, countTombstones(t, ts.db))
}

func TestLiveDiff_LeavesRowsOutsideItsScope(t *testing.T) {
	ts, s := newLiveDiffSetup(t)
	stored := seedLive(t, ts, 4) // in scope: 3 returned, 1 missing (proves the diff ran)
	outside := []db.Message{
		{ChannelID: ts.ns("C001"), TS: dayTS(0, 14, 0), Text: "last two hours"},
		{ChannelID: ts.ns("C001"), TS: dayTS(0, 9, 5), Text: "joined", Subtype: "channel_join"},
		{ChannelID: ts.ns("C001"), TS: dayTS(-1, 10, 0), Text: "yesterday"},
		{ChannelID: "2:C001", TS: dayTS(0, 10, 0), Text: "account two"},
	}
	for _, m := range outside {
		require.NoError(t, ts.db.UpsertMessage(m))
	}
	s.set(append([]string{}, stored[:3]...), -1)
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))

	assert.True(t, isTombstone(t, ts.db, ts.ns("C001"), stored[3]))
	for _, m := range outside {
		assert.False(t, isTombstone(t, ts.db, m.ChannelID, m.TS), "%s must survive", m.Text)
	}
	assert.Equal(t, 1, countTombstones(t, ts.db))
}

func TestLiveDiff_ReturningMessageHeals(t *testing.T) {
	ts, s := newLiveDiffSetup(t)
	stored := seedLive(t, ts, 10)
	s.set(append([]string{}, stored[:9]...), -1)
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	require.True(t, isTombstone(t, ts.db, ts.ns("C001"), stored[9]))

	s.set(append([]string{}, stored...), -1)
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	var deleted int
	var text string
	require.NoError(t, ts.db.QueryRow(`SELECT is_deleted, text FROM messages WHERE channel_id = ? AND ts = ?`,
		ts.ns("C001"), stored[9]).Scan(&deleted, &text))
	assert.Equal(t, 0, deleted)
	assert.Equal(t, "msg "+stored[9], text)
}

func TestBackfillSearch_NeverTombstones(t *testing.T) {
	ts, s := newLiveDiffSetup(t)
	stored := seedLive(t, ts, 10)
	s.set(append([]string{}, stored[:9]...), -1)
	from := time.Date(2026, 9, 22, 0, 0, 0, 0, time.UTC)
	_, err := ts.orch.BackfillSearch(context.Background(), from, from.AddDate(0, 0, 1))
	require.NoError(t, err)
	assert.Equal(t, 0, countTombstones(t, ts.db))
}
