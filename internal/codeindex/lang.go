package codeindex

import (
	"bytes"
	"path"
	"regexp"
	"slices"
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
	// bodySibling is the node kind that holds a definition's body as its
	// next sibling (Dart's function_body), joined into the definition's
	// span.
	bodySibling string
	// locals are ancestor kinds that make a definition local — a
	// function's body — so it is not indexed.
	locals []string
	// heads are first-byte prefixes that name the language of a file
	// with no known name or extension (`<?php`).
	heads []string
	// leads are the kinds of a definition's leading children its
	// signature starts after (GraphQL's description string).
	leads []string
	// mask rewrites a file before it is parsed, keeping its length and
	// newlines (every position unchanged), around a construct the grammar
	// cannot parse (SQLite triggers); symbol text is still read from the
	// file itself.
	mask func(src []byte) []byte
	// docMarkup matches a doc comment's markup, dropped from the doc (C#'s
	// XML tags, Erlang's @doc).
	docMarkup *regexp.Regexp
	// docstring: the first statement string of a body is the doc (Python).
	docstring bool
	// scan indexes the language without a grammar (Markdown headings,
	// config files' top-level keys; noSymbols for a language named only).
	scan func(src []byte) []Symbol
	// scripts: the file's `<script>` blocks are parsed with the JavaScript
	// or TypeScript grammar (Vue, Svelte; scriptHost).
	scripts bool
}

// holdsDefinitions reports whether the language's entries can be code
// definitions: a language indexed by a scan instead of a grammar (markup,
// styles, config: headings and keys at most) never holds one (ruling R32).
func (l *langSpec) holdsDefinitions() bool { return l.scan == nil }

