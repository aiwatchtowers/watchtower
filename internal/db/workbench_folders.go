package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"path/filepath"
	"strconv"
)

// WorkbenchFolder is a workbench_folders row (00196, multi-folder
// workbench): one folder of a workbench. RemovedAt is set once the folder
// left the bench; the row stays so targets and sessions can still name it.
type WorkbenchFolder struct {
	ID, WorkbenchID int64
	FolderPath      string // absolute, symlinks resolved (ResolveWorkbenchFolder)
	Name            string // unique per bench among live rows, NOCASE (UniqueFolderName)
	Position        int
	AddedAt         string
	AddedBy         string // owner | agent_suggestion
	RemovedAt       sql.NullString
}

// Querier runs a single-row read on a *DB or inside a caller's *sql.Tx.
type Querier interface {
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

// workbenchFolderOwnerQuery reads a folder row's workbench (checkOwnedBy).
const workbenchFolderOwnerQuery = `SELECT workbench_id FROM workbench_folders WHERE id = ?`

const workbenchFolderCols = `id, workbench_id, folder_path, name, position, added_at, added_by, removed_at`

func scanWorkbenchFolder(row interface{ Scan(...any) error }) (*WorkbenchFolder, error) {
	var f WorkbenchFolder
	if err := row.Scan(&f.ID, &f.WorkbenchID, &f.FolderPath, &f.Name, &f.Position, &f.AddedAt, &f.AddedBy,
		&f.RemovedAt); err != nil {
		return nil, err
	}
	return &f, nil
}

// UniqueFolderName names the folder at path among its bench's live folders:
// its last path component; if taken, <parent>-<last>; then
// <parent>-<last>-2, -3… (<last>-2… for a folder with no parent name).
// taken reports whether a live folder of the bench already has the name and
// compares NOCASE.
func UniqueFolderName(path string, taken func(name string) bool) string {
	last := filepath.Base(path)
	if !taken(last) {
		return last
	}
	base := last
	if parent := filepath.Base(filepath.Dir(path)); parent != "/" && parent != "." && parent != "" {
		base = parent + "-" + last
		if !taken(base) {
			return base
		}
	}
	for n := 2; ; n++ {
		if name := base + "-" + strconv.Itoa(n); !taken(name) {
			return name
		}
	}
}

// WorkbenchFolders is workbench workbenchID's folders in position order,
// the removed ones too when withRemoved; never nil.
func (db *DB) WorkbenchFolders(ctx context.Context, workbenchID int64, withRemoved bool) ([]WorkbenchFolder, error) {
	q := `SELECT ` + workbenchFolderCols + ` FROM workbench_folders WHERE workbench_id = ?`
	if !withRemoved {
		q += ` AND removed_at IS NULL`
	}
	rows, err := db.QueryContext(ctx, q+` ORDER BY position, id`, workbenchID)
	if err != nil {
		return nil, fmt.Errorf("listing the folders of workbench %d: %w", workbenchID, err)
	}
	defer rows.Close()
	out := []WorkbenchFolder{}
	for rows.Next() {
		f, err := scanWorkbenchFolder(rows)
		if err != nil {
			return nil, fmt.Errorf("listing the folders of workbench %d: %w", workbenchID, err)
		}
		out = append(out, *f)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing the folders of workbench %d: %w", workbenchID, err)
	}
	return out, nil
}

// WorkbenchFolderByID returns folder row id, live or removed, or
// ErrWorkbenchNotFound.
func (db *DB) WorkbenchFolderByID(ctx context.Context, id int64) (*WorkbenchFolder, error) {
	return oneWorkbenchFolder(ctx, db, fmt.Sprintf("workbench folder %d", id),
		`SELECT `+workbenchFolderCols+` FROM workbench_folders WHERE id = ?`, id)
}

// LiveFolderByPath returns the live folder row of path on any bench
// (compared NOCASE: APFS), read through q so a caller's transaction sees its
// own writes, or ErrWorkbenchNotFound.
func (db *DB) LiveFolderByPath(ctx context.Context, q Querier, path string) (*WorkbenchFolder, error) {
	return oneWorkbenchFolder(ctx, q, path, `SELECT `+workbenchFolderCols+` FROM workbench_folders
		WHERE folder_path = ? COLLATE NOCASE AND removed_at IS NULL`, path)
}

// HomeFolder returns workbench workbenchID's home folder: its live row whose
// path is projects.folder_path. ErrWorkbenchNotFound when there is none.
func (db *DB) HomeFolder(ctx context.Context, workbenchID int64) (*WorkbenchFolder, error) {
	return oneWorkbenchFolder(ctx, db, fmt.Sprintf("the home folder of workbench %d", workbenchID),
		`SELECT f.id, f.workbench_id, f.folder_path, f.name, f.position, f.added_at, f.added_by, f.removed_at
		FROM workbench_folders f JOIN projects p ON p.id = f.workbench_id
		WHERE f.workbench_id = ? AND f.removed_at IS NULL AND f.folder_path = p.folder_path COLLATE NOCASE
		ORDER BY f.id LIMIT 1`, workbenchID)
}

// HomeFolderID is HomeFolder's row id.
func (db *DB) HomeFolderID(ctx context.Context, workbenchID int64) (int64, error) {
	f, err := db.HomeFolder(ctx, workbenchID)
	if err != nil {
		return 0, err
	}
	return f.ID, nil
}

func oneWorkbenchFolder(ctx context.Context, q Querier, what, query string, args ...any) (*WorkbenchFolder, error) {
	f, err := scanWorkbenchFolder(q.QueryRowContext(ctx, query, args...))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("%s: %w", what, ErrWorkbenchNotFound)
	}
	if err != nil {
		return nil, fmt.Errorf("reading %s: %w", what, err)
	}
	return f, nil
}

