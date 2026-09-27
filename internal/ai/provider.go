package ai

import (
	"context"
	"encoding/json"
)

// StreamChunk is one piece of a streamed assistant turn. ToolBoundary marks a
// tool call interrupting the turn: any text streamed before it was pre-tool
// reasoning (the "let me check X first" preamble), so a v1 consumer discards
// what it has shown and starts the visible answer fresh from the text that
// follows. Text is empty on a boundary chunk. Tool, when set, reports one tool
// call's start or end — only from a loop whose tool events were switched on
// (agentloop.Client.EmitToolEvents, used by the protocol-v2 chat session).
type StreamChunk struct {
	Text         string
	ToolBoundary bool
	Tool         *ToolEvent
}

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
