package media

import (
	"bytes"
	"context"
	"errors"
	"io"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/doclinks"
	"watchtower/internal/extsync"
)

// confFetcher is an in-memory Confluence: pages and attachments by id,
// attachment bytes, and injectable Fetch/Download failures.
type confFetcher struct {
	mu          sync.Mutex
	items       map[string]*extsync.Item
	order       []string
	blobs       map[string][]byte
	downloadErr error
	downloads   int
}

func newConfFetcher() *confFetcher {
	return &confFetcher{items: map[string]*extsync.Item{}, blobs: map[string][]byte{}}
}

func (f *confFetcher) put(it *extsync.Item) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if _, ok := f.items[it.Ref.ExtID]; !ok {
		f.order = append(f.order, it.Ref.ExtID)
	}
	f.items[it.Ref.ExtID] = it
}

func (f *confFetcher) page(id string, version int, mod time.Time, text string, refs ...extsync.MediaRef) {
	f.put(&extsync.Item{Ref: extsync.ItemRef{Kind: extsync.KindPage, ExtID: id, Version: version, Modified: mod},
		Title: "Page " + id, Status: "current", Sections: []extsync.Section{{Text: text}}, Media: refs})
}

func (f *confFetcher) attachment(id, parent, name, mediaType string, mod time.Time, data []byte) {
	f.put(&extsync.Item{Ref: extsync.ItemRef{Kind: extsync.KindAttachment, ExtID: id, Version: 1, Modified: mod, ParentID: parent},
		Title: name, Status: "current", Created: mod, Download: "/dl/" + id, MediaType: mediaType, Size: int64(len(data))})
	f.mu.Lock()
	f.blobs[id] = data
	f.mu.Unlock()
}

func (f *confFetcher) refs(kind extsync.ItemKind) []extsync.ItemRef {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []extsync.ItemRef
	for _, id := range f.order {
		r := f.items[id].Ref
		if r.Kind == kind || (kind == extsync.KindPage && r.Kind == extsync.KindBlogpost) {
			out = append(out, r)
		}
	}
	return out
}

func (f *confFetcher) Containers(context.Context) ([]extsync.Container, error) { return nil, nil }

func (f *confFetcher) Changed(_ context.Context, _ extsync.Container, kind extsync.ItemKind, _ time.Time, _ string) ([]extsync.ItemRef, string, error) {
	return f.refs(kind), "", nil
}

func (f *confFetcher) All(_ context.Context, _ extsync.Container, kind extsync.ItemKind, _ string) ([]extsync.ItemRef, string, error) {
	return f.refs(kind), "", nil
}

func (f *confFetcher) Fetch(_ context.Context, _ extsync.Container, ref extsync.ItemRef) (*extsync.Item, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	it := f.items[ref.ExtID]
	if it == nil {
		return nil, nil
	}
	cp := *it
	return &cp, nil
}

func (f *confFetcher) Comments(context.Context, extsync.Container, string) ([]extsync.Item, error) {
	return nil, nil
}

func (f *confFetcher) Download(_ context.Context, it *extsync.Item, _ int64) (io.ReadCloser, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.downloads++
	if f.downloadErr != nil {
		return nil, f.downloadErr
	}
	return io.NopCloser(bytes.NewReader(f.blobs[it.Ref.ExtID])), nil
}

func (f *confFetcher) Users(context.Context, []string) (map[string]extsync.User, error) {
	return map[string]extsync.User{}, nil
}

// confEnv is a media env with one Confluence source synced by a real
// extsync engine over a confFetcher (recorder and relink as cmd wires them).
type confEnv struct {
	*env
	src    db.ExtSource
	f      *confFetcher
	engine *extsync.Engine
}

