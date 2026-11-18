// Package workbenchfolders puts folders on a workbench and takes them off
// (multi-folder workbench, spec 2026-11-18 §6.1, §6.3): the only writer of
// workbench_folders besides db.CreateWorkbench, run through the CLI
// (`workbench folder add|remove|locate`). Each write is one short
// BEGIN IMMEDIATE transaction; the install, docs indexing and git watching
// run after it commits, in the caller. A folder belongs to at most one
// workbench (PROJ-24): the live-path unique index and the in-transaction
// checks here keep it so.
package workbenchfolders

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"watchtower/internal/db"
)

// Refusal codes (spec D42: an agent or the Desktop reads "<code>: <sentence>").
const (
	CodeNotFound        = "not_found"
	CodeAlreadyHere     = "already_here"
	CodeOtherBench      = "other_bench"
	CodeNested          = "nested"
	CodeSessionsRunning = "sessions_running"
	CodeLastFolder      = "last_folder"
	CodeFolderRemoved   = "folder_removed"
	CodeFolderPresent   = "folder_present"
)

// Refusal is a folder write or lookup the rules refuse. Folder is the folder
// it is about (already_here, nested, folder_removed, folder_present,
// sessions_running, last_folder); OtherBench the workbench a folder already
// belongs to (other_bench). For sessions_running Detail is the count of
// running sessions; for every other code it is the sentence.
type Refusal struct {
	Code, Detail string
	Folder       *db.WorkbenchFolder
	OtherBench   *db.Workbench
}

// Error is "<code>: <sentence>" (spec D42), the text every caller — the CLI,
// MCP, a start — shows; sessions_running's sentence is spec §6.3's.
func (r *Refusal) Error() string {
	if r.Code == CodeSessionsRunning && r.Folder != nil {
		if r.Detail == "1" {
			return fmt.Sprintf("%s: 1 session is running in %s. Finish it first.", r.Code, r.Folder.Name)
		}
		return fmt.Sprintf("%s: %s sessions are running in %s. Finish them first.", r.Code, r.Detail, r.Folder.Name)
	}
	return r.Code + ": " + r.Detail
}

// SessionRowsSQL picks the agent session rows (not shells) of one folder:
// its own rows and, for the home folder, the bench's rows with no folder (a
// row written without the CLI reads as the home folder). Its two arguments
// are SessionRowsArgs. Callers add db.NotDeletingSQL and their own run
// conditions.
const SessionRowsSQL = `(workbench_folder_id = ? OR (workbench_folder_id IS NULL AND project_id = ?)) AND kind <> 'shell'`

// SessionRowsArgs are SessionRowsSQL's arguments for folder f; home says f
// is its bench's home folder.
func SessionRowsArgs(f db.WorkbenchFolder, home bool) []any {
	homeBench := int64(-1) // matches no project
	if home {
		homeBench = f.WorkbenchID
	}
	return []any{f.ID, homeBench}
}

// LockPath is the lock file that serialises folder membership changes of the
// workspace across processes (workbench folder add|remove|locate, resync,
// delete): the caller holds it (fsutil.LockFile) from before the
// transaction through the install or uninstall that follows it, so a
// remove's uninstall never strips a re-add's fresh install. The SQLite
// write transaction itself stays short inside it.
func LockPath(workspaceDir string) string {
	return filepath.Join(workspaceDir, "workbench-folders.lock")
}

// AddedBy values (workbench_folders.added_by).
const (
	AddedByOwner           = "owner"
	AddedByAgentSuggestion = "agent_suggestion"
)

// CheckAddedBy refuses an added_by value the column does not take.
func CheckAddedBy(addedBy string) error {
	if addedBy != AddedByOwner && addedBy != AddedByAgentSuggestion {
		return fmt.Errorf("added_by %q: want %s or %s", addedBy, AddedByOwner, AddedByAgentSuggestion)
	}
	return nil
}

// LiveSessions counts the sessions the session host runs in folder folderID
// (advisory; see Remove).
type LiveSessions func(ctx context.Context, folderID int64) (int, error)

// expandHome is path trimmed, with a leading `~` or `~/` made the home
// directory: the one expansion every lookup and write of this package does.
func expandHome(path string) (string, error) {
	p := strings.TrimSpace(path)
	if p != "~" && !strings.HasPrefix(p, "~/") {
		return p, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolving %s: %w", path, err)
	}
	return filepath.Join(home, strings.TrimPrefix(p, "~")), nil
}

