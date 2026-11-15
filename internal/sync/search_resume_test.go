package sync

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	gosync "sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	watchtowerslack "watchtower/internal/slack"
)

// resumeNow is the fixed clock of the resume tests: the search window, and so
// the blanket query, stays the same across their runs.
var resumeNow = time.Date(2026, 9, 22, 15, 0, 0, 0, time.UTC)

// pagedSearch serves a blanket window of `pages` pages with one match each
// and a mention query of one page. While limitPage > 0 the blanket page of
// that number answers 429 with an hour's Retry-After, which runs past any
// run's fetch deadline, so the call returns ErrFetchDeadline at once.
type pagedSearch struct {
	mu        gosync.Mutex
	pages     int
	limitPage int
	requests  []string // "query#page" in request order
}

func (s *pagedSearch) handle(w http.ResponseWriter, r *http.Request) {
	_ = r.ParseForm()
	query := r.FormValue("query")
	page, _ := strconv.Atoi(r.FormValue("page"))
	s.mu.Lock()
	s.requests = append(s.requests, fmt.Sprintf("%s#%d", query, page))
	pages, limit := s.pages, s.limitPage
	s.mu.Unlock()

	if strings.HasPrefix(query, "<@") {
		match := map[string]any{"user": "U002", "username": "bob", "ts": mentionTS, "text": "<@U001> look",
			"channel": map[string]any{"id": "C001", "name": "general"}}
		jsonOK(w, map[string]any{"ok": true, "messages": map[string]any{
			"matches": []map[string]any{match},
			"paging":  map[string]any{"count": 100, "total": 1, "page": 1, "pages": 1},
			"total":   1,
		}})
		return
	}
	if limit > 0 && page == limit {
		w.Header().Set("Retry-After", "3600")
		w.WriteHeader(http.StatusTooManyRequests)
		return
	}
	jsonOK(w, map[string]any{"ok": true, "messages": map[string]any{
		"matches": []map[string]any{liveDiffMatch(dayTS(0, 8, page))},
		"paging":  map[string]any{"count": 100, "total": pages, "page": page, "pages": pages},
		"total":   pages,
	}})
}

// mentionTS is the ts of the mention query's one match.
var mentionTS = dayTS(0, 9, 30)

// blanket returns the pages requested by blanket (non-mention) queries since
// the last reset, as "query#page".
func (s *pagedSearch) blanket() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []string
	for _, r := range s.requests {
		if !strings.HasPrefix(r, "<@") {
			out = append(out, r)
		}
	}
	return out
}

func (s *pagedSearch) reset(limitPage int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.requests, s.limitPage = nil, limitPage
}

func newResumeSetup(t *testing.T, pages, limitPage int) (*testSetup, *pagedSearch) {
	t.Helper()
	s := &pagedSearch{pages: pages, limitPage: limitPage}
	ts := newTestSetup(t, searchAuditMux(s.handle))
	require.NoError(t, ts.db.UpsertWorkspace(db.Workspace{ID: "T001", Name: "test", Domain: "test"}))
	require.NoError(t, ts.db.SetSlackAccountSearchWatermark(ts.accountID, "2026-09-20"))
	ts.orch.now = func() time.Time { return resumeNow }
	return ts, s
}

// freshClient gives the orchestrator a new client, without the hour-long
// hold the previous run's 429 left — the next run would wait it out.
func (ts *testSetup) freshClient() {
	ts.orch.slackClient = watchtowerslack.NewClientWithAPIURLUnlimited("xoxp-test-token", ts.srv.URL+"/")
}

func pageRequests(query string, pages ...int) []string {
	out := make([]string, 0, len(pages))
	for _, p := range pages {
		out = append(out, fmt.Sprintf("%s#%d", query, p))
	}
	return out
}

const resumeQuery = "after:2026-09-18"

