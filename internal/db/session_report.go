package db

import (
	"database/sql"
	"fmt"
	"time"
)

// PRState is a workbench_pr_states row: the cached state of a PR or branch a
// session report names. Go is its only reader and writer.
type PRState struct {
	WorkbenchID int64
	Ref         string        // pr:<number> | branch:<name>
	State       string        // merged | open | closed | none | unknown
	PRNumber    sql.NullInt64 // set for a pr ref, and for a branch whose PR gh found
	Title       string
	Additions   sql.NullInt64
	Deletions   sql.NullInt64
	MergedAt    string
	CheckedAt   string
}

// LinkSessionTarget records that terminal session sessionID's agent wrote to
// target targetID: first_at is set on the first link and kept, last_at moves
// to now on every link.
func (db *DB) LinkSessionTarget(sessionID, targetID int64) error {
	now := time.Now().UTC().Format(time.RFC3339)
	_, err := db.Exec(`INSERT INTO terminal_session_targets (session_id, target_id, first_at, last_at)
		VALUES (?, ?, ?, ?)
		ON CONFLICT (session_id, target_id) DO UPDATE SET last_at = excluded.last_at`,
		sessionID, targetID, now, now)
	if err != nil {
		return fmt.Errorf("linking terminal session %d to target %d: %w", sessionID, targetID, err)
	}
	return nil
}

// LinkSessionTargetStatus is LinkSessionTarget for a status write: last_at and
// status_at both move to now, first_at is kept.
func (db *DB) LinkSessionTargetStatus(sessionID, targetID int64) error {
	now := time.Now().UTC().Format(time.RFC3339)
	return upsertStatusLink(db, sessionID, targetID, now)
}

type execer interface {
	Exec(string, ...any) (sql.Result, error)
}

func upsertStatusLink(q execer, sessionID, targetID int64, now string) error {
	_, err := q.Exec(`INSERT INTO terminal_session_targets (session_id, target_id, first_at, last_at, status_at)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT (session_id, target_id) DO UPDATE SET last_at = excluded.last_at, status_at = excluded.status_at`,
		sessionID, targetID, now, now, now)
	if err != nil {
		return fmt.Errorf("linking terminal session %d to target %d: %w", sessionID, targetID, err)
	}
	return nil
}

// LeafStamp is the latest status stamp of a target: the session that wrote
// it and when (RFC 3339 UTC).
type LeafStamp struct {
	SessionID int64
	At        string
}

// SessionLeafOwners maps target id to the latest link status stamp among the
// claude/codex sessions of workbench workbenchID: the latest status_at, a tie
// going to the higher session id. A link with NULL status_at owns nothing.
// Binding stamps (SessionBindings) are folded in by the session report.
func (db *DB) SessionLeafOwners(workbenchID int64) (map[int64]LeafStamp, error) {
	rows, err := db.Query(`SELECT target_id, session_id, status_at FROM (
			SELECT l.target_id, l.session_id, l.status_at,
				ROW_NUMBER() OVER (PARTITION BY l.target_id ORDER BY l.status_at DESC, l.session_id DESC) AS rn
			FROM terminal_session_targets l
			JOIN terminal_sessions s ON s.id = l.session_id
			WHERE s.project_id = ? AND s.kind IN ('claude', 'codex') AND l.status_at IS NOT NULL
		) WHERE rn = 1`, workbenchID)
	if err != nil {
		return nil, fmt.Errorf("reading leaf owners of workbench %d: %w", workbenchID, err)
	}
	defer rows.Close()
	out := map[int64]LeafStamp{}
	for rows.Next() {
		var target int64
		var st LeafStamp
		if err := rows.Scan(&target, &st.SessionID, &st.At); err != nil {
			return nil, fmt.Errorf("reading leaf owners of workbench %d: %w", workbenchID, err)
		}
		out[target] = st
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading leaf owners of workbench %d: %w", workbenchID, err)
	}
	return out, nil
}

// SessionBinding is a claude/codex session's bound target and its binding
// stamp: target_bound_at when Go re-bound it after launch, else created_at
// (the launch target counts as a binding at launch).
type SessionBinding struct {
	SessionID int64
	TargetID  int64
	At        string
}

// SessionBindings is the binding of every claude/codex session of workbench
// workbenchID that has a target, in session id order.
func (db *DB) SessionBindings(workbenchID int64) ([]SessionBinding, error) {
	rows, err := db.Query(`SELECT id, target_id, COALESCE(target_bound_at, created_at) FROM terminal_sessions
		WHERE project_id = ? AND kind IN ('claude', 'codex') AND target_id IS NOT NULL ORDER BY id`, workbenchID)
	if err != nil {
		return nil, fmt.Errorf("reading session bindings of workbench %d: %w", workbenchID, err)
	}
	defer rows.Close()
	var out []SessionBinding
	for rows.Next() {
		var b SessionBinding
		if err := rows.Scan(&b.SessionID, &b.TargetID, &b.At); err != nil {
			return nil, fmt.Errorf("reading session bindings of workbench %d: %w", workbenchID, err)
		}
		out = append(out, b)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading session bindings of workbench %d: %w", workbenchID, err)
	}
	return out, nil
}

