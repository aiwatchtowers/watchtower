package codeindex

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// association is one language's extensions and file names, as Monaco or
// languages.js registers them.
type association struct {
	Extensions []string `json:"extensions"`
	Filenames  []string `json:"filenames"`
}

// monacoIDs maps an editor language id to the index's, where they differ.
var monacoIDs = map[string]string{"csharp": "c_sharp"}

// associationExceptions are the editor associations the index maps
// differently on purpose, with why.
var associationExceptions = map[string]string{
	// Monaco's typescript also highlights .tsx; the index parses TSX with
	// its own grammar.
	".tsx": "tsx",
	// languages.js borrows Java's highlighter for Groovy; Groovy is not
	// Java to a parser.
	".groovy": "", ".gradle": "", ".gvy": "", "Jenkinsfile": "",
	// Monaco gives .pp to both Pascal and Ruby (Puppet manifests); neither
	// parses as Ruby.
	".pp": "",
	// A compiled Rust library, not source.
	".rlib": "",
}

func monacoAssociations(t *testing.T) map[string]association {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("testdata", "monaco-languages.json"))
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Languages map[string]association `json:"languages"`
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatal(err)
	}
	return doc.Languages
}

var (
	jsEntry  = regexp.MustCompile(`(?s)\{\s*id:\s*"([^"]+)"(.*?)\}`)
	jsArray  = func(key string) *regexp.Regexp { return regexp.MustCompile(`(?s)\b` + key + `:\s*\[(.*?)\]`) }
	jsExts   = jsArray("extensions")
	jsNames  = jsArray("filenames")
	jsString = regexp.MustCompile(`"([^"]*)"`)
)

// languagesJSAssociations reads the associations list of the code
// viewer's languages.js.
func languagesJSAssociations(t *testing.T) map[string]association {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "WatchtowerDesktop", "Sources", "CodeEditorWeb", "languages.js"))
	if err != nil {
		t.Fatal(err)
	}
	src := string(data)
	start := strings.Index(src, "var associations = [")
	end := strings.Index(src[max(start, 0):], "];")
	if start < 0 || end < 0 {
		t.Fatal("languages.js has no associations list")
	}
	strs := func(re *regexp.Regexp, body string) []string {
		var out []string
		if m := re.FindStringSubmatch(body); m != nil {
			for _, s := range jsString.FindAllStringSubmatch(m[1], -1) {
				out = append(out, s[1])
			}
		}
		return out
	}
	out := map[string]association{}
	for _, m := range jsEntry.FindAllStringSubmatch(src[start:start+end], -1) {
		out[m[1]] = association{Extensions: strs(jsExts, m[2]), Filenames: strs(jsNames, m[2])}
	}
	if len(out) == 0 {
		t.Fatal("no associations read from languages.js")
	}
	return out
}

// Every extension and file name Monaco or languages.js maps to a language
// the index knows maps to the same language here (spec §6.3).
func TestLanguageFor_MatchesTheEditor(t *testing.T) {
	checked := 0
	for source, assocs := range map[string]map[string]association{
		"monaco": monacoAssociations(t), "languages.js": languagesJSAssociations(t),
	} {
		for editorID, a := range assocs {
			id := editorID
			if mapped, ok := monacoIDs[editorID]; ok {
				id = mapped
			}
			if langByID[id] == nil {
				continue // not indexed (yet)
			}
			check := func(key, rel string) {
				want := id
				if exc, ok := associationExceptions[key]; ok {
					want = exc
				}
				checked++
				if got := LanguageFor(rel, nil); got != want {
					t.Errorf("%s maps %s to %s; LanguageFor(%q) = %q, want %q", source, key, editorID, rel, got, want)
				}
			}
			for _, e := range a.Extensions {
				check(e, "dir/file"+e)
			}
			for _, n := range a.Filenames {
				check(n, "dir/"+n)
			}
		}
	}
	if checked < 50 {
		t.Errorf("only %d associations checked", checked)
	}
}

// The first-line rules of Monaco and languages.js, for files with no
// telling name: shebangs and PHP's opening tag.
func TestLanguageFor_FirstLines(t *testing.T) {
	for head, want := range map[string]string{
		"#!/usr/bin/env node\n":         "javascript",
		"#!/usr/bin/env -S deno run\n":  "javascript",
		"#!/usr/local/bin/bun\n":        "javascript",
		"#!/usr/bin/env ruby\n":         "ruby",
		"#!/usr/bin/php\n":              "php",
		"<?php\necho 1;\n":              "php",
		"#!/usr/bin/env python3\n":      "python",
		"#!/usr/bin/env lua5.4\n":       "lua",
		"#!/usr/bin/env Rscript\n":      "r",
		"#!/usr/bin/env elixir\n":       "elixir",
		"#!/usr/bin/env scala\n":        "scala",
		"<?xml version=\"1.0\"?>\n<a/>": "",
	} {
		if got := LanguageFor("bin/tool", []byte(head)); got != want {
			t.Errorf("LanguageFor(bin/tool, %q) = %q, want %q", head, got, want)
		}
	}
	// A known name or extension wins over the first line.
	if got := LanguageFor("notes.md", []byte("<?php\n")); got != "markdown" {
		t.Errorf("notes.md with a <?php head = %q", got)
	}
}
