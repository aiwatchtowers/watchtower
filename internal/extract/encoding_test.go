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

// Realistic, lowercase-heavy, multi-sentence prose fixtures (review round 3
// finding R3-1: the round-2 case-based rules were caught out by capital-dense
// fixtures that don't represent real text — ordinary Russian/Ukrainian prose
// is mostly lowercase, with only sentence-initial and proper-noun capitals).
const (
	ruProse4Sentences = "Сегодня мы обсудили план на собрание. Все участники согласились с новыми условиями. " +
		"После обеда команда начала работать над задачей. Результаты будут готовы к вечеру."
	ukProse4Sentences = "Сьогодні ми обговорили план на зустріч. Усі учасники погодилися з новими умовами. " +
		"Після обіду команда почала працювати над завданням. Результати будуть готові до вечора."
)

// TestPlainMojibakeFamiliesFail pins that every required mojibake family
// still fails — realistic lowercase-heavy multi-sentence prose, not the
// capital-dense fixtures round 2 used (which happened to pass only because
// they were unusually capital-dense; see bestCyrillicText's doc comment for
// the measured scores this relies on). KOI8-R/KOI8-U are intentionally NOT
// here: bestCyrillicText recognizes them as a real candidate and decodes
// them correctly instead of rejecting them — see
// TestPlainKOI8ProseDecodesCorrectly.
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

// TestPlainKOI8ProseDecodesCorrectly pins the review round 3 fix: realistic
// (lowercase-heavy, multi-sentence) KOI8-R and KOI8-U documents are no
// longer rejected as cp1251 mojibake — bestCyrillicText recognizes koi8-r/
// koi8-u as real candidates, scores them against windows-1251, and — since
// they win here — returns THEIR OWN decode, so the file is searchable in
// its actual content, not merely "accepted". This is the exact regression
// review round 3 found (R3-1): round 2's case-flip/word-mixing rules
// rejected ordinary KOI8 prose because normal sentence capitalization is
// too sparse in a real paragraph to clear their thresholds; the frequency
// score replacing them doesn't depend on case at all.
func TestPlainKOI8ProseDecodesCorrectly(t *testing.T) {
	x := newExtractor(t, nil)

	cases := map[string]struct {
		enc  encoding.Encoding
		text string
	}{
		"koi8-r (Russian)":   {charmap.KOI8R, ruProse4Sentences},
		"koi8-u (Ukrainian)": {charmap.KOI8U, ukProse4Sentences},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			doc := encodeStr(t, c.enc, c.text)
			secs, status, err := x.Extract(context.Background(), "text/plain", "a.txt", strings.NewReader(doc))
			require.NoError(t, err)
			assert.Equal(t, StatusOK, status)
			require.Len(t, secs, 1)
			assert.Equal(t, c.text, secs[0].Text)
		})
	}
}

// TestPlainAllLowercaseKOI8RPhraseDecodesCorrectly pins the exact regression
// sample from the round 3 verify report: a short, entirely lowercase KOI8-R
// phrase with no capitalization at all (so round 2's case-flip rule could
// never have caught it even in principle) is recognized and decoded, not
// rejected.
func TestPlainAllLowercaseKOI8RPhraseDecodesCorrectly(t *testing.T) {
	x := newExtractor(t, nil)
	doc := encodeStr(t, charmap.KOI8R, "привет мир как дела")
	secs, status, err := x.Extract(context.Background(), "text/plain", "a.txt", strings.NewReader(doc))
	require.NoError(t, err)
	assert.Equal(t, StatusOK, status)
	require.Len(t, secs, 1)
	assert.Equal(t, "привет мир как дела", secs[0].Text)
}

// TestPlainCyrillicCSVWithLatinHeadersDecodes pins the case the heuristic
// exists to still accept: a mostly-Russian windows-1251 CSV whose header row
// is plain (all-Latin) English column names decodes correctly, picking
// windows-1251 over koi8-r/koi8-u by a wide margin (the Cyrillic rows score
// far higher under their real encoding than under either KOI8 guess).
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

