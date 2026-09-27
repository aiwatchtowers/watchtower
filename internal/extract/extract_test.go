package extract

import (
	"archive/zip"
	"bytes"
	"context"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"unicode/utf8"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/extsync"
)

const (
	mtDocx = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
	mtXlsx = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
	mtPptx = "application/vnd.openxmlformats-officedocument.presentationml.presentation"
)

// fakeOCR records the calls it receives and answers from text (or err).
type fakeOCR struct {
	mu    sync.Mutex
	pages [][]int
	seen  []bool // whether the file existed when Recognize ran
	text  map[int]string
	err   error
}

func (o *fakeOCR) Recognize(_ context.Context, path string, pages []int) (map[int]string, error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	_, statErr := os.Stat(path)
	o.seen = append(o.seen, statErr == nil)
	o.pages = append(o.pages, append([]int(nil), pages...))
	if o.err != nil {
		return nil, o.err
	}
	return o.text, nil
}

func newExtractor(t *testing.T, ocr OCR) *Extractor {
	t.Helper()
	return &Extractor{TempDir: filepath.Join(t.TempDir(), "tmp", "extract"), OCR: ocr}
}

func fixture(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", name))
	require.NoError(t, err)
	return b
}

func run(t *testing.T, x *Extractor, mediaType, name string) ([]extsync.Section, string) {
	t.Helper()
	secs, status, err := x.Extract(context.Background(), mediaType, name, bytes.NewReader(fixture(t, name)))
	require.NoError(t, err)
	assertTempDirEmpty(t, x.TempDir)
	return secs, status
}

// assertTempDirEmpty fails when any file is left under dir.
func assertTempDirEmpty(t *testing.T, dir string) {
	t.Helper()
	var left []string
	err := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) {
				return nil
			}
			return err
		}
		if !d.IsDir() {
			left = append(left, path)
		}
		return nil
	})
	require.NoError(t, err)
	assert.Empty(t, left, "temp files left behind")
}

func TestPlainCSV(t *testing.T) {
	secs, status := run(t, newExtractor(t, nil), "text/csv", "sample.csv")
	assert.Equal(t, StatusOK, status)
	assert.Equal(t, []extsync.Section{{Text: "name,qty\napple,3\npear,5"}}, secs)
}

func TestPlainByExtensionFallback(t *testing.T) {
	x := newExtractor(t, nil)
	secs, status, err := x.Extract(context.Background(), "application/octet-stream", "notes.md", strings.NewReader("\uFEFF# Title\r\nbody\r\n"))
	require.NoError(t, err)
	assert.Equal(t, StatusOK, status)
	assert.Equal(t, []extsync.Section{{Text: "# Title\nbody"}}, secs)
}

func TestMediaTypeWithParams(t *testing.T) {
	x := newExtractor(t, nil)
	secs, status, err := x.Extract(context.Background(), "Text/Plain; charset=utf-8", "x.bin", strings.NewReader("hi"))
	require.NoError(t, err)
	assert.Equal(t, StatusOK, status)
	assert.Equal(t, []extsync.Section{{Text: "hi"}}, secs)
}

func TestPlainInvalidUTF8Fails(t *testing.T) {
	x := newExtractor(t, nil)
	secs, status, err := x.Extract(context.Background(), "text/plain", "a.txt", bytes.NewReader([]byte{'a', 0xff, 0xfe}))
	require.NoError(t, err)
	assert.Equal(t, StatusFailed, status)
	assert.Nil(t, secs)
}

func TestHTML(t *testing.T) {
	secs, status := run(t, newExtractor(t, nil), "text/html", "sample.html")
	assert.Equal(t, StatusOK, status)
	assert.Equal(t, []extsync.Section{{Text: "Release notes\nFirst paragraph with bold text.\none\ntwo\nTail&end"}}, secs)
}

func TestHTMLTableCells(t *testing.T) {
	x := newExtractor(t, nil)
	doc := `<table><tr><th>Name</th><th>Qty</th></tr><tr><td>apple</td><td>3</td></tr></table><p>after</p>`
	secs, status, err := x.Extract(context.Background(), "text/html", "t.html", strings.NewReader(doc))
	require.NoError(t, err)
	assert.Equal(t, StatusOK, status)
	assert.Equal(t, []extsync.Section{{Text: "Name | Qty\napple | 3\nafter"}}, secs)
}

func TestDocx(t *testing.T) {
	secs, status := run(t, newExtractor(t, nil), mtDocx, "sample.docx")
	assert.Equal(t, StatusOK, status)
	assert.Equal(t, []extsync.Section{
		{Text: "Intro line"},
		{Heading: "Goals", Text: "Ship\tthe thing\nSecond line"},
		{Heading: "Risks", Text: "Cell text"},
	}, secs)
}

