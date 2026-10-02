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

// WorkbenchDocSource is the source name of attached workbench documents. Its
// documents are visible only to a search or open that names their workbench
// (Request.WorkbenchID, DocOptions.WorkbenchID; workbenchDocVisible in search.go) —
// PROJ-08: a workbench session sees its own documents, every other caller none.
// The value keeps its pre-rename spelling: it is persisted in kb_documents
// (spec 2026-10-02 A1).
const WorkbenchDocSource = "project_doc"

const (
	workbenchDocPrefix = WorkbenchDocSource + ":"
	// workbenchDocMaxBytes caps how much of one file is read; a longer file is
	// indexed up to it and its anchor says so (attached documents are
	// .md/.txt plans and specs).
	workbenchDocMaxBytes = 2 << 20
)

// workbenchDocSource renders one document per attached workbench document
// (project_documents), reading the file from the workbench folder.
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
// trigger — IndexWorkbenchDocs, run by `workbench resync` and the agent's
// attach_document.
type workbenchDocSource struct{}

func (workbenchDocSource) Name() string { return WorkbenchDocSource }

const workbenchDocSelect = `SELECT d.id, d.project_id, d.rel_path, d.kind, d.title, d.updated_at, p.folder_path, p.name
	FROM project_documents d JOIN projects p ON p.id = d.project_id`

type workbenchDocRow struct {
	id, workbenchID                 int64
	relPath, kind, title, updatedAt string
	folder, workbenchName           string
}

func scanWorkbenchDoc(s interface{ Scan(...any) error }) (workbenchDocRow, error) {
	var r workbenchDocRow
	err := s.Scan(&r.id, &r.workbenchID, &r.relPath, &r.kind, &r.title, &r.updatedAt, &r.folder, &r.workbenchName)
	return r, err
}

func workbenchDocKey(id int64) string { return workbenchDocPrefix + strconv.FormatInt(id, 10) }

func (workbenchDocSource) Changed(ctx context.Context, q Queryer, cursor string, _ time.Time) ([]string, string, bool, error) {
	rs, err := q.QueryContext(ctx, `SELECT d.id, p.folder_path, d.rel_path, COALESCE(k.doc_time_unix, -1)
		FROM project_documents d JOIN projects p ON p.id = d.project_id
		LEFT JOIN kb_documents k ON k.id = '`+workbenchDocPrefix+`' || d.id ORDER BY d.id`)
	if err != nil {
		return nil, cursor, true, fmt.Errorf("kb workbench docs: %w", err)
	}
	defer rs.Close()
	var keys []string
	for rs.Next() {
		var id int64
		var folder, rel string
		var indexed float64
		if err := rs.Scan(&id, &folder, &rel, &indexed); err != nil {
			return nil, cursor, true, fmt.Errorf("kb workbench docs: %w", err)
		}
		if privacyProtected(folder) {
			continue
		}
		fi, err := statInside(folder, rel)
		switch {
		case errors.Is(err, fs.ErrNotExist), errors.Is(err, errDocOutside):
			// Gone, or now leading out of the folder: re-rendered as its
			// title (the render refuses the link before touching it).
			keys = append(keys, workbenchDocKey(id))
		case err != nil:
			// Unreadable for now: keep the indexed text.
		case float64(fi.ModTime().Unix()) != indexed:
			keys = append(keys, workbenchDocKey(id))
		}
	}
	return keys, cursor, true, rs.Err()
}

// statInside stats folder/rel after resolveInside.
func statInside(folder, rel string) (fs.FileInfo, error) {
	realFolder, err := filepath.EvalSymlinks(folder)
	if err != nil {
		return nil, err
	}
	path, err := resolveInside(realFolder, rel)
	if err != nil {
		return nil, err
	}
	return os.Stat(path)
}

