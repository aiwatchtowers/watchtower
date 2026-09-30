package tools

import (
	"context"
	"encoding/json"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/extsync"
	"watchtower/internal/jira"
)

// repoRoot walks up from the package directory to go.mod.
func repoRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	require.NoError(t, err)
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		require.NotEqual(t, dir, parent, "go.mod not found")
		dir = parent
	}
}

// skippedDirs are never walked: other worktrees, the Swift app, fixtures.
var skippedDirs = map[string]bool{".git": true, ".claude": true, "WatchtowerDesktop": true,
	"node_modules": true, "testdata": true, "vendor": true}

// writeCallSites lists "<file>:<enclosing func>" for every production call
// of a method named PutJSON or PutPage under the module's Go sources.
func writeCallSites(t *testing.T, root string) (sites map[string][]string, files int) {
	t.Helper()
	sites = map[string][]string{}
	err := filepath.WalkDir(root, func(path string, e fs.DirEntry, err error) error {
		switch {
		case err != nil:
			return err
		case e.IsDir() && skippedDirs[e.Name()]:
			return filepath.SkipDir
		case e.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go"):
			return nil
		}
		files++
		rel, _ := filepath.Rel(root, path)
		return collectWriteCalls(path, filepath.ToSlash(rel), sites)
	})
	require.NoError(t, err)
	return sites, files
}

// collectWriteCalls adds one file's PutJSON/PutPage call sites to sites.
func collectWriteCalls(path, rel string, sites map[string][]string) error {
	f, err := parser.ParseFile(token.NewFileSet(), path, nil, 0)
	if err != nil {
		return err
	}
	for _, decl := range f.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Body == nil {
			continue
		}
		ast.Inspect(fn.Body, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			if sel, ok := call.Fun.(*ast.SelectorExpr); ok && (sel.Sel.Name == "PutJSON" || sel.Sel.Name == "PutPage") {
				sites[sel.Sel.Name] = append(sites[sel.Sel.Name], rel+":"+fn.Name.Name)
			}
			return true
		})
	}
	return nil
}

// EXT-05: the only Confluence write path is edit_confluence_page. PutJSON
// (the one write method of *jira.ConfluenceAPI) is called only by the page
// client's PutPage, and PutPage only by the edit tool's Execute; the sync
// path cannot even import the tool package.
func TestEXT05_OnlyEditToolReachesPut(t *testing.T) {
	root := repoRoot(t)
	sites, files := writeCallSites(t, root)
	require.GreaterOrEqual(t, files, 300, "scan floor: the walk must cover the module")
	assert.Equal(t, []string{"internal/tools/confluence_page_client.go:PutPage"}, sites["PutJSON"],
		"PutJSON is called only by the page client's PutPage")
	assert.Equal(t, []string{"internal/tools/confluence_page_edit.go:executeConfluenceEdit"}, sites["PutPage"],
		"PutPage is called only by edit_confluence_page's Execute (after Approve)")

	for _, pkg := range []string{"watchtower/internal/extsync", "watchtower/internal/confluence"} {
		out, err := exec.Command("go", "list", "-deps", pkg).CombinedOutput()
		require.NoError(t, err, string(out))
		deps := strings.Fields(string(out))
		require.Contains(t, deps, "watchtower/internal/db", "scan floor for %s", pkg)
		assert.NotContains(t, deps, "watchtower/internal/tools", "%s must not reach the edit tool", pkg)
	}
}

// ---- the live client adapter ---------------------------------------------

type restCall struct {
	method, path string
	q            url.Values
	body         any
}

// fakeREST answers GETs from a path → JSON map (404 otherwise) and records
// PUTs.
type fakeREST struct {
	get   map[string]string
	put   string
	calls []restCall
}

func (f *fakeREST) GetJSON(_ context.Context, path string, q url.Values, out any) error {
	f.calls = append(f.calls, restCall{method: "GET", path: path, q: q})
	raw, ok := f.get[path]
	if !ok {
		return &jira.HTTPStatusError{Status: 404, Body: "{}"}
	}
	return json.Unmarshal([]byte(raw), out)
}

