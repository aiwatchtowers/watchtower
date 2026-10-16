// Package guide embeds the user guide (docs/guide/**.md) so the binary can
// index it and the Desktop app can link to it.
package guide

import (
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"io/fs"
	"path"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"unicode"
)

// BaseURL is where a guide page lives on GitHub; append "<path>#<anchor>".
const BaseURL = "https://github.com/aiwatchtowers/watchtower/blob/main/docs/guide/"

//go:embed *.md */*.md */*/*.md
var files embed.FS

// Page is one guide page.
type Page struct {
	Path, Title string
	Sections    []Section
}

// Section is a "##"/"###" section. The text before the first heading has an
// empty Heading and Anchor.
type Section struct {
	Heading, Anchor, Text string
}

// paths returns every embedded file path (WRITING.md included), sorted.
func paths() []string {
	var out []string
	_ = fs.WalkDir(files, ".", func(p string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			out = append(out, p)
		}
		return nil
	})
	sort.Strings(out)
	return out
}

// Pages returns every embedded page except WRITING.md, sorted by path.
func Pages() []Page {
	var pages []Page
	for _, p := range paths() {
		if p == "WRITING.md" {
			continue
		}
		b, err := files.ReadFile(p)
		if err != nil {
			continue
		}
		pages = append(pages, parse(p, string(b)))
	}
	return pages
}

func parse(p, body string) Page {
	page := Page{Path: p}
	seen := map[string]int{}
	cur := Section{}
	var text strings.Builder
	flush := func() {
		cur.Text = strings.TrimSpace(text.String())
		if cur.Heading != "" || cur.Text != "" {
			page.Sections = append(page.Sections, cur)
		}
		text.Reset()
	}
	fence := ""
	for _, line := range strings.Split(body, "\n") {
		trim := strings.TrimSpace(line)
		if fence != "" {
			if strings.HasPrefix(trim, fence) {
				fence = ""
			}
		} else if strings.HasPrefix(trim, "```") || strings.HasPrefix(trim, "~~~") {
			fence = trim[:3]
		} else if strings.HasPrefix(line, "# ") && page.Title == "" {
			page.Title = strings.TrimSpace(line[2:])
			continue
		} else if h, ok := sectionHeading(line); ok {
			flush()
			cur = Section{Heading: h, Anchor: Slug(h, seen)}
			continue
		}
		text.WriteString(line)
		text.WriteByte('\n')
	}
	flush()
	return page
}

func sectionHeading(line string) (string, bool) {
	for _, prefix := range []string{"## ", "### "} {
		if strings.HasPrefix(line, prefix) {
			return strings.TrimSpace(line[len(prefix):]), true
		}
	}
	return "", false
}

// Slug returns the GitHub anchor for heading: lowercase, spaces to "-",
// everything but letters, digits, "-" and "_" dropped. seen counts repeats on
// one page (the second "x" becomes "x-1").
func Slug(heading string, seen map[string]int) string {
	var b strings.Builder
	for _, r := range strings.ToLower(strings.TrimSpace(heading)) {
		switch {
		case r == ' ':
			b.WriteByte('-')
		case r == '-' || r == '_' || unicode.IsLetter(r) || unicode.IsDigit(r):
			b.WriteRune(r)
		}
	}
	base := b.String()
	n := seen[base]
	seen[base] = n + 1
	if n == 0 {
		return base
	}
	return base + "-" + strconv.Itoa(n)
}

var relLink = regexp.MustCompile(`\]\(([^)\s:]+\.md)(#[^)\s]*)?\)`)

// Catalogue returns README.md with its relative links rewritten to absolute
// BaseURL ones.
func Catalogue() string {
	b, err := files.ReadFile("README.md")
	if err != nil {
		return ""
	}
	return relLink.ReplaceAllStringFunc(string(b), func(m string) string {
		sub := relLink.FindStringSubmatch(m)
		return "](" + BaseURL + path.Clean(sub[1]) + sub[2] + ")"
	})
}

var entryLine = regexp.MustCompile(`^- \[([^\]]+)\]\(([^)\s#]+\.md)[^)]*\)`)

// Map returns the README's group headings and one "- <Title> (<path>)" line
// per entry, with no descriptions and no URLs: the compact app map for the
// chat prompt.
func Map() string {
	b, err := files.ReadFile("README.md")
	if err != nil {
		return ""
	}
	var out []string
	for _, line := range strings.Split(string(b), "\n") {
		if h, ok := strings.CutPrefix(line, "## "); ok {
			if len(out) > 0 {
				out = append(out, "")
			}
			out = append(out, strings.TrimSpace(h))
		} else if m := entryLine.FindStringSubmatch(line); m != nil {
			out = append(out, "- "+m[1]+" ("+path.Clean(m[2])+")")
		}
	}
	return strings.Join(out, "\n")
}

// Hash is the hex sha256 over all embedded files, in path order.
func Hash() string {
	h := sha256.New()
	for _, p := range paths() {
		b, _ := files.ReadFile(p)
		h.Write([]byte(p))
		h.Write([]byte{0})
		h.Write(b)
		h.Write([]byte{0})
	}
	return hex.EncodeToString(h.Sum(nil))
}
