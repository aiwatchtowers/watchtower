package db

import (
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"unicode"
	"unicode/utf8"
)

// Project is a folder-bound project (Projects POC, migration 00081). Its
// targets, documents and comments live only on its board (PROJ-01,
// docs/inventory/projects.md).
type Project struct {
	ID          int64
	Name        string
	FolderPath  string // absolute, symlinks resolved (ResolveProjectFolder)
	Description string
	CreatedAt   string
	UpdatedAt   string
	// BoardLanguage is the language the board is written in (00087); empty
	// means follow the session language. Always NormalizeBoardLanguage'd.
	BoardLanguage string
}

// ProjectSource is a source the project's docs name (a channel, a Jira
// project, a Confluence space, a person, a link).
type ProjectSource struct {
	ID        int64
	ProjectID int64
	Kind      string
	Ref       string
	Label     string
}

// ProjectDocument is a file inside the project folder (a spec, a plan, a doc)
// that Claude Code attached for owner review.
type ProjectDocument struct {
	ID        int64
	ProjectID int64
	TargetID  sql.NullInt64
	RelPath   string // relative to the project folder
	Kind      string // spec | plan | doc
	Title     string
	CreatedAt string
	UpdatedAt string // bumped by every re-attach ("revised")
	Origin    string // agent | import | owner (migration 00083)
}

var (
	ErrProjectFolderTaken = errors.New("folder is already bound to a project")
	ErrProjectNotFound    = errors.New("project not found")
	// ErrNotInProject is returned when a target, document, source or comment
	// named by a project write belongs to another project, or to none.
	ErrNotInProject = errors.New("does not belong to this project")
)

var (
	projectSourceKinds   = map[string]bool{"slack_channel": true, "jira_project": true, "confluence_space": true, "person": true, "link": true}
	projectDocumentKinds = map[string]bool{"spec": true, "plan": true, "doc": true}
)

const projectCols = `id, name, folder_path, description, created_at, updated_at, board_language`

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

// ResolveProjectFolder turns dir into the absolute, symlink-resolved path of
// an existing directory — the only form CreateProject stores, so two spellings
// of one folder can never bind two projects. A folder a project must not own
// — root, home or an ancestor, or overlapping one of the protected dirs the
// caller passes (Watchtower's own data) — fails with ErrProjectFolderNotAllowed.
func ResolveProjectFolder(dir string, protected []string) (string, error) {
	if strings.TrimSpace(dir) == "" {
		return "", errors.New("project folder is required")
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
	if err := checkProjectFolderAllowed(resolved, protected); err != nil {
		return "", err
	}
	return resolved, nil
}

// CreateProject binds a new project to folder, which must already be resolved
// (ResolveProjectFolder). A folder bound to another project fails with
// ErrProjectFolderTaken.
func (db *DB) CreateProject(name, folder string) (int64, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return 0, errors.New("project name is required")
	}
	if !filepath.IsAbs(folder) {
		return 0, fmt.Errorf("project folder %q must be an absolute, resolved path", folder)
	}
	if err := checkFolderLineBreaks(folder); err != nil {
		return 0, err
	}
	// APFS is case-insensitive, so another spelling of a bound folder is the
	// same folder; the UNIQUE index below compares bytes.
	var taken int64
	err := db.QueryRow(`SELECT id FROM projects WHERE folder_path = ? COLLATE NOCASE LIMIT 1`, folder).Scan(&taken)
	if err == nil {
		return 0, fmt.Errorf("%s: %w", folder, ErrProjectFolderTaken)
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return 0, fmt.Errorf("checking folder %s: %w", folder, err)
	}
	res, err := db.Exec(`INSERT INTO projects (name, folder_path) VALUES (?, ?)`, name, folder)
	if err != nil {
		if strings.Contains(err.Error(), "UNIQUE constraint failed: projects.folder_path") {
			return 0, fmt.Errorf("%s: %w", folder, ErrProjectFolderTaken)
		}
		return 0, fmt.Errorf("inserting project: %w", err)
	}
	return res.LastInsertId()
}

func scanProject(row interface{ Scan(...any) error }) (*Project, error) {
	var p Project
	if err := row.Scan(&p.ID, &p.Name, &p.FolderPath, &p.Description, &p.CreatedAt, &p.UpdatedAt, &p.BoardLanguage); err != nil {
		return nil, err
	}
	return &p, nil
}

