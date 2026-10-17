package userguide

import (
	"encoding/json"
	"os"
	"slices"
	"sort"
	"testing"
)

// searchFixture is testdata/queries.json, shared with the Desktop's
// GuideSearchTests: both rankers must agree on it.
type searchFixture struct {
	Stopwords []string `json:"stopwords"`
	Queries   []struct {
		Query string `json:"query"`
		Top   string `json:"top"` // page#anchor, "" = no match
	} `json:"queries"`
	Sections []struct {
		Page      string `json:"page"`
		PageTitle string `json:"page_title"`
		Heading   string `json:"heading"`
		Anchor    string `json:"anchor"`
		Level     int    `json:"level"`
		Text      string `json:"text"`
	} `json:"sections"`
}

func loadSearchFixture(t *testing.T) searchFixture {
	t.Helper()
	data, err := os.ReadFile("testdata/queries.json")
	if err != nil {
		t.Fatal(err)
	}
	var f searchFixture
	if err := json.Unmarshal(data, &f); err != nil {
		t.Fatal(err)
	}
	return f
}

func topOf(sections []Section, query string) string {
	got := Search(sections, query, 1)
	if len(got) == 0 {
		return ""
	}
	return got[0].Page + "#" + got[0].Anchor
}

func TestSearchStopwordsMatchFixture(t *testing.T) {
	f := loadSearchFixture(t)
	var ours []string
	for w := range stopwords {
		ours = append(ours, w)
	}
	sort.Strings(ours)
	if !slices.Equal(ours, f.Stopwords) {
		t.Fatalf("stopwords drifted from testdata/queries.json (the Swift side reads it too):\n got %v\nwant %v", ours, f.Stopwords)
	}
}

// Natural questions find their section on the fixture snapshot (the
// parity half, run by Swift too) and on the live embedded guide.
func TestSearchNaturalQuestions(t *testing.T) {
	f := loadSearchFixture(t)
	snapshot := make([]Section, len(f.Sections))
	for i, s := range f.Sections {
		snapshot[i] = Section{Page: s.Page, PageTitle: s.PageTitle, Heading: s.Heading, Anchor: s.Anchor, Level: s.Level, Text: s.Text}
	}
	live, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	for _, q := range f.Queries {
		if got := topOf(snapshot, q.Query); got != q.Top {
			t.Errorf("snapshot: %q -> %q, want %q", q.Query, got, q.Top)
		}
		if got := topOf(live, q.Query); got != q.Top {
			t.Errorf("live guide: %q -> %q, want %q (a guide edit moved it: update testdata/queries.json)", q.Query, got, q.Top)
		}
	}
}

func TestSearchWordPrefixNotSubstring(t *testing.T) {
	sections := []Section{
		{Page: "a.md", PageTitle: "Alpha", Heading: "Why use it", Text: "Show the item."},
		{Page: "b.md", PageTitle: "Beta", Heading: "Reminders", Text: "A reminder fires before the event."},
	}
	// "how" sits inside "show", "it" inside "item": neither is a word prefix,
	// and both are stopwords anyway; "remind" prefixes "reminders".
	if got := Search(sections, "how do I set a remind", 5); len(got) != 1 || got[0].Page != "b.md" {
		t.Fatalf("got %+v", got)
	}
	if got := Search(sections, "tem", 5); len(got) != 0 {
		t.Fatalf("a substring inside a text word matched: %+v", got)
	}
	// A possessive matches the bare word.
	if got := Search(sections, "event's", 5); len(got) != 1 || got[0].Page != "b.md" {
		t.Fatalf("got %+v", got)
	}
}
