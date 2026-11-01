package handlers

import (
	"bufio"
	"bytes"
	"html"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/rivo/uniseg"
	"github.com/yuin/goldmark"
	gast "github.com/yuin/goldmark/ast"
	"github.com/yuin/goldmark/extension"
	east "github.com/yuin/goldmark/extension/ast"
	ghtml "github.com/yuin/goldmark/renderer/html"
	"github.com/yuin/goldmark/text"

	"watchtower/internal/asks"
)

// anchorContextLength is CommentAnchor.contextLength: characters (grapheme
// clusters) of context on either side of a quote.
const anchorContextLength = 64

// plainHeading is DocumentHeading; offset is in bytes of plainDoc.text (the
// Swift side counts UTF-16 units: only the order is used here).
type plainHeading struct {
	offset int
	level  int
	title  string
}

// plainDoc is Core's RenderedDocument without the style runs.
type plainDoc struct {
	text     string
	headings []plainHeading
}

// plainMarkdown reads CommonMark + the GFM parts swift-markdown reads
// (tables, strikethrough, task items). Goldmark parsers are safe for
// concurrent use.
var plainMarkdown = goldmark.New(goldmark.WithExtensions(extension.Table, extension.Strikethrough, extension.TaskList))

// renderPlain is DocumentRendering.render's text: the plain text the
// Desktop anchors review comments in.
func renderPlain(markdown string) string { return renderDocument(markdown).text }

// renderDocument is DocumentRendering.render over goldmark's tree: every
// block ends with one blank line; a heading or paragraph is its inline text
// (markup dropped, soft breaks a space, hard breaks a newline, escapes and
// entities decoded, raw HTML kept); a code block is its code; a list item
// starts with its indent and "• ", "N. ", "☑ " or "☐ "; a quote is its
// children; a table puts every cell on its own line, then a blank line; a
// rule is one no-break space.
func renderDocument(markdown string) plainDoc {
	src := []byte(markdown)
	b := &plainBuilder{src: src}
	root := plainMarkdown.Parser().Parse(text.NewReader(src))
	for n := root.FirstChild(); n != nil; n = n.NextSibling() {
		b.block(n, 0)
	}
	return plainDoc{text: b.buf.String(), headings: b.headings}
}

type plainBuilder struct {
	src      []byte
	buf      strings.Builder
	headings []plainHeading
}

func (b *plainBuilder) append(s string) { b.buf.WriteString(s) }

func (b *plainBuilder) newlineIfNeeded() {
	if s := b.buf.String(); s != "" && !strings.HasSuffix(s, "\n") {
		b.append("\n")
	}
}

// endBlock: every block ends with one blank line.
func (b *plainBuilder) endBlock() {
	s := b.buf.String()
	if s == "" || strings.HasSuffix(s, "\n\n") {
		return
	}
	if strings.HasSuffix(s, "\n") {
		b.append("\n")
	} else {
		b.append("\n\n")
	}
}

func (b *plainBuilder) block(n gast.Node, depth int) {
	switch n := n.(type) {
	case *gast.Heading:
		offset := b.buf.Len()
		title := b.inlineText(n)
		b.headings = append(b.headings, plainHeading{offset: offset, level: n.Level, title: title})
		b.append(title)
	case *gast.Paragraph, *gast.TextBlock:
		b.inlines(n)
	case *gast.FencedCodeBlock, *gast.CodeBlock:
		b.append(strings.TrimSuffix(b.lines(n), "\n"))
	case *gast.List:
		b.list(n, depth)
	case *gast.Blockquote:
		for c := n.FirstChild(); c != nil; c = c.NextSibling() {
			b.block(c, depth)
		}
	case *east.Table:
		b.table(n)
	case *gast.ThematicBreak:
		b.append(" ")
	case *gast.HTMLBlock:
		raw := b.lines(n)
		if n.HasClosure() {
			raw += string(n.ClosureLine.Value(b.src))
		}
		b.append(raw)
	default:
		return // swift-markdown's other blocks render nothing
	}
	b.endBlock()
}

func (b *plainBuilder) lines(n gast.Node) string {
	var out strings.Builder
	for i := 0; i < n.Lines().Len(); i++ {
		line := n.Lines().At(i)
		out.Write(line.Value(b.src))
	}
	return out.String()
}

