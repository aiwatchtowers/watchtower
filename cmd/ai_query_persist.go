package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"

	"watchtower/internal/chat"
	"watchtower/internal/chatstore"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/logredact"
)

// `ai query --persist` (mobile inbox spec 2026-11-15 §8, stage 3): an
// embedded chat's turn saves its own rows through chatstore (BeginEmbedded,
// then every event the stream writes), so the Desktop writes no chat row.
// The main chat is not here: its turns are the chat engine's (#1822).

// The save_error sentences of `ai query --persist`; the Mac shows them as
// is.
const (
	saveReplyFailed     = "Couldn't save the reply"
	finalizeReplyFailed = "Couldn't finalize the reply"
)

// checkQueryPersist validates `ai query --persist`: an embedded chat's
// protocol-v2 turn, named by its conversation and turn.
func checkQueryPersist() error {
	if !aiFlagPersist {
		return nil
	}
	switch {
	case aiFlagEvents != "v2":
		return errors.New("--persist needs --events v2")
	case aiFlagConversation <= 0:
		return errors.New("--persist needs --conversation")
	case aiFlagTurn == "":
		return errors.New("--persist needs --turn")
	}
	return nil
}

// queryPersist is one `ai query --persist` turn's writer.
type queryPersist struct {
	database *db.DB
	turn     queryTurn
	// out writes the turn's save_error lines. Its own writer on the same
	// stdout: the stream's writer calls observer under its lock, and its
	// lines are whole (one Write each), so the two never interleave.
	out *chat.EventWriter
}

// queryTurn is what queryPersist needs of a *chatstore.EmbeddedTurn (a seam
// for tests that make a write fail).
type queryTurn interface {
	Apply(ev chat.Event) error
	Finalize(status string, f *chatstore.Failure) error
	Done() bool
}

// beginQueryPersist writes the turn's starting rows and answers `started`.
func beginQueryPersist(ctx context.Context, cfg *config.Config, dbPath string, w io.Writer) (*queryPersist, error) {
	database, err := db.Open(dbPath)
	if err != nil {
		return nil, fmt.Errorf("--persist: opening the database: %w", err)
	}
	store := chatstore.New(database, db.ChatLeaseDesktop, "")
	et, err := store.BeginEmbedded(ctx, aiFlagConversation, aiQueryOwnerText, aiFlagTurn, cfg.AI.Provider)
	if err != nil {
		_ = database.Close()
		return nil, fmt.Errorf("--persist: your message wasn't sent because it couldn't be saved: %w", err)
	}
	out := chat.NewEventWriter(w)
	_ = out.Emit(chat.Event{Type: chat.EventStarted, ConversationID: aiFlagConversation,
		OwnerMessageID: et.OwnerID, AssistantMessageID: et.MessageID, TurnID: aiFlagTurn})
	return &queryPersist{database: database, turn: et, out: out}, nil
}

// saveError tells the Mac a write of the turn failed ("Couldn't save the
// reply: …"): the embedded chat shows the sentence under the thread. A
// deleted conversation is no save failure.
func (q *queryPersist) saveError(what string, err error) {
	if errors.Is(err, chatstore.ErrConversationGone) {
		return
	}
	_ = q.out.Emit(chat.Event{Type: chat.EventSaveError, TurnID: aiFlagTurn, Message: what + ": " + err.Error()})
}

// observer folds each written event into the turn; nil without --persist. A
// failure after the process was told to stop (the embedded chat's Stop is a
// SIGTERM) is the owner's Stop: the reply ends `partial`, as the engine
// writes it. A failed write is logged and answered with save_error.
func (q *queryPersist) observer(ctx context.Context) func(chat.Event) {
	if q == nil {
		return nil
	}
	return func(ev chat.Event) {
		var err error
		what := saveReplyFailed
		if ev.Type == chat.EventError && ctx.Err() != nil {
			err = q.turn.Finalize(chatstore.StatusPartial, nil)
			what = finalizeReplyFailed
		} else {
			err = q.turn.Apply(ev)
		}
		if err != nil {
			stderrLogf("ai query: conversation %d: saving turn %s failed: %s", aiFlagConversation, aiFlagTurn, logredact.Full(err))
			q.saveError(what, err)
		}
	}
}

// close ends a turn the stream left open as `partial`, then closes the
// database.
func (q *queryPersist) close() {
	if !q.turn.Done() {
		if err := q.turn.Finalize(chatstore.StatusPartial, nil); err != nil {
			stderrLogf("ai query: conversation %d: finalizing turn %s failed: %s", aiFlagConversation, aiFlagTurn, logredact.Full(err))
			q.saveError(finalizeReplyFailed, err)
		}
	}
	if q.database != nil {
		_ = q.database.Close()
	}
}
