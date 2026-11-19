package kb

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/fsutil"
	"watchtower/internal/workbenchdocs"
)

// WorkbenchDocSource is the source name of workbench documents: the text
// files of a workbench's folders (a file set, fileset.go). Its documents are
// visible only to a search or open that names their workbench
// (Request.WorkbenchID, DocOptions.WorkbenchID; workbenchDocVisible in
// search.go) — PROJ-08: a workbench session sees its own documents, every
// other caller none. The value keeps its pre-rename spelling: it is
// persisted in kb_documents (spec 2026-10-02 A1).
const WorkbenchDocSource = "project_doc"

// workbenchDocPrefix starts every workbench document key:
// wbdoc:<workbench id>:<folder id>:<rel path> (multi-folder workbench, spec
// 2026-11-18 §4 item 7; 00209 rekeyed the older wbdoc:<workbench id>:<rel>).
const workbenchDocPrefix = "wbdoc:"

// listTextFiles lists a folder's text documents (workbenchdocs.Lister.List).
type listTextFiles func(ctx context.Context, folder string) ([]workbenchdocs.File, error)

// workbenchDocSource indexes the text files of every folder of every
// workbench — every .md/.markdown/.txt file git does not ignore (or the walk
// keeps outside git), at most workbenchdocs.MaxTextFiles a folder.
//
// Changed lists each folder and returns the files whose mtime differs from
// their indexed document's (fileset.go, needsRender); Keys is the same
// listing, so a file that left it (deleted, or now ignored) — or a folder
// that left its workbench — loses its entries at the reconcile that follows.
// A listing is made once per run.
//
// The daemon never touches a folder under a privacy-protected location
// (~/Documents, ~/Desktop, ~/Downloads, iCloud and cloud storage): a
// background read there could raise a macOS privacy prompt attributed to
// Watchtower. Those folders are indexed only on an explicit trigger —
// IndexWorkbenchDocs — and Keys keeps what the trigger indexed. A listing
// that fails (a git error) is logged and keeps the folder's entries too;
// a folder that is gone (deleted or moved) keeps them without a log line, so
// it does not log on every knowledge cycle.
type workbenchDocSource struct {
	list   listTextFiles
	listed map[int64]listing // by folder id
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

// workbenchFolder is one indexed folder of a workbench.
type workbenchFolder struct {
	bench, id int64
	folder    string
}

// prefix is the key prefix of the folder's documents.
func (w workbenchFolder) prefix() string { return workbenchDocKind.folderPrefix(w.bench, w.id) }

// indexedFolderCond selects (over workbench_folders f) the folders whose
// documents are indexed: every live folder, and for a workbench with none
// (a legacy bench whose only row 00209 marked removed, db.HomeFolder) its
// lowest-position row.
const indexedFolderCond = `(f.removed_at IS NULL OR (
	NOT EXISTS (SELECT 1 FROM workbench_folders l WHERE l.workbench_id = f.workbench_id AND l.removed_at IS NULL)
	AND f.id = (SELECT f2.id FROM workbench_folders f2 WHERE f2.workbench_id = f.workbench_id ORDER BY f2.position, f2.id LIMIT 1)))`

// listWorkbenchFolders lists the indexed folders of every workbench, or of
// one when bench is not 0.
func listWorkbenchFolders(ctx context.Context, q Queryer, bench int64) ([]workbenchFolder, error) {
	rows, err := q.QueryContext(ctx, `SELECT f.workbench_id, f.id, f.folder_path FROM workbench_folders f
		WHERE (? = 0 OR f.workbench_id = ?) AND `+indexedFolderCond+`
		ORDER BY f.workbench_id, f.position, f.id`, bench, bench)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []workbenchFolder
	for rows.Next() {
		var w workbenchFolder
		if err := rows.Scan(&w.bench, &w.id, &w.folder); err != nil {
			return nil, err
		}
		out = append(out, w)
	}
	return out, rows.Err()
}

// files is w's listing for this run, or nil when the daemon must not read
// the folder (protected), the folder is gone, or the listing failed (logged).
func (s *workbenchDocSource) files(ctx context.Context, w workbenchFolder) ([]workbenchdocs.File, bool) {
	if fsutil.PrivacyProtected(w.folder) {
		return nil, false
	}
	if _, err := os.Stat(w.folder); errors.Is(err, fs.ErrNotExist) {
		return nil, false
	}
	l, ok := s.listed[w.id]
	if !ok {
		l.files, l.err = s.list(ctx, w.folder)
		if l.err != nil {
			log.Printf("kb: listing workbench %d documents in folder %d: %v (its index entries are kept)", w.bench, w.id, l.err)
		}
		if s.listed == nil {
			s.listed = map[int64]listing{}
		}
		s.listed[w.id] = l
	}
	return l.files, l.err == nil
}

func (s *workbenchDocSource) Changed(ctx context.Context, q Queryer, cursor string, _ time.Time) ([]string, string, bool, error) {
	folders, err := listWorkbenchFolders(ctx, q, 0)
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
			key := w.prefix() + f.RelPath
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
	folders, err := listWorkbenchFolders(ctx, q, 0)
	if err != nil {
		return nil, err
	}
	var keys []string
	for _, w := range folders {
		files, ok := s.files(ctx, w)
		if !ok {
			// Not read in the background, or not listable now: what is
			// indexed stays.
			kept, err := docIDsWithPrefix(ctx, q, w.prefix())
			if err != nil {
				return nil, err
			}
			keys = append(keys, kept...)
			continue
		}
		for _, f := range files {
			keys = append(keys, w.prefix()+f.RelPath)
		}
	}
	return keys, nil
}

func (*workbenchDocSource) Build(ctx context.Context, q Queryer, key string) (*Doc, error) {
	bench, folderID, rel, ok := workbenchDocKind.parseKey(key)
	if !ok {
		return nil, nil
	}
	var folder string
	err := q.QueryRowContext(ctx, `SELECT f.folder_path FROM workbench_folders f
		WHERE f.id = ? AND f.workbench_id = ? AND `+indexedFolderCond, folderID, bench).Scan(&folder)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil // the folder left its workbench, or the workbench is gone
	}
	if err != nil {
		return nil, fmt.Errorf("kb %s: %w", key, err)
	}
	return renderFile(WorkbenchDocSource, workbenchDocKind, bench, folderID, folder, rel), nil
}

