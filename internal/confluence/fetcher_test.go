package confluence

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/extsync"
	"watchtower/internal/jira"
)

// route answers GetJSON calls to path whose query satisfies match with a
// fixture file, a generated body, or an error.
type route struct {
	path    string
	match   func(q url.Values) bool
	fixture string
	gen     func(q url.Values) any
	err     error
}

type request struct {
	method string // "GetJSON" | "Download"
	path   string
	q      url.Values
}

// fakeAPI maps path + query → fixture and records every request. An
// unrouted path answers 404, like Confluence does for an unknown id.
type fakeAPI struct {
	t      *testing.T
	mu     sync.Mutex
	routes []route
	reqs   []request
	// download answers Download when set (default: the body "bytes").
	download func(path string) (io.ReadCloser, error)
}

func anyQuery(url.Values) bool { return true }

func cqlHas(sub string) func(url.Values) bool {
	return func(q url.Values) bool { return strings.Contains(q.Get("cql"), sub) && q.Get("cursor") == "" }
}

func cursorIs(c string) func(url.Values) bool {
	return func(q url.Values) bool { return q.Get("cursor") == c }
}

func noCursor(q url.Values) bool { return q.Get("cursor") == "" }

func newFakeAPI(t *testing.T) *fakeAPI {
	a := &fakeAPI{t: t}
	search := "/wiki/rest/api/content/search"
	a.routes = []route{
		{path: "/wiki/api/v2/spaces", match: noCursor, fixture: "spaces.json"},
		{path: "/wiki/api/v2/spaces", match: cursorIs("sp2"), fixture: "spaces_p2.json"},
		{path: search, match: cursorIs("abc"), fixture: "search_pages_p2.json"},
		{path: search, match: cqlHas("type IN (page, blogpost)"), fixture: "search_pages_p1.json"},
		{path: search, match: cqlHas("type = comment"), fixture: "search_comments.json"},
		{path: search, match: cqlHas("type = attachment"), fixture: "search_attachments.json"},
		{path: search, match: cqlHas("id = 1"), fixture: "ancestors_1.json"},
		{path: search, match: cqlHas("id = 2"), fixture: "kind_2.json"},
		{path: search, match: cqlHas("id = "), fixture: "search_empty.json"},
		{path: "/wiki/api/v2/pages/1", match: anyQuery, fixture: "page_1.json"},
		{path: "/wiki/api/v2/pages/5", match: anyQuery, fixture: "page_trashed.json"},
		{path: "/wiki/api/v2/blogposts/2", match: anyQuery, fixture: "blogpost_2.json"},
		{path: "/wiki/api/v2/attachments/att3", match: anyQuery, fixture: "attachment_3.json"},
		{path: "/wiki/api/v2/pages/1/footer-comments", match: noCursor, fixture: "comments_footer_1.json"},
		{path: "/wiki/api/v2/pages/1/inline-comments", match: noCursor, fixture: "comments_inline_1.json"},
		{path: "/wiki/api/v2/blogposts/2/footer-comments", match: noCursor, fixture: "comments_empty.json"},
		{path: "/wiki/api/v2/blogposts/2/inline-comments", match: noCursor, fixture: "comments_empty.json"},
		{path: "/wiki/api/v2/footer-comments/100/children", match: anyQuery, fixture: "comments_empty.json"},
		{path: "/wiki/api/v2/inline-comments/200/children", match: anyQuery, fixture: "comments_empty.json"},
		{path: "/wiki/api/v2/spaces/10/pages", match: noCursor, fixture: "space_pages.json"},
		{path: "/wiki/api/v2/spaces/10/pages", match: cursorIs("pc2"), fixture: "space_pages_p2.json"},
		{path: "/wiki/api/v2/spaces/10/blogposts", match: noCursor, fixture: "space_blogposts.json"},
		{path: "/wiki/rest/api/user/bulk", match: anyQuery, fixture: "users_bulk.json"},
	}
	return a
}

// prepend adds routes that win over the defaults.
func (a *fakeAPI) prepend(rs ...route) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.routes = append(append([]route{}, rs...), a.routes...)
}

// withReplies routes the reply fixtures: 100 → 101 → 102, 200 → 201.
func (a *fakeAPI) withReplies() {
	a.prepend(
		route{path: "/wiki/api/v2/footer-comments/100/children", match: anyQuery, fixture: "comment_children_100.json"},
		route{path: "/wiki/api/v2/footer-comments/101/children", match: anyQuery, fixture: "comment_children_101.json"},
		route{path: "/wiki/api/v2/footer-comments/102/children", match: anyQuery, fixture: "comments_empty.json"},
		route{path: "/wiki/api/v2/inline-comments/200/children", match: anyQuery, fixture: "comment_children_200.json"},
		route{path: "/wiki/api/v2/inline-comments/201/children", match: anyQuery, fixture: "comments_empty.json"},
	)
}

func (a *fakeAPI) GetJSON(_ context.Context, path string, q url.Values, out any) error {
	a.mu.Lock()
	a.reqs = append(a.reqs, request{method: "GetJSON", path: path, q: cloneValues(q)})
	var hit *route
	for i := range a.routes {
		if a.routes[i].path == path && a.routes[i].match(q) {
			hit = &a.routes[i]
			break
		}
	}
	a.mu.Unlock()
	if hit == nil {
		return &jira.HTTPStatusError{Status: 404, Body: `{"message":"not found"}`}
	}
	if hit.err != nil {
		return hit.err
	}
	var raw []byte
	if hit.gen != nil {
		b, err := json.Marshal(hit.gen(q))
		require.NoError(a.t, err)
		raw = b
	} else {
		b, err := os.ReadFile(filepath.Join("testdata", "http", hit.fixture))
		require.NoError(a.t, err)
		raw = b
	}
	return json.Unmarshal(raw, out)
}

