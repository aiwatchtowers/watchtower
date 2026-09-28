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

// TestPlainMojibakeFamiliesFail pins that undeclared non-UTF-8 bytes with no
// byte-order mark fail, exactly as on main — including Cyrillic legacy
// encodings (KOI8-R/KOI8-U), which this package's own encoding-detection
// work tried and, across three review rounds, withdrew: see readUTF8's doc
// comment and docs/backlog/2026-09-27-review-low-priority-pr3-confluence-go.md
// for the record of what was attempted and why every version regressed on
// some other real-world input.
func TestPlainMojibakeFamiliesFail(t *testing.T) {
	x := newExtractor(t, nil)

	cases := map[string]string{
		"cp1252": encodeStr(t, charmap.Windows1252,
			"Café résumé châteaux naïve garçon aujourd'hui il fait beau dehors et nous allons nous promener"),
		"iso-8859-1": encodeStr(t, charmap.ISO8859_1,
			"Café résumé châteaux naïve garçon aujourd'hui il fait beau dehors et nous allons nous promener"),
		"iso-8859-2": encodeStr(t, charmap.ISO8859_2,
			"Dobrý den, jak se máš dnes? Doufám, že se ti daří dobře a že si užíváš krásné počasí venku."),
		"gbk": encodeStr(t, simplifiedchinese.GBK,
			"你好世界，这是一个测试文字内容，希望能够正常显示出来，谢谢大家的耐心等待和支持"),
		"shift-jis": encodeStr(t, japanese.ShiftJIS,
			"こんにちは、世界。これはテストです。今日はいい天気ですね、散歩に行きましょう。"),
		"koi8-r (Russian)": encodeStr(t, charmap.KOI8R,
			"Сегодня мы обсудили план на собрание. Все участники согласились с новыми условиями."),
		"koi8-u (Ukrainian)": encodeStr(t, charmap.KOI8U,
			"Сьогодні ми обговорили план на зустріч. Усі учасники погодилися з новими умовами."),
		"windows-1251 (Russian)": encodeStr(t, charmap.Windows1251,
			"Оплата через ПриватБанк и МегаФон подтверждена сегодня утром, документы готовы."),
	}
	for name, doc := range cases {
		t.Run(name, func(t *testing.T) {
			secs, status, err := x.Extract(context.Background(), "text/plain", "a.txt", strings.NewReader(doc))
			require.NoError(t, err)
			assert.Equal(t, StatusFailed, status, "no undeclared single-byte-charset guess — see readUTF8's doc comment")
			assert.Nil(t, secs)
		})
	}
}

// TestPlainUTF8WithOneStrayByteFails pins the regression a letter-frequency
// guess (tried and withdrawn in an earlier round — see readUTF8's doc
// comment) introduced: an almost-entirely-valid UTF-8 Russian file carrying
// a single stray non-UTF-8 byte must still fail outright, not be indexed as
// a whole-document windows-1251/koi8 misread of its own (otherwise
// perfectly good) UTF-8 bytes. utf8.Valid has no partial-credit notion —
// one bad byte anywhere makes the whole byte stream invalid — so this falls
// through decodeDirect to StatusFailed exactly like any other non-UTF-8,
// no-BOM input.
func TestPlainUTF8WithOneStrayByteFails(t *testing.T) {
	x := newExtractor(t, nil)
	valid := []byte("Привет, коллеги! Отчёт за неделю готов, все задачи выполнены в срок.")
	doc := append(append([]byte(nil), valid...), 0xFF) // one stray byte, otherwise fully valid UTF-8
	secs, status, err := x.Extract(context.Background(), "text/plain", "a.txt", strings.NewReader(string(doc)))
	require.NoError(t, err)
	assert.Equal(t, StatusFailed, status)
	assert.Nil(t, secs)
}

// TestHTMLHonorsDeclaredMIMECharset pins that an HTML document's MIME
// Content-Type charset param is honored unconditionally — before any guess.
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
// utf-16be/"unicode" label is read as UTF-8, not literally as UTF-16.
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
// of what an (already wrong, in that case) meta tag claims.
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

