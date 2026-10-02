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
	goldenFixtures["kotlin"] = "sample.kt"
	goldenFixtures["bash"] = "sample.sh"
	goldenFixtures["sql"] = "00001_init.sql"
	goldenFixtures["hcl"] = "main.tf"
	goldenFixtures["proto"] = "store.proto"
	goldenFixtures["graphql"] = "schema.graphql"
	goldenFixtures["groovy"] = "Sample.groovy"
	goldenFixtures["objc"] = "Store.m"
	goldenFixtures["zig"] = "store.zig"
	goldenFixtures["haskell"] = "Store.hs"
	goldenFixtures["erlang"] = "store.erl"
	goldenFixtures["clojure"] = "store.clj"
	goldenFixtures["perl"] = "Store.pm"
	goldenFixtures["julia"] = "store.jl"
	goldenFixtures["nim"] = "store.nim"
	goldenFixtures["vue"] = "Counter.vue"
	goldenFixtures["svelte"] = "Counter.svelte"
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

// Kotlin: class, object, interface, fun, extension fun and property kinds;
// a KDoc right after the imports or the package header is still a doc.
func TestKotlin_KindsAndDocsAfterTheHeader(t *testing.T) {
	syms := fixtureSymbols(t, "kotlin", "sample.kt")
	wantKinds(t, syms, map[string][2]string{
		"MAX_SIZE": {"const", ""}, "Entry": {"class", ""}, "value": {"field", "Entry"},
		"Shape": {"enum", ""}, "CIRCLE": {"const", "Shape"}, "sides": {"method", "Shape"},
		"Storable": {"interface", ""}, "Store": {"class", ""}, "name": {"field", "Store"},
		"count": {"field", "Store"}, "add": {"method", "Store"}, "empty": {"method", "Store"},
		"Registry": {"module", ""}, "stores": {"field", "Registry"}, "register": {"method", "Registry"},
		"double": {"function", ""}, "lastChar": {"method", "String"}, "Id": {"type", ""},
		"counter": {"var", ""}, "Event": {"interface", ""},
	})
	if d := one(t, syms, "MAX_SIZE").Doc; d != "The largest size a store holds." {
		t.Errorf("MAX_SIZE doc = %q (the KDoc right after the imports)", d)
	}
	if s := one(t, syms, "MAX_SIZE"); s.Signature != "const val MAX_SIZE = 64" {
		t.Errorf("MAX_SIZE signature = %q (from `const`, not the bare name)", s.Signature)
	}
	if d := one(t, syms, "Shape").Doc; d != "" {
		t.Errorf("a // comment became a doc: %q", d)
	}
	if len(byName(syms, "local")) != 0 || len(byName(syms, "inner")) != 0 {
		t.Error("a local inside a function was indexed")
	}
	if s := one(t, fixtureSymbols(t, "kotlin", "NoImports.kt"), "Point"); s.Doc != "A point in the plane." {
		t.Errorf("Point doc = %q (the KDoc right after the package header)", s.Doc)
	}
}

// Both function forms are found; a function inside a function is not.
func TestBash_FunctionFormsAndDirectives(t *testing.T) {
	syms := fixtureSymbols(t, "bash", "sample.sh")
	wantKinds(t, syms, map[string][2]string{
		"log": {"function", ""}, "double": {"function", ""}, "cleanup": {"function", ""},
		"usage": {"function", ""}, "debug": {"function", ""}, "MAX_SIZE": {"const", ""},
		"GREETING": {"const", ""}, "LOG_LEVEL": {"var", ""}, "counter": {"var", ""}, "STORES": {"var", ""},
	})
	for name, doc := range map[string]string{
		"log": "Prints a message to stderr.", "double": "Doubles a number.",
		"MAX_SIZE": "The largest size a store holds.", "cleanup": "",
	} {
		if d := one(t, syms, name).Doc; d != doc {
			t.Errorf("%s doc = %q, want %q (## and a shellcheck directive in the run)", name, d, doc)
		}
	}
	if len(byName(syms, "inner")) != 0 || len(byName(syms, "level")) != 0 {
		t.Error("a function or a local inside a function was indexed")
	}
}

