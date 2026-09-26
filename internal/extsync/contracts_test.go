package extsync

import (
	"context"
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/kb"
)

func countRows(t *testing.T, d *db.DB, query string, args ...any) int {
	t.Helper()
	var n int
	require.NoError(t, d.QueryRow(query, args...).Scan(&n), query)
	return n
}

// TestEXT02_UnselectLeavesNoRowsAndNoIndex — EXT-02 (selection is honest):
// a synced and indexed space, once unselected (DeleteExtSource, what
// `confluence unselect` and account removal do), leaves no ext_documents /
// ext_comments / ext_sources row, the engine never calls the fetcher for it
// again, and the next KB cycle leaves no kb_documents row with its prefix.
func TestEXT02_UnselectLeavesNoRowsAndNoIndex(t *testing.T) {
	ctx := context.Background()
	d, src := newSourceDB(t)
	f := newFake()
	t0 := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	f.addPage("p1", 1, t0)
	f.addBlog("b1", 1, t0.Add(time.Hour))
	f.addComment("c1", "p1", 1, t0.Add(2*time.Hour), "looks good")
	e := New(d, Options{})
	e.SetFetcher(src.JiraAccountID, f)

	_, err := e.Run(ctx)
	require.NoError(t, err)
	require.Equal(t, 2, countDocs(t, d, src.ID))
	require.Equal(t, 1, countRows(t, d, `SELECT COUNT(*) FROM ext_comments WHERE source_id = ?`, src.ID))
	_, err = kb.Run(ctx, d, kb.Options{Sources: []string{"confluence"}})
	require.NoError(t, err)
	prefix := "confluence:" + strconv.FormatInt(src.ID, 10) + ":%"
	require.Equal(t, 2, countRows(t, d, `SELECT COUNT(*) FROM kb_documents WHERE id LIKE ?`, prefix), "the space was indexed")

	require.NoError(t, d.DeleteExtSource(src.ID))
	assert.Zero(t, countRows(t, d, `SELECT COUNT(*) FROM ext_sources WHERE id = ?`, src.ID))
	assert.Zero(t, countDocs(t, d, src.ID))
	assert.Zero(t, countRows(t, d, `SELECT COUNT(*) FROM ext_comments WHERE source_id = ?`, src.ID))

	f.mu.Lock()
	callsBefore := f.netCalls
	f.mu.Unlock()
	_, err = e.Run(ctx)
	require.NoError(t, err)
	f.mu.Lock()
	assert.Equal(t, callsBefore, f.netCalls, "an unselected space is never fetched")
	f.mu.Unlock()

	_, err = kb.Run(ctx, d, kb.Options{Sources: []string{"confluence"}})
	require.NoError(t, err)
	assert.Zero(t, countRows(t, d, `SELECT COUNT(*) FROM kb_documents WHERE id LIKE ?`, prefix), "the next KB cycle drops the space")
	assert.Zero(t, countRows(t, d, `SELECT COUNT(*) FROM kb_chunks WHERE doc_id LIKE ?`, prefix))
}
