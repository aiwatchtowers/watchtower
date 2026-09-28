package extract

import (
	"context"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"golang.org/x/text/encoding"
	"golang.org/x/text/encoding/charmap"
	"golang.org/x/text/encoding/japanese"
	"golang.org/x/text/encoding/simplifiedchinese"
	xunicode "golang.org/x/text/encoding/unicode"
)

// TestPlainNonCyrillicMojibakeFails pins that decodeCleanly's "no
// utf8.RuneError" check alone is not enough to accept windows-1251: cp1251
// has only one undefined byte (0x98) in its whole 256-value table, so a
// wrong-encoding guess "decodes cleanly" for almost any 8-bit byte stream.
// looksLikeCyrillicPlainText is the real gate — each sample below decodes
// without a RuneError under windows-1251, but reads as mojibake, not
// Russian/Ukrainian text, and must stay StatusFailed rather than being
// silently indexed as garbage Cyrillic. Every sample uses ordinary sentence
// capitalization (a capital letter starting a sentence or name) rather than
// an all-lowercase or all-uppercase source: looksLikeCyrillicPlainText
// deliberately does not gate on letter case alone (see its doc comment), so
// a realistic sample — which almost always has SOME capitalization — is
// what actually demonstrates the rejection; an artificially all-one-case
// fragment would not exercise the real signal.
func TestPlainNonCyrillicMojibakeFails(t *testing.T) {
	x := newExtractor(t, nil)

	cases := map[string]string{
		"cp1252":     encodeStr(t, charmap.Windows1252, "Café résumé – Müller"),
		"iso-8859-1": encodeStr(t, charmap.ISO8859_1, "Café résumé châteaux naïve garçon"),
		"iso-8859-2": encodeStr(t, charmap.ISO8859_2, "Dobrý den! Toto je test kódování. Jmenuji se Jan a bydlím v Praze."),
		"koi8-r":     encodeStr(t, charmap.KOI8R, "Привет! Это тест кодировки. Меня зовут Иван, я живу в Москве."),
		"koi8-u":     encodeStr(t, charmap.KOI8U, "Вітаю! Це тест кодування. Мене звати Іван, я живу у Києві."),
		"gbk":        encodeStr(t, simplifiedchinese.GBK, "你好世界，这是一个测试文字内容"),
		"shift-jis":  encodeStr(t, japanese.ShiftJIS, "こんにちは、世界。これはテストです。今日はいい天気ですね。"),
	}
	for name, doc := range cases {
		t.Run(name, func(t *testing.T) {
			secs, status, err := x.Extract(context.Background(), "text/plain", "a.txt", strings.NewReader(doc))
			require.NoError(t, err)
			assert.Equal(t, StatusFailed, status, "must not be silently indexed as mojibake Cyrillic")
			assert.Nil(t, secs)
		})
	}
}

// TestPlainCyrillicCSVWithLatinHeadersDecodes pins the case the heuristic
// exists to still accept: a mostly-Russian windows-1251 CSV whose header row
// is plain (all-Latin) English column names — separate whole words, never
// mixed with a Cyrillic letter inside the same word — decodes correctly.
func TestPlainCyrillicCSVWithLatinHeadersDecodes(t *testing.T) {
	x := newExtractor(t, nil)
	csv := "Name,Date,Amount\n" +
		"Иванов Иван,2026-01-15,1500\n" +
		"Петров Пётр,2026-02-20,2300\n" +
		"Сидорова Анна,2026-03-05,900\n"
	doc := encodeStr(t, charmap.Windows1251, csv)

	secs, status, err := x.Extract(context.Background(), "text/csv", "a.csv", strings.NewReader(doc))
	require.NoError(t, err)
	assert.Equal(t, StatusOK, status)
	require.Len(t, secs, 1)
	assert.Equal(t, strings.TrimSpace(csv), secs[0].Text, "plainText trims surrounding whitespace, the trailing newline included")
}

