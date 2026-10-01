package chat

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestSummarizeToolResult_PerTool(t *testing.T) {
	cases := []struct {
		name, tool, result string
		summary            string
		sources            []Source
	}{
		{
			name: "search_knowledge hits",
			tool: "search_knowledge",
			result: `{"hits":[
				{"ref":"slack:1:C1:100.1","source":"slack","title":"#payments — refund is live","when":"2026-05-13T10:00:00Z",
				 "link":"https://acme.slack.com/archives/C1/p1001","snippets":["the  refund\nflow shipped"]},
				{"ref":"jira:PAY-7","source":"jira","title":"PAY-7 Refund flow","anchor":{"account_id":"1","key":"PAY-7"}},
				{"ref":"gmail:1:t9","source":"gmail","title":"Re: vendor contract","when":"2026-05-01T08:00:00Z"},
				{"ref":"transcript:4","source":"transcript","title":"Weekly sync"},
				{"ref":"confluence:1:p2","source":"confluence","title":"Runbook","anchor":{"space":"OPS"}},
				{"ref":"digest:9","source":"digest","title":"Daily digest","when":"not a date"}]}`,
			summary: "6 results: #payments — refund is live; PAY-7 Refund flow; Re: vendor contract",
			sources: []Source{
				{Kind: "slack", Title: "#payments — refund is live", URL: "https://acme.slack.com/archives/C1/p1001",
					Ref: "slack:1:C1:100.1", Group: "#payments", Snippet: "the refund flow shipped", Date: "2026-05-13"},
				{Kind: "jira", Title: "PAY-7 Refund flow", Ref: "jira:PAY-7", Group: "PAY"},
				{Kind: "email", Title: "Re: vendor contract", Ref: "gmail:1:t9", Group: "Mail", Date: "2026-05-01"},
				{Kind: "meeting", Title: "Weekly sync", Ref: "transcript:4", Group: "Meetings"},
				{Kind: "document", Title: "Runbook", Ref: "confluence:1:p2", Group: "OPS"},
				{Kind: "document", Title: "Daily digest", Ref: "digest:9"},
			},
		},
		{
			name:    "get_knowledge_document",
			tool:    "get_knowledge_document",
			result:  `{"ref":"jira:PAY-7","source":"jira","title":"PAY-7 Refund flow","link":"","text":"long body"}`,
			summary: "Opened PAY-7 Refund flow",
			sources: []Source{{Kind: "jira", Title: "PAY-7 Refund flow", Ref: "jira:PAY-7", Group: "PAY"}},
		},
		{
			name:    "get_knowledge_document on a Slack channel-day",
			tool:    "get_knowledge_document",
			result:  `{"ref":"slack:1:C1:day:2026-05-13","source":"slack","title":"#payments · 2026-05-13","when":"2026-05-13T18:00:00Z","link":""}`,
			summary: "Opened #payments · 2026-05-13",
			sources: []Source{{Kind: "slack", Title: "#payments · 2026-05-13", Ref: "slack:1:C1:day:2026-05-13",
				Group: "#payments", Date: "2026-05-13"}},
		},
		{
			name: "get_jira_issue (Go field names, no json tags)",
			tool: "get_jira_issue",
			result: `{"Key":"PAY-7","ProjectKey":"PAY","Summary":"Refund flow","Status":"In Progress",
				"AssigneeDisplayName":"Ann","UpdatedAt":"2026-05-10T09:00:00.000+0000"}`,
			summary: "Opened PAY-7: Refund flow (In Progress)",
			sources: []Source{{Kind: "jira", Title: "PAY-7: Refund flow", Ref: "jira:PAY-7", Group: "PAY",
				Snippet: "In Progress · Ann", Date: "2026-05-10"}},
		},
		{
			name:    "list_jira_issues",
			tool:    "list_jira_issues",
			result:  `[{"Key":"PAY-1","Summary":"A"},{"Key":"PAY-2","Summary":"B","AssigneeDisplayName":"Bob"}]`,
			summary: "2 issues: PAY-1, PAY-2",
			sources: []Source{
				{Kind: "jira", Title: "PAY-1: A", Ref: "jira:PAY-1", Group: "PAY"},
				{Kind: "jira", Title: "PAY-2: B", Ref: "jira:PAY-2", Group: "PAY", Snippet: "Bob"},
			},
		},
		{
			name:    "list_messages",
			tool:    "list_messages",
			result:  `[{"ts":"1778666400.000100","channel":"payments","sender":"Ann","text":"shipped","permalink":"https://acme.slack.com/archives/C1/p1001"}]`,
			summary: "1 messages",
			sources: []Source{{Kind: "slack", Title: "#payments · Ann", URL: "https://acme.slack.com/archives/C1/p1001",
				Ref: "slack:payments:1778666400.000100", Group: "#payments", Snippet: "shipped", Date: "2026-05-13"}},
		},
		{
			name:    "get_transcript",
			tool:    "get_transcript",
			result:  `{"id":4,"title":"Weekly sync","created_at":"2026-05-12T15:00:00Z","summary":"Agreed on the refund cutover","transcript_text":"..."}`,
			summary: "Opened Weekly sync",
			sources: []Source{{Kind: "meeting", Title: "Weekly sync", Ref: "transcript:4", Group: "Meetings",
				Snippet: "Agreed on the refund cutover", Date: "2026-05-12"}},
		},
		{
			name:    "get_person",
			tool:    "get_person",
			result:  `{"UserID":"1:U42","Summary":"Leads payments"}`,
			summary: "Opened person 1:U42",
			sources: []Source{{Kind: "person", Title: "1:U42", Ref: "person:1:U42"}},
		},
		{
			name:    "get_digest",
			tool:    "get_digest",
			result:  `{"ID":9,"Type":"daily","Summary":"Quiet day"}`,
			summary: "Opened daily digest #9",
			sources: []Source{{Kind: "document", Title: "daily digest #9", Ref: "digest:9"}},
		},
		{
			name:    "get_target",
			tool:    "get_target",
			result:  `{"ID":3,"Text":"Ship refunds"}`,
			summary: "Opened target: Ship refunds",
			sources: []Source{{Kind: "document", Title: "Ship refunds", Ref: "target:3"}},
		},
		{
			name:    "unknown tool yields no sources",
			tool:    "confluence:search",
			result:  "  plain\n\ntext   result ",
			summary: "plain text result",
		},
		{
			name:    "known tool with malformed JSON falls back to the text",
			tool:    "search_knowledge",
			result:  "not json at all",
			summary: "not json at all",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			summary, sources := SummarizeToolResult(c.tool, c.result)
			assert.Equal(t, c.summary, summary)
			assert.Equal(t, c.sources, sources)
		})
	}
}