// TestPlainAcceptsRealWorldCyrillicEdgeCases pins real-document shapes a
// zero-tolerance (round 2) or case-based (round 3) heuristic rejected
// outright: brand-style camelCase names embedded in ordinary prose, a
// single keyboard-layout typo, an all-caps legacy export line, and a short
// (<20 letters) real phrase. Each is a real windows-1251 document that must
// decode, not fail.
func TestPlainAcceptsRealWorldCyrillicEdgeCases(t *testing.T) {
	x := newExtractor(t, nil)

	cases := map[string]string{
		"brand names in a full sentence": "Оплата через ПриватБанк и МегаФон подтверждена сегодня утром",
		"a single keyboard-layout typo in a paragraph": "Договор и соглашение подписано вчера, но здесь опечатка: " +
			"cоглашение подписано, а остальной текст документа читается нормально без проблем",
		"all-caps legacy export line":     "ИТОГО ПО ДОГОВОРУ СУММА К ОПЛАТЕ",
		"short real phrase (<20 letters)": "Привет мир",
		"ultra-short single word":         "ИТОГО",
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

// TestPlainShortMojibakeFails pins the "short text" side of the same
// question (review round 3 asked for short-text behaviour to be decided and
// documented — see bestCyrillicText's doc comment): a short fragment that
// is genuinely NOT Cyrillic still fails, exactly like a long one — no
// separate leniency kicks in just because the input is brief.
func TestPlainShortMojibakeFails(t *testing.T) {
	x := newExtractor(t, nil)
	doc := encodeStr(t, charmap.Windows1252, "Café Müller")
	secs, status, err := x.Extract(context.Background(), "text/plain", "a.txt", strings.NewReader(doc))
	require.NoError(t, err)
	assert.Equal(t, StatusFailed, status)
	assert.Nil(t, secs)
}

// TestScoreCyrillicText pins scoreCyrillicText's measured values directly
// (the numbers bestCyrillicText's doc comment documents cyrillicScoreMin/
// cyrillicScoreMargin against) — mutation-testable independent of the
// candidate-selection logic in bestCyrillicText.
func TestScoreCyrillicText(t *testing.T) {
	cases := []struct {
		name      string
		text      string
		wantOver  float64 // score must be > this
		wantUnder float64 // score must be < this
	}{
		{"real Russian prose", ruProse4Sentences, 1.6, 1.7},
		{"real Ukrainian prose", ukProse4Sentences, 1.55, 1.7},
		{"cp1252 mojibake (Latin, low ratio)", "Cafй rйsumй chвteaux naпve garзon", 0, 0.5},
		{"all-caps real phrase", "ИТОГО ПО ДОГОВОРУ СУММА К ОПЛАТЕ", 1.55, 1.7},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := scoreCyrillicText(c.text)
			assert.Greater(t, got, c.wantOver)
			assert.Less(t, got, c.wantUnder)
		})
	}
	t.Run("no letters at all", func(t *testing.T) {
		assert.Equal(t, 0.0, scoreCyrillicText("12345 !@#$% ,,,"))
	})
}

// TestPlainBOMIsTrimmedBeforeCyrillicScoring pins review round 3 finding
// R3-2: the windows-1251/koi8 guess used to score the UNTRIMMED bytes, so a
// file carrying a (spurious, since the body isn't valid UTF-8) UTF-8 BOM
// decoded that BOM itself as three extra garbage characters ("п»ї") glued
// onto the front of otherwise-correct text.
func TestPlainBOMIsTrimmedBeforeCyrillicScoring(t *testing.T) {
	x := newExtractor(t, nil)
	doc := string(utf8BOM) + encodeStr(t, charmap.Windows1251, "Привет мир, это тест кодировки")
	secs, status, err := x.Extract(context.Background(), "text/plain", "a.txt", strings.NewReader(doc))
	require.NoError(t, err)
	assert.Equal(t, StatusOK, status)
	require.Len(t, secs, 1)
	assert.Equal(t, "Привет мир, это тест кодировки", secs[0].Text)
}

