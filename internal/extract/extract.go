// Package extract turns attachment bytes into text sections (spec
// docs/superpowers/specs/2026-09-26-confluence-knowledge-connector-design.md
// §8): plain text, HTML, OOXML (docx/xlsx/pptx), the PDF text layer, and —
// through an optional OCR — scanned PDF pages and images. It never keeps the
// bytes (EXT-03): whatever needs random access is spooled into a 0600 temp
// file under TempDir and removed before Extract returns.
package extract

import (
	"context"
	"errors"
	"fmt"
	"io"
	"mime"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf8"

	"watchtower/internal/extsync"
)

// Caps (global constraints; no config keys).
const (
	MaxDownload  = 25 << 20
	MaxTextRunes = 200_000
	MaxPDFPages  = 300
	MaxOCRPages  = 50
)

// Extraction statuses (the ext_documents.extract_status CHECK).
const (
	StatusOK             = "ok"
	StatusSkippedType    = "skipped_type"
	StatusTooLarge       = "too_large"
	StatusOCRPending     = "ocr_pending"
	StatusOCRUnavailable = "ocr_unavailable"
	StatusFailed         = "failed"
)

// OCR recognizes text in a file Extract spooled into TempDir. pages lists
// the 0-based PDF page indexes to recognize (nil for an image); the result
// maps a page index (0 for an image) to its text. Task 10 implements it; a
// nil OCR means OCR is unavailable.
type OCR interface {
	Recognize(ctx context.Context, path string, pages []int) (map[int]string, error)
}

// Extractor implements extsync.Extractor. TempDir holds the spooled files
// (Config.WorkspaceDir()/tmp/extract in production); it is created 0700 on
// first use. PDFHelper is the argv prefix of a helper process that parses
// a PDF out of process (path appended; ServePDFHelper is its body) under a
// hard timeout — the PDF library can loop forever on crafted input, which
// only killing a process can stop. Empty parses in process (tests only).
type Extractor struct {
	TempDir   string
	OCR       OCR
	PDFHelper []string
}

var (
	_ extsync.Extractor     = (*Extractor)(nil)
	_ extsync.OCRCapable    = (*Extractor)(nil)
	_ extsync.TypeSupporter = (*Extractor)(nil)
)

// HasOCR reports whether an OCR is wired (controller ruling R2).
func (x *Extractor) HasOCR() bool { return x.OCR != nil }

// Supports reports whether Extract handles the type: exactly the types for
// which it never answers StatusSkippedType.
func (x *Extractor) Supports(mediaType, name string) bool {
	return detect(mediaType, name) != kindUnknown
}

// Extract returns the text sections of one attachment and its extraction
// status. Content problems (invalid UTF-8, a corrupt archive or PDF, a zip
// bomb, an unsupported type) are statuses with a nil error. An error means
// the extraction could not run: reading r failed (a network error, or a
// size cap the reader enforces — matchable with errors.Is), ctx was
// cancelled, or the temp file could not be written. Every temp file is
// removed before Extract returns, a panicking parser included.
func (x *Extractor) Extract(ctx context.Context, mediaType, name string, r io.Reader) (secs []extsync.Section, status string, err error) {
	defer func() {
		if p := recover(); p != nil {
			secs, status, err = nil, StatusFailed, nil
		}
	}()
	secs, status, err = x.dispatch(ctx, detect(mediaType, name), name, r)
	if err != nil || status == StatusFailed || status == StatusTooLarge || status == StatusSkippedType {
		return nil, status, err
	}
	return capSections(secs, MaxTextRunes), status, nil
}

func (x *Extractor) dispatch(ctx context.Context, k kind, name string, r io.Reader) ([]extsync.Section, string, error) {
	switch k {
	case kindText:
		return plainText(r)
	case kindHTML:
		return htmlText(r)
	case kindDocx, kindXlsx, kindPptx:
		return x.spooled(ctx, name, r, func(path string) ([]extsync.Section, string, error) {
			return ooxmlText(k, path)
		})
	case kindPDF:
		return x.spooled(ctx, name, r, func(path string) ([]extsync.Section, string, error) {
			return x.pdfText(ctx, path)
		})
	case kindImage:
		return x.spooled(ctx, name, r, func(path string) ([]extsync.Section, string, error) {
			return x.imageText(ctx, path)
		})
	case kindUnknown:
	}
	return nil, StatusSkippedType, nil
}

// errTooLarge marks input above MaxDownload.
var errTooLarge = errors.New("extract: input exceeds the download cap")

// readCapped reads all of r, up to MaxDownload bytes.
func readCapped(r io.Reader) ([]byte, error) {
	b, err := io.ReadAll(io.LimitReader(r, MaxDownload+1))
	if err != nil {
		return nil, fmt.Errorf("extract: reading: %w", err)
	}
	if len(b) > MaxDownload {
		return nil, errTooLarge
	}
	return b, nil
}