func (f *fakeREST) PutJSON(_ context.Context, path string, body, out any) error {
	f.calls = append(f.calls, restCall{method: "PUT", path: path, body: body})
	return json.Unmarshal([]byte(f.put), out)
}

type fakeCommentSource struct{ items []extsync.Item }

func (f fakeCommentSource) Comments(context.Context, extsync.Container, string) ([]extsync.Item, error) {
	return f.items, nil
}

func (f fakeCommentSource) Users(_ context.Context, ids []string) (map[string]extsync.User, error) {
	out := map[string]extsync.User{}
	for _, id := range ids {
		if id == "557058:known" {
			out[id] = extsync.User{ID: id, DisplayName: "Ann Lee"}
		}
	}
	return out, nil
}

func TestConfluencePageClient_GetFallsBackToBlogPostAndPutsItsCollection(t *testing.T) {
	rest := &fakeREST{get: map[string]string{
		"/wiki/api/v2/blogposts/42": `{"id":"42","title":"Weekly","spaceId":"7","version":{"number":3},` +
			`"body":{"storage":{"value":"<p>Hi</p>"}},"_links":{"webui":"/spaces/ENG/blog/2026/09/30/42/Weekly"}}`,
		"/wiki/api/v2/spaces/7": `{"id":"7","key":"ENG"}`,
	}, put: `{"id":"42","version":{"number":4}}`}
	c := NewConfluencePageClient(rest, fakeCommentSource{}, "https://test.atlassian.net/", true, true)

	page, err := c.GetPage(context.Background(), "42")
	require.NoError(t, err)
	assert.Equal(t, ConfluencePage{ID: "42", Kind: "blogpost", Title: "Weekly", SpaceKey: "ENG", Version: 3, Storage: "<p>Hi</p>",
		URL: "https://test.atlassian.net/wiki/spaces/ENG/blog/2026/09/30/42/Weekly"}, page)
	assert.Equal(t, "/wiki/api/v2/pages/42", rest.calls[0].path, "a page first")
	assert.Equal(t, "storage", rest.calls[0].q.Get("body-format"))

	body := ConfluencePutBody{ID: "42", Status: "current", Title: "Weekly"}
	v, err := c.PutPage(context.Background(), "42", page.Kind, body)
	require.NoError(t, err)
	assert.Equal(t, 4, v)
	last := rest.calls[len(rest.calls)-1]
	assert.Equal(t, restCall{method: "PUT", path: "/wiki/api/v2/blogposts/42", body: body}, last)

	_, err = c.GetPage(context.Background(), "404")
	assert.ErrorIs(t, err, errConfluencePageNotFound)
	assert.True(t, c.HasWriteScopes())
}

func TestConfluencePageClient_MapsCommentsAndUsers(t *testing.T) {
	when := time.Date(2026, 9, 30, 9, 0, 0, 0, time.UTC)
	src := fakeCommentSource{items: []extsync.Item{
		{Ref: extsync.ItemRef{ExtID: "5"}, AuthorID: "557058:known", Created: when, CommentKind: "inline", AnchorText: "the day",
			Resolved: true, Sections: []extsync.Section{{Text: "Why Friday?"}}, MentionedUserIDs: []string{"557058:other"}},
		{Ref: extsync.ItemRef{ExtID: "6"}, ReplyTo: "5", CommentKind: "inline", Sections: []extsync.Section{{Text: "Moved."}}},
	}}
	c := NewConfluencePageClient(&fakeREST{}, src, "https://test.atlassian.net", true, false)
	got, err := c.Comments(context.Background(), "1")
	require.NoError(t, err)
	assert.Equal(t, []ConfluenceComment{
		{ID: "5", AuthorID: "557058:known", Created: when, Kind: "inline", AnchorText: "the day", Resolved: true, Body: "Why Friday?", MentionedUserIDs: []string{"557058:other"}},
		{ID: "6", ReplyTo: "5", Kind: "inline", Body: "Moved."},
	}, got)
	names, err := c.Users(context.Background(), []string{"557058:known", "557058:other"})
	require.NoError(t, err)
	assert.Equal(t, map[string]string{"557058:known": "Ann Lee"}, names)
	assert.False(t, c.HasWriteScopes())
}
