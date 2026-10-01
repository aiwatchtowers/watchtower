package kb

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// writeScopedDoc stores a one-section document of an arbitrary source and
// anchor directly (scope fixtures need control over source, anchor and time).
func writeScopedDoc(t *testing.T, d *db.DB, id, source string, anchor map[string]string, text string, at time.Time) {
	t.Helper()
	_, err := writeDoc(context.Background(), d, &Doc{
		ID: id, Source: source, Title: "doc " + id, Time: at, Anchor: anchor, Sections: []Section{{Text: text}},
	})
	require.NoError(t, err)
}

func hitByRef(res Result, ref string) (Hit, bool) {
	for _, h := range res.Hits {
		if h.Ref == ref {
			return h, true
		}
	}
	return Hit{}, false
}

func TestSearch_ScopeMarksEachSourceKind(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	now := testNow()
	writeScopedDoc(t, d, "s:in", "slack", map[string]string{"channel_id": "1:C1", "thread_ts": "1.1"}, "релиз стейдж", now)
	writeScopedDoc(t, d, "s:out", "slack", map[string]string{"channel_id": "1:C2", "thread_ts": "1.1"}, "релиз стейдж", now)
	writeScopedDoc(t, d, "j:in", "jira", map[string]string{"account_id": "1", "key": "PROJ-12"}, "релиз стейдж", now)
	// PROJX-1 shares PROJ as a string prefix but is another project.
	writeScopedDoc(t, d, "j:out", "jira", map[string]string{"account_id": "1", "key": "PROJX-1"}, "релиз стейдж", now)
	writeScopedDoc(t, d, "c:in", "confluence", map[string]string{"source_id": "1", "ext_id": "5", "space": "Eng"}, "релиз стейдж", now)
	writeScopedDoc(t, d, "c:out", "confluence", map[string]string{"source_id": "2", "ext_id": "6", "space": "OPS"}, "релиз стейдж", now)
	writeScopedDoc(t, d, "i:out", "idea", map[string]string{"idea_id": "1"}, "релиз стейдж", now)

	scope := Scope{SlackChannels: []string{"1:C1"}, JiraProjects: []string{"proj"}, ConfluenceSpaces: []string{"ENG"}}
	res, err := Search(ctx, d, Request{Queries: []string{"релиз"}, Scope: scope, Now: now})
	require.NoError(t, err)
	require.Len(t, res.Hits, 7, "a boost never drops a document")
	for _, h := range res.Hits {
		assert.Equal(t, strings.HasSuffix(h.Ref, ":in"), h.InScope, h.Ref)
	}
	// Equal text and time: the in-scope documents' second contribution puts
	// all three ahead of the rest.
	for i, h := range res.Hits[:3] {
		assert.True(t, h.InScope, "rank %d: %s", i, h.Ref)
	}

	only, err := Search(ctx, d, Request{Queries: []string{"релиз"}, Scope: scope, ScopeOnly: true, Now: now})
	require.NoError(t, err)
	assert.ElementsMatch(t, []string{"s:in", "j:in", "c:in"}, hitRefs(only))

	plain, err := Search(ctx, d, Request{Queries: []string{"релиз"}, Now: now})
	require.NoError(t, err)
	require.Len(t, plain.Hits, 7)
	for _, h := range plain.Hits {
		assert.False(t, h.InScope, "no scope, no in_scope flag: %s", h.Ref)
	}
}

func TestSearch_ScopeBoostOutranksNewerEqualMatch(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	now := testNow()
	writeScopedDoc(t, d, "s:old", "slack", map[string]string{"channel_id": "1:C1", "date": "2025-09-26"}, "миграция базы", now.AddDate(-1, 0, 0))
	writeScopedDoc(t, d, "i:new", "idea", map[string]string{"idea_id": "1"}, "миграция базы", now)

	plain, err := Search(ctx, d, Request{Queries: []string{"миграция"}, Now: now})
	require.NoError(t, err)
	assert.Equal(t, []string{"i:new", "s:old"}, hitRefs(plain), "without a scope recency decides")

	scoped, err := Search(ctx, d, Request{Queries: []string{"миграция"}, Scope: Scope{SlackChannels: []string{"1:C1"}}, Now: now})
	require.NoError(t, err)
	assert.Equal(t, []string{"s:old", "i:new"}, hitRefs(scoped), "the in-scope document ranks first")
}

// TestSearch_ScopeRetrievesBeyondGlobalCandidates pins why the scope runs its
// own retrieval rather than only re-weighting the global list: an in-scope
// chunk below the global top `candidates` would otherwise never be seen.
func TestSearch_ScopeRetrievesBeyondGlobalCandidates(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	now := testNow()
	for i := range candidates + 10 {
		writeScopedDoc(t, d, fmt.Sprintf("i:%02d", i), "idea", map[string]string{"idea_id": fmt.Sprint(i)}, "квартальный отчёт", now)
	}
	long := "квартальный " + strings.Repeat("прочий текст обсуждения ", 60)
	writeScopedDoc(t, d, "j:in", "jira", map[string]string{"account_id": "1", "key": "OPS-1"}, long, now)

	plain, err := Search(ctx, d, Request{Queries: []string{"квартальный"}, Limit: MaxLimit, Now: now})
	require.NoError(t, err)
	_, found := hitByRef(plain, "j:in")
	require.False(t, found, "fixture: the weak in-scope match is outside the global candidates")

	scoped, err := Search(ctx, d, Request{Queries: []string{"квартальный"}, Limit: MaxLimit, Scope: Scope{JiraProjects: []string{"OPS"}}, Now: now})
	require.NoError(t, err)
	h, found := hitByRef(scoped, "j:in")
	require.True(t, found)
	assert.True(t, h.InScope)
}

