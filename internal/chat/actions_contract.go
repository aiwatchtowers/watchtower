package chat

import "strings"

// ActionsContract is the system-prompt block that teaches an action surface
// how write tools work. The Swift twin is
// WatchtowerCore/Services/Actions/AgentToolsContract.swift — byte-identical,
// pinned on both sides by testdata/actions_contract_{main,target}.txt. Any
// surface other than main/target is draft-only (AGENT-04) and gets "".
func ActionsContract(surface string) string {
	var tools []string
	switch surface {
	case "main":
		tools = mainActionTools
	case "target":
		tools = targetActionTools
	default:
		return ""
	}
	lines := make([]string, 0, len(actionsHeader)+len(tools)+len(actionsRules))
	lines = append(lines, actionsHeader...)
	lines = append(lines, tools...)
	lines = append(lines, actionsRules...)
	text := strings.Join(lines, "\n")
	if surface == "target" {
		text += "\n\n" + targetCoexistence
	}
	return text
}

var actionsHeader = []string{
	"=== AGENT ACTIONS ===",
	`You have write TOOLS. A write tool never changes anything by itself: calling it records a PROPOSAL and returns a receipt with an action id and a status. The owner sees a card in this chat and approves or rejects it; only then does the app execute it. A tool the owner has pre-approved runs at once, and its receipt already says "applied".`,
	"Write tools on this surface:",
}

var jiraIssueWriteTools = []string{
	"- add_jira_comment — propose a comment on an existing Jira issue.",
	"- transition_jira_issue — propose moving a Jira issue to another status; pass the target status name.",
	`- assign_jira_issue — propose assigning a Jira issue to "me" (the owner), an email, or a display name.`,
	"- update_jira_issue — propose changing a Jira issue's summary, priority, labels, or due date.",
}

var mainActionTools = concat(
	[]string{
		"- create_target — propose a new task or reminder (a task with a due date) in the owner's task list.",
		"- create_jira_issue — propose a Jira issue on a connected site.",
		"- connect_jira_board — propose watching a Jira board so its issues start syncing; pass board_name when the project has several boards, and ask the owner when the project is ambiguous.",
	},
	jiraIssueWriteTools,
	[]string{
		"- create_track — propose a track that follows a topic over time.",
		"- create_idea — capture an idea in the owner's ideas registry.",
		"- remind_me — set a reminder that resurfaces in the Inbox at a chosen time; pass message_ref when it is about one Slack message.",
	},
)

var targetActionTools = concat(
	[]string{"- create_jira_issue — propose a Jira issue on a connected site."},
	jiraIssueWriteTools,
)

var actionsRules = []string{
	"Rules:",
	`- Read the receipt. Status "pending": tell the owner what you proposed and that it awaits their approval; never claim it is done, created, or sent. Status "applied": report what was done.`,
	"- One proposal per item; never propose the same item twice in one turn.",
	"- For a new Jira issue, call list_jira_projects FIRST to pick a synced project and a known issue type. When the project or type is ambiguous, ask the owner instead of guessing.",
	"- For an existing Jira issue, pass its key (e.g. ABC-123); call get_jira_issue first when you are not sure of its current status, assignee, or fields.",
	"- get_action <id> answers what happened to a proposal; an ACTIONS SINCE YOUR LAST MESSAGE block at the top of the owner's message reports outcomes since your last turn.",
}

const targetCoexistence = "Changes to THIS task and its vertical line still go through `watchtower-action` blocks (TASK ACTIONS above); " +
	"Jira work goes through the Jira tools. Never create other Watchtower tasks from here — report the finding in prose instead."

func concat(parts ...[]string) []string {
	var out []string
	for _, p := range parts {
		out = append(out, p...)
	}
	return out
}