// GetProject returns project id, or ErrProjectNotFound.
func (db *DB) GetProject(id int64) (*Project, error) {
	p, err := scanProject(db.QueryRow(`SELECT `+projectCols+` FROM projects WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("project %d: %w", id, ErrProjectNotFound)
	}
	if err != nil {
		return nil, fmt.Errorf("getting project %d: %w", id, err)
	}
	return p, nil
}

// ListProjects returns every project in id order.
func (db *DB) ListProjects() ([]Project, error) {
	rows, err := db.Query(`SELECT ` + projectCols + ` FROM projects ORDER BY id`)
	if err != nil {
		return nil, fmt.Errorf("listing projects: %w", err)
	}
	defer rows.Close()
	var out []Project
	for rows.Next() {
		p, err := scanProject(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning project: %w", err)
		}
		out = append(out, *p)
	}
	return out, rows.Err()
}

// Board language caps: a name ("Brazilian Portuguese") or a tag ("pt-BR"),
// never a sentence.
const (
	maxBoardLanguageRunes = 40
	maxBoardLanguageWords = 3
)

// ErrInvalidBoardLanguage is returned for a board language that is not a
// short language name or tag.
var ErrInvalidBoardLanguage = errors.New("board language must be a language name or tag such as Russian or pt-BR (letters, spaces and hyphens with at least one letter, at most 3 words and 40 characters)")

// NormalizeBoardLanguage trims s and collapses its inner runs of spaces. Empty
// (follow the session) is valid; anything else must be letters (any script),
// spaces and hyphens with at least one letter — no newline or tab — at most maxBoardLanguageWords words
// and maxBoardLanguageRunes runes: the value is echoed into every session's
// brief, so it must stay a short name with no punctuation or line break.
func NormalizeBoardLanguage(s string) (string, error) {
	s = strings.TrimSpace(s)
	for _, r := range s {
		if !unicode.IsLetter(r) && !unicode.IsMark(r) && r != ' ' && r != '-' {
			return "", fmt.Errorf("%q: %w", s, ErrInvalidBoardLanguage)
		}
	}
	words := strings.Fields(s)
	norm := strings.Join(words, " ")
	if len(words) > maxBoardLanguageWords || utf8.RuneCountInString(norm) > maxBoardLanguageRunes ||
		(norm != "" && !strings.ContainsFunc(norm, unicode.IsLetter)) {
		return "", fmt.Errorf("%q: %w", s, ErrInvalidBoardLanguage)
	}
	return norm, nil
}

// ProjectUpdate is a partial project change: a nil field is left as it is.
type ProjectUpdate struct {
	Description   *string // trimmed
	BoardLanguage *string // NormalizeBoardLanguage'd; empty follows the session
}

// UpdateProject applies u in one statement, so a change of both fields is
// all or nothing. A board language NormalizeBoardLanguage refuses writes
// nothing.
func (db *DB) UpdateProject(id int64, u ProjectUpdate) error {
	var desc, lang any // nil = keep (COALESCE)
	if u.Description != nil {
		desc = strings.TrimSpace(*u.Description)
	}
	if u.BoardLanguage != nil {
		l, err := NormalizeBoardLanguage(*u.BoardLanguage)
		if err != nil {
			return err
		}
		lang = l
	}
	res, err := db.Exec(`UPDATE projects SET description = COALESCE(?, description),
		board_language = COALESCE(?, board_language),
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?`, desc, lang, id)
	if err != nil {
		return fmt.Errorf("updating project %d: %w", id, err)
	}
	return requireAffected(res, fmt.Errorf("project %d: %w", id, ErrProjectNotFound))
}

// DeleteProject removes the project; the foreign keys cascade to its targets,
// sources, documents and comments inside the same statement, so the delete is
// all-or-nothing (PROJ-02). The folder install is removed by the caller.
func (db *DB) DeleteProject(id int64) error {
	res, err := db.Exec(`DELETE FROM projects WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("deleting project %d: %w", id, err)
	}
	return requireAffected(res, fmt.Errorf("project %d: %w", id, ErrProjectNotFound))
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

// requireProject fails with ErrProjectNotFound unless project id exists.
func requireProject(q targetsQuerier, id int64) error {
	var one int
	err := q.QueryRow(`SELECT 1 FROM projects WHERE id = ?`, id).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("project %d: %w", id, ErrProjectNotFound)
	}
	if err != nil {
		return fmt.Errorf("checking project %d: %w", id, err)
	}
	return nil
}

const (
	targetProjectQuery   = `SELECT project_id FROM targets WHERE id = ?`
	documentProjectQuery = `SELECT project_id FROM project_documents WHERE id = ?`
)

// checkTargetInProject fails with ErrNotInProject unless target id is on
// project projectID's board.
func checkTargetInProject(q targetsQuerier, projectID, id int64) error {
	return checkOwnedBy(q, targetProjectQuery, "target", projectID, id)
}

func checkDocumentInProject(q targetsQuerier, projectID, id int64) error {
	return checkOwnedBy(q, documentProjectQuery, "document", projectID, id)
}

func checkOwnedBy(q targetsQuerier, query, noun string, projectID, id int64) error {
	var owner sql.NullInt64
	err := q.QueryRow(query, id).Scan(&owner)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return fmt.Errorf("%s %d does not exist: %w", noun, id, ErrNotInProject)
	case err != nil:
		return fmt.Errorf("checking %s %d: %w", noun, id, err)
	case !owner.Valid || owner.Int64 != projectID:
		return fmt.Errorf("%s %d: %w", noun, id, ErrNotInProject)
	}
	return nil
}

