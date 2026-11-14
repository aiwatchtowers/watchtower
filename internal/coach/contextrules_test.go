package coach

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

// Codex spells Watchtower's servers with "_" where Claude Code uses "-";
// both spellings are protected, and the folding protects nothing else.
func TestIsProtected_ServerSpellings(t *testing.T) {
	for _, s := range []string{"watchtower-workbench", "watchtower_workbench", "watchtower"} {
		assert.True(t, IsProtected(DestMCPServerOff, s), s)
	}
	for _, s := range []string{"alpha_docs", "watchtower_workbench_extra", "watchtowerworkbench"} {
		assert.False(t, IsProtected(DestMCPServerOff, s), s)
	}
	assert.False(t, IsProtected(DestPluginOff, "watchtower_workbench"), "the folding is for servers only")
}
