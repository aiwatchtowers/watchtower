package extsync

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestPagesBackfillThenVersionGate(t *testing.T) {
	d, src := newSourceDB(t) // helper: db + jira account + ext source "ENG"
	f := newFake()
	t0 := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	f.addPage("p1", 1, t0)
	f.addPage("p2", 1, t0.Add(time.Hour))
	f.addBlog("b1", 1, t0.Add(2*time.Hour))
	e := New(d, Options{})
	e.SetFetcher(src.JiraAccountID, f)

	_, err := e.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 3, countDocs(t, d, src.ID))
	assert.Equal(t, map[string]int{"p1": 1, "p2": 1, "b1": 1}, f.fetches)

	_, err = e.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, map[string]int{"p1": 1, "p2": 1, "b1": 1}, f.fetches, "unchanged versions are never re-fetched")
}

func TestSameMinuteEditsAreNotMissed(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	t0 := time.Date(2026, 9, 1, 10, 0, 30, 0, time.UTC)
	f.addPage("p1", 1, t0)
	e := New(d, Options{})
	e.SetFetcher(src.JiraAccountID, f)
	_, _ = e.Run(context.Background())

	f.addPage("p2", 1, t0.Add(-20*time.Second)) // same minute, earlier second than the cursor
	f.mutate("p1", 2, t0)                       // same timestamp, new version
	_, err := e.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, f.fetches["p2"])
	assert.Equal(t, 2, f.fetches["p1"])
}

func TestBudgetCutResumesFromPageToken(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	f.pageSize = 2
	base := time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC)
	for i := 0; i < 7; i++ {
		f.addPage(fmt.Sprintf("p%d", i), 1, base.Add(time.Duration(i)*time.Hour))
	}
	clock := &stepClock{t: base, step: time.Minute} // each Now() call advances one minute
	e := New(d, Options{Budget: 90 * time.Second, Now: clock.Now})
	e.SetFetcher(src.JiraAccountID, f)

	st, err := e.Run(context.Background())
	require.NoError(t, err)
	assert.True(t, st.Incomplete)
	first := countDocs(t, d, src.ID)
	assert.Less(t, first, 7)

	// The cut persisted the in-flight token; the backfill is not done yet.
	cut := loadSource(t, d)
	require.NotEmpty(t, cut.PageToken, "the cut must persist the in-flight token")
	assert.False(t, cut.BackfillDone)
	anchor, page, ok := decodeToken(cut.PageToken)
	require.True(t, ok)
	assert.True(t, anchor.IsZero(), "the backfill pass is anchored at the zero time")

	// The next cycle resumes with exactly the saved token and the original since.
	f.resetCalls()
	_, err = e.Run(context.Background())
	require.NoError(t, err)
	calls := f.changedCalls()
	require.NotEmpty(t, calls)
	assert.Equal(t, changedCall{since: anchor, page: page}, calls[0])

	for i := 0; i < 10 && countDocs(t, d, src.ID) < 7; i++ {
		_, err = e.Run(context.Background())
		require.NoError(t, err)
	}
	assert.Equal(t, 7, countDocs(t, d, src.ID))
	for id, n := range f.fetches {
		assert.Equal(t, 1, n, "%s fetched once across resumed cycles", id)
	}
	assert.True(t, loadSource(t, d).BackfillDone)
}

// A backfill of three items at pageSize 2 is exactly two Changed calls: the
// fresh pass ends the stream, no extra pass follows.
func TestBackfillMakesOnePass(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	t0 := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	for i := 0; i < 3; i++ {
		f.addPage(fmt.Sprintf("p%d", i), 1, t0.Add(time.Duration(i)*time.Hour))
	}
	e := New(d, Options{})
	e.SetFetcher(src.JiraAccountID, f)

	_, err := e.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, []changedCall{{page: ""}, {page: "2"}}, f.changedCalls())
}

