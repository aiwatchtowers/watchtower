package sync

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	gosync "sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// sweepSearch answers search.messages by query: each query returns its own
// ts list as one page (or reports pages), and may be rate-limited.
type sweepSearch struct {
	mu          gosync.Mutex
	results     map[string][]string // query → returned ts
	texts       map[string]string   // ts → text (default "msg <ts>")
	pages       map[string]int      // query → reported pages (default 1)
	rateLimited func(query string) bool
	queries     []string
}

func newSweepSearch() *sweepSearch {
	return &sweepSearch{results: map[string][]string{}, texts: map[string]string{}, pages: map[string]int{}}
}

func (s *sweepSearch) handle(w http.ResponseWriter, r *http.Request) {
	q := r.FormValue("query")
	s.mu.Lock()
	s.queries = append(s.queries, q)
	limited := s.rateLimited != nil && s.rateLimited(q)
	returned, pages := s.results[q], s.pages[q]
	matches := make([]map[string]any, 0, len(returned))
	for _, msgTS := range returned {
		m := liveDiffMatch(msgTS)
		if text, ok := s.texts[msgTS]; ok {
			m["text"] = text
		}
		matches = append(matches, m)
	}
	s.mu.Unlock()
	if limited {
		w.Header().Set("Retry-After", "0")
		w.WriteHeader(http.StatusTooManyRequests)
		return
	}
	if pages == 0 {
		pages = 1
	}
	jsonOK(w, map[string]any{"ok": true, "messages": map[string]any{
		"matches": matches,
		"paging":  map[string]any{"count": 100, "total": len(matches), "page": 1, "pages": pages},
		"total":   len(matches),
	}})
}

func (s *sweepSearch) sent() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string{}, s.queries...)
}

const (
	sweepQuery10 = "after:2026-09-09 before:2026-09-12" // sweeps 2026-09-10
	sweepQuery05 = "after:2026-09-04 before:2026-09-07" // sweeps 2026-09-05
)

// newSweepSetup builds an orchestrator at liveDiffNow (2026-09-22T15:00Z)
// holding n plain rows on 2026-09-10 and on 2026-09-05 in C001.
func newSweepSetup(t *testing.T, n int) (*testSetup, *sweepSearch, map[int][]string) {
	t.Helper()
	s := newSweepSearch()
	ts := newTestSetup(t, searchAuditMux(s.handle))
	require.NoError(t, ts.db.UpsertWorkspace(db.Workspace{ID: "T001", Name: "test", Domain: "test"}))
	require.NoError(t, ts.db.EnsureUser(ts.ns("U001"), "alice"))
	// A known channel keeps Run off the zero-channel full-sync fallback.
	require.NoError(t, ts.db.EnsureChannel(ts.ns("C001"), "general", "public", ""))
	ts.orch.now = func() time.Time { return liveDiffNow }
	rows := map[int][]string{10: seedDay(t, ts, 10, n), 5: seedDay(t, ts, 5, n)}
	return ts, s, rows
}

// seedDay stores n plain rows in C001 on 2026-09-<day> from 08:00Z, 20 min apart.
func seedDay(t *testing.T, ts *testSetup, day, n int) []string {
	t.Helper()
	out := make([]string, n)
	for i := range n {
		out[i] = fmt.Sprintf("%d.000100", time.Date(2026, 9, day, 8, 20*i, 0, 0, time.UTC).Unix())
		require.NoError(t, ts.db.UpsertMessage(db.Message{ChannelID: ts.ns("C001"), TS: out[i], UserID: ts.ns("U001"),
			Text: "msg " + out[i]}))
	}
	return out
}

func sweepCursor(t *testing.T, ts *testSetup) string {
	t.Helper()
	day, err := ts.db.SlackDeletionSweepDay(ts.accountID)
	require.NoError(t, err)
	return day
}

func TestSweep_FirstRunTakesNewestDayAndAdvances(t *testing.T) {
	ts, s, rows := newSweepSetup(t, 4)
	s.results[sweepQuery10] = rows[10][:3]
	require.NoError(t, ts.orch.sweepDeletionDay(context.Background()))

	assert.Equal(t, []string{sweepQuery10}, s.sent())
	assert.True(t, isTombstone(t, ts.db, ts.ns("C001"), rows[10][3]))
	assert.Equal(t, 1, countTombstones(t, ts.db))
	assert.Equal(t, "2026-09-10", sweepCursor(t, ts))
}

func TestSweep_NextRunWalksBackThenWraps(t *testing.T) {
	ts, s, rows := newSweepSetup(t, 2)
	s.results[sweepQuery10] = rows[10]
	s.results[sweepQuery05] = rows[5]

	require.NoError(t, ts.db.SetSlackDeletionSweepDay(ts.accountID, "2026-09-10"))
	require.NoError(t, ts.orch.sweepDeletionDay(context.Background()))
	assert.Equal(t, []string{sweepQuery05}, s.sent())
	assert.Equal(t, "2026-09-05", sweepCursor(t, ts))

	require.NoError(t, ts.orch.sweepDeletionDay(context.Background()))
	assert.Equal(t, []string{sweepQuery05, sweepQuery10}, s.sent(), "past the oldest day the sweep wraps to the newest")
	assert.Equal(t, "2026-09-10", sweepCursor(t, ts))
	assert.Equal(t, 0, countTombstones(t, ts.db))
}

