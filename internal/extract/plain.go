package extract

import (
	"bytes"
	"errors"
	"io"
	"mime"
	"strings"
	"unicode"
	"unicode/utf8"

	"golang.org/x/net/html"
	"golang.org/x/net/html/charset"
	"golang.org/x/text/encoding"
	"golang.org/x/text/encoding/charmap"
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

// readUTF8 reads r (≤ MaxDownload) as text with LF line endings. UTF-8 (with
// or without a BOM) is read directly; failing that, a UTF-16 BOM or windows-
// 1251 — only when the decoded text plausibly reads as Russian/Ukrainian, see
// looksLikeCyrillicPlainText — are tried as fallbacks before giving up. Text
// that still isn't recognized is StatusFailed, input above MaxDownload
// StatusTooLarge. There is no declared-charset step here: a plain-text
// attachment carries no meta tag and this package sees no MIME header to
// read a charset param from. htmlText is the one caller with a real
// declaration available, and it decodes before ever reaching this function.
func readUTF8(r io.Reader) (text, status string, err error) {
	b, err := readCapped(r)
	if errors.Is(err, errTooLarge) {
		return "", StatusTooLarge, nil
	}
	if err != nil {
		return "", "", err
	}
	text, guessed, ok := decodeGuessed(b)
	if !ok || (guessed && !looksLikeCyrillicPlainText(text)) {
		return "", StatusFailed, nil
	}
	return text, StatusOK, nil
}

// decodeGuessed decodes b via the shared "no declared charset" candidate
// order: UTF-8 (with or without a BOM) or a UTF-16 BOM directly (guessed =
// false — these are unambiguous, no plausibility check needed), else a
// windows-1251 attempt that merely decodes cleanly (RuneError-free; guessed
// = true). ok=false only when nothing decodes at all.
//
// A guessed=true result is NOT YET validated as real text: windows-1251
// (like most single-byte charmaps) has almost no undefined byte values, so
// it "decodes cleanly" for nearly any 8-bit input regardless of its real
// encoding. Every caller MUST run looksLikeCyrillicPlainText over the
// candidate's RENDERED text — stripped of markup, for HTML, since counting
// tag names as "letters" would dilute the ratio the check relies on — before
// trusting a guessed decode.
func decodeGuessed(b []byte) (text string, guessed, ok bool) {
	if decoded, gotBOM := decodeByBOM(b); gotBOM {
		return normalizeNewlines(string(decoded)), false, true
	}
	trimmed := bytes.TrimPrefix(b, utf8BOM)
	if utf8.Valid(trimmed) {
		return normalizeNewlines(string(trimmed)), false, true
	}
	decoded, ok := decodeCleanly(b, charmap.Windows1251)
	if !ok {
		return "", false, false
	}
	return normalizeNewlines(string(decoded)), true, true
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
// This alone is NOT a signal that the decode is the RIGHT one: a single-byte
// charmap like windows-1251 leaves only one byte value undefined (0x98) out
// of 256, so it decodes "cleanly" for almost any 8-bit byte stream regardless
// of what encoding actually produced it. Every caller decoding with
// charmap.Windows1251 MUST additionally gate the result through
// looksLikeCyrillicPlainText before trusting it as real text — decodeCleanly
// on its own only rules out garbage that hits the one undefined byte.
func decodeCleanly(b []byte, enc encoding.Encoding) ([]byte, bool) {
	out, err := enc.NewDecoder().Bytes(b)
	if err != nil || bytes.ContainsRune(out, utf8.RuneError) {
		return nil, false
	}
	return out, true
}

// looksLikeCyrillicPlainText reports whether text plausibly is Russian or
// Ukrainian read through a correct windows-1251 decode, as opposed to
// mojibake produced by decoding some OTHER single-byte (or byte-at-a-time
// double-byte) encoding — cp1252, ISO-8859-2, KOI8-R, GBK, ... — as if it
// were windows-1251. All four checks below must hold (spot-checked against
// cp1252/ISO-8859-2/KOI8-R/GBK mojibake samples, each of which reliably
// breaks at least one):
//
//   - Cyrillic letters are at least half of all letters (Latin ASCII
//     included in the denominator, so English column headers alongside
//     Russian data rows — a common CSV shape — don't by themselves fail
//     this: the check is a ratio over all letters, not a ban on Latin).
//   - no single word mixes a Latin and a Cyrillic letter (ordinary Russian/
//     Ukrainian text essentially never does; a wrong-encoding guess
//     routinely produces such words from what were multi-byte sequences or
//     adjacent unrelated glyphs in the true encoding).
//   - no lowercase-to-uppercase flip between two consecutive Cyrillic
//     letters (ordinary prose capitalizes at most a word's first letter; a
//     flip mid-run is a mojibake tell). This check only ever looks at
//     Cyrillic-to-Cyrillic transitions — an all-Latin word (an English
//     "CustomerID" header, say) is exempt, since its casing says nothing
//     about whether the CYRILLIC portion of the text is real.
//   - uppercase Cyrillic letters do not outnumber lowercase ones (ordinary
//     prose is mostly lowercase; several mojibake samples decode as
//     overwhelmingly uppercase Cyrillic).
func looksLikeCyrillicPlainText(text string) bool {
	var cyrillic, latinLetters, upperCyrillic, lowerCyrillic int
	var mixedWords, caseFlips int
	wordHasCyrillic, wordHasLatin := false, false
	hadPrevCyr, prevCyrLower := false, false

	endWord := func() {
		if wordHasCyrillic && wordHasLatin {
			mixedWords++
		}
		wordHasCyrillic, wordHasLatin = false, false
	}

	for _, r := range text {
		switch {
		case unicode.Is(unicode.Cyrillic, r):
			cyrillic++
			wordHasCyrillic = true
			if unicode.IsUpper(r) {
				upperCyrillic++
			} else {
				lowerCyrillic++
			}
			if hadPrevCyr && prevCyrLower && unicode.IsUpper(r) {
				caseFlips++
			}
			hadPrevCyr, prevCyrLower = true, unicode.IsLower(r)
		case unicode.Is(unicode.Latin, r):
			latinLetters++
			wordHasLatin = true
			hadPrevCyr = false
		default:
			endWord()
			hadPrevCyr = false
		}
	}
	endWord()

	total := cyrillic + latinLetters
	if total == 0 || cyrillic == 0 {
		return false
	}
	if float64(cyrillic)/float64(total) < 0.5 {
		return false
	}
	return mixedWords == 0 && caseFlips == 0 && upperCyrillic <= lowerCyrillic
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
// windows-1252-by-default step: an UNDECLARED document falls through to
// decodeUndeclared's own UTF-8/windows-1251-plausibility path instead of
// that default, since silently guessing windows-1252 is exactly the
// mojibake risk this package otherwise guards against for plain text).
func htmlText(mediaType string, r io.Reader) ([]extsync.Section, string, error) {
	b, err := readCapped(r)
	if errors.Is(err, errTooLarge) {
		return nil, StatusTooLarge, nil
	}
	if err != nil {
		return nil, "", err
	}
	if enc, ok := declaredHTMLEncoding(mediaType, b); ok {
		out, derr := enc.NewDecoder().Bytes(b)
		if derr != nil {
			return nil, StatusFailed, nil //nolint:nilerr // a declared-but-broken decode is a content status, not a Go error
		}
		text := normalizeNewlines(string(bytes.TrimPrefix(out, utf8BOM)))
		return oneSection(stripHTML(text)), StatusOK, nil
	}
	text, guessed, ok := decodeGuessed(b)
	if !ok {
		return nil, StatusFailed, nil
	}
	stripped := stripHTML(text)
	// The plausibility check runs on the STRIPPED text, not the raw
	// markup+content decodeGuessed returned: tag names (html, body, p, ...)
	// are themselves Latin letters, and counting them would dilute the
	// Cyrillic ratio for any real Russian/Ukrainian page with enough markup.
	if guessed && !looksLikeCyrillicPlainText(stripped) {
		return nil, StatusFailed, nil
	}
	return oneSection(stripped), StatusOK, nil
}

// declaredHTMLEncoding reports a charset HTML itself declares: a byte-order
// mark or the MIME Content-Type's charset param (both "certain" per
// charset.DetermineEncoding), or an HTML <meta charset>/http-equiv
// Content-Type tag (scanMetaCharset) — charset.DetermineEncoding's own meta
// detection is, through its public API, indistinguishable from its final
// windows-1252-by-default guess (both return certain=false with no way to
// tell them apart), so this package runs its own narrow meta scan instead of
// trusting an uncertain result from the library.
func declaredHTMLEncoding(mediaType string, b []byte) (encoding.Encoding, bool) {
	if enc, _, certain := charset.DetermineEncoding(b, mediaType); certain {
		return enc, true
	}
	if label, ok := scanMetaCharset(b); ok {
		if enc, name := charset.Lookup(label); enc != nil && name != "" {
			return enc, true
		}
	}
	return nil, false
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

// tag handles one tag token: skipped-element depth, cell separators, and
// line ends at block elements (tr among them).
func (st *htmlStripper) tag(tt html.Token) {
	name := tt.Data
	if name == "head" {
		st.inHead = tt.Type == html.StartTagToken
		return
	}
	opening := tt.Type == html.StartTagToken || tt.Type == html.SelfClosingTagToken
	if st.inHead && opening && !headAllowedTags[name] {
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
