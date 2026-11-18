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

// LiveBenchSessions counts the session host's live runs of workbench
// workbenchID's agent rows (advisory; see Merge).
type LiveBenchSessions func(ctx context.Context, workbenchID int64) (int, error)

// MergeReport is what a merge moved, and where the devpack is reinstalled
// with the surviving bench's id after the commit.
type MergeReport struct {
	// MovedFolders are the merged bench's live folders as they now are on
	// the surviving bench (renamed when a name clashed); never nil.
	MovedFolders []db.WorkbenchFolder
	// Targets is how many targets moved.
	Targets int
	// Reinstall is every moved live folder, then every place the merged
	// bench's agent sessions ran in that is still on disk and none of those
	// folders — their worktrees (spec §6.13); never nil.
	Reinstall []string
}

// mergeOp is what a merge does with one table's rows of the merged bench.
type mergeOp int

const (
	// opMove re-keys the rows to the surviving bench.
	opMove mergeOp = iota
	// opDedupe re-keys them, dropping a row whose unique key the surviving
	// bench already holds (its own row is kept).
	opDedupe
	// opDrop deletes them.
	opDrop
	// opCustom runs mergeTable.apply.
	opCustom
)

// mergeTable is one table keyed by the merged bench's id: column is the key
// column, op what the merge does with the rows (apply for opCustom), inside
// the merge transaction.
type mergeTable struct {
	table, column string
	op            mergeOp
	apply         func(ctx context.Context, tx *sql.Tx, m *merger) error
}

// mergeTables is every table keyed by a workbench id — a foreign key to
// projects, or a project_id/workbench_id column
// (TestMergeCoversEveryWorkbenchKeyedTable fails on one missing). Order
// matters: the folders move first (the rows naming the merged bench's home
// folder by NULL are pinned to it on their way), the targets before the
// board columns they point at are dropped.
var mergeTables = []mergeTable{
	{table: "workbench_folders", column: "workbench_id", op: opCustom, apply: moveFolders},
	{table: "targets", column: "project_id", op: opCustom, apply: moveTargets},
	// B's columns go; its targets land in A's first column of their status
	// (PROJ-19: board_column_id NULL).
	{table: "workbench_board_columns", column: "project_id", op: opDrop},
	{table: "workbench_folder_declines", column: "workbench_id", op: opDrop},
	{table: "project_sources", column: "project_id", op: opDedupe},
	{table: "project_target_images", column: "project_id", op: opMove},
	{table: "project_comments", column: "project_id", op: opMove},
	{table: "terminal_sessions", column: "project_id", op: opCustom, apply: pinHomeThenMove("terminal_sessions", "workbench_folder_id", "")},
	{table: "owner_asks", column: "project_id", op: opCustom, apply: pinHomeThenMove("owner_asks", "doc_folder_id", "doc_path <> ''")},
	{table: "coach_proposals", column: "workbench_id", op: opMove},
	// Keyed by folder too (00196): B's folders came along, so no clash.
	{table: "workbench_pr_states", column: "project_id", op: opMove},
	{table: "review_reviewer_threads", column: "project_id", op: opMove},
	{table: "automations", column: "project_id", op: opCustom, apply: moveAutomations},
	{table: "review_rounds", column: "project_id", op: opMove},
	{table: "review_notes", column: "project_id", op: opMove},
	// Caches keyed by content: the surviving bench's copy stays.
	{table: "review_overviews", column: "project_id", op: opDedupe},
	{table: "review_overview_parts", column: "project_id", op: opDedupe},
	{table: "review_lessons", column: "project_id", op: opMove},
	{table: "instruction_suggestions", column: "workbench_id", op: opMove},
	// No foreign key: re-keyed explicitly, or it would point at nothing.
	{table: "permission_requests", column: "workbench_id", op: opMove},
	{table: "session_messages", column: "workbench_id", op: opMove},
	{table: "agent_log_sessions", column: "project_id", op: opMove},
}

