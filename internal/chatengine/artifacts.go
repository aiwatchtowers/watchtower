package chatengine

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"

	"watchtower/internal/chatstore"
)

// ArtifactComment is a new comment on an artifact's passage (Swift
// ArtifactCommentQueries.add with its CommentAnchor).
type ArtifactComment struct {
	Body    string `json:"body"`
	Quote   string `json:"anchor_quote"`
	Prefix  string `json:"anchor_prefix"`
	Suffix  string `json:"anchor_suffix"`
	Heading string `json:"anchor_heading"`
}

// The artifact_manage ops: every write of the Mac's artifact panel
// (ArtifactPanelModel, ArtifactCommentsModel; spec §5.2, ruling F8).
const (
	ArtifactKeep            = "keep"             // Key, Version → Keep/Update in Knowledge
	ArtifactUnkeep          = "unkeep"           // Key → Remove from Knowledge
	ArtifactCommentAdd      = "comment_add"      // Key, Version, Comment → the comment's id
	ArtifactCommentDelete   = "comment_delete"   // CommentID: an unsent one only
	ArtifactCommentResolve  = "comment_resolve"  // CommentID: a sent or outdated one only
	ArtifactCommentReanchor = "comment_reanchor" // Key, Version, Moved, Lost: the panel's re-anchor plan
	ArtifactEdit            = "edit"             // Key, Version (the base), Content → the new version
)

// ErrLiveSlack refuses keeping an artifact of a conversation that used the
// Live Slack connector (LIVE-01); its code is forbidden.
var ErrLiveSlack = fmt.Errorf("%w: the conversation used Live Slack", ErrForbidden)

// ArtifactRequest is one artifact panel write of a conversation.
type ArtifactRequest struct {
	Op           string
	Conversation int64
	Key          string
	Version      int
	CommentID    int64
	Comment      *ArtifactComment
	// Moved and Lost are a re-anchor plan (ArtifactCommentReanchor.Plan):
	// moved live comments go onto Version, lost ones become outdated.
	Moved, Lost []int64
	// Content is an edit's new text of Version.
	Content string
}