// TestPlainAcceptsRealWorldCyrillicEdgeCases pins three real-document shapes
// a zero-tolerance heuristic used to reject outright (review round 2
// findings F1/F2/F3): a single brand-style camelCase name, a single
// keyboard-layout typo, and an all-caps legacy export. Each is a real
// windows-1251 document that must decode, not fail.
func TestPlainAcceptsRealWorldCyrillicEdgeCases(t *testing.T) {
	x := newExtractor(t, nil)

	cases := map[string]string{
		"camelCase brand name (bank)":    "Оплата через ПриватБанк до кінця місяця",
		"camelCase brand name (telecom)": "Договор с компанией МегаФон подписан",
		"single keyboard-layout typo":    "Договор и соглашение подписано вчера, но здесь опечатка: cоглашение подписано",
		"all-caps CSV export":            "ФИО;СУММА\nИВАНОВ ИВАН ИВАНОВИЧ;1500\nПЕТРОВ ПЕТР ПЕТРОВИЧ;2300\n",
		"all-caps single word":           "ИТОГО",
	}
	for name, src := range cases {
		t.Run(name, func(t *testing.T) {
			doc := encodeStr(t, charmap.Windows1251, src)
			secs, status, err := x.Extract(context.Background(), "text/plain", "a.txt", strings.NewReader(doc))
			require.NoError(t, err)
			assert.Equal(t, StatusOK, status)
			require.Len(t, secs, 1)
			assert.Equal(t, strings.TrimSpace(src), secs[0].Text)
		})
	}
}

// TestLooksLikeCyrillicPlainText isolates each of looksLikeCyrillicPlainText's
// conditions with a case built to trip (or, for the two accept-side cases
// each condition exists to tolerate, deliberately NOT trip) exactly it —
// verified by mutation: disabling any one condition turns only its matching
// case(s) green while the rest stay as expected. TestPlainNonCyrillicMojibakeFails
// and TestPlainAcceptsRealWorldCyrillicEdgeCases above cover realistic,
// multi-signal documents; this table isolates the individual mechanism.
func TestLooksLikeCyrillicPlainText(t *testing.T) {
	cases := []struct {
		name string
		text string
		want bool
	}{
		{"real Russian prose", "привет мир, это тест кодировки", true},
		{
			"ratio: mostly Latin with only a couple of separate Cyrillic words",
			"This is a long English sentence with only один русский word inside for testing purposes today",
			false,
		},
		{
			"word mixing below the floor: a single mixed word among many is a typo, not mojibake",
			"привет мир это тест cоглашение подписано вчера пример работы",
			true,
		},
		{
			"word mixing over the threshold: two mixed words in ten is mojibake's shape",
			"йabc boоk привет мир это тест пример работы кодировки сегодня",
			false,
		},
		{
			"case flip below the floor: one brand-style camelCase word is not mojibake",
			"привет мир это ПриватБанк тест пример работы кодировки сегодня",
			true,
		},
		{
			"case flip over the threshold: two mid-word flips in ten is mojibake's shape",
			"привет мир это тест оШибка пример работы друГой кодировки сегодня",
			false,
		},
		{
			"uppercase dominance is not checked: an all-caps phrase is accepted (documented limitation)",
			"ПРИВЕТ МИР ЭТО ТЕСТ",
			true,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			assert.Equal(t, c.want, looksLikeCyrillicPlainText(c.text))
		})
	}
}

// TestHTMLHonorsDeclaredMIMECharset pins that an HTML document's MIME
// Content-Type charset param is honored unconditionally — before any guess,
// and even for content that would otherwise fail the plain-text
// windows-1251 plausibility gate (a single short word here, well under the
// ratio/word-mixing thresholds looksLikeCyrillicPlainText applies to an
// UNDECLARED document).
func TestHTMLHonorsDeclaredMIMECharset(t *testing.T) {
	x := newExtractor(t, nil)
	doc := `<html><body><p>` + encodeStr(t, charmap.Windows1251, "тест") + `</p></body></html>`
	secs, status, err := x.Extract(context.Background(), `text/html; charset=windows-1251`, "a.html", strings.NewReader(doc))
	require.NoError(t, err)
	assert.Equal(t, StatusOK, status)
	require.Len(t, secs, 1)
	assert.Equal(t, "тест", secs[0].Text)
}