// DeclineFolder records the owner's "Never for This Folder": the agent never
// suggests path for workbench workbenchID again. Declining again is no error.
func (db *DB) DeclineFolder(ctx context.Context, workbenchID int64, path string) error {
	if _, err := db.ExecContext(ctx, `INSERT INTO workbench_folder_declines (workbench_id, folder_path) VALUES (?, ?)
		ON CONFLICT (workbench_id, folder_path) DO NOTHING`, workbenchID, path); err != nil {
		return fmt.Errorf("declining folder %s for workbench %d: %w", path, workbenchID, err)
	}
	return nil
}

// FolderDeclined reports whether the owner declined path for workbench
// workbenchID (compared NOCASE), read through q.
func (db *DB) FolderDeclined(ctx context.Context, q Querier, workbenchID int64, path string) (bool, error) {
	var one int
	err := q.QueryRowContext(ctx, `SELECT 1 FROM workbench_folder_declines WHERE workbench_id = ? AND folder_path = ?`,
		workbenchID, path).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("reading the declines of workbench %d: %w", workbenchID, err)
	}
	return true, nil
}

// SetTargetFolderTx sets target targetID's folder inside the caller's
// transaction; an invalid folderID is the home folder. A folder of another
// workbench, or a target on no board, fails with ErrNotInWorkbench.
func (db *DB) SetTargetFolderTx(tx *sql.Tx, targetID int64, folderID sql.NullInt64) error {
	var workbenchID sql.NullInt64
	err := tx.QueryRow(targetWorkbenchQuery, targetID).Scan(&workbenchID)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return fmt.Errorf("target %d does not exist: %w", targetID, ErrNotInWorkbench)
	case err != nil:
		return fmt.Errorf("checking target %d: %w", targetID, err)
	case !workbenchID.Valid:
		return fmt.Errorf("target %d: %w", targetID, ErrNotInWorkbench)
	}
	if folderID.Valid {
		if err := checkOwnedBy(tx, workbenchFolderOwnerQuery, "workbench folder", workbenchID.Int64, folderID.Int64); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(`UPDATE targets SET workbench_folder_id = ? WHERE id = ?`, folderID, targetID); err != nil {
		return fmt.Errorf("setting the folder of target %d: %w", targetID, err)
	}
	return nil
}