func TestSweep_DiffsOnlyTheSweptDay(t *testing.T) {
	ts, s, rows := newSweepSetup(t, 4)
	nextDay := seedDay(t, ts, 11, 1)
	require.NoError(t, ts.db.SetSlackDeletionSweepDay(ts.accountID, "2026-09-11"))
	s.results[sweepQuery10] = rows[10][:3] // the 2026-09-11 row is inside the query but absent
	require.NoError(t, ts.orch.sweepDeletionDay(context.Background()))

	assert.Equal(t, []string{sweepQuery10}, s.sent())
	assert.True(t, isTombstone(t, ts.db, ts.ns("C001"), rows[10][3]), "the diff ran")
	assert.False(t, isTombstone(t, ts.db, ts.ns("C001"), nextDay[0]), "a row outside [day, day+1) survives")
	assert.Equal(t, 1, countTombstones(t, ts.db))
}

func TestSweep_RefreshesEditedText(t *testing.T) {
	ts, s, rows := newSweepSetup(t, 2)
	s.results[sweepQuery10] = rows[10]
	s.texts[rows[10][0]] = "edited text"
	require.NoError(t, ts.orch.sweepDeletionDay(context.Background()))

	var text string
	require.NoError(t, ts.db.QueryRow(`SELECT text FROM messages WHERE channel_id = ? AND ts = ?`,
		ts.ns("C001"), rows[10][0]).Scan(&text))
	assert.Equal(t, "edited text", text)
	var n int
	require.NoError(t, ts.db.QueryRow(`SELECT COUNT(*) FROM kb_dirty WHERE source = 'slack' AND key = ?`,
		"slack:day:"+ts.ns("C001")+":2026-09-10").Scan(&n))
	assert.Equal(t, 1, n)
}

func TestSweep_TooManyPagesSkipsAndAdvances(t *testing.T) {
	ts, s, rows := newSweepSetup(t, 4)
	s.results[sweepQuery10] = rows[10][:3]
	s.pages[sweepQuery10] = sweepMaxPages + 1
	require.NoError(t, ts.orch.sweepDeletionDay(context.Background()))

	assert.Equal(t, []string{sweepQuery10}, s.sent(), "only page 1 is fetched")
	assert.Equal(t, 0, countTombstones(t, ts.db))
	assert.Equal(t, "2026-09-10", sweepCursor(t, ts))
}

func TestSweep_RateLimitedHoldsCursor(t *testing.T) {
	ts, s, rows := newSweepSetup(t, 4)
	s.results[sweepQuery10] = rows[10][:3]
	s.rateLimited = func(string) bool { return true }
	require.NoError(t, ts.db.SetSlackDeletionSweepDay(ts.accountID, "2026-09-11"))
	require.NoError(t, ts.orch.sweepDeletionDay(context.Background()))

	assert.Equal(t, 0, countTombstones(t, ts.db))
	assert.Equal(t, "2026-09-11", sweepCursor(t, ts))
}

func TestSweep_GuardRefusalAdvances(t *testing.T) {
	ts, _, _ := newSweepSetup(t, 6)
	require.NoError(t, ts.orch.sweepDeletionDay(context.Background()))

	assert.Equal(t, 0, countTombstones(t, ts.db))
	assert.Equal(t, "2026-09-10", sweepCursor(t, ts))
}

func TestSweep_NothingStoredSendsNoQuery(t *testing.T) {
	s := newSweepSearch()
	ts := newTestSetup(t, searchAuditMux(s.handle))
	ts.orch.now = func() time.Time { return liveDiffNow }
	require.NoError(t, ts.orch.sweepDeletionDay(context.Background()))
	assert.Empty(t, s.sent())
	assert.Empty(t, sweepCursor(t, ts))
}

func sweepQueries(queries []string) []string {
	var out []string
	for _, q := range queries {
		if strings.Contains(q, "before:") {
			out = append(out, q)
		}
	}
	return out
}

func TestRunSearchSync_SkipsSweepWhenRateLimited(t *testing.T) {
	ts, s, _ := newSweepSetup(t, 4)
	require.NoError(t, ts.db.SetSlackAccountSearchWatermark(ts.accountID, "2026-09-20"))
	s.rateLimited = func(string) bool { return true }
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))

	require.NotEmpty(t, s.sent(), "the live search ran")
	assert.Empty(t, sweepQueries(s.sent()))
	assert.Empty(t, sweepCursor(t, ts))
}

func TestRunSearchSync_SweepsAfterCompletedSearch(t *testing.T) {
	ts, s, rows := newSweepSetup(t, 4)
	require.NoError(t, ts.db.SetSlackAccountSearchWatermark(ts.accountID, "2026-09-20"))
	s.results[sweepQuery10] = rows[10][:3]
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))

	assert.Equal(t, []string{sweepQuery10}, sweepQueries(s.sent()))
	assert.True(t, isTombstone(t, ts.db, ts.ns("C001"), rows[10][3]))
	assert.Equal(t, "2026-09-10", sweepCursor(t, ts))
}
