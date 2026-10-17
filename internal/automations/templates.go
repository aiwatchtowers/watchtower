package automations

import (
	"bytes"
	"embed"
	"encoding/json"
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

// templateParamValue is what a --param value may hold: it lands in YAML and
// in JS strings, so anything else could break a copy. A lone `*` is the
// "every one" scope (jira:read@*), which a template's script reads as such.
var templateParamValue = regexp.MustCompile(`^(\*|[A-Za-z0-9_.-]+)$`)

// templateParamDefaults resolve a param the owner left out at install, so a
// one-click install (the Desktop gallery passes no --param) gives a copy
// that parses (#582).
var templateParamDefaults = map[string]func(*db.DB) (string, error){
	"PROJECT": ownerJiraProject,
}

// HasDefault reports whether install-template fills the param by itself
// when --param leaves it out.
func (p TemplateParam) HasDefault() bool {
	_, ok := templateParamDefaults[p.Key]
	return ok
}

// ownerJiraProject is <PROJECT>'s default: the owner's one active Jira
// project (db.OwnerActiveJiraProjects), else "*" — a report across every
// synced project, which the owner narrows later in the editor.
func ownerJiraProject(d *db.DB) (string, error) {
	owner, err := d.ResolveOwner()
	if err != nil {
		return "", err
	}
	keys, err := d.OwnerActiveJiraProjects(owner.JiraAccountID)
	if err != nil {
		return "", err
	}
	if len(keys) == 1 && templateParamValue.MatchString(keys[0]) {
		return keys[0], nil
	}
	return "*", nil
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
		if err != nil {
			return nil, fmt.Errorf("choosing <%s> for %s: %w", p.Key, name, err)
		}
		out[p.Key] = value
	}
	return out, nil
}

// RenderTemplate returns the recipe files of template name (slug → bytes)
// with each given param's "<KEY>" placeholder replaced. A param the template
// does not declare, or a value outside letters, digits, `_`, `.` and `-`
// (or a lone `*`), is an error naming it; a declared param left out keeps its
// placeholder, so the copy does not parse — install-template fills the
// params that have a default first (FillTemplateParams).
func RenderTemplate(name string, params map[string]string) (map[string][]byte, error) {
	t, ok := templateByName(name)
	if !ok {
		return nil, fmt.Errorf("no template %q", name)
	}
	for key, value := range params {
		if !slices.ContainsFunc(t.Params, func(p TemplateParam) bool { return p.Key == key }) {
			return nil, fmt.Errorf("template %s has no param %s", name, key)
		}
		if !templateParamValue.MatchString(value) {
			return nil, fmt.Errorf("param %s: %q is not a valid value (allowed: letters, digits, _ . and -, or * alone)", key, value)
		}
	}
	out := make(map[string][]byte, len(t.Files))
	for _, slug := range t.Files {
		data, err := templateFS.ReadFile("templates/" + slug + ".md")
		if err != nil {
			return nil, fmt.Errorf("template %s: %w", name, err)
		}
		for key, value := range params {
			data = bytes.ReplaceAll(data, []byte("<"+key+">"), []byte(value))
		}
		out[slug] = data
	}
	return out, nil
}
