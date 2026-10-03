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

// SessionLinkedTargets is the ids of the targets session sessionID's agent
// wrote to, in id order.
func (db *DB) SessionLinkedTargets(sessionID int64) ([]int64, error) {
	rows, err := db.Query(`SELECT target_id FROM terminal_session_targets WHERE session_id = ? ORDER BY target_id`,
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

// PRStates is workbench projectID's cached PR states by ref.
func (db *DB) PRStates(projectID int64) (map[string]PRState, error) {
	rows, err := db.Query(`SELECT project_id, ref, state, pr_number, title, additions, deletions, merged_at, checked_at
		FROM workbench_pr_states WHERE project_id = ?`, projectID)
	if err != nil {
		return nil, fmt.Errorf("reading PR states of workbench %d: %w", projectID, err)
	}
	defer rows.Close()
	out := map[string]PRState{}
	for rows.Next() {
		var s PRState
		if err := rows.Scan(&s.WorkbenchID, &s.Ref, &s.State, &s.PRNumber, &s.Title, &s.Additions, &s.Deletions,
			&s.MergedAt, &s.CheckedAt); err != nil {
			return nil, fmt.Errorf("reading PR states of workbench %d: %w", projectID, err)
		}
		out[s.Ref] = s
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading PR states of workbench %d: %w", projectID, err)
	}
	return out, nil
}
