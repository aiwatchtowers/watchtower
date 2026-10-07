package db

import (
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Workbench is a folder-bound workbench (Projects POC, migration 00081). Its
// targets and comments live only on its board (PROJ-01,
// docs/inventory/workbench.md).
type Workbench struct {
	ID          int64
	Name        string
	FolderPath  string // absolute, symlinks resolved (ResolveWorkbenchFolder)
	Description string
	CreatedAt   string
	UpdatedAt   string
	// ArchiveAfterDays: closed targets older than this many days leave the
	// board (workbench_target_archive, PROJ-15); 0 = never. Default 14.
	ArchiveAfterDays int
	// ArchivedThrough: the "Archive Closed Targets Now" moment (UTC,
	// YYYY-MM-DDTHH:MM:SSZ); closed work not closed after it is archived
	// whatever ArchiveAfterDays says (PROJ-15). "" = never pressed.
	ArchivedThrough string
}

// WorkbenchSource is a source the workbench's docs name (a channel, a Jira
// project, a Confluence space, a person, a link).
type WorkbenchSource struct {
	ID          int64
	WorkbenchID int64
	Kind        string
	Ref         string
	Label       string
}

var (
	ErrWorkbenchFolderTaken = errors.New("folder is already bound to a workbench")
	ErrWorkbenchNotFound    = errors.New("workbench not found")
	// ErrNotInWorkbench is returned when a target, source or comment
	// named by a workbench write belongs to another workbench, or to none.
	ErrNotInWorkbench = errors.New("does not belong to this workbench")
)

var workbenchSourceKinds = map[string]bool{"slack_channel": true, "jira_project": true, "confluence_space": true, "person": true, "link": true}

// workbenchCols leaves out board_language (00087): the board always follows the
// session language (board item #153), so the column is kept but never read.
const workbenchCols = `id, name, folder_path, description, created_at, updated_at, archive_after_days, archived_through`

// WithTx runs fn in one transaction, committing when it returns nil. fn must
// use only the *sql.Tx it is given: the pool holds a single connection, so a
// db.X call inside fn would wait on itself.
func (db *DB) WithTx(fn func(*sql.Tx) error) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("beginning transaction: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	if err := fn(tx); err != nil {
		return err
	}
	return tx.Commit()
}

// ResolveWorkbenchFolder turns dir into the absolute, symlink-resolved path of
// an existing directory — the only form CreateWorkbench stores, so two spellings
// of one folder can never bind two projects. A folder a workbench must not own
// — root, home or an ancestor, or overlapping one of the protected dirs the
// caller passes (Watchtower's own data) — fails with ErrWorkbenchFolderNotAllowed.
func ResolveWorkbenchFolder(dir string, protected []string) (string, error) {
	if strings.TrimSpace(dir) == "" {
		return "", errors.New("workbench folder is required")
	}
	abs, err := filepath.Abs(dir)
	if err != nil {
		return "", fmt.Errorf("resolving folder %q: %w", dir, err)
	}
	resolved, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return "", fmt.Errorf("resolving folder %q: %w", dir, err)
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return "", fmt.Errorf("resolving folder %q: %w", dir, err)
	}
	if !info.IsDir() {
		return "", fmt.Errorf("%s is not a directory", resolved)
	}
	if err := checkWorkbenchFolderAllowed(resolved, protected); err != nil {
		return "", err
	}
	return resolved, nil
}

// CreateWorkbench binds a new workbench to folder, which must already be resolved
// (ResolveWorkbenchFolder). A folder bound to another workbench fails with
// ErrWorkbenchFolderTaken.
func (db *DB) CreateWorkbench(name, folder string) (int64, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return 0, errors.New("workbench name is required")
	}
	if !filepath.IsAbs(folder) {
		return 0, fmt.Errorf("workbench folder %q must be an absolute, resolved path", folder)
	}
	if err := checkFolderLineBreaks(folder); err != nil {
		return 0, err
	}
	// APFS is case-insensitive, so another spelling of a bound folder is the
	// same folder; the UNIQUE index below compares bytes.
	var taken int64
	err := db.QueryRow(`SELECT id FROM projects WHERE folder_path = ? COLLATE NOCASE LIMIT 1`, folder).Scan(&taken)
	if err == nil {
		return 0, fmt.Errorf("%s: %w", folder, ErrWorkbenchFolderTaken)
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return 0, fmt.Errorf("checking folder %s: %w", folder, err)
	}
	res, err := db.Exec(`INSERT INTO projects (name, folder_path) VALUES (?, ?)`, name, folder)
	if err != nil {
		if strings.Contains(err.Error(), "UNIQUE constraint failed: projects.folder_path") {
			return 0, fmt.Errorf("%s: %w", folder, ErrWorkbenchFolderTaken)
		}
		return 0, fmt.Errorf("inserting workbench: %w", err)
	}
	return res.LastInsertId()
}