// TestHTMLDeclaredUTF8OverInvalidBytesFails pins the final routing decision:
// a declared "utf-8" that doesn't error decoding — golang.org/x/text's
// UTF-8 decoder silently substitutes U+FFFD for invalid bytes rather than
// returning a Go error — must not be indexed as StatusOK replacement
// characters (review round 2 finding F5). Earlier rounds fell through to an
// undeclared single-byte-charset guess here, which itself regressed
// (see readUTF8's doc comment); the guess is withdrawn, so this now fails
// outright rather than falling through to one.
func TestHTMLDeclaredUTF8OverInvalidBytesFails(t *testing.T) {
	x := newExtractor(t, nil)
	inner := encodeStr(t, charmap.Windows1251, "привет мир, это тест")
	doc := `<html><head><meta charset="utf-8"></head><body><p>` + inner + `</p></body></html>`
	secs, status, err := x.Extract(context.Background(), "text/html", "a.html", strings.NewReader(doc))
	require.NoError(t, err)
	assert.Equal(t, StatusFailed, status)
	assert.Nil(t, secs)
}

// TestHTMLDeclaredUTF8OverInvalidBytesRecoversValidUTF8 pins the flip side:
// decodeDirect (kept — see readUTF8's doc comment) still gets a chance after
// a failed declared decode, so a declaration that was simply wrong about
// the charset — the real bytes are genuinely valid UTF-8 — is recovered
// without needing any guess at all.
func TestHTMLDeclaredUTF8OverInvalidBytesRecoversValidUTF8(t *testing.T) {
	x := newExtractor(t, nil)
	// A charset the WHATWG spec maps to its dedicated "replacement" encoding
	// (a handful of legacy CJK labels, including iso-2022-kr): its decoder
	// always succeeds with no Go error, producing exactly one U+FFFD for any
	// input whatsoever, regardless of the actual bytes.
	doc := `<html><head><meta charset="iso-2022-kr"></head><body><p>hello world, ordinary ascii text here</p></body></html>`
	secs, status, err := x.Extract(context.Background(), "text/html", "a.html", strings.NewReader(doc))
	require.NoError(t, err)
	assert.Equal(t, StatusOK, status)
	require.Len(t, secs, 1)
	assert.Equal(t, "hello world, ordinary ascii text here", secs[0].Text)
}

// TestHTMLDeclaredReplacementEncodingOverMojibakeFails pins the other half:
// when the document's real bytes are ALSO not recoverable (here, cp1252
// mojibake) there is no guess to fall back to, so this fails.
func TestHTMLDeclaredReplacementEncodingOverMojibakeFails(t *testing.T) {
	x := newExtractor(t, nil)
	inner := encodeStr(t, charmap.Windows1252,
		"Café résumé châteaux naïve garçon aujourd'hui il fait beau dehors et nous allons nous promener")
	doc := `<html><head><meta charset="iso-2022-kr"></head><body><p>` + inner + `</p></body></html>`
	secs, status, err := x.Extract(context.Background(), "text/html", "a.html", strings.NewReader(doc))
	require.NoError(t, err)
	assert.Equal(t, StatusFailed, status)
	assert.Nil(t, secs)
}

// TestHTMLUnknownMetaLabelRecoversValidUTF8 pins that a meta tag naming a
// charset this package doesn't recognize is not itself an error:
// declaredHTMLEncoding reports ok=false for it (charset.Lookup returns a nil
// encoding), and genuinely valid UTF-8 content behind it is still decoded
// via decodeDirect — no guess needed for this case, since the real bytes
// are already unambiguous.
func TestHTMLUnknownMetaLabelRecoversValidUTF8(t *testing.T) {
	x := newExtractor(t, nil)
	doc := `<html><head><meta charset="totally-bogus-charset-name"></head><body><p>привет мир, это тест</p></body></html>`
	secs, status, err := x.Extract(context.Background(), "text/html", "a.html", strings.NewReader(doc))
	require.NoError(t, err)
	assert.Equal(t, StatusOK, status)
	require.Len(t, secs, 1)
	assert.Equal(t, "привет мир, это тест", secs[0].Text)
}

// TestHTMLUnknownMetaLabelOverNonUTF8Fails pins the other half: an unknown
// meta label over genuinely non-UTF-8 bytes has nothing left to fall back
// to once decodeDirect also fails — there is no undeclared guess.
func TestHTMLUnknownMetaLabelOverNonUTF8Fails(t *testing.T) {
	x := newExtractor(t, nil)
	inner := encodeStr(t, charmap.Windows1251, "привет мир, это тест")
	doc := `<html><head><meta charset="totally-bogus-charset-name"></head><body><p>` + inner + `</p></body></html>`
	secs, status, err := x.Extract(context.Background(), "text/html", "a.html", strings.NewReader(doc))
	require.NoError(t, err)
	assert.Equal(t, StatusFailed, status)
	assert.Nil(t, secs)
}