// normalize is path as workbench_folders stores it: `~` expanded, absolute,
// symlinks resolved, cleaned, and checked against the folders no workbench
// may have — root, home, a line break, or overlapping a protected dir
// (Watchtower's own data) — on exactly that stored form
// (db.ResolveWorkbenchFolder). A path that names no directory is a
// not_found refusal; a refused folder keeps db.ErrWorkbenchFolderNotAllowed.
func normalize(path string, protected []string) (string, error) {
	p, err := expandHome(path)
	if err != nil {
		return "", err
	}
	resolved, err := db.ResolveWorkbenchFolder(p, protected)
	if errors.Is(err, db.ErrWorkbenchFolderNotAllowed) {
		return "", err //nolint:wrapcheck // db's message names the folder and why
	}
	if err != nil {
		return "", &Refusal{Code: CodeNotFound, Detail: path + " does not exist or is not a folder."}
	}
	return resolved, nil
}

// lookupForm is path as a lookup compares it: normalize's form when the path
// resolves, else `~` expanded, absolute and cleaned (a moved folder's old
// path no longer resolves).
func lookupForm(path string) string {
	p, err := expandHome(path)
	if err != nil {
		p = strings.TrimSpace(path)
	}
	if abs, err := filepath.Abs(p); err == nil {
		p = abs
	}
	if r, err := filepath.EvalSymlinks(p); err == nil {
		p = r
	}
	return filepath.Clean(p)
}

// within reports whether child lies strictly inside parent, by whole path
// components and ignoring case (APFS).
func within(child, parent string) bool {
	c, p := strings.ToLower(filepath.Clean(child)), strings.ToLower(filepath.Clean(parent))
	return strings.HasPrefix(c, strings.TrimSuffix(p, string(filepath.Separator))+string(filepath.Separator))
}

// Add puts the folder at path on workbench workbenchID, validated and
// written in one BEGIN IMMEDIATE transaction (spec §6.1): not_found (no such
// directory), already_here (a live folder of this bench, any spelling),
// other_bench (a live folder of another bench, named), nested (inside or
// containing a live folder of any bench, named; benches nested before this
// rule stay as they are). A folder this bench removed earlier comes back on
// its old row (same id, removed_at cleared, last position). The stored name
// is db.UniqueFolderName among the bench's live folders. protected are the
// directories no bench folder may overlap (Watchtower's own data; the
// caller knows where it lives).
func Add(ctx context.Context, d *db.DB, workbenchID int64, path, addedBy string, protected []string) (db.WorkbenchFolder, error) {
	if addedBy == "" {
		addedBy = AddedByOwner
	}
	if err := CheckAddedBy(addedBy); err != nil {
		return db.WorkbenchFolder{}, err
	}
	folder, err := normalize(path, protected)
	if err != nil {
		return db.WorkbenchFolder{}, err
	}
	var id int64
	err = withTx(ctx, d, func(tx *sql.Tx) error {
		if err := checkBench(ctx, tx, workbenchID); err != nil {
			return err
		}
		if err := checkFree(ctx, tx, workbenchID, 0, folder); err != nil {
			return err
		}
		name, err := uniqueName(ctx, tx, workbenchID, folder)
		if err != nil {
			return err
		}
		var pos int
		if err := tx.QueryRowContext(ctx, `SELECT COALESCE(MAX(position), -1) + 1 FROM workbench_folders WHERE workbench_id = ?`,
			workbenchID).Scan(&pos); err != nil {
			return fmt.Errorf("reading the folders of workbench %d: %w", workbenchID, err)
		}
		// A folder this bench removed comes back on its row (spec §4 item 1).
		err = tx.QueryRowContext(ctx, `SELECT id FROM workbench_folders WHERE workbench_id = ? AND folder_path = ? COLLATE NOCASE
			AND removed_at IS NOT NULL ORDER BY id DESC LIMIT 1`, workbenchID, folder).Scan(&id)
		switch {
		case err == nil:
			_, err = tx.ExecContext(ctx, `UPDATE workbench_folders SET removed_at = NULL, position = ?, name = ?, folder_path = ?,
				added_by = ?, added_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?`, pos, name, folder, addedBy, id)
			if err != nil {
				return fmt.Errorf("putting folder %s back on workbench %d: %w", folder, workbenchID, err)
			}
			return nil
		case !errors.Is(err, sql.ErrNoRows):
			return fmt.Errorf("reading the folders of workbench %d: %w", workbenchID, err)
		}
		res, err := tx.ExecContext(ctx, `INSERT INTO workbench_folders (workbench_id, folder_path, position, added_by, name)
			VALUES (?, ?, ?, ?, ?)`, workbenchID, folder, pos, addedBy, name)
		if err != nil {
			return fmt.Errorf("putting folder %s on workbench %d: %w", folder, workbenchID, err)
		}
		id, err = res.LastInsertId()
		return err
	})
	if err != nil {
		return db.WorkbenchFolder{}, uniqueRace(ctx, d, workbenchID, folder, err)
	}
	return byID(ctx, d, id)
}

