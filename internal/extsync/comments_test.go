package extsync

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// commentTexts returns the stored comment bodies of pageID, ordered by id.
func commentTexts(t *testing.T, d *db.DB, sourceID int64, pageID string) []string {
	t.Helper()
	rows, err := d.Query(`SELECT body_text FROM ext_comments WHERE source_id = ? AND page_ext_id = ? ORDER BY ext_id`,
		sourceID, pageID)
	require.NoError(t, err)
	defer rows.Close()
	var out []string
	for rows.Next() {
		var s string
		require.NoError(t, rows.Scan(&s))
		out = append(out, s)
	}
	require.NoError(t, rows.Err())
	return out
}

func childrenChangedAt(t *testing.T, d *db.DB, sourceID int64, extID string) string {
	t.Helper()
	var s string
	require.NoError(t, d.QueryRow(`SELECT children_changed_at FROM ext_documents WHERE source_id = ? AND ext_id = ?`,
		sourceID, extID).Scan(&s))
	return s
}

func TestNewCommentStampsParentAndReplacesSet(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	t0 := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	f.addPage("p1", 1, t0)
	f.addComment("c1", "p1", 1, t0, "first")
	clock := &stepClock{t: t0, step: time.Second}
	e := New(d, Options{Now: clock.Now})
	e.SetFetcher(src.JiraAccountID, f)
	_, _ = e.Run(context.Background())
	assert.Equal(t, []string{"first"}, commentTexts(t, d, src.ID, "p1"))
	before := childrenChangedAt(t, d, src.ID, "p1")

	f.addComment("c2", "p1", 1, t0.Add(time.Hour), "second")
	_, err := e.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, []string{"first", "second"}, commentTexts(t, d, src.ID, "p1"))
	assert.NotEqual(t, before, childrenChangedAt(t, d, src.ID, "p1"))
	assert.Equal(t, 1, f.fetches["p1"], "a new comment does not re-fetch the page")
}

// A page re-fetch reloads its whole comment set: a comment deleted remotely
// leaves with the next page version.
func TestPageRefetchReplacesCommentSet(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	t0 := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	f.addPage("p1", 1, t0)
	f.addComment("c1", "p1", 1, t0, "first")
	e := New(d, Options{})
	e.SetFetcher(src.JiraAccountID, f)
	_, err := e.Run(context.Background())
	require.NoError(t, err)

	f.mu.Lock()
	f.docs[KindComment] = nil // c1 deleted remotely: never listed again
	f.mu.Unlock()
	f.mutate("p1", 2, t0.Add(time.Hour))
	_, err = e.Run(context.Background())
	require.NoError(t, err)
	assert.Empty(t, commentTexts(t, d, src.ID, "p1"))
}

// Re-listing an unchanged comment in the cursor overlap does not reload or
// re-stamp its page.
func TestUnchangedCommentIsNotReloaded(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	t0 := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	f.addPage("p1", 1, t0)
	f.addComment("c1", "p1", 1, t0, "first")
	clock := &stepClock{t: t0, step: time.Second}
	e := New(d, Options{Now: clock.Now})
	e.SetFetcher(src.JiraAccountID, f)
	_, err := e.Run(context.Background())
	require.NoError(t, err)
	stamp := childrenChangedAt(t, d, src.ID, "p1")

	_, err = e.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, stamp, childrenChangedAt(t, d, src.ID, "p1"))
}

// A comment whose page is not stored locally is skipped; the pages stream
// brings the page with its comments.
func TestCommentOfUnknownParentIsSkipped(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	t0 := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	f.addComment("c1", "elsewhere", 1, t0, "orphan")
	e := New(d, Options{})
	e.SetFetcher(src.JiraAccountID, f)
	_, err := e.Run(context.Background())
	require.NoError(t, err)
	assert.Empty(t, commentTexts(t, d, src.ID, "elsewhere"))
	assert.Equal(t, "2026-09-01T10:00:00Z", loadSource(t, d).CommentCursor, "the cursor still advances")
}
