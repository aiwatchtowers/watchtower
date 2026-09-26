package ai

import "context"

// StreamChunk is one piece of a streamed assistant turn. ToolBoundary marks a
// tool call interrupting the turn: any text streamed before it was pre-tool
// reasoning (the "let me check X first" preamble), so the consumer discards what
// it has shown and starts the visible answer fresh from the text that follows.
// Text is empty on a boundary chunk.
type StreamChunk struct {
	Text         string
	ToolBoundary bool
}

// Provider is the interface for AI query clients (both streaming and sync).
// ai.Client (Claude) and codex.Client both implement this interface.
type Provider interface {
	Query(ctx context.Context, systemPrompt, userMessage, sessionID string) (<-chan StreamChunk, <-chan error, <-chan string)
	QuerySync(ctx context.Context, systemPrompt, userMessage, sessionID string) (string, *Usage, error)
}
