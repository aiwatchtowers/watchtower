package automations

import (
	"strings"
	"unicode/utf8"
)

// FallbackSummary is the list line of a recipe without a `summary`: the first
// sentence of its description, cut to MaxSummaryRunes on a word boundary with
// a trailing "…". The Swift twin (AutomationSummary) must stay identical.
func FallbackSummary(description string) string {
	s := strings.TrimSpace(description)
	end := len(s)
	for _, sep := range []string{". ", "! ", "? "} {
		if i := strings.Index(s, sep); i >= 0 && i+1 < end {
			end = i + 1
		}
	}
	s = strings.TrimSpace(s[:end])
	if utf8.RuneCountInString(s) <= MaxSummaryRunes {
		return s
	}
	cut := []rune(s)[:MaxSummaryRunes]
	if i := strings.LastIndex(string(cut), " "); i > 0 {
		cut = []rune(string(cut)[:i])
	}
	return strings.TrimRight(string(cut), " ,;:") + "…"
}