func (a *fakeAPI) Download(_ context.Context, path string, _ int64) (io.ReadCloser, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.reqs = append(a.reqs, request{method: "Download", path: path})
	if a.download != nil {
		return a.download(path)
	}
	return io.NopCloser(strings.NewReader("bytes")), nil
}

func cloneValues(q url.Values) url.Values {
	out := url.Values{}
	for k, v := range q {
		out[k] = append([]string(nil), v...)
	}
	return out
}

func (a *fakeAPI) requests() []request {
	a.mu.Lock()
	defer a.mu.Unlock()
	return append([]request(nil), a.reqs...)
}

func (a *fakeAPI) lastQuery() url.Values {
	rs := a.requests()
	return rs[len(rs)-1].q
}

func (a *fakeAPI) requestsTo(path string) []request {
	var out []request
	for _, r := range a.requests() {
		if r.path == path {
			out = append(out, r)
		}
	}
	return out
}

var (
	testSite = "https://acme.atlassian.net"
	engSpace = extsync.Container{Key: "ENG", Name: "Engineering", ExtID: "10"}
)

func TestChangedPagesPaginatesAndMaps(t *testing.T) {
	api := newFakeAPI(t)
	f := NewFetcher(api, "https://acme.atlassian.net")
	c := extsync.Container{Key: "ENG", ExtID: "10"}
	since := time.Date(2026, 9, 2, 12, 30, 0, 0, time.UTC)
	refs, next, err := f.Changed(context.Background(), c, extsync.KindPage, since, "")
	require.NoError(t, err)
	assert.Equal(t, "abc", next)
	require.Len(t, refs, 2)
	assert.Equal(t, extsync.KindPage, refs[0].Kind)
	assert.Equal(t, extsync.KindBlogpost, refs[1].Kind)
	cql := api.lastQuery().Get("cql")
	assert.Contains(t, cql, `space = "ENG"`)
	assert.Contains(t, cql, `lastmodified >= "2026/09/01 12:30"`, "24h timezone-safe overlap")
	assert.Contains(t, cql, "ORDER BY lastmodified ASC")

	assert.Equal(t, extsync.ItemRef{Kind: extsync.KindPage, ExtID: "1", Version: 3,
		Modified: time.Date(2026, 9, 1, 13, 0, 0, 0, time.UTC)}, refs[0])
	assert.Equal(t, 1, refs[1].Version)
	assert.Equal(t, time.Date(2026, 9, 2, 9, 15, 30, 123e6, time.UTC), refs[1].Modified.UTC())

	// Page 2: the same query plus the cursor; the trashed row is dropped
	// and the enumeration ends.
	refs, next, err = f.Changed(context.Background(), c, extsync.KindPage, since, "abc")
	require.NoError(t, err)
	assert.Empty(t, next)
	require.Len(t, refs, 1)
	assert.Equal(t, "4", refs[0].ExtID)
	q := api.lastQuery()
	assert.Equal(t, "abc", q.Get("cursor"))
	assert.Equal(t, cql, q.Get("cql"), "a resumed page replays the pass's query")
	assert.Equal(t, "100", q.Get("limit"))
	assert.Empty(t, q.Get("start"), "offset paging is never used")
}

func TestBuildCQLPinned(t *testing.T) {
	since := time.Date(2026, 9, 2, 12, 30, 45, 0, time.UTC)
	kyiv := time.FixedZone("EEST", 3*3600)
	cases := []struct {
		name  string
		kind  extsync.ItemKind
		since time.Time
		want  string
	}{
		{"pages delta", extsync.KindPage, since,
			`space = "ENG" AND type IN (page, blogpost) AND lastmodified >= "2026/09/01 12:30" ORDER BY lastmodified ASC`},
		{"pages full", extsync.KindPage, time.Time{},
			`space = "ENG" AND type IN (page, blogpost) ORDER BY lastmodified ASC`},
		{"comments delta", extsync.KindComment, since,
			`space = "ENG" AND type = comment AND lastmodified >= "2026/09/01 12:30" ORDER BY lastmodified ASC`},
		{"attachments full", extsync.KindAttachment, time.Time{},
			`space = "ENG" AND type = attachment ORDER BY lastmodified ASC`},
		{"non-UTC since is rendered in UTC", extsync.KindPage, since.In(kyiv),
			`space = "ENG" AND type IN (page, blogpost) AND lastmodified >= "2026/09/01 12:30" ORDER BY lastmodified ASC`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := buildCQL("ENG", tc.kind, tc.since)
			require.NoError(t, err)
			assert.Equal(t, tc.want, got)
		})
	}
	got, err := buildCQL(`we"ird\key`, extsync.KindPage, time.Time{})
	require.NoError(t, err)
	assert.Equal(t, `space = "we\"ird\\key" AND type IN (page, blogpost) ORDER BY lastmodified ASC`, got)
	_, err = buildCQL("ENG", extsync.KindBlogpost, time.Time{})
	assert.Error(t, err, "blog posts are enumerated with pages, never alone")
}

func TestChangedAttachmentsSetsParent(t *testing.T) {
	api := newFakeAPI(t)
	f := NewFetcher(api, testSite)
	refs, next, err := f.Changed(context.Background(), engSpace, extsync.KindAttachment, time.Time{}, "")
	require.NoError(t, err)
	assert.Empty(t, next)
	require.Len(t, refs, 2)
	assert.Equal(t, extsync.ItemRef{Kind: extsync.KindAttachment, ExtID: "att3", Version: 2,
		Modified: time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC), ParentID: "1"}, refs[0])
	assert.Equal(t, "2", refs[1].ParentID)
	assert.NotContains(t, api.lastQuery().Get("cql"), "lastmodified >=", "zero since = no date clause")
}

