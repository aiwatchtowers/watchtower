package confluenceedit

import (
	"strconv"
	"strings"
)

// Parse builds the editable model of a storage-format XHTML document. It
// accepts any input (storage is never rejected for being malformed — the
// untouched bytes round-trip regardless); the only error is ErrTooDeep.
func Parse(storage string) (*Doc, error) {
	root, err := parseTree(storage)
	if err != nil {
		return nil, err
	}
	b := &builder{src: storage, containers: []container{{parent: -1, content: span{0, len(storage)}}}}
	b.topLevel(root.children)
	return &Doc{
		src: storage, blocks: b.blocks, containers: b.containers, units: b.units,
		markers: b.markers, markerSpans: b.markerSpans,
	}, nil
}

// builder classifies the tree into blocks, editable units and markers, all
// in document order (so marker ordinals and unit spans come out sorted).
type builder struct {
	src         string
	blocks      []*block
	containers  []container
	cur         int // the container blocks are being added to
	units       []*unit
	markers     []Marker
	markerSpans []span
}

// checkpoint/rollback let a structure (a list, a table) be tried as
// editable and fall back to one opaque marker without leaking the units or
// the marker ordinals its content consumed on the way.
type checkpoint struct{ units, markers int }

func (b *builder) checkpoint() checkpoint {
	return checkpoint{len(b.units), len(b.markers)}
}

func (b *builder) rollback(c checkpoint) {
	b.units = b.units[:c.units]
	b.markers = b.markers[:c.markers]
	b.markerSpans = b.markerSpans[:c.markers]
}

// transparentContainers are Confluence layout wrappers: their tags stay as
// untouched bytes and their children are top-level blocks (the rule
// internal/confluence's flattenTransparent applies for search).
var transparentContainers = map[string]bool{
	"ac:layout": true, "ac:layout-section": true, "ac:layout-cell": true,
}

// inlineNames are elements that continue a run of inline content at block
// level, so "text <strong>x</strong> more" outside any <p> is one paragraph.
var inlineNames = map[string]bool{
	"strong": true, "b": true, "em": true, "i": true, "s": true, "del": true,
	"strike": true, "u": true, "code": true, "a": true, "span": true, "br": true,
	"sub": true, "sup": true, "time": true, "ac:link": true, "ac:emoticon": true,
	"ac:inline-comment-marker": true,
}

// blockNames are elements that cannot sit inside a list item's or a table
// cell's inline text; one there makes the whole list/table opaque.
var blockNames = map[string]bool{
	"table": true, "div": true, "blockquote": true, "pre": true, "hr": true,
	"h1": true, "h2": true, "h3": true, "h4": true, "h5": true, "h6": true,
	"ac:task-list": true, "ac:layout": true, "ac:layout-section": true,
	"ac:layout-cell": true,
}

func isInline(n *node) bool {
	return n.typ != nodeElement || inlineNames[n.name]
}

func isList(n *node) bool {
	return n.isElement("ul") || n.isElement("ol")
}

// isBlank reports a node carrying nothing visible: whitespace-only text or
// a comment/stray tag.
func isBlank(n *node) bool {
	switch n.typ {
	case nodeText:
		return strings.TrimSpace(n.text) == ""
	case nodeOther:
		return true
	default:
		return false
	}
}

// trimBlank drops blank nodes from both ends of a run.
func trimBlank(run []*node) []*node {
	for len(run) > 0 && isBlank(run[0]) {
		run = run[1:]
	}
	for len(run) > 0 && isBlank(run[len(run)-1]) {
		run = run[:len(run)-1]
	}
	return run
}

func headingLevel(name string) int {
	if len(name) == 2 && name[0] == 'h' && name[1] >= '1' && name[1] <= '6' {
		return int(name[1] - '0')
	}
	return 0
}

