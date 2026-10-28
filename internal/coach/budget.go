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
// an edit; before is the destination's current text (only ~/.claude/CLAUDE.md
// scales with it). 0 means the destination is not a text with a budget (the
// allow list). The one definition: Validate and the CLI both read it.
func BudgetOf(destination, before string) int {
	switch destination {
	case DestSession, DestProcedure, DestChat:
		return instructions.MaxRunes
	case DestPromptAdd:
		return prompts.MaxAdditionRunes
	case DestClaudeMDUser:
		return claudeMDBudget(utf8.RuneCountInString(before))
	}
	return 0
}
