package extsync

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"sort"
	"strconv"
	"sync"
	"testing"
	"time"

	"watchtower/internal/db"
)

// TestMain installs the db schema template cache before running tests (the
// internal/kb precedent): without it every in-memory db re-runs the whole
// goose suite, which under -race is very slow.
func TestMain(m *testing.M) {
	if err := db.InitTestTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}

type fakeDoc struct {
	ref  ItemRef
	item *Item // nil = gone (still listed by Changed, Fetch returns nil)
}

// fakeFetcher is an in-memory Fetcher. Changed(KindPage) enumerates pages and
// blogposts together, like the Confluence CQL does.
type fakeFetcher struct {
	mu           sync.Mutex
	docs         map[ItemKind][]fakeDoc // comments live under KindComment, ref.ParentID = page
	pageSize     int
	fetches      map[string]int
	calls        []changedCall // every non-comment Changed call, in order
	commentCalls []changedCall // every Changed(KindComment) call, in order
	allCalls     map[ItemKind]int
	userCalls    [][]string
	hidden       map[string]bool // absent from All (moved/restricted), still Fetchable
	netCalls     int             // every Fetcher call
	failNext     error           // the next Fetcher call fails with it
	failAll      map[ItemKind]error
	failAllPage  map[ItemKind]string // All(kind) fails when asked for this page token (a partial enumeration)
	attachCalls  []changedCall       // every Changed(KindAttachment) call, in order
	blobs        map[string][]byte   // attachment bytes by id
	downloadErr  map[string]error    // Download fails with it
	readErr      map[string]error    // a Read of the body fails with it after the bytes
	downloads    map[string]int      // Download calls by id
	onFetch      func()              // called on every Fetch
	containers   []Container         // Containers' answer (nil = the one ENG space)
	allKeys      []string            // the container key of every All call
}

// hit counts one Fetcher call and returns the injected failure, if any.
// Callers hold f.mu.
func (f *fakeFetcher) hit() error {
	f.netCalls++
	err := f.failNext
	f.failNext = nil
	return err
}

// failWith makes the next Fetcher call fail with err.
func (f *fakeFetcher) failWith(err error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.failNext = err
}

// removeFromAll hides id from All (moved to another space, or restricted):
// Changed never lists it again either, since it did not change.
func (f *fakeFetcher) removeFromAll(id string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.hidden[id] = true
}

// restoreToAll lists id in All again (a restriction lifted, a restore from
// the trash) without a new version: Changed still does not list it unless
// its modification time falls inside the pass.
func (f *fakeFetcher) restoreToAll(id string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.hidden, id)
}

// addComment adds a footer comment on pageID; Changed(KindComment) lists it
// and Comments(pageID) returns it.
func (f *fakeFetcher) addComment(id, pageID string, version int, modified time.Time, text string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	ref := ItemRef{Kind: KindComment, ExtID: id, Version: version, Modified: modified, ParentID: pageID}
	f.docs[KindComment] = append(f.docs[KindComment], fakeDoc{ref: ref, item: &Item{
		Ref:         ref,
		AuthorID:    "author-" + id,
		Created:     modified,
		CommentKind: "footer",
		Sections:    []Section{{Text: text}},
	}})
}

// deleteComment deletes comment id upstream: All and Comments no longer
// list it, and — its page's version unchanged — Changed never lists it.
func (f *fakeFetcher) deleteComment(id string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.hidden[id] = true
	f.find(id).item = nil
}

// setAuthor sets the author of document id.
func (f *fakeFetcher) setAuthor(id, author string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.find(id).item.AuthorID = author
}

// counts returns copies of the recorded All and Users calls.
func (f *fakeFetcher) counts() (map[ItemKind]int, [][]string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	all := map[ItemKind]int{}
	for k, n := range f.allCalls {
		all[k] = n
	}
	return all, append([][]string(nil), f.userCalls...)
}

// changedCall records one Changed call's since and page token.
type changedCall struct {
	since time.Time
	page  string
}

// maxChangedCalls turns a runaway enumeration loop into an error instead of
// a hung test.
const maxChangedCalls = 100

// resetCalls clears the recorded Changed calls.
func (f *fakeFetcher) resetCalls() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = nil
	f.commentCalls = nil
	f.attachCalls = nil
}

// changedCalls returns a copy of the recorded Changed calls.
func (f *fakeFetcher) changedCalls() []changedCall {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]changedCall(nil), f.calls...)
}

func newFake() *fakeFetcher {
	return &fakeFetcher{docs: map[ItemKind][]fakeDoc{}, pageSize: 2, fetches: map[string]int{},
		allCalls: map[ItemKind]int{}, hidden: map[string]bool{}, blobs: map[string][]byte{},
		downloadErr: map[string]error{}, readErr: map[string]error{}, downloads: map[string]int{}}
}

