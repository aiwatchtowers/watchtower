// Package logredact turns text that may carry company content (CLI stderr,
// HTTP bodies, model output) into something a log line can hold: a scrubbed
// excerpt or a content-free fingerprint (FILES-01). The full text stays on
// the error the caller stores in the database.
package logredact

import (
	"bytes"
	"io"
	"strings"
	"sync"
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

// maxKept and maxKeptBytes bound the texts Detail remembers; the oldest go
// first. An error is logged soon after it is built, so a few hundred recent
// texts cover the window between the two.
const (
	maxKept      = 256
	maxKeptBytes = 4 << 20
)

var kept struct {
	mu    sync.Mutex
	texts []string
	bytes int
}

// Detail marks s, text from outside the process that an error carries in
// full (CLI stderr, an HTTP body, a CLI result envelope), and returns it
// unchanged. The error keeps the whole text for the database; a log writer
// wrapped by Writer cuts every marked text it sees to its Excerpt, so a
// caller that logs the error with %v writes at most the excerpt. Text that
// is its own excerpt (short, unquoted) is not remembered.
func Detail(s string) string {
	if Excerpt(s) == s {
		return s
	}
	kept.mu.Lock()
	defer kept.mu.Unlock()
	kept.texts = append(kept.texts, s)
	kept.bytes += len(s)
	for len(kept.texts) > maxKept || (kept.bytes > maxKeptBytes && len(kept.texts) > 1) {
		kept.bytes -= len(kept.texts[0])
		kept.texts = kept.texts[1:]
	}
	return s
}

// Redact returns p with every text marked by Detail replaced by its
// Excerpt. It returns p itself when nothing matched.
func Redact(p []byte) []byte {
	kept.mu.Lock()
	texts := kept.texts
	kept.mu.Unlock()
	// Longest first, so a marked text that contains another is cut whole.
	var hits []string
	for _, t := range texts {
		if len(t) <= len(p) && bytes.Contains(p, []byte(t)) {
			hits = append(hits, t)
		}
	}
	if len(hits) == 0 {
		return p
	}
	out := string(p)
	for len(hits) > 0 {
		longest := 0
		for i, h := range hits {
			if len(h) > len(hits[longest]) {
				longest = i
			}
		}
		out = strings.ReplaceAll(out, hits[longest], Excerpt(hits[longest]))
		hits = append(hits[:longest], hits[longest+1:]...)
	}
	return []byte(out)
}

// Writer wraps w so that every write passes through Redact. It reports the
// caller's byte count, not the shorter redacted one.
func Writer(w io.Writer) io.Writer { return redactingWriter{w} }

type redactingWriter struct{ w io.Writer }

func (r redactingWriter) Write(p []byte) (int, error) {
	if _, err := r.w.Write(Redact(p)); err != nil {
		return 0, err
	}
	return len(p), nil
}
