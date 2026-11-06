package agentloop

import (
	"encoding/json"

	"watchtower/internal/llmusage"
)

// OpenAI-compatible chat-completions wire types, the subset the tool loop uses.
// The same shape Ollama, LM Studio and vLLM speak on /v1/chat/completions.

type oaRequest struct {
	Model    string      `json:"model"`
	Messages []oaMessage `json:"messages"`
	Tools    []oaTool    `json:"tools,omitempty"`
	Stream   bool        `json:"stream"`
	// StreamOptions asks a streamed answer for its usage chunk.
	StreamOptions *oaStreamOptions `json:"stream_options,omitempty"`
}

type oaMessage struct {
	Role      string       `json:"role"`
	Content   string       `json:"content,omitempty"`
	ToolCalls []oaToolCall `json:"tool_calls,omitempty"`
	// ToolCallID and Name are set on a role:"tool" result message.
	ToolCallID string `json:"tool_call_id,omitempty"`
	Name       string `json:"name,omitempty"`
}

type oaToolCall struct {
	ID       string     `json:"id"`
	Type     string     `json:"type"`
	Function oaFunction `json:"function"`
}

type oaFunction struct {
	Name string `json:"name"`
	// Arguments is a JSON string per the OpenAI contract, not a nested object.
	Arguments string `json:"arguments"`
}

type oaTool struct {
	Type     string    `json:"type"`
	Function oaToolDef `json:"function"`
}

type oaToolDef struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	Parameters  json.RawMessage `json:"parameters,omitempty"`
}

type oaResponse struct {
	Choices []oaChoice `json:"choices"`
	Usage   *oaUsage   `json:"usage,omitempty"`
}

type oaChoice struct {
	Message      oaMessage `json:"message"`
	FinishReason string    `json:"finish_reason,omitempty"`
}

type oaUsage struct {
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
	TotalTokens      int `json:"total_tokens"`
}

// tokens is the usage as a block. prompt_tokens has no cache split, so it
// is all fresh input.
func (u *oaUsage) tokens() llmusage.Tokens {
	return llmusage.Tokens{Input: int64(u.PromptTokens), Output: int64(u.CompletionTokens)}
}

// Streaming wire types: the chat.completion.chunk subset the loop reads.
type oaStreamOptions struct {
	IncludeUsage bool `json:"include_usage"`
}

type oaStreamChunk struct {
	Choices []struct {
		Delta struct {
			Content   string            `json:"content"`
			ToolCalls []oaToolCallDelta `json:"tool_calls"`
		} `json:"delta"`
		FinishReason string `json:"finish_reason"`
	} `json:"choices"`
	Usage *oaUsage `json:"usage"`
	// Error is an object ({message,type}) or a string; Object "error" with
	// Message is the legacy vLLM shape (the ollama client reads the same).
	Error   json.RawMessage `json:"error"`
	Object  string          `json:"object"`
	Message string          `json:"message"`
}

type oaToolCallDelta struct {
	Index    *int       `json:"index"`
	ID       string     `json:"id"`
	Type     string     `json:"type"`
	Function oaFunction `json:"function"`
}
