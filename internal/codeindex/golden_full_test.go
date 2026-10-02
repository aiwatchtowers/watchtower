//go:build codegrammars && cgo

package codeindex

import "testing"

// The full grammar set's fixtures join the golden table.
func init() {
	goldenFixtures["rust"] = "sample.rs"
	goldenFixtures["javascript"] = "sample.js"
	goldenFixtures["typescript"] = "sample.ts"
	goldenFixtures["tsx"] = "sample.tsx"
	goldenFixtures["php"] = "sample.php"
	goldenFixtures["ruby"] = "sample.rb"
	goldenFixtures["java"] = "Sample.java"
	goldenFixtures["c"] = "sample.c"
	goldenFixtures["cpp"] = "sample.cpp"
	goldenFixtures["c_sharp"] = "Sample.cs"
	goldenFixtures["lua"] = "sample.lua"
	goldenFixtures["scala"] = "sample.scala"
	goldenFixtures["dart"] = "sample.dart"
	goldenFixtures["elixir"] = "sample.ex"
	goldenFixtures["elm"] = "Sample.elm"
	goldenFixtures["ocaml"] = "sample.ml"
	goldenFixtures["r"] = "sample.R"
}

// wantKinds checks that each named symbol exists once with the kind and
// container given.
func wantKinds(t *testing.T, syms []Symbol, want map[string][2]string) {
	t.Helper()
	for name, kc := range want {
		if s := one(t, syms, name); string(s.Kind) != kc[0] || s.Container != kc[1] {
			t.Errorf("%s = %s in %q, want %s in %q", name, s.Kind, s.Container, kc[0], kc[1])
		}
	}
}

// What an impl body defines takes the impl's type as container; a doc
// above #[derive] or #[inline] is still the item's doc.
func TestRust_ImplContainerAndAttributeDocs(t *testing.T) {
	syms := fixtureSymbols(t, "rust", "sample.rs")
	wantKinds(t, syms, map[string][2]string{
		"new": {"method", "Store"}, "CAPACITY": {"const", "Store"},
		"COUNT": {"const", "helpers"}, "NAME": {"var", "helpers"},
		"int": {"field", "Bits"}, "len": {"field", "Store"},
	})
	for _, s := range byName(syms, "key") {
		if s.Container != "Storable" && s.Container != "Wrapper" {
			t.Errorf("key in %q, want Storable or Wrapper (impl<T> Storable for Wrapper<T>)", s.Container)
		}
	}
	for name, doc := range map[string]string{"Store": "A key-value store.", "add": "Adds two numbers.", "Bits": "Raw bits of a number."} {
		if d := one(t, syms, name).Doc; d != doc {
			t.Errorf("%s doc = %q, want %q", name, d, doc)
		}
	}
	if s := byName(syms, "side"); len(s) != 0 {
		t.Errorf("an enum struct-variant field was indexed: %+v", s)
	}
}

func TestPHP_KindsAndDocblocksOnly(t *testing.T) {
	syms := fixtureSymbols(t, "php", "sample.php")
	wantKinds(t, syms, map[string][2]string{
		"Shape": {"enum", ""}, "Circle": {"const", "Shape"}, "CAPACITY": {"const", "Store"},
		"name": {"field", "Store"}, "limit": {"field", "Store"}, "entries": {"field", "Store"},
		"empty": {"method", "Store"}, "label": {"method", "Shape"}, "helper": {"function", ""},
		"double": {"function", ""}, "Counts": {"interface", ""}, "MAX_SIZE": {"const", ""},
	})
	if d := one(t, syms, "helper").Doc; d != "" {
		t.Errorf("a // comment above a function became a doc: %q", d)
	}
	if d := one(t, syms, "double").Doc; d != "Doubles a number." {
		t.Errorf("double /** */ doc = %q", d)
	}
	if len(byName(syms, "inner")) != 0 {
		t.Error("a closure inside a function was indexed")
	}
}

