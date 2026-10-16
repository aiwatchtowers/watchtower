// Package userguide indexes the embedded user guide by section for search.
package userguide

import (
	"fmt"
	"io/fs"
	"sort"
	"strings"
	"sync"
	"unicode"

	embedded "watchtower/docs/guide"
)

// Section is one searchable slice of a guide page.
type Section struct {
	Page      string // path under docs/guide/, e.g. features/calendar-and-meeting-prep.md
	PageTitle string
	Heading   string
	Anchor    string // GitHub slug, empty for the page intro
	Text      string
	Level     int // 1 = page intro, 2 = "##", 3 = "###"
}

var (
	loadOnce     sync.Once
	loadSections []Section
	loadErr      error
)

// Load parses every embedded page except README.md and WRITING.md. The result
// is cached after the first call; callers must not modify it.
func Load() ([]Section, error) {
	loadOnce.Do(func() { loadSections, loadErr = parseAll() })
	return loadSections, loadErr
}

// Catalog returns the README.md catalogue text.
func Catalog() string {
	b, err := embedded.FS.ReadFile("README.md")
	if err != nil {
		return ""
	}
	return string(b)
}

// BaseURL is the GitHub location of the guide: the release tag for a clean
// X.Y.Z version (a leading "v" allowed), main for anything else — a dev
// build ("dev", "0.19.0-12-gabc-dirty"), whose tag may not exist or may
// predate docs/guide.
func BaseURL(version string) string {
	ref := "main"
	if v := strings.TrimPrefix(version, "v"); isReleaseVersion(v) {
		ref = "v" + v
	}
	return "https://github.com/aiwatchtowers/watchtower/blob/" + ref + "/docs/guide/"
}

// isReleaseVersion reports whether v is exactly X.Y.Z (digits only).
func isReleaseVersion(v string) bool {
	parts := strings.Split(v, ".")
	if len(parts) != 3 {
		return false
	}
	for _, p := range parts {
		if p == "" || strings.Trim(p, "0123456789") != "" {
			return false
		}
	}
	return true
}

// Anchor builds the GitHub heading slug; seen counts repeats within a page.
func Anchor(heading string, seen map[string]int) string {
	var b strings.Builder
	for _, r := range strings.ToLower(heading) {
		switch {
		case r == ' ':
			b.WriteByte('-')
		case r == '-' || unicode.IsLetter(r) || unicode.IsDigit(r):
			b.WriteRune(r)
		}
	}
	slug := b.String()
	n := seen[slug]
	seen[slug] = n + 1
	if n > 0 {
		return fmt.Sprintf("%s-%d", slug, n)
	}
	return slug
}

func parseAll() ([]Section, error) {
	var pages []string
	err := fs.WalkDir(embedded.FS, ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || !strings.HasSuffix(p, ".md") || p == "README.md" || p == "WRITING.md" {
			return nil
		}
		pages = append(pages, p)
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("walking embedded guide: %w", err)
	}
	sort.Strings(pages)
	var out []Section
	for _, p := range pages {
		b, err := embedded.FS.ReadFile(p)
		if err != nil {
			return nil, fmt.Errorf("reading guide page %s: %w", p, err)
		}
		out = append(out, parsePage(p, string(b))...)
	}
	return out, nil
}

func parsePage(page, src string) []Section {
	title := page
	seen := map[string]int{}
	cur := Section{Page: page, Level: 1}
	var body []string
	var out []Section
	inFence := false

	flush := func() {
		cur.Text = strings.TrimSpace(strings.Join(body, "\n"))
		cur.PageTitle = title
		if cur.Level == 1 {
			cur.Heading = title
		}
		out = append(out, cur)
		body = nil
	}

	for _, line := range strings.Split(src, "\n") {
		if strings.HasPrefix(line, "```") || strings.HasPrefix(line, "~~~") {
			inFence = !inFence
		}
		if !inFence {
			switch {
			case strings.HasPrefix(line, "# ") && title == page:
				title = strings.TrimSpace(line[2:])
				continue
			case strings.HasPrefix(line, "## "), strings.HasPrefix(line, "### "):
				flush()
				level := 2
				if strings.HasPrefix(line, "### ") {
					level = 3
				}
				h := strings.TrimSpace(line[level+1:])
				cur = Section{Page: page, Heading: h, Anchor: Anchor(h, seen), Level: level}
				continue
			}
		}
		body = append(body, line)
	}
	flush()
	return out
}
