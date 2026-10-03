package codeindex

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"testing"

	"watchtower/internal/codewalk"
	"watchtower/internal/gitbin"
)

func write(t *testing.T, root, rel string, data []byte) {
	t.Helper()
	p := filepath.Join(root, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, data, 0o644); err != nil {
		t.Fatal(err)
	}
}

// collect runs an index pass and returns its results by file.
func collect(t *testing.T, root string, paths []string, mk func() parser) map[string]FileResult {
	t.Helper()
	if mk == nil {
		mk = newParser
	}
	out := map[string]FileResult{}
	sum, err := run(context.Background(), root, paths, 2, mk, func(r FileResult) error {
		if _, dup := out[r.File]; dup {
			t.Errorf("file %s emitted twice", r.File)
		}
		out[r.File] = r
		return nil
	})
	if err != nil {
		t.Fatalf("run: %v", err)
	}
	n := 0
	for _, r := range out {
		n += len(r.Symbols)
	}
	if sum.Files != len(out) || sum.Symbols != n {
		t.Fatalf("summary %+v, emitted %d files / %d symbols", sum, len(out), n)
	}
	return out
}

// noGrammar makes parsers that fail the test if any file reaches a
// grammar (a panic would be recovered by the run, so it reports instead).
func noGrammar(t *testing.T) func() parser {
	return func() parser { return guardParser{t} }
}

type guardParser struct{ t *testing.T }

func (g guardParser) parse(l *langSpec, _ []byte) ([]Symbol, bool, error) {
	g.t.Errorf("parsed a %s file with a grammar", l.id)
	return nil, false, nil
}
func (guardParser) close() {}

// boomParser panics on a source holding "boom" and otherwise finds one
// function; closed counts its closes.
type boomParser struct{ closed *atomic.Int32 }

func (boomParser) parse(_ *langSpec, src []byte) ([]Symbol, bool, error) {
	if i := bytes.Index(src, []byte("boom")); i >= 0 {
		_ = src[i+len(src)] // out of range, like a refiner's bug
	}
	return []Symbol{{Name: "f", Kind: KindFunction, Line: 1, Col: 1, EndLine: 1}}, true, nil
}
func (b boomParser) close() { b.closed.Add(1) }

// captureWarnings points the run's notes at a buffer for the test.
func captureWarnings(t *testing.T) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	prev := warnings
	warnings = &buf
	t.Cleanup(func() { warnings = prev })
	return &buf
}

// A parse that panics stays local (ruling R17): that file yields lang ""
// with one note, its worker gets a fresh parser, and the run goes on to
// index the rest — a full run and a named batch alike.
func TestRun_ParsePanicStaysLocal(t *testing.T) {
	root := t.TempDir()
	write(t, root, "a.go", []byte("package a // boom\n"))
	write(t, root, "b.go", []byte("package b\n"))
	write(t, root, "c.go", []byte("package c\n"))
	for _, paths := range [][]string{nil, {"a.go", "b.go", "c.go"}} {
		warned := captureWarnings(t)
		var made, closed atomic.Int32
		mk := func() parser { made.Add(1); return boomParser{&closed} }
		out := map[string]FileResult{}
		sum, err := run(context.Background(), root, paths, 1, mk, func(r FileResult) error {
			out[r.File] = r
			return nil
		})
		if err != nil {
			t.Fatalf("run(%v): %v, want the run to go on", paths, err)
		}
		if r := out["a.go"]; r.Lang != "" || len(r.Symbols) != 0 {
			t.Errorf("panicking a.go = %+v, want lang \"\" with no symbols", r)
		}
		for _, f := range []string{"b.go", "c.go"} {
			if r := out[f]; r.Lang != "go" || len(r.Symbols) != 1 {
				t.Errorf("%s = %+v, want its symbol", f, r)
			}
		}
		if sum.Files != 3 {
			t.Errorf("summary %+v, want 3 files", sum)
		}
		if w := warned.String(); strings.Count(w, "\n") != 1 || !strings.Contains(w, "a.go") || !strings.Contains(w, "panic") {
			t.Errorf("warnings = %q, want one line naming a.go's panic", w)
		}
		if made.Load() != 2 || closed.Load() != 2 {
			t.Errorf("parsers made %d, closed %d; want the panicked one replaced and both closed", made.Load(), closed.Load())
		}
	}
}

