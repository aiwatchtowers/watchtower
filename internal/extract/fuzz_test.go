package extract

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// FuzzExtractPDF drives arbitrary bytes through the production PDF path
// (helper process under a hard timeout). Invariants: Extract returns within
// the timeout plus slack, with no error but the helper timeout (a transient
// failure the engine retries), with a status the PDF path can produce, and
// leaves no temp file. prevloop.pdf is not a seed: every mutation of it runs
// into the helper timeout, starving the fuzzer; it has its own regression
// test (TestPDFHelperTimeoutIsTransient). The timeout leaves room for a
// race-instrumented helper to start.
//
//	go test -fuzz=FuzzExtractPDF -fuzztime=60s ./internal/extract
func FuzzExtractPDF(f *testing.F) {
	for _, name := range []string{"sample.pdf", "scanned.pdf", "mixed.pdf", "short.pdf", "blank.pdf",
		"kidsloop.pdf", "badpage.pdf"} {
		b, err := os.ReadFile(filepath.Join("testdata", name))
		if err != nil {
			f.Fatal(err)
		}
		f.Add(b)
	}
	old := pdfHelperTimeout
	pdfHelperTimeout = 5 * time.Second
	f.Cleanup(func() { pdfHelperTimeout = old })
	allowed := map[string]bool{StatusOK: true, StatusOCRUnavailable: true, StatusFailed: true, StatusTooLarge: true}
	f.Fuzz(func(t *testing.T, data []byte) {
		x := &Extractor{TempDir: filepath.Join(t.TempDir(), "extract"), PDFHelper: testHelper()}
		r := extractWithin(t, 30*time.Second, x, "application/pdf", "f.pdf", data)
		switch {
		case errors.Is(r.err, errPDFHelperTimeout):
			// transient: no status, retried by the engine
		case r.err != nil:
			t.Fatalf("error: %v", r.err)
		case !allowed[r.status]:
			t.Fatalf("status %q", r.status)
		}
		assertTempDirEmpty(t, x.TempDir)
	})
}

// FuzzExtractOOXML drives arbitrary bytes through the in-process OOXML path
// (docx, xlsx and pptx alike — the bytes are tried as each). Invariants: no
// error (every content problem is a status), a status the OOXML path can
// produce, and no temp file left behind. The seeds include a part nested
// past maxXMLDepth, so the plain test run exercises the structure caps too.
//
//	go test -fuzz=FuzzExtractOOXML -fuzztime=60s ./internal/extract
func FuzzExtractOOXML(f *testing.F) {
	for _, name := range []string{"sample.docx", "sample.xlsx", "sample.pptx"} {
		b, err := os.ReadFile(filepath.Join("testdata", name))
		if err != nil {
			f.Fatal(err)
		}
		f.Add(b)
	}
	f.Add(zipOf(f, map[string]func(io.Writer) error{
		"word/document.xml":        nested(docxOpen, docxClose, 2*maxXMLDepth),
		"xl/worksheets/sheet1.xml": nested(`<worksheet><sheetData><row><c t="inlineStr"><is><t>`, `</t></is></c></row></sheetData></worksheet>`, 2*maxXMLDepth),
		"ppt/slides/slide1.xml":    nested(`<p:sld xmlns:p="p" xmlns:a="a"><a:p><a:t>`, `</a:t></a:p></p:sld>`, 2*maxXMLDepth),
	}))
	allowed := map[string]bool{StatusOK: true, StatusFailed: true, StatusTooLarge: true}
	f.Fuzz(func(t *testing.T, data []byte) {
		for _, tc := range []struct{ mediaType, name string }{
			{mtDocx, "f.docx"}, {mtXlsx, "f.xlsx"}, {mtPptx, "f.pptx"},
		} {
			x := &Extractor{TempDir: filepath.Join(t.TempDir(), "extract")}
			_, status, err := x.Extract(context.Background(), tc.mediaType, tc.name, bytes.NewReader(data))
			switch {
			case err != nil:
				t.Fatalf("%s: error: %v", tc.name, err)
			case !allowed[status]:
				t.Fatalf("%s: status %q", tc.name, status)
			}
			assertTempDirEmpty(t, x.TempDir)
		}
	})
}
