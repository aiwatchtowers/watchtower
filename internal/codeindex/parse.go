//go:build cgo

package codeindex

import (
	"embed"
	"fmt"
	"slices"
	"strings"
	"sync"

	"watchtower/internal/codeindex/ts"
)

//go:embed queries/*.scm
var queryFS embed.FS

// compiled caches each language's grammar and query for the process:
// compiled lazily, on the first file of the language (the 90–257 ms the
// spike measured), and never closed.
var compiled sync.Map // language id → func() (*ts.Grammar, error)

func grammarFor(id string) (*ts.Grammar, error) {
	get, _ := compiled.LoadOrStore(id, sync.OnceValues(func() (*ts.Grammar, error) {
		query, err := queryFS.ReadFile("queries/" + id + ".scm")
		if err != nil {
			return nil, fmt.Errorf("reading the %s query: %w", id, err)
		}
		g, err := ts.NewGrammar(grammars[id](), string(query))
		if err != nil {
			return nil, fmt.Errorf("the %s query: %w", id, err)
		}
		return g, nil
	}))
	return get.(func() (*ts.Grammar, error))()
}

type tsParser struct{ p *ts.Parser }

func newParser() parser { return &tsParser{p: ts.NewParser()} }

func (t *tsParser) close() { t.p.Close() }

func (t *tsParser) parse(l *langSpec, src []byte) ([]Symbol, bool, error) {
	if grammars[l.id] == nil {
		return nil, false, nil
	}
	g, err := grammarFor(l.id)
	if err != nil {
		return nil, false, err
	}
	var spans []span
	seen := map[uint]bool{}
	_, err = t.p.Each(g, src, func(_ *ts.Node, caps []ts.Capture) {
		var name, def *ts.Node
		var kind Kind
		for i := range caps {
			c := &caps[i]
			switch {
			case c.Name == "name":
				name = &c.Node
			case strings.HasPrefix(c.Name, "definition."):
				def = &c.Node
				kind = Kind(strings.TrimPrefix(c.Name, "definition."))
			}
		}
		if name == nil || def == nil || seen[name.StartByte()] {
			return
		}
		seen[name.StartByte()] = true
		if s, ok := symbolAt(l, src, name, def, kind); ok {
			spans = append(spans, s)
		}
	})
	if err != nil {
		return nil, false, err
	}
	return assignContainers(spans), true, nil
}

// symbolAt builds the symbol a match names; ok=false drops it.
func symbolAt(l *langSpec, src []byte, name, def *ts.Node, kind Kind) (span, bool) {
	kind, container := refine(l.id, src, def, kind)
	if !kinds[kind] {
		return span{}, false
	}
	outer := wrapperOf(l, def)
	doc := docComment(l, src, outer)
	if doc == "" && l.docstring {
		doc = docstring(src, def)
	}
	return span{
		start: def.StartByte(),
		end:   def.EndByte(),
		sym: Symbol{
			Name:      name.Utf8Text(src),
			Kind:      kind,
			Line:      int(name.StartPosition().Row) + 1,
			Col:       utf16Col(src, int(name.StartByte())),
			EndLine:   int(def.EndPosition().Row) + 1,
			Container: container,
			Signature: signature(l, src, outer, def),
			Doc:       doc,
		},
	}, true
}

// refine settles what a capture alone cannot: a Swift class_declaration's
// kind is its declaration_kind; a Go type is a struct or an interface by
// its type, and a Go method's container is its receiver's type.
func refine(lang string, src []byte, def *ts.Node, kind Kind) (Kind, string) {
	switch lang {
	case "swift":
		if def.Kind() != "class_declaration" {
			return kind, ""
		}
		dk := def.ChildByFieldName("declaration_kind")
		if dk == nil {
			return kind, ""
		}
		switch dk.Utf8Text(src) {
		case "struct":
			return KindStruct, ""
		case "enum":
			return KindEnum, ""
		case "extension":
			return KindType, ""
		}
		return KindClass, "" // class, actor
	case "go":
		switch def.Kind() {
		case "type_spec":
			switch t := def.ChildByFieldName("type"); {
			case t == nil:
			case t.Kind() == "struct_type":
				return KindStruct, ""
			case t.Kind() == "interface_type":
				return KindInterface, ""
			}
		case "method_declaration":
			return kind, goReceiverType(src, def)
		}
	}
	return kind, ""
}

