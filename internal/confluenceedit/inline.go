package confluenceedit

import (
	"regexp"
	"strconv"
	"strings"
)

// inlineCtx is where a unit's inline content sits; it decides what a line
// break becomes and whether markers are allowed at all.
type inlineCtx int

const (
	ctxPara    inlineCtx = iota // paragraph or list item: <br/> is "\n"
	ctxHeading                  // a heading line: <br/> is a marker
	ctxCell                     // a pipe-table cell: must stay plain
)

// inliner renders one unit's inline content as markdown with markers.
type inliner struct {
	b     *builder
	ctx   inlineCtx
	plain bool              // false once a cell needed a marker or a line break
	other bool              // true once the content held a comment or stray tag
	codes []string          // rendered code spans, stood in for by holes until finalize
	links map[string]string // href -> the link's original start tag
}

// inlineUnit renders nodes as the editable text of a unit spanning sp and
// reports whether the content was plain (no marker, no line break).
func (b *builder) inlineUnit(nodes []*node, ctx inlineCtx, sp span) (*unit, bool) {
	in := &inliner{b: b, ctx: ctx, plain: true}
	text, marks := in.finalize(in.nodes(nodes))
	u := &unit{
		kind: unitInline, ctx: ctx, start: sp.start, end: sp.end, text: text,
		marks: marks, other: in.other, links: in.links,
	}
	return b.addUnit(u), in.plain
}

func (in *inliner) nodes(ns []*node) string {
	var sb strings.Builder
	for _, n := range ns {
		sb.WriteString(in.node(n))
	}
	return sb.String()
}

// asciiSpace turns every ASCII whitespace byte of source text into a plain
// space (collapsed later), leaving NBSP and other Unicode spaces alone:
// in XHTML a newline in character data is just a space, while "\n" in the
// editable text is reserved for a real <br/>. A NUL (which XML forbids in a
// document anyway) becomes U+FFFD, so NUL can delimit code-span holes.
var asciiSpace = strings.NewReplacer("\n", " ", "\r", " ", "\t", " ", "\f", " ", "\x00", "\uFFFD")

// noNUL keeps NUL out of every other string that reaches the inline text.
var noNUL = strings.NewReplacer("\x00", "\uFFFD")

// holeRe finds the stand-ins codeSpan ("c") and marker ("m") leave for
// finalize to fill.
var holeRe = regexp.MustCompile("\x00([cm])([0-9]+)\x00")

func (in *inliner) node(n *node) string {
	switch n.typ {
	case nodeText, nodeCDATA:
		return asciiSpace.Replace(n.text)
	case nodeOther:
		in.other = true
		return ""
	default:
		return in.element(n)
	}
}

func (in *inliner) element(n *node) string {
	switch n.name {
	case "strong", "b":
		return in.wrap(n, "**")
	case "em", "i":
		return in.wrap(n, "_")
	case "s", "del", "strike":
		return in.wrap(n, "~~")
	case "code":
		return in.codeSpan(n)
	case "a":
		return in.link(n)
	case "br":
		return in.lineBreak(n)
	case "span":
		if len(n.attrs) == 0 {
			return in.nodes(n.children)
		}
	}
	return in.marker(n)
}

// marker renders n as its ⟦k:label⟧ token. In a cell that makes the table
// not plain; the caller rolls the ordinal back.
func (in *inliner) marker(n *node) string {
	if in.ctx == ctxCell {
		in.plain = false
	}
	return "\x00m" + strconv.Itoa(in.b.addMarker(n)) + "\x00"
}

// wrap renders emphasis. Whitespace at the edges of the content moves
// outside the delimiters ("a<b> x </b>" → "a **x** "), and empty emphasis
// renders as nothing.
func (in *inliner) wrap(n *node, delim string) string {
	s := in.nodes(n.children)
	core := strings.Trim(s, " \n")
	if core == "" {
		return s
	}
	lead := s[:len(s)-len(strings.TrimLeft(s, " \n"))]
	trail := s[len(strings.TrimRight(s, " \n")):]
	return lead + delim + core + delim + trail
}

// codeSpan renders <code> with only text inside as a code span, fenced
// with more backticks than the content holds; anything richer is a marker.
// The content's spaces and tabs are kept verbatim (only line terminators
// become spaces, since "\n" in the editable text means <br/>): the span is
// parked as a hole and filled after finalize has collapsed the rest of the
// line, so rewriting another word of the paragraph never touches it.
func (in *inliner) codeSpan(n *node) string {
	for _, ch := range n.children {
		if ch.typ == nodeElement {
			return in.marker(n)
		}
	}
	content := codeLines.Replace(plainText(n))
	if content == "" {
		return ""
	}
	in.codes = append(in.codes, fenceCode(content))
	return "\x00c" + strconv.Itoa(len(in.codes)-1) + "\x00"
}