// More than one page of items inside the overlap window must not loop: a
// fresh pass pages through them once and stops.
func TestOverlapWindowSpanningPagesTerminates(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	t0 := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	for i := 0; i < 5; i++ { // five items within one minute, pageSize 2
		f.addPage(fmt.Sprintf("p%d", i), 1, t0.Add(time.Duration(i)*time.Second))
	}
	e := New(d, Options{})
	e.SetFetcher(src.JiraAccountID, f)

	_, err := e.Run(context.Background()) // backfill: "", "2", "4"
	require.NoError(t, err)
	assert.Len(t, f.changedCalls(), 3)

	f.resetCalls()
	st, err := e.Run(context.Background()) // fresh pass over the overlap window
	require.NoError(t, err)
	since := t0.Add(4*time.Second - cursorOverlap)
	assert.Equal(t, []changedCall{{since, ""}, {since, "2"}, {since, "4"}}, f.changedCalls())
	assert.Equal(t, 5, st.Unchanged)
	assert.Equal(t, 5, countDocs(t, d, src.ID))
}

// A resumed pass that completes is followed by exactly one fresh pass from
// the advanced cursor, even when that fresh pass spans several pages.
func TestResumedPassThenOneFreshPass(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	t0 := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	for i := 0; i < 5; i++ {
		f.addPage(fmt.Sprintf("p%d", i), 1, t0.Add(time.Duration(i)*time.Second))
	}
	clock := &stepClock{t: t0, step: time.Minute}
	cutting := New(d, Options{Budget: 90 * time.Second, Now: clock.Now})
	cutting.SetFetcher(src.JiraAccountID, f)
	st, err := cutting.Run(context.Background())
	require.NoError(t, err)
	require.True(t, st.Incomplete)
	require.Equal(t, "|2", loadSource(t, d).PageToken)

	f.resetCalls()
	e := New(d, Options{}) // unbounded: the CLI path
	e.SetFetcher(src.JiraAccountID, f)
	_, err = e.Run(context.Background())
	require.NoError(t, err)
	since := t0.Add(4*time.Second - cursorOverlap)
	assert.Equal(t, []changedCall{
		{time.Time{}, "2"}, {time.Time{}, "4"}, // resumed pass completes
		{since, ""}, {since, "2"}, {since, "4"}, // one fresh pass, then stop
	}, f.changedCalls())
	assert.Equal(t, 5, countDocs(t, d, src.ID))
	for id, n := range f.fetches {
		assert.Equal(t, 1, n, "%s fetched once", id)
	}
	final := loadSource(t, d)
	assert.Empty(t, final.PageToken)
	assert.True(t, final.BackfillDone)
}

// A malformed stored cursor fails the stream, on the resumed path too,
// rather than being silently reset.
func TestMalformedCursorFails(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	f.addPage("p1", 1, time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC))
	e := New(d, Options{})
	e.SetFetcher(src.JiraAccountID, f)

	for _, token := range []string{"", "|2"} { // fresh, resumed
		_, err := d.Exec(`UPDATE ext_sources SET page_cursor = 'garbage', page_token = ? WHERE id = ?`, token, src.ID)
		require.NoError(t, err)
		_, err = e.Run(context.Background())
		require.Error(t, err, "token %q", token)
		assert.Contains(t, err.Error(), "bad cursor")
		assert.Equal(t, "garbage", loadSource(t, d).PageCursor)
	}
}

func TestTokenEncoding(t *testing.T) {
	anchor := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	cases := []struct {
		token      string
		wantAnchor time.Time
		wantPage   string
		wantOK     bool
	}{
		{"", time.Time{}, "", false},
		{"legacy-token", time.Time{}, "", false}, // no separator
		{"|", time.Time{}, "", false},            // no provider token
		{"|3", time.Time{}, "3", true},
		{"not-a-time|3", time.Time{}, "", false},
		{"2026-09-01T10:00:00Z|a|b", anchor, "a|b", true}, // provider token containing the separator
	}
	for _, c := range cases {
		gotAnchor, gotPage, gotOK := decodeToken(c.token)
		assert.Equal(t, c.wantOK, gotOK, c.token)
		assert.True(t, c.wantAnchor.Equal(gotAnchor), c.token)
		assert.Equal(t, c.wantPage, gotPage, c.token)
	}

	gotAnchor, gotPage, ok := decodeToken(encodeToken(anchor, "cursor=a|b"))
	assert.True(t, ok)
	assert.True(t, anchor.Equal(gotAnchor))
	assert.Equal(t, "cursor=a|b", gotPage)
	assert.Equal(t, "|7", encodeToken(time.Time{}, "7"))
}