func TestLanguageFor(t *testing.T) {
	cases := []struct {
		rel, head, want string
	}{
		{"a/b/main.go", "", "go"},
		{"View.swift", "", "swift"},
		{"tool.py", "", "python"},
		{"stubs.pyi", "", "python"},
		{"pkg/BUILD.bazel", "", "python"},
		{"bin/run", "#!/usr/bin/env python3\nprint(1)\n", "python"},
		{"bin/run2", "#!/usr/bin/python3.12 -u\n", "python"},
		{"bin/run3", "#!/usr/bin/env -S python -u\n", "python"},
		{"bin/sh", "#!/bin/sh\n", "bash"},
		// A case-insensitive name hit (BUILD) loses to a shebang; the exact
		// name keeps its language, and so does a name with no shebang.
		{"scripts/build", "#!/bin/sh\nset -e\n", "bash"},
		{"pkg/BUILD", "#!/bin/sh\n", "python"},
		{"pkg/build", "", "python"},
		{"pkg/Build", "#!/usr/bin/env python3\n", "python"},
		{"bin/fish", "#!/usr/bin/env fish\n", ""},
		{"README.md", "", "markdown"},
		{"notes.MD", "", "markdown"},
		{"rules.mdc", "", "markdown"},
		{"notes.txt", "", ""},
		{"Makefile", "", ""},
		{"deploy/values.yml", "", "yaml"},
		{"Cargo.toml", "", "toml"},
		{"Pipfile", "", "toml"},
		{"package.json", "", "json"},
		{"tsconfig.jsonc", "", "json"},
		{"web/index.html", "", "html"},
		{"web/site.css", "", "css"},
		{"web/site.scss", "", "scss"},
		{"Dockerfile", "", "dockerfile"},
		{"build/dockerfile", "", "dockerfile"},
		{"web/App.vue", "", "vue"},
		{"web/App.svelte", "", "svelte"},
	}
	for _, tc := range cases {
		if got := LanguageFor(tc.rel, []byte(tc.head)); got != tc.want {
			t.Errorf("LanguageFor(%q, %q) = %q, want %q", tc.rel, tc.head, got, tc.want)
		}
	}
}

func TestFileResult_JSON(t *testing.T) {
	cases := []struct {
		res  FileResult
		want string
	}{
		{FileResult{File: "gone.go", Lang: "go", Deleted: true}, `{"file":"gone.go","deleted":true}`},
		{FileResult{File: "notes.txt"}, `{"file":"notes.txt","lang":"","symbols":[]}`},
		{FileResult{File: "dist/x.js", Skipped: true}, `{"file":"dist/x.js","lang":"","symbols":[],"skipped":true}`},
		{FileResult{File: "a.md", Lang: "markdown", Symbols: []Symbol{{
			Name: "Intro", Kind: KindModule, Path: "a.md", Line: 1, Col: 3, EndLine: 4, Signature: "# Intro", Lang: "markdown", Outline: true,
		}}}, `{"file":"a.md","lang":"markdown","symbols":[{"name":"Intro","kind":"module","path":"a.md","line":1,"col":3,"end_line":4,"container":"","signature":"# Intro","doc":"","lang":"markdown","outline":true}]}`},
	}
	for _, tc := range cases {
		got, err := json.Marshal(tc.res)
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != tc.want {
			t.Errorf("json = %s\nwant   %s", got, tc.want)
		}
	}
	// A code symbol carries no outline key at all.
	got, _ := json.Marshal(Symbol{Name: "f", Kind: KindFunction})
	if bytes.Contains(got, []byte("outline")) {
		t.Errorf("code symbol json %s has an outline key", got)
	}
}