// resolveInside resolves rel inside realFolder, following symlinks one
// path component at a time and refusing — before touching it — any step
// that would leave the folder. Unlike filepath.EvalSymlinks it never
// stats a path outside the folder, so a link into a location macOS guards
// cannot make the indexer touch it.
func resolveInside(realFolder, rel string) (string, error) {
	parts := strings.Split(filepath.ToSlash(rel), "/")
	cur, hops := realFolder, 0
	for len(parts) > 0 {
		part := parts[0]
		parts = parts[1:]
		if part == "" || part == "." {
			continue
		}
		next := filepath.Join(cur, part)
		if !strictlyInside(realFolder, next) {
			return "", errDocOutside
		}
		fi, err := os.Lstat(next)
		if err != nil {
			return "", err
		}
		if fi.Mode()&fs.ModeSymlink == 0 {
			cur = next
			continue
		}
		if hops++; hops > 40 {
			return "", errors.New("too many symbolic links")
		}
		target, err := os.Readlink(next)
		if err != nil {
			return "", err
		}
		if !filepath.IsAbs(target) {
			target = filepath.Join(cur, target)
		}
		if target = filepath.Clean(target); !strictlyInside(realFolder, target) {
			return "", errDocOutside
		}
		// Resolve the target's own components from the folder again: one of
		// them may be a link too.
		relTarget, err := filepath.Rel(realFolder, target)
		if err != nil {
			return "", errDocOutside
		}
		parts = append(strings.Split(filepath.ToSlash(relTarget), "/"), parts...)
		cur = realFolder
	}
	if cur == realFolder {
		return "", errDocNotRegular
	}
	return cur, nil
}

func strictlyInside(root, path string) bool {
	return strings.HasPrefix(path, root+string(filepath.Separator))
}

func (workbenchDocSource) Keys(ctx context.Context, q Queryer) ([]string, error) {
	return queryStrings(ctx, q, `SELECT '`+workbenchDocPrefix+`' || id FROM project_documents`)
}

func (workbenchDocSource) Build(ctx context.Context, q Queryer, key string) (*Doc, error) {
	idStr, ok := splitRef(key, workbenchDocPrefix)
	if !ok {
		return nil, nil //nolint:nilerr // malformed ref: treat as missing doc, not an error
	}
	r, err := scanWorkbenchDoc(q.QueryRowContext(ctx, workbenchDocSelect+` WHERE d.id = ?`, idStr))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("kb %s: %w", key, err)
	}
	return renderWorkbenchDoc(key, r), nil
}