// AddProjectSource adds a source; adding an existing (kind, ref) again returns
// the existing row's id.
func (db *DB) AddProjectSource(s ProjectSource) (int64, error) {
	if !projectSourceKinds[s.Kind] {
		return 0, fmt.Errorf("invalid project source kind %q", s.Kind)
	}
	if strings.TrimSpace(s.Ref) == "" {
		return 0, errors.New("project source ref is required")
	}
	if _, err := db.Exec(`INSERT INTO project_sources (project_id, kind, ref, label) VALUES (?, ?, ?, ?)
		ON CONFLICT(project_id, kind, ref) DO NOTHING`, s.ProjectID, s.Kind, s.Ref, s.Label); err != nil {
		return 0, fmt.Errorf("adding project source: %w", err)
	}
	var id int64
	if err := db.QueryRow(`SELECT id FROM project_sources WHERE project_id = ? AND kind = ? AND ref = ?`,
		s.ProjectID, s.Kind, s.Ref).Scan(&id); err != nil {
		return 0, fmt.Errorf("reading project source id: %w", err)
	}
	return id, nil
}

// RemoveProjectSource deletes one source of the project.
func (db *DB) RemoveProjectSource(projectID, sourceID int64) error {
	res, err := db.Exec(`DELETE FROM project_sources WHERE id = ? AND project_id = ?`, sourceID, projectID)
	if err != nil {
		return fmt.Errorf("removing project source %d: %w", sourceID, err)
	}
	return requireAffected(res, fmt.Errorf("project source %d: %w", sourceID, ErrNotInProject))
}