// TestHTMLHonorsMetaCharset pins the same rule for a <meta charset> tag when
// the MIME type carries no charset param at all (the common case for an
// attachment: the caller usually only knows "text/html").
func TestHTMLHonorsMetaCharset(t *testing.T) {
	x := newExtractor(t, nil)
	doc := `<html><head><meta charset="windows-1251"></head><body><p>` +
		encodeStr(t, charmap.Windows1251, "тест") + `</p></body></html>`
	secs, status, err := x.Extract(context.Background(), "text/html", "a.html", strings.NewReader(doc))
	require.NoError(t, err)
	assert.Equal(t, StatusOK, status)
	require.Len(t, secs, 1)
	assert.Equal(t, "тест", secs[0].Text)
}

// TestHTMLHonorsHTTPEquivMetaCharset pins the older
// <meta http-equiv="Content-Type" content="...;charset=..."> declaration
// form alongside the HTML5 <meta charset> shorthand above.
func TestHTMLHonorsHTTPEquivMetaCharset(t *testing.T) {
	x := newExtractor(t, nil)
	doc := `<html><head><meta http-equiv="Content-Type" content="text/html; charset=windows-1251"></head>` +
		`<body><p>` + encodeStr(t, charmap.Windows1251, "тест") + `</p></body></html>`
	secs, status, err := x.Extract(context.Background(), "text/html", "a.html", strings.NewReader(doc))
	require.NoError(t, err)
	assert.Equal(t, StatusOK, status)
	require.Len(t, secs, 1)
	assert.Equal(t, "тест", secs[0].Text)
}

// TestHTMLMetaUTF16LabelIsTreatedAsUTF8 pins HTML5's own carve-out (review
// round 2 finding F4): a document actually encoded in UTF-16 could never
// spell out an ASCII <meta charset="utf-16"> tag without a byte-order mark
// in the first place, so a META-declared (BOM-less) utf-16/utf-16le/
// utf-16be/"unicode" label is read as UTF-8, not literally as UTF-16 — the
// label only ever survives from an old tool (e.g. Word's "Web Page" export)
// that re-saved as UTF-8 but left the legacy tag behind. Before this fix,
// each label was honored literally, decoding plain UTF-8/ASCII bytes as
// UTF-16 and indexing CJK-looking garbage as StatusOK.
func TestHTMLMetaUTF16LabelIsTreatedAsUTF8(t *testing.T) {
	x := newExtractor(t, nil)
	for _, label := range []string{"utf-16", "utf-16le", "utf-16be", "unicode", "UTF-16"} {
		t.Run(label, func(t *testing.T) {
			doc := `<html><head><meta charset="` + label + `"></head><body><p>Hello world</p></body></html>`
			secs, status, err := x.Extract(context.Background(), "text/html", "a.html", strings.NewReader(doc))
			require.NoError(t, err)
			assert.Equal(t, StatusOK, status)
			require.Len(t, secs, 1)
			assert.Equal(t, "Hello world", secs[0].Text)
		})
	}
}

// TestHTMLMetaUTF16LabelDoesNotOverrideARealBOM pins that the carve-out above
// applies only to a META-declared label with no byte-order mark: a document
// that genuinely opens with a UTF-16 BOM is decoded as real UTF-16 regardless
// of what an (already wrong, in that case) meta tag claims — DetermineEncoding
// resolves the BOM as "certain" before scanMetaCharset is ever consulted.
func TestHTMLMetaUTF16LabelDoesNotOverrideARealBOM(t *testing.T) {
	x := newExtractor(t, nil)
	inner := `<html><head><meta charset="utf-16"></head><body><p>Hi</p></body></html>`
	doc := "\xff\xfe" + encodeStr(t, xunicode.UTF16(xunicode.LittleEndian, xunicode.IgnoreBOM), inner)
	secs, status, err := x.Extract(context.Background(), "text/html", "a.html", strings.NewReader(doc))
	require.NoError(t, err)
	assert.Equal(t, StatusOK, status)
	require.Len(t, secs, 1)
	assert.Equal(t, "Hi", secs[0].Text)
}

