package chat

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"strings"
	"sync"

	"watchtower/internal/ai"
	"watchtower/internal/db"
	"watchtower/internal/fsutil"
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

// imageQuerier is a querier that takes image files for its next query only
// (codex.Client: --image).
type imageQuerier interface{ SetImages(paths []string) }

// turnImagePattern names a turn's image files in the system temp
// directory (fsutil.StaleTempPatterns sweeps one a killed turn left).
const turnImagePattern = "wt-chat-image-*"

// writeTurnImages writes each image's checked bytes to its own 0600 temp
// file, held from the stale-temp sweep while the turn runs (CHAT-04: the
// provider gets a path, never the content on argv, and never the owner's
// own path, which could change after the check). release removes them.
// Errors carry the errno only, never a path (FILES-01).
func writeTurnImages(images []TurnImage) (paths []string, release func(), err error) {
	if strings.Contains(os.TempDir(), ",") {
		return nil, nil, errors.New("the temp folder's path (TMPDIR) has a comma, which codex cannot take for an image; set TMPDIR to a path without one")
	}
	var holds []func()
	release = func() {
		for _, h := range holds {
			h() // removes the file, held or not
		}
	}
	for _, img := range images {
		p, werr := fsutil.WritePrivateTemp(turnImagePattern+imageExt(img.MediaType), string(img.Data))
		if werr != nil {
			release()
			return nil, nil, fmt.Errorf("writing a turn image: %w", errnoOnly(werr))
		}
		hold, herr := fsutil.HoldTempFile(p)
		holds = append(holds, hold)
		if herr != nil {
			// As for codex's prompt file: the sweep only takes files older
			// than a turn runs, so the turn goes on.
			log.Printf("chat: a turn image not shielded from the stale-temp sweep: %v", herr)
		}
		paths = append(paths, p)
	}
	return paths, release, nil
}

// errnoOnly is err's errno when it is a path error, else a generic error:
// a temp file's error names its path in its text.
func errnoOnly(err error) error {
	if pe, ok := errors.AsType[*fs.PathError](err); ok {
		return pe.Err
	}
	return errors.New("temp file error")
}

// imageExt is the file extension of an image media type.
func imageExt(mediaType string) string {
	switch mediaType {
	case "image/jpeg":
		return ".jpg"
	case "image/gif":
		return ".gif"
	case "image/webp":
		return ".webp"
	}
	return ".png"
}

func (b *turnBackend) Turn(ctx context.Context, c Command, emit func(Event)) error {
	replay, err := ReplayFromDB(b.d, b.conversationID, c.TurnID, c.Attachments)
	if err != nil {
		return err
	}
	// Text-like attachments are inlined ahead of the replay + user text;
	// images go by file to a querier that takes them (codex --image); any
	// other image or PDF is an *AttachmentError, returned before the
	// provider is called (the session maps it to attachment_unsupported).
	iq, takesImages := b.q.(imageQuerier)
	text, images, err := TurnAttachments(c.Text, c.Attachments, AttachmentCaps{Images: takesImages})
	if err != nil {
		return err
	}
	if len(images) > 0 {
		paths, release, err := writeTurnImages(images)
		if err != nil {
			return err
		}
		defer release()
		iq.SetImages(paths)
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
		emit(failureEvent(c.TurnID, qerr))
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
// v2 events: text → text_delta, a tool start/end → tool_start/tool_end, the
// turn's usage → usage, and a bare boundary → nothing (protocol v2 never wipes
// text).
func ChunkEvents(turnID string, c ai.StreamChunk) []Event {
	switch {
	case c.Routing != nil:
		r := c.Routing
		return []Event{{Type: EventSessionReady, Provider: r.Provider, Model: r.Model, PreferredProvider: r.PreferredProvider, RoutingMode: r.Mode, Reason: r.Reason}}
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
	case c.Usage != nil:
		return []Event{{Type: EventUsage, TurnID: turnID, Model: c.Usage.Model,
			TokensIn: c.Usage.InputTokens, TokensOut: c.Usage.OutputTokens}}
	case c.Text != "":
		return []Event{{Type: EventTextDelta, TurnID: turnID, Text: c.Text}}
	}
	return nil
}
