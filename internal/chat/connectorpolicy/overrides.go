package connectorpolicy

// claudeDocsToken is the server token of the claude.ai Claude Docs connector.
const claudeDocsToken = "claude_ai_Claude_Docs"

// claudeSlackToken is the server token of the claude.ai Slack connector.
const claudeSlackToken = "claude_ai_Slack"

// overrides are the rows that win over a tool's own annotations (rule 6):
// known misannotated tools and the Claude Docs operation rules. Data only —
// each row says why it exists, and policy_test.go covers every row.
var overrides = append([]override{
	{Server: claudeDocsToken, Tool: "create", Verdict: Allow, CheckDocsWrite: true,
		Why: "creates a comment or object in a private doc this chat created (ask #236); another doc, a share, delete or mention still asks"},
	{Server: claudeDocsToken, Tool: "update", Verdict: Allow, CheckDocsWrite: true,
		Why: "edits a private doc this chat created, every revision kept in its history; another doc, a share, delete or mention still asks"},
	{Server: claudeDocsToken, Tool: "batch", Verdict: Allow, CheckDocsWrite: true,
		Why: "creates a new private doc, or edits one this chat created, in one call; another doc, a share, delete or mention still asks"},
	{Server: claudeDocsToken, Tool: "read", Verdict: Allow,
		Why: "reads a doc the owner can open"},
	{Server: claudeDocsToken, Tool: "query", Verdict: Allow,
		Why: "lists a doc's comments or objects"},
	{Server: claudeDocsToken, Tool: "guide", Verdict: Allow,
		Why: "returns the connector's own usage guide"},
	{Server: claudeDocsToken, Tool: "delete", Verdict: Ask,
		Why: "deletes a doc, tab or comment, which may not be recoverable"},
}, slackOverrides...)

var slackOverrides = func() []override {
	var rows []override
	for _, t := range []string{
		"slack_get_reactions",
		"slack_list_workspaces",
		"slack_list_channel_members",
		"slack_list_user_channels",
		"slack_read_canvas",
		"slack_read_channel",
		"slack_read_file",
		"slack_read_thread",
		"slack_read_user_profile",
		"slack_search_channels",
		"slack_search_emojis",
		"slack_search_public",
		"slack_search_public_and_private",
		"slack_search_users",
	} {
		rows = append(rows, override{Server: claudeSlackToken, Tool: t, Verdict: Allow,
			Why: "reads Slack through the owner's connector (Live Slack, #1764); the connector does not always annotate it"})
	}
	for _, t := range []string{
		"slack_add_reaction",
		"slack_create_canvas",
		"slack_schedule_message",
		"slack_send_message",
		"slack_send_message_draft",
		"slack_update_canvas",
	} {
		rows = append(rows, override{Server: claudeSlackToken, Tool: t, Verdict: Ask,
			Why: "writes to Slack as the owner (message, reaction, canvas); never without approval"})
	}
	return rows
}()
