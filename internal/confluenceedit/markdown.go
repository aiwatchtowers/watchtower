package confluenceedit

import (
	"regexp"
	"strconv"
	"strings"
)

// The markdown subset a replace_section body is written in — the same
// vocabulary Doc.Text renders (spec §3): paragraphs ("\n" inside one is a
// line break), "#".."######" headings, "-"/"*"/"+" and "N."/"N)" lists
// nested by indentation (any deeper indent nests; Text uses two spaces),
// pipe tables (a "---" separator after the first row makes it a header
// row), fenced code (``` or ~~~, with an optional language), and marker
// tokens. A line holding only a block marker's token puts that block back.
// The parser never fails: whatever it does not recognise is paragraph text.

var (
	itemRe    = regexp.MustCompile(`^(\s*)([-*+]|(\d{1,9})[.)])(?:\s+(.*))?$`)
	headingRe = regexp.MustCompile(`^\s{0,3}(#{1,6})(?:\s+(.*?))?\s*$`)
	fenceRe   = regexp.MustCompile("^\\s{0,3}(`{3,}|~{3,})\\s*([^`\\s]*)")
	sepCellRe = regexp.MustCompile(`^:?-+:?$`)
)

// mdParser splits a body into blocks line by line.
type mdParser struct {
	a      *applier
	lines  []string
	i      int
	blocks []*block
}

// parseBody parses a replace_section body into blocks and decides the
// markers of every inline unit (see classify). A marker may appear at most
// once in the whole body, and a block marker only on a line of its own.
func (a *applier) parseBody(body string, c classifyCtx) ([]*block, error) {
	body = noNUL.Replace(strings.ReplaceAll(body, "\r\n", "\n"))
	p := &mdParser{a: a, lines: strings.Split(body, "\n")}
	for p.i < len(p.lines) {
		p.block()
	}
	seen := map[int]bool{}
	for _, bl := range p.blocks {
		if err := a.markBlock(bl, c, seen); err != nil {
			return nil, err
		}
	}
	return p.blocks, nil
}

// markBlock classifies one parsed block's markers, recording each in seen.
func (a *applier) markBlock(bl *block, c classifyCtx, seen map[int]bool) error {
	if bl.kind == blockMarker {
		return claim(seen, bl.marker, a.orig.markers)
	}
	for _, u := range bl.editUnits() {
		if u.kind != unitInline {
			continue
		}
		marks, err := a.classify(u.text, c)
		if err != nil {
			return err
		}
		if err := a.checkInline(marks); err != nil {
			return err
		}
		for _, m := range marks {
			if err := claim(seen, m.k, a.orig.markers); err != nil {
				return err
			}
		}
		u.marks = marks
	}
	return nil
}

func claim(seen map[int]bool, k int, markers []Marker) error {
	if seen[k] {
		return &dupError{tok: markers[k-1].token()}
	}
	seen[k] = true
	return nil
}

type dupError struct{ tok string }

func (e *dupError) Error() string {
	return "duplicate marker " + e.tok + ": each marker can appear only once"
}

func blank(l string) bool { return strings.TrimSpace(l) == "" }

func indentOf(l string) int { return len(l) - len(strings.TrimLeft(l, " \t")) }

func (p *mdParser) add(bl *block) { p.blocks = append(p.blocks, bl) }

func (p *mdParser) block() {
	line := p.lines[p.i]
	switch {
	case blank(line):
		p.i++
	case fenceRe.MatchString(line):
		p.code()
	case headingRe.MatchString(line):
		m := headingRe.FindStringSubmatch(line)
		p.add(&block{kind: blockHeading, level: len(m[1]), unit: inlineU(ctxHeading, m[2])})
		p.i++
	case strings.HasPrefix(strings.TrimSpace(line), "|"):
		p.table()
	case itemRe.MatchString(line):
		p.list()
	default:
		p.paragraph()
	}
}

func inlineU(ctx inlineCtx, text string) *unit {
	return &unit{kind: unitInline, ctx: ctx, text: text}
}

// startsBlock reports a line that ends a paragraph: a blank line or the
// start of any other block.
func startsBlock(l string) bool {
	t := strings.TrimSpace(l)
	return t == "" || fenceRe.MatchString(l) || headingRe.MatchString(l) ||
		strings.HasPrefix(t, "|") || itemRe.MatchString(l)
}

func (p *mdParser) paragraph() {
	var lines []string
	for p.i < len(p.lines) && (len(lines) == 0 || !startsBlock(p.lines[p.i])) {
		lines = append(lines, strings.TrimSpace(p.lines[p.i]))
		p.i++
	}
	text := strings.Join(lines, "\n")
	if k, ok := p.a.tokens[text]; ok && p.a.isBlock[k] {
		p.add(&block{kind: blockMarker, marker: k})
		return
	}
	p.add(&block{kind: blockParagraph, unit: inlineU(ctxPara, text)})
}