func TestSourceHelpers(t *testing.T) {
	assert.Equal(t, "#payments", slackTitleGroup("#payments — a · b"))
	assert.Equal(t, "DM with Ann", slackTitleGroup("DM with Ann · 2026-05-13"))
	assert.Equal(t, "", slackTitleGroup("#payments"))
	assert.Equal(t, "PAY", jiraProject("PAY-7"))
	for _, bad := range []string{"", "PAY", "-7", "PAY-"} {
		assert.Equal(t, "", jiraProject(bad), bad)
	}
	assert.Equal(t, "", isoDay("2026-13-40T00:00:00Z"))
	assert.Equal(t, "", slackDay("garbage"))
	assert.Equal(t, "", slackDay(""))
	long := strings.Repeat("я", SnippetMaxRunes+50)
	assert.Equal(t, SnippetMaxRunes, utf8.RuneCountInString(snippet(long)))
}

// TestSource_OmitsEmptyOptionalFields: a source without the new fields
// serializes exactly as before, so older readers and rows stay compatible.
func TestSource_OmitsEmptyOptionalFields(t *testing.T) {
	b, err := json.Marshal(Source{Kind: "jira", Title: "PAY-1: A", Ref: "jira:PAY-1"})
	require.NoError(t, err)
	assert.JSONEq(t, `{"kind":"jira","title":"PAY-1: A","ref":"jira:PAY-1"}`, string(b))
	var legacy Source
	require.NoError(t, json.Unmarshal([]byte(`{"kind":"slack","title":"#a · b","ref":"r"}`), &legacy))
	assert.Equal(t, Source{Kind: "slack", Title: "#a · b", Ref: "r"}, legacy)
}