// TypeScript and TSX run the JavaScript query too: plain functions and
// TS-only interfaces and type aliases are both found.
func TestTypeScript_JSAndTSConstructs(t *testing.T) {
	ts := fixtureSymbols(t, "typescript", "sample.ts")
	wantKinds(t, ts, map[string][2]string{
		"helper": {"function", ""}, "double": {"function", ""}, "Storable": {"interface", ""},
		"Id": {"type", ""}, "Shape": {"enum", ""}, "Helpers": {"module", ""}, "assist": {"function", "Helpers"},
		"area": {"method", "Base"}, "entries": {"field", "Store"}, "MAX_SIZE": {"const", ""},
	})
	tsx := fixtureSymbols(t, "tsx", "sample.tsx")
	wantKinds(t, tsx, map[string][2]string{
		"Counter": {"function", ""}, "Badge": {"function", ""}, "CounterProps": {"interface", ""},
		"Label": {"type", ""}, "render": {"method", "Panel"},
	})
	if len(byName(ts, "local")) != 0 || len(byName(tsx, "count")) != 0 {
		t.Error("a local inside a function was indexed")
	}
}

func TestJavaScript_LocalsAndConstructors(t *testing.T) {
	syms := fixtureSymbols(t, "javascript", "sample.js")
	wantKinds(t, syms, map[string][2]string{
		"add": {"method", "Store"}, "entries": {"field", "Store"}, "double": {"function", ""},
		"MAX_SIZE": {"const", ""}, "counter": {"var", ""}, "render": {"function", ""}, "ids": {"function", ""},
	})
	if len(byName(syms, "inner")) != 0 || len(byName(syms, "constructor")) != 0 {
		t.Error("a nested function or a constructor was indexed")
	}
	if d := one(t, syms, "helper").Doc; d != "" {
		t.Errorf("a // comment became a doc: %q", d)
	}
}

func TestRuby_KindsAndMagicComments(t *testing.T) {
	syms := fixtureSymbols(t, "ruby", "sample.rb")
	wantKinds(t, syms, map[string][2]string{
		"Acme": {"module", ""}, "Store": {"class", "Acme"}, "add": {"method", "Store"},
		"empty": {"method", "Store"}, "build": {"method", "Store"}, "double": {"function", ""},
		"MAX_SIZE": {"const", "Acme"}, "Shape": {"class", ""},
	})
	if d := one(t, syms, "MAX_SIZE").Doc; d != "The largest size a store holds." {
		t.Errorf("a body's first statement lost its doc: %q", d)
	}
	if s := one(t, syms, "Acme"); s.Signature != "module Acme" {
		t.Errorf("Acme signature = %q (the body's leading comment leaked in)", s.Signature)
	}
	if len(byName(syms, "helper")) != 0 {
		t.Error("a local inside a method was indexed")
	}
}

func TestJava_Kinds(t *testing.T) {
	syms := fixtureSymbols(t, "java", "Sample.java")
	wantKinds(t, syms, map[string][2]string{
		"Storable": {"interface", ""}, "MAX_SIZE": {"const", "Sample"}, "entries": {"field", "Sample"},
		"add": {"method", "Sample"}, "Shape": {"enum", "Sample"}, "CIRCLE": {"const", "Shape"},
		"sides": {"method", "Shape"}, "Point": {"class", "Sample"}, "Marker": {"interface", "Sample"},
	})
	if len(byName(syms, "local")) != 0 {
		t.Error("a local inside a method was indexed")
	}
	if s := byName(syms, "Sample"); len(s) != 1 {
		t.Errorf("the constructor was indexed: %+v", s)
	}
}

func TestC_KindsAndMacros(t *testing.T) {
	syms := fixtureSymbols(t, "c", "sample.c")
	wantKinds(t, syms, map[string][2]string{
		"MAX_SIZE": {"macro", ""}, "store": {"struct", ""}, "len": {"field", "store"}, "keys": {"field", "store"},
		"shape": {"enum", ""}, "CIRCLE": {"const", "shape"}, "bits": {"struct", ""}, "id_t": {"type", ""},
		"capacity": {"const", ""}, "counter": {"var", ""}, "store_new": {"function", ""}, "store_first": {"function", ""},
	})
	if s := one(t, syms, "MAX_SIZE"); s.EndLine != s.Line {
		t.Errorf("a #define ends on line %d, want its own line %d", s.EndLine, s.Line)
	}
	if s := one(t, syms, "store_first"); s.EndLine != 50 || s.Doc != "Returns the store's first key." {
		t.Errorf("store_first = %+v, want the whole definition (to line 50) and its doc", s)
	}
	if len(byName(syms, "local")) != 0 {
		t.Error("a local inside a function was indexed")
	}
}