// SetSessionTarget binds session sessionID to targetID (invalid = clear; links
// stay) in one transaction: target_id plus target_bound_at = now (NULL when
// cleared) and, for a valid target, one status-stamped link of the target
// itself. It writes no link row per leaf: the binding stamp on the session is
// what takes the subtree's leaves for the progress count.
func (db *DB) SetSessionTarget(sessionID int64, targetID sql.NullInt64) error {
	now := time.Now().UTC().Format(time.RFC3339)
	boundAt := sql.NullString{String: now, Valid: targetID.Valid}
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("binding terminal session %d: %w", sessionID, err)
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.Exec(`UPDATE terminal_sessions SET target_id = ?, target_bound_at = ? WHERE id = ?`,
		targetID, boundAt, sessionID); err != nil {
		return fmt.Errorf("binding terminal session %d: %w", sessionID, err)
	}
	if targetID.Valid {
		if err := upsertStatusLink(tx, sessionID, targetID.Int64, now); err != nil {
			return err
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("binding terminal session %d: %w", sessionID, err)
	}
	return nil
}

// SessionLinkedTargets is the ids of the targets session sessionID's agent
// wrote to, in id order.
func (db *DB) SessionLinkedTargets(sessionID int64) ([]int64, error) {
	return sessionLinkedTargets(db, sessionID)
}

// SessionLinkedTargetsTx is SessionLinkedTargets inside the caller's
// transaction.
func (db *DB) SessionLinkedTargetsTx(tx *sql.Tx, sessionID int64) ([]int64, error) {
	return sessionLinkedTargets(tx, sessionID)
}

func sessionLinkedTargets(q interface {
	Query(string, ...any) (*sql.Rows, error)
}, sessionID int64) ([]int64, error) {
	rows, err := q.Query(`SELECT target_id FROM terminal_session_targets WHERE session_id = ? ORDER BY target_id`,
		sessionID)
	if err != nil {
		return nil, fmt.Errorf("reading terminal session %d targets: %w", sessionID, err)
	}
	defer rows.Close()
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("reading terminal session %d targets: %w", sessionID, err)
		}
		ids = append(ids, id)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading terminal session %d targets: %w", sessionID, err)
	}
	return ids, nil
}

// FinishTerminalSession marks session sessionID finished with summary, at
// time at (finish_session). A repeat call overwrites both, so the newest summary
// wins; only a `working` state write clears finished_at again.
func (db *DB) FinishTerminalSession(sessionID int64, summary string, at time.Time) error {
	res, err := db.Exec(`UPDATE terminal_sessions SET finished_at = ?, finish_summary = ? WHERE id = ?`,
		at.UTC().Format(agentStateAtLayout), summary, sessionID)
	if err != nil {
		return fmt.Errorf("finishing terminal session %d: %w", sessionID, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("finishing terminal session %d: %w", sessionID, err)
	}
	if n == 0 {
		return ErrTerminalSessionNotFound
	}
	return nil
}

// UpsertPRState stores s, replacing the cached row of the same workbench and
// ref.
func (db *DB) UpsertPRState(s PRState) error {
	_, err := db.Exec(`INSERT INTO workbench_pr_states
		(project_id, ref, state, pr_number, title, additions, deletions, merged_at, checked_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT (project_id, ref) DO UPDATE SET state = excluded.state, pr_number = excluded.pr_number,
			title = excluded.title, additions = excluded.additions, deletions = excluded.deletions,
			merged_at = excluded.merged_at, checked_at = excluded.checked_at`,
		s.WorkbenchID, s.Ref, s.State, s.PRNumber, s.Title, s.Additions, s.Deletions, s.MergedAt, s.CheckedAt)
	if err != nil {
		return fmt.Errorf("storing PR state %q of workbench %d: %w", s.Ref, s.WorkbenchID, err)
	}
	return nil
}

// PRStates is workbench workbenchID's cached PR states by ref.
func (db *DB) PRStates(workbenchID int64) (map[string]PRState, error) {
	rows, err := db.Query(`SELECT project_id, ref, state, pr_number, title, additions, deletions, merged_at, checked_at
		FROM workbench_pr_states WHERE project_id = ?`, workbenchID)
	if err != nil {
		return nil, fmt.Errorf("reading PR states of workbench %d: %w", workbenchID, err)
	}
	defer rows.Close()
	out := map[string]PRState{}
	for rows.Next() {
		var s PRState
		if err := rows.Scan(&s.WorkbenchID, &s.Ref, &s.State, &s.PRNumber, &s.Title, &s.Additions, &s.Deletions,
			&s.MergedAt, &s.CheckedAt); err != nil {
			return nil, fmt.Errorf("reading PR states of workbench %d: %w", workbenchID, err)
		}
		out[s.Ref] = s
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading PR states of workbench %d: %w", workbenchID, err)
	}
	return out, nil
}
