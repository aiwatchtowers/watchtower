package codeindex

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// tclRules is a valid rules file: Tcl procs and namespaces, Makefile-ish
// targets in files named Taskfile.
const tclRules = `
tcl:
  extensions: [.tcl, tm]
  definitions:
    - kind: function
      pattern: '^\s*proc\s+([A-Za-z_][\w:]*)'
    - kind: module
      pattern: '^\s*namespace\s+eval\s+(\w+)'
tasks:
  filenames: [Taskfile]
  definitions:
    - kind: function
      pattern: '^([\w-]+):'
`

func loadRulesText(t *testing.T, text string) (*Rules, error) {
	t.Helper()
	p := filepath.Join(t.TempDir(), "code-languages.yaml")
	if err := os.WriteFile(p, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
	return LoadRules(p)
}

// collectRules runs an index pass with rules and returns its results by file.
func collectRules(t *testing.T, root string, rules *Rules) map[string]FileResult {
	t.Helper()
	out := map[string]FileResult{}
	if _, err := run(context.Background(), root, nil, 2, rules, newParser, func(r FileResult) error {
		out[r.File] = r
		return nil
	}); err != nil {
		t.Fatalf("run: %v", err)
	}
	return out
}

// tclFolder is a folder indexed with tclRules.
func tclFolder(t *testing.T) map[string]FileResult {
	t.Helper()
	rules, err := loadRulesText(t, tclRules)
	if err != nil || rules == nil {
		t.Fatalf("LoadRules = %v, %v; want rules", rules, err)
	}
	root := t.TempDir()
	write(t, root, "lib/util.tcl", []byte("# helpers\nnamespace eval util {\n    proc foo {a b} {\n        return $a\n    }\n}\n"))
	write(t, root, "pkg/Other.TM", []byte("\xef\xbb\xbfproc bar {} {}\n"))
	write(t, root, "Taskfile", []byte("build:\n\tgo build\n"))
	write(t, root, "notes.txt", []byte("proc nope {} {}\n"))
	return collectRules(t, root, rules)
}

func TestRules_ValidFileIndexesItsLanguages(t *testing.T) {
	util := tclFolder(t)["lib/util.tcl"]
	want := []Symbol{
		{Name: "util", Kind: KindModule, Path: "lib/util.tcl", Line: 2, Col: 16, EndLine: 2, Signature: "namespace eval util {", Lang: "tcl"},
		{Name: "foo", Kind: KindFunction, Path: "lib/util.tcl", Line: 3, Col: 10, EndLine: 3, Signature: "proc foo {a b} {", Lang: "tcl"},
	}
	if util.Lang != "tcl" || util.NoDefinitions || len(util.Symbols) != len(want) {
		t.Fatalf("util.tcl = %+v, want lang tcl, defs, %d symbols", util, len(want))
	}
	for i, s := range util.Symbols {
		if s != want[i] {
			t.Errorf("symbol %d = %+v, want %+v", i, s, want[i])
		}
	}
	line, err := json.Marshal(util)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(line, []byte(`"defs"`)) {
		t.Errorf("a rule language's line carries defs (absent = holds definitions): %s", line)
	}
}

func TestRules_MatchByExtensionOrFileNameOnly(t *testing.T) {
	got := tclFolder(t)
	if o := got["pkg/Other.TM"]; o.Lang != "tcl" || len(o.Symbols) != 1 || o.Symbols[0].Name != "bar" || o.Symbols[0].Col != 6 {
		t.Errorf("Other.TM (upper-case extension, BOM) = %+v", o)
	}
	if tf := got["Taskfile"]; tf.Lang != "tasks" || len(tf.Symbols) != 1 || tf.Symbols[0].Name != "build" {
		t.Errorf("Taskfile (by file name) = %+v", tf)
	}
	if n := got["notes.txt"]; n.Lang != "" || len(n.Symbols) != 0 {
		t.Errorf("notes.txt (no rule claims .txt) = %+v", n)
	}
}

func TestRules_NeverOverrideABuiltInLanguage(t *testing.T) {
	// The load rejects a built-in extension or name (InvalidFileIsIgnoredWhole);
	// a shebang naming a built-in language still beats a rule's extension.
	rules, err := loadRulesText(t, `
mine:
  extensions: [.tool, .txt]
  definitions:
    - kind: function
      pattern: '(\w+)'
`)
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	write(t, root, "run.tool", []byte("#!/usr/bin/env python3\ndef main():\n    pass\n"))
	write(t, root, "plain.txt", []byte("word\n"))
	got := collectRules(t, root, rules)
	if r := got["run.tool"]; r.Lang == "mine" {
		t.Errorf("run.tool (python shebang) indexed by the rules: %+v", r)
	}
	if got["plain.txt"].Lang != "mine" {
		t.Errorf("plain.txt = %+v, want the rule language (no built-in claims .txt)", got["plain.txt"])
	}
}

func TestRules_InvalidFileIsIgnoredWhole(t *testing.T) {
	validTcl := "tcl:\n  extensions: [.tcl]\n  definitions:\n    - {kind: function, pattern: 'proc\\s+(\\w+)'}\n"
	cases := []struct {
		name, text, want string
	}{
		{"invalid YAML", "tcl: [unclosed\n", "invalid YAML"},
		{"invalid RE2", validTcl + "lisp:\n  extensions: [.el]\n  definitions:\n    - {kind: function, pattern: '(defun'}\n", "pattern"},
		{"lookbehind is not RE2", validTcl + "lisp:\n  extensions: [.el]\n  definitions:\n    - {kind: function, pattern: '(?<=defun )(\\w+)'}\n", "pattern"},
		{"kind outside the set", validTcl + "lisp:\n  extensions: [.el]\n  definitions:\n    - {kind: procedure, pattern: 'defun (\\w+)'}\n", `unknown kind "procedure"`},
		{"no group 1", validTcl + "lisp:\n  extensions: [.el]\n  definitions:\n    - {kind: function, pattern: 'defun \\w+'}\n", "no group 1"},
		{"unknown key", "tcl:\n  extension: [.tcl]\n  definitions:\n    - {kind: function, pattern: 'proc (\\w+)'}\n", "invalid YAML"},
		{"no extensions or filenames", "tcl:\n  definitions:\n    - {kind: function, pattern: 'proc (\\w+)'}\n", "no extensions"},
		{"no definitions", "tcl:\n  extensions: [.tcl]\n", "no definitions"},
		{"extension claimed twice", validTcl + "tk:\n  extensions: [.TCL]\n  definitions:\n    - {kind: function, pattern: 'proc (\\w+)'}\n", "extension .tcl is also"},
		{"not a map", "- tcl\n", "invalid YAML"},
		{"built-in extension", "mine:\n  extensions: [GO]\n  definitions:\n    - {kind: function, pattern: '(\\w+)'}\n", "extension .go is the built-in go language's"},
		{"built-in filename", "mine:\n  filenames: [dockerfile]\n  definitions:\n    - {kind: function, pattern: '(\\w+)'}\n", "filename dockerfile is the built-in"},
		{"multi-dot extension", "mine:\n  extensions: [.tar.gz]\n  definitions:\n    - {kind: function, pattern: '(\\w+)'}\n", "only the last dot counts"},
		{"filename with a slash", "mine:\n  filenames: [conf/Taskfile]\n  definitions:\n    - {kind: function, pattern: '(\\w+)'}\n", "has no slash"},
		{"built-in language id", "python:\n  extensions: [.pyx2]\n  definitions:\n    - {kind: function, pattern: '(\\w+)'}\n", "python: a built-in language of that name exists"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			rules, err := loadRulesText(t, c.text)
			if rules != nil || err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("LoadRules = %v, %v; want nil rules and an error containing %q", rules, err, c.want)
			}
			if !strings.Contains(err.Error(), "code-languages.yaml") {
				t.Errorf("error %q does not name the file", err)
			}
		})
	}
}

