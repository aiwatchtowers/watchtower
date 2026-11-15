package sync

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	gosync "sync"
	"sync/atomic"
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
	mu         gosync.Mutex
	pages      int
	limitPage  int
	deleted    int                      // item removed from the window (0 = none); later items slide back a page
	errPage    int                      // blanket page answered missing_scope (0 = none)
	mentionErr bool                     // the mention query answers missing_scope
	onPage     func(page int)           // called before a blanket page is answered
	extra      map[int][]map[string]any // more matches on a blanket page (nil = none)
	requests   []string                 // "query#page" in request order
}

func (s *pagedSearch) handle(w http.ResponseWriter, r *http.Request) {
	_ = r.ParseForm()
	query := r.FormValue("query")
	page, _ := strconv.Atoi(r.FormValue("page"))
	s.mu.Lock()
	s.requests = append(s.requests, fmt.Sprintf("%s#%d", query, page))
	pages, limit, deleted, errPage, mentionErr, onPage := s.pages, s.limitPage, s.deleted, s.errPage, s.mentionErr, s.onPage
	extra := s.extra[page]
	s.mu.Unlock()

	if strings.HasPrefix(query, "<@") && mentionErr {
		jsonOK(w, map[string]any{"ok": false, "error": "missing_scope"})
		return
	}
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
	if onPage != nil {
		onPage(page)
	}
	if errPage > 0 && page == errPage {
		jsonOK(w, map[string]any{"ok": false, "error": "missing_scope"})
		return
	}
	if limit > 0 && page == limit {
		w.Header().Set("Retry-After", "3600")
		w.WriteHeader(http.StatusTooManyRequests)
		return
	}
	item := page
	if deleted > 0 {
		pages--
		if item >= deleted {
			item++
		}
	}
	jsonOK(w, map[string]any{"ok": true, "messages": map[string]any{
		"matches": append([]map[string]any{liveDiffMatch(itemTS(item))}, extra...),
		"paging":  map[string]any{"count": 100, "total": pages, "page": page, "pages": pages},
		"total":   pages,
	}})
}

// itemTS is the ts of the window's item i (one per page).
func itemTS(i int) string { return dayTS(0, 8, i) }

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
	// The deadline stop ends the cycle cleanly: the roster phase, which would
	// meet the same hold and fail the run, is skipped, and the row keeps a note.
	rosterSyncedAt, err := ts.db.SlackRosterSyncedAt(ts.accountID)
	require.NoError(t, err)
	assert.True(t, rosterSyncedAt.IsZero(), "the roster refresh is left for the next cycle")
	acct, err := ts.db.GetSlackAccount(ts.accountID)
	require.NoError(t, err)
	assert.Equal(t, "ok", acct.Status)
	assert.Contains(t, acct.Error, "rate-limited")

	ts.freshClient()
	s.reset(0)
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	assert.Equal(t, pageRequests(resumeQuery, 3, 4, 5, 6), s.blanket(),
		"run 2 re-reads the last page run 1 read, then the pages it left")
	assert.False(t, ts.orch.SearchIncomplete())
	wm, err = ts.db.GetSlackAccountSearchWatermark(ts.accountID)
	require.NoError(t, err)
	assert.NotEqual(t, "2026-09-20", wm, "the finished window moves the watermark")
	out = ts.orch.RunOutcome()
	assert.False(t, out.RateLimited)
	assert.False(t, out.ResumePending)
	assert.Equal(t, 4, out.Pages)

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

