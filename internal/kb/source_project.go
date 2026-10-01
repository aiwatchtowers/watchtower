package kb

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"

	"watchtower/internal/db"
)

// ProjectDocSource is the source name of attached project documents. Its
// documents are visible only to a search or open that names their project
// (Request.ProjectID, DocOptions.ProjectID; projectDocVisible in search.go) —
// PROJ-08: a project session sees its own documents, every other caller none.
const ProjectDocSource = "project_doc"

const (
	projectDocPrefix = ProjectDocSource + ":"
	// projectDocMaxBytes caps how much of one file is read; a longer file is
	// indexed up to it and its anchor says so (attached documents are
	// .md/.txt plans and specs).
	projectDocMaxBytes = 2 << 20
)

// projectDocSource renders one document per attached project document
// (project_documents), reading the file from the project folder.
//
// There is no cursor: a file changes on disk without its row changing, and
// an edit can carry an older mtime (cp -p, a sync client). Changed instead
// lists every document whose file's mtime differs from the indexed
// document's time (the render stores the mtime, and the time is part of the
// content hash), plus every document whose file is gone (nothing to read,
// hash-gated). A file whose stat fails otherwise keeps its indexed text.
//
// The daemon never touches a folder under a privacy-protected location
// (~/Documents, ~/Desktop, ~/Downloads, iCloud and cloud storage): a
// background read there could raise a macOS privacy prompt attributed to
// Watchtower. Those projects' documents are indexed only on an explicit
// trigger — IndexProjectDocs, run by `project resync` and the agent's
// attach_document.
type projectDocSource struct{}

func (projectDocSource) Name() string { return ProjectDocSource }

const projectDocSelect = `SELECT d.id, d.project_id, d.rel_path, d.kind, d.title, d.updated_at, p.folder_path, p.name
	FROM project_documents d JOIN projects p ON p.id = d.project_id`

type projectDocRow struct {
	id, projectID                   int64
	relPath, kind, title, updatedAt string
	folder, projectName             string
}

func scanProjectDoc(s interface{ Scan(...any) error }) (projectDocRow, error) {
	var r projectDocRow
	err := s.Scan(&r.id, &r.projectID, &r.relPath, &r.kind, &r.title, &r.updatedAt, &r.folder, &r.projectName)
	return r, err
}

func projectDocKey(id int64) string { return projectDocPrefix + strconv.FormatInt(id, 10) }

func (projectDocSource) Changed(ctx context.Context, q Queryer, cursor string, _ time.Time) ([]string, string, bool, error) {
	rs, err := q.QueryContext(ctx, `SELECT d.id, p.folder_path, d.rel_path, COALESCE(k.doc_time_unix, -1)
		FROM project_documents d JOIN projects p ON p.id = d.project_id
		LEFT JOIN kb_documents k ON k.id = '`+projectDocPrefix+`' || d.id ORDER BY d.id`)
	if err != nil {
		return nil, cursor, true, fmt.Errorf("kb project docs: %w", err)
	}
	defer rs.Close()
	var keys []string
	for rs.Next() {
		var id int64
		var folder, rel string
		var indexed float64
		if err := rs.Scan(&id, &folder, &rel, &indexed); err != nil {
			return nil, cursor, true, fmt.Errorf("kb project docs: %w", err)
		}
		if privacyProtected(folder) {
			continue
		}
		fi, err := os.Stat(filepath.Join(folder, rel))
		switch {
		case errors.Is(err, fs.ErrNotExist):
			keys = append(keys, projectDocKey(id)) // gone: re-rendered as its title
		case err != nil:
			// Unreadable for now: keep the indexed text.
		case float64(fi.ModTime().Unix()) != indexed:
			keys = append(keys, projectDocKey(id))
		}
	}
	return keys, cursor, true, rs.Err()
}

func (projectDocSource) Keys(ctx context.Context, q Queryer) ([]string, error) {
	return queryStrings(ctx, q, `SELECT '`+projectDocPrefix+`' || id FROM project_documents`)
}

