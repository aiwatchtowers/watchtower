package extract

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/extsync"
)

// discardLog is a logFunc that drops everything.
func discardLog(string, ...any) {}

// loggingExtractor is newExtractor with a Logger writing into the returned
// buffer.
func loggingExtractor(t *testing.T, ocr OCR) (*Extractor, *bytes.Buffer) {
	t.Helper()
	var buf bytes.Buffer
	x := newExtractor(t, ocr)
	x.Logger = log.New(&buf, "", 0)
	return x, &buf
}

// TestPDFHelperTimeoutIsTransient: a helper killed at pdfHelperTimeout (the
// library looping inside NewReader on a self-referencing /Prev) is an
// error — a transient failure the engine retries — not a final failed.
func TestPDFHelperTimeoutIsTransient(t *testing.T) {
	old := pdfHelperTimeout
	pdfHelperTimeout = time.Second
	t.Cleanup(func() { pdfHelperTimeout = old })
	x := newExtractor(t, nil)
	x.PDFHelper = testHelper()
	start := time.Now()
	r := extractWithin(t, 15*time.Second, x, "application/pdf", "prev.pdf", fixture(t, "prevloop.pdf"))
	require.Error(t, r.err)
	assert.Contains(t, r.err.Error(), "timed out")
	assert.Nil(t, r.secs)
	assert.GreaterOrEqual(t, time.Since(start), time.Second, "it really was the timeout that ended it")
	assertTempDirEmpty(t, x.TempDir)
}

// TestPDFHelperCrashIsTransient: a helper exiting non-zero is an error
// carrying its stderr.
func TestPDFHelperCrashIsTransient(t *testing.T) {
	x := newExtractor(t, nil)
	x.PDFHelper = []string{"/bin/sh", "-c", "echo parser exploded >&2; exit 3", "sh"}
	r := extractWithin(t, 10*time.Second, x, "application/pdf", "a.pdf", fixture(t, "sample.pdf"))
	require.Error(t, r.err)
	assert.Contains(t, r.err.Error(), "parser exploded")
	assertTempDirEmpty(t, x.TempDir)
}

// TestPDFHelperGarbageIsFinalAndLogged: output the helper did produce but
// that is not its JSON is a verdict (failed, no error), logged.
func TestPDFHelperGarbageIsFinalAndLogged(t *testing.T) {
	x, logs := loggingExtractor(t, nil)
	x.PDFHelper = []string{"/bin/echo", "not json"}
	r := extractWithin(t, 10*time.Second, x, "application/pdf", "a.pdf", fixture(t, "sample.pdf"))
	require.NoError(t, r.err)
	assert.Equal(t, StatusFailed, r.status)
	assert.Contains(t, logs.String(), "malformed output")
}

// TestPDFHelperStderrOnCleanRunIsLogged: what a helper that exits 0 wrote to
// stderr (a recovered parser panic) reaches the log.
func TestPDFHelperStderrOnCleanRunIsLogged(t *testing.T) {
	x, logs := loggingExtractor(t, nil)
	x.PDFHelper = []string{"/bin/sh", "-c", `echo recovered a panic >&2; echo '{"ok":false}'`, "sh"}
	r := extractWithin(t, 10*time.Second, x, "application/pdf", "a.pdf", fixture(t, "sample.pdf"))
	require.NoError(t, r.err)
	assert.Equal(t, StatusFailed, r.status)
	assert.Contains(t, logs.String(), "recovered a panic")
}

// TestCappedBufferTruncateKeepsTheHead: a truncating buffer never fails a
// write — a chatty helper's stderr must not fail its run.
func TestCappedBufferTruncateKeepsTheHead(t *testing.T) {
	b := &cappedBuffer{max: 4, truncate: true}
	n, err := b.Write([]byte("abcdef"))
	require.NoError(t, err)
	assert.Equal(t, 6, n)
	assert.Equal(t, "abcd", b.buf.String())
	assert.True(t, b.overflow)
}

// TestRecoveredPanicIsLogged: the top-level recover still yields failed
// with a nil error, and now says why.
func TestRecoveredPanicIsLogged(t *testing.T) {
	x, logs := loggingExtractor(t, panicOCR{})
	_, status, err := x.Extract(context.Background(), "image/png", "sample.png", bytes.NewReader(fixture(t, "sample.png")))
	require.NoError(t, err)
	assert.Equal(t, StatusFailed, status)
	assert.Contains(t, logs.String(), "ocr exploded")
}