// TestHTMLDeclaredUTF8OverInvalidBytesFallsThrough pins review round 2
// finding F5: a declared "utf-8" that doesn't error decoding — golang.org/x/
// text's UTF-8 decoder silently substitutes U+FFFD for invalid bytes rather
// than returning a Go error — must not be indexed as StatusOK replacement
// characters. It falls through to the same undeclared UTF-8/windows-1251
// path used when nothing is declared, which recovers the real content here.
func TestHTMLDeclaredUTF8OverInvalidBytesFallsThrough(t *testing.T) {
	x := newExtractor(t, nil)
	inner := encodeStr(t, charmap.Windows1251, "привет мир, это тест")
	doc := `<html><head><meta charset="utf-8"></head><body><p>` + inner + `</p></body></html>`
	secs, status, err := x.Extract(context.Background(), "text/html", "a.html", strings.NewReader(doc))
	require.NoError(t, err)
	assert.Equal(t, StatusOK, status)
	require.Len(t, secs, 1)
	assert.Equal(t, "привет мир, это тест", secs[0].Text)
}

// TestHTMLDeclaredReplacementEncodingFails pins the same F5 rule for a
// declared charset the WHATWG spec maps to its dedicated "replacement"
// encoding for security reasons (a handful of legacy CJK labels, including
// iso-2022-kr): its decoder always succeeds with no error, producing exactly
// one U+FFFD for any input whatsoever, regardless of the actual bytes — that
// must not read as StatusOK "�" either. Here the document's real bytes are
// plain ASCII, so falling through to the undeclared path (rather than a hard
// StatusFailed — the review named both as acceptable) recovers the genuine
// content instead of losing it to a bogus declaration.
func TestHTMLDeclaredReplacementEncodingRecoversRealContent(t *testing.T) {
	x := newExtractor(t, nil)
	doc := `<html><head><meta charset="iso-2022-kr"></head><body><p>hello world, ordinary ascii text here</p></body></html>`
	secs, status, err := x.Extract(context.Background(), "text/html", "a.html", strings.NewReader(doc))
	require.NoError(t, err)
	assert.Equal(t, StatusOK, status)
	require.Len(t, secs, 1)
	assert.Equal(t, "hello world, ordinary ascii text here", secs[0].Text)
}

// TestHTMLDeclaredReplacementEncodingOverMojibakeFails pins the other half:
// when the document's real bytes are ALSO not recoverable (here, cp1252
// mojibake) the undeclared fall-through's own plausibility gate still fails
// it — the "replacement" encoding's single U+FFFD is never indexed as ok,
// but a bogus declaration doesn't manufacture content that isn't there.
func TestHTMLDeclaredReplacementEncodingOverMojibakeFails(t *testing.T) {
	x := newExtractor(t, nil)
	inner := encodeStr(t, charmap.Windows1252, "Café résumé – Müller, encore un peu plus long")
	doc := `<html><head><meta charset="iso-2022-kr"></head><body><p>` + inner + `</p></body></html>`
	secs, status, err := x.Extract(context.Background(), "text/html", "a.html", strings.NewReader(doc))
	require.NoError(t, err)
	assert.Equal(t, StatusFailed, status)
	assert.Nil(t, secs)
}

// TestHTMLUnknownMetaLabelFallsThroughToTheGuess pins that a meta tag naming
// a charset this package doesn't recognize is not itself an error: declaredHTMLEncoding
// reports ok=false for it (charset.Lookup returns a nil encoding), and the
// real windows-1251 content behind it is still recovered via the same
// undeclared-guess path used when nothing is declared at all.
func TestHTMLUnknownMetaLabelFallsThroughToTheGuess(t *testing.T) {
	x := newExtractor(t, nil)
	inner := encodeStr(t, charmap.Windows1251, "привет мир, это тест")
	doc := `<html><head><meta charset="totally-bogus-charset-name"></head><body><p>` + inner + `</p></body></html>`
	secs, status, err := x.Extract(context.Background(), "text/html", "a.html", strings.NewReader(doc))
	require.NoError(t, err)
	assert.Equal(t, StatusOK, status)
	require.Len(t, secs, 1)
	assert.Equal(t, "привет мир, это тест", secs[0].Text)
}