func (f *fakeFetcher) add(kind ItemKind, id string, version int, modified time.Time) {
	f.mu.Lock()
	defer f.mu.Unlock()
	ref := ItemRef{Kind: kind, ExtID: id, Version: version, Modified: modified}
	f.docs[kind] = append(f.docs[kind], fakeDoc{ref: ref, item: &Item{
		Ref:      ref,
		Title:    "Title " + id,
		URL:      "https://example.test/" + id,
		Status:   "current",
		Sections: []Section{{Heading: "H", Text: "body of " + id}},
		Meta:     map[string]string{"space": "ENG"},
	}})
}

func (f *fakeFetcher) addPage(id string, version int, modified time.Time) {
	f.add(KindPage, id, version, modified)
}

func (f *fakeFetcher) addBlog(id string, version int, modified time.Time) {
	f.add(KindBlogpost, id, version, modified)
}

// find returns a pointer to the doc with id, or nil. Callers hold f.mu.
func (f *fakeFetcher) find(id string) *fakeDoc {
	for _, docs := range f.docs {
		for i := range docs {
			if docs[i].ref.ExtID == id {
				return &docs[i]
			}
		}
	}
	return nil
}

// mutate records a new version of id at modified.
func (f *fakeFetcher) mutate(id string, version int, modified time.Time) {
	f.mu.Lock()
	defer f.mu.Unlock()
	d := f.find(id)
	d.ref.Version, d.ref.Modified = version, modified
	if d.item != nil {
		d.item.Ref = d.ref
	}
}

// markGone keeps id listed by Changed but makes Fetch report it gone.
func (f *fakeFetcher) markGone(id string, version int, modified time.Time) {
	f.mutate(id, version, modified)
	f.mu.Lock()
	defer f.mu.Unlock()
	f.find(id).item = nil
}

func (f *fakeFetcher) kinds(kind ItemKind) []ItemKind {
	if kind == KindPage {
		return []ItemKind{KindPage, KindBlogpost}
	}
	return []ItemKind{kind}
}

// paginate serves one page of refs; the token is the next index.
func (f *fakeFetcher) paginate(refs []ItemRef, page string) ([]ItemRef, string, error) {
	start := 0
	if page != "" {
		n, err := strconv.Atoi(page)
		if err != nil {
			return nil, "", fmt.Errorf("fake: bad token %q", page)
		}
		start = min(n, len(refs))
	}
	end := min(start+f.pageSize, len(refs))
	next := ""
	if end < len(refs) {
		next = strconv.Itoa(end)
	}
	return refs[start:end], next, nil
}

func (f *fakeFetcher) Containers(context.Context) ([]Container, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.hit(); err != nil {
		return nil, err
	}
	if f.containers != nil {
		return append([]Container(nil), f.containers...), nil
	}
	return []Container{{Key: "ENG", Name: "Engineering", ExtID: "1"}}, nil
}

func (f *fakeFetcher) Changed(_ context.Context, _ Container, kind ItemKind, since time.Time, page string) ([]ItemRef, string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.hit(); err != nil {
		return nil, "", err
	}
	call := changedCall{since: since, page: page}
	switch kind {
	case KindComment:
		f.commentCalls = append(f.commentCalls, call)
	case KindAttachment:
		f.attachCalls = append(f.attachCalls, call)
	default:
		f.calls = append(f.calls, call)
	}
	if n := len(f.calls) + len(f.commentCalls) + len(f.attachCalls); n > maxChangedCalls {
		return nil, "", fmt.Errorf("fake: runaway enumeration (%d Changed calls)", n)
	}
	var refs []ItemRef
	for _, k := range f.kinds(kind) {
		for _, d := range f.docs[k] {
			if !d.ref.Modified.Before(since) && !f.hidden[d.ref.ExtID] {
				refs = append(refs, d.ref)
			}
		}
	}
	sort.SliceStable(refs, func(i, j int) bool { return refs[i].Modified.Before(refs[j].Modified) })
	return f.paginate(refs, page)
}

func (f *fakeFetcher) All(_ context.Context, c Container, kind ItemKind, page string) ([]ItemRef, string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.hit(); err != nil {
		return nil, "", err
	}
	f.allCalls[kind]++
	f.allKeys = append(f.allKeys, c.Key)
	if err := f.failAll[kind]; err != nil {
		return nil, "", err
	}
	if tok, ok := f.failAllPage[kind]; ok && tok == page {
		return nil, "", fmt.Errorf("fake: All(%s) failed at page %q", kind, page)
	}
	var refs []ItemRef
	for _, k := range f.kinds(kind) {
		for _, d := range f.docs[k] {
			if !f.hidden[d.ref.ExtID] {
				refs = append(refs, d.ref)
			}
		}
	}
	return f.paginate(refs, page)
}