// topLevel classifies a sequence of block-level siblings.
func (b *builder) topLevel(nodes []*node) {
	var run []*node
	for _, n := range nodes {
		if isInline(n) {
			run = append(run, n)
			continue
		}
		b.paragraphRun(run)
		run = nil
		if transparentContainers[n.name] {
			b.enterContainer(n)
			continue
		}
		b.blockFor(n)
	}
	b.paragraphRun(run)
}

// enterContainer classifies a layout element's children as blocks of a new
// container, so a section can be kept from crossing the element's bounds.
func (b *builder) enterContainer(n *node) {
	id := len(b.containers)
	b.containers = append(b.containers, container{
		parent: b.cur, elemStart: n.start, content: span{n.innerStart, n.innerEnd},
	})
	prev := b.cur
	b.cur = id
	b.topLevel(n.children)
	b.cur = prev
}

// addBlock appends bl covering sp in the current container.
func (b *builder) addBlock(bl *block, sp span) {
	bl.span = sp
	bl.container = b.cur
	b.blocks = append(b.blocks, bl)
}

// paragraphRun turns a block-level run of inline content into a paragraph.
func (b *builder) paragraphRun(run []*node) {
	if u := b.runUnit(run, ctxPara); u != nil {
		b.addBlock(&block{kind: blockParagraph, unit: u}, span{u.start, u.end})
	}
}

func (b *builder) blockFor(n *node) {
	sp := span{n.start, n.end}
	switch {
	case headingLevel(n.name) > 0:
		b.addBlock(&block{kind: blockHeading, level: headingLevel(n.name), unit: b.elementUnit(n, ctxHeading)}, sp)
	case n.name == "p":
		b.addBlock(&block{kind: blockParagraph, unit: b.elementUnit(n, ctxPara)}, sp)
	case isList(n):
		b.listBlock(n)
	case n.name == "table":
		b.tableBlock(n)
	case isCodeMacro(n):
		b.codeBlock(n)
	default:
		b.markerBlock(n)
	}
}

func (b *builder) markerBlock(n *node) {
	b.addBlock(&block{kind: blockMarker, marker: b.addMarker(n)}, span{n.start, n.end})
}

// addMarker records n as the next marker and returns its ordinal.
func (b *builder) addMarker(n *node) int {
	k := len(b.markers) + 1
	b.markers = append(b.markers, Marker{Ordinal: k, Label: labelFor(n), Raw: b.src[n.start:n.end]})
	b.markerSpans = append(b.markerSpans, span{n.start, n.end})
	return k
}

func (b *builder) addUnit(u *unit) *unit {
	b.units = append(b.units, u)
	return u
}

// elementUnit makes the content of element n one inline unit. A
// self-closed element (<p />) has no content span to rewrite and yields nil.
func (b *builder) elementUnit(n *node, ctx inlineCtx) *unit {
	u, _ := b.elementUnitPlain(n, ctx)
	return u
}

// elementUnitPlain is elementUnit that also reports whether the content was
// plain (only meaningful for ctxCell).
func (b *builder) elementUnitPlain(n *node, ctx inlineCtx) (*unit, bool) {
	if n.selfClosing {
		return nil, true
	}
	return b.inlineUnit(n.children, ctx, span{n.innerStart, n.innerEnd})
}

// runUnit makes a run of inline siblings one unit spanning them, blank
// nodes at either end excluded; an all-blank run yields nil.
func (b *builder) runUnit(run []*node, ctx inlineCtx) *unit {
	run = trimBlank(run)
	if len(run) == 0 {
		return nil
	}
	u, _ := b.inlineUnit(run, ctx, span{run[0].start, run[len(run)-1].end})
	return u
}

// isCodeMacro reports a code/noformat macro with a plain-text body to edit.
func isCodeMacro(n *node) bool {
	if !n.isElement("ac:structured-macro") {
		return false
	}
	if name := n.attr("ac:name"); name != "code" && name != "noformat" {
		return false
	}
	body := n.firstChild("ac:plain-text-body")
	return body != nil && !body.selfClosing
}