// TestCorruptOOXMLIsLogged: a corrupt archive is failed, and logged.
func TestCorruptOOXMLIsLogged(t *testing.T) {
	x, logs := loggingExtractor(t, nil)
	_, status, err := x.Extract(context.Background(), "", "broken.docx", bytes.NewReader([]byte("not a zip")))
	require.NoError(t, err)
	assert.Equal(t, StatusFailed, status)
	assert.Contains(t, logs.String(), "OOXML")
}

// TestFailedOCRBatchIsLogged: the per-batch OCR error that only marks the
// PDF ocr_pending reaches the log.
func TestFailedOCRBatchIsLogged(t *testing.T) {
	var logs bytes.Buffer
	ocr := ocrFunc(func(context.Context, string, []int) (map[int]string, error) {
		return nil, errors.New("vision request failed")
	})
	pages, scans := scanPagesN(3)
	failed, err := recognizeScans(context.Background(), ocr, "/tmp/x.pdf", pages, scans, log.New(&logs, "", 0).Printf)
	require.NoError(t, err)
	assert.True(t, failed)
	assert.Contains(t, logs.String(), "vision request failed")
}

// badTextPDF is a two-page PDF: page 1 has a readable text layer; page 2's
// content stream is malformed (Tf with one operand), so reading its text
// fails. Neither page carries an image.
func badTextPDF() []byte {
	good := "BT /F1 12 Tf 72 720 Td (The first page reads fine and keeps its text) Tj ET"
	bad := "BT /F1 Tf (x) Tj ET"
	objs := []string{
		"<< /Type /Catalog /Pages 2 0 R >>",
		"<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>",
		"<< /Type /Page /Parent 2 0 R /Resources << /Font << /F1 7 0 R >> >> /Contents 4 0 R >>",
		fmt.Sprintf("<< /Length %d >>\nstream\n%s\nendstream", len(good), good),
		"<< /Type /Page /Parent 2 0 R /Resources << /Font << /F1 7 0 R >> >> /Contents 6 0 R >>",
		fmt.Sprintf("<< /Length %d >>\nstream\n%s\nendstream", len(bad), bad),
		"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
	}
	var buf bytes.Buffer
	buf.WriteString("%PDF-1.4\n")
	offsets := make([]int, len(objs))
	for i, o := range objs {
		offsets[i] = buf.Len()
		fmt.Fprintf(&buf, "%d 0 obj\n%s\nendobj\n", i+1, o)
	}
	xref := buf.Len()
	fmt.Fprintf(&buf, "xref\n0 %d\n0000000000 65535 f \n", len(objs)+1)
	for _, off := range offsets {
		fmt.Fprintf(&buf, "%010d 00000 n \n", off)
	}
	fmt.Fprintf(&buf, "trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n", len(objs)+1, xref)
	return buf.Bytes()
}

// TestPDFUnreadableTextLayerGoesToOCR: a page whose text layer cannot be
// read is a scan candidate — OCR recognizes it — instead of a blank page;
// with no OCR it is ocr_unavailable, retried once OCR appears.
func TestPDFUnreadableTextLayerGoesToOCR(t *testing.T) {
	data := badTextPDF()
	ocr := &fakeOCR{text: map[int]string{1: "recognized second page"}}
	x, logs := loggingExtractor(t, ocr)
	secs, status, err := x.Extract(context.Background(), "application/pdf", "bad.pdf", bytes.NewReader(data))
	require.NoError(t, err)
	assert.Equal(t, StatusOK, status)
	assert.Equal(t, [][]int{{1}}, ocr.pages, "only the unreadable page goes to OCR")
	assert.Equal(t, []extsync.Section{
		{Heading: "Page 1", Text: "The first page reads fine and keeps its text"},
		{Heading: "Page 2", Text: "recognized second page"},
	}, secs)
	assert.Contains(t, logs.String(), "sending it to OCR")

	_, status, err = newExtractor(t, nil).Extract(context.Background(), "application/pdf", "bad.pdf", bytes.NewReader(data))
	require.NoError(t, err)
	assert.Equal(t, StatusOCRUnavailable, status)
}
