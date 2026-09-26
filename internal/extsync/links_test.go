package extsync

import (
	"context"
	"sort"
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// setText gives document id new text, version and modification time.
func (f *fakeFetcher) setText(id string, version int, modified time.Time, text string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	d := f.find(id)
	d.ref.Version, d.ref.Modified = version, modified
	d.item.Ref = d.ref
	d.item.Sections = []Section{{Text: text}}
}

// jiraLinks returns the Jira keys the knowledge document of extID links.
func jiraLinks(t *testing.T, d *db.DB, sourceID int64, extID string) []string {
	t.Helper()
	links, err := d.DocLinksFrom("confluence", "confluence:"+strconv.FormatInt(sourceID, 10)+":"+extID)
	require.NoError(t, err)
	out := []string{}
	for _, l := range links {
		if l.ToKind == "jira_issue" {
			out = append(out, l.ToRef)
		}
	}
	sort.Strings(out)
	return out
}

// A page links the keys of its own text and of its comments (the knowledge
// document includes both). Every rewrite replaces the set: a page edit, a
// comment-only change (the page is not re-fetched) and a deletion each leave
// exactly the keys still mentioned.
func TestLinks_PageAndCommentsReplacedOnEveryWrite(t *testing.T) {
	ctx := context.Background()
	d, src := newSourceDB(t)
	f := newFake()
	f.addPage("p1", 1, t0)
	f.setText("p1", 1, t0, "Implements PROJ-1")
	f.addComment("c1", "p1", 1, t0, "blocked by PROJ-2")
	f.addPage("p2", 1, t0)
	f.setText("p2", 1, t0, "Unrelated OTHER-9")
	e := New(d, Options{})
	e.SetFetcher(src.JiraAccountID, f)

	_, err := e.Run(ctx)
	require.NoError(t, err)
	assert.Equal(t, []string{"PROJ-1", "PROJ-2"}, jiraLinks(t, d, src.ID, "p1"))

	f.setText("p1", 2, t0.Add(time.Hour), "Now implements PROJ-3")
	_, err = e.Run(ctx)
	require.NoError(t, err)
	assert.Equal(t, []string{"PROJ-2", "PROJ-3"}, jiraLinks(t, d, src.ID, "p1"), "a page edit drops PROJ-1")

	fetchesBefore := f.fetches["p1"]
	f.setText("c1", 2, t0.Add(2*time.Hour), "no longer blocked")
	_, err = e.Run(ctx)
	require.NoError(t, err)
	require.Equal(t, fetchesBefore, f.fetches["p1"], "the comments stream alone carried this change")
	assert.Equal(t, []string{"PROJ-3"}, jiraLinks(t, d, src.ID, "p1"), "a comment edit drops PROJ-2")

	f.markGone("p1", 3, t0.Add(3*time.Hour))
	_, err = e.Run(ctx)
	require.NoError(t, err)
	assert.Empty(t, jiraLinks(t, d, src.ID, "p1"), "a deleted page links nothing")
	assert.Equal(t, []string{"OTHER-9"}, jiraLinks(t, d, src.ID, "p2"), "another page is untouched")
}

// The daily reconcile's deletions drop the deleted documents' links too.
func TestLinks_ReconcileDeletionUnlinks(t *testing.T) {
	ctx := context.Background()
	d, src := newSourceDB(t)
	f := newFake()
	f.addPage("p1", 1, t0)
	f.setText("p1", 1, t0, "PROJ-1")
	e := New(d, Options{})
	e.SetFetcher(src.JiraAccountID, f)
	_, err := e.Run(ctx)
	require.NoError(t, err)
	require.Equal(t, []string{"PROJ-1"}, jiraLinks(t, d, src.ID, "p1"))

	f.removeFromAll("p1")
	_, err = d.Exec(`UPDATE ext_sources SET last_reconcile_at = '' WHERE id = ?`, src.ID)
	require.NoError(t, err)
	_, err = e.Run(ctx)
	require.NoError(t, err)
	require.Zero(t, countDocs(t, d, src.ID))
	assert.Empty(t, jiraLinks(t, d, src.ID, "p1"))
}

// An attachment's extracted text links as its own document.
func TestLinks_AttachmentText(t *testing.T) {
	ctx := context.Background()
	d, src, f, e := newAttachmentEngine(t, newFakeExtractor())
	f.addAttachment("a1", "p1", 1, t0, "PROJ-7 spec.txt", "text/plain", []byte("hello"), -1)
	_, err := e.Run(ctx)
	require.NoError(t, err)
	assert.Equal(t, []string{"PROJ-7"}, jiraLinks(t, d, src.ID, "a1"))
	assert.Empty(t, jiraLinks(t, d, src.ID, "p1"), "the parent page does not mention it")
}