func TestRun_FilesDeletedAndUnsupported(t *testing.T) {
	root := t.TempDir()
	write(t, root, "notes.txt", []byte("plain text\n"))
	write(t, root, "dir/keep.txt", []byte("x\n"))
	write(t, root, "big.md", append([]byte("# Big\n"), bytes.Repeat([]byte("a"), codewalk.MaxIndexBytes)...))
	write(t, root, "logo.bin", []byte("PNG\x00\x01binary"))
	got := collect(t, root, []string{"gone.go", "notes.txt", "dir", "big.md", "../outside.md", "logo.bin"}, noGrammar(t))

	if r := got["gone.go"]; !r.Deleted || r.Skipped {
		t.Errorf("gone.go = %+v, want deleted (not skipped)", r)
	}
	// A readable file of a language the build cannot index is a workbench
	// file: lang "" but not skipped (ruling R21).
	if r := got["notes.txt"]; r.Deleted || r.Skipped || r.Lang != "" || len(r.Symbols) != 0 {
		t.Errorf("notes.txt = %+v, want lang \"\", not skipped", r)
	}
	for _, f := range []string{"dir", "big.md", "../outside.md", "logo.bin"} {
		r, ok := got[f]
		if !ok || r.Deleted || !r.Skipped || r.Lang != "" || len(r.Symbols) != 0 {
			t.Errorf("%s = %+v (emitted %v), want skipped with no symbols", f, r, ok)
		}
	}
}

// A full run skips what the index must not parse: files over 2 MB (the
// walk still lists them for search) and binaries.
func TestRun_FullSkipsOversizeFiles(t *testing.T) {
	root := t.TempDir()
	write(t, root, "small.md", []byte("# Small\n"))
	write(t, root, "big.md", append([]byte("# Big\n"), bytes.Repeat([]byte("a"), codewalk.MaxIndexBytes)...))
	got := collect(t, root, nil, noGrammar(t))
	if _, ok := got["big.md"]; ok {
		t.Error("a file over MaxIndexBytes was indexed")
	}
	if r := got["small.md"]; len(r.Symbols) != 1 {
		t.Errorf("small.md = %+v", r)
	}
}

func TestRun_MarkdownHeadingsWithoutAGrammar(t *testing.T) {
	got := collect(t, "testdata/markdown", nil, noGrammar(t))
	r := got["guide.md"]
	if r.Lang != "markdown" {
		t.Fatalf("guide.md = %+v", r)
	}
	type row struct {
		name, container string
		line, col, end  int
	}
	want := []row{
		{"Guide", "", 1, 3, 15},
		{"Install 🙂", "Guide", 5, 4, 14},
		{"Options", "Install 🙂", 11, 5, 14},
		{"Use", "Guide", 15, 4, 15},
	}
	var rows []row
	for _, s := range r.Symbols {
		if s.Kind != KindModule || !s.Outline || s.Path != "guide.md" || s.Lang != "markdown" {
			t.Errorf("heading %+v: want kind module, outline, path and lang set", s)
		}
		rows = append(rows, row{s.Name, s.Container, s.Line, s.Col, s.EndLine})
	}
	if !slices.Equal(rows, want) {
		t.Fatalf("headings = %+v\nwant       %+v", rows, want)
	}
}

func TestRun_EmitErrorStopsTheRun(t *testing.T) {
	root := t.TempDir()
	for _, n := range []string{"a.md", "b.md", "c.md", "d.md"} {
		write(t, root, n, []byte("# H\n"))
	}
	boom := errors.New("stdout closed")
	calls := 0
	_, err := Run(context.Background(), root, nil, 2, func(FileResult) error {
		calls++
		return boom
	})
	if !errors.Is(err, boom) || calls != 1 {
		t.Fatalf("err = %v after %d emits, want %v after 1", err, calls, boom)
	}
}

