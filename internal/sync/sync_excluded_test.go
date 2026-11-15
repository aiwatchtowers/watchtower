package sync

import (
	"context"
	"fmt"
	"io"
	"log"
	"net/http"
	"sort"
	"strconv"
	"strings"
	gosync "sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// exclNow is the clock of the exclusion tests (the forward search and the
// inbox stamps); the catch-up tests move it per run.
var exclNow = time.Date(2026, 11, 15, 12, 0, 0, 0, time.UTC)

// exclMatch is one search.messages match from channel ch.
func exclMatch(ch, name, ts, text string) map[string]any {
	return map[string]any{"user": "U002", "username": "bob", "ts": ts, "text": text,
		"channel": map[string]any{"id": ch, "name": name}}
}

// exclSearch answers search.messages by query: the mention query gets
// mention when set, else the forward matches that mention U001, a dated query (the sweep, a history
// backfill) dated, any other query (the blanket search) forward.
type exclSearch struct {
	mu        gosync.Mutex
	forward   []map[string]any
	dated     []map[string]any
	mention   []map[string]any
	onForward func()
	queries   []string
}

func (s *exclSearch) handle(w http.ResponseWriter, r *http.Request) {
	_ = r.ParseForm()
	query := r.FormValue("query")
	s.mu.Lock()
	s.queries = append(s.queries, query)
	var matches []map[string]any
	onForward := s.onForward
	switch {
	case strings.HasPrefix(query, "<@") && s.mention != nil:
		matches = s.mention
	case strings.HasPrefix(query, "<@"):
		for _, m := range s.forward {
			if strings.Contains(m["text"].(string), "<@U001>") {
				matches = append(matches, m)
			}
		}
	case strings.Contains(query, "before:"):
		matches = s.dated
	default:
		matches = s.forward
	}
	s.mu.Unlock()
	if onForward != nil && !strings.HasPrefix(query, "<@") && !strings.Contains(query, "before:") {
		onForward()
	}
	if matches == nil {
		matches = []map[string]any{}
	}
	jsonOK(w, map[string]any{"ok": true, "messages": map[string]any{
		"matches": matches,
		"paging":  map[string]any{"count": 100, "total": len(matches), "page": 1, "pages": 1},
		"total":   len(matches),
	}})
}

// exclHistory serves conversations.history of C0JUNK from a ts pool, newest
// first, exclusive of oldest/latest, up to limit per page, and logs every
// request. Request number limitAt (1-based, 0 = none) answers 429 with an
// hour's Retry-After, past any run's fetch deadline. Other channels get
// one message each ("<channel>-msg").
type exclHistory struct {
	mu       gosync.Mutex
	pool     []float64 // ascending unix ts of C0JUNK
	served   map[string]int
	requests []historyReq
	limitAt  int
	errCode  string      // C0JUNK requests answer ok:false with this code ("" = none)
	onJunk   func(n int) // called before the n-th C0JUNK request (1-based) is answered
	junkN    int
	calls    int
}

type historyReq struct{ channel, oldest, latest string }

func (h *exclHistory) handle(w http.ResponseWriter, r *http.Request) {
	_ = r.ParseForm()
	ch := r.FormValue("channel")
	oldest, _ := strconv.ParseFloat(r.FormValue("oldest"), 64)
	latest, _ := strconv.ParseFloat(r.FormValue("latest"), 64)
	limit, _ := strconv.Atoi(r.FormValue("limit"))
	h.mu.Lock()
	defer h.mu.Unlock()
	h.calls++
	h.requests = append(h.requests, historyReq{ch, r.FormValue("oldest"), r.FormValue("latest")})
	if h.limitAt > 0 && h.calls == h.limitAt {
		w.Header().Set("Retry-After", "3600")
		w.WriteHeader(http.StatusTooManyRequests)
		return
	}
	if ch == "C0JUNK" {
		h.junkN++
		if h.onJunk != nil {
			h.onJunk(h.junkN)
		}
		if h.errCode != "" {
			jsonOK(w, map[string]any{"ok": false, "error": h.errCode})
			return
		}
	}
	if ch != "C0JUNK" {
		jsonOK(w, map[string]any{"ok": true, "has_more": false, "messages": []map[string]any{
			{"type": "message", "user": "U002", "ts": dayTS(0, 10, 0), "text": ch + "-msg"},
		}})
		return
	}
	var page []map[string]any
	more := false
	for i := len(h.pool) - 1; i >= 0; i-- {
		v := h.pool[i]
		if v <= oldest || (latest > 0 && v >= latest) {
			continue
		}
		if len(page) == limit {
			more = true
			break
		}
		ts := formatSlackTS(v)
		h.served[ts]++
		text := "junk " + ts
		if i == 0 {
			text = "<@U001> an old mention"
		}
		page = append(page, map[string]any{"type": "message", "user": "U002", "ts": ts, "text": text})
	}
	if page == nil {
		page = []map[string]any{}
	}
	jsonOK(w, map[string]any{"ok": true, "has_more": more, "messages": page})
}

// junkRequests returns the C0JUNK history requests so far.
func (h *exclHistory) junkRequests() []historyReq {
	h.mu.Lock()
	defer h.mu.Unlock()
	var out []historyReq
	for _, r := range h.requests {
		if r.channel == "C0JUNK" {
			out = append(out, r)
		}
	}
	return out
}

type exclSetup struct {
	*testSetup
	search  *exclSearch
	history *exclHistory
	now     time.Time
}

func newExclSetup(t *testing.T) *exclSetup {
	t.Helper()
	e := &exclSetup{search: &exclSearch{}, history: &exclHistory{served: map[string]int{}}, now: exclNow}
	mux := searchAuditMux(e.search.handle)
	mux.HandleFunc("/conversations.history", e.history.handle)
	mux.HandleFunc("/conversations.replies", func(w http.ResponseWriter, _ *http.Request) {
		jsonOK(w, map[string]any{"ok": true, "has_more": false, "messages": []map[string]any{}})
	})
	mux.HandleFunc("/conversations.list", func(w http.ResponseWriter, _ *http.Request) {
		jsonOK(w, map[string]any{"ok": true, "response_metadata": map[string]any{"next_cursor": ""},
			"channels": []map[string]any{
				{"id": "C001", "name": "general", "is_channel": true, "is_member": true},
				{"id": "C0JUNK", "name": "junk", "is_channel": true, "is_member": true},
			}})
	})
	e.testSetup = newTestSetup(t, mux)
	e.orch.logger = log.New(io.Discard, "", 0)
	e.orch.now = func() time.Time { return e.now }
	require.NoError(t, e.db.SetSlackFirstCycleAtOnce(e.accountID, exclNow.AddDate(0, 0, -60)))
	require.NoError(t, e.db.SetSlackAccountSearchWatermark(e.accountID, "2026-11-14"))
	require.NoError(t, e.db.EnsureChannel(e.ns("C0JUNK"), "junk", "public", ""))
	require.NoError(t, e.db.EnsureChannel(e.ns("C001"), "general", "public", ""))
	return e
}

func (e *exclSetup) exclude(t *testing.T, excluded bool, at time.Time) {
	t.Helper()
	require.NoError(t, e.db.SetSyncExcluded(e.ns("C0JUNK"), excluded, at))
}

// stored lists the stored ts of a channel, oldest first.
func (e *exclSetup) stored(t *testing.T, raw string) []string {
	t.Helper()
	rows, err := e.db.Query(`SELECT ts FROM messages WHERE channel_id = ? ORDER BY ts`, e.ns(raw))
	require.NoError(t, err)
	defer rows.Close()
	var out []string
	for rows.Next() {
		var ts string
		require.NoError(t, rows.Scan(&ts))
		out = append(out, ts)
	}
	require.NoError(t, rows.Err())
	return out
}

func (e *exclSetup) deleted(t *testing.T, raw, ts string) bool {
	t.Helper()
	var d bool
	require.NoError(t, e.db.QueryRow(`SELECT is_deleted FROM messages WHERE channel_id = ? AND ts = ?`, e.ns(raw), ts).Scan(&d))
	return d
}

func (e *exclSetup) run(t *testing.T, opts SyncOptions) {
	t.Helper()
	require.NoError(t, e.orch.Run(context.Background(), opts))
}

// TestSYNCEX01_EveryPathHonoursExclusion guards SYNCEX-01: a channel with
// Stop syncing on gets no new message rows from any save path — the forward
// search, the mention query (except mentions of the user), resumed search
// pages, the deletion sweep, the history backfill, `sync --full`,
// `sync --channels` and a Sync again catch-up — while the same answer still
// stores another channel's message (the path ran).
func TestSYNCEX01_EveryPathHonoursExclusion(t *testing.T) {
	junkTS := slackTS(exclNow.Add(-time.Hour))
	okTS := slackTS(exclNow.Add(-50 * time.Minute))

	t.Run("forward search", func(t *testing.T) {
		e := newExclSetup(t)
		// Stored before Stop syncing, inside the live diff window: its
		// match is dropped, and the listing diff must not take it for gone.
		kept := slackTS(exclNow.Add(-4 * time.Hour))
		require.NoError(t, e.db.UpsertMessage(db.Message{ChannelID: e.ns("C0JUNK"), TS: kept, UserID: e.ns("U002"), Text: "before"}))
		e.exclude(t, true, exclNow.AddDate(0, 0, -5))
		e.search.forward = []map[string]any{
			exclMatch("C0JUNK", "junk", kept, "before"),
			exclMatch("C0JUNK", "junk", junkTS, "noise"),
			exclMatch("C001", "general", okTS, "kept"),
		}
		e.run(t, SyncOptions{})
		assert.Equal(t, []string{kept}, e.stored(t, "C0JUNK"), "only the row stored before")
		assert.False(t, e.deleted(t, "C0JUNK", kept), "a dropped match still counts as listed")
		assert.Equal(t, []string{okTS}, e.stored(t, "C001"))
	})

	t.Run("mention query", func(t *testing.T) {
		e := newExclSetup(t)
		e.exclude(t, true, exclNow.AddDate(0, 0, -5))
		e.orch.outcome.RateLimited = true // behind: the mention query runs first
		mention := slackTS(exclNow.Add(-time.Hour))
		plain := slackTS(exclNow.Add(-59 * time.Minute))
		okMention := slackTS(exclNow.Add(-58 * time.Minute))
		e.search.mention = []map[string]any{
			exclMatch("C0JUNK", "junk", mention, "<@U001> look"),
			exclMatch("C0JUNK", "junk", plain, "no mention in this text"),
			exclMatch("C001", "general", okMention, "<@U001> here too"),
		}
		e.run(t, SyncOptions{})
		require.True(t, strings.HasPrefix(e.search.queries[0], "<@U001>"), "the mention query ran first: %v", e.search.queries)
		assert.Equal(t, []string{mention}, e.stored(t, "C0JUNK"))
		assert.Equal(t, []string{okMention}, e.stored(t, "C001"))
	})

	t.Run("resumed search pages", func(t *testing.T) {
		ts, s := newResumeSetup(t, 4, 3) // run 1 reads pages 1-2, page 3 is rate-limited
		ts.orch.logger = log.New(io.Discard, "", 0)
		require.NoError(t, ts.db.EnsureChannel(ts.ns("C0JUNK"), "junk", "public", ""))
		require.NoError(t, ts.db.SetSyncExcluded(ts.ns("C0JUNK"), true, resumeNow.AddDate(0, 0, -5)))
		s.extra = map[int][]map[string]any{3: {exclMatch("C0JUNK", "junk", itemTS(30), "noise")}}
		require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
		require.Equal(t, pageRequests(resumeQuery, 1, 2, 3), s.blanket())

		ts.freshClient()
		s.reset(0)
		require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
		require.Equal(t, pageRequests(resumeQuery, 2, 3, 4), s.blanket(), "the run resumed")
		var junk, ok int
		require.NoError(t, ts.db.QueryRow(`SELECT COUNT(*) FROM messages WHERE channel_id = ?`, ts.ns("C0JUNK")).Scan(&junk))
		require.NoError(t, ts.db.QueryRow(`SELECT COUNT(*) FROM messages WHERE channel_id = ? AND ts = ?`, ts.ns("C001"), itemTS(3)).Scan(&ok))
		assert.Zero(t, junk)
		assert.Equal(t, 1, ok, "the resumed page's other match is stored")
	})

	t.Run("deletion sweep", func(t *testing.T) {
		e := newExclSetup(t)
		e.exclude(t, true, exclNow.AddDate(0, 0, -20))
		day := time.Date(2026, 11, 5, 10, 0, 0, 0, time.UTC)
		oldOK := slackTS(day)
		require.NoError(t, e.db.UpsertMessage(db.Message{ChannelID: e.ns("C001"), TS: oldOK, UserID: e.ns("U002"), Text: "old"}))
		newOK := slackTS(day.Add(time.Minute))
		keptJunk := slackTS(day.Add(3 * time.Minute))
		require.NoError(t, e.db.UpsertMessage(db.Message{ChannelID: e.ns("C0JUNK"), TS: keptJunk, UserID: e.ns("U002"), Text: "before"}))
		e.search.dated = []map[string]any{
			exclMatch("C0JUNK", "junk", keptJunk, "before"),
			exclMatch("C0JUNK", "junk", slackTS(day.Add(2*time.Minute)), "noise"),
			exclMatch("C001", "general", oldOK, "old"),
			exclMatch("C001", "general", newOK, "found by the sweep"),
		}
		e.run(t, SyncOptions{})
		require.NotEmpty(t, sweepQueries(e.search.queries), "the sweep ran")
		assert.Equal(t, []string{keptJunk}, e.stored(t, "C0JUNK"), "only the row stored before")
		assert.False(t, e.deleted(t, "C0JUNK", keptJunk), "a dropped match still counts as listed")
		assert.Equal(t, []string{oldOK, newOK}, e.stored(t, "C001"))
	})

	t.Run("history backfill", func(t *testing.T) {
		e := newExclSetup(t)
		e.exclude(t, true, exclNow.AddDate(0, 0, -40))
		day := time.Date(2026, 10, 2, 10, 0, 0, 0, time.UTC)
		e.search.dated = []map[string]any{
			exclMatch("C0JUNK", "junk", slackTS(day), "noise"),
			exclMatch("C001", "general", slackTS(day.Add(time.Minute)), "kept"),
		}
		_, err := e.orch.BackfillSearch(context.Background(), day.Add(-24*time.Hour), day.Add(24*time.Hour))
		require.NoError(t, err)
		assert.Empty(t, e.stored(t, "C0JUNK"))
		assert.Equal(t, []string{slackTS(day.Add(time.Minute))}, e.stored(t, "C001"))
	})

	t.Run("sync --full", func(t *testing.T) {
		e := newExclSetup(t)
		e.exclude(t, true, exclNow.AddDate(0, 0, -5))
		e.history.pool = []float64{float64(exclNow.Add(-time.Hour).Unix())}
		e.run(t, SyncOptions{Full: true})
		assert.Empty(t, e.history.junkRequests(), "an excluded channel is never queued")
		assert.Empty(t, e.stored(t, "C0JUNK"))
		assert.Len(t, e.stored(t, "C001"), 1)
	})

	t.Run("sync again catch-up", func(t *testing.T) {
		e := newExclSetup(t)
		e.seedCatchup(t)
		// Excluded with the bounds still set (no writer leaves this, but
		// PendingCatchups must hold on its own): no catch-up page.
		_, err := e.db.Exec(`UPDATE channel_settings SET sync_excluded = 1 WHERE channel_id = ?`, e.ns("C0JUNK"))
		require.NoError(t, err)
		from, to := e.catchupBounds(t)
		require.NotNil(t, from)
		require.NotNil(t, to)
		okTS := slackTS(e.now.Add(-30 * time.Minute))
		e.search.forward = []map[string]any{exclMatch("C001", "general", okTS, "kept")}
		e.run(t, SyncOptions{})
		assert.Empty(t, e.history.junkRequests(), "no catch-up of an excluded channel")
		assert.Empty(t, e.stored(t, "C0JUNK"))
		assert.Equal(t, []string{okTS}, e.stored(t, "C001"))
	})

	t.Run("sync --channels", func(t *testing.T) {
		e := newExclSetup(t)
		e.exclude(t, true, exclNow.AddDate(0, 0, -5))
		e.history.pool = []float64{float64(exclNow.Add(-time.Hour).Unix())}
		e.run(t, SyncOptions{Channels: []string{"junk", "general"}})
		assert.Empty(t, e.history.junkRequests(), "an excluded channel is never queued")
		assert.Empty(t, e.stored(t, "C0JUNK"))
		assert.Len(t, e.stored(t, "C001"), 1)
	})
}

// Review focus 4: a mention of the user in an excluded channel is stored and
// reaches the Inbox; an ordinary message of the channel is not stored.
func TestSyncExcluded_MentionStillStored(t *testing.T) {
	e := newExclSetup(t)
	e.exclude(t, true, exclNow.AddDate(0, 0, -5))
	mention := slackTS(exclNow.Add(-10 * time.Minute))
	plain := slackTS(exclNow.Add(-9 * time.Minute))
	e.search.forward = []map[string]any{
		exclMatch("C0JUNK", "junk", mention, "<@U001> can you look?"),
		exclMatch("C0JUNK", "junk", plain, "noise"),
	}
	e.run(t, SyncOptions{})

	assert.Equal(t, []string{mention}, e.stored(t, "C0JUNK"))
	assert.Equal(t, []string{mention}, detectedMentions(t, e.testSetup, exclNow.Add(-30*time.Minute)))
}

// Data stored before Stop syncing stays, untouched by later matches.
func TestSyncExcluded_StoredDataStays(t *testing.T) {
	e := newExclSetup(t)
	old := slackTS(exclNow.Add(-3 * time.Hour))
	require.NoError(t, e.db.UpsertMessage(db.Message{ChannelID: e.ns("C0JUNK"), TS: old, UserID: e.ns("U002"), Text: "before"}))
	e.exclude(t, true, exclNow.Add(-2*time.Hour))
	newer := slackTS(exclNow.Add(-time.Hour))
	e.search.forward = []map[string]any{
		exclMatch("C0JUNK", "junk", old, "edited after Stop syncing"),
		exclMatch("C0JUNK", "junk", newer, "noise"),
	}
	e.run(t, SyncOptions{})

	assert.Equal(t, []string{old}, e.stored(t, "C0JUNK"))
	var text string
	var deleted bool
	require.NoError(t, e.db.QueryRow(`SELECT text, is_deleted FROM messages WHERE channel_id = ? AND ts = ?`,
		e.ns("C0JUNK"), old).Scan(&text, &deleted))
	assert.Equal(t, "before", text)
	assert.False(t, deleted)
	cs, err := e.db.GetChannelSettings(e.ns("C0JUNK"))
	require.NoError(t, err)
	assert.True(t, cs.IsMutedForLLM, "Stop syncing mutes what is stored")
}

// A Sync again made while a run is in flight applies from the next run.
func TestSyncExcluded_IncludeResumes(t *testing.T) {
	e := newExclSetup(t)
	e.exclude(t, true, exclNow.Add(-2*time.Hour))
	msg := slackTS(exclNow.Add(-time.Hour))
	e.search.forward = []map[string]any{exclMatch("C0JUNK", "junk", msg, "noise")}
	var once gosync.Once
	e.search.onForward = func() { once.Do(func() { e.exclude(t, false, exclNow) }) }

	e.run(t, SyncOptions{})
	assert.Empty(t, e.stored(t, "C0JUNK"), "the run read the exclusion at its start")

	e.run(t, SyncOptions{})
	assert.Equal(t, []string{msg}, e.stored(t, "C0JUNK"))
}

// Catch-up fixture: excluded on day 1, included on day 10, 12 history pages
// of 999 messages in between.
var (
	catchDay1  = time.Date(2026, 11, 1, 9, 0, 0, 0, time.UTC)
	catchDay10 = time.Date(2026, 11, 10, 9, 0, 0, 0, time.UTC)
)

const catchPages = 12

func (e *exclSetup) seedCatchup(t *testing.T) {
	t.Helper()
	n := catchPages * slackPageSize
	e.history.pool = make([]float64, 0, n)
	for i := range n {
		e.history.pool = append(e.history.pool, float64(catchDay1.Unix()+30+int64(i)*60)+0.0001)
	}
	require.Less(t, e.history.pool[n-1], float64(catchDay10.Unix()))
	e.exclude(t, true, catchDay1)
	e.exclude(t, false, catchDay10)
	e.now = catchDay10.Add(time.Hour)
	require.NoError(t, e.db.SetSlackAccountSearchWatermark(e.accountID, "2026-11-09"))
}

// pageOldest is the oldest ts of catch-up page p (1-based) of the full pool.
func (e *exclSetup) pageOldest(p int) float64 {
	return e.history.pool[len(e.history.pool)-p*slackPageSize]
}

func (e *exclSetup) catchupBounds(t *testing.T) (from, to *float64) {
	t.Helper()
	cs, err := e.db.GetChannelSettings(e.ns("C0JUNK"))
	require.NoError(t, err)
	require.NotNil(t, cs)
	if cs.CatchupFrom.Valid {
		from = &cs.CatchupFrom.Float64
	}
	if cs.CatchupTo.Valid {
		to = &cs.CatchupTo.Float64
	}
	return from, to
}

// assertCaughtUp checks every pool message is stored, each served once,
// with its post time as synced_at, none detected by the Inbox, and the
// catch-up cleared.
func (e *exclSetup) assertCaughtUp(t *testing.T) {
	t.Helper()
	assert.Len(t, e.stored(t, "C0JUNK"), len(e.history.pool))
	for _, v := range e.history.pool {
		if n := e.history.served[formatSlackTS(v)]; n != 1 {
			t.Fatalf("ts %s served %d times", formatSlackTS(v), n)
		}
	}
	var stamped int
	require.NoError(t, e.db.QueryRow(`SELECT COUNT(*) FROM messages WHERE channel_id = ? AND synced_at != ts_unix`,
		e.ns("C0JUNK")).Scan(&stamped))
	assert.Zero(t, stamped, "catch-up rows keep their post time")
	assert.Empty(t, detectedMentions(t, e.testSetup, e.now.Add(-30*time.Minute)), "the old mention is not detected")
	from, to := e.catchupBounds(t)
	assert.Nil(t, from)
	assert.Nil(t, to)
}

// assertWalk checks the request chain: each latest is the previous page's
// oldest ts, every oldest the fixed lower bound.
func assertWalk(t *testing.T, reqs []historyReq, firstLatest float64, e *exclSetup, firstPage int) {
	t.Helper()
	latest := formatSlackTS(firstLatest)
	for i, r := range reqs {
		assert.Equal(t, formatSlackTS(float64(catchDay1.Unix())), r.oldest, "request %d oldest", i)
		assert.Equal(t, latest, r.latest, "request %d latest", i)
		latest = formatSlackTS(e.pageOldest(firstPage + i))
	}
}

func TestSyncAgain_CatchesUpExcludedPeriod(t *testing.T) {
	e := newExclSetup(t)
	e.seedCatchup(t)

	e.run(t, SyncOptions{})
	reqs := e.history.junkRequests()
	require.Len(t, reqs, syncAgainPagesPerRun)
	assertWalk(t, reqs, float64(catchDay10.Unix()), e, 1)
	_, to := e.catchupBounds(t)
	require.NotNil(t, to)
	assert.Equal(t, e.pageOldest(5), *to)

	e.run(t, SyncOptions{})
	require.Len(t, e.history.junkRequests(), 2*syncAgainPagesPerRun)
	_, to = e.catchupBounds(t)
	require.NotNil(t, to)
	assert.Equal(t, e.pageOldest(10), *to)

	e.run(t, SyncOptions{})
	reqs = e.history.junkRequests()
	require.Len(t, reqs, catchPages)
	assertWalk(t, reqs, float64(catchDay10.Unix()), e, 1)
	e.assertCaughtUp(t)

	e.run(t, SyncOptions{})
	assert.Len(t, e.history.junkRequests(), catchPages, "a finished catch-up fetches nothing more")
}

func TestSyncAgain_CatchupSurvivesRestart(t *testing.T) {
	e := newExclSetup(t)
	e.seedCatchup(t)
	e.run(t, SyncOptions{})
	require.Len(t, e.history.junkRequests(), syncAgainPagesPerRun)

	// A new orchestrator over the same database (a daemon restart).
	restarted := NewOrchestrator(e.db, e.orch.slackClient, e.orch.config, e.accountID)
	restarted.SetLogger(log.New(io.Discard, "", 0))
	restarted.now = func() time.Time { return e.now }
	e.orch = restarted
	e.run(t, SyncOptions{})
	reqs := e.history.junkRequests()
	require.Len(t, reqs, 2*syncAgainPagesPerRun)
	assert.Equal(t, formatSlackTS(e.pageOldest(5)), reqs[syncAgainPagesPerRun].latest, "continues at catchup_to")

	e.run(t, SyncOptions{})
	assertWalk(t, e.history.junkRequests(), float64(catchDay10.Unix()), e, 1)
	e.assertCaughtUp(t)
}

func TestSyncAgain_CatchupResumesAfter429(t *testing.T) {
	e := newExclSetup(t)
	e.seedCatchup(t)
	e.history.limitAt = 3
	e.run(t, SyncOptions{})
	require.Len(t, e.history.junkRequests(), 3)
	_, to := e.catchupBounds(t)
	require.NotNil(t, to)
	assert.Equal(t, e.pageOldest(2), *to, "the bound stays at the last saved page")

	e.freshClient() // without the hour-long hold
	for range 3 {
		e.run(t, SyncOptions{})
	}
	reqs := e.history.junkRequests()
	require.Len(t, reqs, catchPages+1)
	assert.Equal(t, reqs[2], reqs[3], "the page cut by the 429 is asked again")
	e.assertCaughtUp(t)
}

// Stop syncing during an unfinished catch-up, then Sync again: the next
// catch-up starts from the first one's start and covers everything once
// more where needed (overlap upserts), and a late advance changes nothing.
func TestSyncAgain_StopSyncingDuringCatchup(t *testing.T) {
	e := newExclSetup(t)
	e.seedCatchup(t)
	e.run(t, SyncOptions{})
	require.Len(t, e.history.junkRequests(), syncAgainPagesPerRun)

	walk, err := e.db.PendingCatchups(e.accountID)
	require.NoError(t, err)
	require.Len(t, walk, 1)
	day11 := catchDay10.AddDate(0, 0, 1)
	e.exclude(t, true, day11)
	from, to := e.catchupBounds(t)
	assert.Nil(t, from)
	assert.Nil(t, to)
	cs, err := e.db.GetChannelSettings(e.ns("C0JUNK"))
	require.NoError(t, err)
	assert.Equal(t, catchDay1.Format(time.RFC3339), cs.ExcludedAt)
	applied, err := e.db.AdvanceCatchup(walk[0], e.pageOldest(6))
	require.NoError(t, err)
	assert.False(t, applied)
	_, to = e.catchupBounds(t)
	assert.Nil(t, to, "a late advance changes nothing")

	// More messages arrive while it is excluded again (days 11–15).
	for i := range 50 {
		e.history.pool = append(e.history.pool, float64(day11.Unix()+30+int64(i)*3600)+0.0001)
	}
	sort.Float64s(e.history.pool)
	day15 := catchDay10.AddDate(0, 0, 5)
	e.exclude(t, false, day15)
	e.now = day15.Add(time.Hour)
	require.NoError(t, e.db.SetSlackAccountSearchWatermark(e.accountID, "2026-11-14"))
	from, to = e.catchupBounds(t)
	require.NotNil(t, from)
	require.NotNil(t, to)
	assert.Equal(t, float64(catchDay1.Unix()), *from)
	assert.Equal(t, float64(day15.Unix()), *to)

	for range 4 {
		e.run(t, SyncOptions{})
	}
	assert.Len(t, e.stored(t, "C0JUNK"), len(e.history.pool), "every message of days 1-15 stored once")
	from, to = e.catchupBounds(t)
	assert.Nil(t, from)
	assert.Nil(t, to)
	for _, v := range e.history.pool {
		require.Positive(t, e.history.served[formatSlackTS(v)], "ts %s fetched", formatSlackTS(v))
	}
}

// formatSlackTS round-trips a pool ts: the walk relies on it.
func TestFormatSlackTS(t *testing.T) {
	v := float64(catchDay1.Unix()) + 0.0001
	assert.Equal(t, fmt.Sprintf("%d.000100", catchDay1.Unix()), formatSlackTS(v))
}

// A Stop syncing while a catch-up walks ends the walk at its next advance
// (compare-and-set).
func TestSyncAgain_ReExcludedMidRunStops(t *testing.T) {
	e := newExclSetup(t)
	e.seedCatchup(t)
	e.history.onJunk = func(n int) {
		if n == 2 {
			require.NoError(t, e.db.SetSyncExcluded(e.ns("C0JUNK"), true, e.now))
		}
	}
	e.run(t, SyncOptions{})
	assert.Len(t, e.history.junkRequests(), 2, "the walk stopped at the advance that no longer applied")
	from, to := e.catchupBounds(t)
	assert.Nil(t, from)
	assert.Nil(t, to)
}

// Only a channel-specific error gives a catch-up up; an account-wide one
// keeps it pending.
func TestSyncAgain_GivesUpOnlyOnChannelErrors(t *testing.T) {
	for _, tc := range []struct {
		code    string
		pending bool
	}{
		{"channel_not_found", false},
		{"not_in_channel", false},
		{"missing_scope", true},
		{"access_denied", true},
		{"account_inactive", true},
		{"invalid_auth", true},
	} {
		t.Run(tc.code, func(t *testing.T) {
			e := newExclSetup(t)
			e.seedCatchup(t)
			e.history.errCode = tc.code
			_ = e.orch.Run(context.Background(), SyncOptions{})
			require.Len(t, e.history.junkRequests(), 1)
			from, to := e.catchupBounds(t)
			assert.Equal(t, tc.pending, from != nil, "catchup_from")
			assert.Equal(t, tc.pending, to != nil, "catchup_to")
		})
	}
}
