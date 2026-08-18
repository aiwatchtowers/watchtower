package ai

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"

	"watchtower/internal/db"
)

func TestBuildSystemPrompt_ContainsWorkspaceInfo(t *testing.T) {
	prompt := BuildSystemPrompt("my-company", "my-company", "T001", "CREATE TABLE test;", "")

	assert.Contains(t, prompt, `"my-company"`)
	assert.Contains(t, prompt, "my-company.slack.com")
	assert.Contains(t, prompt, "Current time:")
	assert.Contains(t, prompt, "You are Watchtower")
}

func TestBuildSystemPrompt_ContainsSchema(t *testing.T) {
	prompt := BuildSystemPrompt("test-ws", "test-ws", "T001", "CREATE TABLE messages;", "")

	assert.Contains(t, prompt, "CREATE TABLE messages;")
}

// The prompt must never hand the assistant a shell recipe: on the codex
// provider command execution is permitted (read-only sandbox), so a suggested
// `sqlite3 <path>` is a readable path to the config file holding the Slack
// token. Data access goes through the read-only MCP tools only. (The database
// path is kept out by construction — BuildSystemPrompt no longer takes one.)
func TestBuildSystemPrompt_NoShellFallback(t *testing.T) {
	prompt := BuildSystemPrompt("test-ws", "test-ws", "T001", "schema", "")

	assert.NotContains(t, prompt, "sqlite3")
	assert.Contains(t, prompt, "no SQL tool and no shell")
	// The no-live-sources ground rule: the assistant must never claim it will
	// check Slack/Jira/Calendar/the web directly, nor beg for tool approvals.
	assert.Contains(t, prompt, "NO internet access and NO live access to Slack, Jira, or Calendar")
	assert.Contains(t, prompt, "never ask the user to approve tool permissions")
}

func TestBuildSystemPrompt_ContainsGuidelines(t *testing.T) {
	prompt := BuildSystemPrompt("test-ws", "test-ws", "T001", "schema", "")

	assert.Contains(t, prompt, "concise")
	assert.Contains(t, prompt, "deep link")
	assert.Contains(t, prompt, "markdown")
}

// Every tool the prompt advertises must actually be registered by
// internal/mcp; naming one that isn't only steers the assistant off the tool
// path (that is how the `read_query` / `list_tables` / `describe_table` text
// this replaces sent it looking for a shell instead).
func TestBuildSystemPrompt_NamesRegisteredTools(t *testing.T) {
	prompt := BuildSystemPrompt("test-ws", "test-ws", "T001", "schema", "")

	for _, tool := range []string{
		"list_messages", "list_people", "get_person", "list_tracks", "get_track",
		"list_targets", "get_target", "get_today_briefing", "list_digests", "get_digest",
		"list_jira_issues", "get_jira_issue", "list_transcripts", "get_transcript",
		"list_upcoming_events", "memory_recall", "memory_open", "memory_map",
	} {
		assert.Contains(t, prompt, tool)
	}

	for _, stale := range []string{"read_query", "list_tables", "describe_table"} {
		assert.NotContains(t, prompt, stale)
	}
}

func TestBuildSystemPrompt_MustUseTools(t *testing.T) {
	prompt := BuildSystemPrompt("test-ws", "test-ws", "T001", "schema", "")

	assert.Contains(t, prompt, "You MUST look things up with the tools below")
}

func TestBuildSystemPrompt_SanitizesInputs(t *testing.T) {
	prompt := BuildSystemPrompt("my company!", "my domain<>", "T001", "schema", "")

	assert.Contains(t, prompt, "my company")
	assert.Contains(t, prompt, "mydomain")
	assert.NotContains(t, prompt, "!")
	assert.NotContains(t, prompt, "<>")
}

func TestBuildSystemPrompt_PreservesUnicode(t *testing.T) {
	prompt := BuildSystemPrompt("Société Générale", "societe", "T001", "schema", "")

	assert.Contains(t, prompt, "Société Générale")
}

func TestBuildSystemPrompt_EmptyInputsGetDefaults(t *testing.T) {
	prompt := BuildSystemPrompt("", "", "", "schema", "")

	assert.Contains(t, prompt, "unknown")
}

func TestBuildSystemPrompt_DefaultLanguage(t *testing.T) {
	// Empty language must fall back to the shared default (currently "Russian").
	prompt := BuildSystemPrompt("test-ws", "test-ws", "T001", "schema", "")
	assert.Contains(t, prompt, "Respond ONLY in Russian")
}

func TestBuildSystemPrompt_EnglishLanguage(t *testing.T) {
	prompt := BuildSystemPrompt("test-ws", "test-ws", "T001", "schema", "English")
	assert.Contains(t, prompt, "Respond ONLY in English")
}

func TestBuildSystemPrompt_NonEnglishLanguage(t *testing.T) {
	prompt := BuildSystemPrompt("test-ws", "test-ws", "T001", "schema", "Russian")
	assert.Contains(t, prompt, "Respond ONLY in Russian")
	assert.Contains(t, prompt, "MUST be in Russian")
}

func TestAssembleUserMessage_QuestionOnly(t *testing.T) {
	msg := AssembleUserMessage("What's up?", "")

	assert.Equal(t, "What's up?", msg)
}

func TestAssembleUserMessage_WithTimeHints(t *testing.T) {
	msg := AssembleUserMessage("What happened?", "Time range: 2025-02-26 10:00 UTC to 2025-02-26 14:00 UTC (ts_unix BETWEEN 1740564000 AND 1740578400)")

	assert.Contains(t, msg, "What happened?")
	assert.Contains(t, msg, "ts_unix BETWEEN")
}

func TestFormatTimeHints_WithTimeRange(t *testing.T) {
	from := time.Date(2025, 2, 26, 10, 0, 0, 0, time.UTC)
	to := time.Date(2025, 2, 26, 14, 0, 0, 0, time.UTC)

	pq := ParsedQuery{
		TimeRange: &TimeRange{From: from, To: to},
	}

	hints := FormatTimeHints(pq)

	assert.Contains(t, hints, "2025-02-26 10:00 UTC")
	assert.Contains(t, hints, "2025-02-26 14:00 UTC")
	assert.Contains(t, hints, "ts_unix BETWEEN")
	assert.Contains(t, hints, "1740564000")
}

func TestFormatTimeHints_NoTimeRange(t *testing.T) {
	pq := ParsedQuery{}
	hints := FormatTimeHints(pq)
	assert.Empty(t, hints)
}

func TestDBSchemaNotEmpty(t *testing.T) {
	assert.NotEmpty(t, db.Schema)
	assert.Contains(t, db.Schema, "CREATE TABLE")
	assert.Contains(t, db.Schema, "messages")
	assert.Contains(t, db.Schema, "channels")
	assert.Contains(t, db.Schema, "users")
	assert.Contains(t, db.Schema, "messages_fts")
}