// ManageArtifact applies an artifact panel write. It returns the new
// comment's id (comment_add), the new version (edit) or 0.
func (e *Engine) ManageArtifact(ctx context.Context, r ArtifactRequest) (int64, error) {
	if r.Conversation <= 0 {
		return 0, chatstore.ErrInvalid
	}
	switch r.Op {
	case ArtifactKeep, ArtifactUnkeep, ArtifactCommentAdd, ArtifactCommentReanchor, ArtifactEdit:
		if r.Key == "" || (r.Op != ArtifactUnkeep && r.Version <= 0) {
			return 0, chatstore.ErrInvalid
		}
	case ArtifactCommentDelete, ArtifactCommentResolve:
		if r.CommentID <= 0 {
			return 0, chatstore.ErrInvalid
		}
	default:
		return 0, chatstore.ErrInvalid
	}
	tx, err := e.c.DB.BeginTx(ctx, nil)
	if err != nil {
		return 0, fmt.Errorf("chatengine: artifact write: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	id, err := e.artifactWriteTx(tx, r)
	if err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("chatengine: artifact write: %w", err)
	}
	e.changed(r.Conversation)
	return id, nil
}

func (e *Engine) artifactWriteTx(tx *sql.Tx, r ArtifactRequest) (int64, error) {
	now := e.c.Clock()
	switch r.Op {
	case ArtifactKeep:
		if _, err := artifactVersionTx(tx, r.Conversation, r.Key, r.Version); err != nil {
			return 0, err
		}
		var live sql.NullInt64
		if err := tx.QueryRow(`SELECT live_slack_since FROM chat_conversations WHERE id = ?`, r.Conversation).Scan(&live); err != nil {
			return 0, fmt.Errorf("chatengine: keeping an artifact: %w", err)
		}
		if live.Valid {
			return 0, ErrLiveSlack
		}
		_, err := tx.Exec(`INSERT INTO chat_knowledge_artifacts (conversation_id, artifact_key, version, kept_at)
			VALUES (?, ?, ?, ?)
			ON CONFLICT (conversation_id, artifact_key) DO UPDATE SET version = excluded.version, kept_at = excluded.kept_at`,
			r.Conversation, r.Key, r.Version, now.UTC().Format("2006-01-02T15:04:05Z"))
		return 0, wrapArtifact(err)
	case ArtifactUnkeep:
		_, err := tx.Exec(`DELETE FROM chat_knowledge_artifacts WHERE conversation_id = ? AND artifact_key = ?`, r.Conversation, r.Key)
		return 0, wrapArtifact(err)
	case ArtifactCommentAdd:
		c := r.Comment
		if c == nil || strings.TrimSpace(c.Body) == "" || strings.TrimSpace(c.Quote) == "" {
			return 0, chatstore.ErrInvalid
		}
		if _, err := artifactVersionTx(tx, r.Conversation, r.Key, r.Version); err != nil {
			return 0, err
		}
		res, err := tx.Exec(`INSERT INTO chat_artifact_comments (conversation_id, artifact_key, artifact_version, body,
			anchor_quote, anchor_prefix, anchor_suffix, anchor_heading, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			r.Conversation, r.Key, r.Version, strings.TrimSpace(c.Body), c.Quote, c.Prefix, c.Suffix, c.Heading, seconds(now))
		if err != nil {
			return 0, wrapArtifact(err)
		}
		return res.LastInsertId()
	case ArtifactCommentDelete:
		return 0, oneRow(tx.Exec(`DELETE FROM chat_artifact_comments WHERE id = ? AND conversation_id = ? AND status = 'open'`,
			r.CommentID, r.Conversation))
	case ArtifactCommentResolve:
		return 0, oneRow(tx.Exec(`UPDATE chat_artifact_comments SET status = 'resolved'
			WHERE id = ? AND conversation_id = ? AND status IN ('sent', 'outdated')`, r.CommentID, r.Conversation))
	case ArtifactCommentReanchor:
		for _, id := range r.Moved {
			if _, err := tx.Exec(`UPDATE chat_artifact_comments SET artifact_version = ?
				WHERE id = ? AND conversation_id = ? AND artifact_key = ? AND status IN ('open', 'sent')`,
				r.Version, id, r.Conversation, r.Key); err != nil {
				return 0, wrapArtifact(err)
			}
		}
		for _, id := range r.Lost {
			if _, err := tx.Exec(`UPDATE chat_artifact_comments SET status = 'outdated'
				WHERE id = ? AND conversation_id = ? AND artifact_key = ? AND status IN ('open', 'sent')`,
				id, r.Conversation, r.Key); err != nil {
				return 0, wrapArtifact(err)
			}
		}
		return 0, nil
	default: // ArtifactEdit
		return editArtifactTx(tx, r, seconds(now))
	}
}

// editArtifactTx is ArtifactPanelModel.saveEdit: the owner's text of a
// version stored as a new edited version (MAX(version)+1) with the base's
// kind, title, meta and message; the same text writes nothing.
func editArtifactTx(tx *sql.Tx, r ArtifactRequest, now float64) (int64, error) {
	base, err := artifactVersionTx(tx, r.Conversation, r.Key, r.Version)
	if err != nil {
		return 0, err
	}
	if r.Content == base.content {
		return int64(r.Version), nil
	}
	var next int64
	if err := tx.QueryRow(`SELECT COALESCE(MAX(version), 0) + 1 FROM chat_artifacts WHERE conversation_id = ? AND artifact_key = ?`,
		r.Conversation, r.Key).Scan(&next); err != nil {
		return 0, wrapArtifact(err)
	}
	_, err = tx.Exec(`INSERT INTO chat_artifacts
		(conversation_id, message_id, artifact_key, version, kind, title, content, meta_json, edited, created_at)
		SELECT conversation_id, message_id, artifact_key, ?, kind, title, ?, meta_json, 1, ? FROM chat_artifacts WHERE id = ?`,
		next, r.Content, now, base.id)
	return next, wrapArtifact(err)
}

type artifactRow struct {
	id      int64
	content string
}

// artifactVersionTx is the stored version of (conv, key); ErrNotFound when
// there is none.
func artifactVersionTx(tx *sql.Tx, conv int64, key string, version int) (artifactRow, error) {
	var a artifactRow
	err := tx.QueryRow(`SELECT id, content FROM chat_artifacts WHERE conversation_id = ? AND artifact_key = ? AND version = ?`,
		conv, key, version).Scan(&a.id, &a.content)
	if errors.Is(err, sql.ErrNoRows) {
		return a, chatstore.ErrNotFound
	}
	return a, wrapArtifact(err)
}

func wrapArtifact(err error) error {
	if err == nil {
		return nil
	}
	return fmt.Errorf("chatengine: artifact write: %w", err)
}

// oneRow is a write's error, ErrNotFound when it touched no row.
func oneRow(res sql.Result, err error) error {
	if err != nil {
		return wrapArtifact(err)
	}
	if n, err := res.RowsAffected(); err != nil || n == 0 {
		return chatstore.ErrNotFound
	}
	return nil
}
