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
				{"ref":"slack:1:C1:100.1","source":"slack","title":"#payments thread","link":"https://acme.slack.com/archives/C1/p1001"},
				{"ref":"jira:PAY-7","source":"jira","title":"PAY-7 Refund flow"},
				{"ref":"gmail:1:t9","source":"gmail","title":"Re: vendor contract"},
				{"ref":"transcript:4","source":"transcript","title":"Weekly sync"},
				{"ref":"digest:9","source":"digest","title":"Daily digest"}]}`,
			summary: "5 results: #payments thread; PAY-7 Refund flow; Re: vendor contract",
			sources: []Source{
				{Kind: "slack", Title: "#payments thread", URL: "https://acme.slack.com/archives/C1/p1001", Ref: "slack:1:C1:100.1"},
				{Kind: "jira", Title: "PAY-7 Refund flow", Ref: "jira:PAY-7"},
				{Kind: "email", Title: "Re: vendor contract", Ref: "gmail:1:t9"},
				{Kind: "meeting", Title: "Weekly sync", Ref: "transcript:4"},
				{Kind: "document", Title: "Daily digest", Ref: "digest:9"},
			},
		},
		{
			name:    "get_knowledge_document",
			tool:    "get_knowledge_document",
			result:  `{"ref":"jira:PAY-7","source":"jira","title":"PAY-7 Refund flow","link":"","text":"long body"}`,
			summary: "Opened PAY-7 Refund flow",
			sources: []Source{{Kind: "jira", Title: "PAY-7 Refund flow", Ref: "jira:PAY-7"}},
		},
		{
			name:    "get_jira_issue (Go field names, no json tags)",
			tool:    "get_jira_issue",
			result:  `{"Key":"PAY-7","Summary":"Refund flow","Status":"In Progress"}`,
			summary: "Opened PAY-7: Refund flow (In Progress)",
			sources: []Source{{Kind: "jira", Title: "PAY-7: Refund flow", Ref: "jira:PAY-7"}},
		},
		{
			name:    "list_jira_issues",
			tool:    "list_jira_issues",
			result:  `[{"Key":"PAY-1","Summary":"A"},{"Key":"PAY-2","Summary":"B"}]`,
			summary: "2 issues: PAY-1, PAY-2",
			sources: []Source{{Kind: "jira", Title: "PAY-1: A", Ref: "jira:PAY-1"}, {Kind: "jira", Title: "PAY-2: B", Ref: "jira:PAY-2"}},
		},
		{
			name:    "list_messages",
			tool:    "list_messages",
			result:  `[{"ts":"100.1","channel":"payments","sender":"Ann","text":"shipped","permalink":"https://acme.slack.com/archives/C1/p1001"}]`,
			summary: "1 messages",
			sources: []Source{{Kind: "slack", Title: "#payments · Ann", URL: "https://acme.slack.com/archives/C1/p1001", Ref: "slack:payments:100.1"}},
		},
		{
			name:    "get_transcript",
			tool:    "get_transcript",
			result:  `{"id":4,"title":"Weekly sync","transcript_text":"..."}`,
			summary: "Opened Weekly sync",
			sources: []Source{{Kind: "meeting", Title: "Weekly sync", Ref: "transcript:4"}},
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
