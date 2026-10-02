package codeindex

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"watchtower/internal/codewalk"
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

// panicParser fails the test if any file reaches a grammar.
type panicParser struct{}

func (panicParser) parse(l *langSpec, _ []byte) ([]Symbol, bool, error) {
	panic("parsed a " + l.id + " file with a grammar")
}
func (panicParser) close() {}

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
	got := collect(t, root, []string{"gone.go", "notes.txt", "dir", "big.md", "../outside.md"}, func() parser { return panicParser{} })

	if r := got["gone.go"]; !r.Deleted {
		t.Errorf("gone.go = %+v, want deleted", r)
	}
	for _, f := range []string{"notes.txt", "dir", "big.md", "../outside.md"} {
		r, ok := got[f]
		if !ok || r.Deleted || r.Lang != "" || len(r.Symbols) != 0 {
			t.Errorf("%s = %+v (emitted %v), want lang \"\" with no symbols", f, r, ok)
		}
	}
}

// A full run skips what the index must not parse: files over 2 MB (the
// walk still lists them for search) and binaries.
func TestRun_FullSkipsOversizeFiles(t *testing.T) {
	root := t.TempDir()
	write(t, root, "small.md", []byte("# Small\n"))
	write(t, root, "big.md", append([]byte("# Big\n"), bytes.Repeat([]byte("a"), codewalk.MaxIndexBytes)...))
	got := collect(t, root, nil, func() parser { return panicParser{} })
	if _, ok := got["big.md"]; ok {
		t.Error("a file over MaxIndexBytes was indexed")
	}
	if r := got["small.md"]; len(r.Symbols) != 1 {
		t.Errorf("small.md = %+v", r)
	}
}

func TestRun_MarkdownHeadingsWithoutAGrammar(t *testing.T) {
	got := collect(t, "testdata/markdown", nil, func() parser { return panicParser{} })
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
	got := collect(t, root, nil, func() parser { return panicParser{} })
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