// Remove takes folder folderID off its bench (spec §6.3) in one BEGIN
// IMMEDIATE transaction: refused with last_folder for the bench's only live
// folder and with sessions_running (Detail = the count) while sessions run in
// it; otherwise removed_at is set and, when it was the home folder,
// projects.folder_path moves to the next live folder by position. The
// uninstall and the docs drop are the caller's, after the commit.
//
// Running sessions: live (the session host's answer, asked before the
// transaction — never host I/O inside it) is advisory. Inside the
// transaction the rows are recounted from terminal_sessions alone
// (countLiveRows): with an answer from live, only the rows a start may have
// inserted since — newer than the mark taken before asking, or never
// reported by a hook yet — so a start committed first is seen; without one
// (nil, or it failed), every live-looking row counts.
func Remove(ctx context.Context, d *db.DB, folderID int64, live LiveSessions) (db.WorkbenchFolder, error) {
	f, err := byID(ctx, d, folderID)
	if err != nil {
		return f, err
	}
	hostCount, mark, asked := 0, int64(0), false
	if live != nil {
		if err := d.QueryRowContext(ctx, `SELECT COALESCE(MAX(id), 0) FROM terminal_sessions WHERE `+db.NotDeletingSQL).Scan(&mark); err != nil {
			return f, fmt.Errorf("reading the terminal sessions: %w", err)
		}
		if n, err := live(ctx, folderID); err == nil {
			hostCount, asked = n, true
		}
	}
	err = withTx(ctx, d, func(tx *sql.Tx) error {
		cur, err := liveFolder(ctx, tx, folderID)
		if err != nil {
			return err
		}
		f = *cur
		var benchFolder string
		if err := tx.QueryRowContext(ctx, `SELECT folder_path FROM projects WHERE id = ?`, f.WorkbenchID).Scan(&benchFolder); err != nil {
			return fmt.Errorf("reading workbench %d: %w", f.WorkbenchID, err)
		}
		home := strings.EqualFold(benchFolder, f.FolderPath)
		var others int
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM workbench_folders WHERE workbench_id = ? AND removed_at IS NULL AND id <> ?`,
			f.WorkbenchID, f.ID).Scan(&others); err != nil {
			return fmt.Errorf("reading the folders of workbench %d: %w", f.WorkbenchID, err)
		}
		if others == 0 {
			return &Refusal{Code: CodeLastFolder, Detail: "A workbench needs at least one folder.", Folder: &f}
		}
		running, err := countLiveRows(ctx, tx, f, home, asked, mark)
		if err != nil {
			return err
		}
		if n := max(hostCount, running); n > 0 {
			return &Refusal{Code: CodeSessionsRunning, Detail: strconv.Itoa(n), Folder: &f}
		}
		if _, err := tx.ExecContext(ctx, `UPDATE workbench_folders SET removed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?`,
			f.ID); err != nil {
			return fmt.Errorf("removing folder %d: %w", f.ID, err)
		}
		if !home {
			return nil
		}
		var next string
		if err := tx.QueryRowContext(ctx, `SELECT folder_path FROM workbench_folders WHERE workbench_id = ? AND removed_at IS NULL
			ORDER BY position, id LIMIT 1`, f.WorkbenchID).Scan(&next); err != nil {
			return fmt.Errorf("finding the next home folder of workbench %d: %w", f.WorkbenchID, err)
		}
		if _, err := tx.ExecContext(ctx, `UPDATE projects SET folder_path = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
			WHERE id = ?`, next, f.WorkbenchID); err != nil {
			return fmt.Errorf("moving the home folder of workbench %d: %w", f.WorkbenchID, err)
		}
		return nil
	})
	if err != nil {
		return f, err
	}
	return byID(ctx, d, folderID)
}

// countLiveRows counts f's session rows (SessionRowsSQL) that may be running
// (F2): not being deleted, not finished and not failed to launch; with
// asked, only those newer than mark or never reported by a hook.
func countLiveRows(ctx context.Context, tx *sql.Tx, f db.WorkbenchFolder, home, asked bool, mark int64) (int, error) {
	q := `SELECT COUNT(*) FROM terminal_sessions WHERE ` + SessionRowsSQL + ` AND ` + db.NotDeletingSQL +
		` AND finished_at IS NULL AND agent_failed_at IS NULL`
	args := SessionRowsArgs(f, home)
	if asked {
		// The host answered for what ran before the mark; a start since
		// (or one still launching: no hook has reported it) is the race
		// the recount closes (spec §7 row 4).
		q += ` AND (id > ? OR agent_state IS NULL)`
		args = append(args, mark)
	}
	var n int
	if err := tx.QueryRowContext(ctx, q, args...).Scan(&n); err != nil {
		return 0, fmt.Errorf("counting the sessions of folder %d: %w", f.ID, err)
	}
	return n, nil
}

// Locate re-points folder folderID, moved or deleted, to newPath (spec §6.3
// Locate…), with Add's validation (the folder itself aside); the name stays.
// A folder still at its stored path is refused with folder_present: its
// install is there, so it is removed from the bench instead. When it is the
// home folder, projects.folder_path follows. The reinstall is the caller's.
func Locate(ctx context.Context, d *db.DB, folderID int64, newPath string, protected []string) (db.WorkbenchFolder, error) {
	f, err := byID(ctx, d, folderID)
	if err != nil {
		return f, err
	}
	if _, err := onBench(f); err != nil {
		return f, err
	}
	if info, serr := os.Stat(f.FolderPath); serr == nil && info.IsDir() {
		return f, &Refusal{Code: CodeFolderPresent, Detail: fmt.Sprintf("%s is still at %s. Remove it from the bench instead.", f.Name, f.FolderPath),
			Folder: &f}
	}
	folder, err := normalize(newPath, protected)
	if err != nil {
		return f, err
	}
	err = withTx(ctx, d, func(tx *sql.Tx) error {
		cur, err := liveFolder(ctx, tx, folderID)
		if err != nil {
			return err
		}
		f = *cur
		if err := checkFree(ctx, tx, f.WorkbenchID, f.ID, folder); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `UPDATE workbench_folders SET folder_path = ? WHERE id = ?`, folder, f.ID); err != nil {
			return fmt.Errorf("re-pointing folder %d: %w", f.ID, err)
		}
		if _, err := tx.ExecContext(ctx, `UPDATE projects SET folder_path = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
			WHERE id = ? AND folder_path = ? COLLATE NOCASE`, folder, f.WorkbenchID, f.FolderPath); err != nil {
			return fmt.Errorf("re-pointing the home folder of workbench %d: %w", f.WorkbenchID, err)
		}
		return nil
	})
	if err != nil {
		return f, uniqueRace(ctx, d, f.WorkbenchID, folder, err)
	}
	return byID(ctx, d, folderID)
}

// Resolve finds a folder of workbench workbenchID by ref: "" is the home
// folder, then a folder id, the stored name (NOCASE; unique among the
// bench's live folders), or a path (any spelling). A folder that left the
// bench is folder_removed; anything else not on the bench is not_found.
func Resolve(ctx context.Context, d *db.DB, workbenchID int64, ref string) (db.WorkbenchFolder, error) {
	ref = strings.TrimSpace(ref)
	if ref == "" {
		f, err := d.HomeFolder(ctx, workbenchID)
		if errors.Is(err, db.ErrWorkbenchNotFound) {
			return db.WorkbenchFolder{}, &Refusal{Code: CodeNotFound, Detail: fmt.Sprintf("workbench %d has no folder.", workbenchID)}
		}
		if err != nil {
			return db.WorkbenchFolder{}, err //nolint:wrapcheck // db's message names the workbench
		}
		fallback, err := IsFallbackHome(ctx, d, *f)
		if err != nil || fallback {
			return *f, err
		}
		return onBench(*f)
	}
	all, err := d.WorkbenchFolders(ctx, workbenchID, true)
	if err != nil {
		return db.WorkbenchFolder{}, err //nolint:wrapcheck // db's message names the workbench
	}
	if id, perr := strconv.ParseInt(ref, 10, 64); perr == nil {
		for _, f := range all {
			if f.ID == id {
				return onBench(f)
			}
		}
	}
	for _, f := range all {
		if !f.RemovedAt.Valid && strings.EqualFold(f.Name, ref) {
			return f, nil
		}
	}
	path := lookupForm(ref)
	var removed *db.WorkbenchFolder
	for i, f := range all {
		if !strings.EqualFold(f.FolderPath, path) {
			continue
		}
		if !f.RemovedAt.Valid {
			return f, nil
		}
		removed = &all[i]
	}
	if removed != nil {
		return onBench(*removed)
	}
	return db.WorkbenchFolder{}, &Refusal{Code: CodeNotFound, Detail: fmt.Sprintf("%s is not a folder of workbench %d.", ref, workbenchID)}
}

// IsFallbackHome reports whether f is a removed row that is still its
// bench's home because the bench has no live folder at all: a legacy bench
// whose only row migration 00196 marked removed (a case-insensitive
// duplicate of another bench's folder; db.HomeFolder's fallback). Such a
// bench keeps working in that folder as before the migration. q may be a
// caller's transaction.
func IsFallbackHome(ctx context.Context, q db.Querier, f db.WorkbenchFolder) (bool, error) {
	if !f.RemovedAt.Valid {
		return false, nil
	}
	var live bool
	if err := q.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM workbench_folders WHERE workbench_id = ? AND removed_at IS NULL)`,
		f.WorkbenchID).Scan(&live); err != nil {
		return false, fmt.Errorf("reading the folders of workbench %d: %w", f.WorkbenchID, err)
	}
	return !live, nil
}

// onBench is f, or folder_removed when it left the bench.
func onBench(f db.WorkbenchFolder) (db.WorkbenchFolder, error) {
	if f.RemovedAt.Valid {
		return f, &Refusal{Code: CodeFolderRemoved, Detail: f.Name + " was removed from the bench.", Folder: &f}
	}
	return f, nil
}

func withTx(ctx context.Context, d *db.DB, fn func(*sql.Tx) error) error {
	tx, err := d.BeginTx(ctx, nil) // BEGIN IMMEDIATE (db.Open's _txlock)
	if err != nil {
		return fmt.Errorf("beginning transaction: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	if err := fn(tx); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("committing: %w", err)
	}
	return nil
}

func byID(ctx context.Context, d *db.DB, id int64) (db.WorkbenchFolder, error) {
	f, err := d.WorkbenchFolderByID(ctx, id)
	if errors.Is(err, db.ErrWorkbenchNotFound) {
		return db.WorkbenchFolder{}, &Refusal{Code: CodeNotFound, Detail: fmt.Sprintf("there is no workbench folder %d.", id)}
	}
	if err != nil {
		return db.WorkbenchFolder{}, err //nolint:wrapcheck // db's message names the folder
	}
	return *f, nil
}

// liveFolder re-reads folder id inside tx: not_found, or folder_removed once
// it left the bench.
func liveFolder(ctx context.Context, tx *sql.Tx, id int64) (*db.WorkbenchFolder, error) {
	var f db.WorkbenchFolder
	err := tx.QueryRowContext(ctx, `SELECT id, workbench_id, folder_path, name, position, added_at, added_by, removed_at
		FROM workbench_folders WHERE id = ?`, id).Scan(&f.ID, &f.WorkbenchID, &f.FolderPath, &f.Name, &f.Position,
		&f.AddedAt, &f.AddedBy, &f.RemovedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, &Refusal{Code: CodeNotFound, Detail: fmt.Sprintf("there is no workbench folder %d.", id)}
	}
	if err != nil {
		return nil, fmt.Errorf("reading workbench folder %d: %w", id, err)
	}
	if _, err := onBench(f); err != nil {
		return nil, err
	}
	return &f, nil
}

func checkBench(ctx context.Context, tx *sql.Tx, workbenchID int64) error {
	var one int
	err := tx.QueryRowContext(ctx, `SELECT 1 FROM projects WHERE id = ?`, workbenchID).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("workbench %d: %w", workbenchID, db.ErrWorkbenchNotFound)
	}
	if err != nil {
		return fmt.Errorf("reading workbench %d: %w", workbenchID, err)
	}
	return nil
}

// checkFree refuses folder for workbench workbenchID when a live folder other
// than self already is it (already_here / other_bench) or nests with it
// (nested).
func checkFree(ctx context.Context, tx *sql.Tx, workbenchID, self int64, folder string) error {
	live, err := liveFolders(ctx, tx, 0, self)
	if err != nil {
		return err
	}
	for i := range live {
		f := &live[i]
		if !strings.EqualFold(f.FolderPath, folder) {
			continue
		}
		if f.WorkbenchID == workbenchID {
			return &Refusal{Code: CodeAlreadyHere, Detail: fmt.Sprintf("%s is already on this bench as %s.", folder, f.Name), Folder: f}
		}
		return otherBench(ctx, tx, f, folder)
	}
	for i := range live {
		f := &live[i]
		switch {
		case within(folder, f.FolderPath):
			return &Refusal{Code: CodeNested, Detail: fmt.Sprintf("%s is inside %s (%s), a folder on a bench.", folder, f.Name, f.FolderPath), Folder: f}
		case within(f.FolderPath, folder):
			return &Refusal{Code: CodeNested, Detail: fmt.Sprintf("%s contains %s (%s), a folder on a bench.", folder, f.Name, f.FolderPath), Folder: f}
		}
	}
	return nil
}

func otherBench(ctx context.Context, q db.Querier, f *db.WorkbenchFolder, folder string) error {
	var name string
	if err := q.QueryRowContext(ctx, `SELECT name FROM projects WHERE id = ?`, f.WorkbenchID).Scan(&name); err != nil {
		return fmt.Errorf("reading workbench %d: %w", f.WorkbenchID, err)
	}
	return &Refusal{Code: CodeOtherBench, Detail: fmt.Sprintf("%s is on the workbench %q.", folder, name), Folder: f,
		OtherBench: &db.Workbench{ID: f.WorkbenchID, Name: name}}
}

// uniqueName is db.UniqueFolderName among the live folders of workbenchID.
func uniqueName(ctx context.Context, tx *sql.Tx, workbenchID int64, folder string) (string, error) {
	live, err := liveFolders(ctx, tx, workbenchID, 0)
	if err != nil {
		return "", err
	}
	taken := map[string]bool{}
	for _, f := range live {
		taken[strings.ToLower(f.Name)] = true
	}
	return db.UniqueFolderName(folder, func(n string) bool { return taken[strings.ToLower(n)] }), nil
}

// liveFolders reads the live folders of workbenchID (0 = of every bench)
// inside tx, by id, leaving out folder except (0 = none).
func liveFolders(ctx context.Context, tx *sql.Tx, workbenchID, except int64) ([]db.WorkbenchFolder, error) {
	rows, err := tx.QueryContext(ctx, `SELECT id, workbench_id, folder_path, name, position, added_at, added_by, removed_at
		FROM workbench_folders WHERE removed_at IS NULL AND (? = 0 OR workbench_id = ?) AND id <> ? ORDER BY id`,
		workbenchID, workbenchID, except)
	if err != nil {
		return nil, fmt.Errorf("reading the workbench folders: %w", err)
	}
	defer rows.Close()
	var out []db.WorkbenchFolder
	for rows.Next() {
		var f db.WorkbenchFolder
		if err := rows.Scan(&f.ID, &f.WorkbenchID, &f.FolderPath, &f.Name, &f.Position, &f.AddedAt, &f.AddedBy, &f.RemovedAt); err != nil {
			return nil, fmt.Errorf("reading the workbench folders: %w", err)
		}
		out = append(out, f)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading the workbench folders: %w", err)
	}
	return out, nil
}

// uniqueRace turns a live-path unique violation — a racing write that slipped
// past the checks, such as `workbench create` — into the refusal the checks
// would have given; any other error is returned as is.
func uniqueRace(ctx context.Context, d *db.DB, workbenchID int64, folder string, err error) error {
	if !strings.Contains(err.Error(), "UNIQUE constraint failed: workbench_folders.folder_path") {
		return err
	}
	f, lerr := d.LiveFolderByPath(ctx, d, folder)
	if lerr != nil {
		return err
	}
	if f.WorkbenchID == workbenchID {
		return &Refusal{Code: CodeAlreadyHere, Detail: fmt.Sprintf("%s is already on this bench as %s.", folder, f.Name), Folder: f}
	}
	return otherBench(ctx, d, f, folder)
}

// GitFolders is every live folder path of workbench workbenchID with home
// (projects.folder_path) first — workbenchgit.Options.Folders, whose first
// entry is the fallback. home is listed even when no live row holds it (a
// legacy bench on db.HomeFolder's fallback).
func GitFolders(ctx context.Context, d *db.DB, workbenchID int64, home string) ([]string, error) {
	live, err := d.WorkbenchFolders(ctx, workbenchID, false)
	if err != nil {
		return nil, err //nolint:wrapcheck // db's message names the workbench
	}
	paths := []string{home}
	for _, f := range live {
		if !strings.EqualFold(f.FolderPath, home) {
			paths = append(paths, f.FolderPath)
		}
	}
	return paths, nil
}
