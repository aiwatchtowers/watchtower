package extsync

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// docIDs returns the stored document ids of sourceID, sorted.
func docIDs(t *testing.T, d *db.DB, sourceID int64) []string {
	t.Helper()
	rows, err := d.Query(`SELECT ext_id FROM ext_documents WHERE source_id = ? ORDER BY ext_id`, sourceID)
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

func TestReconcileDeletesMovedOrRestrictedPages(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	now := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	f.addPage("p1", 1, now.Add(-time.Hour))
	f.addPage("p2", 1, now.Add(-time.Hour))
	f.addBlog("b1", 1, now.Add(-time.Hour))
	f.addComment("c2", "p2", 1, now.Add(-time.Hour), "on p2")
	e := New(d, Options{Now: func() time.Time { return now }})
	e.SetFetcher(src.JiraAccountID, f)
	_, _ = e.Run(context.Background())
	require.Equal(t, []string{"on p2"}, commentTexts(t, d, src.ID, "p2"))
	f.removeFromAll("p2") // moved to another space / restricted: absent from All, never in Changed
	f.removeFromAll("b1")

	now = now.Add(24 * time.Hour)
	st, err := e.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, []string{"p1"}, docIDs(t, d, src.ID))
	assert.Empty(t, commentTexts(t, d, src.ID, "p2"), "a reconciled page takes its comments with it")
	assert.Equal(t, 2, st.Deleted)
	assert.Equal(t, "2026-09-02T10:00:00Z", loadSource(t, d).LastReconcileAt)
}

func TestReconcileRunsOncePerDay(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	now := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	e := New(d, Options{Now: func() time.Time { return now }})
	e.SetFetcher(src.JiraAccountID, f)
	_, _ = e.Run(context.Background())
	_, _ = e.Run(context.Background())
	all, _ := f.counts()
	assert.Equal(t, 1, all[KindPage])
	assert.Equal(t, 1, all[KindAttachment])

	now = time.Date(2026, 9, 2, 0, 0, 1, 0, time.UTC) // next UTC date, not 24h later
	_, _ = e.Run(context.Background())
	all, _ = f.counts()
	assert.Equal(t, 2, all[KindPage])
}

// A failed enumeration deletes nothing and leaves the reconcile due.
func TestReconcileFailureDeletesNothing(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	now := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	f.addPage("p1", 1, now.Add(-time.Hour))
	e := New(d, Options{Now: func() time.Time { return now }})
	e.SetFetcher(src.JiraAccountID, f)
	_, err := e.Run(context.Background())
	require.NoError(t, err)

	f.removeFromAll("p1")
	now = now.Add(24 * time.Hour)
	// The streams succeed; the attachments enumeration (after pages) fails.
	f.mu.Lock()
	f.failAll = map[ItemKind]error{KindAttachment: errors.New("listing failed")}
	f.mu.Unlock()
	_, err = e.Run(context.Background())
	require.Error(t, err)
	assert.Equal(t, []string{"p1"}, docIDs(t, d, src.ID))
	assert.Equal(t, "2026-09-01T10:00:00Z", loadSource(t, d).LastReconcileAt)
}

func TestReconcileSkippedWhenBudgetSpent(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	t0 := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	for i := 0; i < 5; i++ {
		f.addPage(string(rune('a'+i)), 1, t0.Add(time.Duration(i)*time.Second))
	}
	clock := &stepClock{t: t0, step: time.Minute}
	e := New(d, Options{Budget: 90 * time.Second, Now: clock.Now})
	e.SetFetcher(src.JiraAccountID, f)
	st, err := e.Run(context.Background())
	require.NoError(t, err)
	require.True(t, st.Incomplete)
	all, _ := f.counts()
	assert.Zero(t, all[KindPage], "no reconcile once the budget is spent")
	assert.Empty(t, loadSource(t, d).LastReconcileAt)
}

func TestUsersCachedAndRefreshedAfterTTL(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	now := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	f.addPage("p1", 1, now.Add(-time.Hour))
	f.setAuthor("p1", "u1")
	e := New(d, Options{Now: func() time.Time { return now }})
	e.SetFetcher(src.JiraAccountID, f)

	_, err := e.Run(context.Background())
	require.NoError(t, err)
	_, users := f.counts()
	assert.Equal(t, [][]string{{"u1"}}, users)
	var name, fetched string
	require.NoError(t, d.QueryRow(`SELECT display_name, fetched_at FROM ext_users
		WHERE provider = 'confluence' AND ext_user_id = 'u1'`).Scan(&name, &fetched))
	assert.Equal(t, "Name u1", name)
	assert.Equal(t, "2026-09-01T10:00:00Z", fetched)

	// Same day, the page changes again: u1 is written again but cached.
	f.mutate("p1", 2, now.Add(-30*time.Minute))
	_, err = e.Run(context.Background())
	require.NoError(t, err)
	require.Equal(t, 2, f.fetches["p1"])
	_, users = f.counts()
	assert.Len(t, users, 1, "a cached user is not resolved again within the TTL")

	// 31 days later a changed page resolves u1 again.
	now = now.Add(31 * 24 * time.Hour)
	f.mutate("p1", 3, now.Add(-time.Hour))
	_, err = e.Run(context.Background())
	require.NoError(t, err)
	_, users = f.counts()
	assert.Equal(t, [][]string{{"u1"}, {"u1"}}, users)
}

// Comment authors and body mentions are resolved too, in batches of at most
// usersBatchSize.
func TestUsersIncludeCommentAuthorsAndMentions(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	t0 := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	f.addPage("p1", 1, t0)
	f.mu.Lock()
	f.find("p1").item.MentionedUserIDs = []string{"m1"}
	f.mu.Unlock()
	f.addComment("c1", "p1", 1, t0, "hi")
	e := New(d, Options{})
	e.SetFetcher(src.JiraAccountID, f)
	_, err := e.Run(context.Background())
	require.NoError(t, err)
	_, users := f.counts()
	assert.Equal(t, [][]string{{"author-c1", "m1"}}, users)
}