func TestRun_CancelledContext(t *testing.T) {
	root := t.TempDir()
	write(t, root, "a.md", []byte("# H\n"))
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := Run(ctx, root, nil, 2, func(FileResult) error { return nil })
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v, want context.Canceled", err)
	}
}

func TestRun_UnreadableFolderIsAnError(t *testing.T) {
	_, err := Run(context.Background(), filepath.Join(t.TempDir(), "missing"), nil, 2, func(FileResult) error { return nil })
	if err == nil {
		t.Fatal("want an error for a missing folder")
	}
}

func TestClipAndFirstSentence(t *testing.T) {
	if got := firstSentence("Writes `text` when\n the disk holds it. Then more."); got != "Writes `text` when the disk holds it." {
		t.Errorf("firstSentence = %q", got)
	}
	if got := firstSentence("Uses v1.2 of it"); got != "Uses v1.2 of it" {
		t.Errorf("firstSentence = %q", got)
	}
	long := clip(string(bytes.Repeat([]byte("é"), 300)))
	if n := len([]rune(long)); n != textLimit {
		t.Errorf("clip kept %d characters, want %d", n, textLimit)
	}
}

// HTML, CSS, SCSS and Dockerfiles are known by name only: lang set, no
// symbols, no grammar involved; the config formats are scanned without one
// too, their keys flagged outline.
func TestRun_ScannedLanguagesNeedNoGrammar(t *testing.T) {
	root := t.TempDir()
	files := map[string][2]string{
		"web/index.html": {"html", "<script>function f() {}</script>\n<h1>Title</h1>\n"},
		"web/site.css":   {"css", ".a { color: red; }\n"},
		"web/site.scss":  {"scss", "$c: red;\n.a { .b { color: $c; } }\n"},
		"Dockerfile":     {"dockerfile", "FROM scratch AS base\nCOPY . /app\n"},
		"conf.yaml":      {"yaml", "a:\n  b: 1\n"},
		"conf.toml":      {"toml", "[a]\nb = 1\n"},
		"conf.json":      {"json", "{\"a\": {\"b\": 1}}\n"},
	}
	for rel, f := range files {
		write(t, root, rel, []byte(f[1]))
	}
	got := collect(t, root, nil, noGrammar(t))
	for rel, f := range files {
		wantScanned(t, got[rel], rel, f[0])
	}
	data, err := json.Marshal(got["web/site.css"])
	if err != nil || string(data) != `{"file":"web/site.css","lang":"css","symbols":[]}` {
		t.Errorf("css json = %s (%v)", data, err)
	}
}

// wantScanned checks a scanned file's result: its lang, and for a config
// format its one top-level key a, flagged outline.
func wantScanned(t *testing.T, r FileResult, rel, lang string) {
	t.Helper()
	want := 0
	if lang == "yaml" || lang == "toml" || lang == "json" {
		want = 1
	}
	if r.Lang != lang || len(r.Symbols) != want {
		t.Errorf("%s = %+v, want lang %s with %d symbols", rel, r, lang, want)
	}
	for _, s := range r.Symbols {
		if s.Name != "a" || !s.Outline || s.Lang != lang || s.Path != rel {
			t.Errorf("%s symbol %+v, want a, outline, lang and path set", rel, s)
		}
	}
}

