package kb

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/workbenchdocs"
)

// WorkbenchDocSource is the source name of workbench documents: the text
// files of a workbench folder (a file set, fileset.go). Its documents are
// visible only to a search or open that names their workbench
// (Request.WorkbenchID, DocOptions.WorkbenchID; workbenchDocVisible in
// search.go) — PROJ-08: a workbench session sees its own documents, every
// other caller none. The value keeps its pre-rename spelling: it is
// persisted in kb_documents (spec 2026-10-02 A1).
const WorkbenchDocSource = "project_doc"

// workbenchDocPrefix starts every workbench document key:
// wbdoc:<workbench id>:<rel path>.
const workbenchDocPrefix = "wbdoc:"

// listTextFiles lists a folder's text documents (workbenchdocs.Lister.List).
type listTextFiles func(ctx context.Context, folder string) ([]workbenchdocs.File, error)

// workbenchDocSource indexes the text files of every workbench folder —
// every .md/.markdown/.txt file git does not ignore (or the walk keeps
// outside git), at most workbenchdocs.MaxTextFiles a workbench.
//
// Changed lists each folder and returns the files whose mtime differs from
// their indexed document's (fileset.go, needsRender); Keys is the same
// listing, so a file that left it (deleted, or now ignored) loses its entry
// at the reconcile that follows. A listing is made once per run.
//
// The daemon never touches a folder under a privacy-protected location
// (~/Documents, ~/Desktop, ~/Downloads, iCloud and cloud storage): a
// background read there could raise a macOS privacy prompt attributed to
// Watchtower. Those workbenches are indexed only on an explicit trigger —
// IndexWorkbenchDocs — and Keys keeps what the trigger indexed. A listing
// that fails (a git error) is logged and keeps the workbench's entries too;
// a folder that is gone (deleted or moved) keeps them without a log line, so
// it does not log on every knowledge cycle.
type workbenchDocSource struct {
	list   listTextFiles
	listed map[int64]listing
}

type listing struct {
	files []workbenchdocs.File
	err   error
}

func newWorkbenchDocSource() *workbenchDocSource {
	return &workbenchDocSource{list: workbenchdocs.ListTextFiles}
}

func (*workbenchDocSource) Name() string { return WorkbenchDocSource }

var workbenchDocKind = fileSetKinds[WorkbenchDocSource]

type workbenchFolder struct {
	id     int64
	folder string
}

func listWorkbenchFolders(ctx context.Context, q Queryer) ([]workbenchFolder, error) {
	rows, err := q.QueryContext(ctx, `SELECT id, folder_path FROM projects ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []workbenchFolder
	for rows.Next() {
		var w workbenchFolder
		if err := rows.Scan(&w.id, &w.folder); err != nil {
			return nil, err
		}
		out = append(out, w)
	}
	return out, rows.Err()
}

// files is w's listing for this run, or nil when the daemon must not read
// the folder (protected), the folder is gone, or the listing failed (logged).
func (s *workbenchDocSource) files(ctx context.Context, w workbenchFolder) ([]workbenchdocs.File, bool) {
	if privacyProtected(w.folder) {
		return nil, false
	}
	if _, err := os.Stat(w.folder); errors.Is(err, fs.ErrNotExist) {
		return nil, false
	}
	l, ok := s.listed[w.id]
	if !ok {
		l.files, l.err = s.list(ctx, w.folder)
		if l.err != nil {
			log.Printf("kb: listing workbench %d documents: %v (its index entries are kept)", w.id, l.err)
		}
		if s.listed == nil {
			s.listed = map[int64]listing{}
		}
		s.listed[w.id] = l
	}
	return l.files, l.err == nil
}

func (s *workbenchDocSource) Changed(ctx context.Context, q Queryer, cursor string, _ time.Time) ([]string, string, bool, error) {
	folders, err := listWorkbenchFolders(ctx, q)
	if err != nil {
		return nil, cursor, true, fmt.Errorf("kb workbench docs: %w", err)
	}
	indexed, err := docTimesWithPrefix(ctx, q, workbenchDocPrefix)
	if err != nil {
		return nil, cursor, true, fmt.Errorf("kb workbench docs: %w", err)
	}
	var keys []string
	for _, w := range folders {
		files, ok := s.files(ctx, w)
		if !ok {
			continue
		}
		for _, f := range files {
			key := workbenchDocKind.containerPrefix(w.id) + f.RelPath
			at, ok := indexed[key]
			if !ok {
				at = -1
			}
			if needsRender(w.folder, f.RelPath, at) {
				keys = append(keys, key)
			}
		}
	}
	return keys, cursor, true, nil
}

func (s *workbenchDocSource) Keys(ctx context.Context, q Queryer) ([]string, error) {
	folders, err := listWorkbenchFolders(ctx, q)
	if err != nil {
		return nil, err
	}
	var keys []string
	for _, w := range folders {
		files, ok := s.files(ctx, w)
		if !ok {
			// Not read in the background, or not listable now: what is
			// indexed stays.
			kept, err := docIDsWithPrefix(ctx, q, workbenchDocKind.containerPrefix(w.id))
			if err != nil {
				return nil, err
			}
			keys = append(keys, kept...)
			continue
		}
		for _, f := range files {
			keys = append(keys, workbenchDocKind.containerPrefix(w.id)+f.RelPath)
		}
	}
	return keys, nil
}

func (*workbenchDocSource) Build(ctx context.Context, q Queryer, key string) (*Doc, error) {
	id, rel, ok := workbenchDocKind.parseKey(key)
	if !ok {
		return nil, nil
	}
	var folder string
	err := q.QueryRowContext(ctx, `SELECT folder_path FROM projects WHERE id = ?`, id).Scan(&folder)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("kb %s: %w", key, err)
	}
	return renderFile(WorkbenchDocSource, workbenchDocKind, id, folder, rel), nil
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

// IndexWorkbenchDocs indexes the text files of one workbench folder now,
// protected location or not — an explicit trigger (`workbench resync`,
// `workbench create`, `kb reindex`) runs in a process the owner or the agent
// started — and drops the entries of files the folder no longer lists. A
// failed listing is an error and leaves every entry in place. An unreadable
// file is indexed by its path, never an error. documents is how many files
// the folder lists, changed how many index entries were written or removed.
func IndexWorkbenchDocs(ctx context.Context, d *db.DB, projectID int64) (documents, changed int, err error) {
	return indexWorkbenchDocs(ctx, d, projectID, workbenchdocs.ListTextFiles)
}

func indexWorkbenchDocs(ctx context.Context, d *db.DB, projectID int64, list listTextFiles) (documents, changed int, err error) {
	var folder string
	if err := d.QueryRowContext(ctx, `SELECT folder_path FROM projects WHERE id = ?`, projectID).Scan(&folder); err != nil {
		return 0, 0, fmt.Errorf("kb: workbench %d: %w", projectID, err)
	}
	files, err := list(ctx, folder)
	if err != nil {
		return 0, 0, fmt.Errorf("kb: listing workbench %d documents: %w", projectID, err)
	}
	set := FileSet{Source: WorkbenchDocSource, Container: projectID, Root: folder, Files: make([]string, 0, len(files))}
	for _, f := range files {
		set.Files = append(set.Files, f.RelPath)
	}
	documents, changed, err = indexFileSet(ctx, d, set, true)
	if err != nil {
		return 0, 0, fmt.Errorf("kb: indexing workbench %d documents: %w", projectID, err)
	}
	return documents, changed, nil
}
