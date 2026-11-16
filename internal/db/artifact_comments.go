package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"unicode"
)

// The chat artifact comment writers, ported from the Desktop's
// ArtifactCommentQueries (chat_artifact_comments, migration 00082) and pinned
// with them by internal/chatstore/testdata/chat_writes.json. Nothing here
// reaches the assistant (CHAT-05): a sent comment travels only inside the
// owner's own chat message.

// Comment refusals (ArtifactCommentError): an empty body, an empty quote.
var (
	ErrCommentEmptyBody  = errors.New("db: artifact comment body is empty")
	ErrCommentEmptyQuote = errors.New("db: artifact comment quote is empty")
)

// ArtifactCommentAnchor is where a comment points.
type ArtifactCommentAnchor struct {
	Quote, Prefix, Suffix, Heading string
}

// AddArtifactCommentTx stores an open comment; the body is trimmed. now is
// Unix seconds.
func AddArtifactCommentTx(tx *sql.Tx, conv int64, key string, version int64, a ArtifactCommentAnchor, body string, now float64) (int64, error) {
	body = strings.TrimFunc(body, unicode.IsSpace)
	if body == "" {
		return 0, ErrCommentEmptyBody
	}
	if strings.TrimFunc(a.Quote, unicode.IsSpace) == "" {
		return 0, ErrCommentEmptyQuote
	}
	res, err := tx.Exec(`INSERT INTO chat_artifact_comments
  (conversation_id, artifact_key, artifact_version, body, anchor_quote, anchor_prefix, anchor_suffix, anchor_heading, created_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`, conv, key, version, body, a.Quote, a.Prefix, a.Suffix, a.Heading, now)
	if err != nil {
		return 0, fmt.Errorf("add artifact comment: %w", err)
	}
	return res.LastInsertId()
}

// DeleteUnsentArtifactCommentTx deletes an open (unsent) comment, leaving no
// trace; false when id is not an open comment.
func DeleteUnsentArtifactCommentTx(tx *sql.Tx, id int64) (bool, error) {
	return changedRows(tx.Exec(`DELETE FROM chat_artifact_comments WHERE id = ? AND status = 'open'`, id))
}

// ResolveArtifactCommentTx resolves a sent or outdated comment; false when
// id is neither.
func ResolveArtifactCommentTx(tx *sql.Tx, id int64) (bool, error) {
	return changedRows(tx.Exec(`UPDATE chat_artifact_comments SET status = 'resolved' WHERE id = ? AND status IN ('sent', 'outdated')`, id))
}

// MarkArtifactCommentsSentTx marks exactly ids sent at sentAt, only those
// still open; it returns how many it marked.
func MarkArtifactCommentsSentTx(tx *sql.Tx, ids []int64, sentAt float64) (int64, error) {
	var n int64
	for _, id := range ids {
		res, err := tx.Exec(`UPDATE chat_artifact_comments SET status = 'sent', sent_at = ? WHERE id = ? AND status = 'open'`, sentAt, id)
		if err != nil {
			return 0, fmt.Errorf("mark artifact comments sent: %w", err)
		}
		k, err := res.RowsAffected()
		if err != nil {
			return 0, fmt.Errorf("mark artifact comments sent: %w", err)
		}
		n += k
	}
	return n, nil
}

// ApplyArtifactCommentReanchorTx applies a re-anchor plan: moved live
// comments move onto version, lost ones become outdated (keeping the
// version they were last found on). Resolved and outdated rows are never
// touched.
func ApplyArtifactCommentReanchorTx(tx *sql.Tx, moved, lost []int64, version int64) error {
	for _, id := range moved {
		if _, err := tx.Exec(`UPDATE chat_artifact_comments SET artifact_version = ? WHERE id = ? AND status IN ('open', 'sent')`,
			version, id); err != nil {
			return fmt.Errorf("re-anchor artifact comment: %w", err)
		}
	}
	for _, id := range lost {
		if _, err := tx.Exec(`UPDATE chat_artifact_comments SET status = 'outdated' WHERE id = ? AND status IN ('open', 'sent')`,
			id); err != nil {
			return fmt.Errorf("re-anchor artifact comment: %w", err)
		}
	}
	return nil
}

func changedRows(res sql.Result, err error) (bool, error) {
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n > 0, err
}
