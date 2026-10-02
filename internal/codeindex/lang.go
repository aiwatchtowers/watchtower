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
	// between are sibling kinds that may sit between a doc comment and
	// its definition without ending the run (Rust's #[derive]).
	between []string
	// locals are ancestor kinds that make a definition local — a
	// function's body — so it is not indexed.
	locals []string
	// heads are first-byte prefixes that name the language of a file
	// with no known name or extension (`<?php`).
	heads []string
	// docTags: the doc comment is XML (C#'s <summary>); tags are dropped.
	docTags bool
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
		between:     []string{"attribute_item"},
		docPrefixes: []string{"///", "/**"},
	},
	{
		id:           "php",
		exts:         []string{".php", ".php4", ".php5", ".phtml", ".ctp"},
		interpreters: []string{"php"},
		heads:        []string{"<?php"},
		bodies:       []string{"declaration_list", "enum_declaration_list", "compound_statement"},
		locals:       []string{"function_definition", "method_declaration", "anonymous_function", "arrow_function"},
		docPrefixes:  []string{"/**"},
	},
	{
		id:   "ruby",
		exts: []string{".rb", ".rbx", ".rjs", ".gemspec", ".podspec", ".rake", ".ru", ".jbuilder"},
		names: []string{
			"Rakefile", "Gemfile", "Podfile", "Fastfile", "Appfile", "Matchfile", "Pluginfile", "Brewfile",
			"Vagrantfile", "Guardfile", "Dangerfile", "Berksfile", "Capfile", "Thorfile",
		},
		interpreters: []string{"ruby"},
		bodies:       []string{"body_statement"},
		locals:       []string{"method", "singleton_method", "lambda", "block", "do_block"},
		docPrefixes:  []string{"#"},
		directive:    regexp.MustCompile(`^#\s*(frozen_string_literal|encoding|coding|warn_indent|shareable_constant_value|rubocop):`),
	},
	{
		id:          "java",
		exts:        []string{".java", ".jav"},
		bodies:      []string{"class_body", "interface_body", "enum_body", "annotation_type_body", "block", "constructor_body"},
		locals:      []string{"method_declaration", "constructor_declaration", "compact_constructor_declaration", "lambda_expression"},
		docPrefixes: []string{"/**"},
	},
	{
		id:          "c",
		exts:        []string{".c", ".h"},
		bodies:      []string{"compound_statement", "field_declaration_list", "enumerator_list"},
		locals:      []string{"function_definition"},
		docPrefixes: []string{"///", "/**", "//!", "/*!"},
	},
	{
		id:          "cpp",
		exts:        []string{".cpp", ".cc", ".cxx", ".hpp", ".hh", ".hxx"},
		bodies:      []string{"compound_statement", "field_declaration_list", "enumerator_list", "declaration_list"},
		wrappers:    []string{"template_declaration"},
		locals:      []string{"function_definition", "lambda_expression"},
		docPrefixes: []string{"///", "/**", "//!", "/*!"},
	},
	{
		id:          "c_sharp",
		exts:        []string{".cs", ".csx", ".cake"},
		bodies:      []string{"declaration_list", "enum_member_declaration_list", "block", "accessor_list"},
		locals:      []string{"method_declaration", "constructor_declaration", "accessor_declaration", "lambda_expression", "local_function_statement"},
		docPrefixes: []string{"///", "/**"},
		docTags:     true,
	},
	{
		id:           "lua",
		exts:         []string{".lua"},
		interpreters: []string{"lua", "luajit"},
		bodies:       []string{"block"},
		locals:       []string{"function_declaration", "function_definition"},
		docPrefixes:  []string{"---"},
	},
	jsLike("javascript", []string{".js", ".es6", ".jsx", ".mjs", ".cjs"}, []string{"jakefile"}, []string{"node", "deno", "bun"}),
	jsLike("typescript", []string{".ts", ".cts", ".mts"}, nil, nil),
	jsLike("tsx", []string{".tsx"}, nil, nil),
	{
		id:          "markdown",
		exts:        []string{".md", ".markdown", ".mdown", ".mkdn", ".mkd", ".mdwn", ".mdtxt", ".mdtext", ".mdc"},
		lineScanned: true,
	},
}

// jsLike is a JavaScript-family row: one syntax tree shape, so one set of
// body, wrapper, local and doc rules.
func jsLike(id string, exts, names, interpreters []string) langSpec {
	return langSpec{
		id: id, exts: exts, names: names, interpreters: interpreters,
		bodies:   []string{"statement_block", "class_body", "interface_body", "enum_body", "object_type"},
		wrappers: []string{"export_statement", "lexical_declaration", "variable_declaration", "ambient_declaration"},
		locals: []string{
			"function_declaration", "generator_function_declaration", "function_expression",
			"generator_function", "arrow_function", "method_definition", "class_static_block",
		},
		docPrefixes: []string{"/**"},
	}
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
			byName[strings.ToLower(n)] = l
		}
		for _, p := range l.interpreters {
			byInterpreter[p] = l
		}
	}
	return byID, byExt, byName, byInterpreter
}

// LanguageFor names the language of the file at rel (slash-separated),
// from its file name, then its extension (both case-insensitive, as
// Monaco matches them), then a shebang or a known opening in head (the
// file's first bytes). "" = not a language this table knows. It says
// nothing about whether this build has the grammar.
func LanguageFor(rel string, head []byte) string {
	if l := langFor(rel, head); l != nil {
		return l.id
	}
	return ""
}

func langFor(rel string, head []byte) *langSpec {
	base := path.Base(rel)
	if l := langByName[strings.ToLower(base)]; l != nil {
		return l
	}
	if l := langByExt[strings.ToLower(path.Ext(base))]; l != nil {
		return l
	}
	if l := langByInterpreter[interpreter(head)]; l != nil {
		return l
	}
	for i := range languages {
		for _, h := range languages[i].heads {
			if bytes.HasPrefix(head, []byte(h)) {
				return &languages[i]
			}
		}
	}
	return nil
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