// spooled copies r into a private temp file under TempDir, runs fn on it
// and removes the file, whatever fn does.
func (x *Extractor) spooled(ctx context.Context, name string, r io.Reader, fn func(path string) ([]extsync.Section, string, error)) ([]extsync.Section, string, error) {
	path, cleanup, err := x.spool(ctx, name, r)
	defer cleanup()
	if errors.Is(err, errTooLarge) {
		return nil, StatusTooLarge, nil
	}
	if err != nil {
		return nil, "", err
	}
	return fn(path)
}

// spool writes r (≤ MaxDownload bytes) to a new 0600 file in TempDir. The
// returned cleanup removes it and is always safe to call.
func (x *Extractor) spool(ctx context.Context, name string, r io.Reader) (string, func(), error) {
	noop := func() {}
	if x.TempDir == "" {
		return "", noop, errors.New("extract: no temp dir configured")
	}
	if err := ctx.Err(); err != nil {
		return "", noop, err
	}
	if err := os.MkdirAll(x.TempDir, 0o700); err != nil {
		return "", noop, fmt.Errorf("extract: creating temp dir: %w", err)
	}
	f, err := os.CreateTemp(x.TempDir, "att-*"+safeExt(name))
	if err != nil {
		return "", noop, fmt.Errorf("extract: creating temp file: %w", err)
	}
	path := f.Name()
	cleanup := func() {
		_ = f.Close()
		_ = os.Remove(path)
	}
	n, err := io.Copy(f, io.LimitReader(r, MaxDownload+1))
	if err == nil {
		err = f.Close()
	}
	switch {
	case err != nil:
		return "", cleanup, fmt.Errorf("extract: spooling: %w", err)
	case n > MaxDownload:
		return "", cleanup, errTooLarge
	}
	return path, cleanup, nil
}

// safeExt keeps a short alphanumeric extension of name for the temp file
// (an OCR helper may sniff by extension), never a path element.
func safeExt(name string) string {
	ext := strings.ToLower(filepath.Ext(name))
	if len(ext) < 2 || len(ext) > 6 {
		return ""
	}
	for _, c := range ext[1:] {
		if (c < 'a' || c > 'z') && (c < '0' || c > '9') {
			return ""
		}
	}
	return ext
}

// kind is the extraction route of an attachment.
type kind int

const (
	kindUnknown kind = iota
	kindText
	kindHTML
	kindDocx
	kindXlsx
	kindPptx
	kindPDF
	kindImage
)

var byMediaType = map[string]kind{
	"text/plain": kindText, "text/markdown": kindText, "text/x-markdown": kindText, "text/csv": kindText,
	"application/json": kindText, "text/json": kindText, "application/xml": kindText, "text/xml": kindText,
	"text/html": kindHTML, "application/xhtml+xml": kindHTML,
	"application/vnd.openxmlformats-officedocument.wordprocessingml.document":   kindDocx,
	"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet":         kindXlsx,
	"application/vnd.openxmlformats-officedocument.presentationml.presentation": kindPptx,
	"application/pdf": kindPDF,
	"image/png":       kindImage, "image/jpeg": kindImage, "image/heic": kindImage, "image/heif": kindImage,
	"image/tiff": kindImage, "image/gif": kindImage,
}

var byExtension = map[string]kind{
	".txt": kindText, ".md": kindText, ".markdown": kindText, ".csv": kindText, ".json": kindText, ".xml": kindText,
	".html": kindHTML, ".htm": kindHTML,
	".docx": kindDocx, ".xlsx": kindXlsx, ".pptx": kindPptx, ".pdf": kindPDF,
	".png": kindImage, ".jpg": kindImage, ".jpeg": kindImage, ".heic": kindImage, ".heif": kindImage,
	".tif": kindImage, ".tiff": kindImage, ".gif": kindImage,
}

// detect routes by media type (parameters and case ignored), then by the
// file name's extension.
func detect(mediaType, name string) kind {
	mt := strings.ToLower(strings.TrimSpace(mediaType))
	if parsed, _, err := mime.ParseMediaType(mt); err == nil {
		mt = parsed
	}
	if k, ok := byMediaType[mt]; ok {
		return k
	}
	return byExtension[strings.ToLower(filepath.Ext(name))]
}

// capSections keeps at most limit runes across the sections' headings and
// texts: the section crossing the limit is cut, the rest dropped.
func capSections(secs []extsync.Section, limit int) []extsync.Section {
	left := limit
	for i, s := range secs {
		h, t := utf8.RuneCountInString(s.Heading), utf8.RuneCountInString(s.Text)
		if h+t <= left {
			left -= h + t
			continue
		}
		if h >= left {
			return secs[:i]
		}
		secs[i].Text = string([]rune(s.Text)[:left-h])
		return secs[:i+1]
	}
	return secs
}
