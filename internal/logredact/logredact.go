// Package logredact turns text that may carry company content (CLI stderr,
// HTTP bodies, model output) into something a log line can hold: a scrubbed
// excerpt or a content-free fingerprint (FILES-01). An error built by Errorf
// carries both views: Error() is the log-safe one, Full the whole text for
// the places that store an error for the owner.
package logredact

import (
	"fmt"
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

// Text marks an Errorf argument as text from outside the process (CLI
// stderr, an HTTP body, a CLI result envelope) that may carry company
// content.
type Text string

// DetailError is an error with two views. Error() replaces every Text
// argument with its fingerprint (Body), so it is safe wherever an error
// travels: %v, %w, %q, a log line, a progress line, another process. Full
// recovers the whole text.
type DetailError struct {
	safe error  // the message with Text as fingerprints; carries the %w operands
	full string // the message with Text verbatim
}

// Errorf is fmt.Errorf, except that each Text argument appears verbatim only
// in Full(err); Error() shows its fingerprint. %w operands are wrapped as
// fmt.Errorf wraps them, so errors.Is/As see through the result.
func Errorf(format string, args ...any) error {
	safeArgs := make([]any, len(args))
	fullArgs := make([]any, len(args))
	for i, a := range args {
		if t, ok := a.(Text); ok {
			safeArgs[i] = "[" + Body([]byte(t)) + "]"
			fullArgs[i] = string(t)
			continue
		}
		safeArgs[i], fullArgs[i] = a, a
	}
	return &DetailError{
		safe: fmt.Errorf(format, safeArgs...),
		full: fmt.Errorf(format, fullArgs...).Error(),
	}
}

func (e *DetailError) Error() string { return e.safe.Error() }

// Unwrap exposes the %w operands of the Errorf call.
func (e *DetailError) Unwrap() []error {
	switch u := e.safe.(type) { //nolint:errorlint // reads this error's own Unwrap, not the chain
	case interface{ Unwrap() []error }:
		return u.Unwrap()
	case interface{ Unwrap() error }:
		return []error{u.Unwrap()}
	}
	return nil
}

// Full returns err's message with every DetailError in its chain shown in
// full: the text for pipeline_runs, account status and the other places the
// owner reads an error, and for classifiers that match on the provider's own
// words. It returns "" for a nil err.
func Full(err error) string {
	if err == nil {
		return ""
	}
	s := err.Error()
	var walk func(error)
	walk = func(e error) {
		if e == nil {
			return
		}
		var next []error
		if d, ok := e.(*DetailError); ok { //nolint:errorlint // walk visits every link itself
			s = strings.ReplaceAll(s, d.safe.Error(), d.full)
			next = d.Unwrap()
		} else {
			switch u := e.(type) { //nolint:errorlint // walk visits every link itself
			case interface{ Unwrap() []error }:
				next = u.Unwrap()
			case interface{ Unwrap() error }:
				next = []error{u.Unwrap()}
			}
		}
		for _, n := range next {
			walk(n)
		}
	}
	walk(err)
	return s
}
