package guide

import (
	"sort"
	"strings"
	"unicode"
)

// Search ranks sections for a free-text query: per query word, +3 when a
// heading word starts with it, +2 for the page title, +1 for the text. Ties
// keep guide order. At most limit sections with a positive score return.
func Search(sections []Section, query string, limit int) []Section {
	words := splitWords(query)
	if len(words) == 0 || limit <= 0 {
		return nil
	}
	type scored struct {
		s     Section
		score int
	}
	var hits []scored
	for _, s := range sections {
		heading, title, text := splitWords(s.Heading), splitWords(s.PageTitle), strings.ToLower(s.Text)
		score := 0
		for _, w := range words {
			switch {
			case hasPrefix(heading, w):
				score += 3
			case hasPrefix(title, w):
				score += 2
			case strings.Contains(text, w):
				score++
			}
		}
		if score > 0 {
			hits = append(hits, scored{s, score})
		}
	}
	sort.SliceStable(hits, func(i, j int) bool { return hits[i].score > hits[j].score })
	if len(hits) > limit {
		hits = hits[:limit]
	}
	out := make([]Section, len(hits))
	for i, h := range hits {
		out[i] = h.s
	}
	return out
}

// Page returns the sections of one page in guide order.
func Page(sections []Section, page string) ([]Section, bool) {
	var out []Section
	for _, s := range sections {
		if s.Page == page {
			out = append(out, s)
		}
	}
	return out, len(out) > 0
}

func splitWords(s string) []string {
	out := []string{}
	for _, w := range strings.Fields(strings.ToLower(s)) {
		w = strings.TrimFunc(w, func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsDigit(r) })
		if len([]rune(w)) >= 2 {
			out = append(out, w)
		}
	}
	return out
}

func hasPrefix(words []string, w string) bool {
	for _, x := range words {
		if strings.HasPrefix(x, w) {
			return true
		}
	}
	return false
}
