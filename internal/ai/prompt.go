package ai

import (
	"fmt"
	"regexp"
	"strings"
	"time"

	"watchtower/internal/chat/blocks"
	"watchtower/internal/prompts"
)

const systemPromptTemplate = `You are Watchtower, an AI assistant that answers questions about a Slack workspace from its local database.

Workspace: "%s" (domain: %s.slack.com)
Current time: %s

IMPORTANT: You MUST look things up with the tools below to answer every question. You have NO pre-loaded data — the local database is your only source of truth.

%s

%s
The schema below documents the fields behind those tools; read it as reference, never as something to execute.

=== DATABASE SCHEMA (reference) ===
%s

=== TARGETS & GOAL HIERARCHY ===
The workspace uses a hierarchical goal system called "targets" (replaces the old flat "tasks").
- Table: targets — personal action items and goals, each with a level tag: quarter, month, week, day, or custom.
  level and period_start/period_end together express WHEN a target is due (e.g. a quarter OKR vs today's to-do).
  parent_id links child targets to their parent for tree rendering and progress rollup (progress 0.0–1.0).
- Table: target_links — typed edges between targets or to external refs (Jira keys, Slack permalinks).
  relation is one of: contributes_to, blocks, related, duplicates.
  target_target_id references another target; external_ref holds e.g. 'jira:PROJ-123' or 'slack:C123:ts'.
  created_by is 'ai' (auto-linked) or 'user' (manually added).
Reach targets and their links with list_targets / get_target — status, priority, level, and ownership are filters on list_targets.

%s

%s

=== RESPONSE STYLE ===
- Be concise and direct
%s
- Use markdown for readability
- Highlight: decisions, action items, unanswered questions, unusual activity`

var (
	safeNameRe   = regexp.MustCompile(`[^\p{L}\p{N} _.\-]`) // workspace name: allows spaces and unicode
	safeDomainRe = regexp.MustCompile(`[^a-zA-Z0-9_\-]`)    // domain: strict ASCII for URL context
)

// languageInstruction returns the response language directive for the
// system prompt. `ask` and the REPL are interactive, so they follow the
// language the owner writes in, like the main AI Chat (prompts.ChatDirective);
// lang is only the fallback.
func languageInstruction(lang string) string { return prompts.ChatDirective(lang) }

// BuildSystemPrompt generates the system prompt for `ask`/`repl`. The tool
// list, data-access rules, workflow and linking rules are the shared blocks
// the main AI Chat uses too (internal/chat/blocks — one copy). The database
// path is deliberately NOT part of the prompt: the assistant reads the data
// through the read-only watchtower MCP tools.
func BuildSystemPrompt(workspaceName, domain, teamID, schema, language string) string {
	// Sanitize workspace name and domain to prevent prompt injection
	safeName := safeNameRe.ReplaceAllString(workspaceName, "")
	safeDomain := safeDomainRe.ReplaceAllString(domain, "")
	safeTeamID := safeDomainRe.ReplaceAllString(teamID, "")
	if safeName == "" {
		safeName = "unknown"
	}
	if safeDomain == "" {
		safeDomain = "unknown"
	}
	if safeTeamID == "" {
		safeTeamID = "unknown"
	}

	now := time.Now().UTC().Format("2006-01-02 15:04 UTC")
	return fmt.Sprintf(systemPromptTemplate,
		safeName, safeDomain, now,
		blocks.ToolsList,
		blocks.DataAccessRules,
		schema,
		blocks.Workflow,
		blocks.LinkingRules(nil, safeTeamID),
		languageInstruction(language),
	)
}

