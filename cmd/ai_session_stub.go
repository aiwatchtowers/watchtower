package cmd

import (
	"context"

	"watchtower/internal/ai"
	"watchtower/internal/chat"
)

// aiSessionFlagStubReply (hidden, tests only): the session answers every
// turn with this text at once instead of calling a provider. The Desktop's
// chat timing test (ChatPersistTimingTests) measures the start path with it;
// nothing else passes it. aiQueryFlagStubReply is the same for `ai query`
// (the embedded chats' path, measured by the same test).
var (
	aiSessionFlagStubReply string
	aiQueryFlagStubReply   string
)

func init() {
	f := aiSessionCmd.Flags()
	f.StringVar(&aiSessionFlagStubReply, "test-stub-reply", "", "tests only: answer every turn with this text, no provider")
	_ = f.MarkHidden("test-stub-reply")
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

// stubSessionBackend answers each turn with one text delta and turn_done.
type stubSessionBackend struct{ reply string }

func (stubSessionBackend) Start(context.Context) (string, error) { return "", nil }

func (b stubSessionBackend) Turn(_ context.Context, c chat.Command, emit func(chat.Event)) error {
	emit(chat.Event{Type: chat.EventTurnStart, TurnID: c.TurnID})
	emit(chat.Event{Type: chat.EventTextDelta, TurnID: c.TurnID, Text: b.reply})
	emit(chat.Event{Type: chat.EventTurnDone, TurnID: c.TurnID, Status: chat.StatusComplete})
	return nil
}

func (stubSessionBackend) Cancel() error { return nil }
func (stubSessionBackend) Close() error  { return nil }
