// Package logredact turns text that may carry company content (CLI stderr,
// HTTP bodies, model output) into something a log line can hold: a scrubbed
// excerpt or a content-free fingerprint (FILES-01). The full text stays on
// the error the caller stores in the database.
package logredact

import (
	"strings"
	"unicode"
	"unicode/utf8"

	"watchtower/internal/claude"
)

// ExcerptRunes is the most runes Excerpt keeps.
const ExcerptRunes = 120

// Excerpt replaces every quoted run ("…", '…' or `…`) with "…", collapses
// whitespace and cuts the result to ExcerptRunes runes, adding … when cut.
// An unterminated quote scrubs everything after it. A ' between two letters
// is an apostrophe, not a quote.
func Excerpt(s string) string {
	runes := []rune(s)
	var b strings.Builder
	space := false
	for i := 0; i < len(runes); i++ {
		r := runes[i]
		if unicode.IsSpace(r) {
			space = true
			continue
		}
		if space && b.Len() > 0 {
			b.WriteByte(' ')
		}
		space = false
		if isQuote(runes, i) {
			end := closing(runes, i)
			b.WriteString(`"…"`)
			if end < 0 {
				break
			}
			i = end
			continue
		}
		b.WriteRune(r)
	}
	out := b.String()
	if utf8.RuneCountInString(out) > ExcerptRunes {
		out = string([]rune(out)[:ExcerptRunes]) + "…"
	}
	return out
}

// Body is claude.DescribeOutput re-exported: byte count, shape and a short
// sha256, never a byte of the input.
func Body(b []byte) string { return claude.DescribeOutput(b) }

func isQuote(runes []rune, i int) bool {
	switch runes[i] {
	case '"', '`':
		return true
	case '\'':
		apostrophe := i > 0 && i+1 < len(runes) &&
			unicode.IsLetter(runes[i-1]) && unicode.IsLetter(runes[i+1])
		return !apostrophe
	}
	return false
}

// closing returns the index of the quote that ends the run opened at i, or
// -1 when the run is unterminated. A backslash escapes the next rune.
func closing(runes []rune, i int) int {
	q := runes[i]
	for j := i + 1; j < len(runes); j++ {
		if runes[j] == '\\' {
			j++
			continue
		}
		if runes[j] == q {
			return j
		}
	}
	return -1
}
