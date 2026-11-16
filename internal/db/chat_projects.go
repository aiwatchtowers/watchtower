package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

// The chat project writers, ported from the Desktop's ChatProjectQueries
// (spec 2026-11-15-mobile-inbox-design §8) and pinned with them by
// internal/chatstore/testdata/chat_writes.json. Each runs inside the
// caller's write transaction; now is Unix seconds (a Swift Date).
//
// Every write that changes what a project's chats are prompted with
// (instructions, sources, files, delete; not a rename) drops the stored
// provider session of its chats in the same transaction, so each chat's
// next turn starts fresh with the current prompt.

// ChatProjectDefaultName names a project created with a blank name.
const ChatProjectDefaultName = "New project"

// ErrChatProjectGone means no chat project has that id.
var ErrChatProjectGone = errors.New("db: chat project not found")

// CreateChatProjectTx inserts a project; a blank name becomes
// ChatProjectDefaultName. It returns the id and the stored name.
func CreateChatProjectTx(tx *sql.Tx, name string, now float64) (int64, string, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		name = ChatProjectDefaultName
	}
	res, err := tx.Exec(`INSERT INTO chat_projects (name, instructions, created_at, updated_at) VALUES (?, '', ?, ?)`,
		name, now, now)
	if err != nil {
		return 0, "", fmt.Errorf("create chat project: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, "", fmt.Errorf("create chat project: %w", err)
	}
	return id, name, nil
}

// RenameChatProjectTx renames a project; a blank name is ignored (a project
// always has a name to show). ErrChatProjectGone when absent.
func RenameChatProjectTx(tx *sql.Tx, id int64, name string, now float64) error {
	name = strings.TrimSpace(name)
	if name == "" {
		return nil
	}
	return requireChatProject(tx.Exec(`UPDATE chat_projects SET name = ?, updated_at = ? WHERE id = ?`, name, now, id))
}

// SetChatProjectInstructionsTx stores a project's instructions.
func SetChatProjectInstructionsTx(tx *sql.Tx, id int64, instructions string, now float64) error {
	if err := requireChatProject(tx.Exec(`UPDATE chat_projects SET instructions = ?, updated_at = ? WHERE id = ?`,
		instructions, now, id)); err != nil {
		return err
	}
	return DropChatProjectSessionsTx(tx, id)
}

// ArchiveChatProjectTx archives a project.
func ArchiveChatProjectTx(tx *sql.Tx, id int64, now float64) error {
	return requireChatProject(tx.Exec(`UPDATE chat_projects SET archived_at = ?, updated_at = ? WHERE id = ?`, now, now, id))
}

// DeleteChatProjectTx deletes a project: its chats survive detached (ON
// DELETE SET NULL), its sources and file rows go by cascade. It returns the
// project's file paths for the caller to remove after the commit. A missing
// project is no error (nothing to delete), as in Swift.
func DeleteChatProjectTx(tx *sql.Tx, id int64) ([]string, error) {
	paths, err := txStrings(tx, `SELECT DISTINCT path FROM chat_attachments WHERE project_id = ? ORDER BY path`, id)
	if err != nil {
		return nil, fmt.Errorf("delete chat project: %w", err)
	}
	// Before the delete: its chats are detached by ON DELETE SET NULL.
	if err := DropChatProjectSessionsTx(tx, id); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(`DELETE FROM chat_projects WHERE id = ?`, id); err != nil {
		return nil, fmt.Errorf("delete chat project: %w", err)
	}
	return paths, nil
}

// AddChatProjectSourceTx pins a source to a project; false (and nothing
// written) when the same kind and ref is already there.
func AddChatProjectSourceTx(tx *sql.Tx, projectID int64, kind, ref, label string, now float64) (bool, error) {
	res, err := tx.Exec(`INSERT OR IGNORE INTO chat_project_sources (project_id, kind, ref, label) VALUES (?, ?, ?, ?)`,
		projectID, kind, ref, label)
	if err != nil {
		return false, fmt.Errorf("add chat project source: %w", err)
	}
	if n, err := res.RowsAffected(); err != nil || n == 0 {
		return false, err
	}
	if _, err := tx.Exec(`UPDATE chat_projects SET updated_at = ? WHERE id = ?`, now, projectID); err != nil {
		return false, fmt.Errorf("add chat project source: %w", err)
	}
	return true, DropChatProjectSessionsTx(tx, projectID)
}

// RemoveChatProjectSourceTx removes one source; false when none has that id.
func RemoveChatProjectSourceTx(tx *sql.Tx, id int64) (bool, error) {
	var projectID int64
	err := tx.QueryRow(`SELECT project_id FROM chat_project_sources WHERE id = ?`, id).Scan(&projectID)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("remove chat project source: %w", err)
	}
	if _, err := tx.Exec(`DELETE FROM chat_project_sources WHERE id = ?`, id); err != nil {
		return false, fmt.Errorf("remove chat project source: %w", err)
	}
	return true, DropChatProjectSessionsTx(tx, projectID)
}

// RemoveChatProjectFileTx deletes one project file row (never a
// conversation's attachment). removed is false when no project file has that
// id; orphan is the stored file to remove after the commit, "" while
// another row still points at it.
func RemoveChatProjectFileTx(tx *sql.Tx, id int64) (removed bool, orphan string, err error) {
	var path string
	var projectID int64
	err = tx.QueryRow(`SELECT path, project_id FROM chat_attachments WHERE id = ? AND project_id IS NOT NULL`, id).
		Scan(&path, &projectID)
	if errors.Is(err, sql.ErrNoRows) {
		return false, "", nil
	}
	if err != nil {
		return false, "", fmt.Errorf("remove chat project file: %w", err)
	}
	if _, err := tx.Exec(`DELETE FROM chat_attachments WHERE id = ?`, id); err != nil {
		return false, "", fmt.Errorf("remove chat project file: %w", err)
	}
	if err := DropChatProjectSessionsTx(tx, projectID); err != nil {
		return false, "", err
	}
	if orphan, err = ChatAttachmentOrphanTx(tx, path); err != nil {
		return false, "", err
	}
	return true, orphan, nil
}

// ChatAttachmentOrphanTx returns path when no chat_attachments row points at
// it any more (the stored file can go), else "".
func ChatAttachmentOrphanTx(tx *sql.Tx, path string) (string, error) {
	var n int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM chat_attachments WHERE path = ?`, path).Scan(&n); err != nil {
		return "", fmt.Errorf("count chat attachment references: %w", err)
	}
	if n > 0 {
		return "", nil
	}
	return path, nil
}

// DropChatProjectSessionsTx forgets the stored provider session of every
// chat in the project (ChatProjectQueries.dropSessions).
func DropChatProjectSessionsTx(tx *sql.Tx, projectID int64) error {
	if _, err := tx.Exec(`UPDATE chat_conversations SET session_id = NULL WHERE project_id = ?`, projectID); err != nil {
		return fmt.Errorf("drop chat project sessions: %w", err)
	}
	return nil
}

func requireChatProject(res sql.Result, err error) error {
	if err != nil {
		return fmt.Errorf("write chat project: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("write chat project: %w", err)
	}
	if n == 0 {
		return ErrChatProjectGone
	}
	return nil
}

func txStrings(tx *sql.Tx, query string, args ...any) ([]string, error) {
	rows, err := tx.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	var out []string
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}
