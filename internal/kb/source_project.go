package kb

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// ProjectDocSource is the source name of attached project documents. Its
// documents are visible only to a search or open that names their project
// (Request.ProjectID, DocOptions.ProjectID) — PROJ-08: a project session sees
// its own documents, every other caller none.
const ProjectDocSource = "project_doc"

const (
	projectDocPrefix = ProjectDocSource + ":"
	// projectDocMaxBytes caps how much of one file is read; a longer file is
	// indexed up to it (attached documents are .md/.txt plans and specs).
	projectDocMaxBytes = 2 << 20
)

// projectDocSource renders one document per attached project document
// (project_documents), reading the file from the project folder. A file can
// change on disk without its row changing, so the change marker is the later
// of the row's updated_at and the file's mtime; a file that cannot be
// stat'ed is listed every run (its render is hash-gated, so that is free).
type projectDocSource struct{}

func (projectDocSource) Name() string { return ProjectDocSource }

type projectDocRow struct {
	id, projectID                   int64
	relPath, kind, title, updatedAt string
	folder, projectName             string
}

func (projectDocSource) rows(ctx context.Context, q Queryer, where string, args ...any) ([]projectDocRow, error) {
	rs, err := q.QueryContext(ctx, `SELECT d.id, d.project_id, d.rel_path, d.kind, d.title, d.updated_at, p.folder_path, p.name
		FROM project_documents d JOIN projects p ON p.id = d.project_id`+where+` ORDER BY d.id`, args...)
	if err != nil {
		return nil, err
	}
	defer rs.Close()
	var out []projectDocRow
	for rs.Next() {
		var r projectDocRow
		if err := rs.Scan(&r.id, &r.projectID, &r.relPath, &r.kind, &r.title, &r.updatedAt, &r.folder, &r.projectName); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rs.Err()
}

func projectDocKey(id int64) string { return projectDocPrefix + strconv.FormatInt(id, 10) }

func (s projectDocSource) Changed(ctx context.Context, q Queryer, cursor string, now time.Time) ([]string, string, bool, error) {
	rows, err := s.rows(ctx, q, "")
	if err != nil {
		return nil, cursor, true, fmt.Errorf("kb project docs: %w", err)
	}
	var keys []string
	next := cursor
	// A file dated in the future would otherwise push the cursor past every
	// later edit; capped at now, it is merely re-listed until then.
	nowMarker := now.UTC().Format("2006-01-02T15:04:05Z")
	for _, r := range rows {
		marker := r.updatedAt
		if fi, err := os.Stat(filepath.Join(r.folder, r.relPath)); err == nil {
			marker = maxString(marker, fi.ModTime().UTC().Format("2006-01-02T15:04:05Z"))
		} else {
			keys = append(keys, projectDocKey(r.id)) // gone or unreadable: re-render, hash-gated
			continue
		}
		if marker >= cursor {
			keys = append(keys, projectDocKey(r.id))
		}
		next = maxString(next, min(marker, nowMarker))
	}
	return keys, next, true, nil
}

func (projectDocSource) Keys(ctx context.Context, q Queryer) ([]string, error) {
	return queryStrings(ctx, q, `SELECT '`+projectDocPrefix+`' || id FROM project_documents`)
}

func (s projectDocSource) Build(ctx context.Context, q Queryer, key string) (*Doc, error) {
	idStr, ok := splitRef(key, projectDocPrefix)
	if !ok {
		return nil, nil //nolint:nilerr // malformed ref: treat as missing doc, not an error
	}
	rows, err := s.rows(ctx, q, " WHERE d.id = ?", idStr)
	if err != nil {
		return nil, fmt.Errorf("kb %s: %w", key, err)
	}
	if len(rows) == 0 {
		return nil, nil
	}
	r := rows[0]
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
			"document_id": idStr,
			"rel_path":    r.relPath,
		},
	}
	text, modTime, ok := readProjectDoc(r.folder, path)
	if !ok {
		// Gone, unreadable or no longer inside the folder: indexed by its
		// title, which the row still carries.
		return doc, nil
	}
	doc.Time = modTime
	doc.Sections = markdownSections(text)
	return doc, nil
}

// readProjectDoc reads a regular file that still resolves (symlinks
// followed) inside folder, capped at projectDocMaxBytes and cut to valid
// UTF-8. ok is false for anything else.
func readProjectDoc(folder, path string) (text string, modTime time.Time, ok bool) {
	realFolder, err := filepath.EvalSymlinks(folder)
	if err != nil {
		return "", time.Time{}, false
	}
	realPath, err := filepath.EvalSymlinks(path)
	if err != nil || !strings.HasPrefix(realPath, realFolder+string(filepath.Separator)) {
		return "", time.Time{}, false
	}
	f, err := os.Open(realPath)
	if err != nil {
		return "", time.Time{}, false
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil || !fi.Mode().IsRegular() {
		return "", time.Time{}, false
	}
	b, err := io.ReadAll(io.LimitReader(f, projectDocMaxBytes))
	if err != nil && !errors.Is(err, io.EOF) {
		return "", time.Time{}, false
	}
	for len(b) > 0 && !utf8.Valid(b) {
		b = b[:len(b)-1] // a cap can split a multi-byte rune
	}
	return string(b), fi.ModTime().UTC(), true
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

// projectDocVisible is the SQL condition (over kb_documents aliased d) that
// hides every project document but projectID's; projectID 0 hides them all.
const projectDocVisible = `(d.source <> '` + ProjectDocSource + `' OR json_extract(d.anchor_json, '$.project_id') = ?)`
