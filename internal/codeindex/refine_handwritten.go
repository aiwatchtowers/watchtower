//go:build cgo

package codeindex

import (
	"slices"
	"strconv"
	"strings"

	"watchtower/internal/codeindex/ts"
)

// The refiners and doc readers of the languages whose queries Watchtower
// wrote from scratch (no upstream tags.scm).

// refineKotlin: a class declared `interface` is an interface and `enum
// class` an enum; an extension function is a method of its receiver
// type; a `const val`, and a top-level `val`, is a const.
func refineKotlin(src []byte, def *ts.Node, kind Kind) (Kind, string) {
	switch def.Kind() {
	case "class_declaration":
		return kotlinClassKind(def), ""
	case "function_declaration":
		if r := def.ChildByFieldName("receiver"); r != nil {
			return KindMethod, firstTypeIdentifier(src, r)
		}
	case "property_declaration":
		if kotlinHasModifier(src, def, "const") || (kind == KindVar && kotlinBinding(src, def) == "val") {
			return KindConst, ""
		}
	}
	return kind, ""
}

// kotlinClassKind reads the keyword a class_declaration is spelled with.
func kotlinClassKind(def *ts.Node) Kind {
	for i := range def.ChildCount() {
		c := def.Child(i)
		if c == nil || c.IsNamed() {
			continue
		}
		switch c.Kind() {
		case "interface":
			return KindInterface
		case "enum":
			return KindEnum
		}
	}
	return KindClass
}

// kotlinHasModifier reports a modifier (not an annotation) spelled word
// on def.
func kotlinHasModifier(src []byte, def *ts.Node, word string) bool {
	m := def.NamedChild(0)
	if m == nil || m.Kind() != "modifiers" {
		return false
	}
	for i := range m.NamedChildCount() {
		if c := m.NamedChild(i); c != nil && c.Utf8Text(src) == word {
			return true
		}
	}
	return false
}

// kotlinBinding is a property's `val` or `var`.
func kotlinBinding(src []byte, def *ts.Node) string {
	for i := range def.NamedChildCount() {
		if c := def.NamedChild(i); c != nil && c.Kind() == "binding_pattern_kind" {
			return c.Utf8Text(src)
		}
	}
	return ""
}

// firstTypeIdentifier is the first type_identifier down n's first named
// children: a receiver `List<T>` or `String?` gives List or String.
func firstTypeIdentifier(src []byte, n *ts.Node) string {
	for n != nil && n.Kind() != "type_identifier" {
		n = n.NamedChild(0)
	}
	if n == nil {
		return ""
	}
	return n.Utf8Text(src)
}

// kotlinDoc is the KDoc of the first declaration after the package header
// or the imports, which the grammar parks as their last child.
func kotlinDoc(src []byte, outer *ts.Node) string {
	p := outer.PrevSibling()
	for p != nil && (p.Kind() == "import_list" || p.Kind() == "import_header" || p.Kind() == "package_header") {
		p = lastChild(p)
	}
	if p == nil || !isComment(p) {
		return ""
	}
	return blockDocAbove(src, p, outer)
}

// lastChild is n's last child, nil with none.
func lastChild(n *ts.Node) *ts.Node {
	if n.ChildCount() == 0 {
		return nil
	}
	return n.Child(n.ChildCount() - 1)
}

// blockDocAbove is the first sentence of p, a `/**` block ending on the
// line above outer or on its line; "" for anything else.
func blockDocAbove(src []byte, p, outer *ts.Node) string {
	if p.EndPosition().Row+1 < outer.StartPosition().Row {
		return ""
	}
	if text := p.Utf8Text(src); strings.HasPrefix(text, "/**") {
		return firstSentence(commentText(text))
	}
	return ""
}

// refineBash: a `readonly` or `declare -r` variable is a const.
func refineBash(src []byte, def *ts.Node, kind Kind) (Kind, string) {
	if def.Kind() != "declaration_command" {
		return kind, ""
	}
	words := strings.Fields(strings.SplitN(def.Utf8Text(src), "=", 2)[0])
	if len(words) == 0 {
		return kind, ""
	}
	if words[0] == "readonly" {
		return KindConst, ""
	}
	for _, w := range words[1:] {
		if strings.HasPrefix(w, "-") && strings.Contains(w, "r") {
			return KindConst, ""
		}
	}
	return kind, ""
}

// hclName: a block with two labels (`resource "aws_x" "name"`) is named
// by both, joined with a dot.
func hclName(src []byte, name, def *ts.Node) string {
	if def.Kind() != "block" {
		return name.Utf8Text(src)
	}
	var labels []string
	for i := range def.NamedChildCount() {
		if c := def.NamedChild(i); c != nil && c.Kind() == "string_lit" {
			labels = append(labels, strings.Trim(c.Utf8Text(src), `"`))
		}
	}
	return strings.Join(labels, ".")
}