func TestChangedIsAscendingByModified(t *testing.T) {
	api := newFakeAPI(t)
	f := NewFetcher(api, testSite)
	for _, kind := range []extsync.ItemKind{extsync.KindPage, extsync.KindComment, extsync.KindAttachment} {
		refs, _, err := f.Changed(context.Background(), engSpace, kind, time.Time{}, "")
		require.NoError(t, err)
		assert.True(t, sort.SliceIsSorted(refs, func(i, j int) bool { return refs[i].Modified.Before(refs[j].Modified) }), kind)
		assert.Equal(t, "lastmodified", strings.Fields(strings.SplitN(api.lastQuery().Get("cql"), "ORDER BY", 2)[1])[0])
	}
}

func TestFetchPageRendersSectionsURLMeta(t *testing.T) {
	api := newFakeAPI(t)
	f := NewFetcher(api, "https://acme.atlassian.net")
	it, err := f.Fetch(context.Background(), extsync.Container{Key: "ENG"}, extsync.ItemRef{Kind: extsync.KindPage, ExtID: "1", Version: 3})
	require.NoError(t, err)
	require.NotNil(t, it)
	assert.Equal(t, "https://acme.atlassian.net/wiki/spaces/ENG/pages/1/Release+plan", it.URL)
	assert.Equal(t, "ENG", it.Meta["space"])
	assert.Equal(t, "Engineering / Releases", it.Meta["ancestors"])
	assert.NotEmpty(t, it.Sections)
	assert.Contains(t, it.MentionedUserIDs, "acc-1")

	assert.Equal(t, "Release plan", it.Title)
	assert.Equal(t, "acc-author", it.AuthorID)
	assert.Equal(t, "current", it.Status)
	assert.Equal(t, "current", it.Meta["status"])
	assert.Equal(t, "release, q3", it.Meta["labels"])
	assert.Equal(t, "ENG-42", it.Meta["jira_keys"])
	assert.Equal(t, extsync.ItemRef{Kind: extsync.KindPage, ExtID: "1", Version: 3,
		Modified: time.Date(2026, 9, 1, 13, 0, 0, 0, time.UTC)}, it.Ref)
	assert.Equal(t, time.Date(2026, 8, 1, 10, 0, 0, 0, time.UTC), it.Created)
	assert.Equal(t, "Scope", it.Sections[len(it.Sections)-1].Heading)

	q := api.requestsTo("/wiki/api/v2/pages/1")[0].q
	assert.Equal(t, "storage", q.Get("body-format"))
	assert.Equal(t, "true", q.Get("include-labels"))
	assert.Equal(t, []string{"current", "archived"}, q["status"], "an archived page is fetched, not gone")
	anc := api.requestsTo("/wiki/rest/api/content/search")
	require.Len(t, anc, 1, "exactly one extra call, for the ancestors")
	assert.Equal(t, "id = 1", anc[0].q.Get("cql"))
	assert.Equal(t, "ancestors", anc[0].q.Get("expand"))
}

func TestFetchBlogpostSkipsAncestors(t *testing.T) {
	api := newFakeAPI(t)
	f := NewFetcher(api, testSite)
	it, err := f.Fetch(context.Background(), engSpace, extsync.ItemRef{Kind: extsync.KindBlogpost, ExtID: "2", Version: 1})
	require.NoError(t, err)
	require.NotNil(t, it)
	assert.Equal(t, extsync.KindBlogpost, it.Ref.Kind)
	assert.Equal(t, "https://acme.atlassian.net/wiki/spaces/ENG/blog/2026/09/02/2/Launch+notes", it.URL)
	assert.NotContains(t, it.Meta, "ancestors")
	assert.NotContains(t, it.Meta, "labels", "no labels = no key")
	assert.Empty(t, api.requestsTo("/wiki/rest/api/content/search"))
}

func TestFetchTrashedOr404IsGone(t *testing.T) {
	api := newFakeAPI(t)
	f := NewFetcher(api, testSite)
	ctx := context.Background()

	it, err := f.Fetch(ctx, engSpace, extsync.ItemRef{Kind: extsync.KindPage, ExtID: "5", Version: 2})
	require.NoError(t, err)
	assert.Nil(t, it, "page_trashed.json → gone")

	it, err = f.Fetch(ctx, engSpace, extsync.ItemRef{Kind: extsync.KindPage, ExtID: "404404", Version: 1})
	require.NoError(t, err)
	assert.Nil(t, it, "unknown id (HTTPStatusError 404) → gone")

	it, err = f.Fetch(ctx, engSpace, extsync.ItemRef{Kind: extsync.KindBlogpost, ExtID: "404404", Version: 1})
	require.NoError(t, err)
	assert.Nil(t, it)

	it, err = f.Fetch(ctx, engSpace, extsync.ItemRef{Kind: extsync.KindAttachment, ExtID: "att404", Version: 1})
	require.NoError(t, err)
	assert.Nil(t, it, "attachment 404 → gone")
}

