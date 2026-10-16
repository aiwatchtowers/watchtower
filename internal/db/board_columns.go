package db

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"unicode/utf8"
)

// Workbench board columns (migration 00125, PROJ-19, board #267): named
// columns inside the fixed status categories of one workbench. A status with
// no defined columns has one implicit column, its standard label. The
// triggers keep a target's column inside its workbench and current status.

// BoardColumn is one defined column of a workbench board.
type BoardColumn struct {
	ID          int64  `json:"id,omitempty"`
	Status      string `json:"status"`
	Title       string `json:"title"`
	Description string `json:"description"`
	Position    int    `json:"position"`
}

// BoardColumns is a workbench's column definition.
type BoardColumns struct {
	Columns []BoardColumn `json:"columns"` // ordered by status order, then position
	Hidden  []string      `json:"hidden"`  // subset of HideableStatuses, never nil
}

// BoardStatusOrder is the order of the column categories on the board.
var BoardStatusOrder = []string{"todo", "in_progress", "in_review", "blocked", "done", "dismissed"}

// BoardStatusLabels are the statuses' standard labels — the implicit column of
// a status without defined columns. Twin: the Desktop's WorkbenchBoardCard
// status labels (WatchtowerCore); change both together.
var BoardStatusLabels = map[string]string{
	"todo":        "To Do",
	"in_progress": "In Progress",
	"in_review":   "In Review",
	"blocked":     "Blocked",
	"done":        "Done",
	"dismissed":   "Dismissed",
}

// HideableStatuses are the only statuses a workbench may hide from its board;
// the others carry the rollup and target creation.
var HideableStatuses = []string{"in_review", "blocked"}

// Column definition limits (spec §3).
const (
	maxColumnsPerStatus    = 6
	maxColumnsPerWorkbench = 20
	maxColumnTitleLen      = 40
	maxColumnDescLen       = 500
)

// BoardColumnsError is a refused column definition; Msg is user-facing.
type BoardColumnsError struct{ Msg string }

func (e *BoardColumnsError) Error() string { return e.Msg }

func columnsErrorf(format string, args ...any) error {
	return &BoardColumnsError{Msg: fmt.Sprintf(format, args...)}
}

// IsEmpty reports a board with no defined columns and nothing hidden.
func (b BoardColumns) IsEmpty() bool { return len(b.Columns) == 0 && len(b.Hidden) == 0 }

// IsHidden reports whether status is hidden on the board.
func (b BoardColumns) IsHidden(status string) bool { return slices.Contains(b.Hidden, status) }

// Resolve finds the column name refers to — a column id, a column title, or
// the standard label of a status without defined columns (columnID nil) —
// ignoring case and surrounding space.
func (b BoardColumns) Resolve(name string) (status string, columnID *int64, ok bool) {
	name = strings.TrimSpace(name)
	if id, err := strconv.ParseInt(name, 10, 64); err == nil {
		for _, c := range b.Columns {
			if c.ID == id {
				return c.Status, &id, true
			}
		}
	}
	for _, c := range b.Columns {
		if strings.EqualFold(c.Title, name) {
			id := c.ID
			return c.Status, &id, true
		}
	}
	for _, s := range BoardStatusOrder {
		if strings.EqualFold(BoardStatusLabels[s], name) && !b.hasColumns(s) {
			return s, nil, true
		}
	}
	return "", nil, false
}

func (b BoardColumns) hasColumns(status string) bool {
	return slices.ContainsFunc(b.Columns, func(c BoardColumn) bool { return c.Status == status })
}

// firstColumnTitle is the title of status's first column: its first defined
// column, else its standard label.
func (b BoardColumns) firstColumnTitle(status string) string {
	for _, c := range b.Columns {
		if c.Status == status {
			return c.Title
		}
	}
	return BoardStatusLabels[status]
}

const boardStatusOrderSQL = `CASE status WHEN 'todo' THEN 0 WHEN 'in_progress' THEN 1 WHEN 'in_review' THEN 2
	WHEN 'blocked' THEN 3 WHEN 'done' THEN 4 ELSE 5 END`

