package asks

import (
	"strings"
	"unicode"
)

// NormalizeTitle is the form two ask titles are compared in when the agent
// re-files a withdrawn ask (spec 2026-10-10-owner-asks-v2 Part 8):
// lower-cased, whitespace collapsed to single spaces, trailing punctuation
// and spaces dropped.
func NormalizeTitle(title string) string {
	t := strings.ToLower(strings.Join(strings.Fields(title), " "))
	return strings.TrimRightFunc(t, func(r rune) bool { return unicode.IsPunct(r) || unicode.IsSpace(r) })
}
