package extract

import (
	"bytes"
	"errors"
	"io"
	"strings"
	"unicode/utf8"

	"golang.org/x/net/html"
	"golang.org/x/text/encoding"
	"golang.org/x/text/encoding/charmap"
	"golang.org/x/text/encoding/unicode"

	"watchtower/internal/extsync"
)

// utf8BOM is stripped from the start of text input.
var utf8BOM = []byte{0xEF, 0xBB, 0xBF}

// utf16BOMLE/utf16BOMBE are the byte order marks that identify UTF-16 text
// with no other signal (there is no MIME parameter for it here — these
// files arrive as plain "text/plain" attachments).
var (
	utf16BOMLE = []byte{0xFF, 0xFE}
	utf16BOMBE = []byte{0xFE, 0xFF}
)

// readUTF8 reads r (≤ MaxDownload) as text with LF line endings. UTF-8 (with
// or without a BOM) is read directly; failing that, a UTF-16 BOM or a clean
// windows-1251 decode (common Russian/Ukrainian-locale exports) are tried as
// fallbacks before giving up. Text that still isn't recognized is
// StatusFailed, input above MaxDownload StatusTooLarge.
func readUTF8(r io.Reader) (text, status string, err error) {
	b, err := readCapped(r)
	if errors.Is(err, errTooLarge) {
		return "", StatusTooLarge, nil
	}
	if err != nil {
		return "", "", err
	}
	if decoded, ok := decodeByBOM(b); ok {
		b = decoded
	} else {
		b = bytes.TrimPrefix(b, utf8BOM)
		if !utf8.Valid(b) {
			decoded, ok := decodeCleanly(b, charmap.Windows1251)
			if !ok {
				return "", StatusFailed, nil
			}
			b = decoded
		}
	}
	s := strings.ReplaceAll(string(b), "\r\n", "\n")
	return strings.ReplaceAll(s, "\r", "\n"), StatusOK, nil
}

// decodeByBOM decodes b as UTF-16 when it opens with a UTF-16 byte order
// mark, else reports ok=false (no BOM = not this function's problem: the
// caller's own UTF-8-BOM/utf8.Valid path handles everything else).
func decodeByBOM(b []byte) ([]byte, bool) {
	switch {
	case bytes.HasPrefix(b, utf16BOMLE):
		return decodeCleanly(b, unicode.UTF16(unicode.LittleEndian, unicode.ExpectBOM))
	case bytes.HasPrefix(b, utf16BOMBE):
		return decodeCleanly(b, unicode.UTF16(unicode.BigEndian, unicode.ExpectBOM))
	default:
		return nil, false
	}
}

// decodeCleanly decodes b with enc, reporting ok=false when the decode
// itself errors or falls back to the Unicode replacement character anywhere
// — a single-byte charmap like windows-1251 maps every byte to *some* rune,
// so a wrong-encoding guess would otherwise "succeed" into garbage instead
// of failing the way invalid UTF-8 does.
func decodeCleanly(b []byte, enc encoding.Encoding) ([]byte, bool) {
	out, err := enc.NewDecoder().Bytes(b)
	if err != nil || bytes.ContainsRune(out, utf8.RuneError) {
		return nil, false
	}
	return out, true
}

// plainText is one section holding the whole text (text, markdown, csv,
// json, xml).
func plainText(r io.Reader) ([]extsync.Section, string, error) {
	text, status, err := readUTF8(r)
	if err != nil || status != StatusOK {
		return nil, status, err
	}
	return oneSection(strings.TrimSpace(text)), StatusOK, nil
}

func oneSection(text string) []extsync.Section {
	if text == "" {
		return nil
	}
	return []extsync.Section{{Text: text}}
}

// htmlText strips an HTML document to its text: tags dropped, block
// elements break lines, whitespace collapsed, <head>/<script>/<style>
// skipped.
func htmlText(r io.Reader) ([]extsync.Section, string, error) {
	text, status, err := readUTF8(r)
	if err != nil || status != StatusOK {
		return nil, status, err
	}
	return oneSection(stripHTML(text)), StatusOK, nil
}

// skippedElements carry no document text. "head" is handled separately (see
// htmlStripper.tag) because HTML5 lets a document omit </head> entirely — a
// <body> start tag implicitly closes it, and nothing else does.
var skippedElements = map[string]bool{"script": true, "style": true, "noscript": true, "template": true}

// blockElements end the current line.
var blockElements = map[string]bool{
	"p": true, "div": true, "br": true, "li": true, "tr": true, "table": true, "ul": true, "ol": true,
	"h1": true, "h2": true, "h3": true, "h4": true, "h5": true, "h6": true, "pre": true, "blockquote": true,
	"section": true, "article": true, "header": true, "footer": true, "hr": true, "dt": true, "dd": true,
	"title": true, "body": true, "main": true, "nav": true, "aside": true, "figcaption": true,
}

// stripHTML renders an HTML document as text lines. The cells of one
// table row are joined with " | "; a row is a line.
func stripHTML(doc string) string {
	z := html.NewTokenizer(strings.NewReader(doc))
	st := &htmlStripper{}
	for {
		switch z.Next() {
		case html.ErrorToken:
			st.flush()
			return strings.Join(st.lines, "\n")
		case html.TextToken:
			if st.skip == 0 && !st.inHead {
				st.cur.Write(z.Text())
			}
		case html.StartTagToken, html.SelfClosingTagToken, html.EndTagToken:
			st.tag(z.Token())
		case html.CommentToken, html.DoctypeToken:
		}
	}
}

// htmlStripper is stripHTML's state.
type htmlStripper struct {
	lines  []string
	cur    strings.Builder
	skip   int  // depth inside skippedElements
	inHead bool // inside <head>, explicitly or implicitly (see tag)
	cells  int  // cells opened in the current table row
}

func (st *htmlStripper) flush() {
	if line := strings.Join(strings.Fields(st.cur.String()), " "); line != "" {
		st.lines = append(st.lines, line)
	}
	st.cur.Reset()
}

// tag handles one tag token: skipped-element depth, cell separators, and
// line ends at block elements (tr among them).
func (st *htmlStripper) tag(tt html.Token) {
	name := tt.Data
	if name == "head" {
		st.inHead = tt.Type == html.StartTagToken
		return
	}
	if name == "body" && tt.Type == html.StartTagToken {
		// HTML5 §13.2.6.4.6: a <body> start tag implicitly closes an
		// unclosed <head> — real-world HTML omitting </head> entirely
		// relies on this, and without it every byte after a missing
		// </head> (i.e. the whole document) reads as skipped head content.
		st.inHead = false
	}
	if skippedElements[name] {
		if tt.Type == html.StartTagToken {
			st.skip++
		}
		if tt.Type == html.EndTagToken {
			st.skip = max(st.skip-1, 0)
		}
		return
	}
	if (name == "td" || name == "th") && tt.Type == html.StartTagToken {
		if st.cells > 0 {
			st.cur.WriteString(" | ")
		}
		st.cells++
		return
	}
	if name == "tr" {
		st.cells = 0
	}
	if blockElements[name] {
		st.flush()
	}
}
