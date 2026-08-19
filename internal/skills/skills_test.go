package skills

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fixture writes one skill file into dir and returns its path.
func fixture(t *testing.T, dir, name, content string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("writing fixture %s: %v", name, err)
	}
	return path
}

func TestParse(t *testing.T) {
	cases := []struct {
		name        string
		file        string
		content     string
		wantErr     string // substring; "" means the parse must succeed
		wantPersona string
		wantEnabled bool
		wantBody    string
	}{
		{
			name:        "valid with explicit enabled",
			file:        "status-update",
			content:     "---\ndescription: Draft a status update.\npersona: secretary\nenabled: true\n---\nbody line\n",
			wantPersona: PersonaSecretary,
			wantEnabled: true,
			wantBody:    "body line\n",
		},
		{
			name:        "enabled defaults to true when omitted",
			file:        "thread-untangle",
			content:     "---\ndescription: Untangle.\npersona: both\n---\nbody\n",
			wantPersona: PersonaBoth,
			wantEnabled: true,
			wantBody:    "body\n",
		},
		{
			name:        "enabled false is honoured",
			file:        "quiet",
			content:     "---\ndescription: Off.\npersona: assistant\nenabled: false\n---\nbody\n",
			wantPersona: PersonaAssistant,
			wantEnabled: false,
			wantBody:    "body\n",
		},
		{
			name:        "unknown frontmatter keys are ignored",
			file:        "extra-keys",
			content:     "---\ndescription: Fine.\npersona: secretary\nwhatever: 12\nnested:\n  a: b\n---\nbody\n",
			wantPersona: PersonaSecretary,
			wantEnabled: true,
			wantBody:    "body\n",
		},
		{
			name:    "no frontmatter block",
			file:    "plain",
			content: "# Just markdown\n\nno frontmatter here\n",
			wantErr: "missing YAML frontmatter",
		},
		{
			name:    "unterminated frontmatter block",
			file:    "unterminated",
			content: "---\ndescription: Broken.\npersona: secretary\n",
			wantErr: "missing YAML frontmatter",
		},
		{
			name:    "malformed yaml",
			file:    "broken-yaml",
			content: "---\ndescription: \"unclosed\npersona: secretary\n---\nbody\n",
			wantErr: "malformed frontmatter",
		},
		{
			name:    "empty description",
			file:    "no-description",
			content: "---\ndescription: \"   \"\npersona: secretary\n---\nbody\n",
			wantErr: "description is required",
		},
		{
			name:    "missing description key",
			file:    "no-description-key",
			content: "---\npersona: secretary\n---\nbody\n",
			wantErr: "description is required",
		},
		{
			name:    "unknown persona",
			file:    "bad-persona",
			content: "---\ndescription: Fine.\npersona: butler\n---\nbody\n",
			wantErr: "unknown persona",
		},
		{
			name:    "missing persona",
			file:    "no-persona",
			content: "---\ndescription: Fine.\n---\nbody\n",
			wantErr: "persona is required",
		},
		{
			name:    "illegal name",
			file:    "Bad_Name",
			content: "---\ndescription: Fine.\npersona: secretary\n---\nbody\n",
			wantErr: "invalid skill name",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			skill, err := Parse(tc.file, tc.content)
			if tc.wantErr != "" {
				if err == nil {
					t.Fatalf("expected error containing %q, got none", tc.wantErr)
				}
				if !strings.Contains(err.Error(), tc.wantErr) {
					t.Fatalf("error %q does not contain %q", err, tc.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if skill.Name != tc.file {
				t.Errorf("name = %q, want %q", skill.Name, tc.file)
			}
			if skill.Persona != tc.wantPersona {
				t.Errorf("persona = %q, want %q", skill.Persona, tc.wantPersona)
			}
			if skill.Enabled != tc.wantEnabled {
				t.Errorf("enabled = %v, want %v", skill.Enabled, tc.wantEnabled)
			}
			if skill.Body != tc.wantBody {
				t.Errorf("body = %q, want %q", skill.Body, tc.wantBody)
			}
			if skill.Description == "" {
				t.Errorf("description must not be empty")
			}
		})
	}
}

// TestParseCRLF: a file saved with Windows line endings parses the same.
func TestParseCRLF(t *testing.T) {
	skill, err := Parse("crlf", "---\r\ndescription: Fine.\r\npersona: both\r\n---\r\nbody\r\n")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if skill.Body != "body\n" {
		t.Errorf("body = %q, want %q", skill.Body, "body\n")
	}
}

func TestValidName(t *testing.T) {
	valid := []string{"a", "a1", "status-update", "thread-untangle", "x-9-y"}
	invalid := []string{"", "-lead", "Upper", "with_underscore", "../evil", "a/b", "dot.name", " space", "évil"}
	for _, n := range valid {
		if !ValidName(n) {
			t.Errorf("ValidName(%q) = false, want true", n)
		}
	}
	for _, n := range invalid {
		if ValidName(n) {
			t.Errorf("ValidName(%q) = true, want false", n)
		}
	}
}

func TestMatchesPersona(t *testing.T) {
	both := Skill{Persona: PersonaBoth}
	sec := Skill{Persona: PersonaSecretary}
	asst := Skill{Persona: PersonaAssistant}
	if !both.MatchesPersona(PersonaSecretary) || !both.MatchesPersona(PersonaAssistant) {
		t.Errorf("a 'both' skill must match either persona")
	}
	if !sec.MatchesPersona(PersonaSecretary) || sec.MatchesPersona(PersonaAssistant) {
		t.Errorf("secretary skill matched the wrong persona")
	}
	if !asst.MatchesPersona(PersonaAssistant) || asst.MatchesPersona(PersonaSecretary) {
		t.Errorf("assistant skill matched the wrong persona")
	}
}

func TestDir(t *testing.T) {
	if got, want := Dir("/tmp/ws"), filepath.Join("/tmp/ws", "skills"); got != want {
		t.Errorf("Dir = %q, want %q", got, want)
	}
}

// TestListMissingDir: no skills directory is an empty catalog, not an error —
// the app must work before the daemon has ever deployed anything.
func TestListMissingDir(t *testing.T) {
	list, skipped, err := ListWithSkips(filepath.Join(t.TempDir(), "nope"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(list) != 0 || len(skipped) != 0 {
		t.Fatalf("expected an empty catalog, got %d skills and %d skips", len(list), len(skipped))
	}
}

func TestListEmptyDir(t *testing.T) {
	list, err := List(t.TempDir())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(list) != 0 {
		t.Fatalf("expected 0 skills, got %d", len(list))
	}
}

// TestListSortedAndSkips: valid files come back sorted by name; invalid ones
// are reported as skips instead of breaking the catalog, and non-markdown
// files (including the deploy sidecar) are ignored outright.
func TestListSortedAndSkips(t *testing.T) {
	dir := t.TempDir()
	fixture(t, dir, "zulu.md", "---\ndescription: Z.\npersona: secretary\n---\nz\n")
	fixture(t, dir, "alpha.md", "---\ndescription: A.\npersona: assistant\nenabled: false\n---\na\n")
	fixture(t, dir, "broken.md", "no frontmatter at all\n")
	fixture(t, dir, "notes.txt", "not a skill\n")
	fixture(t, dir, sidecarFile, `{"alpha":"deadbeef"}`)
	if err := os.Mkdir(filepath.Join(dir, "subdir.md"), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	list, skipped, err := ListWithSkips(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(list) != 2 {
		t.Fatalf("expected 2 skills, got %d: %+v", len(list), list)
	}
	if list[0].Name != "alpha" || list[1].Name != "zulu" {
		t.Errorf("expected sorted [alpha zulu], got [%s %s]", list[0].Name, list[1].Name)
	}
	if list[0].Enabled {
		t.Errorf("alpha must be disabled")
	}
	if list[0].Path != filepath.Join(dir, "alpha.md") {
		t.Errorf("path = %q, want the file it was read from", list[0].Path)
	}
	if len(skipped) != 1 || skipped[0].Name != "broken" {
		t.Fatalf("expected exactly the broken file to be skipped, got %+v", skipped)
	}
}

// wantListed is every testdata fixture that must parse, in the sorted order
// ListWithSkips returns. wantSkipped is every fixture that must not.
//
// These two lists ARE the dual-path contract: SkillsCatalogTests reads the same
// directory (via a #filePath-relative path) and asserts the same verdicts, so a
// parser change that makes one side stricter than the other fails here or
// there. Add a fixture for every shape whose verdict is worth pinning, and the
// description text too — a listing with the wrong text is its own bug class
// (see anchor-description below).
var (
	wantListed = []struct {
		name        string
		description string
		persona     string
		enabled     bool
	}{
		// The TWO fixtures whose verdict the two sides deliberately do not
		// share, both anchors: on a value yaml.v3 hands us `hey` rather than
		// the text on the line, and on a key it reports a key the line does
		// not spell. Swift refuses both instead of guessing —
		// SkillsCatalogTests lists them under `goListsThemSwiftRefuses`.
		// Skipping is the safe direction; listing text or keys the file does
		// not contain is not.
		{"anchor-description", "hey", PersonaSecretary, true},
		{"anchor-key", "Carries an anchor on one of its keys.", PersonaSecretary, true},
		{"enabled-comment", "Switched off with the reason written as an inline comment.", PersonaBoth, false},
		{"enabled-no", "Switched off with YAML 1.1's `no` rather than `false`.", PersonaAssistant, false},
		{"escaped-apostrophe", "Use when it's the owner's own wording that matters.", PersonaAssistant, true},
		{"quoted-key", "Written with a quoted key, which yaml.v3 unquotes.", PersonaSecretary, true},
		{"valid-basic", "Use when the owner asks for the shape of a valid skill file.", PersonaSecretary, true},
		{"valid-disabled", "A skill both personas could use, switched off by its own frontmatter.", PersonaBoth, false},
	}
	wantSkipped = []string{
		"bad-enabled",
		"bad-persona",
		"bare-line",
		"blank-description",
		"colon-in-description",
		"duplicate-key",
		"indented-fence",
		"indented-key",
		"leading-indicator",
		"no-frontmatter",
		"no-space-after-colon",
		"quoted-duplicate-key",
		"structural-key",
		"tab-indent",
		"unknown-escape",
		"unterminated-quote",
	}
)

// TestListFixtures pins the shared fixture set — the same files the Swift
// catalog parses, so both sides agree on what is listable.
func TestListFixtures(t *testing.T) {
	list, skipped, err := ListWithSkips("testdata")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(list) != len(wantListed) {
		t.Fatalf("expected %d listable fixtures, got %d: %+v", len(wantListed), len(list), list)
	}
	for i, want := range wantListed {
		got := list[i]
		if got.Name != want.name || got.Persona != want.persona ||
			got.Enabled != want.enabled || got.Description != want.description {
			t.Errorf("fixture %d = {%s %q %s enabled=%v}, want {%s %q %s enabled=%v}",
				i, got.Name, got.Description, got.Persona, got.Enabled,
				want.name, want.description, want.persona, want.enabled)
		}
	}
	if len(skipped) != len(wantSkipped) {
		t.Fatalf("expected %d skipped fixtures, got %d: %+v", len(wantSkipped), len(skipped), skipped)
	}
	for i, want := range wantSkipped {
		if skipped[i].Name != want {
			t.Errorf("skipped[%d] = %q, want %q", i, skipped[i].Name, want)
		}
	}
}

func TestLoad(t *testing.T) {
	dir := t.TempDir()
	fixture(t, dir, "alpha.md", "---\ndescription: A.\npersona: assistant\n---\nalpha body\n")

	skill, err := Load(dir, "alpha")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if skill.Body != "alpha body\n" || skill.Description != "A." {
		t.Errorf("loaded wrong skill: %+v", skill)
	}

	if _, err := Load(dir, "nope"); !errors.Is(err, ErrNotFound) {
		t.Errorf("expected ErrNotFound for an unknown name, got %v", err)
	}
	// A traversal attempt must fail on the name, before any path is built.
	for _, bad := range []string{"../evil", "a/b", "..", "Bad"} {
		if _, err := Load(dir, bad); err == nil || errors.Is(err, ErrNotFound) {
			t.Errorf("Load(%q) = %v, want an invalid-name error", bad, err)
		}
	}
}

// TestLoadTraversalNeverEscapes: the guard must reject the name outright, not
// merely fail to find a file — a real file one level up must stay unreachable.
func TestLoadTraversalNeverEscapes(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "skills")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	fixture(t, root, "secret.md", "---\ndescription: S.\npersona: secretary\n---\ntop secret\n")

	skill, err := Load(dir, "../secret")
	if err == nil {
		t.Fatalf("traversal succeeded and returned %+v", skill)
	}
	if !strings.Contains(err.Error(), "invalid skill name") {
		t.Errorf("expected an invalid-name error, got %v", err)
	}
}

// TestShippedPack: every embedded skill must itself parse, be enabled, and
// carry the shipped marker — a broken shipped file would be deployed to every
// workspace and then silently skipped by the catalog.
func TestShippedPack(t *testing.T) {
	pack := Shipped()
	want := map[string]string{
		"thread-untangle":  PersonaSecretary,
		"status-update":    PersonaSecretary,
		"target-breakdown": PersonaAssistant,
	}
	if len(pack) != len(want) {
		t.Fatalf("expected %d shipped skills, got %d", len(want), len(pack))
	}
	for _, s := range pack {
		persona, known := want[s.Name]
		if !known {
			t.Errorf("unexpected shipped skill %q", s.Name)
			continue
		}
		skill, err := Parse(s.Name, s.Content)
		if err != nil {
			t.Errorf("shipped skill %q does not parse: %v", s.Name, err)
			continue
		}
		if skill.Persona != persona {
			t.Errorf("shipped skill %q persona = %q, want %q", s.Name, skill.Persona, persona)
		}
		if !skill.Enabled {
			t.Errorf("shipped skill %q must ship enabled", s.Name)
		}
		if !skill.Shipped {
			t.Errorf("shipped skill %q must carry the %s marker", s.Name, shippedMarkerKey)
		}
		if strings.TrimSpace(skill.Body) == "" {
			t.Errorf("shipped skill %q has an empty body", s.Name)
		}
	}
}