// graphqlDoc is a GraphQL definition's description: the string that
// opens it.
func graphqlDoc(src []byte, outer *ts.Node) string {
	if d := outer.NamedChild(0); d != nil && d.Kind() == "description" {
		return firstSentence(docstringText(d.Utf8Text(src)))
	}
	return ""
}

// refineGroovy: a class spelled `interface` or `trait` is an interface; a
// variable holding a closure is a function; a `static final` field and a
// `final` top-level variable are consts.
func refineGroovy(src []byte, def *ts.Node, kind Kind) (Kind, string) {
	switch def.Kind() {
	case "class_definition":
		return groovyClassKind(src, def), ""
	case "declaration":
		if v := def.ChildByFieldName("value"); v != nil && v.Kind() == "closure" {
			return KindFunction, ""
		}
		if groovyModifier(src, def, "final") && (kind == KindVar || groovyModifier(src, def, "static")) {
			return KindConst, ""
		}
	}
	return kind, ""
}

// groovyClassKind reads a class_definition's keyword from the file
// itself (the parsed copy spells a trait `class`).
func groovyClassKind(src []byte, def *ts.Node) Kind {
	for i := range def.ChildCount() {
		if c := def.Child(i); c != nil && !c.IsNamed() && (c.Kind() == "interface" || c.Utf8Text(src) == "trait") {
			return KindInterface
		}
	}
	return KindClass
}

// groovyModifier reports a modifier child of def spelled word.
func groovyModifier(src []byte, def *ts.Node, word string) bool {
	for i := range def.NamedChildCount() {
		if c := def.NamedChild(i); c != nil && c.Kind() == "modifier" && c.Utf8Text(src) == word {
			return true
		}
	}
	return false
}

// groovyDoc is the GroovyDoc block directly above a definition (the
// grammar gives it a kind of its own, not a comment).
func groovyDoc(src []byte, outer *ts.Node) string {
	if p := outer.PrevSibling(); p != nil && p.Kind() == "groovy_doc" {
		return blockDocAbove(src, p, outer)
	}
	return ""
}

// refineObjC: an @interface or @implementation of a category is a type
// (the container of what it adds); the rest is C's.
func refineObjC(src []byte, def *ts.Node, kind Kind) (Kind, string) {
	switch def.Kind() {
	case "class_interface", "class_implementation":
		if def.ChildByFieldName("category") != nil {
			return KindType, ""
		}
		return kind, ""
	}
	return refineC(src, def, kind)
}

// objcName: a method is named by its selector, each keyword with its
// colon (`addValue:forKey:`).
func objcName(src []byte, name, def *ts.Node) string {
	if def.Kind() != "method_declaration" && def.Kind() != "method_definition" {
		return name.Utf8Text(src)
	}
	var sel strings.Builder
	for i := range def.NamedChildCount() {
		switch c := def.NamedChild(i); c.Kind() {
		case "identifier":
			sel.WriteString(c.Utf8Text(src))
		case "method_parameter":
			sel.WriteByte(':')
		}
	}
	return sel.String()
}

// zigContainers are the node kinds of a Zig container's body.
var zigContainers = []string{"struct_declaration", "enum_declaration", "union_declaration", "opaque_declaration"}

// refineZig: a declaration is the kind of the container it holds, an
// @import alias is dropped, and other declarations are consts or vars by
// their keyword; a fn in a container is a method; an enum's fields are
// consts.
func refineZig(src []byte, def *ts.Node, kind Kind) (Kind, string) {
	switch def.Kind() {
	case "variable_declaration":
		return zigDeclKind(src, def), ""
	case "function_declaration":
		if p := def.Parent(); p != nil && slices.Contains(zigContainers, p.Kind()) {
			return KindMethod, ""
		}
	case "container_field":
		if p := def.Parent(); p != nil && p.Kind() == "enum_declaration" {
			return KindConst, ""
		}
	}
	return kind, ""
}

// zigDeclKind is a const/var declaration's kind, by its value or keyword;
// "" (dropped) for an @import.
func zigDeclKind(src []byte, def *ts.Node) Kind {
	for i := range def.NamedChildCount() {
		switch c := def.NamedChild(i); c.Kind() {
		case "struct_declaration", "union_declaration", "opaque_declaration":
			return KindStruct
		case "enum_declaration", "error_set_declaration":
			return KindEnum
		case "builtin_function":
			if f := c.NamedChild(0); f != nil && f.Utf8Text(src) == "@import" {
				return ""
			}
		}
	}
	for i := range def.ChildCount() {
		if c := def.Child(i); c != nil && !c.IsNamed() && c.Kind() == "const" {
			return KindConst
		}
	}
	return KindVar
}

