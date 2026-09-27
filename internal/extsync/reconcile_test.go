package extsync

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/kb"
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
	assert.Equal(t, 1, all[KindComment], "comments are reconciled on the same once-a-day schedule")

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

// A failed reconcile is not retried every cycle: the next full enumeration
// waits reconcileRetryAfter, then a success stamps last_reconcile_at.
func TestReconcileFailureBacksOff(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	now := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	e := New(d, Options{Now: func() time.Time { return now }})
	e.SetFetcher(src.JiraAccountID, f)
	f.mu.Lock()
	f.failAll = map[ItemKind]error{KindAttachment: errors.New("listing failed")}
	f.mu.Unlock()
	pageEnumerations := func() int {
		all, _ := f.counts()
		return all[KindPage]
	}

	_, err := e.Run(context.Background())
	require.Error(t, err)
	require.Equal(t, 1, pageEnumerations())

	now = now.Add(time.Hour) // later cycles within the backoff
	_, err = e.Run(context.Background())
	require.NoError(t, err, "the reconcile is skipped, not re-failed")
	now = now.Add(2 * time.Hour)
	_, err = e.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, pageEnumerations(), "no full enumeration inside the backoff")
	assert.Empty(t, loadSource(t, d).LastReconcileAt, "a failed attempt is not a reconcile")

	now = time.Date(2026, 9, 1, 14, 0, 0, 0, time.UTC) // reconcileRetryAfter after the failure
	f.mu.Lock()
	f.failAll = nil
	f.mu.Unlock()
	_, err = e.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 2, pageEnumerations(), "retried once the backoff passed")
	assert.Equal(t, "2026-09-01T14:00:00Z", loadSource(t, d).LastReconcileAt)
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

// A comment deleted upstream does not bump its page's version and is never
// listed by Changed again, so only the reconcile removes it: the row leaves
// ext_comments, its page is stamped children_changed_at, and the next KB
// cycle re-renders the page without it.
func TestReconcileDeletesRemovedComments(t *testing.T) {
	ctx := context.Background()
	d, src := newSourceDB(t)
	f := newFake()
	now := time.Now().UTC().Truncate(time.Second).Add(-48 * time.Hour)
	f.addPage("p1", 1, now.Add(-time.Hour))
	f.addComment("c1", "p1", 1, now.Add(-time.Hour), "keep this remark")
	f.addComment("c2", "p1", 1, now.Add(-time.Hour), "zanzibar remark")
	e := New(d, Options{Now: func() time.Time { return now }})
	e.SetFetcher(src.JiraAccountID, f)
	_, err := e.Run(ctx)
	require.NoError(t, err)
	_, err = kb.Run(ctx, d, kb.Options{Sources: []string{"confluence"}, Now: nextCycle()})
	require.NoError(t, err)
	docRef := "confluence:" + strconv.FormatInt(src.ID, 10) + ":p1"
	require.Contains(t, kbChunkText(t, d, docRef), "zanzibar")

	f.deleteComment("c2")
	now = now.Add(24 * time.Hour)
	_, err = e.Run(ctx)
	require.NoError(t, err)
	assert.Equal(t, []string{"keep this remark"}, commentTexts(t, d, src.ID, "p1"))
	var stamped string
	require.NoError(t, d.QueryRow(`SELECT children_changed_at FROM ext_documents WHERE source_id = ? AND ext_id = 'p1'`,
		src.ID).Scan(&stamped))
	assert.Equal(t, formatTime(now), stamped, "the parent is marked for a KB re-render")

	_, err = kb.Run(ctx, d, kb.Options{Sources: []string{"confluence"}, Now: nextCycle()})
	require.NoError(t, err)
	text := kbChunkText(t, d, docRef)
	assert.NotContains(t, text, "zanzibar", "the deleted comment leaves search")
	assert.Contains(t, text, "keep this remark")
}

// Relink runs for the parent that lost a comment, so a Jira key cited only
// in the deleted comment stops linking.
func TestReconcileRelinksParentOfRemovedComment(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	now := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	f.addPage("p1", 1, now.Add(-time.Hour))
	f.addComment("c1", "p1", 1, now.Add(-time.Hour), "see PROJ-7")
	var relinked []string
	e := New(d, Options{Now: func() time.Time { return now }, Relink: func(_ context.Context, _ Queryer, ref string, texts ...string) error {
		relinked = append(relinked, ref+"|"+strings.Join(texts, " "))
		return nil
	}})
	e.SetFetcher(src.JiraAccountID, f)
	_, err := e.Run(context.Background())
	require.NoError(t, err)

	f.deleteComment("c1")
	relinked = nil
	now = now.Add(24 * time.Hour)
	_, err = e.Run(context.Background())
	require.NoError(t, err)
	require.Len(t, relinked, 1)
	assert.True(t, strings.HasPrefix(relinked[0], docRef("confluence", src.ID, "p1")+"|"), relinked[0])
	assert.NotContains(t, relinked[0], "PROJ-7")
}

// A comment enumeration that fails — outright, or partway through its
// pages — deletes nothing (no comment, no document), leaves the reconcile
// unstamped and puts the source on the reconcile backoff.
func TestReconcileCommentEnumerationFailureDeletesNothing(t *testing.T) {
	for name, fail := range map[string]func(f *fakeFetcher){
		"outright": func(f *fakeFetcher) { f.failAll = map[ItemKind]error{KindComment: errors.New("listing failed")} },
		"partial":  func(f *fakeFetcher) { f.failAllPage = map[ItemKind]string{KindComment: "2"} },
	} {
		t.Run(name, func(t *testing.T) {
			d, src := newSourceDB(t)
			f := newFake()
			now := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
			f.addPage("p1", 1, now.Add(-time.Hour))
			f.addPage("p2", 1, now.Add(-time.Hour))
			for _, id := range []string{"c1", "c2", "c3", "c4"} { // after c1 goes, All(comment) spans two pages
				f.addComment(id, "p1", 1, now.Add(-time.Hour), id)
			}
			e := New(d, Options{Now: func() time.Time { return now }})
			e.SetFetcher(src.JiraAccountID, f)
			_, err := e.Run(context.Background())
			require.NoError(t, err)
			stamp := loadSource(t, d).LastReconcileAt

			f.deleteComment("c1")
			f.removeFromAll("p2")
			f.mu.Lock()
			fail(f)
			f.mu.Unlock()
			now = now.Add(24 * time.Hour)
			_, err = e.Run(context.Background())
			require.Error(t, err)
			assert.Equal(t, []string{"c1", "c2", "c3", "c4"}, commentTexts(t, d, src.ID, "p1"))
			assert.Equal(t, []string{"p1", "p2"}, docIDs(t, d, src.ID))
			assert.Equal(t, stamp, loadSource(t, d).LastReconcileAt)
			assert.False(t, e.reconcileAllowed(loadSource(t, d), now.Add(time.Hour)), "on the backoff")
		})
	}
}

// kbChunkText returns every indexed chunk body of a KB document, joined.
func kbChunkText(t *testing.T, d *db.DB, docID string) string {
	t.Helper()
	rows, err := d.Query(`SELECT body FROM kb_chunks WHERE doc_id = ? ORDER BY idx`, docID)
	require.NoError(t, err)
	defer rows.Close()
	var parts []string
	for rows.Next() {
		var s string
		require.NoError(t, rows.Scan(&s))
		parts = append(parts, s)
	}
	require.NoError(t, rows.Err())
	return strings.Join(parts, "\n")
}