func (projectDocSource) Build(ctx context.Context, q Queryer, key string) (*Doc, error) {
	idStr, ok := splitRef(key, projectDocPrefix)
	if !ok {
		return nil, nil //nolint:nilerr // malformed ref: treat as missing doc, not an error
	}
	r, err := scanProjectDoc(q.QueryRowContext(ctx, projectDocSelect+` WHERE d.id = ?`, idStr))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("kb %s: %w", key, err)
	}
	return renderProjectDoc(key, r), nil
}

func renderProjectDoc(key string, r projectDocRow) *Doc {
	title := r.title
	if strings.TrimSpace(title) == "" {
		title = r.relPath
	}
	path := filepath.Join(r.folder, r.relPath)
	doc := &Doc{
		ID:     key,
		Source: ProjectDocSource,
		Title:  title,
		Meta:   joinNonEmpty([]string{r.projectName, r.relPath, r.kind}),
		Link:   (&url.URL{Scheme: "file", Path: path}).String(),
		Time:   parseTime(r.updatedAt),
		Anchor: map[string]string{
			"project_id":  strconv.FormatInt(r.projectID, 10),
			"document_id": strconv.FormatInt(r.id, 10),
			"rel_path":    r.relPath,
		},
	}
	f, err := readProjectDoc(r.folder, path)
	if err != nil {
		// Indexed by the title the row still carries; the anchor says why
		// the text is missing, so an open does not read as an empty file.
		doc.Anchor["unreadable"] = err.Error()
		return doc
	}
	doc.Time = f.modTime
	doc.Sections = markdownSections(f.text)
	if f.truncated {
		doc.Anchor["truncated"] = "indexed up to 2 MiB"
	}
	return doc
}

type projectDocFile struct {
	text      string
	modTime   time.Time
	truncated bool
}

var (
	errDocMissing    = errors.New("file is missing")
	errDocNotRegular = errors.New("not a regular file")
	errDocOutside    = errors.New("no longer inside the project folder")
)