func TestXlsx(t *testing.T) {
	secs, status := run(t, newExtractor(t, nil), mtXlsx, "sample.xlsx")
	assert.Equal(t, StatusOK, status)
	assert.Equal(t, []extsync.Section{
		{Heading: "Budget", Text: "Item | Cost\nServers | 1200\nTotal | TRUE"},
		{Heading: "Team", Text: "Alice"},
	}, secs)
}

func TestPptxNumericSlideOrder(t *testing.T) {
	secs, status := run(t, newExtractor(t, nil), mtPptx, "sample.pptx")
	assert.Equal(t, StatusOK, status)
	assert.Equal(t, []extsync.Section{
		{Heading: "Slide 1", Text: "Kickoff\nAgenda"},
		{Heading: "Slide 2", Text: "Timeline"},
		{Heading: "Slide 3", Text: "Questions"},
	}, secs)
}

func TestOOXMLByExtensionFallback(t *testing.T) {
	x := newExtractor(t, nil)
	secs, status, err := x.Extract(context.Background(), "", "sample.docx", bytes.NewReader(fixture(t, "sample.docx")))
	require.NoError(t, err)
	assert.Equal(t, StatusOK, status)
	assert.Len(t, secs, 3)
}

func TestCorruptZipFails(t *testing.T) {
	x := newExtractor(t, nil)
	secs, status, err := x.Extract(context.Background(), mtDocx, "bad.docx", strings.NewReader("not a zip"))
	require.NoError(t, err)
	assert.Equal(t, StatusFailed, status)
	assert.Nil(t, secs)
	assertTempDirEmpty(t, x.TempDir)
}

func TestZipBombCapped(t *testing.T) {
	old := maxZipBytes
	maxZipBytes = 1 << 20
	t.Cleanup(func() { maxZipBytes = old })

	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	w, err := zw.Create("word/document.xml")
	require.NoError(t, err)
	_, err = w.Write([]byte(`<w:document xmlns:w="w"><w:body><w:p><w:r><w:t>`))
	require.NoError(t, err)
	_, err = w.Write(bytes.Repeat([]byte("a"), 2<<20))
	require.NoError(t, err)
	_, err = w.Write([]byte(`</w:t></w:r></w:p></w:body></w:document>`))
	require.NoError(t, err)
	require.NoError(t, zw.Close())

	x := newExtractor(t, nil)
	secs, status, err := x.Extract(context.Background(), mtDocx, "bomb.docx", &buf)
	require.NoError(t, err)
	assert.Equal(t, StatusTooLarge, status)
	assert.Nil(t, secs)
	assertTempDirEmpty(t, x.TempDir)
}

func TestZipEntryCountCapped(t *testing.T) {
	old := maxZipEntries
	maxZipEntries = 2
	t.Cleanup(func() { maxZipEntries = old })
	x := newExtractor(t, nil)
	_, status := run(t, x, mtPptx, "sample.pptx") // three slides
	assert.Equal(t, StatusTooLarge, status)
}

func TestPDFTextLayer(t *testing.T) {
	secs, status := run(t, newExtractor(t, nil), "application/pdf", "sample.pdf")
	assert.Equal(t, StatusOK, status)
	assert.Equal(t, []extsync.Section{{Heading: "Page 1", Text: "Quarterly report: revenue grew twelve percent"}}, secs)
}

func TestPDFTextlessPageWithoutOCR(t *testing.T) {
	secs, status := run(t, newExtractor(t, nil), "application/pdf", "scanned.pdf")
	assert.Equal(t, StatusOCRUnavailable, status)
	assert.Empty(t, secs)
}

func TestPDFMixedWithoutOCRKeepsTextPages(t *testing.T) {
	secs, status := run(t, newExtractor(t, nil), "application/pdf", "mixed.pdf")
	assert.Equal(t, StatusOCRUnavailable, status)
	assert.Equal(t, []extsync.Section{{Heading: "Page 1", Text: "Cover page with enough text to count"}}, secs)
}

func TestPDFTextlessPageWithFakeOCR(t *testing.T) {
	ocr := &fakeOCR{text: map[int]string{0: "scanned words"}}
	secs, status := run(t, newExtractor(t, ocr), "application/pdf", "scanned.pdf")
	assert.Equal(t, StatusOK, status)
	assert.Equal(t, []extsync.Section{{Heading: "Page 1", Text: "scanned words"}}, secs)
	assert.Equal(t, [][]int{{0}}, ocr.pages, "the fake receives page index 0")
	assert.Equal(t, []bool{true}, ocr.seen, "the temp file exists while OCR runs")
}

