package chat

import (
	"context"
	"sync"

	"watchtower/internal/ai"
	"watchtower/internal/db"
)

// Querier is the one-shot streaming call a stateless provider offers;
// ai.Provider (codex, ollama/runtime B) satisfies it.
type Querier interface {
	Query(ctx context.Context, systemPrompt, userMessage, sessionID string) (<-chan ai.StreamChunk, <-chan error, <-chan string)
}

// TurnOption configures NewTurnBackend.
type TurnOption func(*turnBackend)

// WithSystemPrompt sets the system prompt sent with every call.
func WithSystemPrompt(p string) TurnOption { return func(b *turnBackend) { b.systemPrompt = p } }

type turnBackend struct {
	q              Querier
	d              *db.DB
	conversationID int64
	systemPrompt   string

	mu        sync.Mutex
	cancel    context.CancelFunc
	cancelled bool
}

// NewTurnBackend runs every turn as one provider call carrying the replayed
// active path (spec §2.4) — the Codex/Ollama path, which has no provider
// session to keep warm. A querier with tool events (runtime B) has them
// switched on so its tool calls become visible steps.
func NewTurnBackend(q Querier, d *db.DB, conversationID int64, opts ...TurnOption) Backend {
	b := &turnBackend{q: q, d: d, conversationID: conversationID}
	for _, o := range opts {
		o(b)
	}
	if e, ok := q.(interface{ EmitToolEvents() }); ok {
		e.EmitToolEvents()
	}
	return b
}

func (b *turnBackend) Start(ctx context.Context) (string, error) { return "", ctx.Err() }

func (b *turnBackend) Turn(ctx context.Context, c Command, emit func(Event)) error {
	replay, err := ReplayFromDB(b.d, b.conversationID, c.TurnID)
	if err != nil {
		return err
	}
	// Text-like attachments are inlined ahead of the replay + user text; an
	// image/PDF is an *AttachmentError, returned before the provider is
	// called (the session maps it to attachment_unsupported).
	text, err := InlineTextAttachments(c.Text, c.Attachments)
	if err != nil {
		return err
	}

	turnCtx, cancel := context.WithCancel(ctx)
	b.mu.Lock()
	b.cancel, b.cancelled = cancel, false
	b.mu.Unlock()
	defer func() {
		cancel()
		b.mu.Lock()
		b.cancel = nil
		b.mu.Unlock()
	}()

	textCh, errCh, sidCh := b.q.Query(turnCtx, b.systemPrompt, replay+text, "")
	for chunk := range textCh {
		for _, e := range ChunkEvents(c.TurnID, chunk) {
			emit(e)
		}
	}
	for range sidCh {
	}
	var qerr error
	for err := range errCh {
		if err != nil && qerr == nil {
			qerr = err
		}
	}

	b.mu.Lock()
	cancelled := b.cancelled
	b.mu.Unlock()
	switch {
	case cancelled:
		emit(Event{Type: EventTurnDone, TurnID: c.TurnID, Status: StatusInterrupted})
	case qerr != nil && ctx.Err() != nil:
		return ctx.Err()
	case qerr != nil:
		code, retry := ClassifyClaudeError(qerr.Error())
		emit(errorEvent(c.TurnID, code, qerr.Error(), retry))
	default:
		emit(Event{Type: EventTurnDone, TurnID: c.TurnID, Status: StatusComplete})
	}
	return nil
}

func (b *turnBackend) Cancel() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.cancel != nil {
		b.cancelled = true
		b.cancel()
	}
	return nil
}

func (b *turnBackend) Close() error { return b.Cancel() }

// ChunkEvents maps one ai.StreamChunk from a one-call-per-turn provider onto
// v2 events: text → text_delta, a tool start/end → tool_start/tool_end, and a
// bare boundary → nothing (protocol v2 never wipes text).
func ChunkEvents(turnID string, c ai.StreamChunk) []Event {
	switch {
	case c.Tool != nil && !c.Tool.Done:
		return []Event{{Type: EventToolStart, TurnID: turnID, ID: c.Tool.ID, Name: displayToolName(c.Tool.Name),
			Args: toolArgs(string(c.Tool.Args))}}
	case c.Tool != nil:
		ok := c.Tool.OK
		var summary string
		var sources []Source
		if ok {
			summary, sources = SummarizeToolResult(displayToolName(c.Tool.Name), c.Tool.Result)
		} else {
			summary = truncateRunes(collapseSpace(c.Tool.Result), SummaryMaxRunes)
		}
		return []Event{{Type: EventToolEnd, TurnID: turnID, ID: c.Tool.ID, OK: &ok, Summary: summary, Sources: sources}}
	case c.Text != "":
		return []Event{{Type: EventTextDelta, TurnID: turnID, Text: c.Text}}
	}
	return nil
}
