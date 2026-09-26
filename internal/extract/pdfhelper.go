package extract

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"os/exec"
	"time"
)

// pdfHelperTimeout bounds one out-of-process PDF parse (a variable so
// tests can shorten it). A parse that runs past it — the library looping
// on a crafted file — is killed and the attachment recorded failed.
var pdfHelperTimeout = 60 * time.Second

// PDFHelperDeadline is how long a helper process may live before it exits
// on its own: the parent's timeout plus a 10 s margin, so the parent's kill
// always comes first and only an orphan (its parent SIGKILLed) ever hits it.
func PDFHelperDeadline() time.Duration { return pdfHelperTimeout + 10*time.Second }

// maxPDFHelperOutput caps the helper's stdout: MaxPDFPages pages of text
// fit comfortably; more means a misbehaving helper.
const maxPDFHelperOutput = 32 << 20

// pdfHelperResult is the helper's stdout (one JSON document).
type pdfHelperResult struct {
	OK    bool      `json:"ok"`
	Pages []pdfPage `json:"pages"`
}

// parsePDF parses the PDF at path: in a helper process when
// Extractor.PDFHelper is set (production), else in this process. ok is
// false for an unreadable PDF; the error is only ctx's.
func (x *Extractor) parsePDF(ctx context.Context, path string) ([]pdfPage, bool, error) {
	if len(x.PDFHelper) == 0 {
		pages, ok := parsePDFFile(path)
		return pages, ok, nil
	}
	return runPDFHelper(ctx, x.PDFHelper, path)
}

// runPDFHelper runs argv + path under pdfHelperTimeout. A timeout, crash,
// non-zero exit, oversize or malformed output is an unreadable PDF (ok
// false), never an error: the next attachment must not be held up by it.
func runPDFHelper(ctx context.Context, argv []string, path string) ([]pdfPage, bool, error) {
	cctx, cancel := context.WithTimeout(ctx, pdfHelperTimeout)
	defer cancel()
	args := append(append([]string(nil), argv[1:]...), path)
	cmd := exec.CommandContext(cctx, argv[0], args...) //nolint:gosec // argv is our own executable, set by the caller
	out := &cappedBuffer{max: maxPDFHelperOutput}
	cmd.Stdout = out
	cmd.Stderr = io.Discard
	cmd.WaitDelay = 5 * time.Second
	err := cmd.Run()
	if ctx.Err() != nil {
		return nil, false, ctx.Err()
	}
	if err != nil || out.overflow {
		return nil, false, nil
	}
	var res pdfHelperResult
	if json.Unmarshal(out.buf.Bytes(), &res) != nil || !res.OK || !validPages(res.Pages) {
		return nil, false, nil
	}
	return res.Pages, true, nil
}

// validPages checks the helper's pages are 0..n-1 in order (pdfStatus
// indexes by position), n in 1..MaxPDFPages.
func validPages(pages []pdfPage) bool {
	if len(pages) == 0 || len(pages) > MaxPDFPages {
		return false
	}
	for i, p := range pages {
		if p.Index != i {
			return false
		}
	}
	return true
}

// ServePDFHelper is the helper process's side: it parses path in process
// and writes the pdfHelperResult JSON to w. The caller (a hidden CLI
// command) runs it in its own process, so a parse that never returns is
// killed by the parent's timeout instead of wedging the daemon.
func ServePDFHelper(w io.Writer, path string) error {
	pages, ok := parsePDFFile(path)
	return json.NewEncoder(w).Encode(pdfHelperResult{OK: ok, Pages: pages})
}

// cappedBuffer keeps at most max bytes and records an overflow.
type cappedBuffer struct {
	buf      bytes.Buffer
	max      int
	overflow bool
}

func (c *cappedBuffer) Write(p []byte) (int, error) {
	if c.buf.Len()+len(p) > c.max {
		c.overflow = true
		return 0, io.ErrShortWrite
	}
	return c.buf.Write(p)
}