// TestSearchResume_DeletionOnReadPageSkipsNothing: a message deleted from
// a page run 1 already read slides every later match back a page; the
// resumed run's one-page overlap still reads the match that slid onto the
// last page run 1 read.
func TestSearchResume_DeletionOnReadPageSkipsNothing(t *testing.T) {
	ts, s := newResumeSetup(t, 6, 4)
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	require.Equal(t, pageRequests(resumeQuery, 1, 2, 3, 4), s.blanket())

	ts.freshClient()
	s.reset(0)
	s.mu.Lock()
	s.deleted = 2 // item 4 now sits on page 3, which run 1 read before it
	s.mu.Unlock()
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	require.False(t, ts.orch.SearchIncomplete())

	var n int
	require.NoError(t, ts.db.QueryRow(`SELECT COUNT(*) FROM messages WHERE channel_id = ? AND ts = ?`,
		ts.ns("C001"), itemTS(4)).Scan(&n))
	assert.Equal(t, 1, n, "the match that slid onto an already-read page is stored")
}

// TestSearchResume_FailingRunsKeepTheirPosition: a resumed run that stops
// on its overlap page keeps the old stop page, so the position never walks
// backwards run after run.
func TestSearchResume_FailingRunsKeepTheirPosition(t *testing.T) {
	ts, s := newResumeSetup(t, 6, 4)
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))

	for range 2 {
		ts.freshClient()
		s.reset(3) // the overlap page itself is rate-limited
		require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
		assert.Equal(t, pageRequests(resumeQuery, 3), s.blanket())
	}
	ts.freshClient()
	s.reset(0)
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	assert.Equal(t, pageRequests(resumeQuery, 3, 4, 5, 6), s.blanket())
}

// TestAdaptive_MentionQueryFirst: an account that is behind (here, its last
// run was rate-limited) runs the mention query before the blanket query, so
// the mention lands even while the blanket query stays rate-limited.
func TestAdaptive_MentionQueryFirst(t *testing.T) {
	ts, s := newResumeSetup(t, 3, 1)
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	require.True(t, ts.orch.RunOutcome().RateLimited)
	require.Equal(t, []string{resumeQuery + "#1"}, s.requests, "a clean account runs no mention query")

	ts.freshClient()
	s.reset(1)
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	s.mu.Lock()
	requests := append([]string(nil), s.requests...)
	s.mu.Unlock()
	require.GreaterOrEqual(t, len(requests), 2)
	assert.Equal(t, "<@U001> "+resumeQuery+"#1", requests[0], "the mention query runs first")
	assert.Equal(t, resumeQuery+"#1", requests[1], "then the blanket query")

	var n int
	require.NoError(t, ts.db.QueryRow(`SELECT COUNT(*) FROM messages WHERE channel_id = ? AND ts = ?`,
		ts.ns("C001"), mentionTS).Scan(&n))
	assert.Equal(t, 1, n, "the mention is stored although the blanket query is rate-limited")
	assert.True(t, ts.orch.SearchIncomplete(), "the blanket window is unfinished")
	wm, err := ts.db.GetSlackAccountSearchWatermark(ts.accountID)
	require.NoError(t, err)
	assert.Equal(t, "2026-09-20", wm, "the mention query never moves the watermark")
}

// TestAdaptive_CleanRunNoMentionQuery: a clean account issues no mention
// query; once a behind account catches up, the next run is clean again.
func TestAdaptive_CleanRunNoMentionQuery(t *testing.T) {
	ts, s := newResumeSetup(t, 3, 0)
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	assert.Equal(t, pageRequests(resumeQuery, 1, 2, 3), s.requests, "a clean run sends only the blanket query")

	// Behind (a pending resume), then caught up.
	ts2, s2 := newResumeSetup(t, 6, 4)
	require.NoError(t, ts2.orch.Run(context.Background(), SyncOptions{}))
	ts2.freshClient()
	s2.reset(0)
	require.NoError(t, ts2.orch.Run(context.Background(), SyncOptions{}))
	assert.Equal(t, "<@U001> "+resumeQuery+"#1", s2.requests[0], "the behind run reads mentions first")
	require.False(t, ts2.orch.RunOutcome().RateLimited)
	require.False(t, ts2.orch.RunOutcome().ResumePending)

	require.NoError(t, ts2.db.SetSlackAccountSearchWatermark(ts2.accountID, "2026-09-20"))
	s2.reset(0)
	require.NoError(t, ts2.orch.Run(context.Background(), SyncOptions{}))
	assert.Equal(t, pageRequests(resumeQuery, 1, 2, 3, 4, 5, 6), s2.requests, "caught up: no mention query")
}