func renderWorkbenchDoc(key string, r workbenchDocRow) *Doc {
	title := r.title
	if strings.TrimSpace(title) == "" {
		title = r.relPath
	}
	path := filepath.Join(r.folder, r.relPath)
	doc := &Doc{
		ID:     key,
		Source: WorkbenchDocSource,
		Title:  title,
		Meta:   joinNonEmpty([]string{r.workbenchName, r.relPath, r.kind}),
		Link:   (&url.URL{Scheme: "file", Path: path}).String(),
		Time:   parseTime(r.updatedAt),
		Anchor: map[string]string{
			"project_id":  strconv.FormatInt(r.workbenchID, 10),
			"document_id": strconv.FormatInt(r.id, 10),
			"rel_path":    r.relPath,
		},
	}
	f, err := readWorkbenchDoc(r.folder, r.relPath)
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

type workbenchDocFile struct {
	text      string
	modTime   time.Time
	truncated bool
}

var (
	errDocMissing    = errors.New("file is missing")
	errDocNotRegular = errors.New("not a regular file")
	errDocOutside    = errors.New("no longer inside the workbench folder")
)

// readWorkbenchDoc reads a regular file that still resolves (symlinks
// followed, resolveInside) inside folder, capped at workbenchDocMaxBytes and
// cut to valid UTF-8. The type is checked before the open, and the open
// never blocks, so a named pipe put in a document's place cannot stall the
// indexer.
func readWorkbenchDoc(folder, rel string) (workbenchDocFile, error) {
	realFolder, err := filepath.EvalSymlinks(folder)
	if err != nil {
		return workbenchDocFile{}, fmt.Errorf("workbench folder: %w", err)
	}
	realPath, err := resolveInside(realFolder, rel)
	if errors.Is(err, fs.ErrNotExist) {
		return workbenchDocFile{}, errDocMissing
	}
	if err != nil {
		return workbenchDocFile{}, err
	}
	if fi, err := os.Stat(realPath); err != nil || !fi.Mode().IsRegular() {
		return workbenchDocFile{}, errDocNotRegular
	}
	f, err := os.OpenFile(realPath, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return workbenchDocFile{}, err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil || !fi.Mode().IsRegular() {
		return workbenchDocFile{}, errDocNotRegular
	}
	b, err := io.ReadAll(io.LimitReader(f, workbenchDocMaxBytes+1))
	if err != nil {
		return workbenchDocFile{}, err
	}
	out := workbenchDocFile{modTime: fi.ModTime().UTC(), truncated: len(b) > workbenchDocMaxBytes}
	if out.truncated {
		b = b[:workbenchDocMaxBytes]
	}
	for len(b) > 0 && !utf8.Valid(b) {
		b = b[:len(b)-1] // a cap can split a multi-byte rune
	}
	out.text = string(b)
	return out, nil
}

// privacyProtected reports whether folder sits where macOS asks the user
// before an app reads it — the home locations the Desktop's New-workbench flow
// warns about, and any other volume (removable and network volumes are
// guarded too, and a dead network mount can block a stat for minutes).
// Paths compare case-insensitively, as on the default APFS volume.
func privacyProtected(folder string) bool {
	if hasPathPrefix(folder, "/Volumes") {
		return true
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return true // cannot tell: never risk a background prompt
	}
	homes := []string{home}
	if resolved, err := filepath.EvalSymlinks(home); err == nil && resolved != home {
		homes = append(homes, resolved)
	}
	for _, h := range homes {
		for _, rel := range []string{"Documents", "Desktop", "Downloads", "Library/CloudStorage", "Library/Mobile Documents"} {
			if hasPathPrefix(folder, filepath.Join(h, rel)) {
				return true
			}
		}
	}
	return false
}

// hasPathPrefix reports whether path is root or below it, ignoring case.
func hasPathPrefix(path, root string) bool {
	return strings.EqualFold(path, root) ||
		(len(path) > len(root) && path[len(root)] == filepath.Separator && strings.EqualFold(path[:len(root)], root))
}

// IndexWorkbenchDocs re-renders every attached document of one workbench now,
// protected location or not — an explicit trigger (`workbench resync`, the
// agent's attach_document) runs in a process the owner or the agent started
// — and drops index entries of documents the workbench no longer has. An
// unreadable document is indexed by its title, never an error. documents is
// how many the workbench has, changed how many index entries were written or
// removed.
func IndexWorkbenchDocs(ctx context.Context, d *db.DB, projectID int64) (documents, changed int, err error) {
	rows, err := workbenchDocRows(ctx, d, projectID)
	if err != nil {
		return 0, 0, fmt.Errorf("kb: listing workbench %d documents: %w", projectID, err)
	}
	docs := make([]*Doc, 0, len(rows))
	live := map[string]bool{}
	for _, r := range rows {
		key := workbenchDocKey(r.id)
		live[key] = true
		docs = append(docs, renderWorkbenchDoc(key, r)) // rendered before the write tx opens
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
			AND json_extract(anchor_json, '$.project_id') = ?`, WorkbenchDocSource, strconv.FormatInt(projectID, 10))
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
		return 0, 0, fmt.Errorf("kb: indexing workbench %d documents: %w", projectID, err)
	}
	return len(docs), changed, nil
}

func workbenchDocRows(ctx context.Context, q Queryer, projectID int64) ([]workbenchDocRow, error) {
	rs, err := q.QueryContext(ctx, workbenchDocSelect+` WHERE d.project_id = ? ORDER BY d.id`, projectID)
	if err != nil {
		return nil, err
	}
	defer rs.Close()
	var out []workbenchDocRow
	for rs.Next() {
		r, err := scanWorkbenchDoc(rs)
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
