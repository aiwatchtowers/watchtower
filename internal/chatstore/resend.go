package chatstore

import (
	"context"
	"database/sql"
	"fmt"
)

// Resend fills st's turn command from the stored rows, for a turn whose
// command never reached its session (the engine went away while the
// session was still binding its socket, unified chat spec §7, D23): the
// owner row's text and files, replayed (a new process has seen nothing).
// The actions-outcome block and the screen context of the first send are
// not stored, so they are not resent.
func (s *Store) Resend(ctx context.Context, st Started) (Started, error) {
	tx, err := s.db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return st, fmt.Errorf("reading a turn to resend: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	var text string
	if err := tx.QueryRowContext(ctx, `SELECT text FROM chat_messages WHERE id = ? AND conversation_id = ? AND role = 'user'`,
		st.UserMessageID, st.ConversationID).Scan(&text); err != nil {
		return st, fmt.Errorf("reading a turn to resend: %w", err)
	}
	atts, err := messageAttachmentsTx(tx, st.UserMessageID)
	if err != nil {
		return st, err
	}
	st.SendText, st.Attachments, st.Replay = composeTurnText(text, ""), atts, true
	return st, nil
}