// readProjectDoc reads a regular file that still resolves (symlinks
// followed) inside folder, capped at projectDocMaxBytes and cut to valid
// UTF-8. The type is checked before the open, and the open never blocks, so
// a named pipe put in a document's place cannot stall the indexer.
func readProjectDoc(folder, path string) (projectDocFile, error) {
	realFolder, err := filepath.EvalSymlinks(folder)
	if err != nil {
		return projectDocFile{}, fmt.Errorf("project folder: %w", err)
	}
	realPath, err := filepath.EvalSymlinks(path)
	if errors.Is(err, fs.ErrNotExist) {
		return projectDocFile{}, errDocMissing
	}
	if err != nil {
		return projectDocFile{}, err
	}
	if !strings.HasPrefix(realPath, realFolder+string(filepath.Separator)) {
		return projectDocFile{}, errDocOutside
	}
	if fi, err := os.Stat(realPath); err != nil || !fi.Mode().IsRegular() {
		return projectDocFile{}, errDocNotRegular
	}
	f, err := os.OpenFile(realPath, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return projectDocFile{}, err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil || !fi.Mode().IsRegular() {
		return projectDocFile{}, errDocNotRegular
	}
	b, err := io.ReadAll(io.LimitReader(f, projectDocMaxBytes+1))
	if err != nil {
		return projectDocFile{}, err
	}
	out := projectDocFile{modTime: fi.ModTime().UTC(), truncated: len(b) > projectDocMaxBytes}
	if out.truncated {
		b = b[:projectDocMaxBytes]
	}
	for len(b) > 0 && !utf8.Valid(b) {
		b = b[:len(b)-1] // a cap can split a multi-byte rune
	}
	out.text = string(b)
	return out, nil
}

// privacyProtected reports whether folder sits where macOS asks the user
// before an app reads it (the locations the Desktop's New-project flow
// warns about).
func privacyProtected(folder string) bool {
	home, err := os.UserHomeDir()
	if err != nil {
		return true // cannot tell: never risk a background prompt
	}
	for _, rel := range []string{"Documents", "Desktop", "Downloads", "Library/CloudStorage", "Library/Mobile Documents"} {
		root := filepath.Join(home, rel)
		if folder == root || strings.HasPrefix(folder, root+string(filepath.Separator)) {
			return true
		}
	}
	return false
}

// IndexProjectDocs re-renders every attached document of one project now,
// protected location or not — an explicit trigger (`project resync`, the
// agent's attach_document) runs in a process the owner or the agent started
// — and drops index entries of documents the project no longer has. An
// unreadable document is indexed by its title, never an error. documents is
// how many the project has, changed how many index entries were written or
// removed.
func IndexProjectDocs(ctx context.Context, d *db.DB, projectID int64) (documents, changed int, err error) {
	rows, err := projectDocRows(ctx, d, projectID)
	if err != nil {
		return 0, 0, fmt.Errorf("kb: listing project %d documents: %w", projectID, err)
	}
	docs := make([]*Doc, 0, len(rows))
	live := map[string]bool{}
	for _, r := range rows {
		key := projectDocKey(r.id)
		live[key] = true
		docs = append(docs, renderProjectDoc(key, r)) // rendered before the write tx opens
	}
	err = withTx(ctx, d, func(tx *sql.Tx) error {
		for _, doc := range docs {
			wrote, err := writeDoc(ctx, tx, doc)
			if err != nil {
				return err
			}
			if wrote {
				changed++
			}
		}
		indexed, err := queryStrings(ctx, tx, `SELECT id FROM kb_documents WHERE source = ?
			AND json_extract(anchor_json, '$.project_id') = ?`, ProjectDocSource, strconv.FormatInt(projectID, 10))
		if err != nil {
			return err
		}
		for _, id := range indexed {
			if live[id] {
				continue
			}
			if _, err := deleteDoc(ctx, tx, id); err != nil {
				return err
			}
			changed++
		}
		return nil
	})
	if err != nil {
		return 0, 0, fmt.Errorf("kb: indexing project %d documents: %w", projectID, err)
	}
	return len(docs), changed, nil
}

func projectDocRows(ctx context.Context, q Queryer, projectID int64) ([]projectDocRow, error) {
	rs, err := q.QueryContext(ctx, projectDocSelect+` WHERE d.project_id = ? ORDER BY d.id`, projectID)
	if err != nil {
		return nil, err
	}
	defer rs.Close()
	var out []projectDocRow
	for rs.Next() {
		r, err := scanProjectDoc(rs)
		if err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rs.Err()
}

// markdownSections splits text at its #, ## and ### headings (outside fenced
// code); each section's anchor is its heading text, so a hit's chunk_anchor
// names the part of the document it matched. Text before the first heading
// is a section without an anchor.
func markdownSections(text string) []Section {
	var out []Section
	var cur strings.Builder
	anchor, fenced := "", false
	flush := func() {
		if strings.TrimSpace(cur.String()) != "" {
			out = append(out, Section{Text: cur.String(), Anchor: anchor})
		}
		cur.Reset()
	}
	for _, line := range strings.Split(text, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "```") || strings.HasPrefix(trimmed, "~~~") {
			fenced = !fenced
		}
		if h, isHeading := markdownHeading(trimmed); isHeading && !fenced {
			flush()
			anchor = h
		}
		cur.WriteString(line)
		cur.WriteString("\n")
	}
	flush()
	return out
}

// markdownHeading returns the text of a level 1–3 ATX heading line.
func markdownHeading(line string) (string, bool) {
	level := len(line) - len(strings.TrimLeft(line, "#"))
	if level < 1 || level > 3 || len(line) == level || line[level] != ' ' {
		return "", false
	}
	return strings.TrimSpace(line[level:]), true
}
