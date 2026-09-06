package reactioncmd

import (
	"fmt"
	"strings"
)

// argGuide describes a tool's arguments to the composer. Only the v1 built-in
// tools are spelled out; anything else gets a generic instruction so a
// newly-registered tool still composes something sensible.
func argGuide(tool string) string {
	switch tool {
	case "create_target":
		return `Arguments:
- "text" (required): the task title, imperative, at most 200 characters.
- "intent" (optional): why it matters / the desired outcome.
- "priority" (optional): "high" | "medium" | "low".
- "reason" (required): one sentence for the owner.`
	case "create_jira_issue":
		return `Arguments:
- "project_key" (required): a project key from the "Available Jira projects" list below — pick the best fit; if none fits, use the first.
- "issue_type" (required): "Task" unless the message clearly implies "Bug" or "Story".
- "summary" (required): the issue title, at most 255 characters.
- "description" (optional): plain-text body summarising the message and any thread context.
- "reason" (required): one sentence for the owner.`
	default:
		return `Return a JSON object of this action's arguments, plus a "reason" (one sentence for the owner).`
	}
}

// buildComposeUserMessage assembles the user message for the reactioncmd.command
// prompt: which action to build, its argument guide, the reacted message and
// any thread context, and grounding facts (Jira projects, today's date).
func buildComposeUserMessage(c candidate, guide string, threadLines, jiraProjects []string, today, langDirective string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "Action to build: %s\n\n%s\n\n", c.Mapping.Tool, guide)

	b.WriteString("The owner reacted to this Slack message:\n")
	if c.AuthorID != "" {
		fmt.Fprintf(&b, "  author: %s\n", c.AuthorID)
	}
	fmt.Fprintf(&b, "  message: %s\n", strings.TrimSpace(c.Text))

	if len(threadLines) > 0 {
		b.WriteString("\nThread context (oldest first):\n")
		for _, l := range threadLines {
			fmt.Fprintf(&b, "  - %s\n", strings.TrimSpace(l))
		}
	}

	if c.Mapping.Tool == "create_jira_issue" {
		if len(jiraProjects) > 0 {
			fmt.Fprintf(&b, "\nAvailable Jira projects: %s\n", strings.Join(jiraProjects, ", "))
		} else {
			b.WriteString("\nAvailable Jira projects: (none synced — use your best guess for project_key)\n")
		}
	}

	fmt.Fprintf(&b, "\nToday's date: %s\n", today)
	if langDirective != "" {
		fmt.Fprintf(&b, "\n%s\n", langDirective)
	}
	b.WriteString("\nReturn ONLY the JSON object of the action's arguments.")
	return b.String()
}