func newConfEnv(t *testing.T) *confEnv {
	t.Helper()
	e := newEnv(t)
	acct := db.SeedTestJiraAccount(t, e.d)
	_, err := e.d.CreateExtSource("confluence", acct, "ENG", "1", "Engineering")
	require.NoError(t, err)
	srcs, err := e.d.ListExtSources("confluence")
	require.NoError(t, err)
	require.Len(t, srcs, 1)
	f := newConfFetcher()
	engine := extsync.New(e.d, extsync.Options{
		Media: ConfluenceRecorder(nil),
		Relink: func(ctx context.Context, q extsync.Queryer, ref string, texts ...string) error {
			return doclinks.LinkConfluenceDoc(ctx, q, ref, texts...)
		},
	})
	engine.SetFetcher(acct, f)
	relink := func(ctx context.Context, q extsync.Queryer, ref string, texts ...string) error {
		return doclinks.LinkConfluenceDoc(ctx, q, ref, texts...)
	}
	e.p.Openers["confluence"] = ConfluenceOpener{DB: e.d, Fetchers: map[int64]extsync.Fetcher{acct: f}}
	e.p.Resolvers = map[string]Resolver{"confluence": ConfluenceResolver{DB: e.d}}
	e.p.AfterDescribed = append(e.p.AfterDescribed, ConfluenceRelinkHook(e.d, relink))
	return &confEnv{env: e, src: srcs[0], f: f, engine: engine}
}

func (c *confEnv) sync() {
	c.t.Helper()
	_, err := c.engine.Run(context.Background())
	require.NoError(c.t, err)
}

func (c *confEnv) itemID(extID, kind, locator string) int64 {
	c.t.Helper()
	var id int64
	require.NoError(c.t, c.d.QueryRow(`SELECT id FROM media_items WHERE ext_id = ? AND kind = ? AND locator = ?`,
		extID, kind, locator).Scan(&id))
	return id
}

