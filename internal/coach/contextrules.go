package coach

import (
	"slices"
	"strings"

	"watchtower/internal/devpack"
)

// The context proposer's thresholds (spec C4: the least start weight, the
// 30-day window, the CLAUDE.md and memory index sizes) join this file with
// the proposer that reads them; an unused constant fails the lint.

var (
	// protectedServers are Watchtower's own MCP servers: the workbench
	// sessions and the chat need them.
	protectedServers = []string{"watchtower-workbench", "watchtower"}
	// protectedPlugins are the plugins a Watchtower skill depends on, by name
	// (any marketplace): the workflow skills (superpowers) and the review
	// skills' agents (pr-review-toolkit). TestCOACH01_ProtectedCoversSkillDependencies
	// keeps this list in step with what .claude/skills and the pack name.
	protectedPlugins = []string{"superpowers", "pr-review-toolkit"}
)

// IsProtected reports whether a context proposal of destination for
// sourceKey would touch Watchtower itself: one of its MCP servers, a plugin a
// Watchtower skill depends on, or a skill of the Watchtower pack. Such a
// proposal is never filed, and Accept of a hand-made row naming one is
// refused (COACH-01). A plugin is matched by its name, the part of
// "<name>@<marketplace>" before the "@".
func IsProtected(destination, sourceKey string) bool {
	if sourceKey == "" {
		return false
	}
	if slices.Contains(devpack.PackSkillNames(), sourceKey) {
		return true
	}
	switch destination {
	case DestMCPServerOff:
		return slices.Contains(protectedServers, sourceKey)
	case DestPluginOff:
		name, _, _ := strings.Cut(sourceKey, "@")
		return slices.Contains(protectedPlugins, name)
	}
	return false
}
