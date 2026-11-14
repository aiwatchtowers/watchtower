package coach

import (
	"slices"
	"strings"

	"watchtower/internal/devpack"
)

// The context proposer's thresholds (spec C4), tunable constants rather than
// settings.
const (
	// ctxUnusedMinTokens is the least start weight of a source worth a
	// proposal.
	ctxUnusedMinTokens = 500
	// ctxWindowDays is the window a source's calls are counted in.
	ctxWindowDays = 30
	// ctxClaudeMDMinBytes is the CLAUDE.md size a restructure starts at,
	// with a "## " section of at least ctxClaudeMDSectionMinBytes.
	ctxClaudeMDMinBytes        = 20 * 1024
	ctxClaudeMDSectionMinBytes = 8 * 1024
	// ctxMemoryIndexMinBytes is the memory index size a cleanup starts at.
	ctxMemoryIndexMinBytes = 8 * 1024
)

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
