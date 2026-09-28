package extract

import (
	"bytes"
	"errors"
	"io"
	"mime"
	"strings"
	"unicode/utf8"

	"golang.org/x/net/html"
	"golang.org/x/net/html/charset"
	"golang.org/x/text/encoding"
	xunicode "golang.org/x/text/encoding/unicode"

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

// readUTF8 reads r (≤ MaxDownload) as text with LF line endings: UTF-8 (with
// or without a BOM) is read directly, a UTF-16 BOM decoded as UTF-16 —
// anything else is StatusFailed, input above MaxDownload StatusTooLarge.
//
// There is deliberately no undeclared single-byte-charset guess here (a
// windows-1251/koi8-r/koi8-u attempt was tried across three review rounds —
// see docs/backlog/2026-09-27-review-low-priority-pr3-confluence-go.md's
// "cp1251/KOI8 detection withdrawn" entry — and every version regressed:
// case-based word rules rejected real prose too eagerly or not eagerly
// enough, and letter-frequency scoring accepted Greek/Hebrew/short-CJK
// mojibake and, worse, turned an almost-entirely-valid UTF-8 file carrying
// one stray byte into full-document mojibake, a real regression from this
// function's UTF-8-only behavior on main). A byte stream that isn't valid
// UTF-8 and carries no BOM fails outright, exactly as before this PR's
// encoding-detection work began. There is no declared-charset step here
// either: a plain-text attachment carries no meta tag and this package sees
// no MIME header to read a charset param from. htmlText is the one caller
// with a real declaration available, and it decodes before ever reaching
// this function.
func readUTF8(r io.Reader) (text, status string, err error) {
	b, err := readCapped(r)
	if errors.Is(err, errTooLarge) {
		return "", StatusTooLarge, nil
	}
	if err != nil {
		return "", "", err
	}
	if text, ok := decodeDirect(b); ok {
		return text, StatusOK, nil
	}
	return "", StatusFailed, nil
}

// decodeDirect handles the two unambiguous cases: a UTF-16 byte-order mark,
// or already-valid UTF-8 (with or without its own BOM). ok=false means
// neither applies — the caller fails rather than guessing (see readUTF8's
// doc comment).
func decodeDirect(b []byte) (text string, ok bool) {
	if decoded, gotBOM := decodeByBOM(b); gotBOM {
		return normalizeNewlines(string(decoded)), true
	}
	trimmed := bytes.TrimPrefix(b, utf8BOM)
	if utf8.Valid(trimmed) {
		return normalizeNewlines(string(trimmed)), true
	}
	return "", false
}

// normalizeNewlines rewrites CRLF/CR to LF.
func normalizeNewlines(s string) string {
	s = strings.ReplaceAll(s, "\r\n", "\n")
	return strings.ReplaceAll(s, "\r", "\n")
}

// decodeByBOM decodes b as UTF-16 when it opens with a UTF-16 byte order
// mark, else reports ok=false (no BOM = not this function's problem: the
// caller's own UTF-8-BOM/utf8.Valid path handles everything else).
func decodeByBOM(b []byte) ([]byte, bool) {
	switch {
	case bytes.HasPrefix(b, utf16BOMLE):
		return decodeCleanly(b, xunicode.UTF16(xunicode.LittleEndian, xunicode.ExpectBOM))
	case bytes.HasPrefix(b, utf16BOMBE):
		return decodeCleanly(b, xunicode.UTF16(xunicode.BigEndian, xunicode.ExpectBOM))
	default:
		return nil, false
	}
}

// decodeCleanly decodes b with enc, reporting ok=false when the decode
// itself errors or falls back to the Unicode replacement character anywhere.
// Used only for the unambiguous UTF-16-by-BOM case (decodeByBOM) — there is
// no undeclared single-byte-charset guess in this package (see readUTF8's
// doc comment).
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

// htmlText strips an HTML document to its text: tags dropped, block elements
// break lines, whitespace collapsed, <head>/<script>/<style> skipped. A
// charset the document declares itself — the MIME Content-Type's charset
// param, a byte-order mark, or an HTML <meta charset>/http-equiv
// Content-Type tag — is honored unconditionally, before any guess (HTML5's
// own "determining the character encoding" algorithm, minus its final
// windows-1252-by-default step — an UNDECLARED document instead just gets
// decodeDirect's UTF-16-BOM/valid-UTF-8 check, same as plain text; there is
// no single-byte-charset guess in this package at all, see readUTF8's doc
// comment). A declared charset whose decode is mostly (or, for a declared
// utf-8, at all) U+FFFD replacement characters is treated as a wrong
// declaration — see tooManyReplacementRunes — and falls back only to
// decodeDirect, never to a guess.
func htmlText(mediaType string, r io.Reader) ([]extsync.Section, string, error) {
	b, err := readCapped(r)
	if errors.Is(err, errTooLarge) {
		return nil, StatusTooLarge, nil
	}
	if err != nil {
		return nil, "", err
	}
	if enc, name, ok := declaredHTMLEncoding(mediaType, b); ok {
		out, derr := enc.NewDecoder().Bytes(b)
		if derr != nil {
			return nil, StatusFailed, nil //nolint:nilerr // a declared-but-broken decode is a content status, not a Go error
		}
		text := normalizeNewlines(string(bytes.TrimPrefix(out, utf8BOM)))
		if !tooManyReplacementRunes(text, name == "utf-8") {
			return oneSection(stripHTML(text)), StatusOK, nil
		}
		// The declared charset decoded without a Go error but is (mostly, or
		// for a declared utf-8 at all) U+FFFD replacement characters — the
		// declaration was wrong, not the content. There is no undeclared
		// guess to fall back to (see readUTF8's doc comment): decodeDirect
		// below still gets a chance (a real BOM, or genuinely valid UTF-8 a
		// wrong declaration masked), but failing that this fails outright
		// rather than indexing "�" as ok or guessing a single-byte charset.
	}
	if text, ok := decodeDirect(b); ok {
		return oneSection(stripHTML(text)), StatusOK, nil
	}
	return nil, StatusFailed, nil
}

// declaredHTMLEncoding reports a charset HTML itself declares — the encoding
// to decode with, and its canonical name (used by the caller's replacement-
// character check: a declared "utf-8" gets zero tolerance, see
// tooManyReplacementRunes) — from a byte-order mark or the MIME
// Content-Type's charset param (both "certain" per charset.DetermineEncoding),
// or an HTML <meta charset>/http-equiv Content-Type tag (scanMetaCharset) —
// charset.DetermineEncoding's own meta detection is, through its public API,
// indistinguishable from its final windows-1252-by-default guess (both
// return certain=false with no way to tell them apart), so this package runs
// its own narrow meta scan instead of trusting an uncertain result from the
// library.
func declaredHTMLEncoding(mediaType string, b []byte) (enc encoding.Encoding, name string, ok bool) {
	if enc, name, certain := charset.DetermineEncoding(b, mediaType); certain {
		return enc, name, true
	}
	label, found := scanMetaCharset(b)
	if !found {
		return nil, "", false
	}
	if html5MetaUTF16Labels[strings.ToLower(strings.TrimSpace(label))] {
		// HTML5's encoding-sniffing algorithm remaps a META-DECLARED (never
		// a real byte-order-mark-backed) UTF-16/"unicode" label to UTF-8: a
		// document actually encoded in UTF-16 could never spell out an
		// ASCII <meta charset="utf-16"> tag in the first place without a
		// BOM, so the label only ever survives from an old tool (e.g. Word's
		// "Web Page" export) that re-saved as UTF-8 but left the legacy tag
		// behind. A real UTF-16 document is instead caught by its BOM, above
		// — an unambiguous, reliable signal this carve-out does not touch.
		return xunicode.UTF8, "utf-8", true
	}
	if enc, name := charset.Lookup(label); enc != nil && name != "" {
		return enc, name, true
	}
	return nil, "", false
}

// html5MetaUTF16Labels are the charset labels HTML5 remaps to UTF-8 when
// found via a <meta> tag (see declaredHTMLEncoding).
var html5MetaUTF16Labels = map[string]bool{
	"utf-16": true, "utf-16le": true, "utf-16be": true, "unicode": true,
}

// replacementShareMax bounds how much of a declared-charset decode may be
// U+FFFD before it counts as a wrong declaration rather than real content: a
// document can legitimately contain an occasional stray replacement
// character (one corrupted byte in an otherwise-fine file), but one that's
// mostly replacement characters was decoded under the wrong charset.
//
// Accepted limit (round-3 finding R3-5): this check cannot see a WRONG
// declared SINGLE-BYTE charset (windows-1252, iso-8859-1, ...) at all —
// every byte maps to some character in a single-byte charmap, never a
// replacement one, so a mislabelled document still decodes "cleanly" as
// mojibake. This is the same "a document that explicitly declares a charset
// is trusted over any guess" rule the whole declared-charset path exists to
// implement (matching browser behavior), so it is deliberately not
// special-cased further; see docs/backlog and the PR description for the
// record of this trade-off.
const replacementShareMax = 0.10

// tooManyReplacementRunes reports whether text carries enough U+FFFD runes
// to call its declared-charset decode a wrong declaration. zeroTolerance
// requests zero tolerance: UTF-8 validity is unambiguous, so a declared
// "utf-8" that produces even one replacement character proves the bytes are
// not what was declared (golang.org/x/text's UTF-8 decoder otherwise
// silently substitutes U+FFFD for invalid bytes with no Go error at all —
// the StatusOK-with-garbage class this whole feature exists to catch).
// Every other declared encoding gets replacementShareMax instead, since a
// multi-byte or stateful charmap can have legitimate edge bytes a strict
// zero-tolerance rule would misfire on.
func tooManyReplacementRunes(text string, zeroTolerance bool) bool {
	total, replacement := 0, 0
	for _, r := range text {
		total++
		if r == utf8.RuneError {
			replacement++
		}
	}
	if total == 0 {
		return false
	}
	if zeroTolerance {
		return replacement > 0
	}
	return float64(replacement) > replacementShareMax*float64(total)
}

// scanMetaCharset finds an HTML <meta charset="..."> or <meta
// http-equiv="Content-Type" content="...;charset=..."> tag within the first
// 1024 bytes (HTML5's own bound — charset.DetermineEncoding scans the same
// window) and returns its charset label.
func scanMetaCharset(b []byte) (label string, ok bool) {
	if len(b) > 1024 {
		b = b[:1024]
	}
	z := html.NewTokenizer(bytes.NewReader(b))
	for {
		tt := z.Next()
		if tt == html.ErrorToken {
			return "", false
		}
		if tt != html.StartTagToken && tt != html.SelfClosingTagToken {
			continue
		}
		tok := z.Token()
		if tok.Data != "meta" {
			continue
		}
		attrs := map[string]string{}
		for _, a := range tok.Attr {
			attrs[strings.ToLower(a.Key)] = a.Val
		}
		if cs := strings.TrimSpace(attrs["charset"]); cs != "" {
			return cs, true
		}
		if strings.EqualFold(attrs["http-equiv"], "content-type") {
			if _, params, err := mime.ParseMediaType(attrs["content"]); err == nil {
				if cs := params["charset"]; cs != "" {
					return cs, true
				}
			}
		}
	}
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
			text := z.Text()
			if st.inHead && st.headChildDepth == 0 && len(bytes.TrimSpace(text)) > 0 {
				// HTML5 §13.2.6.4.6: non-whitespace character data sitting
				// DIRECTLY in <head> (not inside an allowed child like
				// <title>, guarded by headChildDepth) is ALSO the "in head"
				// insertion mode's "anything else" case — the same implicit
				// close a stray tag triggers (see htmlStripper.tag) — so
				// text with no closing tag at all (<html><head>Hello<p>x)
				// isn't dropped as head content.
				st.inHead = false
			}
			if st.skip == 0 && !st.inHead {
				st.cur.Write(text)
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
	// headChildDepth is the nesting depth inside a headContainerTags element
	// (title, style, ...) while inHead: head's OWN text (character data with
	// no wrapping element at all) closes it, per HTML5 — a nested allowed
	// child's text, like <title>'s, does not.
	headChildDepth int
	cells          int // cells opened in the current table row
}

func (st *htmlStripper) flush() {
	if line := strings.Join(strings.Fields(st.cur.String()), " "); line != "" {
		st.lines = append(st.lines, line)
	}
	st.cur.Reset()
}

// headAllowedTags are the only elements HTML5 permits inside <head>
// (https://html.spec.whatwg.org/multipage/semantics.html#the-head-element).
// Any other opening tag while inHead is the "in head" insertion mode's
// "anything else" case (HTML5 §13.2.6.4.6): it pops head and reprocesses the
// tag after it — <body> is the common case, but the same rule fires for any
// ordinary content tag (a stray <p>, say) appearing with no <body> at all.
var headAllowedTags = map[string]bool{
	"title": true, "meta": true, "link": true, "style": true,
	"script": true, "base": true, "noscript": true, "template": true,
}

// headContainerTags are the headAllowedTags elements that have a real end
// tag (title/style/script/noscript/template) — the subset headChildDepth
// tracks. meta/link/base are void: they never get a matching EndTagToken,
// so counting them here would leave headChildDepth stuck above zero after
// the first one (a real <head> almost always has one), permanently
// disabling the text-closes-head rule above. They still belong in
// headAllowedTags (an opening one must not itself close head), just not in
// this narrower set.
var headContainerTags = map[string]bool{
	"title": true, "style": true, "script": true, "noscript": true, "template": true,
}

// tag handles one tag token: skipped-element depth, cell separators, and
// line ends at block elements (tr among them).
func (st *htmlStripper) tag(tt html.Token) {
	name := tt.Data
	if name == "head" {
		st.inHead = tt.Type == html.StartTagToken
		st.headChildDepth = 0
		return
	}
	opening := tt.Type == html.StartTagToken || tt.Type == html.SelfClosingTagToken
	if st.inHead {
		switch {
		case headContainerTags[name]:
			if tt.Type == html.StartTagToken {
				st.headChildDepth++
			} else if tt.Type == html.EndTagToken {
				st.headChildDepth = max(st.headChildDepth-1, 0)
			}
		case headAllowedTags[name]:
			// A void head-only tag (meta/link/base): allowed in head, but
			// never wraps child text, so headChildDepth is untouched.
		case opening:
			st.inHead = false
		}
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
