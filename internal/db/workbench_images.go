package db

import (
	"database/sql"
	"errors"
	"fmt"
)

// MaxTargetImages caps the images one workbench target carries.
const MaxTargetImages = 20

// ErrTooManyImages refuses an attach past MaxTargetImages.
var ErrTooManyImages = fmt.Errorf("a target carries at most %d images", MaxTargetImages)

// WorkbenchTargetImage is an image attached to a workbench target (migration
// 00088). Path is the absolute stored copy under
// <workspace>/project_files/<project_id>/ (internal/workbenchfiles); several
// rows of one workbench may share it (same content on several targets).
type WorkbenchTargetImage struct {
	ID          int64  `json:"id"`
	WorkbenchID int64  `json:"-"`
	TargetID    int64  `json:"target_id"`
	FileName    string `json:"file_name"`
	MIME        string `json:"mime"`
	Size        int64  `json:"size"`
	SHA256      string `json:"sha256"`
	Path        string `json:"path"`
	CreatedAt   string `json:"created_at"`
}

const workbenchTargetImageCols = `id, project_id, target_id, file_name, mime, size, sha256, path, created_at`

// AddWorkbenchTargetImageTx attaches img to its target. The target must be on
// img.WorkbenchID's board (ErrNotInWorkbench otherwise). Attaching content the
// target already carries is a no-op that returns the existing row's id; a new
// image past MaxTargetImages fails with ErrTooManyImages.
func AddWorkbenchTargetImageTx(tx *sql.Tx, img WorkbenchTargetImage) (int64, error) {
	if err := checkTargetInWorkbench(tx, img.WorkbenchID, img.TargetID); err != nil {
		return 0, err
	}
	var id int64
	err := tx.QueryRow(`SELECT id FROM project_target_images WHERE target_id = ? AND sha256 = ?`,
		img.TargetID, img.SHA256).Scan(&id)
	if err == nil {
		return id, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return 0, fmt.Errorf("looking up image on target %d: %w", img.TargetID, err)
	}
	var n int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM project_target_images WHERE target_id = ?`, img.TargetID).Scan(&n); err != nil {
		return 0, fmt.Errorf("counting images of target %d: %w", img.TargetID, err)
	}
	if n >= MaxTargetImages {
		return 0, fmt.Errorf("target %d: %w", img.TargetID, ErrTooManyImages)
	}
	res, err := tx.Exec(`INSERT INTO project_target_images
		(project_id, target_id, file_name, mime, size, sha256, path) VALUES (?, ?, ?, ?, ?, ?, ?)`,
		img.WorkbenchID, img.TargetID, img.FileName, img.MIME, img.Size, img.SHA256, img.Path)
	if err != nil {
		return 0, fmt.Errorf("attaching image to target %d: %w", img.TargetID, err)
	}
	return res.LastInsertId()
}

// RemoveWorkbenchTargetImageTx detaches image id from target targetID of
// workbench projectID and returns its stored path, which the caller discards
// once no row names it (workbenchfiles.Store.Discard). An image of another
// target or workbench reads as ErrNotInWorkbench.
func RemoveWorkbenchTargetImageTx(tx *sql.Tx, projectID, targetID, id int64) (string, error) {
	var path string
	err := tx.QueryRow(`DELETE FROM project_target_images WHERE id = ? AND target_id = ? AND project_id = ?
		RETURNING path`, id, targetID, projectID).Scan(&path)
	if errors.Is(err, sql.ErrNoRows) {
		return "", fmt.Errorf("image %d of target %d: %w", id, targetID, ErrNotInWorkbench)
	}
	if err != nil {
		return "", fmt.Errorf("removing image %d: %w", id, err)
	}
	return path, nil
}

// ListWorkbenchTargetImages returns the target's images, oldest first.
func (db *DB) ListWorkbenchTargetImages(targetID int64) ([]WorkbenchTargetImage, error) {
	rows, err := db.Query(`SELECT `+workbenchTargetImageCols+` FROM project_target_images
		WHERE target_id = ? ORDER BY id`, targetID)
	if err != nil {
		return nil, fmt.Errorf("listing images of target %d: %w", targetID, err)
	}
	defer rows.Close()
	out := []WorkbenchTargetImage{}
	for rows.Next() {
		var m WorkbenchTargetImage
		if err := rows.Scan(&m.ID, &m.WorkbenchID, &m.TargetID, &m.FileName, &m.MIME, &m.Size,
			&m.SHA256, &m.Path, &m.CreatedAt); err != nil {
			return nil, fmt.Errorf("scanning image: %w", err)
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// WorkbenchImagePaths returns the set of stored paths workbench projectID's rows
// still name — what a sweep of its file directory must keep.
func (db *DB) WorkbenchImagePaths(projectID int64) (map[string]bool, error) {
	rows, err := db.Query(`SELECT DISTINCT path FROM project_target_images WHERE project_id = ?`, projectID)
	if err != nil {
		return nil, fmt.Errorf("listing image paths of workbench %d: %w", projectID, err)
	}
	defer rows.Close()
	keep := map[string]bool{}
	for rows.Next() {
		var p string
		if err := rows.Scan(&p); err != nil {
			return nil, fmt.Errorf("scanning image path: %w", err)
		}
		keep[p] = true
	}
	return keep, rows.Err()
}
