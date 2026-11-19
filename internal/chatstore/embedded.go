package chatstore

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"watchtower/internal/chat"
)

// EmbeddedTurn is one turn of an embedded chat (target, track, idea,
// meeting, tuning, the automation editor) saved by its own `ai query
// --events v2 --persist` process: the Go twin of the Desktop's
// DatabaseEmbeddedChatStore as EmbeddedChatEngine drives it. An embedded
// chat is a linear thread: no parent ids, no active leaf, no lease, no
// artifacts. Apply and Finalize run on one goroutine.
type EmbeddedTurn struct {
	s         *Store
	conv      int64
	OwnerID   int64 // 0 = a hidden prompt wrote no owner row
	MessageID int64 // the reply's row
	turnID    string

	text      strings.Builder
	steps     []string // tool ids in start order: a step's seq is its place
	usage     *usage
	lastFlush time.Time
	done      bool
}

// BeginEmbedded is ChatMessageQueries.beginEmbeddedTurn: in one
// transaction, the owner row (nil ownerText: none) and the reply's empty
// `partial` row recording provider ("" = NULL). ErrConversationGone when the
// conversation does not exist, ErrNotEmbedded (nothing written) when it is a
// main chat.
func (s *Store) BeginEmbedded(ctx context.Context, conv int64, ownerText *string, turnID, provider string) (*EmbeddedTurn, error) {
	now := seconds(s.now())
	et := &EmbeddedTurn{s: s, conv: conv, turnID: turnID}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("starting embedded chat turn: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	// An embedded chat only: a main chat's rows are the chat engine's, and
	// a turn written here would race its per-conversation turn lock.
	if err := requireEmbeddedTx(tx, conv); err != nil {
		return nil, err
	}
	if ownerText != nil {
		res, err := tx.Exec(`INSERT INTO chat_messages (conversation_id, role, text, created_at, turn_id) VALUES (?, 'user', ?, ?, ?)`,
			conv, *ownerText, now, turnID)
		if err != nil {
			return nil, fmt.Errorf("inserting the owner message: %w", err)
		}
		if et.OwnerID, err = res.LastInsertId(); err != nil {
			return nil, err
		}
	}
	res, err := tx.Exec(`INSERT INTO chat_messages (conversation_id, role, text, created_at, turn_id, status, provider)
		VALUES (?, 'assistant', '', ?, ?, 'partial', ?)`, conv, now, turnID, sql.NullString{String: provider, Valid: provider != ""})
	if err != nil {
		return nil, fmt.Errorf("inserting the reply: %w", err)
	}
	if et.MessageID, err = res.LastInsertId(); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("starting embedded chat turn: %w", err)
	}
	return et, nil
}

// Done reports whether the turn's end is on disk.
func (et *EmbeddedTurn) Done() bool { return et.done }

// Apply folds one event as EmbeddedChatEngine does: the routing's actual
// provider and model on the reply, the text flushed at most once per
// FlushInterval (the first delta at once), each step written as it starts
// and ends (CHAT-02), the usage kept for the end; turn_done and a turn error
// end the turn (Finalize).
func (et *EmbeddedTurn) Apply(ev chat.Event) error {
	if et.done {
		return nil
	}
	if ev.Type == chat.EventSessionReady {
		return et.saveActual(ev.Provider, ev.Model)
	}
	if ev.TurnID != "" && ev.TurnID != et.turnID {
		return nil
	}
	now := et.s.now()
	switch ev.Type {
	case chat.EventTextDelta:
		et.text.WriteString(ev.Text)
		if now.Sub(et.lastFlush) >= FlushInterval {
			et.lastFlush = now
			return et.write(func(tx *sql.Tx) error {
				res, err := tx.Exec(`UPDATE chat_messages SET text = ? WHERE id = ?`, et.text.String(), et.MessageID)
				return requireRow(res, err)
			})
		}
	case chat.EventToolStart:
		seq := -1
		for i, id := range et.steps {
			if id == ev.ID {
				seq = i
			}
		}
		if seq < 0 {
			et.steps = append(et.steps, ev.ID)
			seq = len(et.steps) - 1
		}
		return et.write(func(tx *sql.Tx) error {
			return upsertStepStartTx(tx, et.MessageID, seq, ev.ID, ev.Name, argsJSON(ev.Args), seconds(now))
		})
	case chat.EventToolEnd:
		return et.write(func(tx *sql.Tx) error { return finishStepTx(tx, et.MessageID, ev, seconds(now)) })
	case chat.EventUsage:
		et.usage = &usage{in: ev.TokensIn, out: ev.TokensOut, model: ev.Model}
	case chat.EventTurnDone:
		if ev.Status == chat.StatusComplete {
			return et.Finalize(StatusComplete, nil)
		}
		return et.Finalize(StatusPartial, nil)
	case chat.EventError:
		f := &Failure{Code: ev.Code, Message: ev.Message, Reason: ev.Reason}
		status := StatusError
		if f.PersistenceCode() == codeQuotaExhausted && et.text.Len() > 0 {
			status = StatusPartial
		}
		return et.Finalize(status, f)
	}
	return nil
}

// saveActual is DatabaseEmbeddedChatStore.saveActual.
func (et *EmbeddedTurn) saveActual(provider, model string) error {
	if provider == "" {
		return nil
	}
	return et.write(func(tx *sql.Tx) error {
		_, err := tx.Exec(`UPDATE chat_messages SET provider = ?, model = ? WHERE id = ? AND conversation_id = ?`,
			provider, model, et.MessageID, et.conv)
		return err
	})
}

// Finalize is the engine's persistFinal: the usage (saveEmbeddedUsage), then
// the text, status and error (finalizeEmbedded), and a complete reply
// touches the conversation — one transaction. A second call is a no-op.
func (et *EmbeddedTurn) Finalize(status string, f *Failure) error {
	if et.done {
		return nil
	}
	var code, msg sql.NullString
	if f != nil {
		code, msg = sql.NullString{String: f.PersistenceCode(), Valid: true}, sql.NullString{String: f.Message, Valid: true}
	}
	now := seconds(et.s.now())
	err := et.write(func(tx *sql.Tx) error {
		if u := et.usage; u != nil {
			res, err := tx.Exec(`UPDATE chat_messages SET tokens_in = ?, tokens_out = ? WHERE id = ?`, u.in, u.out, et.MessageID)
			if err := requireRow(res, err); err != nil {
				return err
			}
			if err := setModelTx(tx, et.MessageID, u); err != nil {
				return err
			}
		}
		res, err := tx.Exec(`UPDATE chat_messages SET text = ?, status = ?, error_code = ?, error_message = ? WHERE id = ?`,
			et.text.String(), status, code, msg, et.MessageID)
		if err := requireRow(res, err); err != nil {
			return err
		}
		if status != StatusComplete {
			return nil
		}
		_, err = tx.Exec(`UPDATE chat_conversations SET updated_at = ? WHERE id = ?`, now, et.conv)
		return err
	})
	if err == nil || errors.Is(err, ErrConversationGone) {
		et.done = true
	}
	return err
}

func (et *EmbeddedTurn) write(fn func(*sql.Tx) error) error {
	err := et.s.db.WithTx(fn)
	if isForeignKeyFailure(err) {
		return ErrConversationGone
	}
	return err
}