// Tables, views, indexes and triggers in a goose migration: the
// annotations are no docs, a SQLite trigger parses, and what follows it
// is still indexed.
func TestSQL_MigrationStatements(t *testing.T) {
	syms := fixtureSymbols(t, "sql", "00001_init.sql")
	wantKinds(t, syms, map[string][2]string{
		"stores": {"type", ""}, "created_at": {"field", "stores"}, "entries": {"type", ""},
		"idx_entries_key": {"const", ""}, "busy_stores": {"type", ""}, "entries_touch": {"const", ""},
		"audit": {"type", ""}, "changed_at": {"field", "audit"}, "audit_touch": {"const", ""},
		"mood": {"type", ""}, "add_one": {"function", ""}, "store_names": {"type", ""},
	})
	if s := one(t, syms, "stores"); s.Doc != "Stores hold entries by key." || s.Signature != "CREATE TABLE IF NOT EXISTS stores" {
		t.Errorf("stores = %+v", s)
	}
	if s := one(t, syms, "entries_touch"); s.Line != 24 || s.EndLine != 27 || s.Signature != "CREATE TRIGGER entries_touch AFTER INSERT ON entries" {
		t.Errorf("entries_touch = %+v, want lines 24-27 and the file's own text", s)
	}
	if d := one(t, syms, "entries").Doc; d != "" {
		t.Errorf("entries doc = %q", d)
	}
}

func TestHCL_TerraformBlocks(t *testing.T) {
	syms := fixtureSymbols(t, "hcl", "main.tf")
	wantKinds(t, syms, map[string][2]string{
		"aws_s3_bucket.artifacts": {"var", ""}, "aws_caller_identity.current": {"var", ""},
		"network": {"module", ""}, "region": {"var", ""}, "bucket_arn": {"const", ""},
		"name_prefix": {"var", ""}, "tags": {"var", ""},
	})
	if s := one(t, syms, "aws_s3_bucket.artifacts"); s.Signature != `resource "aws_s3_bucket" "artifacts"` || s.Doc != "The bucket that holds build artifacts." {
		t.Errorf("artifacts = %+v", s)
	}
	for _, name := range []string{"aws", "terraform", "lifecycle", "bucket", "source", "prevent_destroy"} {
		if len(byName(syms, name)) != 0 {
			t.Errorf("%s was indexed (a provider, a nested block or a block attribute)", name)
		}
	}
}

func TestProto_MessagesAndServices(t *testing.T) {
	syms := fixtureSymbols(t, "proto", "store.proto")
	wantKinds(t, syms, map[string][2]string{
		"Entry": {"struct", ""}, "key": {"field", "Entry"}, "Label": {"struct", "Entry"},
		"name": {"field", "Label"}, "meta": {"field", "Entry"}, "user": {"field", "Entry"},
		"Shape": {"enum", ""}, "SHAPE_CIRCLE": {"const", "Shape"}, "StoreService": {"interface", ""},
		"Add": {"method", "StoreService"}, "Watch": {"method", "StoreService"}, "AddRequest": {"struct", ""},
	})
	if s := one(t, syms, "Watch"); s.Signature != "rpc Watch(WatchRequest) returns (stream Entry)" || s.EndLine != 40 {
		t.Errorf("Watch = %+v", s)
	}
	if len(byName(syms, "source")) != 0 || len(byName(syms, "acme")) != 0 {
		t.Error("a oneof or the package was indexed")
	}
}

// Docs are descriptions, not # comments; a signature starts after the
// description.
func TestGraphQL_DescriptionsAreDocs(t *testing.T) {
	syms := fixtureSymbols(t, "graphql", "schema.graphql")
	wantKinds(t, syms, map[string][2]string{
		"Node": {"interface", ""}, "Shape": {"enum", ""}, "CIRCLE": {"const", "Shape"},
		"AddInput": {"struct", ""}, "SearchResult": {"type", ""}, "Time": {"type", ""},
		"internal": {"macro", ""}, "shape": {"field", "Entry"}, "Query": {"class", ""},
		"LoadEntry": {"function", ""}, "AddEntry": {"function", ""}, "EntryParts": {"function", ""},
	})
	entries := byName(syms, "Entry")
	if len(entries) != 2 || entries[0].Kind != KindClass || entries[1].Kind != KindType {
		t.Fatalf("Entry = %+v, want the type and its extension", entries)
	}
	if s := entries[0]; s.Signature != "type Entry implements Node" || s.Doc != "A value kept under a key." || s.Line != 4 {
		t.Errorf("Entry = %+v", s)
	}
	for name, doc := range map[string]string{"Node": "", "LoadEntry": "", "Shape": "How an entry is drawn."} {
		if d := one(t, syms, name).Doc; d != doc {
			t.Errorf("%s doc = %q, want %q", name, d, doc)
		}
	}
	if len(byName(syms, "format")) != 0 {
		t.Error("a field argument was indexed")
	}
}