func TestAdaptive_NoMentionQueryWithoutUser(t *testing.T) {
	s := &pagedSearch{pages: 1}
	mux := http.NewServeMux()
	mux.HandleFunc("/team.info", func(w http.ResponseWriter, _ *http.Request) {
		jsonOK(w, map[string]any{"ok": true, "team": map[string]any{"id": "T001", "name": "test", "domain": "test"}})
	})
	mux.HandleFunc("/auth.test", func(w http.ResponseWriter, _ *http.Request) {
		jsonOK(w, map[string]any{"ok": false, "error": "internal_error"})
	})
	for _, method := range []string{"/emoji.list", "/users.list", "/conversations.info"} {
		mux.HandleFunc(method, func(w http.ResponseWriter, _ *http.Request) {
			jsonOK(w, map[string]any{"ok": true, "emoji": map[string]string{}, "members": []any{},
				"channel": map[string]any{"id": "C001", "last_read": ""}, "response_metadata": map[string]any{"next_cursor": ""}})
		})
	}
	mux.HandleFunc("/users.info", func(w http.ResponseWriter, _ *http.Request) {
		jsonOK(w, map[string]any{"ok": false, "error": "user_not_found"})
	})
	mux.HandleFunc("/search.messages", s.handle)
	ts := newTestSetup(t, mux)
	require.NoError(t, ts.db.UpsertWorkspace(db.Workspace{ID: "T001", Name: "test", Domain: "test"}))
	require.NoError(t, ts.db.SetSlackAccountSearchWatermark(ts.accountID, "2026-09-20"))
	ts.orch.now = func() time.Time { return resumeNow }
	ts.orch.outcome.RateLimited = true // behind: only the missing user skips the mention query

	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	s.mu.Lock()
	defer s.mu.Unlock()
	assert.Equal(t, []string{resumeQuery + "#1"}, s.requests, "no user, no mention query")
}

