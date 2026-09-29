package devpack

import (
	"strings"
	"testing"
)

func TestProjectSkillShipsWithMarkerAndName(t *testing.T) {
	name, body := ProjectSkill()
	if name != "watchtower-project" {
		t.Fatalf("expected the skill to be named watchtower-project, got %q", name)
	}
	content := string(body)
	if !HasMarker(content) {
		t.Fatalf("the project skill must carry %s in its frontmatter (DEV-04)", MarkerKey)
	}
	if !strings.Contains(content, "\nname: watchtower-project\n") {
		t.Fatalf("frontmatter name must match the directory name")
	}
	if !strings.Contains(content, "\ndescription: ") {
		t.Fatalf("frontmatter must carry a description")
	}
	s := projectSkill()
	if s.Name != name || s.Content != content || len(s.SHA256) != 64 {
		t.Fatalf("projectSkill() must wrap ProjectSkill() with a hex sha256, got %+v", s)
	}
}

// The generic pack is what plain `integrate claude-code` installs into
// ~/.claude/skills. The project skill only makes sense inside a bound
// folder, so it must never leak into it.
func TestProjectSkillIsNotInTheGenericPack(t *testing.T) {
	for _, s := range Skills() {
		if s.Name == ProjectSkillName {
			t.Fatalf("%s must be embedded separately from the generic pack", ProjectSkillName)
		}
	}
}

func TestProjectSkillTeachesEveryProjectTool(t *testing.T) {
	_, body := ProjectSkill()
	content := string(body)
	for _, tool := range []string{
		"project_info", "project_board", "update_project",
		"add_project_source", "remove_project_source",
		"create_targets", "update_target", "attach_document",
		"list_comments", "add_comment", "resolve_comment",
	} {
		if !strings.Contains(content, "`"+tool+"`") {
			t.Fatalf("the skill never names the %s tool", tool)
		}
	}
}

// Spec §5: every flow the skill must teach, pinned by a phrase from it.
func TestProjectSkillTeachesEveryFlow(t *testing.T) {
	_, body := ProjectSkill()
	content := string(body)
	for _, phrase := range []string{
		"## Setup",
		"empty description",              // setup trigger #2
		"Set up this Watchtower project", // setup trigger #1: the first-run prompt
		"Only after the owner agrees",    // first board created only on agreement
		"## Features, specs and plans",
		"one sub-target per plan task",
		"plan path plus the task number",
		"## Revising an attached document",
		"Before editing",
		"`attach_document` again",
		"## Running a plan",
		"verbatim into the implementer's brief",
		"After the task's review passes",
		"## Blocked, or an owner decision is needed",
		"continue with other work",
		"## Comment discipline",
		"no longer exists",
	} {
		if !strings.Contains(content, phrase) {
			t.Fatalf("the skill is missing %q", phrase)
		}
	}
}