// refineHaskell: a data type with several constructors is an enum, and
// the lone constructor of one with a single constructor is dropped; a
// later equation of a function is dropped; a binding whose signature is a
// function type is a function.
func refineHaskell(src []byte, def *ts.Node, kind Kind) (Kind, string) {
	switch def.Kind() {
	case "data_type":
		if cs := def.ChildByFieldName("constructors"); cs != nil && cs.NamedChildCount() > 1 {
			return KindEnum, ""
		}
	case "data_constructor":
		if p := def.Parent(); p != nil && p.NamedChildCount() == 1 {
			return "", ""
		}
	case "function", "bind":
		return haskellEquationKind(src, def, kind), ""
	}
	return kind, ""
}

// haskellEquationKind: "" for a later equation of the function above; a
// function for a binding whose signature has a function type.
func haskellEquationKind(src []byte, def *ts.Node, kind Kind) Kind {
	name := fieldText(src, def, "name")
	p := def.PrevNamedSibling()
	for p != nil && (p.Kind() == "haddock" || isComment(p) || p.Kind() == "pragma") {
		p = p.PrevNamedSibling()
	}
	if p == nil || fieldText(src, p, "name") != name {
		return kind
	}
	if p.Kind() != "signature" {
		return "" // a later equation
	}
	t := p.ChildByFieldName("type")
	if t != nil && t.Kind() == "context" {
		t = t.ChildByFieldName("type")
	}
	if t != nil && t.Kind() == "function" {
		return KindFunction
	}
	return kind
}

// fieldText is the text of n's field child, "" with none.
func fieldText(src []byte, n *ts.Node, field string) string {
	if c := n.ChildByFieldName(field); c != nil {
		return c.Utf8Text(src)
	}
	return ""
}

// haskellDoc is the Haddock comment above a definition or above its own
// type signature. The grammar parks the comment above a body's first
// declaration outside the body: at the end of the imports, or before a
// class's declarations.
func haskellDoc(src []byte, outer *ts.Node) string {
	name := fieldText(src, outer, "name")
	next, p := outer, haskellPrev(outer)
	for p != nil && (p.Kind() == "imports" || p.Kind() == "pragma" || (p.Kind() == "signature" && fieldText(src, p, "name") == name)) {
		if p.Kind() == "imports" {
			p = lastChild(p)
			continue
		}
		next, p = p, haskellPrev(p)
	}
	if p == nil || p.Kind() != "haddock" || p.EndPosition().Row+1 < next.StartPosition().Row {
		return ""
	}
	return firstSentence(haddockText(p.Utf8Text(src)))
}

// haskellPrev is n's previous sibling, or, for the first declaration of a
// declarations list, the list's.
func haskellPrev(n *ts.Node) *ts.Node {
	if p := n.PrevSibling(); p != nil {
		return p
	}
	if par := n.Parent(); par != nil && strings.HasSuffix(par.Kind(), "declarations") {
		return par.PrevSibling()
	}
	return nil
}

// haddockText strips a Haddock comment's markers: `-- |` on the first
// line and `--` on the rest, or a `{-| … -}` block's.
func haddockText(c string) string {
	if strings.HasPrefix(c, "{-") {
		return strings.TrimLeft(strings.TrimSpace(commentText(c)), "|^ ")
	}
	lines := strings.Split(c, "\n")
	for i, l := range lines {
		l = strings.TrimPrefix(strings.TrimSpace(l), "--")
		lines[i] = strings.TrimLeft(l, " |^")
	}
	return strings.Join(lines, " ")
}

// refineErlang: a function declaration that repeats the one above it
// (same name and arity: another clause) is dropped.
func refineErlang(src []byte, def *ts.Node, kind Kind) (Kind, string) {
	if def.Kind() != "fun_decl" {
		return kind, ""
	}
	p := def.PrevNamedSibling()
	for p != nil && isComment(p) {
		p = p.PrevNamedSibling()
	}
	if p != nil && p.Kind() == "fun_decl" && erlangHead(src, p) == erlangHead(src, def) {
		return "", ""
	}
	return kind, ""
}

// erlangHead is a function declaration's name and arity, "add/3".
func erlangHead(src []byte, def *ts.Node) string {
	clause := def.ChildByFieldName("clause")
	if clause == nil {
		return ""
	}
	arity := 0
	if args := clause.ChildByFieldName("args"); args != nil {
		arity = int(args.NamedChildCount())
	}
	return fieldText(src, clause, "name") + "/" + strconv.Itoa(arity)
}

