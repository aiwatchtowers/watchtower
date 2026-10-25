package specreview

import (
	"regexp"
	"strconv"
	"strings"
)

var planTaskHeading = regexp.MustCompile(`^### Task [0-9A-Za-z.]+:`)

// Chapters splits doc at "## " headings outside fenced code (deeper levels
// fold in); in a plan the "### Task N:" headings split instead. Text before
// the first heading is chapter ch:0 "Intro", present only when not blank.
func Chapters(doc string, t DocType) []Chapter {
	type head struct {
		text  string
		start int
	}
	var heads []head
	fence := ""
	for pos := 0; pos < len(doc); {
		end := strings.IndexByte(doc[pos:], '\n')
		next := len(doc)
		line := doc[pos:]
		if end >= 0 {
			line = doc[pos : pos+end]
			next = pos + end + 1
		}
		line = strings.TrimRight(line, "\r")
		if f := fenceMarker(line); f != "" {
			switch {
			case fence == "":
				fence = f
			case strings.HasPrefix(f, fence[:1]) && len(f) >= len(fence):
				fence = ""
			}
		} else if fence == "" && isChapterHeading(line, t) {
			heads = append(heads, head{strings.TrimSpace(strings.TrimLeft(line, "#")), pos})
		}
		pos = next
	}

	out := []Chapter{}
	introEnd := len(doc)
	if len(heads) > 0 {
		introEnd = heads[0].start
	}
	if strings.TrimSpace(doc[:introEnd]) != "" {
		out = append(out, Chapter{Key: "ch:0", Heading: "Intro", Start: 0, End: introEnd})
	}
	for i, h := range heads {
		end := len(doc)
		if i+1 < len(heads) {
			end = heads[i+1].start
		}
		out = append(out, Chapter{Key: "ch:" + strconv.Itoa(i+1), Heading: h.text, Start: h.start, End: end})
	}
	return out
}

func isChapterHeading(line string, t DocType) bool {
	if t == Plan {
		return planTaskHeading.MatchString(line)
	}
	return strings.HasPrefix(line, "## ")
}

// fenceMarker returns the run of ``` or ~~~ that opens or closes a fence on
// this line (up to three spaces of indent), else "".
func fenceMarker(line string) string {
	s := strings.TrimLeft(line, " ")
	if len(line)-len(s) > 3 || len(s) < 3 || (s[0] != '`' && s[0] != '~') {
		return ""
	}
	n := 0
	for n < len(s) && s[n] == s[0] {
		n++
	}
	if n < 3 {
		return ""
	}
	return s[:n]
}