func TestRules_MissingOrEmptyFile(t *testing.T) {
	rules, err := LoadRules(filepath.Join(t.TempDir(), "absent.yaml"))
	if rules != nil || err != nil {
		t.Errorf("missing file: LoadRules = %v, %v; want nil, nil", rules, err)
	}
	rules, err = loadRulesText(t, "")
	if err != nil || rules.langFor("a.tcl") != nil {
		t.Errorf("empty file: LoadRules = %v, %v; want no languages and no error", rules, err)
	}
	if _, err := LoadRules(t.TempDir()); err == nil {
		t.Error("a directory as the rules file: no error")
	}
}

func TestRules_UTF16ColumnAfterANonASCIIPrefix(t *testing.T) {
	rules, err := loadRulesText(t, "tcl:\n  extensions: [.tcl]\n  definitions:\n    - {kind: function, pattern: 'proc\\s+(\\S+)'}\n")
	if err != nil {
		t.Fatal(err)
	}
	// `"😀é" ` is 1+2+1+1+1 = 6 UTF-16 units (9 bytes), `proc ` 5 more.
	syms := rules.langFor("x.tcl").symbols([]byte("\"😀é\" proc naïve {} {}\r\n"))
	if len(syms) != 1 || syms[0].Name != "naïve" || syms[0].Col != 12 || syms[0].Signature != `"😀é" proc naïve {} {}` {
		t.Errorf("symbols = %+v, want naïve at UTF-16 col 12", syms)
	}
}