func TestPDFMixedWithOCROrdersPages(t *testing.T) {
	ocr := &fakeOCR{text: map[int]string{1: "second page scan"}}
	secs, status := run(t, newExtractor(t, ocr), "application/pdf", "mixed.pdf")
	assert.Equal(t, StatusOK, status)
	assert.Equal(t, []extsync.Section{
		{Heading: "Page 1", Text: "Cover page with enough text to count"},
		{Heading: "Page 2", Text: "second page scan"},
	}, secs)
	assert.Equal(t, [][]int{{1}}, ocr.pages)
}

func TestPDFOCRErrorIsPending(t *testing.T) {
	ocr := &fakeOCR{err: errors.New("helper crashed")}
	secs, status := run(t, newExtractor(t, ocr), "application/pdf", "mixed.pdf")
	assert.Equal(t, StatusOCRPending, status)
	assert.Equal(t, []extsync.Section{{Heading: "Page 1", Text: "Cover page with enough text to count"}}, secs)
}

func TestPDFCorruptFails(t *testing.T) {
	x := newExtractor(t, nil)
	secs, status, err := x.Extract(context.Background(), "application/pdf", "x.pdf", strings.NewReader("%PDF-1.4 garbage"))
	require.NoError(t, err)
	assert.Equal(t, StatusFailed, status)
	assert.Nil(t, secs)
	assertTempDirEmpty(t, x.TempDir)
}

func TestImageWithoutOCR(t *testing.T) {
	secs, status := run(t, newExtractor(t, nil), "image/png", "sample.png")
	assert.Equal(t, StatusOCRUnavailable, status)
	assert.Nil(t, secs)
}

func TestImageWithFakeOCR(t *testing.T) {
	ocr := &fakeOCR{text: map[int]string{0: "whiteboard notes"}}
	secs, status := run(t, newExtractor(t, ocr), "image/png", "sample.png")
	assert.Equal(t, StatusOK, status)
	assert.Equal(t, []extsync.Section{{Text: "whiteboard notes"}}, secs)
	assert.Equal(t, [][]int{nil}, ocr.pages)
	assert.Equal(t, []bool{true}, ocr.seen)
}

func TestUnknownTypeSkipped(t *testing.T) {
	x := newExtractor(t, nil)
	for _, c := range [][2]string{{"application/zip", "a.zip"}, {"video/mp4", "clip.mp4"}, {"", "legacy.doc"}, {"application/octet-stream", "noext"}} {
		secs, status, err := x.Extract(context.Background(), c[0], c[1], strings.NewReader("whatever"))
		require.NoError(t, err)
		assert.Equal(t, StatusSkippedType, status, c)
		assert.Nil(t, secs, c)
		assert.False(t, x.Supports(c[0], c[1]), c)
	}
}

// TestSupportsAgreesWithExtract: a type Supports accepts is never reported
// skipped_type — the engine's one-time re-extraction of rows written without
// an extractor relies on it to terminate.
func TestSupportsAgreesWithExtract(t *testing.T) {
	x := newExtractor(t, nil)
	for _, c := range [][2]string{
		{"text/plain", "a.txt"}, {"text/csv", "a.csv"}, {"application/json", "a.json"}, {"application/xml", "a.xml"},
		{"text/markdown", "a.md"}, {"text/html", "a.html"}, {mtDocx, "a.docx"}, {mtXlsx, "a.xlsx"}, {mtPptx, "a.pptx"},
		{"application/pdf", "a.pdf"}, {"image/jpeg", "a.jpg"}, {"image/heic", "a.heic"}, {"image/tiff", "a.tiff"},
		{"image/gif", "a.gif"}, {"", "a.png"},
	} {
		require.True(t, x.Supports(c[0], c[1]), c)
		_, status, err := x.Extract(context.Background(), c[0], c[1], strings.NewReader("x"))
		require.NoError(t, err)
		assert.NotEqual(t, StatusSkippedType, status, c)
	}
	assertTempDirEmpty(t, x.TempDir)
}

func TestTextCap(t *testing.T) {
	x := newExtractor(t, nil)
	big := strings.Repeat("я", 300_000)
	secs, status, err := x.Extract(context.Background(), "text/plain", "big.txt", strings.NewReader(big))
	require.NoError(t, err)
	assert.Equal(t, StatusOK, status)
	total := 0
	for _, s := range secs {
		total += utf8.RuneCountInString(s.Heading) + utf8.RuneCountInString(s.Text)
	}
	assert.LessOrEqual(t, total, MaxTextRunes)
	assert.Greater(t, total, MaxTextRunes-100)
}

