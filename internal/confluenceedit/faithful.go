package confluenceedit

// unfaithful names what re-rendering the original block o (source src)
// from markdown would lose, or returns "" when markdown carries it
// faithfully (ruling R11): attributes on a paragraph, heading, list or
// table element; a table's column widths; a noformat block; code-macro
// parameters other than the language; a list item holding several
// paragraphs.
func unfaithful(src string, o *block) string {
	root, err := parseTree(src)
	if err != nil {
		return "nesting too deep"
	}
	el := firstElement(root)
	if el == nil {
		return ""
	}
	switch o.kind {
	case blockParagraph, blockHeading:
		if (el.name == "p" || headingLevel(el.name) > 0) && len(el.attrs) > 0 {
			return "attributes such as alignment or style"
		}
	case blockList:
		return listUnfaithful(el, o)
	case blockTable:
		return tableUnfaithful(el)
	case blockCode:
		return codeUnfaithful(el)
	case blockMarker:
	}
	return ""
}

// firstElement is n's first child element, or nil (a block that is a bare
// inline run has none of its own).
func firstElement(n *node) *node {
	for _, ch := range n.children {
		if ch.typ == nodeElement {
			return ch
		}
	}
	return nil
}

func listUnfaithful(el *node, o *block) string {
	for _, it := range o.items {
		if len(it.paras) > 1 {
			return "a list item with several paragraphs"
		}
	}
	if hasAttrs(el, func(n *node) bool { return n.name == "ol" && onlyStart(n) }) {
		return "list attributes"
	}
	return ""
}

func onlyStart(n *node) bool {
	for _, at := range n.attrs {
		if at.Key != "start" {
			return false
		}
	}
	return true
}

func tableUnfaithful(el *node) string {
	if firstDescendant(el, "colgroup") {
		return "column widths"
	}
	if hasAttrs(el, func(*node) bool { return false }) {
		return "table layout or cell attributes"
	}
	return ""
}

func codeUnfaithful(el *node) string {
	if el.attr("ac:name") != "code" {
		return "a " + el.attr("ac:name") + " block"
	}
	for _, ch := range el.children {
		if ch.isElement("ac:parameter") && ch.attr("ac:name") != "language" {
			return "code block parameters such as a title or line numbers"
		}
	}
	return ""
}

// structural are the list and table elements whose attributes a markdown
// list or pipe table cannot carry.
var structural = map[string]bool{
	"ul": true, "ol": true, "li": true, "p": true, "table": true, "thead": true,
	"tbody": true, "tfoot": true, "tr": true, "th": true, "td": true,
}

// hasAttrs reports a structural element (el itself, then down through
// structural children) carrying attributes, unless exempt says its
// attributes are carried anyway. Inline content — markers included — is
// the units' business (kept byte for byte, or checked by the skeleton
// guard), not the block's.
func hasAttrs(el *node, exempt func(*node) bool) bool {
	if el.typ != nodeElement || !structural[el.name] {
		return false
	}
	if len(el.attrs) > 0 && !exempt(el) {
		return true
	}
	for _, ch := range el.children {
		if hasAttrs(ch, exempt) {
			return true
		}
	}
	return false
}

func firstDescendant(el *node, name string) bool {
	for _, ch := range el.children {
		if ch.isElement(name) || ch.typ == nodeElement && firstDescendant(ch, name) {
			return true
		}
	}
	return false
}
