// Package slackconnector is the one list of the owner's Slack connector
// tools (the claude.ai Slack connector and the Codex Slack app share the
// tool names) and the names they carry on each path. A leaf: the connector
// policy (internal/chat/connectorpolicy), the probe (internal/slacklive) and
// cmd all read it, so no list is kept twice.
package slackconnector

// ReadTools are the connector's read-only tools (bare names). Only these are
// ever offered to a Live path; anything else is a write or unknown.
var ReadTools = []string{
	"slack_search_public",
	"slack_search_public_and_private",
	"slack_search_channels",
	"slack_search_users",
	"slack_search_emojis",
	"slack_read_channel",
	"slack_read_thread",
	"slack_read_canvas",
	"slack_read_user_profile",
	"slack_list_user_channels",
	"slack_list_channel_members",
	"slack_get_reactions",
	"slack_read_file",
	"slack_list_workspaces",
}

// WriteTools are the connector's write tools (message, reaction, canvas):
// never without the owner's approval in the chat, never in an automation or
// the probe.
var WriteTools = []string{
	"slack_send_message",
	"slack_schedule_message",
	"slack_send_message_draft",
	"slack_create_canvas",
	"slack_update_canvas",
	"slack_add_reaction",
}

// ClaudeServer is the claude.ai Slack connector's server token.
const ClaudeServer = "claude_ai_Slack"

// ClaudeToolPrefix is the claude CLI's name of a connector tool
// (mcp__claude_ai_Slack__<name>).
const ClaudeToolPrefix = "mcp__" + ClaudeServer + "__"

// ClaudeStepPrefix and CodexStepPrefix are the chat's step names of a
// connector tool (chat displayToolName, what the Desktop stores in
// chat_turn_steps.name): Claude "claude_ai_Slack:<name>", Codex
// "codex_apps:slack.<name>" (an mcp_tool_call of server codex_apps, tool
// "slack.<name>").
const (
	ClaudeStepPrefix = ClaudeServer + ":"
	CodexStepPrefix  = "codex_apps:slack."
)
