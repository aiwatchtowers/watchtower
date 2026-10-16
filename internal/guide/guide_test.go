package guide

import (
	"io/fs"
	"strings"
	"testing"

	embedded "watchtower/docs/guide"
)

func TestLoadSplitsAtH2AndH3(t *testing.T) {
	sections, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	page, ok := Page(sections, "features/calendar-and-meeting-prep.md")
	if !ok {
		t.Fatal("calendar page missing")
	}
	intro := page[0]
	if intro.Level != 1 || intro.Anchor != "" || intro.Heading != intro.PageTitle || intro.PageTitle != "Calendar and meeting prep" {
		t.Fatalf("bad intro section: %+v", intro)
	}
	headings := map[string]int{}
	for _, s := range page[1:] {
		headings[s.Heading] = s.Level
	}
	if headings["Why use it"] != 2 || headings["What Prepare reads"] != 3 {
		t.Fatalf("expected ## and ### sections, got %v", headings)
	}
	for _, s := range sections {
		for _, line := range strings.Split(s.Text, "\n") {
			if strings.HasPrefix(line, "## ") || strings.HasPrefix(line, "### ") {
				t.Fatalf("%s / %s contains heading line %q", s.Page, s.Heading, line)
			}
		}
		if s.Page == "README.md" || s.Page == "WRITING.md" {
			t.Fatalf("catalogue leaked into sections: %s", s.Page)
		}
	}
}

func TestAnchorMatchesGitHub(t *testing.T) {
	seen := map[string]int{}
	if got := Anchor("Why the briefing skips a day?", seen); got != "why-the-briefing-skips-a-day" {
		t.Fatalf("got %q", got)
	}
	if got := Anchor("Recordings → Recap", seen); got != "recordings--recap" {
		t.Fatalf("got %q", got)
	}
	Anchor("Troubleshooting", seen)
	if got := Anchor("Troubleshooting", seen); got != "troubleshooting-1" {
		t.Fatalf("got %q", got)
	}
	if got := Anchor("Troubleshooting", seen); got != "troubleshooting-2" {
		t.Fatalf("got %q", got)
	}
}

func TestEveryPageIsInCatalog(t *testing.T) {
	cat := Catalog()
	err := fs.WalkDir(embedded.FS, ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(p, ".md") || p == "README.md" || p == "WRITING.md" {
			return err
		}
		if !strings.Contains(cat, "]("+p+")") {
			t.Errorf("page %s is not linked from README.md", p)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestSearchPrefersHeadings(t *testing.T) {
	sections, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	got := Search(sections, "recap", 3)
	if len(got) == 0 || !strings.Contains(strings.ToLower(got[0].Heading), "recap") {
		t.Fatalf("first hit should have Recap in its heading: %+v", got)
	}
	if len(got) > 3 {
		t.Fatalf("limit ignored: %d", len(got))
	}
	if r := Search(sections, "zzzz-no-match", 3); len(r) != 0 {
		t.Fatalf("expected no hits, got %d", len(r))
	}
}

func TestBaseURL(t *testing.T) {
	if got := BaseURL("1.2.3"); got != "https://github.com/aiwatchtowers/watchtower/blob/v1.2.3/docs/guide/" {
		t.Fatal(got)
	}
}
