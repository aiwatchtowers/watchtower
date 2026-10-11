package cmd

import (
	"strings"
	"unicode/utf8"
)

// The CLI's one-line text helpers: the brief's lines, the ask guard's
// recorded question and the escalated ask's title.

// briefClip collapses whitespace to single spaces and cuts s to n runes.
func briefClip(s string, n int) string {
	s = strings.Join(strings.Fields(s), " ")
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	r := []rune(s)
	return string(r[:n-1]) + "…"
}

// oneLine collapses every run of whitespace, line breaks included, to one
// space.
func oneLine(s string) string { return strings.Join(strings.Fields(s), " ") }

// clipRunes cuts s to at most n runes.
func clipRunes(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return strings.TrimSpace(string([]rune(s)[:n]))
}
