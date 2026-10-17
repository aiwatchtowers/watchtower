package authoring_test

import (
	"regexp"
	"strings"
	"testing"

	"watchtower/internal/automations"
	"watchtower/internal/skills"
)

func createAutomationBody(t *testing.T) string {
	t.Helper()
	for _, s := range skills.Shipped() {
		if s.Name != "create-automation" {
			continue
		}
		skill, err := skills.Parse(s.Name, s.Content)
		if err != nil {
			t.Fatalf("create-automation does not parse: %v", err)
		}
		return skill.Body
	}
	t.Fatal("create-automation is not in the shipped pack")
	return ""
}

// markdownBlocks returns the content of every fenced block whose info string
// is "markdown" (the outer fence is longer than the js fence it contains).
func markdownBlocks(body string) []string {
	var out, cur []string
	fence := ""
	for line := range strings.SplitSeq(body, "\n") {
		if fence == "" {
			if m := regexp.MustCompile("^(`{4,})markdown$").FindStringSubmatch(line); m != nil {
				fence, cur = m[1], nil
			}
			continue
		}
		if line == fence {
			out = append(out, strings.Join(cur, "\n")+"\n")
			fence = ""
			continue
		}
		cur = append(cur, line)
	}
	return out
}

var workbenchKeys = regexp.MustCompile(`(?m)^\s*-\s*(shell|session|ask):`)

func TestCreateAutomationSkill_ExamplesParse(t *testing.T) {
	blocks := markdownBlocks(createAutomationBody(t))
	// The format sketch plus the five templates.
	if len(blocks) < 6 {
		t.Fatalf("expected at least 6 markdown examples, found %d", len(blocks))
	}
	for i, block := range blocks {
		text := strings.ReplaceAll(block, "<PROJECT>", "ACME")
		scope := automations.Scope{Kind: automations.ScopePersonal}
		if workbenchKeys.MatchString(text) {
			scope = automations.Scope{Kind: automations.ScopeWorkbench, WorkbenchID: 1}
		}
		if _, err := automations.ParseRecipe("example", []byte(text), scope); err != nil {
			t.Errorf("example %d (%s) does not parse: %v\n%s", i+1, scope, err, text)
		}
	}
}

func TestCreateAutomationSkill_NamesBothTools(t *testing.T) {
	body := createAutomationBody(t)
	for _, want := range []string{"draft_automation", "save_automation", "before `save_automation`"} {
		if !strings.Contains(body, want) {
			t.Errorf("skill body does not contain %q", want)
		}
	}
}