func (c *confEnv) jiraLinks(extID string) []string {
	c.t.Helper()
	rows, err := c.d.Query(`SELECT to_ref FROM doc_links WHERE from_kind = 'confluence' AND from_ref = ? ORDER BY to_ref`,
		"confluence:"+itoa(c.src.ID)+":"+extID)
	require.NoError(c.t, err)
	defer rows.Close()
	var out []string
	for rows.Next() {
		var s string
		require.NoError(c.t, rows.Scan(&s))
		out = append(out, s)
	}
	require.NoError(c.t, rows.Err())
	return out
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

var confMod = time.Date(2026, 10, 25, 9, 0, 0, 0, time.UTC)

var inlineChart = extsync.MediaRef{Kind: "image", Locator: "att:chart.png", Name: "chart.png", Anchor: "Results"}

func TestConfluenceResolver_CopiesAttachmentDescription(t *testing.T) {
	c := newConfEnv(t)
	c.f.page("p1", 1, confMod, "page body", inlineChart)
	c.f.attachment("a1", "p1", "chart.png", "image/png", confMod, noisePNG(t, 64, 64, 7))
	c.sync()
	inline, own := c.itemID("p1", "image", "att:chart.png"), c.itemID("a1", "image", "attachment")

	c.run() // the attachment is described; the inline image waits for it
	assert.Equal(t, "ok", c.row(own).Status)
	assert.Equal(t, "pending", c.row(inline).Status, "an inline image listed before its attachment waits")
	c.run()

	r, a := c.row(inline), c.row(own)
	assert.Equal(t, "ok", r.Status)
	assert.Equal(t, a.Body, r.Body)
	assert.Equal(t, a.ImageText, r.ImageText)
	assert.Equal(t, a.ContentKey, r.ContentKey)
	assert.Equal(t, "confluence:"+itoa(c.src.ID)+":p1", r.KBRef, "the copy renders into the page's own document")
	img, _ := c.gen.calls()
	assert.Equal(t, 1, img, "the bytes are described once")
	assert.Equal(t, 1, c.f.downloads)
}

func TestConfluenceResolver_WaitsWhilePending(t *testing.T) {
	c := newConfEnv(t)
	c.f.page("p1", 1, confMod, "page body", inlineChart)
	c.f.attachment("a1", "p1", "chart.png", "image/png", confMod, noisePNG(t, 64, 64, 7))
	c.sync()
	delete(c.p.Openers, "confluence") // the attachment cannot be opened yet
	inline, own := c.itemID("p1", "image", "att:chart.png"), c.itemID("a1", "image", "attachment")

	c.run()
	c.run()
	assert.Equal(t, "pending", c.row(own).Status)
	r := c.row(inline)
	assert.Equal(t, "pending", r.Status)
	assert.Zero(t, r.Attempts, "waiting spends no attempt")

	// An attachment not synced yet: the image waits, then ends unreachable.
	c.f.page("p2", 1, confMod, "page body", extsync.MediaRef{Kind: "image", Locator: "att:later.png", Name: "later.png"})
	c.sync()
	later := c.itemID("p2", "image", "att:later.png")
	c.run()
	assert.Equal(t, "pending", c.row(later).Status)
	c.p.Resolvers["confluence"] = ConfluenceResolver{DB: c.d, Now: func() time.Time { return time.Now().Add(25 * time.Hour) }}
	c.run()
	assert.Equal(t, "unreachable", c.row(later).Status)
	assert.Equal(t, "not_found", c.row(later).Error)
}

func TestConfluenceResolver_UnreachableWithoutAttachmentItem(t *testing.T) {
	c := newConfEnv(t)
	c.f.page("p1", 1, confMod, "page body",
		inlineChart, extsync.MediaRef{Kind: "image", Locator: "att:spec.pdf", Name: "spec.pdf"})
	// chart.png predates the start mark: its document is stored, its item is not.
	c.f.attachment("a1", "p1", "chart.png", "image/png", confMod.Add(-48*time.Hour), noisePNG(t, 64, 64, 7))
	c.f.attachment("a2", "p1", "spec.pdf", "application/pdf", confMod, []byte("%PDF-1.4 not an image"))
	require.NoError(t, c.d.SetMediaStartAt(confMod.Add(-time.Hour)))
	c.sync()
	var n int
	require.NoError(t, c.d.QueryRow(`SELECT COUNT(*) FROM media_items WHERE ext_id IN ('a1', 'a2')`).Scan(&n))
	require.Zero(t, n)

	c.run()
	for _, loc := range []string{"att:chart.png", "att:spec.pdf"} {
		r := c.row(c.itemID("p1", "image", loc))
		assert.Equal(t, "unreachable", r.Status, loc)
		assert.Equal(t, "not_found", r.Error, loc)
	}
	img, _ := c.gen.calls()
	assert.Zero(t, img)
	assert.Zero(t, c.f.downloads)
}

func TestConfluenceOpener_GoneAndFailures(t *testing.T) {
	c := newConfEnv(t)
	c.f.page("p1", 1, confMod, "page body")
	c.f.attachment("a1", "p1", "shot.png", "image/png", confMod, noisePNG(t, 64, 64, 9))
	c.f.attachment("a2", "p1", "gone.png", "image/png", confMod, noisePNG(t, 64, 64, 10))
	c.sync()
	c.f.mu.Lock()
	delete(c.f.items, "a2") // deleted upstream since the sync
	c.f.downloadErr = errors.New(`GET https://acme.example.net/wiki/download/a1?token=s3cr3t: 500 <html>boom</html>`)
	c.f.mu.Unlock()
	a1, a2 := c.itemID("a1", "image", "attachment"), c.itemID("a2", "image", "attachment")

	for range maxMediaAttempts {
		c.run()
	}
	assert.Equal(t, "unreachable", c.row(a2).Status)
	assert.Equal(t, "not_found", c.row(a2).Error)
	r := c.row(a1)
	assert.Equal(t, "failed", r.Status)
	assert.Contains(t, ErrorClasses, r.Error)
	assert.NotContains(t, c.log.String(), "s3cr3t", "the log carries the URL without its query")

	// Only the attachment's own item is opened.
	_, _, err := ConfluenceOpener{DB: c.d}.Open(context.Background(), db.MediaItem{ParentKind: "confluence", Locator: "att:x.png"}, 1)
	assert.ErrorIs(t, err, ErrGone)
}

func TestConfluenceRecorder_RefusesSitesAndDeniedHosts(t *testing.T) {
	c := newConfEnv(t)
	_, err := c.d.Exec(`UPDATE jira_accounts SET site_url = 'https://wiki.acme.example', cloud_id = 'cloud-1'`)
	require.NoError(t, err)
	c.engine = extsync.New(c.d, extsync.Options{Media: ConfluenceRecorder([]string{"intra.example.org"})})
	c.engine.SetFetcher(c.src.JiraAccountID, c.f)
	c.f.page("p1", 1, confMod, "page body",
		extsync.MediaRef{Kind: "link", Locator: "url:https://example.com/a", URL: "https://example.com/a?utm_source=x"},
		extsync.MediaRef{Kind: "link", Locator: "url:https://wiki.acme.example/x", URL: "https://wiki.acme.example/x"},
		extsync.MediaRef{Kind: "link", Locator: "url:https://docs.intra.example.org/y", URL: "https://docs.intra.example.org/y"},
		extsync.MediaRef{Kind: "image", Locator: "url:https://img.example.com/p.png", URL: "https://img.example.com/p.png"},
		inlineChart)
	c.sync()

	rows, err := c.d.Query(`SELECT kind, locator, fetch_url, content_key FROM media_items WHERE ext_id = 'p1' ORDER BY id`)
	require.NoError(t, err)
	defer rows.Close()
	var got [][4]string
	for rows.Next() {
		var r [4]string
		require.NoError(t, rows.Scan(&r[0], &r[1], &r[2], &r[3]))
		got = append(got, r)
	}
	require.NoError(t, rows.Err())
	assert.Equal(t, [][4]string{
		{"link", "url:https://example.com/a", "https://example.com/a?utm_source=x", "url:https://example.com/a"},
		{"image", "url:https://img.example.com/p.png", "https://img.example.com/p.png", ""},
		{"image", "att:chart.png", "", ""},
	}, got)
}

func TestLinkConfluenceDoc_KeepsImageKeysOnPageResync(t *testing.T) {
	c := newConfEnv(t)
	c.f.page("p1", 1, confMod, "page body without keys", inlineChart)
	c.f.attachment("a1", "p1", "chart.png", "image/png", confMod, noisePNG(t, 64, 64, 7))
	c.sync()
	assert.Empty(t, c.jiraLinks("p1"))

	c.run()
	c.run()
	assert.Equal(t, []string{"PROJ-7"}, c.jiraLinks("a1"), "the attachment's own document links the key on its image")
	assert.Equal(t, []string{"PROJ-7"}, c.jiraLinks("p1"), "the page links the key on its inline image")

	c.f.page("p1", 2, confMod.Add(time.Hour), "page body edited, still without keys", inlineChart)
	c.sync()
	assert.Equal(t, []string{"PROJ-7"}, c.jiraLinks("p1"), "a re-sync keeps the image's key")
}

func TestLinkConfluenceDoc_IgnoresLinkSummaryKeys(t *testing.T) {
	c := newConfEnv(t)
	c.f.page("p1", 1, confMod, "page body without keys",
		extsync.MediaRef{Kind: "link", Locator: "url:https://example.com/a", URL: "https://example.com/a"})
	c.sync()
	id := c.itemID("p1", "link", "url:https://example.com/a")
	require.NoError(t, c.d.FinishMedia(context.Background(), id, db.MediaResult{Status: "ok",
		Title: "Tracker ABC-1", Body: "The page says ABC-1 is blocked.", Keys: []string{"ABC-1"}}))
	it, err := c.d.MediaItemAt(context.Background(), db.MediaParent{Kind: "confluence", ExtSourceID: c.src.ID, ExtID: "p1"}.Key(),
		"link", "url:https://example.com/a")
	require.NoError(t, err)
	require.NotNil(t, it)

	for _, hook := range c.p.AfterDescribed {
		require.NoError(t, hook(context.Background(), *it))
	}
	assert.Empty(t, c.jiraLinks("p1"), "a link summary adds no key from the hook")
	c.f.page("p1", 2, confMod.Add(time.Hour), "page body edited",
		extsync.MediaRef{Kind: "link", Locator: "url:https://example.com/a", URL: "https://example.com/a"})
	c.sync()
	assert.Empty(t, c.jiraLinks("p1"), "nor on a re-sync")
}
