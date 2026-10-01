package extsync

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// An item the reconcile deleted (a view restriction) that comes back
// without a new version — the restriction lifted a week later — is never
// listed by Changed again; the next reconcile fetches it back, with its
// comments and attachments.
func TestReconcileRefetchesAnItemThatComesBack(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	now := time.Now().UTC().Truncate(time.Second).Add(-30 * 24 * time.Hour)
	old := now.Add(-time.Hour)
	f.addPage("p1", 1, old)
	f.addPage("p2", 1, old)
	f.addComment("c2", "p2", 1, old, "on p2")
	f.addAttachment("a2", "p2", 1, old, "notes.txt", "text/plain", []byte("x"), -1)
	e := New(d, Options{Now: func() time.Time { return now }, Extractor: newFakeExtractor()})
	e.SetFetcher(src.JiraAccountID, f)
	_, err := e.Run(context.Background())
	require.NoError(t, err)
	require.Equal(t, []string{"a2", "p1", "p2"}, docIDs(t, d, src.ID))

	for _, id := range []string{"p2", "c2", "a2"} {
		f.removeFromAll(id)
	}
	now = now.Add(24 * time.Hour)
	_, err = e.Run(context.Background())
	require.NoError(t, err)
	require.Equal(t, []string{"p1"}, docIDs(t, d, src.ID))
	require.Empty(t, commentTexts(t, d, src.ID, "p2"))

	for _, id := range []string{"p2", "c2", "a2"} {
		f.restoreToAll(id)
	}
	now = now.Add(7 * 24 * time.Hour)
	st, err := e.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, []string{"a2", "p1", "p2"}, docIDs(t, d, src.ID), "the reconcile fetched the restored items back")
	assert.Equal(t, []string{"on p2"}, commentTexts(t, d, src.ID, "p2"))
	row, ok := loadAttachment(t, d, src.ID, "a2")
	require.True(t, ok)
	assert.Equal(t, []Section{{Text: "text of notes.txt"}}, row.sections)
	assert.Equal(t, 2, st.Fetched)
	assert.Equal(t, formatTime(now), loadSource(t, d).LastReconcileAt)

	now = now.Add(24 * time.Hour)
	_, err = e.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 2, f.fetchCount("p2"), "a recovered item is not fetched again")
	assert.Equal(t, 2, f.downloadCount("a2"))
}

// A version the delta never lists (its modification time is outside every
// pass, like an edit to an archived page) is fetched by the reconcile.
func TestReconcileRefetchesAVersionMismatch(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	now := time.Now().UTC().Truncate(time.Second).Add(-30 * 24 * time.Hour)
	f.addPage("p1", 1, now.Add(-time.Hour))
	f.addComment("c1", "p1", 1, now.Add(-time.Hour), "first")
	e := New(d, Options{Now: func() time.Time { return now }})
	e.SetFetcher(src.JiraAccountID, f)
	_, err := e.Run(context.Background())
	require.NoError(t, err)

	f.mutate("p1", 2, now.Add(-2*time.Hour))
	f.mutate("c1", 2, now.Add(-2*time.Hour))
	f.mu.Lock()
	f.find("c1").item.Sections = []Section{{Text: "edited"}}
	f.mu.Unlock()
	now = now.Add(24 * time.Hour)
	_, err = e.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 2, f.fetchCount("p1"))
	var version int
	require.NoError(t, d.QueryRow(`SELECT version FROM ext_documents WHERE source_id = ? AND ext_id = 'p1'`, src.ID).Scan(&version))
	assert.Equal(t, 2, version)
	assert.Equal(t, []string{"edited"}, commentTexts(t, d, src.ID, "p1"))
}

