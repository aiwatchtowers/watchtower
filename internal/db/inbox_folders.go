package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
)

// InboxFolder is one row of inbox_folders (00175): the root (kind 'root',
// ParentID nil), Needs approval (kind 'approvals') or an owner folder. The
// folder tables hold the Inbox menu's arrangement only, never an item
// (STRIP-02); only the CLI writes them, through WithInboxFolderRevision.
type InboxFolder struct {
	ID                      int64
	Kind, Slug, Title, Icon string
	ParentID                *int64
	Position                int
	Hidden                  bool
}

// ErrInboxRevisionConflict is the refusal of a folder write whose expected
// revision is not the tree's: nothing was written. Now is the tree's
// revision, Given the caller's.
type ErrInboxRevisionConflict struct{ Now, Given int64 }

func (e *ErrInboxRevisionConflict) Error() string {
	return fmt.Sprintf("inbox folder revision conflict (revision %d, you had %d)", e.Now, e.Given)
}

// InboxFolderTree reads the folder tree in one read-only transaction: the
// tree's revision, every folder (the root first, then grouped by parent id,
// each sibling list in position order; pre-order is the caller's) and the
// routes (automation id → folder id).
func (db *DB) InboxFolderTree(ctx context.Context) (revision int64, folders []InboxFolder, routes map[int64]int64, err error) {
	tx, err := db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return 0, nil, nil, fmt.Errorf("reading the inbox folder tree: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	if revision, err = inboxFolderRevisionTx(ctx, tx); err != nil {
		return 0, nil, nil, err
	}
	if folders, err = inboxFoldersTx(ctx, tx); err != nil {
		return 0, nil, nil, err
	}
	if routes, err = inboxFolderRoutesTx(ctx, tx); err != nil {
		return 0, nil, nil, err
	}
	return revision, folders, routes, nil
}

func inboxFolderRevisionTx(ctx context.Context, tx *sql.Tx) (int64, error) {
	var rev int64
	if err := tx.QueryRowContext(ctx, `SELECT revision FROM inbox_folder_state WHERE id = 1`).Scan(&rev); err != nil {
		return 0, fmt.Errorf("reading the inbox folder revision: %w", err)
	}
	return rev, nil
}

func inboxFoldersTx(ctx context.Context, tx *sql.Tx) ([]InboxFolder, error) {
	rows, err := tx.QueryContext(ctx, `SELECT id, kind, slug, title, icon, parent_id, position, hidden
		FROM inbox_folders ORDER BY parent_id IS NOT NULL, parent_id, position, id`)
	if err != nil {
		return nil, fmt.Errorf("reading inbox folders: %w", err)
	}
	defer rows.Close()
	folders := []InboxFolder{}
	for rows.Next() {
		var (
			f      InboxFolder
			parent sql.NullInt64
		)
		if err := rows.Scan(&f.ID, &f.Kind, &f.Slug, &f.Title, &f.Icon, &parent, &f.Position, &f.Hidden); err != nil {
			return nil, fmt.Errorf("scanning an inbox folder: %w", err)
		}
		if parent.Valid {
			p := parent.Int64
			f.ParentID = &p
		}
		folders = append(folders, f)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading inbox folders: %w", err)
	}
	return folders, nil
}

func inboxFolderRoutesTx(ctx context.Context, tx *sql.Tx) (map[int64]int64, error) {
	rows, err := tx.QueryContext(ctx, `SELECT automation_id, folder_id FROM inbox_folder_routes`)
	if err != nil {
		return nil, fmt.Errorf("reading inbox folder routes: %w", err)
	}
	defer rows.Close()
	routes := map[int64]int64{}
	for rows.Next() {
		var automationID, folderID int64
		if err := rows.Scan(&automationID, &folderID); err != nil {
			return nil, fmt.Errorf("scanning an inbox folder route: %w", err)
		}
		routes[automationID] = folderID
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading inbox folder routes: %w", err)
	}
	return routes, nil
}

// WithInboxFolderRevision runs one folder or route write as a compare-and-set
// on the tree's revision: in one BEGIN IMMEDIATE transaction it reads the
// revision, refuses with *ErrInboxRevisionConflict (fn not called, nothing
// written) when it is not expect, else runs fn and bumps the revision. An fn
// error rolls everything back and is returned as is. It returns the new
// revision. Never retried here: a write computed against a stale tree could
// land in the wrong place, so the caller re-reads.
func (db *DB) WithInboxFolderRevision(ctx context.Context, expect int64, fn func(tx *sql.Tx) error) (newRevision int64, err error) {
	tx, err := db.BeginTx(ctx, nil) // BEGIN IMMEDIATE (_txlock=immediate)
	if err != nil {
		return 0, fmt.Errorf("starting an inbox folder write: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	now, err := inboxFolderRevisionTx(ctx, tx)
	if err != nil {
		return 0, err
	}
	if now != expect {
		return 0, &ErrInboxRevisionConflict{Now: now, Given: expect}
	}
	if err := fn(tx); err != nil {
		return 0, err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE inbox_folder_state SET revision = revision + 1 WHERE id = 1`); err != nil {
		return 0, fmt.Errorf("bumping the inbox folder revision: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("committing an inbox folder write: %w", err)
	}
	return now + 1, nil
}

// ErrNoInboxArtifact is InboxArtifactFolder's answer for an id that is not
// an inbox artifact (no such output, or one of another kind).
var ErrNoInboxArtifact = errors.New("no inbox artifact")

// InboxArtifactFolder returns the effective folder of an inbox artifact
// (inbox_artifact_folders: its explicit folder ?? its automation's route ??
// the root).
func (db *DB) InboxArtifactFolder(ctx context.Context, outputID int64) (int64, error) {
	var folderID int64
	err := db.QueryRowContext(ctx, `SELECT folder_id FROM inbox_artifact_folders WHERE output_id = ?`, outputID).Scan(&folderID)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, fmt.Errorf("inbox artifact %d: %w", outputID, ErrNoInboxArtifact)
	}
	if err != nil {
		return 0, fmt.Errorf("reading the folder of inbox artifact %d: %w", outputID, err)
	}
	return folderID, nil
}
