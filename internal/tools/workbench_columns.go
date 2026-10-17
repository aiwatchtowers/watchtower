package tools

import (
	"database/sql"
	"fmt"
	"strings"

	"watchtower/internal/db"
)

// Board columns on the workbench surface (PROJ-19, board #267): update_target
// moves a card by column, and a status the owner turned off is never set by
// an agent.

// HiddenStatusHints says what an agent does instead of a status the board
// has turned off (db.HideableStatuses); the brief's "Turned off" line and
// hiddenStatusRefusal share it.
var HiddenStatusHints = map[string]string{
	"in_review": "go straight to done once the review passes",
	"blocked":   "leave it in_progress; the open ask already shows the owner what waits",
}

// hiddenStatusRefusal is the refusal of status on a board that turned it
// off. Every agent-facing writer of a workbench target's status calls it for
// a hidden status (PROJ-19); the owner's writers (CLI, Desktop) and the
// system writers do not.
func hiddenStatusRefusal(status string) error {
	return &ValidationError{Msg: status + " is turned off on this board — " + HiddenStatusHints[status]}
}

// columnMove is a resolved update_target column: the status and column
// (nil = the status's first column) to write in one statement, and whether
// the target already sits there.
type columnMove struct {
	status   string
	columnID *int64
	same     bool
}

// resolveTargetColumn checks update_target's status and column against the
// board's column definition: a hidden status is refused, a column must name
// one of the board's columns, agree with status and be set on a leaf. It
// returns the move to write, or nil when no column is given.
func resolveTargetColumn(d *db.DB, t *db.Target, a updateTargetArgs) (*columnMove, error) {
	if a.Column == nil && a.Status == "" {
		return nil, nil
	}
	def, err := d.GetBoardColumns(t.WorkbenchID.Int64)
	if err != nil {
		return nil, fmt.Errorf("reading board columns: %w", err)
	}
	if a.Column == nil {
		if def.IsHidden(a.Status) {
			return nil, hiddenStatusRefusal(a.Status)
		}
		return nil, nil
	}
	stored, err := leafTargetColumn(d, t.ID)
	if err != nil {
		return nil, err
	}
	// column "" alone keeps the status and clears the column.
	mv := columnMove{status: t.Status}
	if a.Status != "" {
		mv.status = a.Status
	}
	name := strings.TrimSpace(*a.Column)
	if name != "" {
		status, id, err := resolveNamedColumn(def, name, a.Status)
		if err != nil {
			return nil, err
		}
		mv.status, mv.columnID = status, id
	}
	if (a.Status != "" || name != "") && def.IsHidden(mv.status) {
		return nil, hiddenStatusRefusal(mv.status)
	}
	mv.same = mv.status == t.Status && sameColumn(stored, mv.columnID)
	return &mv, nil
}

// leafTargetColumn reads targetID's stored column, refusing a target that
// has children: columns apply to leaf targets only.
func leafTargetColumn(d *db.DB, targetID int) (sql.NullInt64, error) {
	var stored sql.NullInt64
	var parent bool
	if err := d.QueryRow(`SELECT board_column_id, EXISTS (SELECT 1 FROM targets c WHERE c.parent_id = t.id)
		FROM targets t WHERE t.id = ?`, targetID).Scan(&stored, &parent); err != nil {
		return stored, fmt.Errorf("reading target %d column: %w", targetID, err)
	}
	if parent {
		return stored, &ValidationError{Msg: "columns apply to leaf targets"}
	}
	return stored, nil
}

// resolveNamedColumn resolves a non-empty column name on the board and
// checks it agrees with the requested status (empty = no status given).
func resolveNamedColumn(def db.BoardColumns, name, wantStatus string) (string, *int64, error) {
	status, id, ok := def.Resolve(name)
	if !ok {
		return "", nil, &ValidationError{Msg: fmt.Sprintf("no column %q on this board; its columns: %s", name,
			strings.Join(columnNames(def), ", "))}
	}
	if wantStatus != "" && wantStatus != status {
		return "", nil, &ValidationError{Msg: fmt.Sprintf("column %q is in %s, status says %s — send one of them",
			columnTitle(def, status, id), status, wantStatus)}
	}
	return status, id, nil
}

func sameColumn(stored sql.NullInt64, id *int64) bool {
	if id == nil {
		return !stored.Valid
	}
	return stored.Valid && stored.Int64 == *id
}

// columnNames lists every name a column resolves by, in board order: the
// defined titles, and the standard label of each status without columns
// that is not hidden.
func columnNames(def db.BoardColumns) []string {
	var names []string
	for _, s := range db.BoardStatusOrder {
		defined := false
		for _, c := range def.Columns {
			if c.Status == s {
				names, defined = append(names, c.Title), true
			}
		}
		if !defined && !def.IsHidden(s) {
			names = append(names, db.BoardStatusLabels[s])
		}
	}
	return names
}

// columnTitle is the title of a resolved column: its defined title, or the
// standard label of status for an implicit one.
func columnTitle(def db.BoardColumns, status string, id *int64) string {
	if id != nil {
		for _, c := range def.Columns {
			if c.ID == *id {
				return c.Title
			}
		}
	}
	return db.BoardStatusLabels[status]
}

// applyColumnMove writes a resolved column move (actor agent) unless the
// target already sits there.
func applyColumnMove(d *db.DB, tx *sql.Tx, t *db.Target, mv *columnMove) error {
	if mv.same {
		return nil
	}
	if err := d.SetTargetColumnTx(tx, int64(t.ID), mv.status, mv.columnID, db.ActorAgent); err != nil {
		return fmt.Errorf("moving target to its column: %w", err)
	}
	return nil
}

// targetBoardColumn is a workbench target's effective column title (the
// board's BoardNode.Column), "" when its board defines no columns.
func targetBoardColumn(d *db.DB, target *db.Target) (string, error) {
	def, err := d.GetBoardColumns(target.WorkbenchID.Int64)
	if err != nil {
		return "", fmt.Errorf("reading board columns: %w", err)
	}
	if len(def.Columns) == 0 {
		return "", nil
	}
	board, err := d.GetWorkbenchBoard(target.WorkbenchID.Int64)
	if err != nil {
		return "", fmt.Errorf("loading board: %w", err)
	}
	return findBoardColumn(board, target.ID), nil
}

func findBoardColumn(nodes []db.BoardNode, id int) string {
	for _, n := range nodes {
		if n.Target.ID == id {
			return n.Column
		}
		if c := findBoardColumn(n.Children, id); c != "" {
			return c
		}
	}
	return ""
}