// codeBlock makes a code macro's plain-text body (its CDATA bytes) the
// unit; the macro's tag and parameters stay untouched bytes.
func (b *builder) codeBlock(n *node) {
	body := n.firstChild("ac:plain-text-body")
	u := b.addUnit(&unit{
		kind: unitCode, start: body.innerStart, end: body.innerEnd, text: plainText(body),
		other: !onlyText(body),
	})
	b.addBlock(&block{kind: blockCode, lang: strings.TrimSpace(param(n, "language")), unit: u}, span{n.start, n.end})
}

// onlyText reports whether n's children are all text or CDATA, i.e. its
// content is exactly what plainText returns.
func onlyText(n *node) bool {
	for _, ch := range n.children {
		if ch.typ != nodeText && ch.typ != nodeCDATA {
			return false
		}
	}
	return true
}

// plainText concatenates n's direct text and CDATA children.
func plainText(n *node) string {
	var sb strings.Builder
	for _, ch := range n.children {
		if ch.typ == nodeText || ch.typ == nodeCDATA {
			sb.WriteString(ch.text)
		}
	}
	return sb.String()
}

// listBlock renders a regular list as a markdown list, or falls back to one
// opaque marker for anything a markdown list cannot carry.
func (b *builder) listBlock(n *node) {
	cp := b.checkpoint()
	var items []listItem
	if b.collectList(n, 0, &items) {
		b.addBlock(&block{kind: blockList, items: items}, span{n.start, n.end})
		return
	}
	b.rollback(cp)
	b.markerBlock(n)
}

func (b *builder) collectList(list *node, depth int, items *[]listItem) bool {
	num := listStart(list) - 1
	for _, ch := range list.children {
		if isBlank(ch) {
			continue
		}
		if !ch.isElement("li") {
			return false
		}
		num++
		bullet := "-"
		if list.name == "ol" {
			bullet = strconv.Itoa(num) + "."
		}
		if !b.collectItem(ch, depth, bullet, items) {
			return false
		}
	}
	return true
}

// listStart is a list's first number: an <ol>'s start attribute when that
// is a valid integer, else 1.
func listStart(list *node) int {
	if list.name != "ol" {
		return 1
	}
	if n, err := strconv.Atoi(strings.TrimSpace(list.attr("start"))); err == nil {
		return n
	}
	return 1
}

// collectItem flattens one <li>: its own text (an inline run and/or <p>
// children, each one unit) followed by nested lists. Text after a nested
// list, or a block element inside the item, makes the list irregular.
func (b *builder) collectItem(li *node, depth int, bullet string, items *[]listItem) bool {
	idx := len(*items)
	*items = append(*items, listItem{depth: depth, bullet: bullet})
	it := itemWalker{b: b, items: items, idx: idx, depth: depth}
	for _, ch := range li.children {
		if !it.child(ch) {
			return false
		}
	}
	return it.flush()
}

// itemWalker holds the state of one collectItem pass.
type itemWalker struct {
	b      *builder
	items  *[]listItem
	idx    int
	depth  int
	run    []*node
	nested bool
}

func (it *itemWalker) child(ch *node) bool {
	switch {
	case isList(ch):
		if !it.flush() {
			return false
		}
		it.nested = true
		return it.b.collectList(ch, it.depth+1, it.items)
	case ch.isElement("p"):
		if !it.flush() || it.nested {
			return false
		}
		it.addPara(it.b.elementUnit(ch, ctxPara))
		return true
	case ch.typ == nodeElement && blockNames[ch.name]:
		return false
	default:
		it.run = append(it.run, ch)
		return true
	}
}

func (it *itemWalker) flush() bool {
	run := trimBlank(it.run)
	it.run = nil
	if len(run) == 0 {
		return true
	}
	if it.nested {
		return false
	}
	it.addPara(it.b.runUnit(run, ctxPara))
	return true
}

func (it *itemWalker) addPara(u *unit) {
	if u != nil {
		(*it.items)[it.idx].paras = append((*it.items)[it.idx].paras, u)
	}
}

