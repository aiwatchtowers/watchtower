package extract

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"unicode"

	"github.com/ledongthuc/pdf"

	"watchtower/internal/extsync"
)

// minTextRunes is the non-space rune count below which a PDF page that
// carries images is treated as a scan and sent to OCR.
const minTextRunes = 20

// Page-tree walk bounds. The library's own Reader.Page follows /Kids with
// no visited set and spins forever on a cyclic tree, so the walk is ours.
const maxPDFTreeDepth = 32

var maxPDFTreeNodes = 4 * MaxPDFPages

// pdfPage is one parsed page: its text layer (possibly short) and whether
// it is a scan — short text on a page that carries image XObjects.
type pdfPage struct {
	Index int    `json:"index"`
	Text  string `json:"text"`
	Scan  bool   `json:"scan"`
}

// pdfText extracts the PDF at path, one section per page with text. Scan
// pages (up to MaxOCRPages) go to OCR; a page's own short text layer is
// kept when OCR is unavailable or finds nothing. The status is
// StatusOCRUnavailable / StatusOCRPending only when some scan page ended
// with no text at all; a blank page (no text, no image) never counts. An
// unreadable PDF — corrupt, encrypted, or one the helper process had to be
// killed for — is StatusFailed.
func (x *Extractor) pdfText(ctx context.Context, path string) ([]extsync.Section, string, error) {
	pages, ok, err := x.parsePDF(ctx, path)
	if err != nil || !ok {
		return nil, StatusFailed, err
	}
	scans := scanPages(pages)
	hasOCR, ocrFailed := x.OCR != nil, false
	if len(scans) > 0 && hasOCR {
		ocrFailed, err = recognizeScans(ctx, x.OCR, path, pages, scans, x.logf)
		switch {
		case errors.Is(err, ErrOCRUnavailable):
			hasOCR = false
		case err != nil:
			return nil, "", err
		}
	}
	return pageSections(pages), pdfStatus(pages, scans, hasOCR, ocrFailed), nil
}

// OCRBatchPages is how many scan pages one OCR call gets: each call has its
// own helper timeout, so a large scan is never all-or-nothing under one
// 60 s bound (MaxOCRPages / OCRBatchPages = at most 5 calls).
const OCRBatchPages = 10

// recognizeScans OCRs the scan pages in batches of OCRBatchPages and applies
// what each batch recognized. A failed batch loses only its own pages
// (failed reports that one did; its error is logged); ErrOCRUnavailable and
// a cancelled ctx stop the remaining batches and are returned.
func recognizeScans(ctx context.Context, ocr OCR, path string, pages []pdfPage, scans []int, logf logFunc) (failed bool, err error) {
	for start := 0; start < len(scans); start += OCRBatchPages {
		batch := scans[start:min(start+OCRBatchPages, len(scans))]
		got, err := ocr.Recognize(ctx, path, batch)
		switch {
		case ctx.Err() != nil:
			return false, ctx.Err()
		case errors.Is(err, ErrOCRUnavailable):
			return false, err
		case err != nil:
			logf("extract: OCR of PDF pages %v failed (kept for retry): %v", batch, err)
			failed = true
		default:
			applyOCR(pages, got)
		}
	}
	return failed, nil
}

// scanPages lists the 0-based indexes of the scan pages, at most
// MaxOCRPages.
func scanPages(pages []pdfPage) []int {
	var out []int
	for _, p := range pages {
		if p.Scan && len(out) < MaxOCRPages {
			out = append(out, p.Index)
		}
	}
	return out
}

// applyOCR replaces a page's text with the recognized text when OCR found
// any; otherwise the page keeps its own (short) text layer.
func applyOCR(pages []pdfPage, got map[int]string) {
	for i := range pages {
		if t := strings.TrimSpace(got[pages[i].Index]); t != "" {
			pages[i].Text = t
		}
	}
}

// pdfStatus: ok unless one of the OCR'd scan pages still has no text.
func pdfStatus(pages []pdfPage, scans []int, hasOCR, ocrFailed bool) string {
	missing := false
	for _, i := range scans {
		if strings.TrimSpace(pages[i].Text) == "" {
			missing = true
		}
	}
	switch {
	case !missing:
		return StatusOK
	case !hasOCR:
		return StatusOCRUnavailable
	case ocrFailed:
		return StatusOCRPending
	}
	return StatusOK // OCR ran and found no text: an image without words
}

// pageSections renders the pages with text in page order, headed
// "Page N" (1-based).
func pageSections(pages []pdfPage) []extsync.Section {
	secs := []extsync.Section{}
	for _, p := range pages {
		if t := strings.TrimSpace(p.Text); t != "" {
			secs = append(secs, extsync.Section{Heading: fmt.Sprintf("Page %d", p.Index+1), Text: t})
		}
	}
	return secs
}