func (f *fakeFetcher) Fetch(_ context.Context, _ Container, ref ItemRef) (*Item, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.hit(); err != nil {
		return nil, err
	}
	f.fetches[ref.ExtID]++
	if f.onFetch != nil {
		f.onFetch()
	}
	d := f.find(ref.ExtID)
	if d == nil || d.item == nil {
		return nil, nil
	}
	it := *d.item
	return &it, nil
}

func (f *fakeFetcher) Comments(_ context.Context, _ Container, pageID string) ([]Item, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.hit(); err != nil {
		return nil, err
	}
	var out []Item
	for _, d := range f.docs[KindComment] {
		if d.ref.ParentID == pageID && d.item != nil {
			out = append(out, *d.item)
		}
	}
	return out, nil
}

func (f *fakeFetcher) Download(_ context.Context, it *Item, limit int64) (io.ReadCloser, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.hit(); err != nil {
		return nil, err
	}
	id := it.Ref.ExtID
	f.downloads[id]++
	if err := f.downloadErr[id]; err != nil {
		return nil, err
	}
	b, ok := f.blobs[id]
	if !ok {
		return nil, fmt.Errorf("fake: no bytes for %s", id)
	}
	if int64(len(b)) > limit {
		return nil, fmt.Errorf("fake: %w", ErrTooLarge)
	}
	var r io.Reader = bytes.NewReader(b)
	if err := f.readErr[id]; err != nil {
		r = io.MultiReader(r, errReader{err})
	}
	return io.NopCloser(r), nil
}

// errReader fails every Read with err.
type errReader struct{ err error }

func (r errReader) Read([]byte) (int, error) { return 0, r.err }

// addAttachment adds an attachment of parent with its bytes; Size is
// len(data) unless size >= 0 overrides it.
func (f *fakeFetcher) addAttachment(id, parent string, version int, modified time.Time, name, mediaType string, data []byte, size int64) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if size < 0 {
		size = int64(len(data))
	}
	ref := ItemRef{Kind: KindAttachment, ExtID: id, Version: version, Modified: modified, ParentID: parent}
	f.docs[KindAttachment] = append(f.docs[KindAttachment], fakeDoc{ref: ref, item: &Item{
		Ref:       ref,
		Title:     name,
		URL:       "https://example.test/att/" + id,
		Status:    "current",
		AuthorID:  "uploader-" + id,
		Meta:      map[string]string{"space": "ENG"},
		Download:  "/download/" + id,
		MediaType: mediaType,
		Size:      size,
	}})
	f.blobs[id] = data
}

// downloadCount returns how often id was downloaded.
func (f *fakeFetcher) downloadCount(id string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.downloads[id]
}

// fetchCount returns how often id was fetched.
func (f *fakeFetcher) fetchCount(id string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.fetches[id]
}

func (f *fakeFetcher) Users(_ context.Context, ids []string) (map[string]User, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.hit(); err != nil {
		return nil, err
	}
	f.userCalls = append(f.userCalls, append([]string(nil), ids...))
	out := make(map[string]User, len(ids))
	for _, id := range ids {
		out[id] = User{ID: id, DisplayName: "Name " + id, Email: id + "@example.test"}
	}
	return out, nil
}

// stepClock returns its time and then advances it by step on every Now call.
type stepClock struct {
	mu   sync.Mutex
	t    time.Time
	step time.Duration
}

func (c *stepClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.t
	c.t = c.t.Add(c.step)
	return now
}

// newSourceDB opens a test db with one Jira account and one enabled
// Confluence source "ENG".
func newSourceDB(t *testing.T) (*db.DB, db.ExtSource) {
	t.Helper()
	d := db.OpenTestDB(t)
	acct := db.SeedTestJiraAccount(t, d)
	if _, err := d.CreateExtSource("confluence", acct, "ENG", "1", "Engineering"); err != nil {
		t.Fatalf("creating ext source: %v", err)
	}
	srcs, err := d.ListExtSources("confluence")
	if err != nil || len(srcs) != 1 {
		t.Fatalf("listing ext sources: %v (%d rows)", err, len(srcs))
	}
	return d, srcs[0]
}

// loadSource returns the (single) confluence source as stored now.
func loadSource(t *testing.T, d *db.DB) db.ExtSource {
	t.Helper()
	srcs, err := d.ListExtSources("confluence")
	if err != nil || len(srcs) != 1 {
		t.Fatalf("listing ext sources: %v (%d rows)", err, len(srcs))
	}
	return srcs[0]
}

func countDocs(t *testing.T, d *db.DB, sourceID int64) int {
	t.Helper()
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM ext_documents WHERE source_id = ?`, sourceID).Scan(&n); err != nil {
		t.Fatalf("counting docs: %v", err)
	}
	return n
}