func TestSearchResume_ContinuesFromPage(t *testing.T) {
	ts, s := newResumeSetup(t, 6, 4)

	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	assert.Equal(t, pageRequests(resumeQuery, 1, 2, 3, 4), s.blanket(), "run 1 stops on page 4's deadline")
	assert.True(t, ts.orch.SearchIncomplete())
	wm, err := ts.db.GetSlackAccountSearchWatermark(ts.accountID)
	require.NoError(t, err)
	assert.Equal(t, "2026-09-20", wm, "the watermark waits for the whole window")
	out := ts.orch.RunOutcome()
	assert.True(t, out.RateLimited)
	assert.True(t, out.ResumePending)
	assert.Equal(t, 3, out.Pages)

	ts.freshClient()
	s.reset(0)
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	assert.Equal(t, pageRequests(resumeQuery, 4, 5, 6), s.blanket(), "run 2 fetches only the pages run 1 left")
	assert.False(t, ts.orch.SearchIncomplete())
	wm, err = ts.db.GetSlackAccountSearchWatermark(ts.accountID)
	require.NoError(t, err)
	assert.NotEqual(t, "2026-09-20", wm, "the finished window moves the watermark")
	out = ts.orch.RunOutcome()
	assert.False(t, out.RateLimited)
	assert.False(t, out.ResumePending)
	assert.Equal(t, 3, out.Pages)

	var n int
	require.NoError(t, ts.db.QueryRow(`SELECT COUNT(*) FROM messages WHERE ts <> ?`, mentionTS).Scan(&n))
	assert.Equal(t, 6, n, "every page of the window is stored")
}

func TestSearchResume_DroppedWhenQueryChanges(t *testing.T) {
	ts, s := newResumeSetup(t, 6, 4)
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	require.Equal(t, pageRequests(resumeQuery, 1, 2, 3, 4), s.blanket())

	// The window moved (another writer's watermark, a new day): the old page
	// position means nothing for the new query.
	require.NoError(t, ts.db.SetSlackAccountSearchWatermark(ts.accountID, "2026-09-21"))
	ts.freshClient()
	s.reset(0)
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	assert.Equal(t, pageRequests("after:2026-09-19", 1, 2, 3, 4, 5, 6), s.blanket())
	assert.False(t, ts.orch.RunOutcome().ResumePending)
}

func TestSearchResume_RestartReReads(t *testing.T) {
	ts, s := newResumeSetup(t, 6, 4)
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	require.True(t, ts.orch.RunOutcome().ResumePending)

	// A restarted daemon builds a new orchestrator: the position was in memory.
	ts.freshClient()
	ts.orch = NewOrchestrator(ts.db, ts.orch.slackClient, ts.orch.config, ts.accountID)
	ts.orch.now = func() time.Time { return resumeNow }
	s.reset(0)
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	assert.Equal(t, pageRequests(resumeQuery, 1, 2, 3, 4, 5, 6), s.blanket())
}

func TestSearchResume_NoDiffOnResumedRun(t *testing.T) {
	ts, s := newResumeSetup(t, 6, 4)
	// A stored message the search never returns: a diff would tombstone it.
	gone := dayTS(0, 10, 0)
	require.NoError(t, ts.db.UpsertMessage(db.Message{ChannelID: ts.ns("C001"), TS: gone, UserID: ts.ns("U001"), Text: "gone"}))

	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	ts.freshClient()
	s.reset(0)
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	require.False(t, ts.orch.SearchIncomplete(), "run 2 finished the window")
	assert.False(t, isTombstone(t, ts.db, ts.ns("C001"), gone), "a window read across two runs is never diffed")

	// Control: the same window read in one run is diffed.
	require.NoError(t, ts.db.SetSlackAccountSearchWatermark(ts.accountID, "2026-09-20"))
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	assert.True(t, isTombstone(t, ts.db, ts.ns("C001"), gone))
}

func TestSearchResume_FirstSyncCarriedAcrossRuns(t *testing.T) {
	ts, s := newResumeSetup(t, 6, 4)
	require.NoError(t, ts.db.SetSlackAccountSearchWatermark(ts.accountID, ""))
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	_, ok := ts.orch.FirstSyncFrom()
	require.False(t, ok, "an unfinished first sync starts no backfill")

	ts.freshClient()
	s.reset(0)
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	require.False(t, ts.orch.SearchIncomplete())
	_, ok = ts.orch.FirstSyncFrom()
	assert.True(t, ok, "the first sync finished by a resumed run is still the account's first")
}

// TestRun_ResetsFetchDeadline: Run's deadline lasts only the run. A later
// call on the same client (the CLI, the chat, media) meets the run's
// leftover hour-long hold and waits on its own ctx, as without a deadline,
// instead of failing with ErrFetchDeadline.
func TestRun_ResetsFetchDeadline(t *testing.T) {
	ts, _ := newResumeSetup(t, 3, 1)
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	require.True(t, ts.orch.SearchIncomplete(), "page 1 met the deadline during the run")

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := ts.orch.slackClient.GetEmoji(ctx)
	require.Error(t, err)
	assert.ErrorIs(t, err, context.Canceled)
	assert.False(t, errors.Is(err, watchtowerslack.ErrFetchDeadline), "no deadline after the run")
}
