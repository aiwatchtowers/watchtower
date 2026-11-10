package coach

import (
	"path/filepath"
	"unicode/utf8"

	"watchtower/internal/instructions"
	"watchtower/internal/prompts"
)

// LockPath is the file both the daemon's weekly pass and `coach run` hold
// (flock) while they judge and propose, so the two never run at once.
func LockPath(workspaceDir string) string { return filepath.Join(workspaceDir, "coach.lock") }

// BudgetOf is the most runes a text of the given destination may hold after
// an edit; before is the destination's current text (CLAUDE.md, AGENTS.md
// and the user skills scale with it). 0 means the destination is not a text
// with a budget (the allow lists). The one definition: Validate and the CLI both read it.
func BudgetOf(destination, before string) int {
	switch destination {
	case DestSession, DestProcedure, DestChat:
		return instructions.MaxRunes
	case DestPromptAdd:
		return prompts.MaxAdditionRunes
	case DestClaudeMDUser, DestCodexAgentsMDUser:
		return claudeMDBudget(utf8.RuneCountInString(before))
	case DestClaudeSkillUser, DestCodexSkillUser:
		return skillBudget(utf8.RuneCountInString(before))
	case DestPackOverlay:
		return packOverlayMaxRunes
	}
	return 0
}

const (
	// skillGrowth is how many runes one edit may add to a skill file.
	skillGrowth = 2000
	// skillMaxRunes is the ceiling the coach's edits never push a skill past;
	// a skill at or over it may only stay the same size or shrink.
	skillMaxRunes = 20000
	// packOverlayMaxRunes is the most runes one pack skill's overlay may hold.
	packOverlayMaxRunes = 1000
)

// skillBudget is the most runes an edit may leave in a skill of n runes:
// n + skillGrowth, capped at skillMaxRunes; a skill at or over the ceiling
// keeps n.
func skillBudget(n int) int {
	if n >= skillMaxRunes {
		return n
	}
	return min(n+skillGrowth, skillMaxRunes)
}
