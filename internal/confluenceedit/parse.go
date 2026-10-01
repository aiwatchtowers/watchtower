package confluenceedit

import (
	"strings"

	"golang.org/x/net/html"

	"watchtower/internal/confluence"
)

type nodeType int

const (
	nodeElement nodeType = iota
	nodeText             // character data, entities decoded
	nodeCDATA            // a <![CDATA[...]]> section; text is its body
	nodeOther            // a comment, doctype, stray end tag or dangling tail
)

// node is one element or leaf of the source, with byte offsets into it.
// For an element, [start,innerStart) is its start tag, [innerStart,innerEnd)
// its content and [innerEnd,end) its end tag (empty when the element was
// closed implicitly, by an ancestor's end tag or by the end of input).
type node struct {
	typ         nodeType
	name        string // lowercased tag name (elements only)
	attrs       []html.Attribute
	text        string // nodeText / nodeCDATA content
	selfClosing bool   // written as <x/>: no content span to rewrite
	start       int
	innerStart  int
	innerEnd    int
	end         int
	children    []*node
}

// attr returns the value of attribute key, or "" when absent.
func (n *node) attr(key string) string {
	for _, a := range n.attrs {
		if a.Key == key {
			return a.Val
		}
	}
	return ""
}

func (n *node) isElement(name string) bool {
	return n.typ == nodeElement && n.name == name
}

// firstChild returns n's first direct child element called name, or nil.
func (n *node) firstChild(name string) *node {
	for _, ch := range n.children {
		if ch.isElement(name) {
			return ch
		}
	}
	return nil
}

// voidElements are HTML elements that never have content even when written
// without a trailing "/" (<br>, <col ...>).
var voidElements = map[string]bool{
	"area": true, "base": true, "br": true, "col": true, "embed": true,
	"hr": true, "img": true, "input": true, "link": true, "meta": true,
	"param": true, "source": true, "track": true, "wbr": true,
}

// treeBuilder turns the token stream into a tree with XML semantics.
//
// Storage format is XHTML, so the tree is built the XML way rather than by
// the HTML5 tree-construction algorithm internal/confluence uses: every
// "<x/>" is an empty element (the rule confluence.normalizeSelfClosing
// exists to force onto the HTML5 builder for ac:*/ri:*/time — here it holds
// for every tag by construction, since no HTML5 builder ever runs), an end
// tag closes the nearest open element of the same name, and nothing is
// re-parented. CDATA sections are split out first with the one shared
// confluence.SplitCDATA rule and never reach the HTML5 tokenizer, which
// would misread a '>' inside one as the end of a bogus comment.
//
// Offsets come from the tokenizer's Raw bytes, which partition its input
// with no gap or overlap, so every node's span is an exact slice of the
// source.
type treeBuilder struct {
	root  *node
	stack []*node
	err   error
}

// parseTree builds the tree for src. The only error is ErrTooDeep.
func parseTree(src string) (*node, error) {
	root := &node{typ: nodeElement, innerEnd: len(src), end: len(src)}
	tb := &treeBuilder{root: root, stack: []*node{root}}
	off := 0
	confluence.SplitCDATA(src, func(raw, body string, isCDATA bool) {
		if isCDATA {
			tb.leaf(&node{typ: nodeCDATA, text: body, start: off, end: off + len(raw)})
		} else {
			tb.tokenize(raw, off)
		}
		off += len(raw)
	})
	for _, n := range tb.stack[1:] {
		n.innerEnd, n.end = len(src), len(src)
	}
	return root, tb.err
}

// tokenize feeds one CDATA-free segment of the source, starting at byte
// base, through the tokenizer.
func (tb *treeBuilder) tokenize(seg string, base int) {
	z := html.NewTokenizer(strings.NewReader(seg))
	pos := 0
	for z.Next() != html.ErrorToken {
		n := len(z.Raw())
		tb.token(z.Token(), base+pos, base+pos+n)
		pos += n
	}
	if pos < len(seg) {
		// The tokenizer drops an incomplete trailing token (e.g. "<p" at
		// end of input); keep its bytes as an inert leaf.
		tb.leaf(&node{typ: nodeOther, start: base + pos, end: base + len(seg)})
	}
}

func (tb *treeBuilder) token(tok html.Token, start, end int) {
	switch tok.Type {
	case html.StartTagToken:
		if voidElements[tok.Data] {
			tb.leaf(&node{typ: nodeElement, name: tok.Data, attrs: tok.Attr, start: start, end: end})
			return
		}
		tb.open(&node{typ: nodeElement, name: tok.Data, attrs: tok.Attr, start: start, innerStart: end})
	case html.SelfClosingTagToken:
		tb.leaf(&node{typ: nodeElement, name: tok.Data, attrs: tok.Attr, selfClosing: true, start: start, end: end})
	case html.EndTagToken:
		tb.close(tok.Data, start, end)
	case html.TextToken:
		tb.leaf(&node{typ: nodeText, text: tok.Data, start: start, end: end})
	default:
		tb.leaf(&node{typ: nodeOther, start: start, end: end})
	}
}

// leaf appends a content-less node to the innermost open element.
func (tb *treeBuilder) leaf(n *node) {
	n.innerStart, n.innerEnd = n.end, n.end
	top := tb.stack[len(tb.stack)-1]
	top.children = append(top.children, n)
}

func (tb *treeBuilder) open(n *node) {
	if len(tb.stack)-1 >= maxDepth {
		tb.err = ErrTooDeep
	}
	top := tb.stack[len(tb.stack)-1]
	top.children = append(top.children, n)
	tb.stack = append(tb.stack, n)
}

// close ends the nearest open element called name at the end tag spanning
// [start,end); elements opened inside it and still open end implicitly
// where the end tag starts. An end tag with no open match is kept as an
// inert leaf.
func (tb *treeBuilder) close(name string, start, end int) {
	for i := len(tb.stack) - 1; i >= 1; i-- {
		if tb.stack[i].name != name {
			continue
		}
		for _, inner := range tb.stack[i+1:] {
			inner.innerEnd, inner.end = start, start
		}
		tb.stack[i].innerEnd, tb.stack[i].end = start, end
		tb.stack = tb.stack[:i]
		return
	}
	tb.leaf(&node{typ: nodeOther, start: start, end: end})
}