// codeLines maps line terminators inside a code span to spaces.
var codeLines = strings.NewReplacer("\r\n", " ", "\n", " ", "\r", " ", "\f", " ")

// fenceCode wraps content in more backticks than it holds, padding with one
// space each side where CommonMark would otherwise strip or misread one
// (content starting/ending with a backtick, or with a space at both ends).
func fenceCode(content string) string {
	fence := strings.Repeat("`", longestRun(content, '`')+1)
	bothSpaces := strings.HasPrefix(content, " ") && strings.HasSuffix(content, " ") && strings.Trim(content, " ") != ""
	if bothSpaces || strings.HasPrefix(content, "`") || strings.HasSuffix(content, "`") {
		content = " " + content + " "
	}
	return fence + content + fence
}

// link renders <a href> as [text](href); an anchor without href, or a link
// with no visible text, is a marker. The href is checked BEFORE the
// children are walked: a marker's Raw covers its whole element, so a
// marker minted for a child first would be orphaned inside it (its token
// never shown). Empty text means the children minted no marker (a token
// is never empty), so that fallback is safe after the walk.
func (in *inliner) link(n *node) string {
	href := n.attr("href")
	if href == "" {
		return in.marker(n)
	}
	text := strings.TrimSpace(in.nodes(n.children))
	if text == "" {
		return in.marker(n)
	}
	href = noNUL.Replace(href)
	if _, seen := in.links[href]; !seen {
		if in.links == nil {
			in.links = map[string]string{}
		}
		in.links[href] = in.b.src[n.start:n.innerStart]
	}
	return "[" + text + "](" + href + ")"
}

func (in *inliner) lineBreak(n *node) string {
	if in.ctx == ctxPara {
		return "\n"
	}
	return in.marker(n)
}

// finalize collapses runs of spaces and trims every line (the editable
// text's only newlines are line breaks), then fills the holes: code spans
// with their verbatim spans, markers with their tokens (recording where
// each real marker sits). Only ASCII spaces collapse — an NBSP is content
// the owner typed and stays as is.
func (in *inliner) finalize(s string) (string, []mark) {
	lines := strings.Split(s, "\n")
	for i, l := range lines {
		lines[i] = collapseSpaces(l)
	}
	return in.fillHoles(strings.Trim(strings.Join(lines, "\n"), "\n"))
}

func (in *inliner) fillHoles(s string) (string, []mark) {
	locs := holeRe.FindAllStringSubmatchIndex(s, -1)
	if len(locs) == 0 {
		return s, nil
	}
	var sb strings.Builder
	var marks []mark
	prev := 0
	for _, l := range locs {
		sb.WriteString(s[prev:l[0]])
		i, _ := strconv.Atoi(s[l[4]:l[5]])
		if s[l[2]] == 'c' {
			sb.WriteString(in.codes[i])
		} else {
			marks = append(marks, mark{at: sb.Len(), k: i})
			sb.WriteString(in.b.markers[i-1].token())
		}
		prev = l[1]
	}
	sb.WriteString(s[prev:])
	return sb.String(), marks
}

func collapseSpaces(s string) string {
	var sb strings.Builder
	prevSpace := false
	for _, r := range s {
		if r == ' ' && prevSpace {
			continue
		}
		prevSpace = r == ' '
		sb.WriteRune(r)
	}
	return strings.Trim(sb.String(), " ")
}

// maxLabelRunes caps a marker label; the label is a hint, Raw is the data.
const maxLabelRunes = 60

// labelFor is a marker's human hint: what kind of element, and the one
// attribute or text that identifies it.
func labelFor(n *node) string {
	return sanitizeLabel(rawLabel(n), n.name)
}

func rawLabel(n *node) string {
	switch n.name {
	case "ac:link":
		return linkLabel(n)
	case "ac:structured-macro":
		return macroLabel(n)
	case "ac:image":
		return "image " + resourceName(n)
	case "ac:emoticon":
		return "emoticon " + n.attr("ac:name")
	case "time":
		return "date " + n.attr("datetime")
	case "ac:inline-comment-marker":
		return "commented " + flatText(n)
	case "br":
		return "line break"
	}
	return structureLabel(n)
}