// tableBlock renders a plain table (every cell plain inline text, no
// spans, rectangular, one header row of <th> over rows of <td>) as a pipe
// table, or falls back to one opaque marker. A pipe table always has a
// header row, so a headerless or column-header table has no faithful pipe
// form — shown as a table, it would gain a header row the page lacks.
func (b *builder) tableBlock(n *node) {
	cp := b.checkpoint()
	var rows [][]*unit
	if headerRowShape(n) && b.collectRows(n, &rows) && rectangular(rows) {
		b.addBlock(&block{kind: blockTable, rows: rows}, span{n.start, n.end})
		return
	}
	b.rollback(cp)
	b.markerBlock(n)
}

// headerRowShape reports a table whose first row is all <th> and every
// other row all <td>.
func headerRowShape(table *node) bool {
	for i, tr := range tableRows(table, nil) {
		want := "td"
		if i == 0 {
			want = "th"
		}
		for _, cell := range tr.children {
			if cell.typ == nodeElement && cell.name != want {
				return false
			}
		}
	}
	return true
}

// tableRows lists a table's <tr> elements in order, through thead/tbody/
// tfoot.
func tableRows(n *node, acc []*node) []*node {
	for _, ch := range n.children {
		switch {
		case ch.isElement("tr"):
			acc = append(acc, ch)
		case ch.isElement("thead"), ch.isElement("tbody"), ch.isElement("tfoot"):
			acc = tableRows(ch, acc)
		}
	}
	return acc
}

func rectangular(rows [][]*unit) bool {
	if len(rows) == 0 || len(rows[0]) == 0 {
		return false
	}
	for _, r := range rows {
		if len(r) != len(rows[0]) {
			return false
		}
	}
	return true
}

func (b *builder) collectRows(n *node, rows *[][]*unit) bool {
	for _, ch := range n.children {
		switch {
		case isBlank(ch), ch.isElement("colgroup"):
			continue
		case ch.isElement("thead"), ch.isElement("tbody"), ch.isElement("tfoot"):
			if !b.collectRows(ch, rows) {
				return false
			}
		case ch.isElement("tr"):
			row, ok := b.tableRow(ch)
			if !ok {
				return false
			}
			*rows = append(*rows, row)
		default:
			return false
		}
	}
	return true
}

func (b *builder) tableRow(tr *node) ([]*unit, bool) {
	var row []*unit
	for _, ch := range tr.children {
		if isBlank(ch) {
			continue
		}
		if !ch.isElement("td") && !ch.isElement("th") || spansCells(ch) {
			return nil, false
		}
		u, ok := b.cellUnit(ch)
		if !ok {
			return nil, false
		}
		row = append(row, u)
	}
	return row, true
}

func spansCells(cell *node) bool {
	for _, key := range []string{"colspan", "rowspan"} {
		if v := cell.attr(key); v != "" && v != "1" {
			return true
		}
	}
	return false
}

// cellUnit makes a cell's text one unit: the content of its single <p>
// wrapper (how Confluence Cloud writes cells) or the whole cell content.
// It fails for anything a pipe-table cell cannot hold: a marker, a line
// break, a '|', several paragraphs or a block element. A self-closed cell
// (<td />) is an empty cell with no unit.
func (b *builder) cellUnit(cell *node) (*unit, bool) {
	if cell.selfClosing {
		return nil, true
	}
	content := trimBlank(cell.children)
	target := cell
	if len(content) == 1 && content[0].isElement("p") {
		target = content[0]
	} else if hasBlockChild(content) {
		return nil, false
	}
	u, plain := b.elementUnitPlain(target, ctxCell)
	if !plain || (u != nil && strings.ContainsAny(u.text, "|\n")) {
		return nil, false
	}
	return u, true
}

func hasBlockChild(nodes []*node) bool {
	for _, n := range nodes {
		if n.typ == nodeElement && (blockNames[n.name] || n.name == "p" || isList(n)) {
			return true
		}
	}
	return false
}