func TestCpp_MethodsAndQualifiedDefinitions(t *testing.T) {
	syms := fixtureSymbols(t, "cpp", "sample.cpp")
	wantKinds(t, syms, map[string][2]string{
		"acme": {"module", ""}, "Storable": {"class", "acme"}, "Point": {"struct", "acme"},
		"Shape": {"enum", "acme"}, "Id": {"type", "acme"}, "kMaxSize": {"const", ""}, "twice": {"function", ""},
		"name_": {"field", "Store"},
	})
	adds := byName(syms, "add")
	if len(adds) != 2 {
		t.Fatalf("add = %+v, want the declaration and the out-of-class definition", adds)
	}
	for _, s := range adds {
		if s.Kind != KindMethod || s.Container != "Store" {
			t.Errorf("add = %+v, want a method of Store", s)
		}
	}
	// Store is the class and its constructor declaration (a method).
	if s := byName(syms, "Store"); len(s) != 2 || s[0].Kind != KindClass || s[1].Kind != KindMethod ||
		s[0].Signature != "template <typename T> class Store : public Storable" || s[0].Doc != "A key-value store." {
		t.Errorf("Store = %+v (the template wrapper gives signature and doc)", s)
	}
	if len(byName(syms, "local")) != 0 {
		t.Error("a lambda inside a function was indexed")
	}
}

func TestCSharp_KindsAndXMLDocs(t *testing.T) {
	syms := fixtureSymbols(t, "c_sharp", "Sample.cs")
	wantKinds(t, syms, map[string][2]string{
		"IStorable": {"interface", ""}, "Store": {"class", ""}, "MaxSize": {"const", "Store"},
		"entries": {"field", "Store"}, "Add": {"method", "Store"}, "Shape": {"enum", ""}, "Circle": {"const", "Shape"},
		"Point": {"struct", ""}, "Label": {"class", ""}, "Handler": {"type", ""}, "Acme.Store": {"module", ""},
	})
	if d := one(t, syms, "Store").Doc; d != "A key-value store." {
		t.Errorf("Store doc = %q, want the <summary> text", d)
	}
	for _, s := range byName(syms, "Key") {
		if s.Container == "Store" && s.Doc != "" {
			t.Errorf("a // comment became a doc: %q", s.Doc)
		}
	}
	if len(byName(syms, "local")) != 0 {
		t.Error("a local inside a method was indexed")
	}
}

// `function M.foo()` is foo in M; `function M:add()` a method of M.
func TestLua_TableFunctions(t *testing.T) {
	syms := fixtureSymbols(t, "lua", "sample.lua")
	wantKinds(t, syms, map[string][2]string{
		"new": {"function", "M"}, "add": {"method", "M"}, "stop": {"function", "M"},
		"helper": {"function", ""}, "double": {"function", ""}, "start": {"function", ""},
	})
	if d := one(t, syms, "new").Doc; d != "Builds an empty store." {
		t.Errorf("new doc = %q", d)
	}
	if d := one(t, syms, "helper").Doc; d != "" {
		t.Errorf("a -- comment became a doc: %q", d)
	}
	if len(byName(syms, "inner")) != 0 {
		t.Error("a local function inside a function was indexed")
	}
}

func TestScala_Kinds(t *testing.T) {
	syms := fixtureSymbols(t, "scala", "sample.scala")
	wantKinds(t, syms, map[string][2]string{
		"Storable": {"interface", ""}, "MaxSize": {"const", ""}, "add": {"method", "Store"},
		"entries": {"field", "Store"}, "name": {"field", "Store"}, "Shape": {"enum", ""}, "Circle": {"const", "Shape"},
		"Point": {"class", ""}, "Id": {"type", ""}, "double": {"function", ""}, "empty": {"method", "Store"},
	})
	if s := one(t, syms, "add"); s.Signature != "def add(key: String, value: T): Unit" {
		t.Errorf("add signature = %q (the trailing = must go)", s.Signature)
	}
	if len(byName(syms, "local")) != 0 {
		t.Error("a local inside a method was indexed")
	}
}