// GetBoardColumns returns workbench projectID's column definition
// (ErrWorkbenchNotFound for an unknown workbench).
func (db *DB) GetBoardColumns(projectID int64) (BoardColumns, error) {
	return getBoardColumnsOn(db, projectID)
}

func getBoardColumnsOn(q interface {
	QueryRow(string, ...any) *sql.Row
	Query(string, ...any) (*sql.Rows, error)
}, projectID int64) (BoardColumns, error) {
	var hiddenJSON sql.NullString
	err := q.QueryRow(`SELECT board_hidden_statuses FROM projects WHERE id = ?`, projectID).Scan(&hiddenJSON)
	if errors.Is(err, sql.ErrNoRows) {
		return BoardColumns{}, fmt.Errorf("workbench %d: %w", projectID, ErrWorkbenchNotFound)
	}
	if err != nil {
		return BoardColumns{}, fmt.Errorf("reading workbench %d hidden statuses: %w", projectID, err)
	}
	out := BoardColumns{Columns: []BoardColumn{}, Hidden: []string{}}
	if hiddenJSON.Valid {
		var stored []string
		if err := json.Unmarshal([]byte(hiddenJSON.String), &stored); err != nil {
			return BoardColumns{}, fmt.Errorf("parsing workbench %d hidden statuses: %w", projectID, err)
		}
		out.Hidden = normalizeHidden(stored)
	}
	cols, err := readBoardColumnRows(q, projectID)
	if err != nil {
		return BoardColumns{}, err
	}
	out.Columns = cols
	return out, nil
}

// readBoardColumnRows reads workbench projectID's column rows in board order,
// without touching its hidden-status setting.
func readBoardColumnRows(q interface {
	Query(string, ...any) (*sql.Rows, error)
}, projectID int64) ([]BoardColumn, error) {
	rows, err := q.Query(`SELECT id, status, title, description, position FROM workbench_board_columns
		WHERE project_id = ? ORDER BY `+boardStatusOrderSQL+`, position, id`, projectID)
	if err != nil {
		return nil, fmt.Errorf("reading workbench %d board columns: %w", projectID, err)
	}
	defer rows.Close()
	out := []BoardColumn{}
	for rows.Next() {
		var c BoardColumn
		if err := rows.Scan(&c.ID, &c.Status, &c.Title, &c.Description, &c.Position); err != nil {
			return nil, fmt.Errorf("scanning board column: %w", err)
		}
		out = append(out, c)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading workbench %d board columns: %w", projectID, err)
	}
	return out, nil
}

// normalizeHidden keeps the hideable statuses of in, once each, in
// HideableStatuses order.
func normalizeHidden(in []string) []string {
	out := []string{}
	for _, s := range HideableStatuses {
		if slices.Contains(in, s) {
			out = append(out, s)
		}
	}
	return out
}

// ReplaceBoardColumns replaces workbench projectID's column definition in one
// write transaction: columns with an ID are updated (their status never
// changes), columns without are created, stored columns missing from in are
// deleted (their targets fall to the status's first column via ON DELETE SET
// NULL). Positions are rewritten 0..n per status in input order. Any limit
// violation refuses the whole input with a *BoardColumnsError and writes
// nothing. Returns the stored definition.
func (db *DB) ReplaceBoardColumns(projectID int64, in BoardColumns) (BoardColumns, error) {
	cols, hidden, err := validateBoardColumns(in)
	if err != nil {
		return BoardColumns{}, err
	}
	hiddenJSON := sql.NullString{}
	if len(hidden) > 0 {
		b, err := json.Marshal(hidden)
		if err != nil {
			return BoardColumns{}, fmt.Errorf("encoding hidden statuses: %w", err)
		}
		hiddenJSON = sql.NullString{String: string(b), Valid: true}
	}
	var out BoardColumns
	err = db.WithTx(func(tx *sql.Tx) error {
		stored, err := getBoardColumnsOn(tx, projectID)
		if err != nil {
			return err
		}
		if err := writeBoardColumns(tx, projectID, stored.Columns, cols); err != nil {
			return err
		}
		if _, err := tx.Exec(`UPDATE projects SET board_hidden_statuses = ? WHERE id = ?`, hiddenJSON, projectID); err != nil {
			return fmt.Errorf("writing workbench %d hidden statuses: %w", projectID, err)
		}
		out, err = getBoardColumnsOn(tx, projectID)
		return err
	})
	if err != nil {
		return BoardColumns{}, err
	}
	return out, nil
}