func (b *plainBuilder) list(l *gast.List, depth int) {
	indent := strings.Repeat("    ", depth)
	index := 0
	for item := l.FirstChild(); item != nil; item = item.NextSibling() {
		marker := "• "
		if l.IsOrdered() {
			marker = strconv.Itoa(l.Start+index) + ". "
		}
		if box := taskBox(item); box != nil {
			marker = "☐ "
			if box.IsChecked {
				marker = "☑ "
			}
		}
		index++
		b.append(indent + marker)
		position := 0
		for c := item.FirstChild(); c != nil; c = c.NextSibling() {
			if position > 0 {
				b.newlineIfNeeded()
			}
			position++
			switch c := c.(type) {
			case *gast.Paragraph, *gast.TextBlock:
				b.inlines(c)
			case *gast.List:
				b.list(c, depth+1)
			default:
				b.block(c, depth+1)
			}
		}
		b.newlineIfNeeded()
	}
}

// taskBox is a GFM task item's checkbox: the first inline of its first block.
func taskBox(item gast.Node) *east.TaskCheckBox {
	if first := item.FirstChild(); first != nil {
		if box, ok := first.FirstChild().(*east.TaskCheckBox); ok {
			return box
		}
	}
	return nil
}

// table: every cell its own line (a short row padded with empty ones), then
// a blank line.
func (b *plainBuilder) table(t *east.Table) {
	var rows [][]gast.Node
	columns := 0
	for row := t.FirstChild(); row != nil; row = row.NextSibling() {
		var cells []gast.Node
		for cell := row.FirstChild(); cell != nil; cell = cell.NextSibling() {
			cells = append(cells, cell)
		}
		columns = max(columns, len(cells))
		rows = append(rows, cells)
	}
	b.newlineIfNeeded()
	for _, row := range rows {
		for column := range columns {
			if column < len(row) {
				b.inlines(row[column])
			}
			b.append("\n")
		}
	}
	b.append("\n")
}

func (b *plainBuilder) inlineText(n gast.Node) string {
	inner := &plainBuilder{src: b.src}
	inner.inlines(n)
	return inner.buf.String()
}

func (b *plainBuilder) inlines(n gast.Node) {
	for c := n.FirstChild(); c != nil; c = c.NextSibling() {
		b.inline(c)
	}
}

func (b *plainBuilder) inline(n gast.Node) {
	switch n := n.(type) {
	case *gast.Text:
		value := n.Segment.Value(b.src)
		if n.IsRaw() {
			b.append(string(value))
		} else {
			b.append(decodeText(value))
		}
		switch {
		case n.HardLineBreak():
			b.append("\n")
		case n.SoftLineBreak():
			b.append(" ")
		}
	case *gast.String:
		b.append(string(n.Value))
	case *gast.CodeSpan:
		for c := n.FirstChild(); c != nil; c = c.NextSibling() {
			if t, ok := c.(*gast.Text); ok {
				value := string(t.Segment.Value(b.src))
				if strings.HasSuffix(value, "\n") {
					value = strings.TrimSuffix(value, "\n") + " "
				}
				b.append(value)
			}
		}
	case *gast.AutoLink:
		b.append(string(n.Label(b.src)))
	case *gast.RawHTML:
		for i := 0; i < n.Segments.Len(); i++ {
			segment := n.Segments.At(i)
			b.append(string(segment.Value(b.src)))
		}
	case *east.TaskCheckBox:
		// The item's marker.
	default:
		// Emphasis, strong, strikethrough, a link or an image: its text.
		b.inlines(n)
	}
}

// decodeText resolves backslash escapes and character references as
// goldmark's HTML writer does, then undoes the writer's HTML escaping.
func decodeText(value []byte) string {
	var out bytes.Buffer
	w := bufio.NewWriter(&out)
	ghtml.DefaultWriter.Write(w, value)
	_ = w.Flush()
	return html.UnescapeString(out.String())
}

// MARK: - Re-locating a quote

// locateQuote is OwnerAskReviewText.range(ofQuote:in:): the quote as
// written, else as the markdown renders it (a raw-markdown quote with `code`
// or **bold**), the first exact hit; failing both, a whitespace-collapsed
// match that is the only one (CommentAnchor.locate with no stored context).
// Byte offsets into rendered.
func locateQuote(rendered, quote string) (start, end int, ok bool) {
	written := strings.TrimSpace(quote)
	if written == "" {
		return 0, 0, false
	}
	needles := []string{written}
	if r := strings.TrimSpace(renderPlain(written)); r != "" && r != written {
		needles = append(needles, r)
	}
	for _, needle := range needles {
		if i := strings.Index(rendered, needle); i >= 0 {
			return i, i + len(needle), true
		}
	}
	for _, needle := range needles {
		if s, e, ok := collapsedMatch(rendered, needle); ok {
			return s, e, true
		}
	}
	return 0, 0, false
}

