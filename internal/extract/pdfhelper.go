package extract

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os/exec"
	"strings"
	"time"
)

// PDFHelperTimeout bounds one out-of-process PDF parse. A parse that runs
// past it — the library looping on a crafted file — is killed, and the
// attachment's extraction fails transiently (retried under the engine's
// attempt cap).
const PDFHelperTimeout = 60 * time.Second

// pdfHelperTimeout is PDFHelperTimeout, a variable so tests can shorten it.
var pdfHelperTimeout = PDFHelperTimeout

// errPDFHelperTimeout marks a helper killed at pdfHelperTimeout.
var errPDFHelperTimeout = errors.New("pdf helper timed out")

// PDFHelperDeadline is how long a helper process may live before it exits
// on its own: the parent's timeout plus a 10 s margin, so the parent's kill
// always comes first and only an orphan (its parent SIGKILLed) ever hits it.
func PDFHelperDeadline() time.Duration { return pdfHelperTimeout + 10*time.Second }

// maxPDFHelperOutput caps the helper's stdout: MaxPDFPages pages of text
// fit comfortably; more means a misbehaving helper. maxPDFHelperStderr
// keeps enough of stderr for an error message or a log line.
const (
	maxPDFHelperOutput = 32 << 20
	maxPDFHelperStderr = 4 << 10
)

// pdfHelperResult is the helper's stdout (one JSON document).
type pdfHelperResult struct {
	OK    bool      `json:"ok"`
	Pages []pdfPage `json:"pages"`
}

// parsePDF parses the PDF at path: in a helper process when
// Extractor.PDFHelper is set (production), else in this process. ok is
// false for an unreadable PDF. An error is ctx's, or a helper that timed
// out, crashed or exited non-zero — a transient failure the engine retries,
// not a verdict on the file.
func (x *Extractor) parsePDF(ctx context.Context, path string) ([]pdfPage, bool, error) {
	if len(x.PDFHelper) == 0 {
		pages, ok := parsePDFFile(path, x.logf)
		return pages, ok, nil
	}
	return x.runPDFHelper(ctx, path)
}

// runPDFHelper runs PDFHelper + path under pdfHelperTimeout. A timeout,
// crash or non-zero exit is an error carrying the helper's stderr. Output
// the helper did produce but that is oversized or malformed is an
// unreadable PDF (ok false) — a verdict, logged. What a clean helper run
// wrote to stderr (recovered parser panics) is logged too.
func (x *Extractor) runPDFHelper(ctx context.Context, path string) ([]pdfPage, bool, error) {
	cctx, cancel := context.WithTimeout(ctx, pdfHelperTimeout)
	defer cancel()
	argv := x.PDFHelper
	args := append(append([]string(nil), argv[1:]...), path)
	cmd := exec.CommandContext(cctx, argv[0], args...) //nolint:gosec // argv is our own executable, set by the caller
	out := &cappedBuffer{max: maxPDFHelperOutput}
	stderr := &cappedBuffer{max: maxPDFHelperStderr, truncate: true}
	cmd.Stdout, cmd.Stderr = out, stderr
	cmd.WaitDelay = 5 * time.Second
	err := cmd.Run()
	diag := strings.TrimSpace(stderr.buf.String())
	switch {
	case ctx.Err() != nil:
		return nil, false, ctx.Err()
	case errors.Is(cctx.Err(), context.DeadlineExceeded):
		return nil, false, fmt.Errorf("%w after %s: %s", errPDFHelperTimeout, pdfHelperTimeout, diag)
	case err != nil:
		return nil, false, fmt.Errorf("pdf helper: %w: %s", err, diag)
	}
	if diag != "" {
		x.logf("pdf helper: %s", diag)
	}
	return x.decodePDFHelper(out)
}

// decodePDFHelper reads a clean helper run's stdout; oversized or
// malformed output is an unreadable PDF, logged.
func (x *Extractor) decodePDFHelper(out *cappedBuffer) ([]pdfPage, bool, error) {
	if out.overflow {
		x.logf("pdf helper: output exceeds %d bytes; recording the PDF failed", maxPDFHelperOutput)
		return nil, false, nil
	}
	var res pdfHelperResult
	if err := json.Unmarshal(out.buf.Bytes(), &res); err != nil {
		x.logf("pdf helper: malformed output (%v); recording the PDF failed", err)
		return nil, false, nil
	}
	if !res.OK {
		return nil, false, nil // the helper's verdict: an unreadable PDF
	}
	if !validPages(res.Pages) {
		x.logf("pdf helper: invalid page list (%d pages); recording the PDF failed", len(res.Pages))
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
// and writes the pdfHelperResult JSON to w; diagnostics (recovered parser
// panics) go to diag, which the parent logs. The caller (a hidden CLI
// command) runs it in its own process, so a parse that never returns is
// killed by the parent's timeout instead of wedging the daemon.
func ServePDFHelper(w, diag io.Writer, path string) error {
	logger := log.New(diag, "", 0)
	pages, ok := parsePDFFile(path, logger.Printf)
	return json.NewEncoder(w).Encode(pdfHelperResult{OK: ok, Pages: pages})
}

// cappedBuffer keeps at most max bytes and records an overflow. An
// overflowing write fails, unless truncate is set: then the head is kept
// and the rest dropped silently (stderr, where more text must not turn a
// clean run into a failed one).
type cappedBuffer struct {
	buf      bytes.Buffer
	max      int
	overflow bool
	truncate bool
}

func (c *cappedBuffer) Write(p []byte) (int, error) {
	if c.buf.Len()+len(p) <= c.max {
		return c.buf.Write(p)
	}
	c.overflow = true
	if !c.truncate {
		return 0, io.ErrShortWrite
	}
	c.buf.Write(p[:c.max-c.buf.Len()])
	return len(p), nil
}
