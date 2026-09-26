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

	for i := 0; i < 10 && countDocs(t, d, src.ID) < 7; i++ {
		_, err = e.Run(context.Background())
		require.NoError(t, err)
	}
	assert.Equal(t, 7, countDocs(t, d, src.ID))
	for id, n := range f.fetches {
		assert.Equal(t, 1, n, "%s fetched once across resumed cycles", id)
	}
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
