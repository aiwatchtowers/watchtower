package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
)

// SessionFolderPath is the workbench folder session sessionID was started
// for (terminal_sessions.workbench_folder_id, 00196) — the main repository
// its review, finish gate and report read — and whether that folder has
// left the bench (removed: the path is still the folder's). A row with no
// folder (one started before 00196, or a database not yet migrated past
// it) reads as the workbench's projects.folder_path. ErrTerminalSessionNotFound
// when there is no such session on a workbench.
func (db *DB) SessionFolderPath(ctx context.Context, sessionID int64) (path string, removed bool, err error) {
	ok, err := db.hasColumnsCached("terminal_sessions", "workbench_folder_id")
	if err != nil {
		return "", false, err
	}
	q := `SELECT p.folder_path, 0 FROM terminal_sessions s JOIN projects p ON p.id = s.project_id WHERE s.id = ?`
	if ok {
		q = `SELECT COALESCE(f.folder_path, p.folder_path), f.removed_at IS NOT NULL
			FROM terminal_sessions s JOIN projects p ON p.id = s.project_id
			LEFT JOIN workbench_folders f ON f.id = s.workbench_folder_id
			WHERE s.id = ?`
	}
	err = db.QueryRowContext(ctx, q, sessionID).Scan(&path, &removed)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, fmt.Errorf("session %d on a workbench: %w", sessionID, ErrTerminalSessionNotFound)
	}
	if err != nil {
		return "", false, fmt.Errorf("reading session %d's folder: %w", sessionID, err)
	}
	return path, removed, nil
}

// SessionFolderID is the id of the workbench folder session sessionID was
// started for (the key of its PR states, review threads and ask documents);
// a row with no folder reads as its workbench's home folder (HomeFolderID).
// ErrTerminalSessionNotFound when there is no such session on a workbench;
// ErrWorkbenchNotFound when its workbench has no folder row at all.
func (db *DB) SessionFolderID(ctx context.Context, sessionID int64) (int64, error) {
	ok, err := db.hasColumnsCached("terminal_sessions", "workbench_folder_id")
	if err != nil {
		return 0, err
	}
	col := `NULL`
	if ok {
		col = `s.workbench_folder_id`
	}
	var workbenchID int64
	var folderID sql.NullInt64
	err = db.QueryRowContext(ctx, `SELECT s.project_id, `+col+` FROM terminal_sessions s
		WHERE s.id = ? AND s.project_id IS NOT NULL`, sessionID).Scan(&workbenchID, &folderID)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, fmt.Errorf("session %d on a workbench: %w", sessionID, ErrTerminalSessionNotFound)
	}
	if err != nil {
		return 0, fmt.Errorf("reading session %d's folder: %w", sessionID, err)
	}
	if folderID.Valid {
		return folderID.Int64, nil
	}
	return db.HomeFolderID(ctx, workbenchID)
}
