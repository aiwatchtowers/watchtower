package chat

import (
	"os"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// The actions contract is a Go↔Swift dual path (spec §4.1 item 4): Go owns
// the main chat's prompt, Swift's AgentToolsContract still feeds the target
// chat. Both sides compare against the SAME fixture files, so an edit to one
// copy without the other fails on the side that drifted.
func TestActionsContract_MatchesSharedFixtures(t *testing.T) {
	for _, surface := range []string{"main", "target"} {
		raw, err := os.ReadFile("testdata/actions_contract_" + surface + ".txt")
		require.NoError(t, err)
		want := strings.TrimSuffix(string(raw), "\n")
		assert.Equal(t, want, ActionsContract(surface), surface)
	}
	assert.Empty(t, ActionsContract("meeting"), "a draft-only surface gets no actions contract (AGENT-04)")
}

func TestActionsContract_ListsEveryWriteToolOfTheSurface(t *testing.T) {
	main := ActionsContract("main")
	for _, tool := range []string{"create_target", "create_jira_issue", "connect_jira_board", "add_jira_comment",
		"transition_jira_issue", "assign_jira_issue", "update_jira_issue", "edit_confluence_page", "create_track", "dismiss_tracks", "create_idea", "remind_me",
		"send_slack_message"} {
		assert.Contains(t, main, "- "+tool+" — ", tool)
	}
	target := ActionsContract("target")
	for _, tool := range []string{"create_target", "connect_jira_board", "create_track", "dismiss_tracks", "create_idea", "remind_me", "send_slack_message"} {
		assert.NotContains(t, target, "- "+tool+" — ", "%s is not offered on the target surface", tool)
	}
	// Slack send (#166): the style rule rides with the tool, main only.
	assert.Contains(t, main, "call get_writing_style FIRST")
	assert.NotContains(t, target, "get_writing_style")
	assert.Contains(t, target, "watchtower-action")
	// Confluence page editing (spec 2026-09-30 §5): both surfaces carry the
	// write tool and the read-first / markers / base_version rule.
	for _, block := range []string{main, target} {
		assert.Contains(t, block, "- edit_confluence_page — ")
		assert.Contains(t, block, "read it with get_confluence_page first")
		assert.Contains(t, block, "pass its version as base_version")
		assert.Contains(t, block, "Prefer replace_text for a small edit")
		assert.Contains(t, block, "Keep every ⟦…⟧ marker you do not mean to delete, verbatim")
		assert.Contains(t, block, `After a "page changed" error, read the page again`)
	}
}