// xmlTag is an XML doc comment's markup: `<summary>`, `<see cref="X"/>`.
var xmlTag = regexp.MustCompile(`</?[A-Za-z][^>]*>`)

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
		docMarkup:   xmlTag,
	},
	{
		id:           "lua",
		exts:         []string{".lua"},
		interpreters: []string{"lua", "luajit"},
		bodies:       []string{"block"},
		locals:       []string{"function_declaration", "function_definition"},
		docPrefixes:  []string{"---"},
	},
	{
		id:           "scala",
		exts:         []string{".scala", ".sc", ".sbt"},
		interpreters: []string{"scala"},
		bodies:       []string{"template_body", "block", "enum_body"},
		locals:       []string{"function_definition", "lambda_expression"},
		docPrefixes:  []string{"/**"},
	},
	{
		id:          "dart",
		exts:        []string{".dart"},
		bodies:      []string{"class_body", "enum_body", "extension_body", "function_body"},
		wrappers:    []string{"static_final_declaration_list"},
		between:     []string{"annotation", "const_builtin", "final_builtin"},
		bodySibling: "function_body",
		locals:      []string{"function_body", "function_expression"},
		docPrefixes: []string{"///", "/**"},
	},
	{
		id:           "elixir",
		exts:         []string{".ex", ".exs"},
		interpreters: []string{"elixir"},
		bodies:       []string{"do_block"},
	},
	{
		id:          "elm",
		exts:        []string{".elm"},
		between:     []string{"type_annotation"},
		docPrefixes: []string{"{-|"},
	},
	{
		id:          "ocaml",
		exts:        []string{".ml"},
		bodies:      []string{"structure", "signature", "object_expression", "record_declaration", "variant_declaration"},
		wrappers:    []string{"value_definition", "type_definition", "module_definition", "class_definition", "class_type_definition"},
		docPrefixes: []string{"(**"},
	},
	{
		id:           "r",
		exts:         []string{".r", ".rhistory", ".rmd", ".rprofile", ".rt"},
		interpreters: []string{"Rscript"},
		bodies:       []string{"braced_expression"},
		docPrefixes:  []string{"#'"},
	},
	{
		id:     "kotlin",
		exts:   []string{".kt", ".kts"},
		bodies: []string{"class_body", "enum_class_body", "function_body"},
		locals: []string{
			"function_body", "lambda_literal", "anonymous_initializer", "getter", "setter",
			"secondary_constructor", "object_literal",
		},
		docPrefixes: []string{"/**"},
	},
	{
		id:   "bash",
		exts: []string{".sh", ".bash", ".zsh", ".ksh", ".command"},
		names: []string{
			".zshrc", ".zprofile", ".zshenv", ".zlogin", ".zlogout", ".bashrc", ".bash_profile",
			".bash_aliases", ".bash_logout", ".profile", ".envrc", "pre-commit", "pre-push", "commit-msg",
			"prepare-commit-msg", "post-commit", "post-merge", "post-checkout", "pre-rebase", "gradlew",
		},
		interpreters: []string{"sh", "bash", "zsh", "ksh", "dash"},
		bodies:       []string{"compound_statement", "subshell"},
		locals:       []string{"function_definition"},
		docPrefixes:  []string{"#"},
		directive:    regexp.MustCompile(`^#(!|\s*shellcheck\s)`),
	},
	{
		id:          "sql",
		exts:        []string{".sql", ".ddl", ".dml", ".psql", ".pgsql"},
		bodies:      []string{"column_definitions", "create_query", "function_body"},
		wrappers:    []string{"statement"},
		docPrefixes: []string{"--"},
		directive:   regexp.MustCompile(`^--\s*\+goose\b`),
		mask:        maskSQLiteTriggers,
	},
	{
		id:          "hcl",
		exts:        []string{".tf", ".tfvars", ".hcl", ".nomad"},
		bodies:      []string{"block_start"},
		docPrefixes: []string{"#", "//", "/*"},
	},
	{
		id:          "proto",
		exts:        []string{".proto"},
		bodies:      []string{"message_body", "enum_body"},
		docPrefixes: []string{"//", "/*"},
	},
	{
		id:   "graphql",
		exts: []string{".graphql", ".gql"},
		bodies: []string{
			"fields_definition", "enum_values_definition", "input_fields_definition", "selection_set",
		},
		leads: []string{"description"},
	},
	{
		id:     "groovy",
		exts:   []string{".groovy", ".gradle", ".gvy"},
		names:  []string{"Jenkinsfile"},
		bodies: []string{"closure"},
		locals: []string{"function_definition"},
		mask:   maskGroovy,
	},
	{
		id:          "objc",
		exts:        []string{".m", ".mm"},
		bodies:      []string{"compound_statement", "field_declaration_list", "enumerator_list", "instance_variables"},
		wrappers:    []string{"type_definition"},
		locals:      []string{"function_definition", "method_definition"},
		docPrefixes: []string{"///", "/**", "//!", "/*!"},
		mask:        maskObjC,
	},
	{
		id:          "zig",
		exts:        []string{".zig"},
		bodies:      []string{"block", "struct_declaration", "enum_declaration", "union_declaration", "opaque_declaration"},
		locals:      []string{"function_declaration", "test_declaration", "comptime_declaration"},
		docPrefixes: []string{"///"},
	},
	{
		id:   "haskell",
		exts: []string{".hs"},
		// A Haddock comment inside a definition (before a class's
		// declarations) ends its signature like a body.
		bodies: []string{"match", "class_declarations", "data_constructors", "fields", "haddock"},
	},
	{
		id:           "erlang",
		exts:         []string{".erl", ".hrl"},
		interpreters: []string{"escript"},
		bodies:       []string{"clause_body"},
		between:      []string{"spec"},
		docPrefixes:  []string{"%%"},
		docMarkup:    regexp.MustCompile(`@doc\b`),
	},
	{
		id:          "clojure",
		exts:        []string{".clj", ".cljs", ".cljc", ".edn"},
		docPrefixes: []string{";;"},
	},
	{
		id:           "perl",
		exts:         []string{".pl", ".pm"},
		interpreters: []string{"perl"},
		bodies:       []string{"block"},
		locals:       []string{"subroutine_declaration_statement", "anonymous_subroutine_expression"},
		docPrefixes:  []string{"#"},
		directive:    regexp.MustCompile(`^#!`),
	},
	{
		id:           "julia",
		exts:         []string{".jl"},
		interpreters: []string{"julia"},
		locals:       []string{"function_definition", "macro_definition", "let_statement"},
	},
	{
		id:   "nim",
		exts: []string{".nim", ".nims"},
		// A type's `##` doc opens its body: the signature ends there.
		bodies: []string{"statement_list", "field_declaration_list", "documentation_comment"},
		locals: []string{
			"proc_declaration", "func_declaration", "method_declaration", "iterator_declaration",
			"converter_declaration", "template_declaration", "macro_declaration",
		},
	},
	jsLike("javascript", []string{".js", ".es6", ".jsx", ".mjs", ".cjs"}, []string{"jakefile"}, []string{"node", "deno", "bun"}),
	jsLike("typescript", []string{".ts", ".cts", ".mts"}, nil, nil),
	jsLike("tsx", []string{".tsx"}, nil, nil),
	{
		id:   "markdown",
		exts: []string{".md", ".markdown", ".mdown", ".mkdn", ".mkd", ".mdwn", ".mdtxt", ".mdtext", ".mdc"},
		scan: markdownHeadings,
	},
	{
		id:   "yaml",
		exts: []string{".yaml", ".yml", ".clang-format", ".clang-tidy", ".yamllint", ".cff"},
		scan: yamlKeys,
	},
	{
		id:    "toml",
		exts:  []string{".toml"},
		names: []string{"Cargo.lock", "Pipfile", "poetry.lock", "uv.lock", "Gopkg.lock"},
		scan:  tomlKeys,
	},
	{
		id: "json",
		exts: []string{
			".json", ".bowerrc", ".jshintrc", ".jscsrc", ".eslintrc", ".babelrc", ".har", ".jsonc", ".json5",
			".jsonl", ".ndjson", ".webmanifest", ".code-workspace", ".resolved", ".prettierrc", ".swcrc", ".map",
		},
		names: []string{"composer.lock", "Pipfile.lock", "flake.lock", ".watchmanconfig"},
		scan:  jsonKeys,
	},
	{
		id: "html",
		exts: []string{
			".html", ".htm", ".shtml", ".xhtml", ".mdoc", ".jsp", ".asp", ".aspx", ".jshtm", ".astro", ".ejs",
		},
		scan: noSymbols,
	},
	{id: "css", exts: []string{".css"}, scan: noSymbols},
	{id: "scss", exts: []string{".scss"}, scan: noSymbols},
	{
		id:    "dockerfile",
		exts:  []string{".dockerfile"},
		names: []string{"Dockerfile", "Containerfile"},
		scan:  noSymbols,
	},
	{id: "vue", exts: []string{".vue"}, scripts: true},
	{id: "svelte", exts: []string{".svelte"}, scripts: true},
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
// file's first bytes); a shebang beats a name that matches only in
// another case. "" = not a language this table knows. It says
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
		// A name that matches only case-insensitively (a script `build`,
		// not Bazel's BUILD) yields to a shebang naming another language.
		if sh := langByInterpreter[interpreter(head)]; sh != nil && sh != l && !slices.Contains(l.names, base) {
			return sh
		}
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