// mergeStepHook, when set (tests only), runs before each table's step; its
// error fails the merge — the "crash mid-move" injection (spec §7).
var mergeStepHook func(table string) error

// rollupTrigger is PROJ-05's status rollup on a target's move. A merge moves
// whole trees whose statuses already agree, but the trigger fires per row
// and would re-derive a parent from the part of its children moved so far;
// the merge drops it for its one UPDATE and re-creates it from its stored
// text, inside the transaction.
const rollupTrigger = "targets_project_status_rollup_au"

// merger is one merge's state inside its transaction.
type merger struct {
	from, into int64
	fromName   string
	// fromHome is the merged bench's home folder: its rows that name it by
	// NULL are pinned to it before they move (on the surviving bench NULL
	// means that bench's own home).
	fromHome int64
	// folders is every folder row the merged bench had, as moved.
	folders []db.WorkbenchFolder
	report  *MergeReport
}

// Merge merges workbench from into workbench into (spec §6.13; PROJ-09 as
// amended by ask #1548). One BEGIN IMMEDIATE transaction re-counts from's
// live sessions — sessions_running refuses the merge and writes nothing —
// moves every row keyed by from's id (mergeTables) and deletes from's
// projects row: all of it or nothing. The reinstall and the re-index run
// after it, in the caller, which holds the folder lock (LockPath) from
// before this call. live (nil = no host) is the host's count, asked before
// the transaction; inside it the rows that may have started since count
// too, as in Remove.
func Merge(ctx context.Context, d *db.DB, from, into int64, live LiveBenchSessions) (MergeReport, error) {
	if from == into {
		return MergeReport{}, &Refusal{Code: CodeAlreadyHere, Detail: "a workbench cannot be merged into itself."}
	}
	hostCount, mark, asked := 0, int64(0), false
	if live != nil {
		if err := d.QueryRowContext(ctx, `SELECT COALESCE(MAX(id), 0) FROM terminal_sessions WHERE `+db.NotDeletingSQL).Scan(&mark); err != nil {
			return MergeReport{}, fmt.Errorf("reading the terminal sessions: %w", err)
		}
		if n, err := live(ctx, from); err == nil {
			hostCount, asked = n, true
		}
	}
	report := MergeReport{MovedFolders: []db.WorkbenchFolder{}, Reinstall: []string{}}
	var cwds []string
	err := withTx(ctx, d, func(tx *sql.Tx) error {
		m := &merger{from: from, into: into, report: &report}
		if err := checkBench(ctx, tx, into); err != nil {
			return err
		}
		if err := tx.QueryRowContext(ctx, `SELECT name FROM projects WHERE id = ?`, from).Scan(&m.fromName); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return fmt.Errorf("workbench %d: %w", from, db.ErrWorkbenchNotFound)
			}
			return fmt.Errorf("reading workbench %d: %w", from, err)
		}
		running, err := countBenchLiveRows(ctx, tx, from, asked, mark)
		if err != nil {
			return err
		}
		if n := max(hostCount, running); n > 0 {
			return &Refusal{Code: CodeSessionsRunning, Detail: strconv.Itoa(n), OtherBench: &db.Workbench{ID: from, Name: m.fromName}}
		}
		if err := tx.QueryRowContext(ctx, `SELECT f.id FROM workbench_folders f JOIN projects p ON p.id = f.workbench_id
			WHERE f.workbench_id = ?
			ORDER BY (f.removed_at IS NULL AND f.folder_path = p.folder_path COLLATE NOCASE) DESC, f.position, f.id
			LIMIT 1`, from).Scan(&m.fromHome); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return &Refusal{Code: CodeNotFound, Detail: fmt.Sprintf("workbench %d has no folder.", from)}
			}
			return fmt.Errorf("reading the home folder of workbench %d: %w", from, err)
		}
		if cwds, err = sessionCwds(ctx, tx, from); err != nil {
			return err
		}
		for _, t := range mergeTables {
			if mergeStepHook != nil {
				if err := mergeStepHook(t.table); err != nil {
					return err
				}
			}
			if err := t.run(ctx, tx, m); err != nil {
				return fmt.Errorf("merging %s of workbench %d: %w", t.table, from, err)
			}
		}
		if _, err := tx.ExecContext(ctx, `DELETE FROM projects WHERE id = ?`, from); err != nil {
			return fmt.Errorf("deleting workbench %d: %w", from, err)
		}
		return nil
	})
	if err != nil {
		return MergeReport{}, err
	}
	report.Reinstall = reinstallPlaces(report.MovedFolders, cwds)
	return report, nil
}

