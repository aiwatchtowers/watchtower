package automations

import (
	"bytes"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"regexp"
	"slices"
	"strings"
	"sync"

	"gopkg.in/yaml.v3"

	"watchtower/internal/db"
)

// templateFS holds the gallery (spec §15): index.json and one recipe file per
// slug. A template installs one or more of those files.
//
//go:embed templates/index.json templates/*.md
var templateFS embed.FS

// TemplateParam is a value the owner gives at install time; RenderTemplate
// replaces "<Key>" with it.
type TemplateParam struct {
	Key     string `json:"key"`
	Label   string `json:"label"`
	Example string `json:"example"`
}

// Template is one gallery entry. Permissions and Outputs are its first
// recipe's frontmatter lists as written (placeholders included), for the
// gallery card.
type Template struct {
	Name        string          `json:"name"`
	Title       string          `json:"title"`
	Description string          `json:"description"`
	TriggerText string          `json:"trigger_text"`
	Scope       ScopeKind       `json:"scope"`
	Files       []string        `json:"files"`
	Params      []TemplateParam `json:"params"`
	// Notes are what the owner must know before relying on the template
	// (e.g. a trigger that does not fire yet); install-template prints them.
	Notes       []string `json:"notes"`
	Permissions []string `json:"-"`
	Outputs     []string `json:"-"`
}

// loadTemplates reads the embedded index once. The gallery is compiled in, so
// a broken index or recipe is a build defect TestTemplates_AllParseAndValidate
// catches; it panics rather than ship an empty gallery silently.
var loadTemplates = sync.OnceValue(func() []Template {
	raw, err := templateFS.ReadFile("templates/index.json")
	if err != nil {
		panic(fmt.Sprintf("automations: reading the template index: %v", err))
	}
	var out []Template
	if err := json.Unmarshal(raw, &out); err != nil {
		panic(fmt.Sprintf("automations: decoding the template index: %v", err))
	}
	for i := range out {
		t := &out[i]
		if len(t.Files) == 0 {
			panic("automations: template " + t.Name + " installs no file")
		}
		if t.Params == nil {
			t.Params = []TemplateParam{}
		}
		if t.Notes == nil {
			t.Notes = []string{}
		}
		if t.Permissions, t.Outputs, err = templateLists(t.Files[0]); err != nil {
			panic(fmt.Sprintf("automations: template %s: %v", t.Name, err))
		}
	}
	return out
})

// templateLists reads the permissions and outputs of one embedded recipe's
// frontmatter as written, without validating them.
func templateLists(slug string) (permissions, outputs []string, err error) {
	data, err := templateFS.ReadFile("templates/" + slug + ".md")
	if err != nil {
		return nil, nil, err
	}
	fm, _, err := splitFrontmatter(strings.Split(string(normaliseRecipeBytes(data)), "\n"))
	if err != nil {
		return nil, nil, err
	}
	var lists struct {
		Permissions []string `yaml:"permissions"`
		Outputs     []string `yaml:"outputs"`
	}
	if err := yaml.Unmarshal([]byte(strings.Join(fm, "\n")), &lists); err != nil {
		return nil, nil, err
	}
	if lists.Permissions == nil {
		lists.Permissions = []string{}
	}
	if lists.Outputs == nil {
		lists.Outputs = []string{}
	}
	return lists.Permissions, lists.Outputs, nil
}

// Templates is the gallery, in index order.
func Templates() []Template { return slices.Clone(loadTemplates()) }

// templateByName finds a gallery entry.
func templateByName(name string) (Template, bool) {
	all := loadTemplates()
	i := slices.IndexFunc(all, func(t Template) bool { return t.Name == name })
	if i < 0 {
		return Template{}, false
	}
	return all[i], true
}

// templateParamValue is what one --param value may hold: it lands in YAML and
// in JS strings, so anything else could break a copy. A param's value is a
// comma-separated list of such values (templateParamValues).
var templateParamValue = regexp.MustCompile(`^[A-Za-z0-9_.-]+$`)

// templateParamDefaults resolve a param the owner left out at install, so a
// one-click install (the Desktop gallery passes no --param) gives a copy
// that parses (#582).
var templateParamDefaults = map[string]func(*db.DB) (string, error){
	"PROJECT": ownerJiraProjects,
}

// HasDefault reports whether install-template fills the param by itself
// when --param leaves it out.
func (p TemplateParam) HasDefault() bool {
	_, ok := templateParamDefaults[p.Key]
	return ok
}

// ErrNoActiveJiraProject is <PROJECT>'s default finding nothing: the install
// is refused rather than writing a report on no project. Its text is what the
// Desktop gallery shows, next step included; the CLI's text output adds the
// --param hint.
// It is a sentence for the owner, not a Go-style error string.
var ErrNoActiveJiraProject error = noActiveJiraProjectError{}

