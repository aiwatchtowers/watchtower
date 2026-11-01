package handlers

import (
	"bufio"
	"bytes"
	"html"
	"slices"
	"strconv"
	"strings"
	"sync/atomic"
	"unicode"
	"unicode/utf8"

	"github.com/rivo/uniseg"
	"github.com/yuin/goldmark"
	gast "github.com/yuin/goldmark/ast"
	"github.com/yuin/goldmark/extension"
	east "github.com/yuin/goldmark/extension/ast"
	ghtml "github.com/yuin/goldmark/renderer/html"
	"github.com/yuin/goldmark/text"
	"golang.org/x/text/unicode/norm"

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
	index    *anchorIndex // anchors(), built on first use
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

// anchorIndex is a rendered text split once into grapheme clusters, with
// its NFC form and its whitespace-collapsed NFC form, so each quote of a
// snapshot costs a substring search and a walk of 64 clusters either side.
// Matching runs on NFC (Swift's String and NSString compare canonically
// equivalent text as equal); every offset handed back is in the original
// text, so prefix, suffix and quote are its own bytes, as Swift's are.
type anchorIndex struct {
	text string
	// starts[i] is cluster i's first byte in text; starts[len] = len(text).
	starts []int
	// nfc is the clusters' NFC forms joined; nfcStarts as starts.
	nfc       string
	nfcStarts []int
	// collapsed is nfc with every whitespace run one space; units[k] is the
	// cluster where its k-th unit (a cluster or a run) starts, unitStarts[k]
	// that unit's first byte in collapsed, then len(collapsed).
	collapsed  string
	units      []int
	unitStarts []int
}

// anchorIndexBuilds counts index builds (a test bounds them per snapshot).
var anchorIndexBuilds atomic.Int64

func newAnchorIndex(text string) *anchorIndex {
	anchorIndexBuilds.Add(1)
	ix := &anchorIndex{text: text}
	var nfc, collapsed strings.Builder
	lastSpace := false
	g := uniseg.NewGraphemes(text)
	for g.Next() {
		from, _ := g.Positions()
		cluster := norm.NFC.String(g.Str())
		ix.starts = append(ix.starts, from)
		ix.nfcStarts = append(ix.nfcStarts, nfc.Len())
		nfc.WriteString(cluster)
		space := isSpaceCluster(cluster)
		if space && lastSpace {
			continue
		}
		ix.units = append(ix.units, len(ix.starts)-1)
		ix.unitStarts = append(ix.unitStarts, collapsed.Len())
		if space {
			collapsed.WriteByte(' ')
		} else {
			collapsed.WriteString(cluster)
		}
		lastSpace = space
	}
	ix.starts = append(ix.starts, len(text))
	ix.nfcStarts = append(ix.nfcStarts, nfc.Len())
	ix.unitStarts = append(ix.unitStarts, collapsed.Len())
	ix.nfc, ix.collapsed = nfc.String(), collapsed.String()
	return ix
}

// anchors is the doc's index, built on first use.
func (d *plainDoc) anchors() *anchorIndex {
	if d.index == nil {
		d.index = newAnchorIndex(d.text)
	}
	return d.index
}

// boundary is the position of offset in bounds (sorted), or -1 when offset
// falls inside an element (a hit starting or ending inside a cluster).
func boundary(bounds []int, offset int) int {
	i, found := slices.BinarySearch(bounds, offset)
	if !found {
		return -1
	}
	return i
}

// exact is the first hit of needle (NFC) that starts and ends on cluster
// boundaries, as cluster indices [first, end).
func (ix *anchorIndex) exact(needle string) (first, end int, ok bool) {
	for from := 0; ; {
		i := strings.Index(ix.nfc[from:], needle)
		if i < 0 {
			return 0, 0, false
		}
		at := from + i
		if s, e := boundary(ix.nfcStarts, at), boundary(ix.nfcStarts, at+len(needle)); s >= 0 && e >= 0 {
			return s, e, true
		}
		from = at + 1
	}
}

// collapsedOnly is CommentAnchor.locate's whitespace-collapsed tier with no
// stored context: exactly one boundary-aligned hit, else no match.
func (ix *anchorIndex) collapsedOnly(needle string) (first, end int, ok bool) {
	want := strings.TrimSpace(collapseSpaces(norm.NFC.String(needle)))
	if want == "" {
		return 0, 0, false
	}
	hits := 0
	for from := 0; ; {
		i := strings.Index(ix.collapsed[from:], want)
		if i < 0 {
			break
		}
		at := from + i
		s, e := boundary(ix.unitStarts, at), boundary(ix.unitStarts, at+len(want))
		if s >= 0 && e >= 0 {
			hits++
			if hits > 1 {
				return 0, 0, false
			}
			// The needle is trimmed: its last unit is one cluster.
			first, end = ix.units[s], ix.units[e-1]+1
		}
		from = at + 1
	}
	return first, end, hits == 1
}

// locate is OwnerAskReviewText.range(ofQuote:in:): the quote as written,
// else as the markdown renders it (a raw-markdown quote with `code` or
// **bold**), the first hit; failing both, a whitespace-collapsed match that
// is the only one. Cluster indices [first, end).
//
// CommentAnchor.locate's legacy tier (old "———" and " | " separators) is
// left out on purpose: with no stored context it always scores 0, so it
// never finds anything here.
func (ix *anchorIndex) locate(quote string) (first, end int, ok bool) {
	written := strings.TrimSpace(quote)
	if written == "" {
		return 0, 0, false
	}
	needles := []string{written}
	if r := strings.TrimSpace(renderPlain(written)); r != "" && r != written {
		needles = append(needles, r)
	}
	for _, needle := range needles {
		if f, e, ok := ix.exact(norm.NFC.String(needle)); ok {
			return f, e, true
		}
	}
	for _, needle := range needles {
		if f, e, ok := ix.collapsedOnly(needle); ok {
			return f, e, true
		}
	}
	return 0, 0, false
}

// relocate finds quote and returns its byte range in the text with
// CommentAnchor.make's context: up to anchorContextLength characters
// before and after.
func (ix *anchorIndex) relocate(quote string) (start, end int, prefix, suffix string, ok bool) {
	f, e, found := ix.locate(quote)
	if !found {
		return 0, 0, "", "", false
	}
	clusters := len(ix.starts) - 1
	start, end = ix.starts[f], ix.starts[e]
	prefix = ix.text[ix.starts[max(0, f-anchorContextLength)]:start]
	suffix = ix.text[end:ix.starts[min(clusters, e+anchorContextLength)]]
	return start, end, prefix, suffix, true
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

// relocate is the context Core's SpecReviewAnswer gives a quote it finds in
// the rendered snapshot; ok is false when the quote is not found there.
func relocate(rendered, quote string) (prefix, suffix string, ok bool) {
	_, _, prefix, suffix, ok = newAnchorIndex(rendered).relocate(quote)
	return prefix, suffix, ok
}

// placeComment is SpecReviewAnswer.comment: the quote as found in the
// rendered snapshot, with its context and the rendered heading nearest
// before it (none: the reviewer's heading without its hashes). A quote not
// found keeps the reviewer's heading and quote with no context.
func placeComment(heading, quote, body string, doc *plainDoc) asks.Comment {
	start, end, prefix, suffix, ok := doc.anchors().relocate(quote)
	if !ok {
		return asks.Comment{Heading: heading, Quote: quote, Body: body}
	}
	// Swift's max(by:) keeps the first of equal offsets.
	found, best := "", -1
	for _, h := range doc.headings {
		if h.offset <= start && h.offset > best {
			found, best = h.title, h.offset
		}
	}
	if found == "" {
		found = plainTitle(heading)
	}
	return asks.Comment{Heading: found, Quote: doc.text[start:end], Prefix: prefix, Suffix: suffix, Body: body}
}
