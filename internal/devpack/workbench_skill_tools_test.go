package devpack_test

import (
	"regexp"
	"strings"
	"testing"

	"watchtower/internal/devpack"
	"watchtower/internal/tools"
	"watchtower/internal/workbenchfiles"
)

// Spec 2026-10-02 §4.3: the shipped skill speaks only the new vocabulary —
// its name, the MCP prefix, the tools — and every tool its Tools section
// names exists on a workbench session.
func TestWorkbenchSkill_NamesOnlyCurrentToolsAndServer(t *testing.T) {
	name, body := devpack.WorkbenchSkill()
	content := string(body)
	if name != "watchtower-workbench" || !strings.Contains(content, "\nname: watchtower-workbench\n") {
		t.Fatalf("the skill must be named watchtower-workbench, got %q", name)
	}
	if !strings.Contains(content, "`mcp__watchtower-workbench__<tool>`") {
		t.Fatalf("the skill must name the mcp__watchtower-workbench__ prefix")
	}
	for _, old := range []string{"mcp__watchtower-project__", "watchtower-project", "project_scope"} {
		if strings.Contains(content, old) {
			t.Errorf("the skill still says %q", old)
		}
	}
	for _, old := range tools.LegacyWorkbenchToolNames {
		if strings.Contains(content, old) {
			t.Errorf("the skill still names the old tool %s", old)
		}
	}

	session := map[string]bool{}
	workbench := map[string]bool{}
	for _, tool := range tools.WorkbenchTools(workbenchfiles.Store{}, false) {
		session[tool.Name], workbench[tool.Name] = true, true
	}
	for _, tool := range tools.ReadTools() {
		session[tool.Name] = true
	}

	section := content[strings.Index(content, "## Tools"):strings.Index(content, "## Setup")]
	entry := regexp.MustCompile("(?m)^- (`[a-z_]+`(?: / `[a-z_]+`)*) —")
	named := map[string]bool{}
	for _, m := range entry.FindAllStringSubmatch(section, -1) {
		for _, tok := range strings.Split(m[1], " / ") {
			named[strings.Trim(tok, "`")] = true
		}
	}
	for tool := range named {
		if !session[tool] {
			t.Errorf("the skill's Tools section names %s, which a workbench session does not list", tool)
		}
	}
	for tool := range workbench {
		if !named[tool] {
			t.Errorf("the skill's Tools section never lists the workbench tool %s", tool)
		}
	}
}