func TestCapSectionsAcrossSections(t *testing.T) {
	secs := capSections([]extsync.Section{{Heading: "ab", Text: "cdef"}, {Heading: "g", Text: "hij"}, {Text: "zz"}}, 8)
	assert.Equal(t, []extsync.Section{{Heading: "ab", Text: "cdef"}, {Heading: "g", Text: "h"}}, secs)
}

func TestOversizeInputTooLarge(t *testing.T) {
	x := newExtractor(t, nil)
	r := io.LimitReader(zeroReader{}, MaxDownload+1)
	secs, status, err := x.Extract(context.Background(), "application/pdf", "huge.pdf", r)
	require.NoError(t, err)
	assert.Equal(t, StatusTooLarge, status)
	assert.Nil(t, secs)
	assertTempDirEmpty(t, x.TempDir)
}

type zeroReader struct{}

func (zeroReader) Read(p []byte) (int, error) {
	clear(p)
	return len(p), nil
}

var errBoom = errors.New("boom")

type failingReader struct{}

func (failingReader) Read([]byte) (int, error) { return 0, errBoom }

// TestReadErrorPropagates: a read failure (network, a size cap enforced by
// the reader) is an error, wrapped so the caller can match it — not a status.
func TestReadErrorPropagates(t *testing.T) {
	x := newExtractor(t, nil)
	for _, c := range [][2]string{{"text/plain", "a.txt"}, {"application/pdf", "a.pdf"}, {mtDocx, "a.docx"}, {"image/png", "a.png"}} {
		_, _, err := x.Extract(context.Background(), c[0], c[1], failingReader{})
		assert.ErrorIs(t, err, errBoom, c)
	}
	assertTempDirEmpty(t, x.TempDir)
}

func TestTempFilesArePrivate(t *testing.T) {
	var mode fs.FileMode
	var dirMode fs.FileMode
	ocr := ocrFunc(func(_ context.Context, path string, _ []int) (map[int]string, error) {
		fi, err := os.Stat(path)
		if err != nil {
			return nil, err
		}
		mode = fi.Mode().Perm()
		di, err := os.Stat(filepath.Dir(path))
		if err != nil {
			return nil, err
		}
		dirMode = di.Mode().Perm()
		return map[int]string{0: "x"}, nil
	})
	x := newExtractor(t, ocr)
	_, status := run(t, x, "image/png", "sample.png")
	assert.Equal(t, StatusOK, status)
	assert.Equal(t, fs.FileMode(0o600), mode)
	assert.Equal(t, fs.FileMode(0o700), dirMode)
}

func TestNoTempDirIsAnError(t *testing.T) {
	x := &Extractor{}
	_, _, err := x.Extract(context.Background(), "application/pdf", "a.pdf", bytes.NewReader(fixture(t, "sample.pdf")))
	assert.Error(t, err)
}

func TestHasOCR(t *testing.T) {
	var c extsync.OCRCapable = &Extractor{}
	assert.False(t, c.HasOCR(context.Background()))
	c = &Extractor{OCR: &fakeOCR{}}
	assert.True(t, c.HasOCR(context.Background()))
}

type ocrFunc func(ctx context.Context, path string, pages []int) (map[int]string, error)

func (f ocrFunc) Recognize(ctx context.Context, path string, pages []int) (map[int]string, error) {
	return f(ctx, path, pages)
}

// TestTempDirEmptyAfterExtract runs every fixture through the extractor
// (with and without OCR) and checks nothing is left in TempDir.
func TestTempDirEmptyAfterExtract(t *testing.T) {
	types := map[string]string{
		"sample.csv": "text/csv", "sample.html": "text/html", "sample.docx": mtDocx, "sample.xlsx": mtXlsx,
		"sample.pptx": mtPptx, "sample.pdf": "application/pdf", "scanned.pdf": "application/pdf",
		"mixed.pdf": "application/pdf", "sample.png": "image/png",
	}
	for _, ocr := range []OCR{nil, &fakeOCR{text: map[int]string{0: "t"}}, &fakeOCR{err: errBoom}} {
		x := newExtractor(t, ocr)
		for name, mt := range types {
			_, _, err := x.Extract(context.Background(), mt, name, bytes.NewReader(fixture(t, name)))
			require.NoError(t, err, name)
		}
		assertTempDirEmpty(t, x.TempDir)
	}
}
