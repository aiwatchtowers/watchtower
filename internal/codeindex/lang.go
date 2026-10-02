package codeindex

import (
	"bytes"
	"path"
	"regexp"
	"strings"
)

// langSpec is one language: how a file is recognised, and how its
// signatures and doc comments are cut out of the syntax tree.
type langSpec struct {
	id string
	// exts are lower-case extensions with the dot; names are exact file
	// names; interpreters are shebang program names (version suffix
	// stripped: python3.12 → python).
	exts, names, interpreters []string
	// bodies are the node kinds that open a definition's body: the
	// signature stops where the first of them starts.
	bodies []string
	// wrappers are parent kinds a definition is read through for its
	// signature and doc (Go's `type X struct`, Python's decorators).
	wrappers []string
	// docPrefixes are the comment openers that make a comment a doc
	// comment; none means comments are never docs.
	docPrefixes []string
	// directive matches a comment that is a tool directive (Go's
	// //go:generate), skipped when collecting a doc.
	directive *regexp.Regexp
	// docstring: the first statement string of a body is the doc (Python).
	docstring bool
	// lineScanned languages are indexed without a grammar (Markdown).
	lineScanned bool
}

// languages is the language table. Associations mirror Monaco's built-ins
// and WatchtowerDesktop/Sources/CodeEditorWeb/languages.js for each
// language indexed here.
var languages = []langSpec{
	{
		id:          "go",
		exts:        []string{".go"},
		bodies:      []string{"block", "field_declaration_list"},
		wrappers:    []string{"type_declaration", "const_declaration", "var_declaration"},
		docPrefixes: []string{"//"},
		directive:   regexp.MustCompile(`^//(line |extern |export |[a-z0-9]+:[a-z0-9])`),
	},
	{
		id:          "swift",
		exts:        []string{".swift"},
		bodies:      []string{"class_body", "enum_class_body", "protocol_body", "function_body", "computed_property"},
		docPrefixes: []string{"///", "/**"},
	},
	{
		id:   "python",
		exts: []string{".py", ".rpy", ".pyw", ".cpy", ".gyp", ".gypi", ".pyi", ".bzl", ".star"},
		names: []string{
			"BUILD", "BUILD.bazel", "WORKSPACE", "WORKSPACE.bazel", "SConstruct", "SConscript", "Snakefile",
		},
		interpreters: []string{"python"},
		bodies:       []string{"block"},
		wrappers:     []string{"decorated_definition"},
		docstring:    true,
	},
	{
		id:          "rust",
		exts:        []string{".rs"},
		bodies:      []string{"block", "field_declaration_list", "declaration_list", "enum_variant_list"},
		docPrefixes: []string{"///", "/**"},
	},
	{
		id:          "markdown",
		exts:        []string{".md", ".markdown", ".mdown", ".mkdn", ".mkd", ".mdwn", ".mdtxt", ".mdtext", ".mdc"},
		lineScanned: true,
	},
}

var langByID, langByExt, langByName, langByInterpreter = indexLanguages()

func indexLanguages() (byID, byExt, byName, byInterpreter map[string]*langSpec) {
	byID, byExt, byName, byInterpreter = map[string]*langSpec{}, map[string]*langSpec{}, map[string]*langSpec{}, map[string]*langSpec{}
	for i := range languages {
		l := &languages[i]
		byID[l.id] = l
		for _, e := range l.exts {
			byExt[e] = l
		}
		for _, n := range l.names {
			byName[n] = l
		}
		for _, p := range l.interpreters {
			byInterpreter[p] = l
		}
	}
	return byID, byExt, byName, byInterpreter
}

// LanguageFor names the language of the file at rel (slash-separated),
// from its exact file name, then its extension, then a shebang in head
// (the file's first bytes). "" = not a language this table knows. It says
// nothing about whether this build has the grammar.
func LanguageFor(rel string, head []byte) string {
	if l := langFor(rel, head); l != nil {
		return l.id
	}
	return ""
}

func langFor(rel string, head []byte) *langSpec {
	base := path.Base(rel)
	if l := langByName[base]; l != nil {
		return l
	}
	if l := langByExt[strings.ToLower(path.Ext(base))]; l != nil {
		return l
	}
	return langByInterpreter[interpreter(head)]
}

// interpreter is the program a `#!` first line runs, through env, with any
// version suffix dropped: "#!/usr/bin/env python3.12 -u" → "python".
func interpreter(head []byte) string {
	if !bytes.HasPrefix(head, []byte("#!")) {
		return ""
	}
	line, _, _ := bytes.Cut(head[2:], []byte("\n"))
	fields := strings.Fields(string(line))
	if len(fields) == 0 {
		return ""
	}
	prog := path.Base(fields[0])
	if prog == "env" {
		prog = ""
		for _, f := range fields[1:] {
			if !strings.HasPrefix(f, "-") && !strings.Contains(f, "=") {
				prog = path.Base(f)
				break
			}
		}
	}
	return strings.TrimRight(prog, "0123456789.")
}
