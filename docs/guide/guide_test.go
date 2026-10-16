package guide

import (
	"os"
	"path"
	"regexp"
	"strings"
	"testing"
)

func TestPagesHaveTitles(t *testing.T) {
	pages := Pages()
	if len(pages) == 0 {
		t.Fatal("no pages embedded")
	}
	for _, p := range pages {
		if p.Title == "" {
			t.Errorf("%s: empty title", p.Path)
		}
		if p.Path == "WRITING.md" {
			t.Errorf("WRITING.md must not be a page")
		}
	}
}

func TestSlug(t *testing.T) {
	m := map[string]int{}
	if got := Slug("Why use it", m); got != "why-use-it" {
		t.Errorf("got %q", got)
	}
	if got := Slug("When it's empty or wrong", m); got != "when-its-empty-or-wrong" {
		t.Errorf("got %q", got)
	}
	if got := Slug("Why use it", m); got != "why-use-it-1" {
		t.Errorf("got %q", got)
	}
}

var mdLink = regexp.MustCompile(`\]\(([^)\s:]+\.md)(#[^)\s]*)?\)`)

func TestRelativeLinksResolve(t *testing.T) {
	byPath := map[string]Page{}
	for _, p := range Pages() {
		byPath[p.Path] = p
	}
	for _, p := range Pages() {
		for _, s := range p.Sections {
			for _, m := range mdLink.FindAllStringSubmatch(s.Text, -1) {
				target := path.Join(path.Dir(p.Path), m[1])
				tp, ok := byPath[target]
				if !ok {
					// Links leaving the guide (../../features/x.md) are not
					// embedded; they resolve on disk from this package's dir.
					if !strings.HasPrefix(target, "../") {
						t.Errorf("%s: link to missing %s", p.Path, m[1])
					} else if _, serr := os.Stat(target); serr != nil {
						t.Errorf("%s: link to missing %s", p.Path, m[1])
					}
					continue
				}
				if m[2] == "" {
					continue
				}
				found := false
				for _, ts := range tp.Sections {
					if ts.Anchor != "" && "#"+ts.Anchor == m[2] {
						found = true
					}
				}
				if !found {
					t.Errorf("%s: %s has no anchor %s", p.Path, target, m[2])
				}
			}
		}
	}
}

func TestCatalogueListsEveryPageOnce(t *testing.T) {
	b, err := files.ReadFile("README.md")
	if err != nil {
		t.Fatal(err)
	}
	counts := map[string]int{}
	for _, m := range mdLink.FindAllStringSubmatch(string(b), -1) {
		counts[path.Clean(m[1])]++
	}
	for _, p := range Pages() {
		if p.Path == "README.md" {
			continue
		}
		if counts[p.Path] != 1 {
			t.Errorf("%s listed %d times in README.md", p.Path, counts[p.Path])
		}
	}
}

func TestFeaturePagesUnder8KB(t *testing.T) {
	for _, p := range paths() {
		if !strings.HasPrefix(p, "features/") {
			continue
		}
		b, _ := files.ReadFile(p)
		if len(b) > 8192 {
			t.Errorf("%s is %d bytes (> 8192)", p, len(b))
		}
	}
}

func TestCatalogueLinksAreAbsolute(t *testing.T) {
	c := Catalogue()
	if mdLink.MatchString(c) {
		t.Errorf("relative .md link left: %v", mdLink.FindString(c))
	}
	if !strings.Contains(c, BaseURL+"features/inbox.md") {
		t.Error("missing absolute inbox link")
	}
}

func TestMapIsCompact(t *testing.T) {
	m := Map()
	if !strings.Contains(m, "- Inbox (features/inbox.md)") {
		t.Fatalf("missing Inbox entry:\n%s", m)
	}
	if strings.Contains(m, "https://") || strings.Contains(m, " — ") {
		t.Fatalf("map carries a URL or description:\n%s", m)
	}
}