func TestFetchAttachmentAndDownload(t *testing.T) {
	api := newFakeAPI(t)
	f := NewFetcher(api, testSite)
	it, err := f.Fetch(context.Background(), engSpace, extsync.ItemRef{Kind: extsync.KindAttachment, ExtID: "att3", Version: 2})
	require.NoError(t, err)
	require.NotNil(t, it)
	assert.Equal(t, extsync.ItemRef{Kind: extsync.KindAttachment, ExtID: "att3", Version: 2,
		Modified: time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC), ParentID: "1"}, it.Ref)
	assert.Equal(t, "diagram.png", it.Title)
	assert.Equal(t, "image/png", it.MediaType)
	assert.Equal(t, int64(48213), it.Size)
	assert.Equal(t, "acc-5", it.AuthorID)
	assert.Equal(t, "/wiki/rest/api/content/1/child/attachment/att3/download", it.Download)
	assert.Equal(t, "https://acme.atlassian.net/wiki/spaces/ENG/pages/1/Release+plan?preview=%2F1%2Fatt3%2Fdiagram.png", it.URL)
	assert.Equal(t, "ENG", it.Meta["space"])

	rc, err := f.Download(context.Background(), it, 1<<20)
	require.NoError(t, err)
	require.NoError(t, rc.Close())
	rs := api.requests()
	assert.Equal(t, request{method: "Download", path: it.Download}, rs[len(rs)-1])

	_, err = f.Download(context.Background(), &extsync.Item{}, 1)
	assert.Error(t, err, "an item without a download path")
}

func TestCommentsMapsInlineAndResolved(t *testing.T) {
	api := newFakeAPI(t)
	f := NewFetcher(api, testSite)
	items, err := f.Comments(context.Background(), engSpace, "1")
	require.NoError(t, err)
	require.Len(t, items, 2)
	byID := map[string]extsync.Item{}
	for _, it := range items {
		byID[it.Ref.ExtID] = it
		assert.Equal(t, "1", it.Ref.ParentID)
		assert.Equal(t, extsync.KindComment, it.Ref.Kind)
		require.Len(t, it.Sections, 1, "a comment is one section")
	}
	footer, inline := byID["100"], byID["200"]
	assert.Equal(t, "footer", footer.CommentKind)
	assert.False(t, footer.Resolved)
	assert.Empty(t, footer.AnchorText)
	assert.Equal(t, 2, footer.Ref.Version)
	assert.Equal(t, "acc-2", footer.AuthorID)
	assert.Contains(t, footer.MentionedUserIDs, "acc-3")
	assert.Contains(t, footer.Sections[0].Text, MentionPrefix+"acc-3]")

	assert.Equal(t, "inline", inline.CommentKind)
	assert.Equal(t, "before the freeze", inline.AnchorText)
	assert.True(t, inline.Resolved)
	assert.Equal(t, "Which freeze?", inline.Sections[0].Text)

	for _, p := range []string{"/wiki/api/v2/pages/1/footer-comments", "/wiki/api/v2/pages/1/inline-comments"} {
		q := api.requestsTo(p)[0].q
		assert.Equal(t, "storage", q.Get("body-format"), p)
		assert.Equal(t, "100", q.Get("limit"), p)
	}
	assert.ElementsMatch(t, []string{"open", "reopened", "resolved", "dangling"},
		api.requestsTo("/wiki/api/v2/pages/1/inline-comments")[0].q["resolution-status"])
}

func TestCommentsIncludesRepliesAtAnyDepth(t *testing.T) {
	api := newFakeAPI(t)
	api.withReplies()
	f := NewFetcher(api, testSite)
	items, err := f.Comments(context.Background(), engSpace, "1")
	require.NoError(t, err)
	byID := map[string]extsync.Item{}
	for _, it := range items {
		byID[it.Ref.ExtID] = it
	}
	require.Len(t, byID, 5)
	assert.Equal(t, "footer", byID["102"].CommentKind, "third level keeps its root's kind")
	assert.Equal(t, 4, byID["102"].Ref.Version)
	assert.Equal(t, "1", byID["102"].Ref.ParentID)
	reply := byID["201"]
	assert.Equal(t, "inline", reply.CommentKind)
	assert.Equal(t, "before the freeze", reply.AnchorText, "a reply inherits its thread's anchor")
	assert.True(t, reply.Resolved, "a reply inherits its thread's resolution")
}

// The engine contract: every comment Changed(KindComment) lists for a page
// is returned by Comments() for that page, with the same Version, and every
// CommentKind is footer or inline.
func TestChangedCommentsAgreeWithComments(t *testing.T) {
	api := newFakeAPI(t)
	api.withReplies()
	f := NewFetcher(api, testSite)
	ctx := context.Background()
	refs, next, err := f.Changed(ctx, engSpace, extsync.KindComment, time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC), "")
	require.NoError(t, err)
	assert.Empty(t, next)
	require.Len(t, refs, 5, "the comment on an attachment is not listed: Comments() never returns it")

	sets := map[string]map[string]extsync.Item{}
	for _, r := range refs {
		assert.Equal(t, extsync.KindComment, r.Kind)
		require.NotEmpty(t, r.ParentID)
		if sets[r.ParentID] == nil {
			items, err := f.Comments(ctx, engSpace, r.ParentID)
			require.NoError(t, err)
			sets[r.ParentID] = map[string]extsync.Item{}
			for _, it := range items {
				sets[r.ParentID][it.Ref.ExtID] = it
				assert.Contains(t, []string{"footer", "inline"}, it.CommentKind)
			}
		}
		it, ok := sets[r.ParentID][r.ExtID]
		require.True(t, ok, "comment %s listed by Changed but not by Comments", r.ExtID)
		assert.Equal(t, r.Version, it.Ref.Version, r.ExtID)
		assert.Equal(t, r.ParentID, it.Ref.ParentID, r.ExtID)
	}
	assert.Empty(t, api.requestsTo("/wiki/rest/api/content/search")[1:],
		"the parent kind was learned from the listing, no lookup call")

	// The comment reconcile deletes every stored comment All(KindComment)
	// does not list, and Comments() is what wrote them: All must list each
	// with the same id, version and parent.
	all, next, err := f.All(ctx, engSpace, extsync.KindComment, "")
	require.NoError(t, err)
	assert.Empty(t, next)
	assert.ElementsMatch(t, refs, all)

	// The reverse, which the reconcile depends on: every comment Comments()
	// returns — over every page and blog post of the space, not only the
	// parents listed above — is in All(KindComment) with the same version
	// and parent, or the reconcile would delete a live comment it wrote.
	listed := map[string]extsync.ItemRef{}
	for _, r := range all {
		listed[r.ExtID] = r
	}
	parents := map[string]bool{}
	for _, r := range refs {
		parents[r.ParentID] = true
	}
	for page := ""; ; {
		docs, nextPage, err := f.All(ctx, engSpace, extsync.KindPage, page)
		require.NoError(t, err)
		for _, d := range docs {
			parents[d.ExtID] = true
		}
		if nextPage == "" {
			break
		}
		page = nextPage
	}
	written := 0
	for parent := range parents {
		items, err := f.Comments(ctx, engSpace, parent)
		require.NoError(t, err)
		for _, it := range items {
			written++
			r, ok := listed[it.Ref.ExtID]
			require.True(t, ok, "comment %s returned by Comments(%s) but not listed by All", it.Ref.ExtID, parent)
			assert.Equal(t, it.Ref.Version, r.Version, it.Ref.ExtID)
			assert.Equal(t, parent, r.ParentID, it.Ref.ExtID)
		}
	}
	assert.Equal(t, len(all), written, "Comments() over every parent returns exactly the listed set")
}