// A comment the listing holds but the store lacks (on a stored page) gets
// its page's comment set reloaded; the page itself is not re-fetched.
func TestReconcileReloadsCommentSetOfMissingComment(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	now := time.Now().UTC().Truncate(time.Second).Add(-30 * 24 * time.Hour)
	f.addPage("p1", 1, now.Add(-time.Hour))
	f.addComment("c1", "p1", 1, now.Add(-time.Hour), "first")
	f.removeFromAll("c1")
	f.mu.Lock()
	f.find("c1").item = nil // not served yet: the page's first load has no comment
	f.mu.Unlock()
	e := New(d, Options{Now: func() time.Time { return now }})
	e.SetFetcher(src.JiraAccountID, f)
	_, err := e.Run(context.Background())
	require.NoError(t, err)
	require.Empty(t, commentTexts(t, d, src.ID, "p1"))

	f.mu.Lock()
	ref := f.find("c1").ref
	f.find("c1").item = &Item{Ref: ref, CommentKind: "footer", Sections: []Section{{Text: "back"}}}
	f.mu.Unlock()
	f.restoreToAll("c1")
	now = now.Add(24 * time.Hour)
	_, err = e.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, []string{"back"}, commentTexts(t, d, src.ID, "p1"))
	assert.Equal(t, 1, f.fetchCount("p1"))
}

// A recovery the budget cuts leaves the reconcile unstamped; the next
// cycle resumes it without re-fetching what was written, then stamps it.
func TestReconcileRecoveryResumesAfterBudgetCut(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	start := time.Now().UTC().Truncate(time.Second).Add(-30 * 24 * time.Hour)
	ids := []string{"p1", "p2", "p3", "p4"}
	for _, id := range ids {
		f.addPage(id, 1, start.Add(-48*time.Hour))
	}
	// The streams list nothing (every cursor is past the pages' modification
	// time), so only the reconcile's recovery can bring them in.
	_, err := d.Exec(`UPDATE ext_sources SET page_cursor = ?, comment_cursor = ?, attachment_cursor = ? WHERE id = ?`,
		formatTime(start), formatTime(start), formatTime(start), src.ID)
	require.NoError(t, err)
	prev := recoverBatchSize
	recoverBatchSize = 1
	t.Cleanup(func() { recoverBatchSize = prev })
	clock := &manualClock{t: start}
	f.onFetch = func() { clock.advance(time.Minute) } // every Fetch spends the whole budget
	e := New(d, Options{Budget: time.Minute, Now: clock.Now})
	e.SetFetcher(src.JiraAccountID, f)

	st, err := e.Run(context.Background())
	require.NoError(t, err)
	assert.True(t, st.Incomplete)
	assert.Equal(t, []string{"p1"}, docIDs(t, d, src.ID), "the first chunk runs even past the budget")
	assert.Empty(t, loadSource(t, d).LastReconcileAt, "a cut recovery is not a reconcile")

	for range 3 {
		_, err = e.Run(context.Background())
		require.NoError(t, err)
	}
	assert.Equal(t, ids, docIDs(t, d, src.ID))
	assert.Equal(t, formatTime(clock.Now()), loadSource(t, d).LastReconcileAt)
	for _, id := range ids {
		assert.Equal(t, 1, f.fetchCount(id), "%s fetched once", id)
	}
}

// listedStale honours the pending version for attachments only.
func TestListedStale(t *testing.T) {
	listed := map[string]ItemRef{
		"same":    {ExtID: "same", Version: 2},
		"other":   {ExtID: "other", Version: 3},
		"pending": {ExtID: "pending", Version: 4},
		"missing": {ExtID: "missing", Version: 1},
	}
	local := map[string]attachmentVersion{
		"same": {stored: 2}, "other": {stored: 2}, "pending": {stored: 3, pending: 4},
	}
	ids := func(refs []ItemRef) []string {
		var out []string
		for _, r := range refs {
			out = append(out, r.ExtID)
		}
		return out
	}
	assert.Equal(t, []string{"missing", "other", "pending"}, ids(listedStale(listed, local, false)))
	assert.Equal(t, []string{"missing", "other"}, ids(listedStale(listed, local, true)))
}
