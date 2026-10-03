package codeindex

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"maps"
	"os"
	"path"
	"regexp"
	"slices"
	"strings"
	"unicode"

	"gopkg.in/yaml.v3"
)

// Rules are the owner's regex languages from code-languages.yaml (spec
// §6.5): definitions for languages the index has no grammar or scan for.
// A rule language applies only to its own extensions and file names, and
// only to a file the language table does not know — it never overrides a
// built-in language.
type Rules struct {
	byExt, byName map[string]*ruleLang
}

// ruleLang is one language of the rules file.
type ruleLang struct {
	id   string
	defs []ruleDef
}

// ruleDef is one definition pattern: group 1 of re is the name.
type ruleDef struct {
	kind Kind
	re   *regexp.Regexp
}

// rulesFileLang is a language's entry as written in the file.
type rulesFileLang struct {
	Extensions  []string `yaml:"extensions"`
	Filenames   []string `yaml:"filenames"`
	Definitions []struct {
		Kind    string `yaml:"kind"`
		Pattern string `yaml:"pattern"`
	} `yaml:"definitions"`
}

// LoadRules reads the rules file at path. A missing file is no rules and
// no error. Any problem — unreadable, invalid YAML, an unknown key, a kind
// outside §6.1, a pattern that is not RE2 or has no group, an entry that
// could never match (a built-in language's id, extension or file name, a
// multi-dot extension, a file name with a slash) — ignores the whole
// file: nil rules and the error, never a partial load.
func LoadRules(path string) (*Rules, error) {
	data, err := os.ReadFile(path)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return nil, nil
	case err != nil:
		return nil, fmt.Errorf("reading %s: %w", path, err)
	}
	r, err := parseRules(data)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return r, nil
}

// parseRules parses and validates a rules file's contents; empty contents
// are no rules.
func parseRules(data []byte) (*Rules, error) {
	var file map[string]rulesFileLang
	dec := yaml.NewDecoder(bytes.NewReader(data))
	dec.KnownFields(true)
	if err := dec.Decode(&file); err != nil && !errors.Is(err, io.EOF) {
		return nil, fmt.Errorf("invalid YAML: %w", err)
	}
	r := &Rules{byExt: map[string]*ruleLang{}, byName: map[string]*ruleLang{}}
	for _, id := range slices.Sorted(maps.Keys(file)) { // a stable first error
		fl := file[id]
		l, err := ruleLanguage(id, fl)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", id, err)
		}
		if err := r.add(l, fl); err != nil {
			return nil, fmt.Errorf("%s: %w", id, err)
		}
	}
	return r, nil
}

// ruleLanguage validates one language's definitions.
func ruleLanguage(id string, fl rulesFileLang) (*ruleLang, error) {
	switch {
	case strings.TrimSpace(id) == "":
		return nil, errors.New("a language needs a name")
	case langByID[id] != nil:
		return nil, errors.New("a built-in language of that name exists")
	case len(fl.Extensions) == 0 && len(fl.Filenames) == 0:
		return nil, errors.New("no extensions or filenames")
	case len(fl.Definitions) == 0:
		return nil, errors.New("no definitions")
	}
	l := &ruleLang{id: id}
	for i, d := range fl.Definitions {
		if !kinds[Kind(d.Kind)] {
			return nil, fmt.Errorf("definitions[%d]: unknown kind %q", i, d.Kind)
		}
		re, err := regexp.Compile(d.Pattern)
		if err != nil {
			return nil, fmt.Errorf("definitions[%d]: pattern: %w", i, err)
		}
		if re.NumSubexp() < 1 {
			return nil, fmt.Errorf("definitions[%d]: pattern %q has no group 1 for the name", i, d.Pattern)
		}
		l.defs = append(l.defs, ruleDef{kind: Kind(d.Kind), re: re})
	}
	return l, nil
}

// add registers l under its extensions (lower-cased, a missing leading
// dot added) and exact file names. One that could never match — empty, a
// multi-dot extension, a file name with a slash, one the language table
// already claims (built-in languages win) — or one claimed by two
// languages is an error.
func (r *Rules) add(l *ruleLang, fl rulesFileLang) error {
	for _, e := range fl.Extensions {
		e = strings.ToLower(strings.TrimSpace(e))
		if !strings.HasPrefix(e, ".") {
			e = "." + e
		}
		if err := claim(r.byExt, langByExt, "extension", e, l); err != nil {
			return err
		}
	}
	for _, n := range fl.Filenames {
		if err := claim(r.byName, langByName, "filename", n, l); err != nil {
			return err
		}
	}
	return nil
}

// claim registers key (an extension or a file name) for l in m, checking
// it can match: builtin is the language table's map for the same key.
func claim(m map[string]*ruleLang, builtin map[string]*langSpec, what, key string, l *ruleLang) error {
	switch {
	case key == "" || key == ".":
		return fmt.Errorf("an empty %s", what)
	case what == "extension" && strings.Count(key, ".") > 1:
		return fmt.Errorf("extension %s: only the last dot counts, so it never matches", key)
	case strings.ContainsAny(key, "/\\"):
		return fmt.Errorf("%s %s: a file name has no slash", what, key)
	case builtin[strings.ToLower(key)] != nil:
		return fmt.Errorf("%s %s is the built-in %s language's", what, key, builtin[strings.ToLower(key)].id)
	case m[key] != nil:
		return fmt.Errorf("%s %s is also %s's", what, key, m[key].id)
	}
	m[key] = l
	return nil
}

// langFor is the rule language of rel by its file name, then extension;
// nil when none (or r is nil).
func (r *Rules) langFor(rel string) *ruleLang {
	if r == nil {
		return nil
	}
	base := path.Base(rel)
	if l := r.byName[base]; l != nil {
		return l
	}
	return r.byExt[strings.ToLower(path.Ext(base))]
}

// symbols matches every definition pattern against each line of src (a
// leading BOM already trimmed): one symbol per pattern per line, named
// by group 1 (spaces trimmed, clipped like a signature; an empty name is
// no symbol), its signature the line. Rules carry no container or doc.
func (l *ruleLang) symbols(src []byte) []Symbol {
	var out []Symbol
	for i, line := range srcLines(src) {
		for _, d := range l.defs {
			m := d.re.FindStringSubmatchIndex(line)
			if m == nil || m[2] < 0 {
				continue // no match, or group 1 unmatched
			}
			raw := line[m[2]:m[3]]
			name := clip(raw)
			if name == "" {
				continue
			}
			lead := len(raw) - len(strings.TrimLeftFunc(raw, unicode.IsSpace))
			out = append(out, Symbol{
				Name:      name,
				Kind:      d.kind,
				Line:      i + 1,
				Col:       utf16Col([]byte(line), m[2]+lead),
				EndLine:   i + 1,
				Signature: clip(line),
			})
		}
	}
	return out
}