// A leading UTF-8 BOM is not part of a scanned file: the first key is
// found, its name is clean, and its line-1 column is the editor's (which
// drops the BOM).
func TestRun_ScanSkipsALeadingBOM(t *testing.T) {
	root := t.TempDir()
	files := map[string]string{"a.toml": "first = 1\n", "a.yaml": "first: 1\n", "a.json": "{\"first\": 1}\n"}
	wantCol := map[string]int{"a.toml": 1, "a.yaml": 1, "a.json": 3}
	for rel, body := range files {
		write(t, root, rel, append([]byte("\xef\xbb\xbf"), body...))
	}
	got := collect(t, root, nil, noGrammar(t))
	for rel := range files {
		syms := got[rel].Symbols
		if len(syms) != 1 || syms[0].Name != "first" || syms[0].Line != 1 || syms[0].Col != wantCol[rel] {
			t.Errorf("%s = %+v, want first at 1:%d", rel, syms, wantCol[rel])
		}
	}
}

// Paths named by --files or --serve are filtered by .gitignore like the
// full run's list: an ignored file yields a skipped result, a
// tracked file under an ignore rule and an untracked kept one are indexed.
func TestRun_NamedPathsHonourGitignore(t *testing.T) {
	bin, ok := gitbin.Locate()
	if !ok {
		t.Skip("no git binary")
	}
	root := t.TempDir()
	git := func(args ...string) {
		c := exec.Command(bin, args...)
		c.Dir = root
		c.Env = append(slices.DeleteFunc(os.Environ(), func(kv string) bool {
			return strings.HasPrefix(kv, "GIT_DIR=") || strings.HasPrefix(kv, "GIT_WORK_TREE=") || strings.HasPrefix(kv, "GIT_INDEX_FILE=")
		}), "GIT_CONFIG_GLOBAL="+os.DevNull, "GIT_CONFIG_NOSYSTEM=1")
		if out, err := c.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
	}
	git("init", "-q")
	write(t, root, ".gitignore", []byte("dist/\n"))
	write(t, root, "dist/x.md", []byte("# Built\n"))
	write(t, root, "dist/tracked.md", []byte("# Tracked\n"))
	write(t, root, "docs/a.md", []byte("# Kept\n"))
	git("add", "-f", "dist/tracked.md")

	paths := []string{"dist/x.md", "dist/tracked.md", "docs/a.md"}
	got := collect(t, root, paths, noGrammar(t))
	if r := got["dist/x.md"]; r.Lang != "" || len(r.Symbols) != 0 || r.Deleted || !r.Skipped {
		t.Errorf("ignored dist/x.md = %+v, want skipped with no symbols", r)
	}
	for _, p := range []string{"dist/tracked.md", "docs/a.md"} {
		if r := got[p]; r.Lang != "markdown" || len(r.Symbols) != 1 || r.Skipped {
			t.Errorf("%s = %+v, want its heading", p, r)
		}
	}
	// The full run agrees.
	full := collect(t, root, nil, noGrammar(t))
	if _, ok := full["dist/x.md"]; ok {
		t.Error("the full run listed an ignored file")
	}
	if _, ok := full["dist/tracked.md"]; !ok {
		t.Error("the full run missed a tracked file")
	}
}

// A named path comes back exactly as it was asked for — in the result and
// in its symbols, for a file and for a deleted path alike — however it is
// spelled (ruling R16).
func TestRun_NamedPathsEchoedVerbatim(t *testing.T) {
	root := t.TempDir()
	write(t, root, "a.md", []byte("# A\n"))
	write(t, root, "docs/b.md", []byte("# B\n"))
	paths := []string{"./a.md", "docs/../docs/b.md", "./gone.md", "a.md"}
	got := collect(t, root, paths, noGrammar(t))
	if len(got) != len(paths) {
		t.Fatalf("results %v, want one per path asked", slices.Collect(maps.Keys(got)))
	}
	for _, p := range []string{"./a.md", "docs/../docs/b.md", "a.md"} {
		r := got[p]
		if r.Lang != "markdown" || len(r.Symbols) != 1 || r.Symbols[0].Path != p {
			t.Errorf("%s = %+v, want its heading with path %q", p, r, p)
		}
	}
	if r := got["./gone.md"]; !r.Deleted {
		t.Errorf("./gone.md = %+v, want deleted", r)
	}
}