// TestHTMLUndeclaredNonUTF8Fails pins that an HTML document with NO declared
// charset anywhere, and bytes that are not valid UTF-8 (real Cyrillic text
// included — see readUTF8's doc comment for why this package no longer
// guesses a legacy single-byte charset), fails outright rather than
// guessing charset.DetermineEncoding's own windows-1252-by-default (which
// would silently misdecode it as Latin mojibake) or any other charset.
func TestHTMLUndeclaredNonUTF8Fails(t *testing.T) {
	x := newExtractor(t, nil)
	cases := map[string]string{
		"cp1251 Russian": encodeStr(t, charmap.Windows1251, "привет мир, это тест"),
		"cp1252 mojibake": encodeStr(t, charmap.Windows1252,
			"Café résumé châteaux naïve garçon aujourd'hui il fait beau dehors et nous allons nous promener"),
	}
	for name, inner := range cases {
		t.Run(name, func(t *testing.T) {
			doc := `<html><body><p>` + inner + `</p></body></html>`
			secs, status, err := x.Extract(context.Background(), "text/html", "a.html", strings.NewReader(doc))
			require.NoError(t, err)
			assert.Equal(t, StatusFailed, status)
			assert.Nil(t, secs)
		})
	}
}

// TestHTMLHeadClosedByTextWithNoTag pins review round 2 finding F7: HTML5's
// "in head" insertion mode closes head on non-whitespace character data
// directly inside it, not only on a stray tag.
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
// still be recognized as such and not itself close head.
func TestHTMLTitleTextIsNotHeadContent(t *testing.T) {
	x := newExtractor(t, nil)
	doc := `<html><head><title>Page Title</title><body><p>Hello body</p></body></html>`
	secs, status, err := x.Extract(context.Background(), "text/html", "t.html", strings.NewReader(doc))
	require.NoError(t, err)
	assert.Equal(t, StatusOK, status)
	require.Len(t, secs, 1)
	assert.Equal(t, "Hello body", secs[0].Text, "the title's own text is head content and must not leak into the body text")
}

// TestHTMLHeadClosedByTextDespiteVoidElements pins review round 3 finding
// R3-4: headChildDepth used to count void head-only elements (meta/link/
// base) the same as title/style/script, but a void element never gets a
// matching end tag — so once a real <head> (which almost always has at
// least one meta or link) was seen, the depth stayed above zero forever and
// the F7 text-closes-head rule never fired again. Each case here has no
// closing tag anywhere.
func TestHTMLHeadClosedByTextDespiteVoidElements(t *testing.T) {
	x := newExtractor(t, nil)
	// want asserts the FULL text, not just a substring: a subsequent <p>
	// tag closes head on its own regardless of this bug (an ordinary,
	// already-correct rule — any disallowed OPENING TAG closes head, not
	// only loose text), so a Contains-only check on the text AFTER <p>
	// would pass even with the bug reintroduced; what the bug actually drops
	// is the loose head-text itself (checked first in "want").
	cases := map[string]struct{ doc, want string }{
		"meta only": {`<html><head><meta name="a" content="b">Body text<p>y`, "Body text\ny"},
		"link only": {`<html><head><link rel="x" href="y">Body text<p>y`, "Body text\ny"},
		"base only": {`<html><head><base href="x">Loose text<p>y`, "Loose text\ny"},
		"title then meta+link": {
			`<html><head><title>T</title><meta name="a"><link rel="b">After<p>y`, "After\ny",
		},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			secs, status, err := x.Extract(context.Background(), "text/html", "t.html", strings.NewReader(c.doc))
			require.NoError(t, err)
			assert.Equal(t, StatusOK, status)
			require.Len(t, secs, 1)
			assert.Equal(t, c.want, secs[0].Text, "the loose head-text must not be dropped")
		})
	}
}

// encodeStr encodes s with enc, failing the test on error.
func encodeStr(t *testing.T, enc encoding.Encoding, s string) string {
	t.Helper()
	b, err := enc.NewEncoder().Bytes([]byte(s))
	require.NoError(t, err)
	return string(b)
}
