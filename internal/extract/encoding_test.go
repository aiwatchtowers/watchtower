package extract

import (
	"context"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"golang.org/x/text/encoding"
	"golang.org/x/text/encoding/charmap"
	"golang.org/x/text/encoding/simplifiedchinese"
)

// TestPlainNonCyrillicMojibakeFails pins that decodeCleanly's "no
// utf8.RuneError" check alone is not enough to accept windows-1251: cp1251
// has only one undefined byte (0x98) in its whole 256-value table, so a
// wrong-encoding guess "decodes cleanly" for almost any 8-bit byte stream.
// looksLikeCyrillicPlainText is the real gate — each sample below decodes
// without a RuneError under windows-1251, but reads as mojibake, not
// Russian/Ukrainian text, and must stay StatusFailed rather than being
// silently indexed as garbage Cyrillic.
func TestPlainNonCyrillicMojibakeFails(t *testing.T) {
	x := newExtractor(t, nil)

	cases := map[string]string{
		"cp1252": encodeStr(t, charmap.Windows1252, "Café résumé – Müller"),
		"gbk":    encodeStr(t, simplifiedchinese.GBK, "你好世界，这是一个测试文字内容"),
		"koi8-r": encodeStr(t, charmap.KOI8R, "привет мир, это тест кодировки, дополнительный текст"),
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

// encodeStr encodes s with enc, failing the test on error.
func encodeStr(t *testing.T, enc encoding.Encoding, s string) string {
	t.Helper()
	b, err := enc.NewEncoder().Bytes([]byte(s))
	require.NoError(t, err)
	return string(b)
}