// ListProjectSources returns the project's sources by kind, then id.
func (db *DB) ListProjectSources(projectID int64) ([]ProjectSource, error) {
	rows, err := db.Query(`SELECT id, project_id, kind, ref, label FROM project_sources
		WHERE project_id = ? ORDER BY kind, id`, projectID)
	if err != nil {
		return nil, fmt.Errorf("listing project sources: %w", err)
	}
	defer rows.Close()
	var out []ProjectSource
	for rows.Next() {
		var s ProjectSource
		if err := rows.Scan(&s.ID, &s.ProjectID, &s.Kind, &s.Ref, &s.Label); err != nil {
			return nil, fmt.Errorf("scanning project source: %w", err)
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

const projectDocumentCols = `id, project_id, target_id, rel_path, kind, title, created_at, updated_at, origin`

func scanProjectDocument(row interface{ Scan(...any) error }) (*ProjectDocument, error) {
	var d ProjectDocument
	if err := row.Scan(&d.ID, &d.ProjectID, &d.TargetID, &d.RelPath, &d.Kind, &d.Title, &d.CreatedAt, &d.UpdatedAt, &d.Origin); err != nil {
		return nil, err
	}
	return &d, nil
}

func validateProjectDocument(d ProjectDocument) error {
	if strings.TrimSpace(d.RelPath) == "" || filepath.IsAbs(d.RelPath) {
		return fmt.Errorf("document path %q must be relative to the project folder", d.RelPath)
	}
	if d.Kind != "" && !projectDocumentKinds[d.Kind] {
		return fmt.Errorf("invalid document kind %q", d.Kind)
	}
	return nil
}

// UpsertProjectDocument attaches d as the agent's. On an existing (project,
// rel_path) it bumps updated_at ("revised"), marks it origin 'agent' (an
// imported document the agent revises is the agent's from then on) and
// replaces kind/title/target only with the values d sets; created reports
// whether a new row was inserted. Whether rel_path stays inside the folder is
// the caller's check.
func (db *DB) UpsertProjectDocument(d ProjectDocument) (id int64, created bool, err error) {
	if err := validateProjectDocument(d); err != nil {
		return 0, false, err
	}
	err = db.WithTx(func(tx *sql.Tx) error {
		if d.TargetID.Valid {
			if err := checkTargetInProject(tx, d.ProjectID, d.TargetID.Int64); err != nil {
				return err
			}
		}
		qerr := tx.QueryRow(`SELECT id FROM project_documents WHERE project_id = ? AND rel_path = ?`,
			d.ProjectID, d.RelPath).Scan(&id)
		if errors.Is(qerr, sql.ErrNoRows) {
			created = true
			id, qerr = insertProjectDocument(tx, d, "agent")
			return qerr
		}
		if qerr != nil {
			return fmt.Errorf("looking up document %q: %w", d.RelPath, qerr)
		}
		return reviseProjectDocument(tx, id, d)
	})
	if err != nil {
		return 0, false, err
	}
	return id, created, nil
}

func insertProjectDocument(tx *sql.Tx, d ProjectDocument, origin string) (int64, error) {
	kind := d.Kind
	if kind == "" {
		kind = "doc"
	}
	res, err := tx.Exec(`INSERT INTO project_documents (project_id, target_id, rel_path, kind, title, origin)
		VALUES (?, ?, ?, ?, ?, ?)`, d.ProjectID, d.TargetID, d.RelPath, kind, d.Title, origin)
	if err != nil {
		return 0, fmt.Errorf("inserting document %q: %w", d.RelPath, err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, fmt.Errorf("inserting document %q: %w", d.RelPath, err)
	}
	return id, nil
}

func reviseProjectDocument(tx *sql.Tx, id int64, d ProjectDocument) error {
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

// AttachOwnerProjectDocument attaches d as the owner's (origin 'owner', the
// Desktop's "Add document…"). A rel_path the project already has — compared
// ignoring case, the import rule — is left untouched: created=false, and the
// returned relPath is the stored spelling. The owner attaching a file is never
// a revision. Whether rel_path stays inside the folder is the caller's check.
func (db *DB) AttachOwnerProjectDocument(d ProjectDocument) (id int64, relPath string, created bool, err error) {
	if err := validateProjectDocument(d); err != nil {
		return 0, "", false, err
	}
	err = db.WithTx(func(tx *sql.Tx) error {
		if err := requireProject(tx, d.ProjectID); err != nil {
			return err
		}
		if d.TargetID.Valid {
			if err := checkTargetInProject(tx, d.ProjectID, d.TargetID.Int64); err != nil {
				return err
			}
		}
		qerr := tx.QueryRow(`SELECT id, rel_path FROM project_documents WHERE project_id = ? AND rel_path = ? COLLATE NOCASE`,
			d.ProjectID, d.RelPath).Scan(&id, &relPath)
		switch {
		case qerr == nil:
			return nil
		case !errors.Is(qerr, sql.ErrNoRows):
			return fmt.Errorf("looking up document %q: %w", d.RelPath, qerr)
		}
		created, relPath = true, d.RelPath
		id, qerr = insertProjectDocument(tx, d, "owner")
		return qerr
	})
	if err != nil {
		return 0, "", false, err
	}
	return id, relPath, created, nil
}

// GetProjectDocument returns document id, or (nil, nil) when absent.
func (db *DB) GetProjectDocument(id int64) (*ProjectDocument, error) {
	d, err := scanProjectDocument(db.QueryRow(`SELECT `+projectDocumentCols+` FROM project_documents WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("getting document %d: %w", id, err)
	}
	return d, nil
}

// ListProjectDocuments returns the project's documents in id order.
func (db *DB) ListProjectDocuments(projectID int64) ([]ProjectDocument, error) {
	rows, err := db.Query(`SELECT `+projectDocumentCols+` FROM project_documents WHERE project_id = ? ORDER BY id`, projectID)
	if err != nil {
		return nil, fmt.Errorf("listing documents: %w", err)
	}
	defer rows.Close()
	var out []ProjectDocument
	for rows.Next() {
		d, err := scanProjectDocument(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning document: %w", err)
		}
		out = append(out, *d)
	}
	return out, rows.Err()
}

// ImportProjectDocuments attaches docs as origin 'import' in one transaction,
// skipping every rel_path the project already has — an attached document,
// whatever its origin, is never touched. It returns the rel_paths inserted.
func (db *DB) ImportProjectDocuments(projectID int64, docs []ProjectDocument) ([]string, error) {
	var inserted []string
	err := db.WithTx(func(tx *sql.Tx) error {
		if err := requireProject(tx, projectID); err != nil {
			return err
		}
		for _, d := range docs {
			ok, err := importProjectDocument(tx, projectID, d)
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

// importProjectDocument inserts d unless the project already has its
// rel_path — compared ignoring case, since APFS is case-insensitive and the
// agent may have attached another spelling of the same file.
func importProjectDocument(tx *sql.Tx, projectID int64, d ProjectDocument) (bool, error) {
	if err := validateProjectDocument(d); err != nil {
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