// `implements` and `trait`, which the grammar does not know, still give
// the class its own name.
func TestGroovy_ClassesTraitsAndGroovyDoc(t *testing.T) {
	syms := fixtureSymbols(t, "groovy", "Sample.groovy")
	wantKinds(t, syms, map[string][2]string{
		"MAX_SIZE": {"const", ""}, "Storable": {"interface", ""}, "Store": {"class", ""},
		"CAPACITY": {"const", "Store"}, "entries": {"field", "Store"}, "name": {"field", "Store"},
		"add": {"method", "Store"}, "empty": {"method", "Store"}, "twice": {"function", ""},
		"helper": {"function", ""}, "Named": {"interface", ""}, "label": {"method", "Named"},
		"Cache": {"class", ""}, "text": {"field", "Cache"},
		"Ledger": {"class", ""}, "total": {"field", "Ledger"}, "Journal": {"class", ""},
	})
	if len(byName(syms, "Old")) != 0 || len(byName(syms, "Older")) != 0 {
		t.Error("a class header inside a block comment was indexed")
	}
	if s := one(t, syms, "Store"); s.Signature != "@CompileStatic class Store implements Storable" || s.Doc != "Keeps entries by key." {
		t.Errorf("Store = %+v", s)
	}
	if d := one(t, syms, "add").Doc; d != "Adds a value under a key." {
		t.Errorf("add doc = %q", d)
	}
	if len(byName(syms, "local")) != 0 || len(byName(syms, "Shape")) != 0 {
		t.Error("a local, or an enum the grammar cannot parse, was indexed")
	}
}

// Objective-C runs the C query too; methods are named by selector, and an
// NS_ENUM is an enum.
func TestObjC_SelectorsCategoriesAndEnumMacros(t *testing.T) {
	syms := fixtureSymbols(t, "objc", "Store.m")
	wantKinds(t, syms, map[string][2]string{
		"Storable": {"protocol", ""}, "empty": {"method", "Storable"},
		"Shape": {"enum", ""}, "ShapeCircle": {"const", "Shape"}, "name": {"field", "Store"},
		"dump": {"method", "Store"}, "_entries": {"field", "Store"}, "twice": {"function", ""},
		"Point": {"struct", ""}, "x": {"field", "Point"}, "MAX_SIZE": {"macro", ""},
	})
	adds := byName(syms, "addValue:forKey:")
	if len(adds) != 2 || adds[0].Container != "Store" || adds[1].Container != "Store" || adds[1].Signature != "- (void)addValue:(id)value forKey:(NSString *)key" {
		t.Errorf("addValue:forKey: = %+v, want the declaration and the definition in Store", adds)
	}
	stores := byName(syms, "Store")
	if len(stores) != 3 || stores[0].Kind != KindClass || stores[1].Kind != KindType || stores[2].Kind != KindClass {
		t.Errorf("Store = %+v, want the @interface, its category (a type) and the @implementation", stores)
	}
	if s := one(t, syms, "Shape"); s.Signature != "typedef NS_ENUM(NSInteger, Shape)" || s.Doc != "How a store is drawn." || s.Col != 28 {
		t.Errorf("Shape = %+v (the file's own text, the name where it is)", s)
	}
	if len(byName(syms, "local")) != 0 || len(byName(syms, "doubled")) != 0 || len(byName(syms, "")) != 0 {
		t.Error("a local, or an empty typedef name, was indexed")
	}
}

func TestZig_ContainersAndImports(t *testing.T) {
	syms := fixtureSymbols(t, "zig", "store.zig")
	wantKinds(t, syms, map[string][2]string{
		"max_size": {"const", ""}, "counter": {"var", ""}, "Store": {"struct", ""}, "len": {"field", "Store"},
		"capacity": {"const", "Store"}, "init": {"method", "Store"}, "Shape": {"enum", ""},
		"circle": {"const", "Shape"}, "sides": {"method", "Shape"}, "Value": {"struct", ""},
		"text": {"field", "Value"}, "Failure": {"enum", ""}, "twice": {"function", ""},
	})
	if d := one(t, syms, "init").Doc; d != "Builds an empty store." {
		t.Errorf("init doc = %q", d)
	}
	if d := one(t, syms, "Shape").Doc; d != "" {
		t.Errorf("a // comment became a doc: %q", d)
	}
	if len(byName(syms, "std")) != 0 || len(byName(syms, "local")) != 0 {
		t.Error("an @import alias or a local was indexed")
	}
}