func TestSearch_ScopeOnlyWithEmptyScopeFindsNothing(t *testing.T) {
	d := db.OpenTestDB(t)
	writeScopedDoc(t, d, "i:1", "idea", map[string]string{"idea_id": "1"}, "релиз", testNow())
	res, err := Search(context.Background(), d, Request{Queries: []string{"релиз"}, ScopeOnly: true, Now: testNow()})
	require.NoError(t, err)
	assert.Empty(t, res.Hits)
	assert.NotNil(t, res.Hits)
}

func TestSearch_ScopeHonoursSourcesFilter(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	now := testNow()
	writeScopedDoc(t, d, "s:in", "slack", map[string]string{"channel_id": "1:C1", "thread_ts": "1.1"}, "релиз", now)
	writeScopedDoc(t, d, "j:in", "jira", map[string]string{"account_id": "1", "key": "PROJ-1"}, "релиз", now)
	writeScopedDoc(t, d, "i:out", "idea", map[string]string{"idea_id": "1"}, "релиз", now)
	scope := Scope{SlackChannels: []string{"1:C1"}, JiraProjects: []string{"PROJ"}}
	res, err := Search(ctx, d, Request{Queries: []string{"релиз"}, Sources: []string{"jira", "idea"}, Scope: scope, Now: now})
	require.NoError(t, err)
	assert.Equal(t, []string{"j:in", "i:out"}, hitRefs(res), "an explicit sources filter applies to the scoped list too")
}

func TestRecent(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	now := testNow()
	writeScopedDoc(t, d, "s:new", "slack", map[string]string{"channel_id": "1:C1", "thread_ts": "3.1"}, "a", now.Add(-time.Hour))
	writeScopedDoc(t, d, "j:mid", "jira", map[string]string{"account_id": "1", "key": "PROJ-1"}, "b", now.Add(-48*time.Hour))
	writeScopedDoc(t, d, "c:old", "confluence", map[string]string{"source_id": "1", "ext_id": "1", "space": "ENG"}, "c", now.AddDate(0, -2, 0))
	writeScopedDoc(t, d, "s:other", "slack", map[string]string{"channel_id": "1:C2", "thread_ts": "4.1"}, "d", now)
	scope := Scope{SlackChannels: []string{"1:C1"}, JiraProjects: []string{"PROJ"}, ConfluenceSpaces: []string{"eng"}}

	got, err := Recent(ctx, d, scope, now.AddDate(0, 0, -14), 10)
	require.NoError(t, err)
	require.Len(t, got, 2, "older than since is left out, another channel never appears")
	assert.Equal(t, "s:new", got[0].Ref)
	assert.Equal(t, "j:mid", got[1].Ref)
	assert.Equal(t, "doc s:new", got[0].Title)
	assert.Equal(t, map[string]string{"channel_id": "1:C1", "thread_ts": "3.1"}, got[0].Anchor)
	assert.True(t, got[0].InScope)

	got, err = Recent(ctx, d, scope, time.Time{}, 1)
	require.NoError(t, err)
	assert.Equal(t, []string{"s:new"}, []string{got[0].Ref})

	got, err = Recent(ctx, d, Scope{}, time.Time{}, 10)
	require.NoError(t, err)
	assert.Empty(t, got)
}

// Every filter at once: the scope, sources and the time window combine in
// both the boost and the only retrieval.
func TestSearch_ScopeWithEveryFilter(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	now := testNow()
	writeScopedDoc(t, d, "j:in", "jira", map[string]string{"account_id": "1", "key": "PROJ-1"}, "релиз", now.AddDate(0, 0, -2))
	writeScopedDoc(t, d, "j:old", "jira", map[string]string{"account_id": "1", "key": "PROJ-2"}, "релиз", now.AddDate(0, -3, 0))
	writeScopedDoc(t, d, "j:out", "jira", map[string]string{"account_id": "1", "key": "OPS-1"}, "релиз", now.AddDate(0, 0, -1))
	writeScopedDoc(t, d, "s:in", "slack", map[string]string{"channel_id": "1:C1", "thread_ts": "1.1"}, "релиз", now.AddDate(0, 0, -1))
	req := Request{Queries: []string{"релиз"}, Sources: []string{"jira"}, From: now.AddDate(0, 0, -7), To: now,
		Scope: Scope{SlackChannels: []string{"1:C1"}, JiraProjects: []string{"PROJ"}}, Now: now}
	res, err := Search(ctx, d, req)
	require.NoError(t, err)
	assert.Equal(t, []string{"j:in", "j:out"}, hitRefs(res))
	req.ScopeOnly = true
	res, err = Search(ctx, d, req)
	require.NoError(t, err)
	assert.Equal(t, []string{"j:in"}, hitRefs(res))
}

// KB-03 for scoped hits: an in-scope hit opens and anchors like any other.
func TestSearch_ScopedHitsOpen(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedAll(t, d)
	scope := Scope{SlackChannels: []string{"1:C1"}, JiraProjects: []string{"PROJ"}, ConfluenceSpaces: []string{"ENG"}}
	res, err := Search(ctx, d, Request{Queries: []string{"релиз*", "стейдж*", "договор*", "runbook"}, Scope: scope, Limit: MaxLimit, Now: testNow()})
	require.NoError(t, err)
	inScope := map[string]bool{}
	for _, h := range res.Hits {
		doc, err := GetDocument(ctx, d, h.Ref, DocOptions{FromChunk: h.Chunk})
		require.NoError(t, err, h.Ref)
		assert.Equal(t, h.Anchor, doc.Anchor, h.Ref)
		if h.InScope {
			inScope[h.Source] = true
		}
	}
	assert.Equal(t, map[string]bool{"slack": true, "jira": true, "confluence": true}, inScope, "the fixture's in-scope sources are all hit")
}