// TestHTMLBOMIsTrimmedBeforeCyrillicScoring is R3-2's HTML-path variant: a
// document that genuinely opens with a UTF-8 BOM (so charset.DetermineEncoding
// resolves it "certain" UTF-8, and the F5 replacement-rune check falls it
// through once the cp1251 body proves not to be valid UTF-8) must have that
// same leading BOM trimmed before the fallback windows-1251/koi8 guess
// scores the bytes, or the BOM itself decodes as three extra garbage
// characters ("п»ї") glued onto the front of otherwise-correct text.
func TestHTMLBOMIsTrimmedBeforeCyrillicScoring(t *testing.T) {
	x := newExtractor(t, nil)
	doc := string(utf8BOM) + `<html><body><p>` +
		encodeStr(t, charmap.Windows1251, "Привет мир, это тест кодировки") + `</p></body></html>`
	secs, status, err := x.Extract(context.Background(), "text/html", "a.html", strings.NewReader(doc))
	require.NoError(t, err)
	assert.Equal(t, StatusOK, status)
	require.Len(t, secs, 1)
	assert.Equal(t, "Привет мир, это тест кодировки", secs[0].Text)
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

// TestHTMLDeclaredUTF8OverInvalidBytesFallsThrough pins review round 2
// finding F5: a declared "utf-8" that doesn't error decoding — golang.org/x/
// text's UTF-8 decoder silently substitutes U+FFFD for invalid bytes rather
// than returning a Go error — must not be indexed as StatusOK replacement
// characters. It falls through to the same undeclared path, which recovers
// the real content here.
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

// TestHTMLDeclaredReplacementEncodingRecoversRealContent pins the same F5
// rule for a declared charset the WHATWG spec maps to its dedicated
// "replacement" encoding for security reasons (a handful of legacy CJK
// labels, including iso-2022-kr): its decoder always succeeds with no error,
// producing exactly one U+FFFD for any input whatsoever — that must not read
// as StatusOK "�" either. Here the document's real bytes are plain ASCII,
// so falling through to the undeclared path recovers the genuine content.
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
// mojibake) the undeclared fall-through's own scoring still fails it.
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

// TestHTMLUnknownMetaLabelFallsThroughToTheGuess pins that a meta tag naming
// a charset this package doesn't recognize is not itself an error: the real
// windows-1251 content behind it is still recovered via the undeclared path.
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

// TestHTMLUndeclaredFallsBackToTheScoredGuess pins that an HTML document
// with NO declared charset anywhere still runs through the same
// UTF-8/windows-1251-or-koi8 scoring pipeline as plain text, rather than
// charset.DetermineEncoding's own final windows-1252-by-default guess.
func TestHTMLUndeclaredFallsBackToTheScoredGuess(t *testing.T) {
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
// like the plain-text case.
func TestHTMLUndeclaredMojibakeStillFails(t *testing.T) {
	x := newExtractor(t, nil)
	doc := `<html><body><p>` + encodeStr(t, charmap.Windows1252,
		"Café résumé châteaux naïve garçon aujourd'hui il fait beau dehors et nous allons nous promener") +
		`</p></body></html>`
	secs, status, err := x.Extract(context.Background(), "text/html", "a.html", strings.NewReader(doc))
	require.NoError(t, err)
	assert.Equal(t, StatusFailed, status)
	assert.Nil(t, secs)
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
	cases := map[string]string{
		"meta only":            `<html><head><meta name="a" content="b">Body text<p>y`,
		"link only":            `<html><head><link rel="x" href="y">Body text<p>y`,
		"base only":            `<html><head><base href="x">Loose text<p>y`,
		"title then meta+link": `<html><head><title>T</title><meta name="a"><link rel="b">After<p>y`,
	}
	for name, doc := range cases {
		t.Run(name, func(t *testing.T) {
			secs, status, err := x.Extract(context.Background(), "text/html", "t.html", strings.NewReader(doc))
			require.NoError(t, err)
			assert.Equal(t, StatusOK, status)
			require.Len(t, secs, 1)
			assert.Contains(t, secs[0].Text, "y", "the loose head-text must not be dropped")
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
