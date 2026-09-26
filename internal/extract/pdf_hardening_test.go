package extract

import (
	"bytes"
	"context"
	"os"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/extsync"
)

// TestMain doubles the test binary as the PDF helper process: invoked as
// `<test binary> pdf-helper <path>` it serves one parse and exits, the way
// the production CLI's hidden command does.
func TestMain(m *testing.M) {
	if len(os.Args) == 3 && os.Args[1] == "pdf-helper" {
		if err := ServePDFHelper(os.Stdout, os.Args[2]); err != nil {
			os.Exit(1)
		}
		os.Exit(0)
	}
	os.Exit(m.Run())
}

// testHelper is the PDFHelper argv prefix that runs this test binary.
func testHelper() []string { return []string{os.Args[0], "pdf-helper"} }

type extractResult struct {
	secs   []extsync.Section
	status string
	err    error
}

// extractWithin runs Extract in a goroutine and fails the test — instead
// of hanging it — when it has not returned within d.
func extractWithin(t *testing.T, d time.Duration, x *Extractor, mediaType, name string, data []byte) extractResult {
	t.Helper()
	done := make(chan extractResult, 1)
	go func() {
		secs, status, err := x.Extract(context.Background(), mediaType, name, bytes.NewReader(data))
		done <- extractResult{secs, status, err}
	}()
	select {
	case r := <-done:
		return r
	case <-time.After(d):
		t.Fatalf("Extract(%s) did not return within %s", name, d)
		return extractResult{}
	}
}

// TestPDFKidsLoopFailsFast: a page tree whose /Kids points back at itself
// used to spin Reader.Page forever; the bounded walk returns failed.
func TestPDFKidsLoopFailsFast(t *testing.T) {
	for _, helper := range [][]string{nil, testHelper()} {
		x := newExtractor(t, nil)
		x.PDFHelper = helper
		r := extractWithin(t, 10*time.Second, x, "application/pdf", "loop.pdf", fixture(t, "kidsloop.pdf"))
		require.NoError(t, r.err)
		assert.Equal(t, StatusFailed, r.status, "helper=%v", helper)
		assert.Nil(t, r.secs)
		assertTempDirEmpty(t, x.TempDir)
	}
}

// TestPDFPrevLoopKilledByHelperTimeout: a self-referencing xref /Prev loops
// inside the library's NewReader, which no in-process bound can stop; the
// helper process is killed at pdfHelperTimeout and the PDF is failed.
func TestPDFPrevLoopKilledByHelperTimeout(t *testing.T) {
	old := pdfHelperTimeout
	pdfHelperTimeout = time.Second
	t.Cleanup(func() { pdfHelperTimeout = old })
	x := newExtractor(t, nil)
	x.PDFHelper = testHelper()
	start := time.Now()
	r := extractWithin(t, 15*time.Second, x, "application/pdf", "prev.pdf", fixture(t, "prevloop.pdf"))
	require.NoError(t, r.err)
	assert.Equal(t, StatusFailed, r.status)
	assert.GreaterOrEqual(t, time.Since(start), time.Second, "it really was the timeout that ended it")
	assertTempDirEmpty(t, x.TempDir)
}

func TestPDFViaHelperMatchesInProcess(t *testing.T) {
	for _, name := range []string{"sample.pdf", "mixed.pdf", "short.pdf", "badpage.pdf"} {
		in := newExtractor(t, nil)
		out := newExtractor(t, nil)
		out.PDFHelper = testHelper()
		a := extractWithin(t, 30*time.Second, in, "application/pdf", name, fixture(t, name))
		b := extractWithin(t, 30*time.Second, out, "application/pdf", name, fixture(t, name))
		require.NoError(t, b.err, name)
		assert.Equal(t, a, b, name)
		assertTempDirEmpty(t, out.TempDir)
	}
}

