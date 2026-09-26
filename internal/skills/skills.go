// Package skills is the assistant-skill catalog: one markdown file per skill
// in <workspace>/skills, loadable on demand by the assistant during a Discuss
// chat.
//
// The file is the single source of truth — identity is the filename stem, and
// everything else (description, enable toggle) lives in the file's YAML
// frontmatter, so Go and Swift always agree without a DB or a defaults store.
// Parsing is strict on what matters (a skill with no description is skipped,
// never listed, never loadable) and lenient elsewhere (unknown frontmatter
// keys are ignored, the memory-vault Obsidian precedent — including the
// `persona` key files from the two-persona era still carry).
package skills

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// fileExt is the one extension the catalog reads; anything else in the
// directory is ignored outright (never listed, never a parse error).
const fileExt = ".md"

// shippedMarkerKey is stamped in the frontmatter of every skill we ship, so a
// reader can label origin (shipped vs. owner-written) from the file alone,
// without consulting the deploy sidecar. It is an ordinary unknown key to any
// parser that does not care about it.
const shippedMarkerKey = "x-watchtower-shipped"

// namePattern is a skill's identity: the filename stem, and the only value
// load_skill will ever join onto a path (the traversal guard).
var namePattern = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*$`)

// ErrNotFound is returned by Load when no skill file with that name exists.
var ErrNotFound = errors.New("skill not found")

// Skill is one parsed, valid skill file.
type Skill struct {
	// Name is the filename stem — the skill's identity.
	Name string
	// Description tells the model when to load this skill.
	Description string
	// Enabled defaults to true when the frontmatter omits it.
	Enabled bool
	// Shipped is true when the file carries our shipped marker.
	Shipped bool
	// Body is everything after the frontmatter block.
	Body string
	// Path is the file the skill was read from.
	Path string
}

// Skipped records one file the catalog refused to list, so a caller can log it
// (one bad file must never break the catalog).
type Skipped struct {
	Name   string
	Path   string
	Reason string
}

// frontmatter is the strict subset of keys the catalog understands. Enabled is
// a pointer so an omitted key can default to true rather than to false.
type frontmatter struct {
	Description string `yaml:"description"`
	Enabled     *bool  `yaml:"enabled"`
	Shipped     string `yaml:"x-watchtower-shipped"`
}

// ValidName reports whether name is a legal skill identity. Every path join in
// this package (and in the load_skill MCP tool) is gated on it, so a name can
// never escape the skills directory.
func ValidName(name string) bool { return namePattern.MatchString(name) }

// Dir is the skills directory for a workspace.
func Dir(workspaceDir string) string { return filepath.Join(workspaceDir, "skills") }

// List returns every valid skill in dir, sorted by name. A missing directory
// is an empty catalog, not an error. Invalid files are skipped silently — use
// ListWithSkips when the caller can report them.
func List(dir string) ([]Skill, error) {
	list, _, err := ListWithSkips(dir)
	return list, err
}

// ListWithSkips is List plus the files it refused, each with a reason.
func ListWithSkips(dir string) ([]Skill, []Skipped, error) {
	entries, err := os.ReadDir(dir)
	if os.IsNotExist(err) {
		return nil, nil, nil
	}
	if err != nil {
		return nil, nil, fmt.Errorf("reading skills directory: %w", err)
	}

	var out []Skill
	var skipped []Skipped
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), fileExt) {
			continue
		}
		name := strings.TrimSuffix(e.Name(), fileExt)
		path := filepath.Join(dir, e.Name())
		content, err := os.ReadFile(path)
		if err != nil {
			skipped = append(skipped, Skipped{Name: name, Path: path, Reason: err.Error()})
			continue
		}
		skill, err := Parse(name, string(content))
		if err != nil {
			skipped = append(skipped, Skipped{Name: name, Path: path, Reason: err.Error()})
			continue
		}
		skill.Path = path
		out = append(out, skill)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	sort.Slice(skipped, func(i, j int) bool { return skipped[i].Name < skipped[j].Name })
	return out, skipped, nil
}

// Load reads one skill by name. The name is validated before any path is
// built, so a traversal attempt fails without touching the filesystem.
func Load(dir, name string) (Skill, error) {
	if !ValidName(name) {
		return Skill{}, fmt.Errorf("invalid skill name %q: must match %s", name, namePattern)
	}
	path := filepath.Join(dir, name+fileExt)
	content, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return Skill{}, fmt.Errorf("%w: %s", ErrNotFound, name)
	}
	if err != nil {
		return Skill{}, fmt.Errorf("reading skill %s: %w", name, err)
	}
	skill, err := Parse(name, string(content))
	if err != nil {
		return Skill{}, err
	}
	skill.Path = path
	return skill, nil
}

// Parse turns one file's name and content into a Skill, or returns the reason
// it is not listable. Everything it rejects is a hard requirement: a legal
// name, a frontmatter block, a non-empty description.
func Parse(name, content string) (Skill, error) {
	if !ValidName(name) {
		return Skill{}, fmt.Errorf("invalid skill name %q: must match %s", name, namePattern)
	}
	head, body, ok := splitFrontmatter(content)
	if !ok {
		return Skill{}, errors.New("missing YAML frontmatter block")
	}
	var fm frontmatter
	if err := yaml.Unmarshal([]byte(head), &fm); err != nil {
		return Skill{}, fmt.Errorf("malformed frontmatter: %w", err)
	}
	description := strings.TrimSpace(fm.Description)
	if description == "" {
		return Skill{}, errors.New("description is required")
	}
	enabled := true
	if fm.Enabled != nil {
		enabled = *fm.Enabled
	}
	return Skill{
		Name:        name,
		Description: description,
		Enabled:     enabled,
		Shipped:     strings.TrimSpace(fm.Shipped) != "",
		Body:        body,
	}, nil
}

// splitFrontmatter separates a leading "---" delimited YAML block from the
// body. Line-based rather than substring-based so a "---" inside the body (a
// markdown horizontal rule) can never be mistaken for the closing delimiter of
// a block that never opened.
func splitFrontmatter(content string) (head, body string, ok bool) {
	normalized := strings.ReplaceAll(content, "\r\n", "\n")
	if !strings.HasPrefix(normalized, "---\n") {
		return "", "", false
	}
	lines := strings.Split(normalized[len("---\n"):], "\n")
	for i, line := range lines {
		if strings.TrimRight(line, " \t") == "---" {
			return strings.Join(lines[:i], "\n"), strings.Join(lines[i+1:], "\n"), true
		}
	}
	return "", "", false
}