func footerComment(id string) map[string]any {
	return map[string]any{"id": id, "status": "current",
		"version": map[string]any{"number": 1, "createdAt": "2026-09-01T16:00:00.000Z", "authorId": "acc-2"},
		"body":    map[string]any{"storage": map[string]string{"value": "<p>r</p>"}}}
}

func childrenOf(ids ...string) func(url.Values) any {
	return func(url.Values) any {
		results := []any{}
		for _, id := range ids {
			results = append(results, footerComment(id))
		}
		return map[string]any{"results": results}
	}
}

// A reply listing that names a comment already walked (here: a comment
// listed as its own child) is an error, never a further recursion.
func TestCommentsSelfReferencingReplyIsAnError(t *testing.T) {
	api := newFakeAPI(t)
	api.prepend(route{path: "/wiki/api/v2/footer-comments/100/children", match: anyQuery, gen: childrenOf("100")})
	items, err := NewFetcher(api, testSite).Comments(context.Background(), engSpace, "1")
	assert.ErrorContains(t, err, "listed twice")
	assert.Nil(t, items)
	assert.Len(t, api.requestsTo("/wiki/api/v2/footer-comments/100/children"), 1, "the cycle is not followed")
}

// A reply chain deeper than maxReplyDepth is an error; a chain exactly at the
// cap is walked in full.
func TestCommentsReplyDepthIsCapped(t *testing.T) {
	chain := func(levels int) *fakeAPI {
		api := newFakeAPI(t)
		prev := "100"
		for i := 1; i <= levels; i++ {
			id := fmt.Sprintf("c%d", i)
			api.prepend(route{path: "/wiki/api/v2/footer-comments/" + prev + "/children", match: anyQuery, gen: childrenOf(id)})
			prev = id
		}
		api.prepend(route{path: "/wiki/api/v2/footer-comments/" + prev + "/children", match: anyQuery, fixture: "comments_empty.json"})
		return api
	}

	items, err := NewFetcher(chain(maxReplyDepth), testSite).Comments(context.Background(), engSpace, "1")
	require.NoError(t, err)
	assert.Len(t, items, maxReplyDepth+2, "root + the whole chain + the inline comment")

	api := chain(maxReplyDepth + 1)
	items, err = NewFetcher(api, testSite).Comments(context.Background(), engSpace, "1")
	assert.ErrorContains(t, err, "nested deeper than 50")
	assert.Nil(t, items)
	deepest := fmt.Sprintf("/wiki/api/v2/footer-comments/c%d/children", maxReplyDepth+1)
	assert.Empty(t, api.requestsTo(deepest), "no listing past the cap")
}

func TestCommentsResolvesUnknownParentKind(t *testing.T) {
	api := newFakeAPI(t)
	f := NewFetcher(api, testSite)
	items, err := f.Comments(context.Background(), engSpace, "2")
	require.NoError(t, err)
	assert.Empty(t, items)
	lookups := api.requestsTo("/wiki/rest/api/content/search")
	require.Len(t, lookups, 1)
	assert.Equal(t, "id = 2", lookups[0].q.Get("cql"))
	assert.Len(t, api.requestsTo("/wiki/api/v2/blogposts/2/footer-comments"), 1, "a blog post's comments come from /blogposts")
	assert.Empty(t, api.requestsTo("/wiki/api/v2/pages/2/footer-comments"))

	items, err = f.Comments(context.Background(), engSpace, "777")
	require.NoError(t, err)
	assert.Nil(t, items, "a parent search no longer finds has no comments")
}

func TestCommentsPaginatesByCursor(t *testing.T) {
	api := newFakeAPI(t)
	api.prepend(
		route{path: "/wiki/api/v2/pages/1/footer-comments", match: noCursor, gen: func(url.Values) any {
			return map[string]any{"results": []any{}, "_links": map[string]string{
				"next": "/wiki/api/v2/pages/1/footer-comments?cursor=fc2&limit=100"}}
		}},
		route{path: "/wiki/api/v2/pages/1/footer-comments", match: cursorIs("fc2"), fixture: "comments_footer_1.json"},
	)
	f := NewFetcher(api, testSite)
	items, err := f.Comments(context.Background(), engSpace, "1")
	require.NoError(t, err)
	assert.Len(t, items, 2)
	assert.Len(t, api.requestsTo("/wiki/api/v2/pages/1/footer-comments"), 2)
}