// run applies t to the merged bench's rows.
func (t mergeTable) run(ctx context.Context, tx *sql.Tx, m *merger) error {
	if t.op == opCustom {
		return t.apply(ctx, tx, m)
	}
	//nolint:gosec // G202: table and column names are mergeTables' constants; every value is a bound arg.
	rekey, drop := `UPDATE `+t.table+` SET `+t.column+` = ? WHERE `+t.column+` = ?`, `DELETE FROM `+t.table+` WHERE `+t.column+` = ?`
	switch t.op {
	case opDrop:
		_, err := tx.ExecContext(ctx, drop, m.from)
		return err //nolint:wrapcheck // Merge names the table
	case opDedupe:
		ignoring := strings.Replace(rekey, "UPDATE ", "UPDATE OR IGNORE ", 1)
		if _, err := tx.ExecContext(ctx, ignoring, m.into, m.from); err != nil {
			return err //nolint:wrapcheck // Merge names the table
		}
		// What is left clashed with a row the surviving bench already had.
		_, err := tx.ExecContext(ctx, drop, m.from)
		return err //nolint:wrapcheck // Merge names the table
	default:
		_, err := tx.ExecContext(ctx, rekey, m.into, m.from)
		return err //nolint:wrapcheck // Merge names the table
	}
}

// moveFolders moves every folder row of the merged bench, positioned after
// the surviving bench's; a live folder whose name a live folder there
// already has is renamed (db.UniqueFolderName).
func moveFolders(ctx context.Context, tx *sql.Tx, m *merger) error {
	var last int
	if err := tx.QueryRowContext(ctx, `SELECT COALESCE(MAX(position), -1) FROM workbench_folders WHERE workbench_id = ?`,
		m.into).Scan(&last); err != nil {
		return fmt.Errorf("reading the folders of workbench %d: %w", m.into, err)
	}
	live, err := liveFolders(ctx, tx, m.into, 0)
	if err != nil {
		return err
	}
	taken := map[string]bool{}
	for _, f := range live {
		taken[strings.ToLower(f.Name)] = true
	}
	rows, err := tx.QueryContext(ctx, `SELECT `+folderCols+` FROM workbench_folders WHERE workbench_id = ? ORDER BY position, id`, m.from)
	if err != nil {
		return fmt.Errorf("reading the folders of workbench %d: %w", m.from, err)
	}
	moving, err := scanFolders(rows)
	if err != nil {
		return err
	}
	for i := range moving {
		f := &moving[i]
		last++
		f.WorkbenchID, f.Position = m.into, last
		if !f.RemovedAt.Valid {
			if taken[strings.ToLower(f.Name)] {
				f.Name = db.UniqueFolderName(f.FolderPath, func(n string) bool { return taken[strings.ToLower(n)] })
			}
			taken[strings.ToLower(f.Name)] = true
		}
		if _, err := tx.ExecContext(ctx, `UPDATE workbench_folders SET workbench_id = ?, position = ?, name = ? WHERE id = ?`,
			f.WorkbenchID, f.Position, f.Name, f.ID); err != nil {
			return fmt.Errorf("moving folder %d: %w", f.ID, err)
		}
		if !f.RemovedAt.Valid {
			m.report.MovedFolders = append(m.report.MovedFolders, *f)
		}
	}
	m.folders = moving
	return nil
}

