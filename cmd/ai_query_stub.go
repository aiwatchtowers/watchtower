package cmd

import (
	"context"

	"watchtower/internal/ai"
)

// aiQueryFlagStubReply (hidden, tests only): `ai query` answers with this
// text at once instead of calling a provider. The Desktop's embedded-chat
// timing gate (ChatPersistTimingTests, mobile Inbox spec §8, ask #1361)
// measures the `ai query --persist` start path with it; nothing else
// passes it.
var aiQueryFlagStubReply string

func init() {
	q := aiQueryCmd.Flags()
	q.StringVar(&aiQueryFlagStubReply, "test-stub-reply", "", "tests only: answer with this text, no provider")
	_ = q.MarkHidden("test-stub-reply")
}

type queryClient interface {
	Query(ctx context.Context, systemPrompt, userMessage, sessionID string) (<-chan ai.StreamChunk, <-chan error, <-chan string)
}

// queryStream is the query's provider stream, or the stub's one chunk.
func queryStream(ctx context.Context, c queryClient, systemPrompt, prompt, sessionID string) (<-chan ai.StreamChunk, <-chan error, <-chan string) {
	if aiQueryFlagStubReply == "" {
		return c.Query(ctx, systemPrompt, prompt, sessionID)
	}
	text := make(chan ai.StreamChunk, 1)
	text <- ai.StreamChunk{Text: aiQueryFlagStubReply}
	close(text)
	errs, sid := make(chan error), make(chan string)
	close(errs)
	close(sid)
	return text, errs, sid
}
