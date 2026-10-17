package userguide

import (
	"sort"
	"strings"
	"unicode"
)

// Search ranks sections for a free-text query. Query words are the
// question's words minus stopwords (filler like "how do I get the"). Per
// query word a section adds 3 when a heading word starts with it, 2 when a
// page-title word does and 1 when a text word does — all that apply, so a
// word in the heading of the page it names outranks a passing mention.
// Ties keep guide order. At most limit sections with a positive score
// return. Mirrored by the Desktop's GuideSearch.rank; the shared fixture
// testdata/queries.json holds both to the same words and results.
func Search(sections []Section, query string, limit int) []Section {
	words := queryWords(query)
	if len(words) == 0 || limit <= 0 {
		return nil
	}
	type scored struct {
		s     Section
		score int
	}
	var hits []scored
	for _, s := range sections {
		heading, title, text := splitWords(s.Heading), splitWords(s.PageTitle), splitWords(s.Text)
		score := 0
		for _, w := range words {
			if hasPrefix(heading, w) {
				score += 3
			}
			if hasPrefix(title, w) {
				score += 2
			}
			if hasPrefix(text, w) {
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

// stopwordList is English filler that carries no topic: question words,
// auxiliaries, pronouns, articles, prepositions and the generic verbs of a
// how-to question. The same words are in GuideSearch.swift.
const stopwordList = `a about after again all also am an and any are as at be been before being
but by can can't could did didn't do does doesn't doing don't done for from get gets getting got
had has have having he her here him his how i i'm if in into is isn't it it's its just me might
more most must my need needs no not of off on one only or our out own please set sets setting
should so some such than that the their them then there these they this those to too up us use
used uses using very via want wants was way we were what when where which who whom whose why will
with without would yes you your`

var stopwords = func() map[string]bool {
	m := map[string]bool{}
	for w := range strings.FieldsSeq(stopwordList) {
		m[w] = true
	}
	return m
}()

// queryWords is splitWords minus stopwords.
func queryWords(query string) []string {
	out := []string{}
	for _, w := range splitWords(query) {
		if !stopwords[w] {
			out = append(out, w)
		}
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

// splitWords lowercases s (a typographic apostrophe becomes '), splits it
// on whitespace, trims non-letter/digit edges and a possessive 's, and keeps
// words of two or more characters.
func splitWords(s string) []string {
	out := []string{}
	for w := range strings.FieldsSeq(strings.ReplaceAll(strings.ToLower(s), "’", "'")) {
		w = strings.TrimFunc(w, func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsDigit(r) })
		w = strings.TrimSuffix(w, "'s")
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