// IndexWorkbenchDocs indexes the text files of every folder of one workbench
// now, protected location or not — an explicit trigger (`workbench resync`,
// `workbench create`, `workbench folder add`, `kb reindex`) runs in a process
// the owner or the agent started — and drops the entries of files no folder
// lists any more, and of folders that left the workbench. A folder whose
// listing fails keeps its entries and its failure is returned (the other
// folders are still indexed). An unreadable file is indexed by its path,
// never an error. documents is how many files the folders list, changed how
// many index entries were written or removed.
func IndexWorkbenchDocs(ctx context.Context, d *db.DB, workbenchID int64) (documents, changed int, err error) {
	return indexWorkbenchDocs(ctx, d, workbenchID, workbenchdocs.ListTextFiles)
}

func indexWorkbenchDocs(ctx context.Context, d *db.DB, workbenchID int64, list listTextFiles) (documents, changed int, err error) {
	var one int
	if err := d.QueryRowContext(ctx, `SELECT 1 FROM projects WHERE id = ?`, workbenchID).Scan(&one); err != nil {
		return 0, 0, fmt.Errorf("kb: workbench %d: %w", workbenchID, err)
	}
	folders, err := listWorkbenchFolders(ctx, d, workbenchID)
	if err != nil {
		return 0, 0, fmt.Errorf("kb: workbench %d folders: %w", workbenchID, err)
	}
	var sets []FileSet
	var keep []string
	var errs []error
	for _, w := range folders {
		files, err := list(ctx, w.folder) // each folder capped on its own (MaxTextFiles)
		if err != nil {
			keep = append(keep, w.prefix())
			errs = append(errs, fmt.Errorf("kb: listing workbench %d documents in %s: %w", workbenchID, w.folder, err))
			continue
		}
		set := FileSet{Source: WorkbenchDocSource, Container: workbenchID, Folder: w.id, Root: w.folder, Files: make([]string, 0, len(files))}
		for _, f := range files {
			set.Files = append(set.Files, f.RelPath)
		}
		sets = append(sets, set)
	}
	documents, changed, err = indexFileSets(ctx, d, WorkbenchDocSource, workbenchID, sets, true, keep)
	if err != nil {
		errs = append(errs, fmt.Errorf("kb: indexing workbench %d documents: %w", workbenchID, err))
	}
	return documents, changed, errors.Join(errs...)
}