// code consumes a fenced block up to a closing fence of the same character
// at least as long, or to the end of the body.
func (p *mdParser) code() {
	m := fenceRe.FindStringSubmatch(p.lines[p.i])
	fence := m[1]
	p.i++
	var body []string
	for p.i < len(p.lines) {
		l := strings.TrimSpace(p.lines[p.i])
		p.i++
		if strings.HasPrefix(l, fence) && strings.Trim(l, fence[:1]) == "" {
			break
		}
		body = append(body, p.lines[p.i-1])
	}
	p.add(&block{kind: blockCode, lang: m[2], unit: &unit{kind: unitCode, text: strings.Join(body, "\n")}})
}

func (p *mdParser) table() {
	var rows [][]*unit
	header := false
	width := 0
	for p.i < len(p.lines) && strings.HasPrefix(strings.TrimSpace(p.lines[p.i]), "|") {
		cells := splitRow(p.lines[p.i])
		p.i++
		if len(rows) == 1 && !header && isSeparator(cells) {
			header = true
			continue
		}
		row := make([]*unit, len(cells))
		for j, c := range cells {
			row[j] = inlineU(ctxCell, c)
		}
		rows = append(rows, row)
		width = max(width, len(row))
	}
	for i := range rows {
		for len(rows[i]) < width {
			rows[i] = append(rows[i], inlineU(ctxCell, ""))
		}
	}
	p.add(&block{kind: blockTable, rows: rows, header: header})
}

// splitRow splits "| a | b |" into trimmed cells; "\|" is a literal pipe.
func splitRow(l string) []string {
	t := strings.TrimSpace(l)
	t = strings.TrimPrefix(t, "|")
	if strings.HasSuffix(t, "|") && !strings.HasSuffix(t, `\|`) {
		t = t[:len(t)-1]
	}
	var cells []string
	var cur strings.Builder
	for i := 0; i < len(t); i++ {
		switch {
		case t[i] == '\\' && i+1 < len(t) && t[i+1] == '|':
			cur.WriteByte('|')
			i++
		case t[i] == '|':
			cells = append(cells, strings.TrimSpace(cur.String()))
			cur.Reset()
		default:
			cur.WriteByte(t[i])
		}
	}
	return append(cells, strings.TrimSpace(cur.String()))
}

func isSeparator(cells []string) bool {
	for _, c := range cells {
		if !sepCellRe.MatchString(c) {
			return false
		}
	}
	return len(cells) > 0
}

// list consumes one list: items at any indentation, nested by indent (see
// nestDepth), with indented non-item lines continuing the previous item
// on a new line. A blank line ends the list unless an item or an indented
// line follows; a top-level item with the other kind of bullet starts the
// next list, as Text renders two adjacent lists.
func (p *mdParser) list() {
	var items []listItem
	var stack []int
	for p.i < len(p.lines) {
		line := p.lines[p.i]
		if blank(line) {
			if !p.listContinuesAfterBlank() {
				break
			}
			p.i++
			continue
		}
		m := itemRe.FindStringSubmatch(line)
		if m == nil {
			if indentOf(line) == 0 {
				break
			}
			last := items[len(items)-1].paras[0]
			last.text = strings.TrimLeft(last.text+"\n"+strings.TrimSpace(line), "\n")
			p.i++
			continue
		}
		var depth int
		stack, depth = nestDepth(stack, len(m[1]))
		if depth == 0 && len(items) > 0 && (bullet(m) == "-") != (items[0].bullet == "-") {
			break // a new kind of top-level list is a block of its own
		}
		items = append(items, listItem{depth: depth, bullet: bullet(m), paras: []*unit{inlineU(ctxPara, strings.TrimSpace(m[4]))}})
		p.i++
	}
	p.add(&block{kind: blockList, items: items})
}

func (p *mdParser) listContinuesAfterBlank() bool {
	j := p.i
	for j < len(p.lines) && blank(p.lines[j]) {
		j++
	}
	return j < len(p.lines) && (itemRe.MatchString(p.lines[j]) || indentOf(p.lines[j]) > 0)
}

// bullet is an item's bullet in Text's form: "-" or "N.".
func bullet(m []string) string {
	if m[3] == "" {
		return "-"
	}
	n, _ := strconv.Atoi(m[3])
	return strconv.Itoa(n) + "."
}

// nestDepth places an item indented ind in the stack of open list indents
// and returns its depth: deeper than the current list nests one level,
// shallower closes lists back to the nearest one it fits. Tolerant of any
// indent width (Text writes two spaces per level).
func nestDepth(stack []int, ind int) ([]int, int) {
	for len(stack) > 1 && ind < stack[len(stack)-1] && ind <= stack[len(stack)-2] {
		stack = stack[:len(stack)-1]
	}
	switch {
	case len(stack) == 0:
		stack = append(stack, ind)
	case ind > stack[len(stack)-1]:
		stack = append(stack, ind)
	case ind < stack[len(stack)-1]:
		stack[len(stack)-1] = ind
	}
	return stack, len(stack) - 1
}
