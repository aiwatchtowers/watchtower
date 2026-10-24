package automations

import "strings"

// FallbackSummary is the list line of a recipe without a `summary`: the first
// sentence of its description, cut to MaxSummaryRunes on a word boundary with
// a trailing "…". All whitespace (newlines included) is collapsed to single
// spaces first, so the result is always one line. The Swift twin
// (AutomationSummary) must stay identical.
func FallbackSummary(description string) string {
	s := strings.Join(strings.Fields(description), " ")
	end := len(s)
	for _, sep := range []string{". ", "! ", "? "} {
		if i := strings.Index(s, sep); i >= 0 && i+1 < end {
			end = i + 1
		}
	}
	runes := []rune(s[:end])
	if len(runes) <= MaxSummaryRunes {
		return string(runes)
	}
	cut := runes[:MaxSummaryRunes]
	if runes[MaxSummaryRunes] != ' ' {
		if i := strings.LastIndex(string(cut), " "); i > 0 {
			cut = []rune(string(cut)[:i])
		}
	}
	return strings.TrimRight(string(cut), " ,;:") + "…"
}