func TestAllPagesIncludesArchivedAndBlogposts(t *testing.T) {
	api := newFakeAPI(t)
	f := NewFetcher(api, testSite)
	ctx := context.Background()
	var all []extsync.ItemRef
	token, tokens := "", []string{}
	for {
		refs, next, err := f.All(ctx, engSpace, extsync.KindPage, token)
		require.NoError(t, err)
		all = append(all, refs...)
		if next == "" {
			break
		}
		tokens = append(tokens, next)
		token = next
		require.Less(t, len(tokens), 10)
	}
	assert.Equal(t, []string{"p:pc2", "b:"}, tokens)
	ids := map[string]extsync.ItemRef{}
	for _, r := range all {
		ids[r.ExtID] = r
	}
	assert.Len(t, ids, 4)
	assert.Equal(t, extsync.KindPage, ids["6"].Kind, "archived page is enumerated")
	assert.NotContains(t, ids, "7", "trashed page is not")
	assert.Equal(t, extsync.KindBlogpost, ids["2"].Kind)
	assert.Equal(t, 3, ids["1"].Version)

	pq := api.requestsTo("/wiki/api/v2/spaces/10/pages")[0].q
	assert.Equal(t, []string{"current", "archived"}, pq["status"])
	assert.Equal(t, "all", pq.Get("depth"))
	assert.Equal(t, "100", pq.Get("limit"))

	_, _, err := f.All(ctx, engSpace, extsync.KindPage, "x:bogus")
	assert.Error(t, err, "a malformed token")
	_, _, err = f.All(ctx, extsync.Container{Key: "ENG"}, extsync.KindPage, "")
	assert.Error(t, err, "no space id")
}

// All and Changed agree on visibility: every ref Changed lists is also
// enumerated by All, with the same version, so the daily reconcile never
// deletes something the delta just wrote. Trashed is excluded from both.
func TestAllCoversChanged(t *testing.T) {
	api := newFakeAPI(t)
	f := NewFetcher(api, testSite)
	ctx := context.Background()
	collect := func(list func(page string) ([]extsync.ItemRef, string, error)) map[string]extsync.ItemRef {
		out := map[string]extsync.ItemRef{}
		page := ""
		for {
			refs, next, err := list(page)
			require.NoError(t, err)
			for _, r := range refs {
				out[r.ExtID] = r
			}
			if next == "" {
				return out
			}
			page = next
		}
	}
	for _, kind := range []extsync.ItemKind{extsync.KindPage, extsync.KindAttachment} {
		changed := collect(func(p string) ([]extsync.ItemRef, string, error) {
			return f.Changed(ctx, engSpace, kind, time.Time{}, p)
		})
		all := collect(func(p string) ([]extsync.ItemRef, string, error) { return f.All(ctx, engSpace, kind, p) })
		require.NotEmpty(t, changed)
		for id, r := range changed {
			a, ok := all[id]
			require.True(t, ok, "%s %s listed by Changed but not by All", kind, id)
			assert.Equal(t, r.Version, a.Version)
			assert.Equal(t, r.Kind, a.Kind)
		}
		assert.NotContains(t, changed, "9", "trashed")
	}
}

func TestContainersPaginates(t *testing.T) {
	api := newFakeAPI(t)
	f := NewFetcher(api, testSite)
	cs, err := f.Containers(context.Background())
	require.NoError(t, err)
	assert.Equal(t, []extsync.Container{
		{Key: "ENG", Name: "Engineering", ExtID: "10"},
		{Key: "OPS", Name: "Operations", ExtID: "20"},
	}, cs)
	rs := api.requestsTo("/wiki/api/v2/spaces")
	require.Len(t, rs, 2)
	assert.Equal(t, "250", rs[0].q.Get("limit"))
	assert.Equal(t, "sp2", rs[1].q.Get("cursor"))
}

func TestUsersMapsNames(t *testing.T) {
	api := newFakeAPI(t)
	f := NewFetcher(api, testSite)
	users, err := f.Users(context.Background(), []string{"acc-1", "acc-2"})
	require.NoError(t, err)
	assert.Equal(t, map[string]extsync.User{
		"acc-1": {ID: "acc-1", DisplayName: "Ann", Email: "ann@example.com"},
		"acc-2": {ID: "acc-2", DisplayName: "Bob Stone"},
	}, users)
	assert.Equal(t, []string{"acc-1", "acc-2"}, api.lastQuery()["accountId"])

	users, err = f.Users(context.Background(), nil)
	require.NoError(t, err)
	assert.Empty(t, users)
}

func TestUsersBatchesBy100(t *testing.T) {
	api := newFakeAPI(t)
	api.prepend(route{path: "/wiki/rest/api/user/bulk", match: anyQuery, gen: func(q url.Values) any {
		var results []map[string]string
		for _, id := range q["accountId"] {
			results = append(results, map[string]string{"accountId": id, "displayName": "U " + id})
		}
		return map[string]any{"results": results}
	}})
	f := NewFetcher(api, testSite)
	ids := make([]string, 150)
	for i := range ids {
		ids[i] = fmt.Sprintf("acc-%03d", i)
	}
	users, err := f.Users(context.Background(), ids)
	require.NoError(t, err)
	reqs := api.requestsTo("/wiki/rest/api/user/bulk")
	require.Len(t, reqs, 2)
	assert.Len(t, reqs[0].q["accountId"], 100)
	assert.Len(t, reqs[1].q["accountId"], 50)
	assert.Len(t, users, 150)
	assert.Equal(t, extsync.User{ID: "acc-149", DisplayName: "U acc-149"}, users["acc-149"])
}

