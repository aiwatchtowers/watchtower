package chatengine

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"os"
	"time"

	"watchtower/internal/chatstore"
)

// AttachError is a file the composer cannot attach: its code is invalid,
// its message the Mac's line (chatstore.Rejection.Message), which names the
// file — for the owner's screen, never a log (FILES-01).
type AttachError struct {
	Rejection *chatstore.Rejection
}

func (e *AttachError) Error() string { return e.Rejection.Message() }

// Unwrap makes ErrorCode answer invalid.
func (e *AttachError) Unwrap() error { return chatstore.ErrInvalid }

// AttachBytes stores data as a pending file of conv (ChatAttachmentStore
// .importData): validated (AttachError), then written 0600 under the
// conversation's folder with its chat_attachments row. The phone's sealed
// upload lands here too (ruling F7).
func (e *Engine) AttachBytes(ctx context.Context, conv int64, name string, data []byte) (int64, error) {
	kind, rej := chatstore.ValidateAttachment(data, name)
	if rej != nil {
		return 0, &AttachError{Rejection: rej}
	}
	id, err := chatstore.SaveAttachment(ctx, e.c.DB, e.c.FilesDir, conv, name, kind, data, seconds(e.c.Clock()))
	if err == nil {
		e.changed(conv)
	}
	return id, err
}

// AttachPath stores the file the app picked at path as a pending file of
// conv (ChatAttachmentStore.importFile): a regular file only — a folder,
// a symlink, a missing path or a file over its kind's limit is an
// AttachError, and nothing is written.
func (e *Engine) AttachPath(ctx context.Context, conv int64, path string) (int64, error) {
	name, data, err := readAttachable(path)
	if err != nil {
		return 0, err
	}
	return e.AttachBytes(ctx, conv, name, data)
}

func readAttachable(path string) (string, []byte, error) {
	if path == "" {
		return "", nil, chatstore.ErrInvalid
	}
	name, data, rej := chatstore.ReadAttachmentFile(path)
	if rej != nil {
		return "", nil, &AttachError{Rejection: rej}
	}
	return name, data, nil
}

// DiscardAttachment removes a pending file of conv (ChatAttachmentStore
// .discard: the composer's ✕): the row, then the file once no row points
// at it. chatstore.ErrNotFound when conv has no such pending file.
func (e *Engine) DiscardAttachment(ctx context.Context, conv, id int64) error {
	tx, err := e.c.DB.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("chatengine: discarding an attachment: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	var path string
	err = tx.QueryRow(`SELECT path FROM chat_attachments WHERE id = ? AND conversation_id = ? AND message_id IS NULL`, id, conv).Scan(&path)
	if errors.Is(err, sql.ErrNoRows) {
		return chatstore.ErrNotFound
	}
	if err != nil {
		return fmt.Errorf("chatengine: discarding an attachment: %w", err)
	}
	if _, err := tx.Exec(`DELETE FROM chat_attachments WHERE id = ?`, id); err != nil {
		return fmt.Errorf("chatengine: discarding an attachment: %w", err)
	}
	var n int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM chat_attachments WHERE path = ?`, path).Scan(&n); err != nil {
		return fmt.Errorf("chatengine: discarding an attachment: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("chatengine: discarding an attachment: %w", err)
	}
	if n == 0 {
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			log.Printf("chatengine: chat %d: a discarded attachment stayed on disk (%s)", conv, errClass(err))
		}
	}
	e.changed(conv)
	return nil
}

// seconds is a Swift Date's timeIntervalSince1970.
func seconds(t time.Time) float64 { return float64(t.UnixNano()) / 1e9 }