// clojureDoc is a definition form's docstring: in `(defn name "doc" …)`
// the string right after the name, unless it is the form's last value
// (the value of `(def x "text")`); in a protocol method `(name [args]
// "doc")` the string at its end.
func clojureDoc(src []byte, outer *ts.Node) string {
	n := outer.NamedChildCount()
	var c *ts.Node
	if p := outer.Parent(); p != nil && p.Kind() == "list_lit" {
		if n > 2 {
			c = outer.NamedChild(n - 1)
		}
	} else if n > 3 {
		c = outer.NamedChild(2)
	}
	if c == nil || c.Kind() != "str_lit" {
		return ""
	}
	return firstSentence(docstringText(c.Utf8Text(src)))
}

// refinePerl: a sub's container is the package statement above it (a
// `package X { … }` block encloses its subs and needs nothing); a
// bareword is a const only as a key of a `use constant { … }` list.
func refinePerl(src []byte, def *ts.Node, kind Kind) (Kind, string) {
	switch def.Kind() {
	case "subroutine_declaration_statement":
		for p := def.PrevNamedSibling(); p != nil; p = p.PrevNamedSibling() {
			if p.Kind() == "package_statement" {
				return kind, fieldText(src, p, "name")
			}
		}
	case "autoquoted_bareword":
		p := def.Parent()
		for p != nil && p.Kind() == "list_expression" {
			p = p.Parent()
		}
		if p == nil || p.Kind() != "anonymous_hash_expression" || !perlUsesConstant(src, p.Parent()) {
			return "", ""
		}
	}
	return kind, ""
}

// perlUsesConstant reports `use constant`.
func perlUsesConstant(src []byte, n *ts.Node) bool {
	return n != nil && n.Kind() == "use_statement" && fieldText(src, n, "module") == "constant"
}

// juliaDoc is a Julia docstring: the string directly above a definition.
// An indented first block (the signature Julia docs open with) is
// skipped.
func juliaDoc(src []byte, outer *ts.Node) string {
	p := outer.PrevSibling()
	if p == nil || p.Kind() != "string_literal" || p.EndPosition().Row+1 < outer.StartPosition().Row {
		return ""
	}
	lines := strings.Split(docstringText(p.Utf8Text(src)), "\n")
	for len(lines) > 0 && (strings.TrimSpace(lines[0]) == "" || strings.HasPrefix(lines[0], "    ")) {
		lines = lines[1:]
	}
	return firstSentence(strings.Join(lines, " "))
}

// refineNim: a type is the kind of its definition; a method's container
// is the type of its first parameter.
func refineNim(src []byte, def *ts.Node, kind Kind) (Kind, string) {
	switch def.Kind() {
	case "type_declaration":
		return nimTypeKind(def.NamedChild(1)), ""
	case "method_declaration":
		if ps := def.ChildByFieldName("parameters"); ps != nil && ps.NamedChildCount() > 0 {
			t := ps.NamedChild(0).ChildByFieldName("type")
			for t != nil && t.Kind() != "identifier" {
				t = t.NamedChild(0) // var T, ref T, T[U]
			}
			if t != nil {
				return kind, t.Utf8Text(src)
			}
		}
	}
	return kind, ""
}

// nimTypeKind is the kind of a type definition's body node.
func nimTypeKind(t *ts.Node) Kind {
	if t != nil && t.Kind() == "type_expression" {
		t = t.NamedChild(0)
	}
	switch {
	case t == nil:
	case t.Kind() == "enum_declaration":
		return KindEnum
	case t.Kind() == "object_declaration", t.Kind() == "tuple_type":
		return KindStruct
	case t.Kind() == "ref_type" && t.NamedChildCount() > 0 && t.NamedChild(0).Kind() == "object_declaration":
		return KindClass
	case t.Kind() == "concept_declaration":
		return KindInterface
	}
	return KindType
}

// nimDoc is a definition's `##` doc where Nim puts it: the first one in
// a routine (before its body) or in a type's body, else one trailing on
// the definition's last line.
func nimDoc(src []byte, outer *ts.Node) string {
	d := nimFirstDoc(outer, 2)
	if n := outer.NextNamedSibling(); d == nil && n != nil && n.Kind() == "documentation_comment" && n.StartPosition().Row == outer.EndPosition().Row {
		d = n
	}
	if d == nil {
		return ""
	}
	return firstSentence(strings.TrimPrefix(strings.TrimSpace(d.Utf8Text(src)), "##"))
}

// nimFirstDoc is the documentation comment among n's children before its
// body, fields or values, looking depth levels into a type's body.
func nimFirstDoc(n *ts.Node, depth int) *ts.Node {
	for i := range n.NamedChildCount() {
		switch c := n.NamedChild(i); c.Kind() {
		case "documentation_comment":
			return c
		case "statement_list", "field_declaration_list", "enum_field_declaration":
			return nil
		case "enum_declaration", "object_declaration", "ref_type":
			if depth > 0 {
				return nimFirstDoc(c, depth-1)
			}
		}
	}
	return nil
}