func TestMapErr(t *testing.T) {
	scope403 := &jira.HTTPStatusError{Status: 403, Body: `{"message":"Unauthorized; SCOPE does not match"}`}
	plain403 := &jira.HTTPStatusError{Status: 403, Body: `{"message":"forbidden"}`}
	scope401 := &jira.HTTPStatusError{Status: 401, Body: `{"code":401,"message":"Unauthorized; scope does not match"}`}
	plain401 := &jira.HTTPStatusError{Status: 401, Body: `{"message":"Unauthorized"}`}
	nf := &jira.HTTPStatusError{Status: 404, Body: "not found"}
	other := errors.New("boom")
	cases := []struct {
		name                    string
		in                      error
		revoked, consent, is404 bool
	}{
		{"revoked", fmt.Errorf("refresh: %w", jira.ErrAuthRevoked), true, false, false},
		{"403 naming a scope", scope403, false, true, false},
		{"401 naming a scope", scope401, false, true, false},
		{"plain 401", plain401, false, false, false},
		{"plain 403", plain403, false, false, false},
		{"404", nf, false, false, true},
		{"other", other, false, false, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := mapErr(tc.in)
			require.Error(t, got)
			assert.ErrorIs(t, got, tc.in, "the original error stays in the chain")
			assert.Equal(t, tc.revoked, errors.Is(got, extsync.ErrAuthRevoked))
			assert.Equal(t, tc.consent, errors.Is(got, extsync.ErrNeedsConsent))
			assert.Equal(t, tc.is404, isNotFound(got))
		})
	}
	assert.NoError(t, mapErr(nil))
}

func TestFetcherMapsErrors(t *testing.T) {
	ctx := context.Background()
	search := "/wiki/rest/api/content/search"
	cases := []struct {
		name string
		err  error
		call func(f *Fetcher) error
		want error
	}{
		{"revoked on Changed", fmt.Errorf("x: %w", jira.ErrAuthRevoked), func(f *Fetcher) error {
			_, _, err := f.Changed(ctx, engSpace, extsync.KindPage, time.Time{}, "")
			return err
		}, extsync.ErrAuthRevoked},
		{"missing scope on Fetch", &jira.HTTPStatusError{Status: 403, Body: "scope does not match"}, func(f *Fetcher) error {
			_, err := f.Fetch(ctx, engSpace, extsync.ItemRef{Kind: extsync.KindPage, ExtID: "1"})
			return err
		}, extsync.ErrNeedsConsent},
		{"revoked on Users", jira.ErrAuthRevoked, func(f *Fetcher) error {
			_, err := f.Users(ctx, []string{"a"})
			return err
		}, extsync.ErrAuthRevoked},
		{"revoked on Comments", jira.ErrAuthRevoked, func(f *Fetcher) error {
			_, err := f.Comments(ctx, engSpace, "1")
			return err
		}, extsync.ErrAuthRevoked},
		{"401 missing scope on Changed", &jira.HTTPStatusError{Status: 401, Body: "Unauthorized; scope does not match"}, func(f *Fetcher) error {
			_, _, err := f.Changed(ctx, engSpace, extsync.KindComment, time.Time{}, "")
			return err
		}, extsync.ErrNeedsConsent},
		{"missing scope on Containers", &jira.HTTPStatusError{Status: 403, Body: "scope"}, func(f *Fetcher) error {
			_, err := f.Containers(ctx)
			return err
		}, extsync.ErrNeedsConsent},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			api := newFakeAPI(t)
			for _, p := range []string{search, "/wiki/api/v2/pages/1", "/wiki/rest/api/user/bulk", "/wiki/api/v2/spaces"} {
				api.prepend(route{path: p, match: anyQuery, err: tc.err})
			}
			assert.ErrorIs(t, tc.call(NewFetcher(api, testSite)), tc.want)
		})
	}
}

// R8: a rejected pagination cursor surfaces as an error, never as an empty
// successful page (the engine drops the stored token on a failed resumed
// call).
func TestRejectedCursorIsAnError(t *testing.T) {
	for _, status := range []int{400, 404} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			api := newFakeAPI(t)
			rejected := &jira.HTTPStatusError{Status: status, Body: "invalid cursor"}
			api.prepend(
				route{path: "/wiki/rest/api/content/search", match: cursorIs("stale"), err: rejected},
				route{path: "/wiki/api/v2/spaces/10/pages", match: cursorIs("stale"), err: rejected},
				route{path: "/wiki/api/v2/pages/1/footer-comments", match: noCursor, gen: func(url.Values) any {
					return map[string]any{"results": []any{}, "_links": map[string]string{
						"next": "/wiki/api/v2/pages/1/footer-comments?cursor=stale"}}
				}},
				route{path: "/wiki/api/v2/pages/1/footer-comments", match: cursorIs("stale"), err: rejected},
			)
			f := NewFetcher(api, testSite)
			ctx := context.Background()
			refs, next, err := f.Changed(ctx, engSpace, extsync.KindPage, time.Time{}, "stale")
			assert.Error(t, err)
			assert.Empty(t, refs)
			assert.Empty(t, next)
			_, _, err = f.All(ctx, engSpace, extsync.KindAttachment, "stale")
			assert.Error(t, err)
			_, _, err = f.All(ctx, engSpace, extsync.KindPage, "p:stale")
			assert.Error(t, err)
			_, err = f.Comments(ctx, engSpace, "1")
			assert.Error(t, err)
		})
	}
}

func TestNextLinkWithoutCursorIsAnError(t *testing.T) {
	api := newFakeAPI(t)
	api.prepend(route{path: "/wiki/rest/api/content/search", match: anyQuery, gen: func(url.Values) any {
		return map[string]any{"results": []any{}, "_links": map[string]string{
			"next": "/rest/api/content/search?start=100&limit=100"}}
	}})
	_, _, err := NewFetcher(api, testSite).Changed(context.Background(), engSpace, extsync.KindPage, time.Time{}, "")
	assert.ErrorContains(t, err, "without a cursor")
}