// parsePDFFile parses the PDF at path in this process: the bounded
// page-tree walk, then each page's text layer. ok is false when the file
// cannot be parsed or has no page; panics are recovered. The library can
// still loop forever inside NewReader on a crafted cross-reference chain
// (a self-referencing /Prev) or object stream (/Extends cycle), which no
// caller-side bound can stop — production therefore runs this in a helper
// process under a hard timeout (see Extractor.PDFHelper).
func parsePDFFile(path string, logf logFunc) (pages []pdfPage, ok bool) {
	defer func() {
		if p := recover(); p != nil {
			logf("extract: recovered panic parsing a PDF: %v", p)
			pages, ok = nil, false
		}
	}()
	f, r, err := pdf.Open(path)
	if err != nil {
		return nil, false
	}
	defer func() { _ = f.Close() }()
	nodes := pageNodes(r.Trailer().Key("Root").Key("Pages"))
	if len(nodes) == 0 {
		return nil, false
	}
	pages = make([]pdfPage, len(nodes))
	for i, v := range nodes {
		pages[i] = readPage(i, v, logf)
	}
	return pages, true
}

// pageNodes walks the page tree from root depth-first, visiting at most
// maxPDFTreeNodes nodes and maxPDFTreeDepth levels, and returns up to
// MaxPDFPages page nodes. /Count is never trusted.
func pageNodes(root pdf.Value) []pdf.Value {
	w := &treeWalk{budget: maxPDFTreeNodes}
	w.visit(root, 0)
	return w.pages
}

type treeWalk struct {
	pages  []pdf.Value
	budget int
}

func (w *treeWalk) visit(v pdf.Value, depth int) {
	if w.budget <= 0 || depth > maxPDFTreeDepth || len(w.pages) >= MaxPDFPages {
		return
	}
	w.budget--
	switch v.Key("Type").Name() {
	case "Page":
		w.pages = append(w.pages, v)
	case "Pages":
		kids := v.Key("Kids")
		for i := 0; i < kids.Len() && w.budget > 0 && len(w.pages) < MaxPDFPages; i++ {
			w.visit(kids.Index(i), depth+1)
		}
	}
}

// readPage reads one page; a panic in it loses only this page. A page whose
// text layer cannot be read is a scan candidate — OCR gets a chance at it —
// rather than blank.
func readPage(i int, v pdf.Value, logf logFunc) pdfPage {
	p := pdfPage{Index: i}
	res, hasImages := pageResources(v, logf)
	text, ok := pageText(v, res, logf)
	p.Text = text
	p.Scan = !ok || (hasImages && countNonSpace(p.Text) < minTextRunes)
	return p
}

// pageResources returns the page's (inherited) resources and whether they
// carry any XObject. Parent links are followed at most maxPDFTreeDepth
// times — the library's own lookup has no bound.
func pageResources(v pdf.Value, logf logFunc) (res pdf.Value, hasImages bool) {
	defer func() {
		if p := recover(); p != nil {
			logf("extract: recovered panic reading PDF page resources: %v", p)
			res, hasImages = pdf.Value{}, false
		}
	}()
	for n := 0; n <= maxPDFTreeDepth && !v.IsNull(); n++ {
		if r := v.Key("Resources"); !r.IsNull() {
			return r, len(r.Key("XObject").Keys()) > 0
		}
		v = v.Key("Parent")
	}
	return pdf.Value{}, false
}

// pageText is the page's trimmed text layer ("" when it has none); ok is
// false when reading it failed (an error or a recovered panic, logged).
// Fonts are resolved from res here, so the library never walks the
// unbounded parent chain itself.
func pageText(v pdf.Value, res pdf.Value, logf logFunc) (text string, ok bool) {
	defer func() {
		if p := recover(); p != nil {
			logf("extract: recovered panic reading a PDF page's text: %v", p)
			text, ok = "", false
		}
	}()
	fontDict := res.Key("Font")
	fonts := map[string]*pdf.Font{}
	for _, name := range fontDict.Keys() {
		fonts[name] = &pdf.Font{V: fontDict.Key(name)}
	}
	t, err := pdf.Page{V: v}.GetPlainText(fonts)
	if err != nil {
		logf("extract: reading a PDF page's text: %v; sending it to OCR", err)
		return "", false
	}
	return strings.TrimSpace(t), true
}

func countNonSpace(s string) int {
	n := 0
	for _, r := range s {
		if !unicode.IsSpace(r) {
			n++
		}
	}
	return n
}

// imageText OCRs an image: no OCR or a rejected helper →
// StatusOCRUnavailable, an OCR error → StatusOCRPending.
func (x *Extractor) imageText(ctx context.Context, path string) ([]extsync.Section, string, error) {
	if x.OCR == nil {
		return nil, StatusOCRUnavailable, nil
	}
	got, err := x.OCR.Recognize(ctx, path, nil)
	switch {
	case ctx.Err() != nil:
		return nil, "", ctx.Err()
	case errors.Is(err, ErrOCRUnavailable):
		return nil, StatusOCRUnavailable, nil
	case err != nil:
		return nil, StatusOCRPending, nil //nolint:nilerr // an OCR failure is a status (retried later), not an extraction error
	}
	return oneSection(strings.TrimSpace(got[0])), StatusOK, nil
}
