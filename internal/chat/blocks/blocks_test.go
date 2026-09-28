package blocks

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestLinkingRules_MapsEachConnectedAccount(t *testing.T) {
	out := LinkingRules([]SlackTeam{
		{AccountID: 1, TeamID: "T111", Name: "Acme"},
		{AccountID: 2, TeamID: "T222", Name: "Partner org"},
	}, "T111")
	assert.Contains(t, out, "- account 1 → team_id T111 (Acme)")
	assert.Contains(t, out, "- account 2 → team_id T222 (Partner org)")
	assert.Contains(t, out, "An id without a prefix uses team_id T111.")
	assert.Contains(t, out, "slack://channel?team=T111&id=C123&message=1740577800.000100", "example uses the first team")
	assert.Contains(t, out, `prefer the hit's "link"`)
	assert.Contains(t, out, "chunk_anchor")
}

func TestLinkingRules_SingleLegacyTeam(t *testing.T) {
	out := LinkingRules(nil, "T001")
	assert.Contains(t, out, "team_id: T001")
	assert.NotContains(t, out, "account 1 →")
	assert.Contains(t, out, "deep link")
}

func TestLinkingRules_NoTeamAtAll(t *testing.T) {
	out := LinkingRules(nil, "")
	assert.Contains(t, out, "omit Slack deep links")
	assert.Contains(t, out, "team=T0000000", "the example still renders with a placeholder id")
}

// The CLI prompt test forbids "!" and "<>" (sanitized-input check), so the
// shared text must never contain them.
func TestSharedBlocks_HaveNoForbiddenCharacters(t *testing.T) {
	for _, s := range []string{ToolsList, DataAccessRules, Workflow, LinkingRules(nil, "T1")} {
		assert.False(t, strings.ContainsAny(s, "!<>"), s)
	}
}