// validateBoardColumns checks in against the spec §3 limits and returns the
// trimmed columns with their positions and the normalized hidden list.
func validateBoardColumns(in BoardColumns) ([]BoardColumn, []string, error) {
	for _, s := range in.Hidden {
		if !slices.Contains(HideableStatuses, s) {
			return nil, nil, columnsErrorf("status %q cannot be hidden (only %s)", s, strings.Join(HideableStatuses, " and "))
		}
	}
	if len(in.Columns) > maxColumnsPerWorkbench {
		return nil, nil, columnsErrorf("at most %d columns per workbench (got %d)", maxColumnsPerWorkbench, len(in.Columns))
	}
	cols := make([]BoardColumn, 0, len(in.Columns))
	perStatus := map[string]int{}
	seen := map[string]bool{}
	for _, c := range in.Columns {
		c.Title = strings.TrimSpace(c.Title)
		c.Description = strings.TrimSpace(c.Description)
		if err := checkColumnFields(c); err != nil {
			return nil, nil, err
		}
		key := strings.ToLower(c.Title)
		if seen[key] {
			return nil, nil, columnsErrorf("column %q: title is used twice", c.Title)
		}
		seen[key] = true
		if err := checkColumnTitleNotOtherLabel(c); err != nil {
			return nil, nil, err
		}
		c.Position = perStatus[c.Status]
		perStatus[c.Status]++
		if perStatus[c.Status] > maxColumnsPerStatus {
			return nil, nil, columnsErrorf("status %s: at most %d columns", c.Status, maxColumnsPerStatus)
		}
		cols = append(cols, c)
	}
	hidden := normalizeHidden(in.Hidden)
	for _, s := range hidden {
		if perStatus[s] > 0 {
			return nil, nil, columnsErrorf("%q: hide it or give it columns, not both", s)
		}
	}
	return cols, hidden, nil
}

// checkColumnFields checks one trimmed column's status, title and
// description against the spec §3 limits.
func checkColumnFields(c BoardColumn) error {
	if _, known := BoardStatusLabels[c.Status]; !known {
		return columnsErrorf("column %q: unknown status %q", c.Title, c.Status)
	}
	if c.Title == "" {
		return columnsErrorf("a %s column has an empty title", c.Status)
	}
	if utf8.RuneCountInString(c.Title) > maxColumnTitleLen {
		return columnsErrorf("column %q: title is longer than %d characters", c.Title, maxColumnTitleLen)
	}
	if strings.Trim(c.Title, "0123456789") == "" {
		return columnsErrorf("column %q: a title cannot be only digits", c.Title)
	}
	if utf8.RuneCountInString(c.Description) > maxColumnDescLen {
		return columnsErrorf("column %q: description is longer than %d characters", c.Title, maxColumnDescLen)
	}
	return nil
}

// checkColumnTitleNotOtherLabel refuses a title equal to another status's
// standard label.
func checkColumnTitleNotOtherLabel(c BoardColumn) error {
	for s, label := range BoardStatusLabels {
		if s != c.Status && strings.EqualFold(label, c.Title) {
			return columnsErrorf("column %q: title is the label of another status (%s)", c.Title, s)
		}
	}
	return nil
}

