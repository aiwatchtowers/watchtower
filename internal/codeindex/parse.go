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

// queryParts lists the query files a language's query is concatenated
// from, when it is not just queries/<id>.scm: TypeScript and TSX are the
// JavaScript query plus the TypeScript-only one, as upstream intends;
// JavaScript adds the node kinds only its grammar has; C++ is the C query
// plus the C++-only one (its grammar extends C's), Objective-C the C query
// plus its own.
var queryParts = map[string][]string{
	"javascript": {"javascript", "javascript_only"},
	"typescript": {"javascript", "typescript"},
	"tsx":        {"javascript", "typescript"},
	"cpp":        {"c", "cpp"},
	"objc":       {"c", "objc"},
}

func grammarFor(id string) (*ts.Grammar, error) {
	get, _ := compiled.LoadOrStore(id, sync.OnceValues(func() (*ts.Grammar, error) {
		parts := queryParts[id]
		if parts == nil {
			parts = []string{id}
		}
		var query []byte
		for _, part := range parts {
			q, err := queryFS.ReadFile("queries/" + part + ".scm")
			if err != nil {
				return nil, fmt.Errorf("reading the %s query: %w", id, err)
			}
			query = append(append(query, q...), '\n')
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
	cols := &columns{src: src}
	tree := src
	if l.mask != nil {
		tree = l.mask(src)
	}
	_, err = t.p.Each(g, tree, func(_ *ts.Node, caps []ts.Capture) {
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
		if s, ok := symbolAt(l, src, cols, name, def, kind); ok {
			spans = append(spans, s)
		}
	})
	if err != nil {
		return nil, false, err
	}
	return assignContainers(spans), true, nil
}

// symbolAt builds the symbol a match names; ok=false drops it (a kind
// outside the set, a local, or an empty name: a node the parser inserted
// to recover from an error).
func symbolAt(l *langSpec, src []byte, cols *columns, name, def *ts.Node, kind Kind) (span, bool) {
	var container string
	if r := refiners[l.id]; r != nil {
		kind, container = r(src, def, kind)
	}
	if !kinds[kind] || name.StartByte() == name.EndByte() || isLocal(l, def) {
		return span{}, false
	}
	outer := wrapperOf(l, def)
	last, endRow := defEnd(l, def, outer)
	return span{
		start: def.StartByte(),
		end:   last.EndByte(),
		sym: Symbol{
			Name:      symbolName(l, src, name, def),
			Kind:      kind,
			Line:      int(name.StartPosition().Row) + 1,
			Col:       cols.at(int(name.StartByte())),
			EndLine:   int(endRow) + 1,
			Container: container,
			Signature: signature(l, src, outer, def),
			Doc:       docOf(l, src, def, outer),
		},
	}, true
}

// defEnd is the last node of def's span — def, or the body that follows
// it as a sibling (Dart) — and the row it ends on: a node that takes its
// line's newline (a #define) ends on that line.
func defEnd(l *langSpec, def, outer *ts.Node) (*ts.Node, uint) {
	last := def
	if n := outer.NextSibling(); l.bodySibling != "" && n != nil && n.Kind() == l.bodySibling {
		last = n
	}
	end := last.EndPosition()
	if end.Column == 0 && end.Row > def.StartPosition().Row {
		return last, end.Row - 1
	}
	return last, end.Row
}

// docOf is the definition's doc: the comment above it, else a Python
// docstring, else the language's own doc reader (Elixir's @doc).
func docOf(l *langSpec, src []byte, def, outer *ts.Node) string {
	doc := docComment(l, src, outer)
	if doc == "" && l.docstring {
		doc = docstring(src, def)
	}
	if d := docFuncs[l.id]; doc == "" && d != nil {
		doc = d(src, outer)
	}
	return doc
}

// refiners settle, per language, what a capture alone cannot: a kind the
// node's contents decide, or a container the enclosing definitions do not
// give (a Go receiver, a Rust impl's type).
var refiners = map[string]func(src []byte, def *ts.Node, kind Kind) (Kind, string){
	"swift": refineSwift,
	"go":    refineGo,
	"rust":  refineRust,
	"c":     refineC,
	"cpp":   refineC,
	"lua":   refineLua,
	"java":  refineJava,

	"c_sharp": refineCSharp,
	"ocaml":   refineOCaml,
	"r":       refineR,

	"javascript": refineJS,
	"typescript": refineJS,
	"tsx":        refineJS,

	"kotlin": refineKotlin,
	"bash":   refineBash,
	"groovy": refineGroovy,
	"objc":   refineObjC,
	"zig":    refineZig,

	"haskell": refineHaskell,
	"erlang":  refineErlang,
	"perl":    refinePerl,
	"nim":     refineNim,
}

// nameFuncs build, per language, a name that is not one node's text (an
// HCL block's two labels).
var nameFuncs = map[string]func(src []byte, name, def *ts.Node) string{
	"hcl":  hclName,
	"objc": objcName,
}

func symbolName(l *langSpec, src []byte, name, def *ts.Node) string {
	if f := nameFuncs[l.id]; f != nil {
		return f(src, name, def)
	}
	return name.Utf8Text(src)
}

// docFuncs read a doc that is not a comment above the definition, tried
// when the comment rule found none (Elixir's @doc attribute).
var docFuncs = map[string]func(src []byte, outer *ts.Node) string{
	"elixir":  elixirDoc,
	"kotlin":  kotlinDoc,
	"graphql": graphqlDoc,
	"groovy":  groovyDoc,
	"haskell": haskellDoc,
	"clojure": clojureDoc,
	"julia":   juliaDoc,
	"nim":     nimDoc,
}

// refineSwift: a class_declaration's kind is its declaration_kind.
func refineSwift(src []byte, def *ts.Node, kind Kind) (Kind, string) {
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
}

// refineGo: a type is a struct or an interface by its type, and a method's
// container is its receiver's type.
func refineGo(src []byte, def *ts.Node, kind Kind) (Kind, string) {
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

// isLocal reports a definition inside the body of one of the language's
// local scopes (a function): not indexed. A function's parameters are not
// in its body (PHP's promoted constructor properties stay).
func isLocal(l *langSpec, def *ts.Node) bool {
	if len(l.locals) == 0 {
		return false
	}
	for cur, p := def, def.Parent(); p != nil; cur, p = p, p.Parent() {
		if !slices.Contains(l.locals, p.Kind()) {
			continue
		}
		if b := p.ChildByFieldName("body"); b == nil || b.Id() == cur.Id() {
			return true // in the body, or the scope is all body (Dart's function_body)
		}
	}
	return false
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

// signature is the definition's source from its outer start (past any
// lead children) to its body (or to a comment of its own before that:
// Ruby's leading body comment), whitespace collapsed; with no body found,
// its first line. A trailing `{`, `:` or `=` (the body opener) is dropped.
func signature(l *langSpec, src []byte, outer, def *ts.Node) string {
	start := sigStart(l, outer)
	end := def.EndByte()
	if body := bodyOf(l, def); body != nil {
		end = body.StartByte()
	} else if nl := strings.IndexByte(window(src, int(start), int(end)), '\n'); nl >= 0 {
		end = start + uint(nl)
	}
	for i := range def.ChildCount() {
		if c := def.Child(i); c != nil && strings.Contains(c.Kind(), "comment") && c.StartByte() < end {
			end = c.StartByte()
			break
		}
	}
	s := strings.TrimSpace(window(src, int(start), int(end)))
	s = strings.TrimSpace(strings.TrimRight(s, "{:="))
	return clip(s)
}

// sigStart is where outer's signature starts: past its leading children
// of the language's lead kinds (a GraphQL description).
func sigStart(l *langSpec, outer *ts.Node) uint {
	start := outer.StartByte()
	for i := range outer.NamedChildCount() {
		c := outer.NamedChild(i)
		if c == nil || !slices.Contains(l.leads, c.Kind()) {
			break
		}
		if n := c.NextSibling(); n != nil {
			start = n.StartByte()
		}
	}
	return start
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
// doc prefixes; directives and the language's between kinds (attributes)
// in the run are skipped, any other comment ends it.
func docComment(l *langSpec, src []byte, outer *ts.Node) string {
	if len(l.docPrefixes) == 0 {
		return ""
	}
	var parts []string
	nextRow := outer.StartPosition().Row
	for p := docStart(l, outer); p != nil; p = p.PrevSibling() {
		between := slices.Contains(l.between, p.Kind())
		if !between && !isComment(p) || p.EndPosition().Row+1 < nextRow {
			break
		}
		nextRow = p.StartPosition().Row
		if between {
			continue
		}
		if q := p.PrevSibling(); q != nil && q.EndPosition().Row == nextRow && !isComment(q) {
			break // a trailing comment of the line above, not a doc for outer
		}
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
	doc := strings.Join(parts, " ")
	if l.docMarkup != nil {
		doc = l.docMarkup.ReplaceAllString(doc, " ")
	}
	return firstSentence(doc)
}

// docStart is the sibling a doc search starts from: the one before outer,
// or, for the first statement of a body, the one before the body (Ruby
// puts a body's leading comment there).
func docStart(l *langSpec, outer *ts.Node) *ts.Node {
	if p := outer.PrevSibling(); p != nil {
		return p
	}
	if par := outer.Parent(); par != nil && slices.Contains(l.bodies, par.Kind()) {
		return par.PrevSibling()
	}
	return nil
}

func isComment(n *ts.Node) bool { return strings.Contains(n.Kind(), "comment") }

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