// JiraPromptSection returns the Jira schema reference to append to the system
// prompt. Call only when Jira integration is enabled.
func JiraPromptSection() string {
	return `

=== JIRA TABLES (reference) ===
The workspace has Jira Cloud integration. These tables back the Jira tools:

CREATE TABLE jira_issues (
    key TEXT PRIMARY KEY,              -- e.g. "PROJ-123"
    project_key TEXT NOT NULL,
    board_id INTEGER,
    summary TEXT NOT NULL,
    description_text TEXT NOT NULL DEFAULT '',
    issue_type TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL,
    status_category TEXT NOT NULL,      -- "todo", "in_progress", "done"
    assignee_account_id TEXT NOT NULL DEFAULT '',
    assignee_display_name TEXT NOT NULL DEFAULT '',
    assignee_slack_id TEXT NOT NULL DEFAULT '',
    reporter_display_name TEXT NOT NULL DEFAULT '',
    reporter_slack_id TEXT NOT NULL DEFAULT '',
    priority TEXT NOT NULL DEFAULT '',  -- "Highest","High","Medium","Low","Lowest"
    story_points REAL,
    due_date TEXT NOT NULL DEFAULT '',  -- ISO date or empty
    sprint_id INTEGER,
    sprint_name TEXT NOT NULL DEFAULT '',
    epic_key TEXT NOT NULL DEFAULT '',
    labels TEXT NOT NULL DEFAULT '[]',  -- JSON array
    components TEXT NOT NULL DEFAULT '[]',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    resolved_at TEXT NOT NULL DEFAULT '',
    is_deleted INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE jira_sprints (
    id INTEGER PRIMARY KEY,
    board_id INTEGER NOT NULL,
    name TEXT NOT NULL,
    state TEXT NOT NULL,               -- "active", "closed", "future"
    goal TEXT NOT NULL DEFAULT '',
    start_date TEXT NOT NULL DEFAULT '',
    end_date TEXT NOT NULL DEFAULT ''
);

CREATE TABLE jira_issue_links (
    id TEXT PRIMARY KEY,
    source_key TEXT NOT NULL,
    target_key TEXT NOT NULL,
    link_type TEXT NOT NULL             -- e.g. "Blocks", "is blocked by"
);

CREATE TABLE jira_user_map (
    jira_account_id TEXT PRIMARY KEY,
    slack_user_id TEXT NOT NULL DEFAULT '',
    display_name TEXT NOT NULL DEFAULT ''
);

CREATE TABLE jira_slack_links (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    issue_key TEXT NOT NULL,
    channel_id TEXT NOT NULL DEFAULT '',
    message_ts TEXT NOT NULL DEFAULT '',
    track_id INTEGER,
    digest_id INTEGER,
    link_type TEXT NOT NULL DEFAULT 'mention'
);

CREATE TABLE jira_boards (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    project_key TEXT NOT NULL DEFAULT '',
    board_type TEXT NOT NULL DEFAULT ''
);

=== HOW TO REACH JIRA DATA ===
list_jira_issues filters by project, status, or assignee account id; get_jira_issue fetches one issue by key
with its full fields. get_jira_status_history returns an issue's status/assignee changes; get_jira_time_in_status
sums time in status per assignee over a period (wall-clock time in a status, not hours worked). The tables above are reference for what those fields mean — you cannot query them directly.

Notes:
- assignee_slack_id links directly to users.id when available
- jira_user_map maps Jira account IDs to Slack user IDs for cross-referencing
- Use is_deleted = 0 to exclude deleted issues
- due_date can be empty string — filter with due_date != '' for overdue queries`
}

// FormatTimeHints formats time range information from a parsed query as hints
// for the AI, including Unix timestamps ready for SQL WHERE clauses.
func FormatTimeHints(pq ParsedQuery) string {
	if pq.TimeRange == nil {
		return ""
	}

	fromUnix := pq.TimeRange.From.Unix()
	toUnix := pq.TimeRange.To.Unix()
	fromStr := pq.TimeRange.From.UTC().Format("2006-01-02 15:04 UTC")
	toStr := pq.TimeRange.To.UTC().Format("2006-01-02 15:04 UTC")

	return fmt.Sprintf("Time range: %s to %s (ts_unix BETWEEN %d AND %d)",
		fromStr, toStr, fromUnix, toUnix)
}

// AssembleUserMessage combines the user's question with optional time hints.
func AssembleUserMessage(question, hints string) string {
	var b strings.Builder
	b.WriteString(question)
	if hints != "" {
		b.WriteString("\n\n")
		b.WriteString(hints)
	}
	return b.String()
}
