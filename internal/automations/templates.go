package automations

import (
	"bytes"
	"embed"
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"sync"
	"unicode"

	"gopkg.in/yaml.v3"
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
	Permissions []string        `json:"-"`
	Outputs     []string        `json:"-"`
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

// RenderTemplate returns the recipe files of template name (slug → bytes)
// with each given param's "<KEY>" placeholder replaced. A param the template
// does not declare, or a value that is empty or holds whitespace, `"`, `@`,
// `<` or `>`, is an error naming it; a declared param left out keeps its
// placeholder, so the installed copy does not parse until the owner fills it.
func RenderTemplate(name string, params map[string]string) (map[string][]byte, error) {
	t, ok := templateByName(name)
	if !ok {
		return nil, fmt.Errorf("no template %q", name)
	}
	for key, value := range params {
		if !slices.ContainsFunc(t.Params, func(p TemplateParam) bool { return p.Key == key }) {
			return nil, fmt.Errorf("template %s has no param %s", name, key)
		}
		if value == "" || strings.ContainsFunc(value, unicode.IsSpace) || strings.ContainsAny(value, `"@<>`) {
			return nil, fmt.Errorf("param %s: %q is not a valid value (it must be non-empty, without whitespace, \", @, < or >)", key, value)
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