// DropWorkbenchFolderDocs removes every index entry of one folder of a
// workbench (the folder left it, spec §6.3), returning how many went.
func DropWorkbenchFolderDocs(ctx context.Context, d *db.DB, workbenchID, folderID int64) (int, error) {
	ids, err := docIDsWithPrefix(ctx, d, workbenchDocKind.folderPrefix(workbenchID, folderID))
	if err != nil {
		return 0, fmt.Errorf("kb: listing the documents of folder %d: %w", folderID, err)
	}
	n := 0
	err = withTx(ctx, d, func(tx *sql.Tx) error {
		var perr error
		n, perr = pruneUnlistedDocs(ctx, tx, ids, nil, nil)
		return perr
	})
	if err != nil {
		return 0, fmt.Errorf("kb: dropping the documents of folder %d: %w", folderID, err)
	}
	return n, nil
}

// DropWorkbenchDocs removes every index entry of a workbench, every folder's
// (a merged bench's, spec §6.13: its folders' documents are indexed again
// under the bench they moved to), returning how many went.
func DropWorkbenchDocs(ctx context.Context, d *db.DB, workbenchID int64) (int, error) {
	ids, err := docIDsWithPrefix(ctx, d, workbenchDocKind.containerPrefix(workbenchID))
	if err != nil {
		return 0, fmt.Errorf("kb: listing the documents of workbench %d: %w", workbenchID, err)
	}
	n := 0
	err = withTx(ctx, d, func(tx *sql.Tx) error {
		var perr error
		n, perr = pruneUnlistedDocs(ctx, tx, ids, nil, nil)
		return perr
	})
	if err != nil {
		return 0, fmt.Errorf("kb: dropping the documents of workbench %d: %w", workbenchID, err)
	}
	return n, nil
}

// workbenchDocNames maps the live folders of workbench workbenchID to their
// stored names when it has more than one, else nil: a document's path is
// shown as <folder>/<rel> only then (spec §6.11).
func workbenchDocNames(ctx context.Context, q Queryer, workbenchID int64) (map[int64]string, error) {
	rows, err := q.QueryContext(ctx, `SELECT id, name FROM workbench_folders WHERE workbench_id = ? AND removed_at IS NULL`, workbenchID)
	if err != nil {
		return nil, fmt.Errorf("kb: folder names of workbench %d: %w", workbenchID, err)
	}
	defer rows.Close()
	names := map[int64]string{}
	for rows.Next() {
		var id int64
		var name string
		if err := rows.Scan(&id, &name); err != nil {
			return nil, fmt.Errorf("kb: folder names of workbench %d: %w", workbenchID, err)
		}
		names[id] = name
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("kb: folder names of workbench %d: %w", workbenchID, err)
	}
	if len(names) < 2 {
		return nil, nil
	}
	return names, nil
}

// workbenchDocTitle is a workbench document's shown path: <folder>/<rel>
// when names (workbenchDocNames) holds its folder, else title unchanged.
func workbenchDocTitle(names map[int64]string, ref, title string) string {
	_, folder, rel, ok := workbenchDocKind.parseKey(ref)
	if name, known := names[folder]; ok && known {
		return name + "/" + rel
	}
	return title
}