// structureLabel labels the opaque block structures and any other element.
func structureLabel(n *node) string {
	switch n.name {
	case "table":
		rows, cols := tableShape(n)
		return "table " + strconv.Itoa(rows) + "x" + strconv.Itoa(cols)
	case "ul", "ol":
		return countLabel("list", countChildren(n, "li"), "item")
	case "ac:task-list":
		return countLabel("task list", countChildren(n, "ac:task"), "task")
	case "a":
		return "anchor " + n.attr("name")
	}
	return strings.TrimPrefix(n.name, "ac:") + " " + flatText(n)
}

func countLabel(kind string, count int, noun string) string {
	if count != 1 {
		noun += "s"
	}
	return kind + " " + strconv.Itoa(count) + " " + noun
}

func linkLabel(n *node) string {
	if u := n.firstChild("ri:user"); u != nil {
		if id := u.attr("ri:account-id"); id != "" {
			return "@" + id
		}
		return "@user"
	}
	body := linkBody(n)
	if body == "" {
		body = resourceName(n)
	}
	return "link " + body
}

// linkBody is an ac:link's visible text, when it carries one.
func linkBody(n *node) string {
	if b := n.firstChild("ac:plain-text-link-body"); b != nil {
		return plainText(b)
	}
	if b := n.firstChild("ac:link-body"); b != nil {
		return flatText(b)
	}
	return ""
}

// resourceName names what an ac:link/ac:image points at.
func resourceName(n *node) string {
	for _, ch := range n.children {
		switch ch.name {
		case "ri:page", "ri:blog-post":
			return ch.attr("ri:content-title")
		case "ri:attachment":
			return ch.attr("ri:filename")
		case "ri:url":
			return ch.attr("ri:value")
		case "ri:space":
			return ch.attr("ri:space-key")
		}
	}
	return ""
}

func macroLabel(n *node) string {
	name := n.attr("ac:name")
	switch name {
	case "jira":
		return "jira " + param(n, "key")
	case "status":
		return "status " + param(n, "title")
	}
	return "macro " + name + " " + param(n, "title")
}

// param returns a macro's ac:parameter value for name.
func param(n *node, name string) string {
	for _, ch := range n.children {
		if ch.isElement("ac:parameter") && ch.attr("ac:name") == name {
			return flatText(ch)
		}
	}
	return ""
}

// flatText concatenates every text and CDATA descendant of n. The tree's
// depth is bounded by maxDepth, so the recursion is too.
func flatText(n *node) string {
	var sb strings.Builder
	var walk func(*node)
	walk = func(n *node) {
		for _, ch := range n.children {
			if ch.typ == nodeText || ch.typ == nodeCDATA {
				sb.WriteString(ch.text)
				sb.WriteByte(' ')
			}
			walk(ch)
		}
	}
	walk(n)
	return sb.String()
}

func countChildren(n *node, name string) int {
	count := 0
	for _, ch := range n.children {
		if ch.isElement(name) {
			count++
		}
	}
	return count
}

// tableShape counts a table's rows and its widest row's cells.
func tableShape(n *node) (rows, cols int) {
	for _, ch := range n.children {
		switch ch.name {
		case "thead", "tbody", "tfoot":
			r, c := tableShape(ch)
			rows, cols = rows+r, max(cols, c)
		case "tr":
			rows++
			cols = max(cols, countChildren(ch, "td")+countChildren(ch, "th"))
		}
	}
	return rows, cols
}

// sanitizeLabel makes a label safe inside ⟦k:label⟧: no marker brackets,
// one line, collapsed spaces, at most maxLabelRunes runes. An empty label
// falls back to the element's name.
func sanitizeLabel(label, fallback string) string {
	// Valid UTF-8 first: the unit text a marker token is embedded in is
	// rebuilt rune by rune (invalid bytes become U+FFFD), so a label with
	// a raw invalid byte would never match its own token in Text().
	label = strings.ToValidUTF8(label, "�")
	label = strings.NewReplacer(markerOpen, " ", markerClose, " ", "\x00", " ").Replace(label)
	label = strings.Join(strings.Fields(label), " ")
	if label == "" {
		label = strings.TrimPrefix(fallback, "ac:")
	}
	if label == "" {
		label = "element"
	}
	if r := []rune(label); len(r) > maxLabelRunes {
		label = strings.TrimSpace(string(r[:maxLabelRunes-1])) + "…"
	}
	return label
}
