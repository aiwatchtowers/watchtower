package devpack

import (
	"strings"
	"testing"
)

func TestSkillsShipWithValidFrontmatter(t *testing.T) {
	skills := Skills()
	if len(skills) != 4 {
		t.Fatalf("expected 4 skills, got %d", len(skills))
	}
	want := map[string]bool{
		"watchtower-task-context":  true,
		"watchtower-who-to-ask":    true,
		"watchtower-whats-changed": true,
		"watchtower-why-decision":  true,
	}
	for _, s := range skills {
		if !want[s.Name] {
			t.Fatalf("unexpected skill %q", s.Name)
		}
		if !strings.HasPrefix(s.Content, "---\n") {
			t.Fatalf("%s: SKILL.md must open with YAML frontmatter", s.Name)
		}
		for _, field := range []string{"name:", "description:", MarkerKey + ":"} {
			if !strings.Contains(s.Content, field) {
				t.Fatalf("%s: frontmatter missing %q", s.Name, field)
			}
		}
		if !strings.Contains(s.Content, "name: "+s.Name) {
			t.Fatalf("%s: frontmatter name must match the directory name", s.Name)
		}
		if len(s.SHA256) != 64 {
			t.Fatalf("%s: expected a hex sha256, got %q", s.Name, s.SHA256)
		}
	}
}

func TestSkillsAreSortedAndStable(t *testing.T) {
	a, b := Skills(), Skills()
	for i := range a {
		if a[i].SHA256 != b[i].SHA256 || a[i].Name != b[i].Name {
			t.Fatalf("Skills() is not deterministic at index %d", i)
		}
		if i > 0 && a[i-1].Name >= a[i].Name {
			t.Fatalf("Skills() must be sorted by name")
		}
	}
}
