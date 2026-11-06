package ai

import (
	"context"
	"encoding/json"

	"watchtower/internal/llmusage"
)

// RoutingMetadata describes a preflight decision; it never changes text already shown.
type RoutingMetadata struct {
	Provider, Model, PreferredProvider, Mode, Reason string
}

// StreamChunk is one piece of a streamed assistant turn. ToolBoundary marks a
// tool call interrupting the turn: any text streamed before it was pre-tool
// reasoning (the "let me check X first" preamble), so a v1 consumer discards
// what it has shown and starts the visible answer fresh from the text that
// follows. Text is empty on a boundary chunk. Tool, when set, reports one tool
// call's start or end — only from a loop whose tool events were switched on
// (agentloop.Client.EmitToolEvents, used by the protocol-v2 chat session).
// Usage, when set, is the turn's token totals — likewise only for a consumer
// that switched those events on (codex.Client.EmitToolEvents).
type StreamChunk struct {
	Routing      *RoutingMetadata
	Text         string
	ToolBoundary bool
	Tool         *ToolEvent
	Usage        *TurnUsage
}

// TurnUsage is one streamed turn's usage block, with the split (fresh input,
// cache reads and writes, output, reported cost) every transport fills the
// same way.
type TurnUsage struct {
	Model string
	llmusage.Tokens
}

// InputTokens is what a chat message records as its input (CHAT-01): every
// input token, cached ones included.
func (u TurnUsage) InputTokens() int { return int(u.AllInput()) }

// OutputTokens is the turn's output tokens.
func (u TurnUsage) OutputTokens() int { return int(u.Output) }

// ToolEvent is one tool call observed by an in-process tool loop: a start
// (Done=false, Args set) or an end (Done=true, OK and Result set).
type ToolEvent struct {
	ID     string
	Name   string
	Args   json.RawMessage
	Done   bool
	OK     bool
	Result string
}

// Provider is the interface for AI query clients (both streaming and sync).
// ai.Client (Claude) and codex.Client both implement this interface.
type Provider interface {
	Query(ctx context.Context, systemPrompt, userMessage, sessionID string) (<-chan StreamChunk, <-chan error, <-chan string)
	QuerySync(ctx context.Context, systemPrompt, userMessage, sessionID string) (string, *Usage, error)
}
