//go:build cgo

package codeindex

import (
	"bytes"
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"slices"
	"testing"
)

var update = flag.Bool("update", false, "rewrite testdata/<lang>/expected.json")

// fixtureSymbols indexes testdata/<lang> and returns the symbols of its
// one source file.
func fixtureSymbols(t *testing.T, lang, file string) []Symbol {
	t.Helper()
	got := collect(t, filepath.Join("testdata", lang), nil, nil)
	r, ok := got[file]
	if !ok {
		t.Fatalf("%s was not indexed (got %v)", file, got)
	}
	if r.Lang != lang {
		t.Fatalf("%s lang = %q, want %q", file, r.Lang, lang)
	}
	return r.Symbols
}

// goldenFixtures maps a language to its fixture file under testdata/<lang>;
// a tagged build adds its languages (golden_full_test.go).
var goldenFixtures = map[string]string{
	"go": "sample.go", "swift": "sample.swift", "python": "sample.py",
	"yaml": "settings.yaml", "toml": "config.toml", "json": "package.json",
}

// The golden fixtures: every symbol field (name, kind, line, col,
// end_line, container, signature, doc) equals expected.json.
func TestGolden(t *testing.T) {
	for lang, file := range goldenFixtures {
		t.Run(lang, func(t *testing.T) {
			got := fixtureSymbols(t, lang, file)
			path := filepath.Join("testdata", lang, "expected.json")
			if *update {
				var buf bytes.Buffer
				enc := json.NewEncoder(&buf)
				enc.SetEscapeHTML(false)
				enc.SetIndent("", "  ")
				if err := enc.Encode(got); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(path, buf.Bytes(), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			var want []Symbol
			if err := json.Unmarshal(data, &want); err != nil {
				t.Fatal(err)
			}
			if !slices.Equal(got, want) {
				for i := range max(len(got), len(want)) {
					var g, w Symbol
					if i < len(got) {
						g = got[i]
					}
					if i < len(want) {
						w = want[i]
					}
					if g != w {
						t.Errorf("symbol %d:\n got  %+v\n want %+v", i, g, w)
					}
				}
			}
		})
	}
}

// noTypes are the fixture languages with no type or module definitions to
// index, noFuncs those with no functions or methods; outlineLangs are
// indexed as an outline of top-level fields only.
var (
	noTypes      = map[string]bool{"lua": true, "r": true, "bash": true}
	noFuncs      = map[string]bool{"hcl": true}
	outlineLangs = map[string]bool{"yaml": true, "toml": true, "json": true}
)

// Every fixture exercises a function or method, a type (or module) and a
// doc, so a query that lost a whole family shows here and not only as a
// golden diff. An outline language's fixture instead lists only top-level
// fields, each flagged outline.
func TestGolden_FixturesCoverTheBasics(t *testing.T) {
	for lang, file := range goldenFixtures {
		t.Run(lang, func(t *testing.T) {
			if outlineLangs[lang] {
				wantOutlineFields(t, fixtureSymbols(t, lang, file))
				return
			}
			var fn, typ, doc bool
			for _, s := range fixtureSymbols(t, lang, file) {
				switch s.Kind {
				case KindFunction, KindMethod:
					fn = true
				case KindClass, KindStruct, KindEnum, KindProtocol, KindInterface, KindType, KindModule:
					typ = true
				case KindConst, KindVar, KindField, KindMacro:
				}
				doc = doc || s.Doc != ""
			}
			if (!fn && !noFuncs[lang]) || (!typ && !noTypes[lang]) || !doc {
				t.Errorf("function/method %v, type %v, doc %v; want all", fn, typ, doc)
			}
		})
	}
}

// wantOutlineFields checks a non-empty outline: every symbol a top-level
// field flagged outline.
func wantOutlineFields(t *testing.T, syms []Symbol) {
	t.Helper()
	if len(syms) == 0 {
		t.Fatal("no symbols")
	}
	for _, s := range syms {
		if s.Kind != KindField || !s.Outline || s.Container != "" {
			t.Errorf("%+v: want a top-level field flagged outline", s)
		}
	}
}

// Every query this build carries compiles against its grammar on the
// official runtime (Ruby's upstream predicates did not).
func TestQueriesCompile(t *testing.T) {
	for id := range grammars {
		if _, err := grammarFor(id); err != nil {
			t.Errorf("%s: %v", id, err)
		}
	}
}

func byName(syms []Symbol, name string) []Symbol {
	var out []Symbol
	for _, s := range syms {
		if s.Name == name {
			out = append(out, s)
		}
	}
	return out
}

func one(t *testing.T, syms []Symbol, name string) Symbol {
	t.Helper()
	got := byName(syms, name)
	if len(got) != 1 {
		t.Fatalf("%d symbols named %q, want 1: %+v", len(got), name, got)
	}
	return got[0]
}

func TestSwift_Kinds(t *testing.T) {
	syms := fixtureSymbols(t, "swift", "sample.swift")
	for name, kind := range map[string]Kind{
		"Shape": KindProtocol, "Point": KindStruct, "Direction": KindEnum, "Cache": KindClass,
		"CounterModel": KindClass, "Grid": KindType, "après": KindFunction, "🙂": KindConst, "counter": KindVar,
	} {
		if s := byName(syms, name); len(s) == 0 || s[0].Kind != kind {
			t.Errorf("%s = %+v, want kind %s", name, s, kind)
		}
	}
	// extension Point is a type row of its own, and the container of
	// what it declares.
	var ext []Symbol
	for _, s := range byName(syms, "Point") {
		if s.Kind == KindType {
			ext = append(ext, s)
		}
	}
	if len(ext) != 1 || one(t, syms, "distance").Container != "Point" {
		t.Errorf("extension Point = %+v, distance in %q", ext, one(t, syms, "distance").Container)
	}
}

func TestSwift_MethodsInsideAnEnumAreMethods(t *testing.T) {
	syms := fixtureSymbols(t, "swift", "sample.swift")
	for _, name := range []string{"flipped", "all"} {
		if s := one(t, syms, name); s.Kind != KindMethod || s.Container != "Direction" {
			t.Errorf("%s = %+v, want a method in Direction", name, s)
		}
	}
}

// Upstream's property pattern reported the enclosing type once per
// property; each type must appear exactly once per declaration.
func TestSwift_PropertiesDoNotProduceFakeTypeRows(t *testing.T) {
	syms := fixtureSymbols(t, "swift", "sample.swift")
	var types []string
	for _, s := range syms {
		if s.Kind == KindClass || s.Kind == KindStruct || s.Kind == KindEnum {
			types = append(types, s.Name)
		}
	}
	slices.Sort(types)
	if want := []string{"Cache", "CounterModel", "Direction", "Point"}; !slices.Equal(types, want) {
		t.Errorf("type rows = %v, want %v", types, want)
	}
	for name, container := range map[string]string{"x": "Point", "y": "Point", "sum": "Point", "store": "Cache", "count": "CounterModel", "area": "Shape"} {
		if s := one(t, syms, name); s.Kind != KindField || s.Container != container {
			t.Errorf("%s = %+v, want a field in %s", name, s, container)
		}
	}
	if s := byName(syms, "previous"); len(s) != 0 {
		t.Errorf("a local inside a function body was indexed: %+v", s)
	}
}

func TestSwift_DocAboveAnAttributeIsPickedUp(t *testing.T) {
	syms := fixtureSymbols(t, "swift", "sample.swift")
	s := one(t, syms, "CounterModel")
	if s.Doc != "A view model the main actor owns." {
		t.Errorf("CounterModel doc = %q", s.Doc)
	}
	if s.Signature != "@MainActor final class CounterModel" {
		t.Errorf("CounterModel signature = %q", s.Signature)
	}
	if d := one(t, syms, "Direction").Doc; d != "" {
		t.Errorf("a // comment became a doc: %q", d)
	}
	if d := one(t, syms, "Cache").Doc; d != "Keeps values by key." {
		t.Errorf("Cache /** */ doc = %q", d)
	}
}

// A function using #expect still parses, and so does what follows it.
func TestSwift_MacroLinesDoNotAbortTheFile(t *testing.T) {
	syms := fixtureSymbols(t, "swift", "sample.swift")
	for _, name := range []string{"increment", "reset", "après", "counter"} {
		if len(byName(syms, name)) != 1 {
			t.Errorf("%s missing after the #expect line", name)
		}
	}
}

// `let 🙂 = 1; func après() {}`: columns in UTF-16 units (🙂 is two).
func TestSwift_ColumnsAreUTF16(t *testing.T) {
	syms := fixtureSymbols(t, "swift", "sample.swift")
	if c := one(t, syms, "🙂").Col; c != 5 {
		t.Errorf("🙂 col = %d, want 5", c)
	}
	if c := one(t, syms, "après").Col; c != 18 {
		t.Errorf("après col = %d, want 18 (UTF-16; bytes would give 20, runes 17)", c)
	}
}

func TestPython_DocstringIsTheDocAndACommentIsNot(t *testing.T) {
	syms := fixtureSymbols(t, "python", "sample.py")
	for name, doc := range map[string]string{
		"top":       "Return the larger value.",
		"decorated": "Decorated function.",
		"Box":       "A box that holds things.",
		"area":      "The box's area, squared.",
		"__init__":  "",
	} {
		if d := one(t, syms, name).Doc; d != doc {
			t.Errorf("%s doc = %q, want %q", name, d, doc)
		}
	}
	if s := one(t, syms, "method"); s.Kind != KindMethod || s.Container != "Inner" {
		t.Errorf("method = %+v, want a method in Inner", s)
	}
	if len(byName(syms, "inner")) != 0 {
		t.Error("a function nested in a function was indexed")
	}
}

func TestGo_ReceiverContainerAndDirectives(t *testing.T) {
	syms := fixtureSymbols(t, "go", "sample.go")
	for name, container := range map[string]string{"Add": "Store", "Len": "Store", "First": "Pair", "items": "Store", "Read": "Reader"} {
		if c := one(t, syms, name).Container; c != container {
			t.Errorf("%s container = %q, want %q", name, c, container)
		}
	}
	if d := one(t, syms, "Len").Doc; d != "" {
		t.Errorf("a //go: directive became a doc: %q", d)
	}
	if d := one(t, syms, "Pair").Doc; d != "Pair holds two values." {
		t.Errorf("Pair doc = %q (the directive after it must be skipped)", d)
	}
	if s := one(t, syms, "Store"); s.Kind != KindStruct || s.Signature != "type Store struct" {
		t.Errorf("Store = %+v", s)
	}
	if len(byName(syms, "local")) != 0 {
		t.Error("a local inside a function body was indexed")
	}
}