// TestHTMLUndeclaredFallsBackToPlausibilityGate pins that an HTML document
// with NO declared charset anywhere still runs through the same
// UTF-8/windows-1251-plausibility pipeline as plain text, rather than
// charset.DetermineEncoding's own final windows-1252-by-default guess (which
// would silently misdecode this exact byte sequence as Latin mojibake).
func TestHTMLUndeclaredFallsBackToPlausibilityGate(t *testing.T) {
	x := newExtractor(t, nil)
	doc := `<html><body><p>` + encodeStr(t, charmap.Windows1251, "привет мир, это тест") + `</p></body></html>`
	secs, status, err := x.Extract(context.Background(), "text/html", "a.html", strings.NewReader(doc))
	require.NoError(t, err)
	assert.Equal(t, StatusOK, status)
	require.Len(t, secs, 1)
	assert.Equal(t, "привет мир, это тест", secs[0].Text)
}

// TestHTMLUndeclaredMojibakeStillFails pins that an undeclared HTML document
// whose bytes are actually some OTHER 8-bit encoding still fails, exactly
// like the plain-text case: no declaration anywhere means no free pass past
// the plausibility gate.
func TestHTMLUndeclaredMojibakeStillFails(t *testing.T) {
	x := newExtractor(t, nil)
	doc := `<html><body><p>` + encodeStr(t, charmap.Windows1252, "Café résumé – Müller, encore un peu plus long") + `</p></body></html>`
	secs, status, err := x.Extract(context.Background(), "text/html", "a.html", strings.NewReader(doc))
	require.NoError(t, err)
	assert.Equal(t, StatusFailed, status)
	assert.Nil(t, secs)
}

// TestHTMLHeadClosedByTextWithNoTag pins review round 2 finding F7: HTML5's
// "in head" insertion mode closes head on non-whitespace character data
// directly inside it, not only on a stray tag — so a document with no
// closing tag anywhere (<html><head>Hello there<p>x) doesn't drop the text
// sitting directly in head as if it were head content.
func TestHTMLHeadClosedByTextWithNoTag(t *testing.T) {
	x := newExtractor(t, nil)
	doc := `<html><head>Hello there<p>x`
	secs, status, err := x.Extract(context.Background(), "text/html", "t.html", strings.NewReader(doc))
	require.NoError(t, err)
	assert.Equal(t, StatusOK, status)
	require.Len(t, secs, 1)
	assert.Equal(t, "Hello there\nx", secs[0].Text)
}

// TestHTMLTitleTextIsNotHeadContent pins the flip side of the F7 fix: text
// inside an element HTML5 DOES allow in <head> (<title>, in particular) must
// still be recognized as such and not itself close head — only character
// data sitting DIRECTLY in head, with no wrapping element at all, does.
func TestHTMLTitleTextIsNotHeadContent(t *testing.T) {
	x := newExtractor(t, nil)
	doc := `<html><head><title>Page Title</title><body><p>Hello body</p></body></html>`
	secs, status, err := x.Extract(context.Background(), "text/html", "t.html", strings.NewReader(doc))
	require.NoError(t, err)
	assert.Equal(t, StatusOK, status)
	require.Len(t, secs, 1)
	assert.Equal(t, "Hello body", secs[0].Text, "the title's own text is head content and must not leak into the body text")
}

// encodeStr encodes s with enc, failing the test on error.
func encodeStr(t *testing.T, enc encoding.Encoding, s string) string {
	t.Helper()
	b, err := enc.NewEncoder().Bytes([]byte(s))
	require.NoError(t, err)
	return string(b)
}