// One row per function (at its first equation), Haddock docs above the
// definition or its signature.
func TestHaskell_EquationsAndHaddock(t *testing.T) {
	syms := fixtureSymbols(t, "haskell", "Store.hs")
	wantKinds(t, syms, map[string][2]string{
		"Acme.Store": {"module", ""}, "maxSize": {"const", ""}, "Store": {"struct", ""},
		"entries": {"field", "Store"}, "Shape": {"enum", ""}, "Circle": {"const", "Shape"},
		"Key": {"struct", ""}, "Id": {"type", ""}, "Storable": {"interface", ""}, "key": {"method", "Storable"},
		"label": {"method", "Storable"}, "empty": {"function", ""}, "add": {"function", ""},
		"twice": {"function", ""}, "size": {"function", ""},
	})
	for name, doc := range map[string]string{
		"maxSize": "The largest size a store holds.", "empty": "Builds an empty store.",
		"key": "The key a value is stored under.", "label": "", "Shape": "", "size": "Counts the entries.",
	} {
		if d := one(t, syms, name).Doc; d != doc {
			t.Errorf("%s doc = %q, want %q", name, d, doc)
		}
	}
	if s := one(t, syms, "Storable"); s.Signature != "class Storable a where" {
		t.Errorf("Storable signature = %q", s.Signature)
	}
	if len(byName(syms, "local")) != 0 {
		t.Error("a where binding was indexed")
	}
}

func TestErlang_FormsAndClauses(t *testing.T) {
	syms := fixtureSymbols(t, "erlang", "store.erl")
	wantKinds(t, syms, map[string][2]string{
		"MAX_SIZE": {"macro", ""}, "is_key": {"macro", ""}, "entry": {"struct", ""},
		"key": {"field", "entry"}, "id": {"type", ""}, "new": {"function", ""}, "add": {"function", ""},
		"size": {"function", ""},
	})
	if s := byName(syms, "store"); len(s) != 2 || s[0].Kind != KindModule || s[1].Kind != KindType {
		t.Errorf("store = %+v, want the module and the opaque type", s)
	}
	for name, doc := range map[string]string{
		"new": "Builds an empty store.", "add": "Adds a value under a key.", "size": "", "entry": "A stored entry.",
	} {
		if d := one(t, syms, name).Doc; d != doc {
			t.Errorf("%s doc = %q, want %q (through -spec, @doc dropped, %% not a doc)", name, d, doc)
		}
	}
	if len(byName(syms, "init")) != 0 {
		t.Error("a -callback was indexed")
	}
}

func TestClojure_DefFormsAndDocstrings(t *testing.T) {
	syms := fixtureSymbols(t, "clojure", "store.clj")
	wantKinds(t, syms, map[string][2]string{
		"acme.store": {"module", ""}, "max-size": {"var", ""}, "greeting": {"var", ""}, "registry": {"var", ""},
		"add": {"function", ""}, "helper": {"function", ""}, "area": {"function", ""}, "with-store": {"macro", ""},
		"Storable": {"protocol", ""}, "key-of": {"method", "Storable"}, "Entry": {"struct", ""}, "Box": {"struct", ""},
	})
	for name, doc := range map[string]string{
		"acme.store": "A key-value store.", "add": "Adds a value under a key.", "greeting": "The greeting a store prints.",
		"max-size": "The largest size a store holds.", "key-of": "The key a value is stored under.", "registry": "",
	} {
		if d := one(t, syms, name).Doc; d != doc {
			t.Errorf("%s doc = %q, want %q", name, d, doc)
		}
	}
	if len(byName(syms, "inner")) != 0 || len(byName(syms, "local")) != 0 {
		t.Error("a local was indexed")
	}
}

// A sub's container is the package statement above it.
func TestPerl_PackagesAndConstants(t *testing.T) {
	syms := fixtureSymbols(t, "perl", "Store.pm")
	wantKinds(t, syms, map[string][2]string{
		"Acme::Store": {"module", ""}, "MAX_SIZE": {"const", ""}, "CIRCLE": {"const", ""}, "SQUARE": {"const", ""},
		"VERSION": {"var", ""}, "counter": {"var", ""}, "new": {"function", "Acme::Store"},
		"add": {"function", "Acme::Store"}, "key": {"function", "Acme::Store::Entry"},
	})
	if d := one(t, syms, "new").Doc; d != "Builds an empty store." {
		t.Errorf("new doc = %q", d)
	}
	for _, name := range []string{"entries", "self", "inner", "class"} {
		if len(byName(syms, name)) != 0 {
			t.Errorf("%s was indexed (a hash key or a local)", name)
		}
	}
}