// moveTargets moves every target of the merged bench with its tree, status
// and folder: a target on the merged bench's home folder (NULL) is pinned
// to it, and each lands in the surviving bench's first column of its status
// (PROJ-19). The rollup trigger is suspended meanwhile (rollupTrigger).
func moveTargets(ctx context.Context, tx *sql.Tx, m *merger) error {
	var trigger string
	if err := tx.QueryRowContext(ctx, `SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = ?`,
		rollupTrigger).Scan(&trigger); err != nil {
		return fmt.Errorf("reading trigger %s: %w", rollupTrigger, err)
	}
	if _, err := tx.ExecContext(ctx, `DROP TRIGGER `+rollupTrigger); err != nil {
		return fmt.Errorf("suspending trigger %s: %w", rollupTrigger, err)
	}
	res, err := tx.ExecContext(ctx, `UPDATE targets SET project_id = ?, board_column_id = NULL,
		workbench_folder_id = COALESCE(workbench_folder_id, ?) WHERE project_id = ?`, m.into, m.fromHome, m.from)
	if err != nil {
		return err //nolint:wrapcheck // Merge names the table
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err //nolint:wrapcheck // Merge names the table
	}
	m.report.Targets = int(n)
	if _, err := tx.ExecContext(ctx, trigger); err != nil {
		return fmt.Errorf("restoring trigger %s: %w", rollupTrigger, err)
	}
	return nil
}

// pinHomeThenMove re-keys table's rows after pinning the ones whose column
// is NULL — the merged bench's home folder — to that folder (where, when
// set, narrows the rows the NULL means a folder for).
func pinHomeThenMove(table, column, where string) func(ctx context.Context, tx *sql.Tx, m *merger) error {
	//nolint:gosec // G202: table, column and where are mergeTables' constants; every value is a bound arg.
	pin, move := `UPDATE `+table+` SET `+column+` = ? WHERE project_id = ? AND `+column+` IS NULL`, `UPDATE `+table+` SET project_id = ? WHERE project_id = ?`
	if where != "" {
		pin += ` AND ` + where
	}
	return func(ctx context.Context, tx *sql.Tx, m *merger) error {
		if _, err := tx.ExecContext(ctx, pin, m.fromHome, m.from); err != nil {
			return err //nolint:wrapcheck // Merge names the table
		}
		_, err := tx.ExecContext(ctx, move, m.into, m.from)
		return err //nolint:wrapcheck // Merge names the table
	}
}

// moveAutomations moves the merged bench's recipes; a slug the surviving
// bench already holds becomes <folder name>/<slug> (the indexer's own name
// for such a recipe, spec §6.11), its folder being the moved folder the
// recipe lies in.
func moveAutomations(ctx context.Context, tx *sql.Tx, m *merger) error {
	held, err := benchRecipes(ctx, tx, m.into)
	if err != nil {
		return err
	}
	taken := map[string]bool{}
	for _, r := range held {
		taken[r.slug] = true
	}
	moving, err := benchRecipes(ctx, tx, m.from)
	if err != nil {
		return err
	}
	for _, r := range moving {
		slug := r.slug
		if taken[slug] {
			slug = m.recipeSlug(r.slug, r.path, taken)
		}
		taken[slug] = true
		if _, err := tx.ExecContext(ctx, `UPDATE automations SET project_id = ?, slug = ? WHERE id = ?`, m.into, slug, r.id); err != nil {
			return fmt.Errorf("moving automation %d: %w", r.id, err)
		}
	}
	return nil
}

// recipe is one automations row of a bench.
type recipe struct {
	id         int64
	slug, path string
}

