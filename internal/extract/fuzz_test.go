package extract

import (
	"errors"
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
