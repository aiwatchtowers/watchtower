package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
)

// CountOutsideTouch counts one more tool call of session sessionID inside
// repoRoot, a repository outside its workbench's folders (00196, the folder
// suggestion hook), in one autocommit upsert, and returns the new count,
// whether the agent was already nudged about it and whether the owner
// quieted it (Not Now).
func (db *DB) CountOutsideTouch(ctx context.Context, sessionID int64, repoRoot string) (touches int, nudged, quiet bool, err error) {
	err = db.QueryRowContext(ctx, `INSERT INTO session_outside_touches (session_id, repo_root, touches) VALUES (?, ?, 1)
		ON CONFLICT (session_id, repo_root) DO UPDATE SET touches = touches + 1
		RETURNING touches, nudged_at IS NOT NULL, quiet`, sessionID, repoRoot).Scan(&touches, &nudged, &quiet)
	if err != nil {
		return 0, false, false, fmt.Errorf("counting session %d's touch of %s: %w", sessionID, repoRoot, err)
	}
	return touches, nudged, quiet, nil
}

// MarkOutsideNudged records that session sessionID's agent was told about
// repoRoot.
func (db *DB) MarkOutsideNudged(ctx context.Context, sessionID int64, repoRoot string) error {
	if _, err := db.ExecContext(ctx, `INSERT INTO session_outside_touches (session_id, repo_root, nudged_at)
		VALUES (?, ?, strftime('%Y-%m-%dT%H:%M:%SZ','now'))
		ON CONFLICT (session_id, repo_root) DO UPDATE SET nudged_at = excluded.nudged_at`, sessionID, repoRoot); err != nil {
		return fmt.Errorf("marking session %d nudged about %s: %w", sessionID, repoRoot, err)
	}
	return nil
}

// ClaimOutsideNudge stamps nudged_at on session sessionID's counted row for
// repoRoot unless it is already stamped or quiet, and reports whether this
// call stamped it: of two hooks racing past the third touch only one wins,
// so the agent is told once.
func (db *DB) ClaimOutsideNudge(ctx context.Context, sessionID int64, repoRoot string) (bool, error) {
	res, err := db.ExecContext(ctx, `UPDATE session_outside_touches SET nudged_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE session_id = ? AND repo_root = ? AND nudged_at IS NULL AND quiet = 0`, sessionID, repoRoot)
	if err != nil {
		return false, fmt.Errorf("marking session %d nudged about %s: %w", sessionID, repoRoot, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("marking session %d nudged about %s: %w", sessionID, repoRoot, err)
	}
	return n == 1, nil
}

// QuietOutsideRoot records the owner's Not Now: session sessionID is never
// asked about repoRoot again.
func (db *DB) QuietOutsideRoot(ctx context.Context, sessionID int64, repoRoot string) error {
	if _, err := db.ExecContext(ctx, `INSERT INTO session_outside_touches (session_id, repo_root, quiet) VALUES (?, ?, 1)
		ON CONFLICT (session_id, repo_root) DO UPDATE SET quiet = 1`, sessionID, repoRoot); err != nil {
		return fmt.Errorf("quieting session %d about %s: %w", sessionID, repoRoot, err)
	}
	return nil
}

// OutsideTouches is how many tool calls of session sessionID touched
// repoRoot (compared NOCASE) as the hook counted them; 0 when none did.
func (db *DB) OutsideTouches(ctx context.Context, sessionID int64, repoRoot string) (int, error) {
	var n int
	err := db.QueryRowContext(ctx, `SELECT touches FROM session_outside_touches WHERE session_id = ? AND repo_root = ? COLLATE NOCASE`,
		sessionID, repoRoot).Scan(&n)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("reading session %d's touches of %s: %w", sessionID, repoRoot, err)
	}
	return n, nil
}