func TestRules_LongLineSignatureIsClipped(t *testing.T) {
	rules, err := loadRulesText(t, "tcl:\n  extensions: [.tcl]\n  definitions:\n    - {kind: function, pattern: 'proc\\s+(\\w+)'}\n")
	if err != nil {
		t.Fatal(err)
	}
	syms := rules.langFor("x.tcl").symbols([]byte("   proc foo " + strings.Repeat("x ", 300) + "\n"))
	if len(syms) != 1 || len([]rune(syms[0].Signature)) > textLimit+1 || !strings.HasSuffix(syms[0].Signature, "…") || !strings.HasPrefix(syms[0].Signature, "proc foo x") {
		t.Errorf("signature = %q, want the trimmed line clipped to %d characters + …", syms[0].Signature, textLimit)
	}
}

func TestStream_DoneLineCarriesTheRulesError(t *testing.T) {
	root := t.TempDir()
	write(t, root, "a.md", []byte("# A\n"))
	var out bytes.Buffer
	in := strings.NewReader("a.md\n" + "a.md\n") // two runs
	if err := Serve(context.Background(), root, Options{Workers: 1, RulesErr: errors.New("x.yaml: invalid YAML")}, in, &out); err != nil {
		t.Fatalf("Serve: %v", err)
	}
	runs := streamLines(t, out.String())
	if len(runs) != 2 {
		t.Fatalf("%d runs, want 2", len(runs))
	}
	for i, r := range runs {
		if d := r[len(r)-1]; d["rules_error"] != "x.yaml: invalid YAML" {
			t.Errorf("run %d done = %v, want rules_error", i, d)
		}
	}
	out.Reset()
	if err := Stream(context.Background(), root, nil, Options{Workers: 1}, &out); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out.String(), "rules_error") {
		t.Errorf("rules_error without a rules error: %s", out.String())
	}
}

func TestRules_FirstErrorIsStable(t *testing.T) {
	text := "zeta:\n  extensions: [.zz]\n  definitions:\n    - {kind: procedure, pattern: '(\\w+)'}\n" +
		"alpha:\n  extensions: [.aa]\n  definitions:\n    - {kind: function, pattern: '(x'}\n"
	for range 20 { // map order is random: every load must name alpha
		if _, err := loadRulesText(t, text); err == nil || !strings.Contains(err.Error(), ": alpha: definitions[0]: pattern") {
			t.Fatalf("error = %v, want alpha's (languages are checked in sorted order)", err)
		}
	}
}

func TestRules_NameIsTrimmedClippedAndNeverEmpty(t *testing.T) {
	rules, err := loadRulesText(t, "tcl:\n  extensions: [.tcl]\n  definitions:\n    - {kind: function, pattern: '^proc(.*)$'}\n")
	if err != nil {
		t.Fatal(err)
	}
	src := "proc   \n" + "proc  foo  \n" + "proc " + strings.Repeat("n", 300) + "\n"
	syms := rules.langFor("x.tcl").symbols([]byte(src))
	if len(syms) != 2 {
		t.Fatalf("symbols = %+v, want 2 (an empty name is no symbol)", syms)
	}
	if syms[0].Name != "foo" || syms[0].Line != 2 || syms[0].Col != 7 {
		t.Errorf("symbol 0 = %+v, want foo at 2:7 (spaces trimmed)", syms[0])
	}
	if n := []rune(syms[1].Name); len(n) > textLimit+1 || !strings.HasSuffix(syms[1].Name, "…") {
		t.Errorf("long name has %d characters, want ≤ %d with …", len(n), textLimit+1)
	}
}
