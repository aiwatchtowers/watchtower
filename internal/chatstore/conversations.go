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
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, fmt.Errorf("creating a chat: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	if projectID != nil {
		var n int
		if err := tx.QueryRow(`SELECT COUNT(*) FROM chat_projects WHERE id = ?`, *projectID).Scan(&n); err != nil {
			return 0, fmt.Errorf("creating a chat: %w", err)
		}
		if n == 0 {
			return 0, ErrProjectGone
		}
	}
	now := seconds(s.now())
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
	return id, tx.Commit()
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
	res, err := s.db.ExecContext(ctx, `UPDATE chat_conversations SET pinned = ? WHERE id = ? AND context_type IS NULL`, pinned, conv)
	return requireConversation(res, err)
}

// Rename is ChatConversationQueries.rename: the owner's title, with
// title_source 'user' so no AI or prefix title ever writes over it.
func (s *Store) Rename(ctx context.Context, conv int64, title string) error {
	title = strings.TrimSpace(title)
	if title == "" {
		return ErrInvalid
	}
	res, err := s.db.ExecContext(ctx, `UPDATE chat_conversations SET title = ?, title_source = 'user', updated_at = ? WHERE id = ? AND context_type IS NULL`,
		title, seconds(s.now()), conv)
	return requireConversation(res, err)
}

// Delete is ChatConversationQueries.delete: the row and, by cascade, its
// messages, steps, artifacts, attachment rows and lease. The caller removes
// the attachment folder after it returns (RemoveConversationFiles).
func (s *Store) Delete(ctx context.Context, conv int64) error {
	res, err := s.db.ExecContext(ctx, `DELETE FROM chat_conversations WHERE id = ? AND context_type IS NULL`, conv)
	return requireConversation(res, err)
}

// Archive is ChatConversationQueries.archive: the chat leaves the list
// (ReadList skips archived rows) and keeps its messages. ErrConversationGone
// when absent or not a main chat.
func (s *Store) Archive(ctx context.Context, conv int64) error {
	res, err := s.db.ExecContext(ctx, `UPDATE chat_conversations SET archived_at = ? WHERE id = ? AND context_type IS NULL`,
		seconds(s.now()), conv)
	return requireConversation(res, err)
}

// Move is ChatConversationQueries.setProject: conv into projectID (nil =
// out of any project). An actual move also clears the stored provider
// session, so the next turn starts fresh and replays with the new
// project's block. ErrConversationGone when conv is absent or not a main
// chat, ErrProjectGone when the project does not exist.
func (s *Store) Move(ctx context.Context, conv int64, projectID *int64) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("moving a chat: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	var n int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM chat_conversations WHERE id = ? AND context_type IS NULL`, conv).Scan(&n); err != nil {
		return fmt.Errorf("moving a chat: %w", err)
	}
	if n == 0 {
		return ErrConversationGone
	}
	if projectID != nil {
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM chat_projects WHERE id = ?`, *projectID).Scan(&n); err != nil {
			return fmt.Errorf("moving a chat: %w", err)
		}
		if n == 0 {
			return ErrProjectGone
		}
	}
	if _, err := tx.ExecContext(ctx, `UPDATE chat_conversations SET project_id = ?, session_id = NULL
		WHERE id = ? AND project_id IS NOT ?`, projectID, conv, projectID); err != nil {
		return fmt.Errorf("moving a chat: %w", err)
	}
	return tx.Commit()
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