func TestRunFetchDeadline_SearchRunsOnly(t *testing.T) {
	assert.Equal(t, slackFetchDeadline, runFetchDeadline(SyncOptions{}))
	assert.Equal(t, slackFetchDeadline, runFetchDeadline(SyncOptions{Workers: 4, SkipDMs: true}))
	assert.Zero(t, runFetchDeadline(SyncOptions{Full: true}), "a full sync keeps the plain retry cap")
	assert.Zero(t, runFetchDeadline(SyncOptions{Channels: []string{"general"}}))
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

// TestSearchResume_MovingWindowKeptAcrossMidnight: a window computed from
// now (a first sync, a clamped catch-up) keeps its after: date while a
// resume is pending, so the next day's run continues the same window and a
// first sync still reports itself.
func TestSearchResume_MovingWindowKeptAcrossMidnight(t *testing.T) {
	for name, watermark := range map[string]string{
		"first sync": "",
		"clamped":    resumeNow.AddDate(0, 0, -45).Format(searchDateFormat),
	} {
		t.Run(name, func(t *testing.T) {
			ts, s := newResumeSetup(t, 6, 4)
			require.NoError(t, ts.db.SetSlackAccountSearchWatermark(ts.accountID, watermark))
			require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
			run1 := s.blanket()
			require.Len(t, run1, 4)
			query := strings.TrimSuffix(run1[0], "#1")

			ts.orch.now = func() time.Time { return resumeNow.AddDate(0, 0, 1) }
			ts.freshClient()
			s.reset(0)
			require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
			var window []string // the sweep's after:/before: queries follow a finished window
			for _, r := range s.blanket() {
				if !strings.Contains(r, "before:") {
					window = append(window, r)
				}
			}
			assert.Equal(t, pageRequests(query, 3, 4, 5, 6), window, "the next day continues the same window")
			if watermark == "" {
				_, ok := ts.orch.FirstSyncFrom()
				assert.True(t, ok, "the first sync survives midnight")
			}
		})
	}
}

// TestAdaptive_MentionQueryErrorDoesNotFallBack: the mention query's page 1
// failing for a reason other than a rate limit is logged and the blanket
// query runs; no full sync (the mux cannot serve one, so it would fail Run).
func TestAdaptive_MentionQueryErrorDoesNotFallBack(t *testing.T) {
	ts, s := newResumeSetup(t, 3, 0)
	s.mentionErr = true
	ts.orch.outcome.RateLimited = true // behind, so the mention query runs
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	assert.Equal(t, pageRequests(resumeQuery, 1, 2, 3), s.blanket())
	assert.False(t, ts.orch.SearchIncomplete())
}

// TestSearchResume_ResumedFirstPageErrorStops: a resumed pass whose first
// page fails for a reason other than a rate limit keeps what earlier runs
// fetched and stops; only page 1 falls back to the full sync.
func TestSearchResume_ResumedFirstPageErrorStops(t *testing.T) {
	ts, s := newResumeSetup(t, 6, 4)
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))

	ts.freshClient()
	s.reset(0)
	s.mu.Lock()
	s.errPage = 3
	s.mu.Unlock()
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}), "no full-sync fallback")
	assert.Equal(t, pageRequests(resumeQuery, 3), s.blanket())
	assert.True(t, ts.orch.SearchIncomplete())
	assert.True(t, ts.orch.RunOutcome().ResumePending)

	ts.freshClient()
	s.reset(0)
	s.mu.Lock()
	s.errPage = 0
	s.mu.Unlock()
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	assert.Equal(t, pageRequests(resumeQuery, 3, 4, 5, 6), s.blanket(), "the position survived")
}

// TestSearchSync_UnrelatedHoldDoesNotEndTheCycle: only a stop on the fetch
// deadline ends the cycle. A later page failing for another reason while
// some other call left a hold keeps the cycle going (finishSync runs, no
// rate-limit note).
func TestSearchSync_UnrelatedHoldDoesNotEndTheCycle(t *testing.T) {
	s := &pagedSearch{pages: 3, errPage: 2}
	inner := searchAuditMux(s.handle)
	var armed atomic.Bool
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/emoji.list" && armed.Load() {
			w.Header().Set("Retry-After", "3600")
			w.WriteHeader(http.StatusTooManyRequests)
			return
		}
		inner.ServeHTTP(w, r)
	})
	ts := newTestSetup(t, mux)
	require.NoError(t, ts.db.UpsertWorkspace(db.Workspace{ID: "T001", Name: "test", Domain: "test"}))
	require.NoError(t, ts.db.SetSlackAccountSearchWatermark(ts.accountID, "2026-09-20"))
	require.NoError(t, ts.db.SetSlackRosterSyncedAt(ts.accountID, resumeNow))
	ts.orch.now = func() time.Time { return resumeNow }
	ts.orch.readStateSyncedAt = resumeNow
	s.onPage = func(page int) {
		if page != 2 {
			return
		}
		// Another call on the client meets an hour-long 429 just before
		// page 2 fails: the hold is active when the pass stops.
		armed.Store(true)
		_, _ = ts.orch.slackClient.GetEmoji(context.Background())
	}

	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	require.False(t, ts.orch.slackClient.HoldUntil().IsZero(), "the unrelated hold is active")
	assert.False(t, ts.orch.searchRateLimited, "the cycle was not ended")
	acct, err := ts.db.GetSlackAccount(ts.accountID)
	require.NoError(t, err)
	assert.NotContains(t, acct.Error, "rate-limited")
	assert.True(t, ts.orch.SearchIncomplete())
}