func TestJulia_DefinitionsAndDocstrings(t *testing.T) {
	syms := fixtureSymbols(t, "julia", "store.jl")
	wantKinds(t, syms, map[string][2]string{
		"Acme": {"module", ""}, "MAX_SIZE": {"const", "Acme"}, "counter": {"var", "Acme"}, "Store": {"struct", "Acme"},
		"entries": {"field", "Store"}, "Shape": {"type", "Acme"}, "Bits": {"type", "Acme"}, "Color": {"enum", "Acme"},
		"green": {"const", "Color"}, "add!": {"function", "Acme"}, "twice": {"function", "Acme"},
		"trace": {"macro", "Acme"}, "length": {"function", "Acme"},
	})
	for name, doc := range map[string]string{
		"Store": "A key-value store.", "twice": "Doubles a number.", "add!": "", "MAX_SIZE": "The largest size a store holds.",
	} {
		if d := one(t, syms, name).Doc; d != doc {
			t.Errorf("%s doc = %q, want %q", name, d, doc)
		}
	}
	if len(byName(syms, "inner")) != 0 || len(byName(syms, "local_key")) != 0 {
		t.Error("a local was indexed")
	}
}

// Nim docs sit after the definition's line or open its body.
func TestNim_RoutinesTypesAndTrailingDocs(t *testing.T) {
	syms := fixtureSymbols(t, "nim", "store.nim")
	wantKinds(t, syms, map[string][2]string{
		"MaxSize": {"const", ""}, "defaultName": {"const", ""}, "counter": {"var", ""}, "Shape": {"enum", ""},
		"circle": {"const", "Shape"}, "Store": {"struct", ""}, "name": {"field", "Store"}, "Storable": {"interface", ""},
		"Id": {"type", ""}, "Node": {"class", ""}, "Pair": {"struct", ""}, "newStore": {"function", ""},
		"area": {"method", "Node"}, "items": {"function", ""}, "withStore": {"macro", ""}, "trace": {"macro", ""},
		"toInt": {"function", ""},
	})
	for name, doc := range map[string]string{
		"MaxSize": "The largest size a store holds.", "Shape": "How a store is drawn.", "Store": "A key-value store.",
		"name": "The store's name.", "newStore": "Builds an empty store.", "add": "",
	} {
		if d := one(t, syms, name).Doc; d != doc {
			t.Errorf("%s doc = %q, want %q", name, d, doc)
		}
	}
	if s := one(t, syms, "Shape"); s.Signature != "Shape* = enum" {
		t.Errorf("Shape signature = %q (the trailing doc must not leak in)", s.Signature)
	}
	if len(byName(syms, "inner")) != 0 || len(byName(syms, "local")) != 0 {
		t.Error("a local was indexed")
	}
}

// A Vue file's <script setup lang="ts"> is parsed with the TypeScript
// query, its symbols on their lines in the .vue file; what the template
// holds is not code.
func TestVue_ScriptSetupLinesAreTheFile(t *testing.T) {
	syms := fixtureSymbols(t, "vue", "Counter.vue")
	inc := one(t, syms, "increment")
	if inc.Kind != KindFunction || inc.Line != 19 || inc.Col != 10 || inc.EndLine != 21 || inc.Doc != "Adds one to the count." {
		t.Errorf("increment = %+v, want a function at 19:10–21 with its doc", inc)
	}
	if s := one(t, syms, "Counter"); s.Kind != KindInterface || s.Line != 12 {
		t.Errorf("Counter = %+v, want an interface on line 12 (TypeScript)", s)
	}
	wantKinds(t, syms, map[string][2]string{"reset": {"method", "Store"}})
	if len(byName(syms, "fakeTemplate")) != 0 {
		t.Error("text in the template was indexed")
	}
}

// A Svelte file's lang="ts" blocks (module and instance) are TypeScript.
func TestSvelte_TypeScriptBlocks(t *testing.T) {
	syms := fixtureSymbols(t, "svelte", "Counter.svelte")
	wantKinds(t, syms, map[string][2]string{
		"Options": {"interface", ""}, "step": {"function", ""}, "Tally": {"class", ""}, "total": {"method", "Tally"},
	})
	if s := one(t, syms, "step"); s.Line != 12 || s.Doc != "Moves the count by one step." {
		t.Errorf("step = %+v, want line 12 with its doc", s)
	}
	if len(byName(syms, "fakeMarkup")) != 0 {
		t.Error("text in the markup was indexed")
	}
}
