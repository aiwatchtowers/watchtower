package db

import (
	"database/sql"
	"errors"
	"fmt"
	"sort"
	"strings"
)

// The owner's target status writers (the tower's targets.* commands; plan
// Task 9). Each claims status_actor = 'owner' in the statement that writes
// the status, so the targets_status_history triggers record the owner
// (PROJ-06) and the migration-00085 rollup records its parents as system
// (PROJ-05); application code writes no history row. Each reads the
// ancestors' statuses before and after its write in the caller's
// transaction and returns the ones the rollup moved, sorted (Swift
// WorkbenchQueries.rolledUpAncestors): the Desktop reports them with the
// target as the owner's own writes, which never notify.

// ErrColumnMismatch is the PROJ-19 trigger's refusal of a board column of
// another workbench or status.
var ErrColumnMismatch = errors.New("board column does not match the target")

// SetTargetStatusOwnerTx is the owner's status write on target id
// (WorkbenchQueries.updateTargetStatus over TargetQueries.updateStatus):
// status claimed as the owner, the leaf's progress and its parents',
// and INBOX-02's target_due cascade when it closes.
func SetTargetStatusOwnerTx(tx *sql.Tx, id int64, status string) (rolledUp []int64, err error) {
	return rolledUpAncestors(tx, id, func() error {
		if err := requireTarget(tx, id); err != nil {
			return err
		}
		return updateTargetStatusOn(tx, int(id), status, ActorOwner)
	})
}

// SetTargetColumnOwnerTx is the owner's card move to board column columnID
// of status (nil = the status's first column; WorkbenchQueries.
// updateTargetColumn over TargetQueries.updateStatus(_:id:status:
// boardColumnID:), PROJ-19): status and column in one statement; with the
// status unchanged only the column, so no history row and the progress
// kept. A column that does not match is ErrColumnMismatch.
func SetTargetColumnOwnerTx(tx *sql.Tx, id int64, status string, columnID *int64) (rolledUp []int64, err error) {
	return rolledUpAncestors(tx, id, func() error {
		if err := requireTarget(tx, id); err != nil {
			return err
		}
		err := setTargetColumnTx(tx, id, status, columnID, ActorOwner)
		if err != nil && strings.Contains(err.Error(), ErrColumnMismatch.Error()) {
			return fmt.Errorf("target %d: %w", id, ErrColumnMismatch)
		}
		return err
	})
}

// SnoozeTargetOwnerTx is the owner's snooze of target id to until (a
// date "2006-01-02" from the Targets tab, or a UTC minute
// "2006-01-02T15:04" from Home's Hide; TargetQueries.snooze): status
// snoozed claimed as the owner, then the leaf's progress and its parents'.
func SnoozeTargetOwnerTx(tx *sql.Tx, id int64, until string) (rolledUp []int64, err error) {
	return rolledUpAncestors(tx, id, func() error {
		res, err := tx.Exec(`UPDATE targets SET status = 'snoozed', snooze_until = ?, status_actor = 'owner',
			updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = ?`, until, id)
		if err != nil {
			return fmt.Errorf("snoozing target %d: %w", id, err)
		}
		if err := requireRow(res, "target", id); err != nil {
			return err
		}
		if err := fault("target.snooze"); err != nil {
			return err
		}
		if _, err := tx.Exec(`UPDATE targets SET progress = ? WHERE id = ? AND
			NOT EXISTS (SELECT 1 FROM targets c WHERE c.parent_id = targets.id AND c.status != 'dismissed')`,
			statusToProgress("snoozed"), id); err != nil {
			return fmt.Errorf("snoozing target %d: %w", id, err)
		}
		var parentID sql.NullInt64
		if err := tx.QueryRow(`SELECT parent_id FROM targets WHERE id = ?`, id).Scan(&parentID); err != nil {
			return fmt.Errorf("reading target %d parent: %w", id, err)
		}
		if parentID.Valid {
			return recomputeParentProgressOn(tx, parentID.Int64)
		}
		return nil
	})
}

// MarkInProgressOnWorkOnTx is Work on It's status write
// (WorkbenchQueries.markInProgressOnWorkOn): a workbench task still todo
// with no sub-targets on its own workbench moves to in_progress as the
// owner's write. Anything else — another status, a group, a personal
// target, a missing row — writes nothing (moved false).
func MarkInProgressOnWorkOnTx(tx *sql.Tx, id int64) (moved bool, rolledUp []int64, err error) {
	var status string
	var projectID sql.NullInt64
	err = tx.QueryRow(`SELECT status, project_id FROM targets WHERE id = ?`, id).Scan(&status, &projectID)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil, nil
	}
	if err != nil {
		return false, nil, fmt.Errorf("reading target %d: %w", id, err)
	}
	if !projectID.Valid || status != "todo" {
		return false, nil, nil
	}
	var group bool
	if err := tx.QueryRow(`SELECT EXISTS(SELECT 1 FROM targets WHERE parent_id = ? AND project_id = ?)`,
		id, projectID.Int64).Scan(&group); err != nil {
		return false, nil, fmt.Errorf("reading target %d children: %w", id, err)
	}
	if group {
		return false, nil, nil
	}
	rolledUp, err = SetTargetStatusOwnerTx(tx, id, "in_progress")
	return err == nil, rolledUp, err
}

func requireTarget(tx *sql.Tx, id int64) error {
	var one int
	err := tx.QueryRow(`SELECT 1 FROM targets WHERE id = ?`, id).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("target %d: %w", id, ErrRowNotFound)
	}
	if err != nil {
		return fmt.Errorf("reading target %d: %w", id, err)
	}
	return nil
}

// rolledUpAncestors runs write between two reads of id's ancestor
// statuses and returns the ancestors whose status moved, sorted.
func rolledUpAncestors(tx *sql.Tx, id int64, write func() error) ([]int64, error) {
	before, err := ancestorStatusesTx(tx, id)
	if err != nil {
		return nil, err
	}
	if err := write(); err != nil {
		return nil, err
	}
	after, err := ancestorStatusesTx(tx, id)
	if err != nil {
		return nil, err
	}
	moved := []int64{}
	for aid, s := range after {
		if before[aid] != s {
			moved = append(moved, aid)
		}
	}
	sort.Slice(moved, func(i, j int) bool { return moved[i] < moved[j] })
	return moved, nil
}

// ancestorStatusesTx is every ancestor of id on its own workbench's board
// with its status (WorkbenchQueries.ancestorStatuses; the walk stops at 256
// levels, the triggers' own bound).
func ancestorStatusesTx(tx *sql.Tx, id int64) (map[int64]string, error) {
	rows, err := tx.Query(`WITH RECURSIVE up(id, depth) AS (
			SELECT p.id, 1 FROM targets c
			JOIN targets p ON p.id = c.parent_id AND p.project_id = c.project_id
			WHERE c.id = ?
			UNION ALL
			SELECT p.id, up.depth + 1 FROM up
			JOIN targets c ON c.id = up.id
			JOIN targets p ON p.id = c.parent_id AND p.project_id = c.project_id
			WHERE up.depth < 256
		)
		SELECT t.id, t.status FROM up JOIN targets t ON t.id = up.id`, id)
	if err != nil {
		return nil, fmt.Errorf("reading target %d ancestors: %w", id, err)
	}
	defer rows.Close()
	out := map[int64]string{}
	for rows.Next() {
		var aid int64
		var s string
		if err := rows.Scan(&aid, &s); err != nil {
			return nil, err
		}
		out[aid] = s
	}
	return out, rows.Err()
}
