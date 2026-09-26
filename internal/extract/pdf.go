package extract

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"unicode"

	"github.com/ledongthuc/pdf"

	"watchtower/internal/extsync"
)

// minTextRunes is the non-space rune count below which a PDF page is
// treated as having no text layer (a scan) and sent to OCR.
const minTextRunes = 20

// pdfText reads the text layer of the PDF at path, one section per page
// (up to MaxPDFPages). Pages without a text layer go to OCR (up to
// MaxOCRPages): no OCR → StatusOCRUnavailable, an OCR error →
// StatusOCRPending; the text pages are returned either way. An unreadable
// PDF (corrupt, encrypted) is StatusFailed.
func (x *Extractor) pdfText(ctx context.Context, path string) ([]extsync.Section, string, error) {
	pages, textless, ok := readPDF(path)
	if !ok {
		return nil, StatusFailed, nil
	}
	if len(textless) == 0 {
		return pageSections(pages), StatusOK, nil
	}
	if x.OCR == nil {
		return pageSections(pages), StatusOCRUnavailable, nil
	}
	if len(textless) > MaxOCRPages {
		textless = textless[:MaxOCRPages]
	}
	got, err := x.OCR.Recognize(ctx, path, textless)
	if err != nil {
		if ctx.Err() != nil {
			return nil, "", ctx.Err()
		}
		return pageSections(pages), StatusOCRPending, nil
	}
	for _, i := range textless {
		if t := strings.TrimSpace(got[i]); t != "" {
			pages[i] = t
		}
	}
	return pageSections(pages), StatusOK, nil
}

// readPDF returns the text of each page with a text layer (0-based index →
// text) and the indexes of the pages without one. ok is false when the
// file cannot be parsed; the parser's panics are recovered.
func readPDF(path string) (pages map[int]string, textless []int, ok bool) {
	defer func() {
		if recover() != nil {
			pages, textless, ok = nil, nil, false
		}
	}()
	f, r, err := pdf.Open(path)
	if err != nil {
		return nil, nil, false
	}
	defer f.Close()
	n := min(r.NumPage(), MaxPDFPages)
	pages = map[int]string{}
	fonts := map[string]*pdf.Font{}
	for i := range n {
		text := pageText(r.Page(i+1), fonts)
		if countNonSpace(text) < minTextRunes {
			textless = append(textless, i)
			continue
		}
		pages[i] = text
	}
	return pages, textless, true
}

// pageText is one page's text layer ("" when it has none or fails).
func pageText(p pdf.Page, fonts map[string]*pdf.Font) string {
	if p.V.IsNull() {
		return ""
	}
	for _, name := range p.Fonts() {
		if _, ok := fonts[name]; !ok {
			font := p.Font(name)
			fonts[name] = &font
		}
	}
	text, err := p.GetPlainText(fonts)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(text)
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

// pageSections renders pages in page order, headed "Page N" (1-based).
func pageSections(pages map[int]string) []extsync.Section {
	idx := make([]int, 0, len(pages))
	for i := range pages {
		idx = append(idx, i)
	}
	sort.Ints(idx)
	secs := make([]extsync.Section, 0, len(idx))
	for _, i := range idx {
		secs = append(secs, extsync.Section{Heading: fmt.Sprintf("Page %d", i+1), Text: pages[i]})
	}
	return secs
}

// imageText OCRs an image: no OCR → StatusOCRUnavailable, an OCR error →
// StatusOCRPending.
func (x *Extractor) imageText(ctx context.Context, path string) ([]extsync.Section, string, error) {
	if x.OCR == nil {
		return nil, StatusOCRUnavailable, nil
	}
	got, err := x.OCR.Recognize(ctx, path, nil)
	if err != nil {
		if ctx.Err() != nil {
			return nil, "", ctx.Err()
		}
		return nil, StatusOCRPending, nil
	}
	return oneSection(strings.TrimSpace(got[0])), StatusOK, nil
}
