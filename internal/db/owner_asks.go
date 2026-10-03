package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"

	"watchtower/internal/asks"
)

// OwnerAsk is the agent's ask of the owner on a workbench: a document review,
// a check or questions (spec 2026-10-03-workbench-owner-asks Part 2). Go
// writes open, withdrawn and delivered; the Desktop writes only
// open -> answered, with Answer and AnsweredAt.
type OwnerAsk struct {
	ID              int64
	WorkbenchID     int64
	SessionID       sql.NullInt64 // terminal_sessions row; NULL = an external terminal or a gone session
	TargetID        sql.NullInt64
	Kind            string // review | check | question
	Title           string
	Summary         string
	Changes         string // review re-round: what changed
	Payload         string // JSON: focus, questions, checklist
	DocPath         string // review only
	DocSnapshot     string // review only; left empty by the list readers
	PreviousAskID   sql.NullInt64
	Status          string // open | answered | delivered | withdrawn
	WithdrawnReason string // agent | superseded, on withdrawn only
	Answer          string // JSON, Desktop-written
	CreatedAt       string
	AnsweredAt      string
	DeliveredAt     string
}

// OwnerAskFilter selects the asks of one workbench.
type OwnerAskFilter struct {
	// Statuses keeps these statuses; empty = answered and open (list_asks' default).
	Statuses []string
	// SessionID keeps one session's asks; 0 = any.
	SessionID int64
	// Limit caps the rows; 0 = no cap.
	Limit int
}

// Withdrawn reasons (owner_asks.withdrawn_reason).
const (
	WithdrawnByAgent    = "agent"
	WithdrawnSuperseded = "superseded"
)

var (
	ErrAskNotFound = errors.New("ask not found")
	ErrAskNotOpen  = errors.New("not open")
	// ErrTooManyOpenAsks refuses an ask past the per-workbench cap; its text
	// is the agent-facing message.
	ErrTooManyOpenAsks = fmt.Errorf("too many open asks (%d) — withdraw or wait for answers", asks.MaxOpenPerWorkbench)
)

const (
	ownerAskHead = `a.id, a.project_id, a.session_id, a.target_id, a.kind, a.title, a.summary, a.changes,
	a.payload, a.doc_path, `
	ownerAskTail = `, a.previous_ask_id, a.status, a.withdrawn_reason, a.answer, a.created_at,
	a.answered_at, a.delivered_at`
	ownerAskCols = ownerAskHead + `a.doc_snapshot` + ownerAskTail
	// ownerAskListCols leaves doc_snapshot out: it holds up to 2 MiB a row.
	ownerAskListCols = ownerAskHead + `''` + ownerAskTail
)

// answeredForSessionPredicate (over alias a, s = the LEFT JOINed session):
// the ask's session is the given one, none, or a row that is gone.
const answeredForSessionPredicate = `(a.session_id = ? OR a.session_id IS NULL OR s.id IS NULL)`

func scanOwnerAsk(row interface{ Scan(...any) error }) (*OwnerAsk, error) {
	var a OwnerAsk
	if err := row.Scan(&a.ID, &a.WorkbenchID, &a.SessionID, &a.TargetID, &a.Kind, &a.Title, &a.Summary, &a.Changes,
		&a.Payload, &a.DocPath, &a.DocSnapshot, &a.PreviousAskID, &a.Status, &a.WithdrawnReason, &a.Answer,
		&a.CreatedAt, &a.AnsweredAt, &a.DeliveredAt); err != nil {
		return nil, err
	}
	return &a, nil
}

