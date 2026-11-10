package reviewmap

import (
	"fmt"
	"slices"
	"strings"
)

// maxChapterLines is the split size of a lane and of a directory (tech spec
// §2.5): a unit is never cut, so one big file still makes one chapter.
const maxChapterLines = 400

// spec is a chapter the session's agent proposed, before validation.
type spec struct {
	title string
	paths []string
	core  bool
}

// agentChapters builds the agent's chapters the way the Desktop's
// ReviewChapters.resolve does: n in "agent:<n>" is the 1-based index over
// every spec, empty ones included (numbers may have gaps); a path is taken
// once, by the first spec naming it; tests come first inside a chapter;
// core chapters move first after numbering. lines holds every diff path
// (noise at 0). taken gains the paths used.
func agentChapters(specs []spec, lines map[string]int, taken map[string]bool) []Chapter {
	var out []Chapter
	for i, s := range specs {
		var paths []string
		for _, p := range s.paths {
			if _, ok := lines[p]; ok && !taken[p] {
				taken[p] = true
				paths = append(paths, p)
			}
		}
		if len(paths) == 0 {
			continue
		}
		out = append(out, Chapter{
			Key:          fmt.Sprintf("agent:%d", i+1),
			Title:        s.title,
			Core:         s.core,
			Paths:        testsFirst(paths),
			ChangedLines: sumLines(paths, lines),
			agent:        true,
		})
	}
	core := slices.DeleteFunc(slices.Clone(out), func(c Chapter) bool { return !c.Core })
	return append(core, slices.DeleteFunc(out, func(c Chapter) bool { return c.Core })...)
}

func testsFirst(paths []string) []string {
	out := make([]string, 0, len(paths))
	for _, p := range paths {
		if IsTest(p) {
			out = append(out, p)
		}
	}
	for _, p := range paths {
		if !IsTest(p) {
			out = append(out, p)
		}
	}
	return out
}

func sumLines(paths []string, lines map[string]int) int {
	n := 0
	for _, p := range paths {
		n += lines[p]
	}
	return n
}

// dirPart is one chapter of the directory split: its directory, its part
// number (1-based) and files.
type dirPart struct {
	dir    string
	number int
	paths  []string
	lines  int
}

// unit is a file with the tests that go with it, or a test with no
// subject; units are never cut.
type unit struct {
	sortKey, dir string
	paths        []string
	lines        int
}

// splitByDir is the Desktop's ReviewChapters.mechanical ported as is: files
// sorted by path (byte order), a test placed before its one subject (one
// in the test's own directory first, else the one subject anywhere with the
// test's stem), units grouped by directory in order of first appearance and
// a directory split into parts of at most maxChapterLines (a unit over the
// cap stays whole).
func splitByDir(paths []string, lines map[string]int) []dirPart {
	live := slices.Clone(paths)
	slices.Sort(live)

	subjectsByStem := map[string][]string{}
	for _, p := range live {
		if !IsTest(p) {
			stem := fileStem(p, false)
			subjectsByStem[stem] = append(subjectsByStem[stem], p)
		}
	}
	testsBySubject := map[string][]string{}
	var standalone []string
	for _, p := range live {
		if !IsTest(p) {
			continue
		}
		all := subjectsByStem[fileStem(p, true)]
		var sameDir []string
		for _, s := range all {
			if dirOf(s) == dirOf(p) {
				sameDir = append(sameDir, s)
			}
		}
		subjects := all
		if len(sameDir) > 0 {
			subjects = sameDir
		}
		if len(subjects) == 1 {
			testsBySubject[subjects[0]] = append(testsBySubject[subjects[0]], p)
		} else {
			standalone = append(standalone, p)
		}
	}

	var units []unit
	for _, p := range live {
		if IsTest(p) {
			continue
		}
		group := append(slices.Clone(testsBySubject[p]), p)
		units = append(units, unit{sortKey: p, dir: dirOf(p), paths: group, lines: sumLines(group, lines)})
	}
	for _, p := range standalone {
		units = append(units, unit{sortKey: p, dir: dirOf(p), paths: []string{p}, lines: lines[p]})
	}
	slices.SortStableFunc(units, func(a, b unit) int { return strings.Compare(a.sortKey, b.sortKey) })

	var dirOrder []string
	byDir := map[string][]unit{}
	for _, u := range units {
		if _, ok := byDir[u.dir]; !ok {
			dirOrder = append(dirOrder, u.dir)
		}
		byDir[u.dir] = append(byDir[u.dir], u)
	}

	var out []dirPart
	for _, dir := range dirOrder {
		number := 0
		var cur dirPart
		flush := func() {
			number++
			cur.dir, cur.number = dir, number
			out = append(out, cur)
			cur = dirPart{}
		}
		for _, u := range byDir[dir] {
			if len(cur.paths) > 0 && cur.lines+u.lines > maxChapterLines {
				flush()
			}
			cur.paths = append(cur.paths, u.paths...)
			cur.lines += u.lines
		}
		if len(cur.paths) > 0 {
			flush()
		}
	}
	return out
}

// keySuffix is "<dir>" for a directory's first part, "<dir>#N" after.
func (d dirPart) keySuffix() string {
	if d.number == 1 {
		return d.dir
	}
	return fmt.Sprintf("%s#%d", d.dir, d.number)
}

// title is the directory ("(root)" for the top) with " (N)" after the
// first part, as the Desktop titles it.
func (d dirPart) title() string {
	base := d.dir
	if base == "" {
		base = "(root)"
	}
	if d.number == 1 {
		return base
	}
	return fmt.Sprintf("%s (%d)", base, d.number)
}

func dirOf(p string) string {
	i := strings.LastIndexByte(p, '/')
	if i < 0 {
		return ""
	}
	return p[:i]
}

// fileStem is the base name without its extension; for a test, the test
// suffix (unless it is the whole name) and a test_ prefix are dropped too.
func fileStem(p string, test bool) string {
	name := dropExtension(p[strings.LastIndexByte(p, '/')+1:])
	if !test {
		return name
	}
	for _, suffix := range testSuffixes {
		if strings.HasSuffix(name, suffix) && name != suffix {
			name = strings.TrimSuffix(name, suffix)
			break
		}
	}
	return strings.TrimPrefix(name, "test_")
}
