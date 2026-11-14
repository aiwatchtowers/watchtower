package chat

import "testing"

// A codex app call (mcp_tool_call, server codex_apps, tool slack.<name>) is
// named "mcp__codex_apps__slack.<name>" by the codex stream; the chat shows
// it as "codex_apps:slack.<name>" (cmd's Slack Live watcher matches this).
func TestDisplayToolName_CodexSlackApp(t *testing.T) {
	if got := displayToolName("mcp__codex_apps__slack.slack_list_workspaces"); got != "codex_apps:slack.slack_list_workspaces" {
		t.Fatalf("got %q", got)
	}
}