// An item whose ExtID does not match the ref it was fetched for is rejected.
func TestWriteItemsRejectsMismatchedItem(t *testing.T) {
	d, src := newSourceDB(t)
	refs := []ItemRef{{Kind: KindPage, ExtID: "p1", Version: 1}}
	items := []*Item{{Ref: ItemRef{Kind: KindPage, ExtID: "p2", Version: 1}}}
	var st Stats
	err := writeItems(context.Background(), d, src.ID, refs, items, time.Now(), &st)
	require.Error(t, err)
	assert.Zero(t, countDocs(t, d, src.ID))
}

func TestGoneItemIsDeleted(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	t0 := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	f.addPage("p1", 1, t0)
	e := New(d, Options{})
	e.SetFetcher(src.JiraAccountID, f)
	_, _ = e.Run(context.Background())
	f.markGone("p1", 2, t0.Add(time.Hour)) // Changed lists it, Fetch returns nil
	_, err := e.Run(context.Background())
	require.NoError(t, err)
	assert.Zero(t, countDocs(t, d, src.ID))
}

// The stored row carries the item's fields, sections and meta as JSON, and
// the source's cursor/token/backfill state reflects the completed pass.
func TestUpsertWritesRowAndStreamState(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	t0 := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	f.addBlog("b1", 3, t0)
	now := time.Date(2026, 9, 26, 12, 0, 0, 0, time.UTC)
	e := New(d, Options{Now: func() time.Time { return now }})
	e.SetFetcher(src.JiraAccountID, f)

	st, err := e.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, Stats{Fetched: 1}, st)

	var kind, title, status, modified, sectionsJSON, metaJSON, syncedAt string
	var version int
	require.NoError(t, d.QueryRow(`SELECT kind, title, status, version, modified_at, sections_json, meta_json, synced_at
		FROM ext_documents WHERE source_id = ? AND ext_id = 'b1'`, src.ID).
		Scan(&kind, &title, &status, &version, &modified, &sectionsJSON, &metaJSON, &syncedAt))
	assert.Equal(t, "blogpost", kind)
	assert.Equal(t, "Title b1", title)
	assert.Equal(t, 3, version)
	assert.Equal(t, "current", status)
	assert.Equal(t, "2026-09-01T10:00:00Z", modified)
	assert.Equal(t, "2026-09-26T12:00:00Z", syncedAt)
	var secs []Section
	require.NoError(t, json.Unmarshal([]byte(sectionsJSON), &secs))
	assert.Equal(t, []Section{{Heading: "H", Text: "body of b1"}}, secs)
	assert.JSONEq(t, `{"space":"ENG"}`, metaJSON)

	srcs, err := d.ListExtSources("confluence")
	require.NoError(t, err)
	assert.Equal(t, "2026-09-01T10:00:00Z", srcs[0].PageCursor)
	assert.Empty(t, srcs[0].PageToken)
	assert.True(t, srcs[0].BackfillDone)
}

// A disabled source, or one whose account has no fetcher, is skipped.
func TestRunSkipsDisabledAndUnwiredSources(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	f.addPage("p1", 1, time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC))

	e := New(d, Options{}) // no fetcher wired
	_, err := e.Run(context.Background())
	require.NoError(t, err)
	assert.Zero(t, countDocs(t, d, src.ID))

	_, err = d.Exec(`UPDATE ext_sources SET enabled = 0 WHERE id = ?`, src.ID)
	require.NoError(t, err)
	e.SetFetcher(src.JiraAccountID, f)
	_, err = e.Run(context.Background())
	require.NoError(t, err)
	assert.Zero(t, countDocs(t, d, src.ID))
	assert.Empty(t, f.fetches)
}