// WebSearch returns text with `Links: [...]` lines; every link becomes a
// "web" chip under the Web group, and a result with no links falls back.
func TestSummarizeToolResult_WebSearch(t *testing.T) {
	raw := "Web search results for query: \"go 1.25 release\"\n\n" +
		`Links: [{"title":"Go 1.25 Release Notes","url":"https://go.dev/doc/go1.25"},{"title":"No URL","url":""}]` + "\n\n" +
		"Go 1.25 was released in August.\n" +
		`Links: [{"title":"Blog","url":"https://go.dev/blog/go1.25"}] trailing`
	summary, sources := SummarizeToolResult("WebSearch", raw)
	assert.Equal(t, "2 web results: Go 1.25 Release Notes; Blog", summary)
	assert.Equal(t, []Source{
		{Kind: "web", Title: "Go 1.25 Release Notes", URL: "https://go.dev/doc/go1.25", Group: "Web"},
		{Kind: "web", Title: "Blog", URL: "https://go.dev/blog/go1.25", Group: "Web"},
	}, sources)

	summary, sources = SummarizeToolResult("WebSearch", "Web search results for query: \"x\"\n\nNo links found.")
	assert.Empty(t, sources)
	assert.Contains(t, summary, "No links found.")
}

func TestSummarizeToolResult_DedupesSources(t *testing.T) {
	_, sources := SummarizeToolResult("search_knowledge", `{"hits":[
		{"ref":"a","source":"slack","title":"one","link":"https://x/1"},
		{"ref":"b","source":"slack","title":"one again","link":"https://x/1"},
		{"ref":"c","source":"jira","title":"c"},
		{"ref":"c","source":"jira","title":"c again"}]}`)
	require.Len(t, sources, 2, "same URL, or same ref when there is no URL, is one chip")
}

// TestSummarizeToolResult_HugeResultIsBounded: a 200 KB tool result must still
// produce a ≤300-rune summary and ≤10 sources (Review Focus 3).
func TestSummarizeToolResult_HugeResultIsBounded(t *testing.T) {
	type msg struct {
		TS        string `json:"ts"`
		Channel   string `json:"channel"`
		Sender    string `json:"sender"`
		Text      string `json:"text"`
		Permalink string `json:"permalink"`
	}
	var msgs []msg
	for i := 0; i < 600; i++ {
		msgs = append(msgs, msg{TS: fmt.Sprintf("%d.1", i), Channel: "general", Sender: "Ann",
			Text: strings.Repeat("платёж ", 40), Permalink: fmt.Sprintf("https://acme.slack.com/p%d", i)})
	}
	b, err := json.Marshal(msgs)
	require.NoError(t, err)
	require.Greater(t, len(b), 200_000)

	summary, sources := SummarizeToolResult("list_messages", string(b))
	assert.LessOrEqual(t, utf8.RuneCountInString(summary), SummaryMaxRunes)
	assert.Len(t, sources, MaxSources)

	summary, sources = SummarizeToolResult("some_unknown_tool", strings.Repeat("Кириллица ", 30_000))
	assert.LessOrEqual(t, utf8.RuneCountInString(summary), SummaryMaxRunes, "runes, not bytes")
	assert.True(t, utf8.ValidString(summary), "never cuts a multi-byte rune in half")
	assert.Empty(t, sources)
}