// writeBoardColumns applies cols over the stored columns of projectID inside
// tx: deletes the missing ones, updates by id, inserts the new ones.
func writeBoardColumns(tx *sql.Tx, projectID int64, stored, cols []BoardColumn) error {
	storedStatus := make(map[int64]string, len(stored))
	for _, c := range stored {
		storedStatus[c.ID] = c.Status
	}
	keep := map[int64]bool{}
	for _, c := range cols {
		if c.ID == 0 {
			continue
		}
		s, ok := storedStatus[c.ID]
		if !ok {
			return columnsErrorf("column %q: id %d is not a column of this workbench", c.Title, c.ID)
		}
		if keep[c.ID] {
			return columnsErrorf("column %q: id %d is given twice", c.Title, c.ID)
		}
		if s != c.Status {
			return columnsErrorf("column %q: status cannot change (delete it and add a new one)", c.Title)
		}
		keep[c.ID] = true
	}
	for _, c := range stored {
		if keep[c.ID] {
			continue
		}
		if _, err := tx.Exec(`DELETE FROM workbench_board_columns WHERE id = ?`, c.ID); err != nil {
			return fmt.Errorf("deleting board column %d: %w", c.ID, err)
		}
	}
	for _, c := range cols {
		if c.ID != 0 {
			if _, err := tx.Exec(`UPDATE workbench_board_columns SET title = ?, description = ?, position = ? WHERE id = ?`,
				c.Title, c.Description, c.Position, c.ID); err != nil {
				return fmt.Errorf("updating board column %d: %w", c.ID, err)
			}
			continue
		}
		if _, err := tx.Exec(`INSERT INTO workbench_board_columns (project_id, status, title, description, position, created_at)
			VALUES (?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ','now'))`,
			projectID, c.Status, c.Title, c.Description, c.Position); err != nil {
			return fmt.Errorf("creating board column %q: %w", c.Title, err)
		}
	}
	return nil
}

// SetTargetColumnTx moves target targetID to status and column columnID (nil
// = the status's first column) inside tx. A status change is one UPDATE of
// status, board_column_id and status_actor, so the PROJ-19 check sees the new
// pair; it is recorded with actor (PROJ-06) and gets the same follow-ups as
// UpdateTargetStatusAsTx. With the status unchanged only board_column_id is
// written: the leaf keeps its progress and no history row is added. A column
// that is not of the target's workbench and status is refused by the trigger.
func (db *DB) SetTargetColumnTx(tx *sql.Tx, targetID int64, status string, columnID *int64, actor string) error {
	col := sql.NullInt64{}
	if columnID != nil {
		col = sql.NullInt64{Int64: *columnID, Valid: true}
	}
	var current string
	if err := tx.QueryRow(`SELECT status FROM targets WHERE id = ?`, targetID).Scan(&current); err != nil {
		return fmt.Errorf("reading target %d status: %w", targetID, err)
	}
	if current != status {
		return setTargetStatusOn(tx, int(targetID), status, actor, &col)
	}
	if _, err := tx.Exec(`UPDATE targets SET board_column_id = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id = ?`, col, targetID); err != nil {
		return fmt.Errorf("moving target %d to its column: %w", targetID, err)
	}
	return nil
}

// boardLeafColumns maps each leaf target of workbench workbenchID to its
// effective column title, or returns nil when the workbench defines no
// columns. A parent's stored column is ignored (spec §3).
func (db *DB) boardLeafColumns(workbenchID int64, targets []Target) (map[int64]string, error) {
	cols, err := readBoardColumnRows(db, workbenchID)
	if err != nil {
		return nil, err
	}
	def := BoardColumns{Columns: cols}
	if len(def.Columns) == 0 {
		return nil, nil
	}
	rows, err := db.Query(`SELECT t.id, c.title FROM targets t JOIN workbench_board_columns c ON c.id = t.board_column_id
		WHERE t.project_id = ?`, workbenchID)
	if err != nil {
		return nil, fmt.Errorf("reading board target columns: %w", err)
	}
	defer rows.Close()
	stored := map[int64]string{}
	for rows.Next() {
		var id int64
		var title string
		if err := rows.Scan(&id, &title); err != nil {
			return nil, fmt.Errorf("scanning board target column: %w", err)
		}
		stored[id] = title
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading board target columns: %w", err)
	}
	parents := map[int64]bool{}
	for _, t := range targets {
		if t.ParentID.Valid {
			parents[t.ParentID.Int64] = true
		}
	}
	out := make(map[int64]string, len(targets))
	for _, t := range targets {
		id := int64(t.ID)
		if parents[id] {
			continue
		}
		if title, ok := stored[id]; ok {
			out[id] = title
			continue
		}
		out[id] = def.firstColumnTitle(t.Status)
	}
	return out, nil
}
