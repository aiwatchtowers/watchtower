package chatstore

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

// ErrProjectGone refuses a new conversation in a chat project that does not
// exist.
var ErrProjectGone = errors.New("chatstore: chat project not found")

// NewConversation is ChatConversationQueries.create for a main chat (no
// context, empty title, prefix title source) in projectID (nil = none), with
// the routing the phone chose (nil or automatic = the column default; pinned
// = setRouting's write).
func (s *Store) NewConversation(ctx context.Context, projectID *int64, routing *Routing) (int64, error) {
	var id int64
	err := s.inTx(ctx, "creating a chat", func(tx *sql.Tx) error {
		var err error
		id, err = newConversationTx(tx, projectID, routing, seconds(s.now()))
		return err
	})
	return id, err
}

func newConversationTx(tx *sql.Tx, projectID *int64, routing *Routing, now float64) (int64, error) {
	if projectID != nil {
		var n int
		if err := tx.QueryRow(`SELECT COUNT(*) FROM chat_projects WHERE id = ?`, *projectID).Scan(&n); err != nil {
			return 0, fmt.Errorf("creating a chat: %w", err)
		}
		if n == 0 {
			return 0, ErrProjectGone
		}
	}
	res, err := tx.Exec(`INSERT INTO chat_conversations (title, project_id, created_at, updated_at)
		VALUES ('', ?, ?, ?)`, projectID, now, now)
	if err != nil {
		return 0, fmt.Errorf("creating a chat: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, fmt.Errorf("creating a chat: %w", err)
	}
	if routing != nil && !routing.Automatic {
		row := &convRow{routingMode: "preferred_reserve"}
		if err := writeRoutingTx(tx, id, row, routing, *routing); err != nil {
			return 0, err
		}
	}
	return id, nil
}

// inTx runs fn in one write transaction; what names the write in errors.
func (s *Store) inTx(ctx context.Context, what string, fn func(tx *sql.Tx) error) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("%s: %w", what, err)
	}
	defer func() { _ = tx.Rollback() }()
	if err := fn(tx); err != nil {
		return err
	}
	return tx.Commit()
}

// ConversationExists says whether main chat conv is there. A Discuss chat
// (context_type set) is not a main chat and counts as absent: the phone
// reaches main chats only (iPhone chat spec §1).
func (s *Store) ConversationExists(ctx context.Context, conv int64) (bool, error) {
	var n int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM chat_conversations WHERE id = ? AND context_type IS NULL`, conv).Scan(&n); err != nil {
		return false, fmt.Errorf("reading a chat: %w", err)
	}
	return n > 0, nil
}

// Pin is ChatConversationQueries.pin. ErrConversationGone when absent or
// not a main chat (Pin, Rename and Delete write main chats only, spec §1).
func (s *Store) Pin(ctx context.Context, conv int64, pinned bool) error {
	return s.inTx(ctx, "writing a chat", func(tx *sql.Tx) error { return pinTx(tx, conv, pinned) })
}

func pinTx(tx *sql.Tx, conv int64, pinned bool) error {
	return requireConversation(tx.Exec(`UPDATE chat_conversations SET pinned = ? WHERE id = ? AND context_type IS NULL`, pinned, conv))
}

// Rename is ChatConversationQueries.rename: the owner's title, with
// title_source 'user' so no AI or prefix title ever writes over it.
func (s *Store) Rename(ctx context.Context, conv int64, title string) error {
	return s.inTx(ctx, "writing a chat", func(tx *sql.Tx) error { return renameTx(tx, conv, title, seconds(s.now())) })
}

func renameTx(tx *sql.Tx, conv int64, title string, now float64) error {
	title = strings.TrimSpace(title)
	if title == "" {
		return ErrInvalid
	}
	return requireConversation(tx.Exec(`UPDATE chat_conversations SET title = ?, title_source = 'user', updated_at = ? WHERE id = ? AND context_type IS NULL`,
		title, now, conv))
}

// Delete is ChatConversationQueries.delete: the row and, by cascade, its
// messages, steps, artifacts, attachment rows and lease. The caller removes
// the attachment folder after it returns (RemoveConversationFiles).
func (s *Store) Delete(ctx context.Context, conv int64) error {
	return s.inTx(ctx, "writing a chat", func(tx *sql.Tx) error { return deleteTx(tx, conv, "") })
}

// deleteTx deletes a main chat (contextType "") or a conversation of
// contextType only.
func deleteTx(tx *sql.Tx, conv int64, contextType string) error {
	if contextType == "" {
		return requireConversation(tx.Exec(`DELETE FROM chat_conversations WHERE id = ? AND context_type IS NULL`, conv))
	}
	return requireConversation(tx.Exec(`DELETE FROM chat_conversations WHERE id = ? AND context_type = ?`, conv, contextType))
}

func requireConversation(res sql.Result, err error) error {
	if err != nil {
		return fmt.Errorf("writing a chat: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("writing a chat: %w", err)
	}
	if n == 0 {
		return ErrConversationGone
	}
	return nil
}
