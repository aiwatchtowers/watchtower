//go:build cgo

package codeindex

import (
	"slices"
	"strings"

	"watchtower/internal/codeindex/ts"
)

// typeName is the bare name of a type node: `Foo<T>`, `a::Foo`, `&Foo`
// and `*Foo` give Foo; "" for a type with no single name.
func typeName(src []byte, t *ts.Node) string {
	for t != nil {
		switch t.Kind() {
		case "type_identifier", "identifier", "namespace_identifier":
			return t.Utf8Text(src)
		case "generic_type":
			t = t.ChildByFieldName("type")
		case "template_type":
			t = t.ChildByFieldName("name")
		case "scoped_type_identifier", "qualified_identifier":
			t = t.ChildByFieldName("name")
		case "reference_type", "pointer_type":
			t = t.ChildByFieldName("type")
		default:
			return ""
		}
	}
	return ""
}

// refineRust: a definition in an impl body takes the impl's type as its
// container (`impl<T> Trait for a::Foo<T>` gives Foo).
func refineRust(src []byte, def *ts.Node, kind Kind) (Kind, string) {
	list := def.Parent()
	if list == nil || list.Kind() != "declaration_list" {
		return kind, ""
	}
	impl := list.Parent()
	if impl == nil || impl.Kind() != "impl_item" {
		return kind, ""
	}
	return kind, typeName(src, impl.ChildByFieldName("type"))
}

// refineJS: a top-level variable is a function when its value is one,
// else a const for `const` and a var for `let`/`var`.
func refineJS(src []byte, def *ts.Node, kind Kind) (Kind, string) {
	if def.Kind() != "variable_declarator" {
		return kind, ""
	}
	if v := def.ChildByFieldName("value"); v != nil {
		switch v.Kind() {
		case "arrow_function", "function_expression", "generator_function":
			return KindFunction, ""
		}
	}
	if decl := def.Parent(); decl != nil && decl.Kind() == "lexical_declaration" {
		if k := decl.ChildByFieldName("kind"); k != nil && k.Utf8Text(src) == "const" {
			return KindConst, ""
		}
	}
	return KindVar, ""
}

// refineJava: a `static final` field is a const.
func refineJava(src []byte, def *ts.Node, kind Kind) (Kind, string) {
	if def.Kind() != "field_declaration" || def.NamedChildCount() == 0 {
		return kind, ""
	}
	if m := def.NamedChild(0); m != nil && m.Kind() == "modifiers" {
		words := strings.Fields(m.Utf8Text(src))
		if slices.Contains(words, "static") && slices.Contains(words, "final") {
			return KindConst, ""
		}
	}
	return kind, ""
}

// refineCSharp: a `const` field is a const.
func refineCSharp(src []byte, def *ts.Node, kind Kind) (Kind, string) {
	if def.Kind() != "field_declaration" {
		return kind, ""
	}
	for i := range def.NamedChildCount() {
		if c := def.NamedChild(i); c != nil && c.Kind() == "modifier" && c.Utf8Text(src) == "const" {
			return KindConst, ""
		}
	}
	return kind, ""
}

// refineC: a `const`/`constexpr` variable is a const; in C++, a function
// declared in a class body is a method, and one defined as `a::Foo<T>::bar`
// a method of Foo.
func refineC(src []byte, def *ts.Node, kind Kind) (Kind, string) {
	switch def.Kind() {
	case "declaration":
		if p := def.Parent(); kind == KindFunction && p != nil && p.Kind() == "field_declaration_list" {
			return KindMethod, ""
		}
		if kind == KindVar && hasQualifier(src, def, "const", "constexpr") {
			return KindConst, ""
		}
	case "function_definition":
		d := def.ChildByFieldName("declarator")
		for d != nil && d.Kind() != "function_declarator" {
			d = d.ChildByFieldName("declarator")
		}
		if d == nil {
			return kind, ""
		}
		q := d.ChildByFieldName("declarator")
		if q == nil || q.Kind() != "qualified_identifier" {
			return kind, ""
		}
		for n := q.ChildByFieldName("name"); n != nil && n.Kind() == "qualified_identifier"; n = q.ChildByFieldName("name") {
			q = n
		}
		return KindMethod, typeName(src, q.ChildByFieldName("scope"))
	}
	return kind, ""
}

// hasQualifier reports a type_qualifier child of def spelled as one of
// words.
func hasQualifier(src []byte, def *ts.Node, words ...string) bool {
	for i := range def.NamedChildCount() {
		if c := def.NamedChild(i); c != nil && c.Kind() == "type_qualifier" && slices.Contains(words, c.Utf8Text(src)) {
			return true
		}
	}
	return false
}

// refineLua: `function M.foo()`, `function M:foo()` and `M.foo = function`
// take the table M as container.
func refineLua(src []byte, def *ts.Node, kind Kind) (Kind, string) {
	name := def.ChildByFieldName("name")
	if def.Kind() == "assignment_statement" && def.NamedChildCount() > 0 {
		if list := def.NamedChild(0); list != nil {
			name = list.ChildByFieldName("name")
		}
	}
	if name == nil {
		return kind, ""
	}
	switch name.Kind() {
	case "dot_index_expression", "method_index_expression":
		if t := name.ChildByFieldName("table"); t != nil && t.Kind() == "identifier" {
			return kind, t.Utf8Text(src)
		}
	}
	return kind, ""
}
