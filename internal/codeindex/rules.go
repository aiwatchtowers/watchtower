package codeindex

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"regexp"
	"strings"

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
// outside §6.1, a pattern that is not RE2 or has no group — ignores the
// whole file: nil rules and the error, never a partial load.
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
	for id, fl := range file {
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
// dot added) and exact file names; one claimed by two languages is an
// error.
func (r *Rules) add(l *ruleLang, fl rulesFileLang) error {
	for _, e := range fl.Extensions {
		e = strings.ToLower(strings.TrimSpace(e))
		if e != "" && !strings.HasPrefix(e, ".") {
			e = "." + e
		}
		if len(e) < 2 {
			return errors.New("an empty extension")
		}
		if o := r.byExt[e]; o != nil {
			return fmt.Errorf("extension %s is also %s's", e, o.id)
		}
		r.byExt[e] = l
	}
	for _, n := range fl.Filenames {
		if n == "" {
			return errors.New("an empty filename")
		}
		if o := r.byName[n]; o != nil {
			return fmt.Errorf("filename %s is also %s's", n, o.id)
		}
		r.byName[n] = l
	}
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
// by group 1, its signature the line. Rules carry no container or doc.
func (l *ruleLang) symbols(src []byte) []Symbol {
	var out []Symbol
	for i, line := range srcLines(src) {
		for _, d := range l.defs {
			m := d.re.FindStringSubmatchIndex(line)
			if m == nil || m[2] < 0 || m[2] == m[3] {
				continue // no match, or group 1 empty or unmatched
			}
			out = append(out, Symbol{
				Name:      line[m[2]:m[3]],
				Kind:      d.kind,
				Line:      i + 1,
				Col:       utf16Col([]byte(line), m[2]),
				EndLine:   i + 1,
				Signature: clip(line),
			})
		}
	}
	return out
}