// A Dart method's body is the signature's sibling: the span takes it in.
func TestDart_BodySiblingAndAnnotations(t *testing.T) {
	syms := fixtureSymbols(t, "dart", "sample.dart")
	wantKinds(t, syms, map[string][2]string{
		"Storable": {"class", ""}, "maxSize": {"const", ""}, "entries": {"field", "Store"},
		"add": {"method", "Store"}, "Shape": {"enum", ""}, "circle": {"const", "Shape"},
		"Counts": {"interface", ""}, "Shout": {"type", ""}, "shout": {"method", "Shout"},
		"Id": {"type", ""}, "twice": {"function", ""},
	})
	if s := one(t, syms, "add"); s.EndLine != 32 {
		t.Errorf("add ends on line %d, want 32 (its body)", s.EndLine)
	}
	for _, s := range byName(syms, "key") {
		if s.Container == "Store" && s.Doc != "" {
			t.Errorf("a // comment above @override became a doc: %q", s.Doc)
		}
	}
	if d := one(t, syms, "maxSize").Doc; d != "The largest size a store holds." {
		t.Errorf("maxSize doc = %q (through `const`)", d)
	}
	if len(byName(syms, "local")) != 0 {
		t.Error("a local inside a method was indexed")
	}
}

// defmodule is a module, defprotocol a protocol; docs are @moduledoc/@doc.
func TestElixir_ModulesAndDocAttributes(t *testing.T) {
	syms := fixtureSymbols(t, "elixir", "sample.ex")
	wantKinds(t, syms, map[string][2]string{
		"Acme.Store": {"module", ""}, "Acme.Storable": {"protocol", ""}, "Inner": {"module", "Acme.Store"},
		"new": {"function", "Acme.Store"}, "add": {"function", "Acme.Store"}, "size": {"function", "Acme.Store"},
		"twice": {"macro", "Acme.Store"}, "assist": {"function", "Inner"}, "key": {"function", "Acme.Storable"},
	})
	for name, doc := range map[string]string{
		"Acme.Store": "A key-value store.", "new": "Builds an empty store.", "add": "Adds a value under a key.",
		"size": "", "Inner": "", "key": "The key this value is stored under.",
	} {
		if d := one(t, syms, name).Doc; d != doc {
			t.Errorf("%s doc = %q, want %q", name, d, doc)
		}
	}
	if len(byName(syms, "helper")) != 0 {
		t.Error("a local inside a function was indexed")
	}
}

func TestElm_Kinds(t *testing.T) {
	syms := fixtureSymbols(t, "elm", "Sample.elm")
	wantKinds(t, syms, map[string][2]string{
		"Sample": {"module", ""}, "maxSize": {"function", ""}, "Store": {"type", ""}, "Shape": {"enum", ""},
		"Circle": {"const", "Shape"}, "add": {"function", ""}, "send": {"function", ""},
	})
	if d := one(t, syms, "maxSize").Doc; d != "The largest size a store holds." {
		t.Errorf("maxSize doc = %q (above its type annotation)", d)
	}
	if d := one(t, syms, "add").Doc; d != "" {
		t.Errorf("a -- comment became a doc: %q", d)
	}
	if len(byName(syms, "local")) != 0 {
		t.Error("a let binding was indexed")
	}
}

func TestOCaml_Kinds(t *testing.T) {
	syms := fixtureSymbols(t, "ocaml", "sample.ml")
	wantKinds(t, syms, map[string][2]string{
		"max_size": {"const", ""}, "store": {"struct", ""}, "entries": {"field", "store"}, "shape": {"enum", ""},
		"Circle": {"const", "shape"}, "empty": {"function", ""}, "add": {"function", ""},
		"STORABLE": {"interface", ""}, "key": {"function", "STORABLE"}, "Helpers": {"module", ""},
		"assist": {"function", "Helpers"}, "counter": {"class", ""}, "incr": {"method", "counter"}, "now": {"function", ""},
	})
	if d := one(t, syms, "name").Doc; d != "" {
		t.Errorf("the line above's trailing comment became name's doc: %q", d)
	}
	if d := one(t, syms, "add").Doc; d != "" {
		t.Errorf("a (* *) comment became a doc: %q", d)
	}
	if len(byName(syms, "local")) != 0 {
		t.Error("a let inside an expression was indexed")
	}
}

func TestR_Assignments(t *testing.T) {
	syms := fixtureSymbols(t, "r", "sample.R")
	wantKinds(t, syms, map[string][2]string{
		"double": {"function", ""}, "helper": {"function", ""}, "add_value": {"function", ""},
		"max_size": {"var", ""}, "stack": {"var", ""},
	})
	if d := one(t, syms, "double").Doc; d != "Doubles a number." {
		t.Errorf("double roxygen doc = %q", d)
	}
	if len(byName(syms, "local")) != 0 || len(byName(syms, "push")) != 0 {
		t.Error("a definition inside a function or a call was indexed")
	}
}
