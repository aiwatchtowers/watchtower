package codeindex

import (
	"slices"
	"testing"
)

// outlineRow is the part of an outline symbol these tests pin.
type outlineRow struct {
	name           string
	line, col, end int
}

func outlineRows(t *testing.T, syms []Symbol) []outlineRow {
	t.Helper()
	var rows []outlineRow
	for _, s := range syms {
		if s.Kind != KindField || !s.Outline || s.Container != "" {
			t.Errorf("%+v: want a top-level field flagged outline", s)
		}
		rows = append(rows, outlineRow{s.Name, s.Line, s.Col, s.EndLine})
	}
	return rows
}

func wantRows(t *testing.T, syms []Symbol, want []outlineRow) {
	t.Helper()
	if got := outlineRows(t, syms); !slices.Equal(got, want) {
		t.Errorf("rows = %+v\nwant   %+v", got, want)
	}
}

// Top-level keys only: nested mapping keys, sequence items, block scalar
// lines and a document that is one scalar are not keys; quoted keys are
// unquoted, and every document of the file is read.
func TestYAMLKeys(t *testing.T) {
	src := "# Doc for a.\na: 1\nb:\n  nested: 2\n  deeper:\n    x: 3\n\"q k\": 4\n'it''s': 5\n" +
		"url: http://example.com/a:b\ntext: |\n  c: not a key\nhttp://x\n- item\n  y: 6\n" +
		"#c: commented\n---\nd: 7\n--- >\ne: folded text\n...\nf: 8\n"
	wantRows(t, yamlKeys([]byte(src)), []outlineRow{
		{"a", 2, 1, 2}, {"b", 3, 1, 6}, {"q k", 7, 2, 7}, {"it's", 8, 2, 8}, {"url", 9, 1, 9},
		{"text", 10, 1, 11}, {"d", 17, 1, 17}, {"f", 21, 1, 21},
	})
	if d := yamlKeys([]byte(src))[0].Doc; d != "Doc for a." {
		t.Errorf("a doc = %q", d)
	}
	for _, line := range []string{"- a: 1", "? complex", "[a, b]: 1", "&anchor a: 1", "!!str a: 1", "%YAML 1.2", "a:b", "a # b: c", ": x"} {
		if _, _, ok := yamlKey(line); ok {
			t.Errorf("yamlKey(%q) read a key", line)
		}
	}
}

// Keys before the first table and each table header, by first segment;
// what multi-line strings and arrays hold is not read as keys or tables.
func TestTOMLKeys(t *testing.T) {
	src := "a = 1\nb.c = 2\nb.d = 3\ns = '''\nfake = 1\n[fake]\n'''\narr = [\n  { x = 1 },\n]\n" +
		"t = { y = [1,\n 2] }\n# trailing \"\"\" in a comment\nz = \"a # not a comment\"\n" +
		"[tbl]\nk = 1\n[tbl.sub]\nk2 = 2\n[other]\n[tbl.late]\n[[arr2]]\n[[arr2]]\nlast = '''x'''\n[ 'lit.key' ]\n"
	wantRows(t, tomlKeys([]byte(src)), []outlineRow{
		{"a", 1, 1, 1}, {"b", 2, 1, 3}, {"s", 4, 1, 7}, {"arr", 8, 1, 10}, {"t", 11, 1, 12},
		{"z", 14, 1, 14}, {"tbl", 15, 2, 18}, {"other", 19, 2, 19}, {"arr2", 21, 3, 23}, {"lit.key", 24, 4, 24},
	})
}

// The keys of the top-level object only, nesting and strings respected,
// JSONC comments skipped; a top-level array lists none.
func TestJSONKeys(t *testing.T) {
	src := "{\n  \"a\": {\"b\": 1, \"c\": [\"d\", {\"e\": 2}]},\n  // \"f\": 3,\n  \"g\": \"h}\\\"\",\n" +
		"  /* \"i\": 4 */ \"j\": [\n    1\n  ],\n  'k': 5, \"\\u00e9\": 6\n}\n"
	wantRows(t, jsonKeys([]byte(src)), []outlineRow{
		{"a", 2, 4, 2}, {"g", 4, 4, 4}, {"j", 5, 17, 7}, {"k", 8, 4, 8}, {"é", 8, 12, 8},
	})
	for _, src := range []string{`["a", "b", {"c": 1}]`, `"scalar"`, ``, `{`, `{"a"`} {
		syms := jsonKeys([]byte(src))
		if src == `{"a"` {
			wantRows(t, syms, []outlineRow{{"a", 1, 3, 1}})
		} else if len(syms) != 0 {
			t.Errorf("jsonKeys(%q) = %+v, want none", src, syms)
		}
	}
}

// Vue and Svelte are parsed as their <script> blocks' language: TypeScript
// for lang="ts", TSX for lang="tsx", else JavaScript; everything outside
// the blocks is blanked with newlines kept.
func TestScriptHost(t *testing.T) {
	for src, want := range map[string]string{
		"<template/>\n<script>\nlet a\n</script>":                  "javascript",
		"<script setup lang=\"ts\">\nlet a: number\n</script>":     "typescript",
		"<script>\n</script>\n<script setup lang='ts'>\n</script>": "typescript",
		"<script lang=\"tsx\">\n</script>":                         "tsx",
		"<SCRIPT Lang=TypeScript>\n</SCRIPT>":                      "typescript",
		"<script context=\"module\" lang=\"js\">\n</script>":       "javascript",
		"<p>no script</p>": "javascript",
		"<scripts lang=\"ts\">\n</scripts>\n<script>let a</script>": "javascript",
	} {
		if got := scriptHost([]byte(src)).id; got != want {
			t.Errorf("scriptHost(%q) = %s, want %s", src, got, want)
		}
	}
	src := "<p>é</p>\n<script lang=\"ts\">\nlet a = 1\n</script>\n<b>x</b>\n"
	masked := string(scriptHost([]byte(src)).mask([]byte(src)))
	if want := "         \n                  \nlet a = 1\n         \n        \n"; masked != want || len(masked) != len(src) {
		t.Errorf("masked = %q\nwant     %q", masked, want)
	}
	if langByID["typescript"].mask != nil {
		t.Error("scriptHost changed the shared TypeScript row")
	}
}