// RunOutcome.RateLimited counts only the run's own 429s: one another caller
// of the same client meets while the run is going (the chat, a media fetch)
// does not back the account's cadence off.
func TestRunOutcome_ConcurrentCallers429IsNotTheRuns(t *testing.T) {
	var queries []string
	var mu gosync.Mutex
	var orch atomic.Pointer[Orchestrator]
	var once gosync.Once
	search := oneMatchSearch(&queries, &mu)
	mux := searchAuditMux(func(w http.ResponseWriter, r *http.Request) {
		once.Do(func() { // the chat opens a DM mid-run and is rate-limited
			_, err := orch.Load().slackClient.OpenDM(context.Background(), "U0OTHER")
			require.Error(t, err)
		})
		search(w, r)
	})
	mux.HandleFunc("/conversations.open", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Retry-After", "0")
		w.WriteHeader(http.StatusTooManyRequests)
	})
	ts := newTestSetup(t, mux)
	orch.Store(ts.orch)

	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	require.NotZero(t, ts.orch.slackClient.RateLimitedCalls(), "the other caller met its 429")
	assert.False(t, ts.orch.RunOutcome().RateLimited)
}

// m2: a window that resumes across cycles the cadence skips (no sync error,
// so the Inbox watermark moves on meanwhile) and finishes more than 24 h
// after it began still stamps what it stores for the first time with the
// current time: the lookback counts from the run that began the window. A
// late mention on its last page is detected exactly once, and the search
// watermark waits for that page.
func TestSearchResume_LateWindowStillDetected(t *testing.T) {
	ts, s := newResumeSetup(t, 6, 4)
	now := resumeNow
	ts.orch.now = func() time.Time { return now }
	require.NoError(t, ts.db.SetSlackFirstCycleAtOnce(ts.accountID, resumeNow.AddDate(0, 0, -30)))
	mention := func(at time.Time) map[string]any {
		return map[string]any{"user": "U002", "username": "bob", "ts": slackTS(at), "text": "<@U001> ping",
			"channel": map[string]any{"id": "C001", "name": "general"}}
	}
	early, late := resumeNow.Add(-2*time.Hour), resumeNow.Add(-time.Hour)
	s.extra = map[int][]map[string]any{1: {mention(early)}, 6: {mention(late)}}
	watermark := func() string {
		wm, err := ts.db.GetSlackAccountSearchWatermark(ts.accountID)
		require.NoError(t, err)
		return wm
	}

	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	require.True(t, ts.orch.RunOutcome().ResumePending, "run 1 stops on page 4")

	now = resumeNow.Add(30 * time.Minute)
	ts.freshClient()
	s.reset(5)
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	require.True(t, ts.orch.RunOutcome().ResumePending, "run 2 stops on page 5")
	assert.Equal(t, "2026-09-20", watermark(), "the watermark waits for the last page")

	// The cadence skips cycles meanwhile; the Inbox watermark moves on.
	inboxWatermark := resumeNow.Add(25 * time.Hour)
	now = resumeNow.Add(26 * time.Hour)
	ts.freshClient()
	s.reset(0)
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	require.False(t, ts.orch.RunOutcome().ResumePending, "run 3 finishes the window")
	assert.NotEqual(t, "2026-09-20", watermark(), "the finished window moves the watermark")

	assert.Equal(t, []string{slackTS(late)}, detectedMentions(t, ts, inboxWatermark),
		"the late mention is detected; the one run 1 stored is not again")
	assert.Equal(t, float64(now.Unix()), storedSyncedAt(t, ts, slackTS(late)))

	// A later run re-reading the same messages moves nothing.
	now = now.Add(time.Hour)
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	assert.Empty(t, detectedMentions(t, ts, resumeNow.Add(26*time.Hour)), "detected exactly once")
}