// collapsedMatch finds needle with every whitespace run of both read as one
// space; one hit only (several with no context to rank them are no match).
func collapsedMatch(text, needle string) (start, end int, ok bool) {
	want := strings.TrimSpace(collapseSpaces(needle))
	if want == "" {
		return 0, 0, false
	}
	var collapsed strings.Builder
	// origins maps the collapsed byte where a grapheme starts to its
	// original byte range (a collapsed run: its first whitespace grapheme).
	type span struct{ from, to int }
	origins := map[int]span{}
	lastSpace := false
	g := uniseg.NewGraphemes(text)
	for g.Next() {
		from, to := g.Positions()
		space := isSpaceCluster(g.Str())
		if space && lastSpace {
			continue
		}
		origins[collapsed.Len()] = span{from, to}
		if space {
			collapsed.WriteByte(' ')
		} else {
			collapsed.WriteString(g.Str())
		}
		lastSpace = space
	}
	c := collapsed.String()
	first := strings.Index(c, want)
	if first < 0 || strings.Contains(c[first+1:], want) {
		return 0, 0, false
	}
	// The needle is trimmed: its last byte is in a non-space grapheme.
	last := first + len(want) - 1
	for ; last > first; last-- {
		if _, ok := origins[last]; ok {
			break
		}
	}
	return origins[first].from, origins[last].to, true
}

func collapseSpaces(s string) string {
	var out strings.Builder
	lastSpace := false
	g := uniseg.NewGraphemes(s)
	for g.Next() {
		if isSpaceCluster(g.Str()) {
			if !lastSpace {
				out.WriteByte(' ')
			}
			lastSpace = true
			continue
		}
		out.WriteString(g.Str())
		lastSpace = false
	}
	return out.String()
}

// isSpaceCluster is Character.isWhitespace: the cluster's first scalar.
func isSpaceCluster(cluster string) bool {
	r, _ := utf8.DecodeRuneInString(cluster)
	return unicode.IsSpace(r)
}

// anchorContext is CommentAnchor.make's context: up to anchorContextLength
// characters before start and after end.
func anchorContext(text string, start, end int) (prefix, suffix string) {
	var bounds []int // grapheme starts, then len(text)
	g := uniseg.NewGraphemes(text)
	for g.Next() {
		from, _ := g.Positions()
		bounds = append(bounds, from)
	}
	bounds = append(bounds, len(text))
	i := 0 // the last boundary at or before start
	for i+1 < len(bounds) && bounds[i+1] <= start {
		i++
	}
	j := len(bounds) - 1 // the first boundary at or after end
	for j > 0 && bounds[j-1] >= end {
		j--
	}
	from := bounds[max(0, i-anchorContextLength)]
	to := bounds[min(len(bounds)-1, j+anchorContextLength)]
	return text[from:start], text[end:to]
}

// relocate is the context Core's SpecReviewAnswer gives a quote it finds in
// the rendered snapshot; ok is false when the quote is not found there.
func relocate(rendered, quote string) (prefix, suffix string, ok bool) {
	start, end, found := locateQuote(rendered, quote)
	if !found {
		return "", "", false
	}
	prefix, suffix = anchorContext(rendered, start, end)
	return prefix, suffix, true
}

// placeComment is SpecReviewAnswer.comment: the quote as found in the
// rendered snapshot, with its context and the rendered heading nearest
// before it (none: the reviewer's heading without its hashes). A quote not
// found keeps the reviewer's heading and quote with no context.
func placeComment(heading, quote, body string, doc *plainDoc) asks.Comment {
	start, end, ok := locateQuote(doc.text, quote)
	if !ok {
		return asks.Comment{Heading: heading, Quote: quote, Body: body}
	}
	prefix, suffix := anchorContext(doc.text, start, end)
	found := ""
	for _, h := range doc.headings {
		if h.offset <= start {
			found = h.title
		}
	}
	if found == "" {
		found = plainTitle(heading)
	}
	return asks.Comment{Heading: found, Quote: doc.text[start:end], Prefix: prefix, Suffix: suffix, Body: body}
}
