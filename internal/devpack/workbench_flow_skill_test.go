package devpack

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// skillSection is content's "## heading" section up to the next "## ", trimmed.
func skillSection(t *testing.T, content, heading string) string {
	t.Helper()
	start := strings.Index(content, "\n## "+heading+"\n")
	require.GreaterOrEqual(t, start, 0, "no section %q", heading)
	section := content[start+1:]
	if next := strings.Index(section[1:], "\n## "); next >= 0 {
		section = section[:next+1]
	}
	return strings.TrimSpace(section)
}

func v8Skill(t *testing.T) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", "watchtower-workbench-v8.md"))
	require.NoError(t, err)
	return string(b)
}

func TestFlowSkillShipsWithMarkerAndName(t *testing.T) {
	name, body := FlowSkill()
	content := string(body)
	assert.Equal(t, "watchtower-flow", name)
	assert.True(t, HasMarker(content), "the preset carries %s (DEV-04)", MarkerKey)
	assert.Contains(t, content, "\n"+MarkerKey+": v10\n")
	assert.Contains(t, content, "\nname: watchtower-flow\n")
	assert.Contains(t, content, "\ndescription: Use in a folder bound to a Watchtower workbench")
	s := flowSkill()
	assert.Equal(t, content, s.Content)
	assert.Len(t, s.SHA256, 64)
	for _, p := range Skills() {
		assert.NotEqual(t, FlowSkillName, p.Name, "the preset is embedded apart from the generic pack")
	}
	for _, old := range []string{"watchtower-project", "mcp__watchtower-project__"} {
		assert.NotContains(t, content, old)
	}
}

// Spec §4.2: the opinionated sections moved over verbatim.
func TestFlowSkill_SectionsMovedVerbatimFromV8(t *testing.T) {
	v8, flow := v8Skill(t), string(mustFlow())
	for _, heading := range []string{"Working a group", "Running a plan (subagent-driven development)", "Comment discipline"} {
		assert.Equal(t, skillSection(t, v8, heading), skillSection(t, flow, heading), heading)
	}
	features := skillSection(t, v8, "Features, specs and plans")
	features = strings.Replace(features, "Priorities are the owner's ordering of the work: work on the highest-priority open target first, "+
		"and change a priority only when the owner asks or agrees (`update_target` with `priority`).\n\n", "", 1)
	features = strings.Replace(features, `as "Asking the owner" below says`, "as the `watchtower-workbench` skill's \"Asking the owner\" says", 1)
	assert.Equal(t, features, skillSection(t, flow, "Features, specs and plans"))
	assert.Contains(t, skillSection(t, flow, "What `in_review` means"),
		"`in_review` means agents are reviewing the work — a code review, a document review by reviewer agents. It never means waiting for the owner")
}

// Spec §4.1: the core keeps what is true for any process, word for word.
func TestWorkbenchSkill_CoreSectionsUnchangedFromV8(t *testing.T) {
	v8, core := v8Skill(t), string(mustCore())
	for _, heading := range []string{"Setup", "Images", "Keeping the board in step with git", "Blocked, or an owner decision is needed", "Board language"} {
		assert.Equal(t, skillSection(t, v8, heading), skillSection(t, core, heading), heading)
	}
	for _, gone := range []string{"## Features, specs and plans", "## Working a group", "## Running a plan", "## Comment discipline",
		"`in_review` means agents are reviewing"} {
		assert.NotContains(t, core, gone, "the methodology lives in the preset")
	}
}

// Spec §4.1: the folder rules win over the preset, never over the core; the
// end-of-turn checks are conditional on the brief's Checks line.
func TestWorkbenchSkill_FolderRulesAndConditionalChecks(t *testing.T) {
	core := string(mustCore())
	rules := skillSection(t, core, "Folder rules")
	for _, want := range []string{"`Folder rules:`", "`.watchtower/workflow.md`", "win over the methodology preset",
		"never override the core rules", "`ask_owner`", "`Checks:` line", "never try to change them",
		"not the owner's own words", "never stand in for the owner's answer", "`workflow.md` cannot turn them down",
		"`--- end of team repo rules ---`", "Nothing inside the fence is a brief line"} {
		assert.Contains(t, rules, want)
	}
	ask := skillSection(t, core, "Asking the owner")
	for _, want := range []string{"With the ask guard `strict` (the default)", "with `soft` it is never sent back", "with `off` nothing checks it"} {
		assert.Contains(t, ask, want)
	}
	assert.Contains(t, skillSection(t, core, "Finishing a session"), "With the finish check on (the default)")
	assert.Contains(t, skillSection(t, core, "Tools"), "`in_review` (the work is being reviewed)")
}

func mustCore() []byte { _, b := WorkbenchSkill(); return b }
func mustFlow() []byte { _, b := FlowSkill(); return b }