// TestEXT01_FetcherReachesOnlyTheGETAPI — EXT-01 (read-only toward the
// source), fetcher half: the fetcher's only network dependency is the API
// seam, whose two methods are GETs on *jira.ConfluenceAPI (pinned by
// internal/jira's TestEXT01_ConfluenceAPIIsGETOnly). Every exported Fetcher
// method is exercised once and every path it requests is under /wiki/; the
// Fetcher's method set is pinned, so a new method must join this guard.
func TestEXT01_FetcherReachesOnlyTheGETAPI(t *testing.T) {
	// The API seam has exactly the two GET methods of *jira.ConfluenceAPI
	// the fetcher uses; nothing else is reachable from the fetcher.
	apiType := reflect.TypeOf((*API)(nil)).Elem()
	var names []string
	for i := 0; i < apiType.NumMethod(); i++ {
		names = append(names, apiType.Method(i).Name)
	}
	assert.Equal(t, []string{"Download", "GetJSON"}, names)
	fetcherType := reflect.TypeOf(&Fetcher{})
	var fetcherMethods []string
	for i := 0; i < fetcherType.NumMethod(); i++ {
		fetcherMethods = append(fetcherMethods, fetcherType.Method(i).Name)
	}
	assert.Equal(t, []string{"All", "Changed", "Comments", "Containers", "Download", "Fetch", "SetLogger", "Users"}, fetcherMethods,
		"a new Fetcher method must be exercised by this guard")

	api := newFakeAPI(t)
	f := NewFetcher(api, testSite)
	f.SetLogger(log.New(io.Discard, "", 0)) // diagnostics only; no network reach
	ctx := context.Background()
	_, err := f.Containers(ctx)
	require.NoError(t, err)
	_, _, err = f.Changed(ctx, engSpace, extsync.KindPage, time.Now(), "")
	require.NoError(t, err)
	_, _, err = f.All(ctx, engSpace, extsync.KindPage, "")
	require.NoError(t, err)
	_, _, err = f.All(ctx, engSpace, extsync.KindAttachment, "")
	require.NoError(t, err)
	_, err = f.Fetch(ctx, engSpace, extsync.ItemRef{Kind: extsync.KindPage, ExtID: "1"})
	require.NoError(t, err)
	att, err := f.Fetch(ctx, engSpace, extsync.ItemRef{Kind: extsync.KindAttachment, ExtID: "att3"})
	require.NoError(t, err)
	_, err = f.Comments(ctx, engSpace, "1")
	require.NoError(t, err)
	rc, err := f.Download(ctx, att, 10)
	require.NoError(t, err)
	require.NoError(t, rc.Close())
	_, err = f.Users(ctx, []string{"acc-1"})
	require.NoError(t, err)

	rs := api.requests()
	methods := map[string]bool{}
	for _, r := range rs {
		methods[r.method] = true
		assert.True(t, strings.HasPrefix(r.path, "/wiki/"), r.path)
	}
	assert.Equal(t, map[string]bool{"GetJSON": true, "Download": true}, methods)
}

func TestFetchUnsupportedKind(t *testing.T) {
	f := NewFetcher(newFakeAPI(t), testSite)
	_, err := f.Fetch(context.Background(), engSpace, extsync.ItemRef{Kind: extsync.KindComment, ExtID: "100"})
	assert.Error(t, err, "comments come from Comments(), never Fetch")
}

// TestEXT01_FetcherCannotReachPut — EXT-01, narrowed: *jira.ConfluenceAPI
// gained a write method (PutJSON, EXT-05's edit-tool path), but the sync
// engine and this fetcher must never be able to reach it. Two checks:
//  1. The confluence.API seam the fetcher depends on has no PUT-capable
//     method at all — its method set is pinned to exactly
//     {Download, GetJSON}, so a future addition to *jira.ConfluenceAPI
//     (like PutJSON itself) does not leak into this interface by accident;
//     it would have to be added here deliberately, which is exactly the
//     review point EXT-01 wants.
//  2. On the real build graph, the generic sync engine (internal/extsync)
//     still does not depend on internal/jira at all — not even indirectly
//     through some other path — so it has no way to construct a
//     *jira.ConfluenceAPI to call PutJSON on in the first place. This is
//     the same check internal/extsync's own
//     TestEXT04_EngineImportsNoLinkOrAIPackages makes; it is repeated here,
//     scoped to this task's contract, so EXT-01's guard does not silently
//     depend on EXT-04 staying green for unrelated reasons.
func TestEXT01_FetcherCannotReachPut(t *testing.T) {
	apiType := reflect.TypeOf((*API)(nil)).Elem()
	var names []string
	for i := 0; i < apiType.NumMethod(); i++ {
		names = append(names, apiType.Method(i).Name)
	}
	require.Equal(t, []string{"Download", "GetJSON"}, names,
		"the fetcher's API seam must stay GET-only even though *jira.ConfluenceAPI now has PutJSON")

	out, err := exec.Command("go", "list", "-deps", "watchtower/internal/extsync").Output()
	require.NoError(t, err)
	deps := strings.Fields(string(out))
	require.Contains(t, deps, "watchtower/internal/db", "scan floor: the dependency list must actually be read")
	for _, dep := range deps {
		assert.False(t, dep == "watchtower/internal/jira" || strings.HasPrefix(dep, "watchtower/internal/jira/"),
			"internal/extsync must not depend on internal/jira (which is where PutJSON lives)")
	}
}
