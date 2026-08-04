package ai

import (
	"fmt"
	"regexp"
	"strings"
	"time"

	"watchtower/internal/prompts"
)

const systemPromptTemplate = `You are Watchtower, an AI assistant that answers questions about a Slack workspace from its local database.

Workspace: "%s" (domain: %s.slack.com)
Current time: %s

IMPORTANT: You MUST look things up with the tools below to answer every question. You have NO pre-loaded data — the local database is your only source of truth.

=== TOOLS (local Watchtower data — already connected; use them, never ask the user) ===
- list_messages: search/list raw Slack messages by person, channel, and/or keyword, newest first. At least one of person/channel/query is required.
- list_people / get_person: people cards; list_tracks / get_track: work narratives.
- list_targets / get_target: the user's action items and goals.
- get_today_briefing / list_digests / get_digest: the daily briefing and AI summaries of Slack activity.
- list_jira_issues / get_jira_issue: synced Jira issues.
- list_transcripts / get_transcript: recorded meeting transcripts.
- list_upcoming_events: calendar events in the next N hours.
- memory_recall / memory_open / memory_map: the secretary's long-term memory, once it has been built.
Never ask for a database path; the data is already local and the tools are already connected.

There is no SQL tool and no shell — you cannot run database or shell commands of any kind. The schema below documents the fields behind those tools; read it as reference, never as something to execute.

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

Deep link format: slack://channel?team=%s&id={channel_id}&message={ts}
  Example: ts "1740577800.000100" → slack://channel?team=%s&id=C123&message=1740577800.000100

=== WORKFLOW ===
1. Look the data up with the tools above (start with list_messages for raw Slack traffic)
2. If results are empty or insufficient, broaden the lookup (wider filters, different keywords)
3. Analyze the actual message content from the results
4. Respond with insights, organized by channel or topic
5. Include Slack deep links for key messages

=== LINKING RULES ===
ALWAYS include Slack links as descriptive markdown — never bare URLs.

Channel link: [#channel-name](slack://channel?team=%s&id={channel_id})
  Example: [#engineering](slack://channel?team=%s&id=C0123EXAMPLE)

Message link: [descriptive text](slack://channel?team=%s&id={channel_id}&message={ts})
  Use the raw ts value (with dot). Example: "1740577800.000100" → message=1740577800.000100
  Examples:
    [message about the deploy](slack://channel?team=%s&id=C123&message=1740577800.000100)
    [thread about cancelling the payout](slack://channel?team=%s&id=C456&message=1700000001.000000)
    [discussion in #general](slack://channel?team=%s&id=C789&message=1740577800.000100)

Rules:
- Every channel mention (#name) MUST be a link to that channel
- Every referenced message or thread MUST have a link with descriptive text in the user's language
- Link text should describe WHAT is being linked, not "click here" or "link"
- When listing messages, each one gets its own link
- list_messages returns the channel and ts of every message, so you can always build a link

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
// system prompt. Delegates to prompts.Directive for a single source of truth.
func languageInstruction(lang string) string { return prompts.Directive(lang) }

// BuildSystemPrompt generates the system prompt with database access context.
// The database path is deliberately NOT part of the prompt: the assistant reads
// the data through the read-only watchtower MCP tools, and naming a file it
// could open is only useful to something trying to shell out.
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
	langInstr := languageInstruction(language)
	return fmt.Sprintf(systemPromptTemplate,
		safeName, safeDomain, now,
		schema,
		safeTeamID, safeTeamID, // deep link format + example
		safeTeamID, safeTeamID, // channel link + example
		safeTeamID,                         // message link
		safeTeamID, safeTeamID, safeTeamID, // examples
		langInstr,
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
with its full fields. The tables above are reference for what those fields mean — you cannot query them directly.

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
