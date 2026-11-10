package reviewmap

import (
	"fmt"
	"path"
	"strings"

	"watchtower/internal/reviewdiff"
)

const patternsFile = "review-map.md"

const patternsNotePrefix = ".watchtower/" + patternsFile + ": "

// Patterns are a repository's own danger and noise globs from
// .watchtower/review-map.md. Each glob is matched per path segment with
// path.Match, and a "**" segment matches any number of segments.
type Patterns struct {
	Breaking    []string
	Significant []string
	Skip        []string
	Notes       []string // why the file or a line of it was not used
}

// LoadPatterns reads <workbenchFolder>/.watchtower/review-map.md under the
// lens-file rules (reviewdiff.ReadWatchtowerFile). A missing file gives no
// patterns and no note; a refused one gives no patterns and one note.
func LoadPatterns(workbenchFolder string) Patterns {
	data, note := reviewdiff.ReadWatchtowerFile(workbenchFolder, patternsFile)
	if note != "" {
		return Patterns{Notes: []string{patternsNotePrefix + note}}
	}
	return ParsePatterns(string(data))
}

// ParsePatterns parses the file's text: "## Breaking", "## Significant" and
// "## Can skip" headings (case-insensitive), each followed by "- <glob>"
// lines. Every other non-empty line, any other heading ("#", "###" or an
// unknown "## "; its globs are dropped) and a bad glob become notes.
func ParsePatterns(text string) Patterns {
	var p Patterns
	text = strings.TrimPrefix(text, "\ufeff")
	var cur *[]string
	unknown := false // under an unknown heading: its globs are dropped silently
	for i, raw := range strings.Split(text, "\n") {
		n := i + 1
		line := strings.TrimSpace(raw)
		switch {
		case line == "":
		case strings.HasPrefix(line, "#"):
			// Any heading ends the current section; only the three "## "
			// ones start a new one, so a "### Sub" never feeds its parent.
			name := strings.TrimSpace(strings.TrimLeft(line, "#"))
			cur = nil
			if strings.HasPrefix(line, "## ") {
				switch strings.ToLower(name) {
				case "breaking":
					cur = &p.Breaking
				case "significant":
					cur = &p.Significant
				case "can skip":
					cur = &p.Skip
				}
			}
			unknown = cur == nil
			if unknown {
				p.Notes = append(p.Notes, fmt.Sprintf("%sline %d: unknown section %q", patternsNotePrefix, n, name))
			}
		case line == "-" || strings.HasPrefix(line, "- "):
			if unknown {
				continue
			}
			if cur == nil {
				p.Notes = append(p.Notes, badPatternLine(n))
				continue
			}
			glob := strings.TrimSpace(line[1:])
			if glob == "" {
				p.Notes = append(p.Notes, fmt.Sprintf("%sline %d: empty glob", patternsNotePrefix, n))
				continue
			}
			if !validGlob(glob) {
				p.Notes = append(p.Notes, fmt.Sprintf("%sline %d: bad glob %q", patternsNotePrefix, n, glob))
				continue
			}
			*cur = append(*cur, glob)
		default:
			p.Notes = append(p.Notes, badPatternLine(n))
		}
	}
	return p
}

func badPatternLine(n int) string {
	return fmt.Sprintf(`%sline %d: not a "## Breaking|Significant|Can skip" heading or a "- glob"`, patternsNotePrefix, n)
}

// validGlob refuses a malformed segment and an empty, "." or ".." one (a
// leading or trailing "/", "a//b", "./x"): no git path segment equals those,
// so the glob could never match.
func validGlob(glob string) bool {
	for _, seg := range strings.Split(glob, "/") {
		if seg == "" || seg == "." || seg == ".." {
			return false
		}
		if _, err := path.Match(seg, ""); err != nil {
			return false
		}
	}
	return true
}

// Match returns the level a pattern gives path, or skip when a "Can skip"
// glob matches it; ok is false when no glob matches. A danger glob wins over
// a skip glob, and Breaking over Significant.
func (p Patterns) Match(filePath string) (level Level, skip bool, ok bool) {
	switch {
	case matchAny(p.Breaking, filePath):
		return Breaking, false, true
	case matchAny(p.Significant, filePath):
		return Significant, false, true
	case matchAny(p.Skip, filePath):
		return Normal, true, true
	}
	return Normal, false, false
}

func matchAny(globs []string, filePath string) bool {
	segs := strings.Split(filePath, "/")
	for _, g := range globs {
		if matchSegments(strings.Split(g, "/"), segs) {
			return true
		}
	}
	return false
}

// matchSegments matches glob segments against path segments, "**" taking any
// number of them. It fills a table over (glob suffix, path suffix) pairs, so
// a glob of many "**" costs len(glob) × len(segs) steps, not exponential.
func matchSegments(glob, segs []string) bool {
	// m[i][j]: glob[i:] matches segs[j:].
	m := make([][]bool, len(glob)+1)
	for i := range m {
		m[i] = make([]bool, len(segs)+1)
	}
	m[len(glob)][len(segs)] = true
	for i := len(glob) - 1; i >= 0; i-- {
		for j := len(segs); j >= 0; j-- {
			if glob[i] == "**" {
				m[i][j] = m[i+1][j] || (j < len(segs) && m[i][j+1])
				continue
			}
			if j < len(segs) {
				ok, _ := path.Match(glob[i], segs[j])
				m[i][j] = ok && m[i+1][j+1]
			}
		}
	}
	return m[0][0]
}