// InsertOwnerAsk files a as a new open ask of a.WorkbenchID inside the
// caller's transaction (status and answer fields are ignored). A previous ask
// that is still open is withdrawn as superseded in the same transaction, and
// its id comes back as superseded (0 when there was nothing to supersede). An
// ask past asks.MaxOpenPerWorkbench open asks fails with ErrTooManyOpenAsks;
// the caller's rollback then undoes the supersede too. The target, the
// session and the previous ask (of the same kind) must belong to the
// workbench.
func (db *DB) InsertOwnerAsk(tx *sql.Tx, a OwnerAsk) (id, superseded int64, err error) {
	if a.TargetID.Valid {
		if err := checkTargetInWorkbench(tx, a.WorkbenchID, a.TargetID.Int64); err != nil {
			return 0, 0, err
		}
	}
	if a.SessionID.Valid {
		if err := checkOwnedBy(tx, `SELECT project_id FROM terminal_sessions WHERE id = ?`,
			"terminal session", a.WorkbenchID, a.SessionID.Int64); err != nil {
			return 0, 0, err
		}
	}
	if a.PreviousAskID.Valid {
		if superseded, err = supersedeOwnerAsk(tx, a); err != nil {
			return 0, 0, err
		}
	}
	open, err := countOpenOwnerAsks(tx, a.WorkbenchID)
	if err != nil {
		return 0, 0, err
	}
	if open >= asks.MaxOpenPerWorkbench {
		return 0, 0, ErrTooManyOpenAsks
	}
	if a.Payload == "" {
		a.Payload = "{}"
	}
	res, err := tx.Exec(`INSERT INTO owner_asks
		(project_id, session_id, target_id, kind, title, summary, changes, payload, doc_path, doc_snapshot, previous_ask_id)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		a.WorkbenchID, a.SessionID, a.TargetID, a.Kind, a.Title, a.Summary, a.Changes, a.Payload,
		a.DocPath, a.DocSnapshot, a.PreviousAskID)
	if err != nil {
		return 0, 0, fmt.Errorf("inserting ask: %w", err)
	}
	id, err = res.LastInsertId()
	if err != nil {
		return 0, 0, err
	}
	return id, superseded, nil
}

// CountOpenOwnerAsks returns how many asks of workbench projectID are open —
// for a refusal before anything is recorded; InsertOwnerAsk enforces the cap.
func (db *DB) CountOpenOwnerAsks(projectID int64) (int, error) {
	return countOpenOwnerAsks(db, projectID)
}

func countOpenOwnerAsks(q targetsQuerier, projectID int64) (int, error) {
	var open int
	if err := q.QueryRow(`SELECT COUNT(*) FROM owner_asks WHERE project_id = ? AND status = 'open'`,
		projectID).Scan(&open); err != nil {
		return 0, fmt.Errorf("counting open asks: %w", err)
	}
	return open, nil
}

// supersedeOwnerAsk withdraws a.PreviousAskID as superseded when it is still
// open and returns its id; an ask in any other status is left alone (0).
func supersedeOwnerAsk(tx *sql.Tx, a OwnerAsk) (int64, error) {
	prev, err := getOwnerAsk(tx, ownerAskListCols, a.WorkbenchID, a.PreviousAskID.Int64)
	if err != nil {
		return 0, err
	}
	if prev.Kind != a.Kind {
		return 0, fmt.Errorf("previous_ask_id: ask %d is a %s ask, not a %s ask", prev.ID, prev.Kind, a.Kind)
	}
	if prev.Status != "open" {
		return 0, nil
	}
	if _, err := tx.Exec(`UPDATE owner_asks SET status = 'withdrawn', withdrawn_reason = ?
		WHERE id = ? AND status = 'open'`, WithdrawnSuperseded, prev.ID); err != nil {
		return 0, fmt.Errorf("superseding ask %d: %w", prev.ID, err)
	}
	return prev.ID, nil
}

// GetOwnerAsk returns ask id of workbench projectID, snapshot included;
// another workbench's ask is ErrAskNotFound.
func (db *DB) GetOwnerAsk(projectID, id int64) (*OwnerAsk, error) {
	return getOwnerAsk(db, ownerAskCols, projectID, id)
}

func getOwnerAsk(q targetsQuerier, cols string, projectID, id int64) (*OwnerAsk, error) {
	a, err := scanOwnerAsk(q.QueryRow(`SELECT `+cols+` FROM owner_asks a WHERE a.id = ? AND a.project_id = ?`, id, projectID))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("ask %d: %w", id, ErrAskNotFound)
	}
	if err != nil {
		return nil, fmt.Errorf("loading ask %d: %w", id, err)
	}
	return a, nil
}

// ListOwnerAsks returns workbench projectID's asks matching f, answered first,
// then open, then the rest, newest first within each; DocSnapshot is left empty.
func (db *DB) ListOwnerAsks(projectID int64, f OwnerAskFilter) ([]OwnerAsk, error) {
	statuses := f.Statuses
	if len(statuses) == 0 {
		statuses = []string{"answered", "open"}
	}
	q := `SELECT ` + ownerAskListCols + ` FROM owner_asks a WHERE a.project_id = ?
		AND a.status IN (?` + strings.Repeat(", ?", len(statuses)-1) + `)`
	args := []any{projectID}
	for _, s := range statuses {
		args = append(args, s)
	}
	if f.SessionID != 0 {
		q += ` AND a.session_id = ?`
		args = append(args, f.SessionID)
	}
	q += ` ORDER BY CASE a.status WHEN 'answered' THEN 0 WHEN 'open' THEN 1 ELSE 2 END, a.id DESC`
	if f.Limit > 0 {
		q += ` LIMIT ?`
		args = append(args, f.Limit)
	}
	return db.queryOwnerAsks(q, args...)
}

func (db *DB) queryOwnerAsks(q string, args ...any) ([]OwnerAsk, error) {
	rows, err := db.Query(q, args...)
	if err != nil {
		return nil, fmt.Errorf("listing asks: %w", err)
	}
	defer rows.Close()
	var out []OwnerAsk
	for rows.Next() {
		a, err := scanOwnerAsk(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning ask: %w", err)
		}
		out = append(out, *a)
	}
	return out, rows.Err()
}

// WithdrawOwnerAsk withdraws open ask id of workbench projectID for reason
// (WithdrawnByAgent or WithdrawnSuperseded). An ask in any other status fails
// with ErrAskNotOpen ("ask N is <status>"), another workbench's with
// ErrAskNotFound.
func (db *DB) WithdrawOwnerAsk(projectID, id int64, reason string) error {
	if reason != WithdrawnByAgent && reason != WithdrawnSuperseded {
		return fmt.Errorf("invalid withdrawn reason %q", reason)
	}
	return db.WithTx(func(tx *sql.Tx) error {
		res, err := tx.Exec(`UPDATE owner_asks SET status = 'withdrawn', withdrawn_reason = ?
			WHERE id = ? AND project_id = ? AND status = 'open'`, reason, id, projectID)
		if err != nil {
			return fmt.Errorf("withdrawing ask %d: %w", id, err)
		}
		n, err := res.RowsAffected()
		if err != nil {
			return err
		}
		if n == 1 {
			return nil
		}
		a, err := getOwnerAsk(tx, ownerAskListCols, projectID, id)
		if err != nil {
			return err
		}
		return fmt.Errorf("ask %d is %s: %w", id, a.Status, ErrAskNotOpen)
	})
}

// MarkOwnerAskDelivered moves answered ask id of workbench projectID to
// delivered (get_ask has read the answer) and reports whether it did; an ask
// in any other status, or of another workbench, is left alone (false).
func (db *DB) MarkOwnerAskDelivered(projectID, id int64) (bool, error) {
	res, err := db.Exec(`UPDATE owner_asks SET status = 'delivered',
		delivered_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id = ? AND project_id = ? AND status = 'answered'`, id, projectID)
	if err != nil {
		return false, fmt.Errorf("delivering ask %d: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, err
	}
	return n == 1, nil
}

// AnsweredAsksForBrief returns workbench projectID's answered asks for the
// brief of session sessionID (0 = no session): those of that session, of no
// session or of a session row that is gone, oldest answer first; others counts
// the answered asks of the workbench's other sessions. DocSnapshot is left empty.
func (db *DB) AnsweredAsksForBrief(projectID, sessionID int64) (list []OwnerAsk, others int, err error) {
	const from = ` FROM owner_asks a LEFT JOIN terminal_sessions s ON s.id = a.session_id
		WHERE a.project_id = ? AND a.status = 'answered' AND `
	list, err = db.queryOwnerAsks(`SELECT `+ownerAskListCols+from+answeredForSessionPredicate+
		` ORDER BY a.answered_at, a.id`, projectID, sessionID)
	if err != nil {
		return nil, 0, err
	}
	if err := db.QueryRow(`SELECT COUNT(*)`+from+`NOT `+answeredForSessionPredicate,
		projectID, sessionID).Scan(&others); err != nil {
		return nil, 0, fmt.Errorf("counting other sessions' answered asks: %w", err)
	}
	return list, others, nil
}