func scanWorkbench(row interface{ Scan(...any) error }) (*Workbench, error) {
	var p Workbench
	var archivedThrough sql.NullString
	if err := row.Scan(&p.ID, &p.Name, &p.FolderPath, &p.Description, &p.CreatedAt, &p.UpdatedAt,
		&p.ArchiveAfterDays, &archivedThrough); err != nil {
		return nil, err
	}
	p.ArchivedThrough = archivedThrough.String
	return &p, nil
}

// GetWorkbench returns workbench id, or ErrWorkbenchNotFound.
func (db *DB) GetWorkbench(id int64) (*Workbench, error) {
	p, err := scanWorkbench(db.QueryRow(`SELECT `+workbenchCols+` FROM projects WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("workbench %d: %w", id, ErrWorkbenchNotFound)
	}
	if err != nil {
		return nil, fmt.Errorf("getting workbench %d: %w", id, err)
	}
	return p, nil
}

// WorkbenchByFolder returns the workbench bound to folder — an absolute,
// symlink-resolved path (ResolveWorkbenchFolder's form), compared the way
// CreateWorkbench does (case-insensitively: APFS) — or ErrWorkbenchNotFound.
// A subfolder of a workbench folder is not that workbench.
func (db *DB) WorkbenchByFolder(folder string) (*Workbench, error) {
	p, err := scanWorkbench(db.QueryRow(`SELECT `+workbenchCols+` FROM projects
		WHERE folder_path = ? COLLATE NOCASE ORDER BY id LIMIT 1`, folder))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("%s: %w", folder, ErrWorkbenchNotFound)
	}
	if err != nil {
		return nil, fmt.Errorf("finding the workbench of %s: %w", folder, err)
	}
	return p, nil
}

// ListWorkbenches returns every workbench in id order.
func (db *DB) ListWorkbenches() ([]Workbench, error) {
	rows, err := db.Query(`SELECT ` + workbenchCols + ` FROM projects ORDER BY id`)
	if err != nil {
		return nil, fmt.Errorf("listing projects: %w", err)
	}
	defer rows.Close()
	var out []Workbench
	for rows.Next() {
		p, err := scanWorkbench(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning workbench: %w", err)
		}
		out = append(out, *p)
	}
	return out, rows.Err()
}

// UpdateWorkbenchDescription replaces the workbench's description (trimmed).
func (db *DB) UpdateWorkbenchDescription(id int64, description string) error {
	res, err := db.Exec(`UPDATE projects SET description = ?,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?`, strings.TrimSpace(description), id)
	if err != nil {
		return fmt.Errorf("updating workbench %d: %w", id, err)
	}
	return requireAffected(res, fmt.Errorf("workbench %d: %w", id, ErrWorkbenchNotFound))
}

// SetWorkbenchArchiveDays sets after how many days closed targets of
// workbench projectID are archived (0 = never). It is the Go writer for
// tests and tooling; the only production writer is the Desktop's
// WorkbenchQueries.setArchiveAfterDays (WatchtowerCore, via GRDB). The
// column's CHECK (0...365) is the rule both share.
func (db *DB) SetWorkbenchArchiveDays(projectID int64, days int) error {
	res, err := db.Exec(`UPDATE projects SET archive_after_days = ?,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?`, days, projectID)
	if err != nil {
		return fmt.Errorf("setting workbench %d archive days to %d: %w", projectID, days, err)
	}
	return requireAffected(res, fmt.Errorf("workbench %d: %w", projectID, ErrWorkbenchNotFound))
}

// ArchiveWorkbenchClosedNow sets workbench projectID's archived_through to
// now, so every closed subtree whose newest close is not after it leaves the
// board ("Archive Closed Targets Now", PROJ-15). Nothing is written per
// target. It is the Go writer for tests and tooling; the only production
// writer is the Desktop's WorkbenchQueries.archiveClosedTargetsNow
// (WatchtowerCore, via GRDB). Both stamp with SQL strftime, never a client
// clock.
func (db *DB) ArchiveWorkbenchClosedNow(projectID int64) error {
	res, err := db.Exec(`UPDATE projects SET archived_through = strftime('%Y-%m-%dT%H:%M:%SZ','now'),
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?`, projectID)
	if err != nil {
		return fmt.Errorf("archiving workbench %d's closed targets: %w", projectID, err)
	}
	return requireAffected(res, fmt.Errorf("workbench %d: %w", projectID, ErrWorkbenchNotFound))
}

// ClearWorkbenchArchivedThrough forgets workbench projectID's Archive Now
// moment ("Undo Archive Now"): what only the moment archived is back, what
// the age rule archives stays archived. The Desktop's dual path is
// WorkbenchQueries.clearArchivedThrough (WatchtowerCore).
func (db *DB) ClearWorkbenchArchivedThrough(projectID int64) error {
	res, err := db.Exec(`UPDATE projects SET archived_through = NULL,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?`, projectID)
	if err != nil {
		return fmt.Errorf("clearing workbench %d's archive moment: %w", projectID, err)
	}
	return requireAffected(res, fmt.Errorf("workbench %d: %w", projectID, ErrWorkbenchNotFound))
}

// DeleteWorkbench removes the workbench; the foreign keys cascade to its targets,
// sources and comments, and its folder files' search index entries
// (kb source project_doc, PROJ-08) and its code questions go in the same
// transaction, so the delete is all-or-nothing (PROJ-02). The folder install
// is removed by the caller.
func (db *DB) DeleteWorkbench(id int64) error {
	return db.WithTx(func(tx *sql.Tx) error {
		res, err := tx.Exec(`DELETE FROM projects WHERE id = ?`, id)
		if err != nil {
			return fmt.Errorf("deleting workbench %d: %w", id, err)
		}
		if err := requireAffected(res, fmt.Errorf("workbench %d: %w", id, ErrWorkbenchNotFound)); err != nil {
			return err
		}
		if err := deleteWorkbenchDocIndex(tx, id); err != nil {
			return err
		}
		return deleteWorkbenchCodeQuestions(tx, id)
	})
}

// deleteWorkbenchCodeQuestions drops a workbench's code questions (spec
// 2026-10-02 §9.4): `chat_conversations` rows of context type
// `code_question` whose `context_id` starts with `<id>:` — the prefix matched
// exactly, so workbench 1 never takes 10's. Their messages, steps and search
// rows go by cascade and the FTS triggers; the questions quote the folder's
// code, so none may outlive the workbench (migration 00104 removed the ones
// earlier deletes left behind).
func deleteWorkbenchCodeQuestions(tx *sql.Tx, projectID int64) error {
	prefix := strconv.FormatInt(projectID, 10) + ":"
	if _, err := tx.Exec(`DELETE FROM chat_conversations WHERE context_type = 'code_question'
		AND substr(context_id, 1, length(?)) = ?`, prefix, prefix); err != nil {
		return fmt.Errorf("deleting workbench %d code questions: %w", projectID, err)
	}
	return nil
}

// deleteWorkbenchDocIndex drops a workbench's folder files from the knowledge index
// (kb_chunks first: the FTS triggers hang off it).
func deleteWorkbenchDocIndex(tx *sql.Tx, projectID int64) error {
	const docs = `SELECT id FROM kb_documents WHERE source = 'project_doc'
		AND json_extract(anchor_json, '$.project_id') = ?`
	pid := strconv.FormatInt(projectID, 10)
	if _, err := tx.Exec(`DELETE FROM kb_chunks WHERE doc_id IN (`+docs+`)`, pid); err != nil {
		return fmt.Errorf("deleting workbench %d search index: %w", projectID, err)
	}
	if _, err := tx.Exec(`DELETE FROM kb_documents WHERE id IN (`+docs+`)`, pid); err != nil {
		return fmt.Errorf("deleting workbench %d search index: %w", projectID, err)
	}
	return nil
}

func requireAffected(res sql.Result, notFound error) error {
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return notFound
	}
	return nil
}

// requireWorkbench fails with ErrWorkbenchNotFound unless workbench id exists.
func requireWorkbench(q targetsQuerier, id int64) error {
	var one int
	err := q.QueryRow(`SELECT 1 FROM projects WHERE id = ?`, id).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("workbench %d: %w", id, ErrWorkbenchNotFound)
	}
	if err != nil {
		return fmt.Errorf("checking workbench %d: %w", id, err)
	}
	return nil
}

const targetWorkbenchQuery = `SELECT project_id FROM targets WHERE id = ?`

// checkTargetInWorkbench fails with ErrNotInWorkbench unless target id is on
// workbench projectID's board.
func checkTargetInWorkbench(q targetsQuerier, projectID, id int64) error {
	return checkOwnedBy(q, targetWorkbenchQuery, "target", projectID, id)
}

func checkOwnedBy(q targetsQuerier, query, noun string, projectID, id int64) error {
	var owner sql.NullInt64
	err := q.QueryRow(query, id).Scan(&owner)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return fmt.Errorf("%s %d does not exist: %w", noun, id, ErrNotInWorkbench)
	case err != nil:
		return fmt.Errorf("checking %s %d: %w", noun, id, err)
	case !owner.Valid || owner.Int64 != projectID:
		return fmt.Errorf("%s %d: %w", noun, id, ErrNotInWorkbench)
	}
	return nil
}

// AddWorkbenchSource adds a source; adding an existing (kind, ref) again returns
// the existing row's id.
func (db *DB) AddWorkbenchSource(s WorkbenchSource) (int64, error) {
	if !workbenchSourceKinds[s.Kind] {
		return 0, fmt.Errorf("invalid workbench source kind %q", s.Kind)
	}
	if strings.TrimSpace(s.Ref) == "" {
		return 0, errors.New("workbench source ref is required")
	}
	if _, err := db.Exec(`INSERT INTO project_sources (project_id, kind, ref, label) VALUES (?, ?, ?, ?)
		ON CONFLICT(project_id, kind, ref) DO NOTHING`, s.WorkbenchID, s.Kind, s.Ref, s.Label); err != nil {
		return 0, fmt.Errorf("adding workbench source: %w", err)
	}
	var id int64
	if err := db.QueryRow(`SELECT id FROM project_sources WHERE project_id = ? AND kind = ? AND ref = ?`,
		s.WorkbenchID, s.Kind, s.Ref).Scan(&id); err != nil {
		return 0, fmt.Errorf("reading workbench source id: %w", err)
	}
	return id, nil
}

// RemoveWorkbenchSource deletes one source of the workbench.
func (db *DB) RemoveWorkbenchSource(projectID, sourceID int64) error {
	res, err := db.Exec(`DELETE FROM project_sources WHERE id = ? AND project_id = ?`, sourceID, projectID)
	if err != nil {
		return fmt.Errorf("removing workbench source %d: %w", sourceID, err)
	}
	return requireAffected(res, fmt.Errorf("workbench source %d: %w", sourceID, ErrNotInWorkbench))
}

// ListWorkbenchSources returns the workbench's sources by kind, then id.
func (db *DB) ListWorkbenchSources(projectID int64) ([]WorkbenchSource, error) {
	rows, err := db.Query(`SELECT id, project_id, kind, ref, label FROM project_sources
		WHERE project_id = ? ORDER BY kind, id`, projectID)
	if err != nil {
		return nil, fmt.Errorf("listing workbench sources: %w", err)
	}
	defer rows.Close()
	var out []WorkbenchSource
	for rows.Next() {
		var s WorkbenchSource
		if err := rows.Scan(&s.ID, &s.WorkbenchID, &s.Kind, &s.Ref, &s.Label); err != nil {
			return nil, fmt.Errorf("scanning workbench source: %w", err)
		}
		out = append(out, s)
	}
	return out, rows.Err()
}