type noActiveJiraProjectError struct{}

func (noActiveJiraProjectError) Error() string {
	return "This template needs a Jira project where you are the assignee or reporter of an open issue. Connect Jira, let it sync, and try again."
}

// ownerJiraProjects is <PROJECT>'s default: every active Jira project of the
// owner (db.OwnerActiveJiraProjects), comma-separated; none is
// ErrNoActiveJiraProject. A key outside the value allowlist is left out.
func ownerJiraProjects(d *db.DB) (string, error) {
	keys, err := d.OwnerActiveJiraProjects()
	if err != nil {
		return "", err
	}
	keys = slices.DeleteFunc(keys, func(k string) bool { return !templateParamValue.MatchString(k) })
	if len(keys) == 0 {
		return "", ErrNoActiveJiraProject
	}
	return strings.Join(keys, ","), nil
}

// TemplateParamValues splits a param value into its comma-separated values,
// a repeated one kept once (first place).
func TemplateParamValues(value string) []string {
	var out []string
	for _, v := range strings.Split(value, ",") {
		if !slices.Contains(out, v) {
			out = append(out, v)
		}
	}
	return out
}

// FillTemplateParams returns params plus a default for every declared param
// of template name that params leaves out and that has one
// (templateParamDefaults). Given values are kept as they are; RenderTemplate
// checks them.
func FillTemplateParams(d *db.DB, name string, params map[string]string) (map[string]string, error) {
	t, ok := templateByName(name)
	if !ok {
		return nil, fmt.Errorf("no template %q", name)
	}
	out := maps.Clone(params)
	if out == nil {
		out = map[string]string{}
	}
	for _, p := range t.Params {
		resolve, ok := templateParamDefaults[p.Key]
		if _, given := out[p.Key]; given || !ok {
			continue
		}
		value, err := resolve(d)
		if errors.Is(err, ErrNoActiveJiraProject) {
			return nil, err // already says what to do, in the gallery's words
		}
		if err != nil {
			return nil, fmt.Errorf("choosing <%s> for %s: %w", p.Key, name, err)
		}
		out[p.Key] = value
	}
	return out, nil
}

// RenderTemplate returns the recipe files of template name (slug → bytes)
// with each given param filled. A param's value is a comma-separated list
// (PROJECT=PAY,OPS): every line holding "<KEY>" is repeated once per value
// with it in place (one value: a plain replace), and "<KEY[]>" becomes the
// values as a JSON array. A param the template does not declare, or a value
// outside letters, digits, `_`, `.` and `-`, is an error naming it; a
// declared param left out keeps its placeholder, so the copy does not parse —
// install-template fills the params that have a default first
// (FillTemplateParams).
func RenderTemplate(name string, params map[string]string) (map[string][]byte, error) {
	t, ok := templateByName(name)
	if !ok {
		return nil, fmt.Errorf("no template %q", name)
	}
	keys := slices.Sorted(maps.Keys(params)) // a stable error and fill order
	for _, key := range keys {
		value := params[key]
		if !slices.ContainsFunc(t.Params, func(p TemplateParam) bool { return p.Key == key }) {
			return nil, fmt.Errorf("template %s has no param %s", name, key)
		}
		for _, v := range TemplateParamValues(value) {
			if !templateParamValue.MatchString(v) {
				return nil, fmt.Errorf("param %s: %q is not a valid value (allowed: letters, digits, _ . and -; "+
					"several values separated by commas)", key, value)
			}
		}
	}
	out := make(map[string][]byte, len(t.Files))
	for _, slug := range t.Files {
		data, err := templateFS.ReadFile("templates/" + slug + ".md")
		if err != nil {
			return nil, fmt.Errorf("template %s: %w", name, err)
		}
		for _, key := range keys {
			data = fillTemplateParam(data, key, TemplateParamValues(params[key]))
		}
		out[slug] = data
	}
	return out, nil
}

// fillTemplateParam fills one param's placeholders (see RenderTemplate).
func fillTemplateParam(data []byte, key string, values []string) []byte {
	quoted := make([]string, len(values))
	for i, v := range values {
		quoted[i] = `"` + v + `"` // the allowlist needs no escaping
	}
	data = bytes.ReplaceAll(data, []byte("<"+key+"[]>"), []byte("["+strings.Join(quoted, ", ")+"]"))
	placeholder := []byte("<" + key + ">")
	lines := bytes.SplitAfter(data, []byte("\n"))
	var out bytes.Buffer
	for _, line := range lines {
		if !bytes.Contains(line, placeholder) {
			out.Write(line)
			continue
		}
		for _, v := range values {
			out.Write(bytes.ReplaceAll(line, placeholder, []byte(v)))
		}
	}
	return out.Bytes()
}
