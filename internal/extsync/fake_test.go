package extsync

import (
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
	mu       sync.Mutex
	docs     map[ItemKind][]fakeDoc
	pageSize int
	fetches  map[string]int
}

func newFake() *fakeFetcher {
	return &fakeFetcher{docs: map[ItemKind][]fakeDoc{}, pageSize: 2, fetches: map[string]int{}}
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
	return []Container{{Key: "ENG", Name: "Engineering", ExtID: "1"}}, nil
}

func (f *fakeFetcher) Changed(_ context.Context, _ Container, kind ItemKind, since time.Time, page string) ([]ItemRef, string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	var refs []ItemRef
	for _, k := range f.kinds(kind) {
		for _, d := range f.docs[k] {
			if !d.ref.Modified.Before(since) {
				refs = append(refs, d.ref)
			}
		}
	}
	sort.SliceStable(refs, func(i, j int) bool { return refs[i].Modified.Before(refs[j].Modified) })
	return f.paginate(refs, page)
}

func (f *fakeFetcher) All(_ context.Context, _ Container, kind ItemKind, page string) ([]ItemRef, string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	var refs []ItemRef
	for _, k := range f.kinds(kind) {
		for _, d := range f.docs[k] {
			refs = append(refs, d.ref)
		}
	}
	return f.paginate(refs, page)
}

func (f *fakeFetcher) Fetch(_ context.Context, _ Container, ref ItemRef) (*Item, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.fetches[ref.ExtID]++
	d := f.find(ref.ExtID)
	if d == nil || d.item == nil {
		return nil, nil
	}
	it := *d.item
	return &it, nil
}

func (f *fakeFetcher) Comments(context.Context, Container, string) ([]Item, error) {
	return nil, nil
}

func (f *fakeFetcher) Download(context.Context, *Item, int64) (io.ReadCloser, error) {
	return nil, fmt.Errorf("fake: no downloads")
}

func (f *fakeFetcher) Users(context.Context, []string) (map[string]User, error) {
	return map[string]User{}, nil
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

func countDocs(t *testing.T, d *db.DB, sourceID int64) int {
	t.Helper()
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM ext_documents WHERE source_id = ?`, sourceID).Scan(&n); err != nil {
		t.Fatalf("counting docs: %v", err)
	}
	return n
}