func TestPDFHelperGarbageIsFailed(t *testing.T) {
	x := newExtractor(t, nil)
	x.PDFHelper = []string{"/bin/echo", "not json"}
	r := extractWithin(t, 10*time.Second, x, "application/pdf", "a.pdf", fixture(t, "sample.pdf"))
	require.NoError(t, r.err)
	assert.Equal(t, StatusFailed, r.status)
}

// TestPDFShortPageKeepsItsText: a short text layer is kept when OCR is
// unavailable or finds nothing, and does not mark the PDF ocr_unavailable.
func TestPDFShortPageKeepsItsText(t *testing.T) {
	want := []extsync.Section{
		{Heading: "Page 1", Text: "A long enough page of real text here"},
		{Heading: "Page 2", Text: "Hi"},
	}
	secs, status := run(t, newExtractor(t, nil), "application/pdf", "short.pdf")
	assert.Equal(t, StatusOK, status)
	assert.Equal(t, want, secs)

	ocr := &fakeOCR{text: map[int]string{}}
	secs, status = run(t, newExtractor(t, ocr), "application/pdf", "short.pdf")
	assert.Equal(t, StatusOK, status)
	assert.Equal(t, want, secs, "OCR found nothing: the short layer stays")
	assert.Equal(t, [][]int{{1}}, ocr.pages, "the short page with an image is still offered to OCR")
}

// TestPDFBlankPageIsNotAScan: a page with no text and no image is blank,
// not a scan — it neither asks for OCR nor marks the PDF ocr_unavailable.
func TestPDFBlankPageIsNotAScan(t *testing.T) {
	ocr := &fakeOCR{}
	secs, status := run(t, newExtractor(t, ocr), "application/pdf", "blank.pdf")
	assert.Equal(t, StatusOK, status)
	assert.Equal(t, []extsync.Section{{Heading: "Page 1", Text: "A long enough page of real text here"}}, secs)
	assert.Empty(t, ocr.pages)
}

// TestPDFBadPageKeepsTheGoodOnes: a page whose resources panic inside the
// library loses only itself.
func TestPDFBadPageKeepsTheGoodOnes(t *testing.T) {
	secs, status := run(t, newExtractor(t, nil), "application/pdf", "badpage.pdf")
	assert.Equal(t, StatusOK, status)
	require.NotEmpty(t, secs)
	assert.Equal(t, extsync.Section{Heading: "Page 1", Text: "The first page reads fine and keeps its text"}, secs[0])
}

// panicOCR panics on every call.
type panicOCR struct{}

func (panicOCR) Recognize(context.Context, string, []int) (map[int]string, error) {
	panic("ocr exploded")
}

// TestPanicInExtractIsFailed: a panic anywhere under Extract (here an OCR
// working on a spooled PDF and on an image) is StatusFailed with a nil
// error, and the spooled file is still removed.
func TestPanicInExtractIsFailed(t *testing.T) {
	for _, c := range [][2]string{{"application/pdf", "scanned.pdf"}, {"image/png", "sample.png"}} {
		x := newExtractor(t, panicOCR{})
		secs, status, err := x.Extract(context.Background(), c[0], c[1], bytes.NewReader(fixture(t, c[1])))
		require.NoError(t, err, c[1])
		assert.Equal(t, StatusFailed, status, c[1])
		assert.Nil(t, secs, c[1])
		assertTempDirEmpty(t, x.TempDir)
	}
}

// TestPageNodesBounded: the walk never visits more than its node budget.
func TestPageNodesBounded(t *testing.T) {
	old := maxPDFTreeNodes
	maxPDFTreeNodes = 3
	t.Cleanup(func() { maxPDFTreeNodes = old })
	secs, status := run(t, newExtractor(t, nil), "application/pdf", "short.pdf") // root + 2 pages = 3 nodes
	assert.Equal(t, StatusOK, status)
	assert.Len(t, secs, 2)
	maxPDFTreeNodes = 2
	secs, _ = run(t, newExtractor(t, nil), "application/pdf", "short.pdf")
	assert.Len(t, secs, 1, "the budget cuts the walk")
}