// benchRecipes is workbench wb's automations rows, by id.
func benchRecipes(ctx context.Context, tx *sql.Tx, wb int64) ([]recipe, error) {
	rows, err := tx.QueryContext(ctx, `SELECT id, slug, path FROM automations WHERE project_id = ? ORDER BY id`, wb)
	if err != nil {
		return nil, fmt.Errorf("reading the automations of workbench %d: %w", wb, err)
	}
	defer rows.Close()
	var out []recipe
	for rows.Next() {
		var r recipe
		if err := rows.Scan(&r.id, &r.slug, &r.path); err != nil {
			return nil, fmt.Errorf("reading the automations of workbench %d: %w", wb, err)
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading the automations of workbench %d: %w", wb, err)
	}
	return out, nil
}

// recipeSlug is <folder name>/<stem> for the recipe at path whose slug is
// taken, with -2, -3… after the stem while that is taken too. The folder is
// the moved folder holding path (the merged bench's name when none does).
func (m *merger) recipeSlug(slug, path string, taken map[string]bool) string {
	if _, stem, ok := strings.Cut(slug, "/"); ok {
		slug = stem
	}
	name, depth := m.fromName, -1
	for _, f := range m.folders {
		if d := len(f.FolderPath); within(path, f.FolderPath) && d > depth {
			name, depth = f.Name, d
		}
	}
	cand := name + "/" + slug
	for n := 2; taken[cand]; n++ {
		cand = name + "/" + slug + "-" + strconv.Itoa(n)
	}
	return cand
}

// runningInBench is a merge's sessions_running sentence (spec §6.13).
func (r *Refusal) runningInBench() string {
	if r.Detail == "1" {
		return fmt.Sprintf("%s: 1 session is running in %s. Finish it first.", r.Code, r.OtherBench.Name)
	}
	return fmt.Sprintf("%s: %s sessions are running in %s. Finish them first.", r.Code, r.Detail, r.OtherBench.Name)
}

// countBenchLiveRows is countLiveRows for a whole bench: its agent rows that
// may be running (F2) and, with asked, only those newer than mark or never
// reported by a hook.
func countBenchLiveRows(ctx context.Context, tx *sql.Tx, wb int64, asked bool, mark int64) (int, error) {
	q := `SELECT COUNT(*) FROM terminal_sessions WHERE project_id = ? AND kind <> 'shell' AND ` + db.NotDeletingSQL +
		` AND finished_at IS NULL AND agent_failed_at IS NULL`
	args := []any{wb}
	if asked {
		q += ` AND (id > ? OR agent_state IS NULL)`
		args = append(args, mark)
	}
	var n int
	if err := tx.QueryRowContext(ctx, q, args...).Scan(&n); err != nil {
		return 0, fmt.Errorf("counting the sessions of workbench %d: %w", wb, err)
	}
	return n, nil
}

// sessionCwds is every place the merged bench's agent sessions ran in: the
// rows' folder_path and every worktree root they reported.
func sessionCwds(ctx context.Context, tx *sql.Tx, wb int64) ([]string, error) {
	rows, err := tx.QueryContext(ctx, `SELECT folder_path FROM terminal_sessions WHERE project_id = ? AND kind <> 'shell'
		UNION SELECT w.root FROM terminal_session_worktrees w JOIN terminal_sessions s ON s.id = w.session_id
		WHERE s.project_id = ? AND s.kind <> 'shell'`, wb, wb)
	if err != nil {
		return nil, fmt.Errorf("reading the session folders of workbench %d: %w", wb, err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var p string
		if err := rows.Scan(&p); err != nil {
			return nil, fmt.Errorf("reading the session folders of workbench %d: %w", wb, err)
		}
		out = append(out, p)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading the session folders of workbench %d: %w", wb, err)
	}
	return out, nil
}

// reinstallPlaces is the moved folders, then each cwd still on disk that is
// none of them, once each.
func reinstallPlaces(folders []db.WorkbenchFolder, cwds []string) []string {
	out := []string{}
	seen := map[string]bool{}
	add := func(p string) {
		if key := strings.ToLower(filepath.Clean(p)); !seen[key] {
			seen[key] = true
			out = append(out, p)
		}
	}
	for _, f := range folders {
		add(f.FolderPath)
	}
	for _, p := range cwds {
		if info, err := os.Stat(p); err == nil && info.IsDir() {
			add(p)
		}
	}
	return out
}
