package extsync_test

import (
	"bytes"
	"context"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/extract"
	"watchtower/internal/extsync"
	"watchtower/internal/kb"
)

// ext03Fetcher serves one page with a PDF and a PNG attachment. It lives in
// the external test package so the guard can drive the real
// extract.Extractor (extsync itself must not import internal/extract).
type ext03Fetcher struct {
	blobs map[string][]byte
	refs  []extsync.ItemRef
	items map[string]*extsync.Item
}

func newExt03Fetcher(t *testing.T) *ext03Fetcher {
	t.Helper()
	mod := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	f := &ext03Fetcher{blobs: map[string][]byte{}, items: map[string]*extsync.Item{}}
	add := func(kind extsync.ItemKind, id, parent, title, mediaType string, data []byte) {
		ref := extsync.ItemRef{Kind: kind, ExtID: id, Version: 1, Modified: mod, ParentID: parent}
		f.refs = append(f.refs, ref)
		f.items[id] = &extsync.Item{Ref: ref, Title: title, Status: "current", MediaType: mediaType,
			Size: int64(len(data)), Download: "/dl/" + id, Sections: []extsync.Section{{Text: "page body"}}}
		f.blobs[id] = data
	}
	add(extsync.KindPage, "p1", "", "Page", "", nil)
	add(extsync.KindAttachment, "a-pdf", "p1", "mixed.pdf", "application/pdf", readFixture(t, "mixed.pdf"))
	add(extsync.KindAttachment, "a-png", "p1", "sample.png", "image/png", readFixture(t, "sample.png"))
	f.items["a-pdf"].Sections, f.items["a-png"].Sections = nil, nil
	return f
}

func readFixture(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "extract", "testdata", name))
	require.NoError(t, err)
	return b
}

func (f *ext03Fetcher) of(kind extsync.ItemKind) []extsync.ItemRef {
	var out []extsync.ItemRef
	for _, r := range f.refs {
		if r.Kind == kind {
			out = append(out, r)
		}
	}
	return out
}

func (f *ext03Fetcher) Containers(context.Context) ([]extsync.Container, error) { return nil, nil }

func (f *ext03Fetcher) Changed(_ context.Context, _ extsync.Container, kind extsync.ItemKind, _ time.Time, _ string) ([]extsync.ItemRef, string, error) {
	return f.of(kind), "", nil
}

func (f *ext03Fetcher) All(_ context.Context, _ extsync.Container, kind extsync.ItemKind, _ string) ([]extsync.ItemRef, string, error) {
	return f.of(kind), "", nil
}

func (f *ext03Fetcher) Fetch(_ context.Context, _ extsync.Container, ref extsync.ItemRef) (*extsync.Item, error) {
	it := *f.items[ref.ExtID]
	return &it, nil
}

func (f *ext03Fetcher) Comments(context.Context, extsync.Container, string) ([]extsync.Item, error) {
	return nil, nil
}

func (f *ext03Fetcher) Download(_ context.Context, it *extsync.Item, _ int64) (io.ReadCloser, error) {
	return io.NopCloser(bytes.NewReader(f.blobs[it.Ref.ExtID])), nil
}

func (f *ext03Fetcher) Users(context.Context, []string) (map[string]extsync.User, error) {
	return map[string]extsync.User{}, nil
}

// pathOCR records the files it was handed and answers fixed text.
type pathOCR struct {
	mu    sync.Mutex
	paths []string
}

func (o *pathOCR) Recognize(_ context.Context, path string, pages []int) (map[int]string, error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	o.paths = append(o.paths, path)
	out := map[int]string{}
	for _, p := range append([]int{0}, pages...) {
		out[p] = "recognized text"
	}
	return out, nil
}

// TestEXT03_BinariesNeverPersisted: after a full sync pass with a PDF and an
// image attachment, (a) the extract temp dir is empty, (b) no stored value
// carries the attachments' raw leading bytes or their base64 forms, and (c)
// no column of ext_*, kb_chunks or kb_documents holds a BLOB value.
func TestEXT03_BinariesNeverPersisted(t *testing.T) {
	d := db.OpenTestDB(t)
	acct := db.SeedTestJiraAccount(t, d)
	_, err := d.CreateExtSource("confluence", acct, "ENG", "1", "Engineering")
	require.NoError(t, err)

	tmp := filepath.Join(t.TempDir(), "tmp", "extract")
	ocr := &pathOCR{}
	e := extsync.New(d, extsync.Options{Extractor: &extract.Extractor{TempDir: tmp, OCR: ocr}})
	e.SetFetcher(acct, newExt03Fetcher(t))
	_, err = e.Run(context.Background())
	require.NoError(t, err)

	// The pass really extracted both, through files under the temp dir.
	var ok int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM ext_documents WHERE kind = 'attachment'
		AND extract_status = 'ok' AND CAST(sections_json AS TEXT) LIKE '%recognized text%'`).Scan(&ok))
	require.Equal(t, 2, ok, "both attachments extracted")
	require.Len(t, ocr.paths, 2)
	for _, p := range ocr.paths {
		assert.True(t, strings.HasPrefix(p, tmp+string(os.PathSeparator)), "spooled under TempDir: %s", p)
	}

	// (a) nothing left in the temp dir.
	assertNoFiles(t, tmp)

	// The knowledge index is built from these rows; it must not carry the
	// bytes either. (Its cycle clock sits past the sync's writes: the KB
	// only lists markers from seconds that are over.)
	_, err = kb.Run(context.Background(), d, kb.Options{Sources: []string{"confluence"}, Now: time.Now().Add(2 * time.Second)})
	require.NoError(t, err)
	var indexed int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM kb_chunks WHERE body LIKE '%recognized text%'`).Scan(&indexed))
	require.Positive(t, indexed, "the attachments' text reached the index")

	// (b) + (c) no raw bytes (nor their base64 forms) and no BLOB anywhere in
	// ext_* or the knowledge index.
	for _, magic := range [][]byte{[]byte("%PDF-"), {0x89, 'P', 'N', 'G'}, []byte("JVBERi0"), []byte("iVBORw0K")} {
		assertNoBytesInTables(t, d, `ext\_%`, magic)
		assertNoBytesInTables(t, d, `kb\_chunks`, magic)
		assertNoBytesInTables(t, d, `kb\_documents`, magic)
	}
}

func assertNoFiles(t *testing.T, dir string) {
	t.Helper()
	var left []string
	require.NoError(t, filepath.WalkDir(dir, func(path string, e fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !e.IsDir() {
			left = append(left, path)
		}
		return nil
	}))
	assert.Empty(t, left, "temp files left behind")
}

// assertNoBytesInTables scans every column of every table matching the
// LIKE pattern (escape '\') for a BLOB value or a value containing magic.
func assertNoBytesInTables(t *testing.T, d *db.DB, pattern string, magic []byte) {
	t.Helper()
	tables := queryStrings(t, d, `SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE ? ESCAPE '\'`, pattern)
	require.NotEmpty(t, tables)
	for _, table := range tables {
		for _, col := range queryStrings(t, d, `SELECT name FROM pragma_table_info(?)`, table) {
			var n int
			q := `SELECT COUNT(*) FROM "` + table + `" WHERE typeof("` + col + `") = 'blob'
				OR instr(CAST("` + col + `" AS BLOB), ?) > 0`
			require.NoError(t, d.QueryRow(q, magic).Scan(&n))
			assert.Zero(t, n, "%s.%s holds attachment bytes", table, col)
		}
	}
}

func queryStrings(t *testing.T, d *db.DB, q string, args ...any) []string {
	t.Helper()
	rows, err := d.Query(q, args...)
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
