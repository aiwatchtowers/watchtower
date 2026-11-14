package coach

import (
	"regexp"
	"testing"

	"github.com/stretchr/testify/assert"

	"watchtower/internal/agentreport"
	"watchtower/internal/db"
)

func restructureClaudeMD() db.CoachProposal {
	return db.CoachProposal{ID: 7, Kind: "restructure", Destination: DestRepoClaudeMD, WorkbenchID: 3,
		Title: "Slim CLAUDE.md", Why: "CLAUDE.md is 24 KB and every session reads it.", Metric: "start_tokens",
		Evidence: []db.CoachEvidence{{Kind: "section", Ref: "## Build & Test · 9.1 KB"},
			{Kind: "section", Ref: "## Database & Migrations · 8.4 KB"}}}
}

func memoryRestructure() db.CoachProposal {
	return db.CoachProposal{ID: 9, Kind: "restructure", Destination: DestMemoryIndex, WorkbenchID: 3,
		SourceKey: "memory", Title: "Archive stale memory lines", Why: "The memory index is 11 KB.",
		Metric: "start_tokens", BeforeText: memIndex,
		Evidence: []db.CoachEvidence{{Kind: "source", Ref: "MEMORY.md · 11.0 KB"}}}
}

func TestBrief_RepoRestructure(t *testing.T) {
	title, prompt := Brief(restructureClaudeMD(), agentreport.English)
	assert.Contains(t, title, "Slim CLAUDE.md")
	for _, want := range []string{"## Build & Test · 9.1 KB", "## Database & Migrations · 8.4 KB",
		"CLAUDE.md is 24 KB and every session reads it.", "own worktree", "pre-PR review", "open a PR", "do not merge",
		"#7"} {
		assert.Contains(t, prompt, want)
	}
	assert.NotContains(t, prompt, "ask_owner", "a repository change ends in a PR, not an owner review")
}

func TestBrief_RepoReplaceCarriesTheText(t *testing.T) {
	p := db.CoachProposal{ID: 4, Kind: "replace", Destination: DestRepoClaudeSkill, Skill: "release", WorkbenchID: 3,
		Title: "Tag first", Why: "Asked twice.", Metric: "corrections", BeforeText: "Old.\n", AfterText: "Tag first.\n"}
	_, prompt := Brief(p, agentreport.English)
	assert.Contains(t, prompt, ".claude/skills/release/SKILL.md")
	assert.Contains(t, prompt, "Tag first.\n")
	assert.Contains(t, prompt, "open a PR")
}

func TestBrief_Memory(t *testing.T) {
	title, prompt := Brief(memoryRestructure(), agentreport.English)
	assert.Contains(t, title, "Archive stale memory lines")
	for _, want := range []string{"MEMORY.md · 11.0 KB", "The memory index is 11 KB.", "ask_owner", "kind review",
		"write no backup files", "Watchtower keeps the old index", "archive"} {
		assert.Contains(t, prompt, want)
	}
	assert.NotContains(t, prompt, "open a PR", "the memory is not in a repository")
}

func TestBrief_Russian(t *testing.T) {
	_, prompt := Brief(memoryRestructure(), agentreport.Russian)
	assert.Contains(t, prompt, "ask_owner")
	assert.Contains(t, prompt, "MEMORY.md · 11.0 KB")
	assert.Regexp(t, regexp.MustCompile(`[а-я]`), prompt)
}

// A brief is built from the proposal alone: no path, home folder, settings
// file or other configuration reaches it.
func TestBrief_NoConfigValues(t *testing.T) {
	absPath := regexp.MustCompile(`(^|[\s(\x60"'])(/[A-Za-z]|~/)`)
	for _, p := range []db.CoachProposal{restructureClaudeMD(), memoryRestructure()} {
		for _, lang := range []agentreport.Lang{agentreport.English, agentreport.Russian} {
			title, prompt := Brief(p, lang)
			for _, s := range []string{title, prompt} {
				assert.NotRegexp(t, absPath, s)
				for _, bad := range []string{"settings.json", ".claude.json", "token", "workspace"} {
					assert.NotContains(t, s, bad)
				}
			}
		}
	}
	_, prompt := RevertBrief(restructureClaudeMD(), 42, agentreport.English)
	assert.NotRegexp(t, absPath, prompt)
}

func TestBrief_Revert(t *testing.T) {
	title, prompt := RevertBrief(restructureClaudeMD(), 42, agentreport.English)
	assert.Contains(t, title, "Revert")
	assert.Contains(t, prompt, "PR #42")
	assert.Contains(t, prompt, "revert PR")
	assert.Contains(t, prompt, "do not merge")
	assert.Contains(t, prompt, "own worktree")
	assert.Contains(t, prompt, "#7")

	_, ru := RevertBrief(restructureClaudeMD(), 42, agentreport.Russian)
	assert.Contains(t, ru, "PR #42")
}
