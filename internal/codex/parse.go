package codex

import "encoding/json"

// CodexEvent represents a single JSONL event from the Codex CLI --json output.
type CodexEvent struct {
	Type     string      `json:"type"` // thread.started, turn.started, turn.completed, item.started, item.completed, error
	ThreadID string      `json:"thread_id"`
	Item     *CodexItem  `json:"item"`
	Usage    *CodexUsage `json:"usage"`
	Error    *CodexError `json:"error"`
	// Message is the text of a top-level "error" event (codex exec puts
	// it beside the type, not under error).
	Message string `json:"message"`
}

// CodexItem represents an item within a Codex event.
type CodexItem struct {
	ID      string `json:"id"`
	Type    string `json:"type"`    // agent_message, command_execution, mcp_tool_call
	Content string `json:"content"` // older Codex CLI versions
	Text    string `json:"text"`    // newer Codex CLI versions (v0.118+)
	// Status is a tool item's state: in_progress, completed, failed (and
	// declined for a command_execution).
	Status string `json:"status"`

	// mcp_tool_call: the server and tool, the call's arguments, and its
	// result or error.
	Server    string            `json:"server"`
	Tool      string            `json:"tool"`
	Arguments json.RawMessage   `json:"arguments"`
	Result    *CodexToolResult  `json:"result"`
	ToolError *CodexItemFailure `json:"error"`

	// command_execution: the shell command, its output and exit code.
	Command          string `json:"command"`
	AggregatedOutput string `json:"aggregated_output"`
	ExitCode         *int   `json:"exit_code"`

	// web_search: the query (also in the action, which an item started
	// before its query was known lacks) and the pages found.
	Query  string `json:"query"`
	Action *struct {
		Query string `json:"query"`
	} `json:"action"`
	Results []CodexWebResult `json:"results"`
}

// CodexWebResult is one page a web_search item found.
type CodexWebResult struct {
	Title string `json:"title"`
	URL   string `json:"url"`
}

// SearchQuery is a web_search item's query, "" while it is not known.
func (i *CodexItem) SearchQuery() string {
	if i.Query == "" && i.Action != nil {
		return i.Action.Query
	}
	return i.Query
}

// CodexToolResult is an mcp_tool_call's result: MCP content blocks.
type CodexToolResult struct {
	Content []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	} `json:"content"`
}

// CodexItemFailure is a failed mcp_tool_call's error.
type CodexItemFailure struct {
	Message string `json:"message"`
}

// MessageText returns the agent message text, preferring Text over Content
// for compatibility across Codex CLI versions.
func (i *CodexItem) MessageText() string {
	if i.Text != "" {
		return i.Text
	}
	return i.Content
}

// CodexUsage holds token usage metrics from a Codex CLI call. InputTokens
// includes CachedInputTokens (the OpenAI convention codex reports).
type CodexUsage struct {
	InputTokens       int `json:"input_tokens"`
	CachedInputTokens int `json:"cached_input_tokens"`
	OutputTokens      int `json:"output_tokens"`
}

// freshInput is the input not served from codex's cache: InputTokens minus
// CachedInputTokens (at most InputTokens). The run budget debits it, and the
// ledger records it as fresh input (docs/features/automations.md#budgets).
func (t *CodexUsage) freshInput() int {
	return t.InputTokens - min(t.CachedInputTokens, t.InputTokens)
}

// add sums u into the receiver.
func (t *CodexUsage) add(u *CodexUsage) {
	t.InputTokens += u.InputTokens
	t.CachedInputTokens += u.CachedInputTokens
	t.OutputTokens += u.OutputTokens
}

// CodexError holds error information from a Codex CLI call.
type CodexError struct {
	Type     string `json:"type"`
	Code     string `json:"code"`
	Status   int    `json:"status"`
	ResetsAt int64  `json:"resets_at"`
	Message  string `json:"message"`
}
