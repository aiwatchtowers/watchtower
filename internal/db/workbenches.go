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
// targets, documents and comments live only on its board (PROJ-01,
// docs/inventory/workbench.md).
type Workbench struct {
	ID          int64
	Name        string
	FolderPath  string // absolute, symlinks resolved (ResolveWorkbenchFolder)
	Description string
	CreatedAt   string
	UpdatedAt   string
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

// WorkbenchDocument is a file inside the workbench folder (a spec, a plan, a doc)
// that Claude Code attached for owner review.
type WorkbenchDocument struct {
	ID          int64
	WorkbenchID int64
	TargetID    sql.NullInt64
	RelPath     string // relative to the workbench folder
	Kind        string // spec | plan | doc
	Title       string
	CreatedAt   string
	UpdatedAt   string // bumped by every re-attach ("revised")
	Origin      string // agent | import | owner (migration 00083)
}

var (
	ErrWorkbenchFolderTaken = errors.New("folder is already bound to a workbench")
	ErrWorkbenchNotFound    = errors.New("workbench not found")
	// ErrNotInWorkbench is returned when a target, document, source or comment
	// named by a workbench write belongs to another workbench, or to none.
	ErrNotInWorkbench = errors.New("does not belong to this workbench")
)

var (
	workbenchSourceKinds   = map[string]bool{"slack_channel": true, "jira_project": true, "confluence_space": true, "person": true, "link": true}
	workbenchDocumentKinds = map[string]bool{"spec": true, "plan": true, "doc": true}
)

// workbenchCols leaves out board_language (00087): the board always follows the
// session language (board item #153), so the column is kept but never read.
const workbenchCols = `id, name, folder_path, description, created_at, updated_at`

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
	if err := row.Scan(&p.ID, &p.Name, &p.FolderPath, &p.Description, &p.CreatedAt, &p.UpdatedAt); err != nil {
		return nil, err
	}
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

// DeleteWorkbench removes the workbench; the foreign keys cascade to its targets,
// sources, documents and comments, and its documents' search index entries
// (kb source project_doc, PROJ-08) go in the same transaction, so the delete
// is all-or-nothing (PROJ-02). The folder install is removed by the caller.
func (db *DB) DeleteWorkbench(id int64) error {
	return db.WithTx(func(tx *sql.Tx) error {
		res, err := tx.Exec(`DELETE FROM projects WHERE id = ?`, id)
		if err != nil {
			return fmt.Errorf("deleting workbench %d: %w", id, err)
		}
		if err := requireAffected(res, fmt.Errorf("workbench %d: %w", id, ErrWorkbenchNotFound)); err != nil {
			return err
		}
		return deleteWorkbenchDocIndex(tx, id)
	})
}

// deleteWorkbenchDocIndex drops a workbench's documents from the knowledge index
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

const (
	targetWorkbenchQuery   = `SELECT project_id FROM targets WHERE id = ?`
	documentWorkbenchQuery = `SELECT project_id FROM project_documents WHERE id = ?`
)

// checkTargetInWorkbench fails with ErrNotInWorkbench unless target id is on
// workbench projectID's board.
func checkTargetInWorkbench(q targetsQuerier, projectID, id int64) error {
	return checkOwnedBy(q, targetWorkbenchQuery, "target", projectID, id)
}

func checkDocumentInWorkbench(q targetsQuerier, projectID, id int64) error {
	return checkOwnedBy(q, documentWorkbenchQuery, "document", projectID, id)
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

const workbenchDocumentCols = `id, project_id, target_id, rel_path, kind, title, created_at, updated_at, origin`

func scanWorkbenchDocument(row interface{ Scan(...any) error }) (*WorkbenchDocument, error) {
	var d WorkbenchDocument
	if err := row.Scan(&d.ID, &d.WorkbenchID, &d.TargetID, &d.RelPath, &d.Kind, &d.Title, &d.CreatedAt, &d.UpdatedAt, &d.Origin); err != nil {
		return nil, err
	}
	return &d, nil
}

func validateWorkbenchDocument(d WorkbenchDocument) error {
	if strings.TrimSpace(d.RelPath) == "" || filepath.IsAbs(d.RelPath) {
		return fmt.Errorf("document path %q must be relative to the workbench folder", d.RelPath)
	}
	if d.Kind != "" && !workbenchDocumentKinds[d.Kind] {
		return fmt.Errorf("invalid document kind %q", d.Kind)
	}
	return nil
}

// UpsertWorkbenchDocument attaches d as the agent's. On an existing (workbench,
// rel_path) it bumps updated_at ("revised"), marks it origin 'agent' (an
// imported document the agent revises is the agent's from then on) and
// replaces kind/title/target only with the values d sets; created reports
// whether a new row was inserted. rel_path is compared ignoring case, as the
// import and the owner attach do (APFS: another spelling is the same file),
// and the stored spelling is kept. Whether rel_path stays inside the folder
// is the caller's check.
func (db *DB) UpsertWorkbenchDocument(d WorkbenchDocument) (id int64, created bool, err error) {
	if err := validateWorkbenchDocument(d); err != nil {
		return 0, false, err
	}
	err = db.WithTx(func(tx *sql.Tx) error {
		if d.TargetID.Valid {
			if err := checkTargetInWorkbench(tx, d.WorkbenchID, d.TargetID.Int64); err != nil {
				return err
			}
		}
		// An exact match first: rows attached before this lookup ignored
		// case may differ only in case.
		qerr := tx.QueryRow(`SELECT id FROM project_documents WHERE project_id = ? AND rel_path = ? COLLATE NOCASE
			ORDER BY rel_path = ? DESC, id LIMIT 1`,
			d.WorkbenchID, d.RelPath, d.RelPath).Scan(&id)
		if errors.Is(qerr, sql.ErrNoRows) {
			created = true
			id, qerr = insertWorkbenchDocument(tx, d, "agent")
			return qerr
		}
		if qerr != nil {
			return fmt.Errorf("looking up document %q: %w", d.RelPath, qerr)
		}
		return reviseWorkbenchDocument(tx, id, d)
	})
	if err != nil {
		return 0, false, err
	}
	return id, created, nil
}

func insertWorkbenchDocument(tx *sql.Tx, d WorkbenchDocument, origin string) (int64, error) {
	kind := d.Kind
	if kind == "" {
		kind = "doc"
	}
	res, err := tx.Exec(`INSERT INTO project_documents (project_id, target_id, rel_path, kind, title, origin)
		VALUES (?, ?, ?, ?, ?, ?)`, d.WorkbenchID, d.TargetID, d.RelPath, kind, d.Title, origin)
	if err != nil {
		return 0, fmt.Errorf("inserting document %q: %w", d.RelPath, err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, fmt.Errorf("inserting document %q: %w", d.RelPath, err)
	}
	return id, nil
}

func reviseWorkbenchDocument(tx *sql.Tx, id int64, d WorkbenchDocument) error {
	_, err := tx.Exec(`UPDATE project_documents SET
		kind = CASE WHEN ? = '' THEN kind ELSE ? END,
		title = CASE WHEN ? = '' THEN title ELSE ? END,
		target_id = COALESCE(?, target_id),
		origin = 'agent',
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id = ?`, d.Kind, d.Kind, d.Title, d.Title, d.TargetID, id)
	if err != nil {
		return fmt.Errorf("revising document %d: %w", id, err)
	}
	return nil
}

// AttachOwnerWorkbenchDocument attaches d as the owner's (origin 'owner', the
// Desktop's "Add document…"). A rel_path the workbench already has — compared
// ignoring case, the import rule — is left untouched: created=false, and the
// returned relPath is the stored spelling. The owner attaching a file is never
// a revision. Whether rel_path stays inside the folder is the caller's check.
func (db *DB) AttachOwnerWorkbenchDocument(d WorkbenchDocument) (id int64, relPath string, created bool, err error) {
	if err := validateWorkbenchDocument(d); err != nil {
		return 0, "", false, err
	}
	err = db.WithTx(func(tx *sql.Tx) error {
		if err := requireWorkbench(tx, d.WorkbenchID); err != nil {
			return err
		}
		if d.TargetID.Valid {
			if err := checkTargetInWorkbench(tx, d.WorkbenchID, d.TargetID.Int64); err != nil {
				return err
			}
		}
		qerr := tx.QueryRow(`SELECT id, rel_path FROM project_documents WHERE project_id = ? AND rel_path = ? COLLATE NOCASE`,
			d.WorkbenchID, d.RelPath).Scan(&id, &relPath)
		switch {
		case qerr == nil:
			return nil
		case !errors.Is(qerr, sql.ErrNoRows):
			return fmt.Errorf("looking up document %q: %w", d.RelPath, qerr)
		}
		created, relPath = true, d.RelPath
		id, qerr = insertWorkbenchDocument(tx, d, "owner")
		return qerr
	})
	if err != nil {
		return 0, "", false, err
	}
	return id, relPath, created, nil
}

// GetWorkbenchDocument returns document id, or (nil, nil) when absent.
func (db *DB) GetWorkbenchDocument(id int64) (*WorkbenchDocument, error) {
	d, err := scanWorkbenchDocument(db.QueryRow(`SELECT `+workbenchDocumentCols+` FROM project_documents WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("getting document %d: %w", id, err)
	}
	return d, nil
}

// ListWorkbenchDocuments returns the workbench's documents in id order.
func (db *DB) ListWorkbenchDocuments(projectID int64) ([]WorkbenchDocument, error) {
	rows, err := db.Query(`SELECT `+workbenchDocumentCols+` FROM project_documents WHERE project_id = ? ORDER BY id`, projectID)
	if err != nil {
		return nil, fmt.Errorf("listing documents: %w", err)
	}
	defer rows.Close()
	var out []WorkbenchDocument
	for rows.Next() {
		d, err := scanWorkbenchDocument(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning document: %w", err)
		}
		out = append(out, *d)
	}
	return out, rows.Err()
}

// ImportWorkbenchDocuments attaches docs as origin 'import' in one transaction,
// skipping every rel_path the workbench already has — an attached document,
// whatever its origin, is never touched. It returns the rel_paths inserted.
func (db *DB) ImportWorkbenchDocuments(projectID int64, docs []WorkbenchDocument) ([]string, error) {
	var inserted []string
	err := db.WithTx(func(tx *sql.Tx) error {
		if err := requireWorkbench(tx, projectID); err != nil {
			return err
		}
		for _, d := range docs {
			ok, err := importWorkbenchDocument(tx, projectID, d)
			if err != nil {
				return err
			}
			if ok {
				inserted = append(inserted, d.RelPath)
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return inserted, nil
}

// importWorkbenchDocument inserts d unless the workbench already has its
// rel_path — compared ignoring case, since APFS is case-insensitive and the
// agent may have attached another spelling of the same file.
func importWorkbenchDocument(tx *sql.Tx, projectID int64, d WorkbenchDocument) (bool, error) {
	if err := validateWorkbenchDocument(d); err != nil {
		return false, err
	}
	res, err := tx.Exec(`INSERT INTO project_documents (project_id, rel_path, kind, title, origin)
		SELECT ?, ?, ?, ?, 'import' WHERE NOT EXISTS (SELECT 1 FROM project_documents
			WHERE project_id = ? AND rel_path = ? COLLATE NOCASE)`,
		projectID, d.RelPath, d.Kind, d.Title, projectID, d.RelPath)
	if err != nil {
		return false, fmt.Errorf("importing document %q: %w", d.RelPath, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("importing document %q: %w", d.RelPath, err)
	}
	return n > 0, nil
}