// goReceiverType is the type name of a Go method's receiver: `(s *Store)`
// and `(p *Pair[K, V])` give Store and Pair.
func goReceiverType(src []byte, def *ts.Node) string {
	recv := def.ChildByFieldName("receiver")
	if recv == nil || recv.NamedChildCount() == 0 {
		return ""
	}
	t := recv.NamedChild(0).ChildByFieldName("type")
	for t != nil {
		switch t.Kind() {
		case "type_identifier":
			return t.Utf8Text(src)
		case "pointer_type", "parenthesized_type":
			t = t.NamedChild(0)
		case "generic_type":
			t = t.ChildByFieldName("type")
		default:
			return ""
		}
	}
	return ""
}

// wrapperOf climbs from def through the language's wrapper parents that
// hold nothing but def (`type X struct`, decorators — not a `type (…)`
// group, even of one), returning the outermost.
func wrapperOf(l *langSpec, def *ts.Node) *ts.Node {
	cur := def
	for {
		par := cur.Parent()
		if par == nil || !slices.Contains(l.wrappers, par.Kind()) {
			return cur
		}
		for i := range par.ChildCount() {
			c := par.Child(i)
			if c == nil {
				continue
			}
			if c.Kind() == "(" || (c.IsNamed() && c.Kind() == cur.Kind() && c.StartByte() != cur.StartByte()) {
				return cur
			}
		}
		cur = par
	}
}

// signature is the definition's source from its outer start to its body,
// whitespace collapsed; with no body found, its first line. A trailing
// `{` or `:` (the body opener) is dropped.
func signature(l *langSpec, src []byte, outer, def *ts.Node) string {
	end := def.EndByte()
	if body := bodyOf(l, def); body != nil {
		end = body.StartByte()
	} else if nl := strings.IndexByte(string(src[outer.StartByte():end]), '\n'); nl >= 0 {
		end = outer.StartByte() + uint(nl)
	}
	s := strings.TrimSpace(string(src[outer.StartByte():end]))
	s = strings.TrimSpace(strings.TrimRight(s, "{:"))
	return clip(s)
}

// bodyOf finds def's body: a child or grandchild of one of the language's
// body kinds, children first.
func bodyOf(l *langSpec, def *ts.Node) *ts.Node {
	var next []*ts.Node
	for i := range def.NamedChildCount() {
		c := def.NamedChild(i)
		if c == nil {
			continue
		}
		if slices.Contains(l.bodies, c.Kind()) {
			return c
		}
		next = append(next, c)
	}
	for _, c := range next {
		for i := range c.NamedChildCount() {
			if g := c.NamedChild(i); g != nil && slices.Contains(l.bodies, g.Kind()) {
				return g
			}
		}
	}
	return nil
}

// docComment is the first sentence of the doc comments directly above
// outer (no blank line between), accepted only with one of the language's
// doc prefixes; directives in the run are skipped, any other comment ends
// it.
func docComment(l *langSpec, src []byte, outer *ts.Node) string {
	if len(l.docPrefixes) == 0 {
		return ""
	}
	var parts []string
	nextRow := outer.StartPosition().Row
	for p := outer.PrevSibling(); p != nil && strings.Contains(p.Kind(), "comment"); p = p.PrevSibling() {
		if p.EndPosition().Row+1 < nextRow {
			break
		}
		nextRow = p.StartPosition().Row
		text := p.Utf8Text(src)
		if l.directive != nil && l.directive.MatchString(text) {
			continue
		}
		if !hasDocPrefix(l, text) {
			break
		}
		parts = append(parts, commentText(text))
	}
	slices.Reverse(parts)
	return firstSentence(strings.Join(parts, " "))
}

func hasDocPrefix(l *langSpec, text string) bool {
	for _, p := range l.docPrefixes {
		if strings.HasPrefix(text, p) {
			return true
		}
	}
	return false
}

// docstring is the first sentence of a Python definition's docstring: a
// string that is the first statement of its body.
func docstring(src []byte, def *ts.Node) string {
	body := def.ChildByFieldName("body")
	if body == nil || body.NamedChildCount() == 0 {
		return ""
	}
	first := body.NamedChild(0)
	if first == nil || first.Kind() != "expression_statement" || first.NamedChildCount() != 1 {
		return ""
	}
	str := first.NamedChild(0)
	if str == nil || str.Kind() != "string" {
		return ""
	}
	return firstSentence(docstringText(str.Utf8Text(src)))
}
