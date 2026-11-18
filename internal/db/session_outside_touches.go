package db

import (
	"context"
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

// QuietOutsideRoot records the owner's Not Now: session sessionID is never
// asked about repoRoot again.
func (db *DB) QuietOutsideRoot(ctx context.Context, sessionID int64, repoRoot string) error {
	if _, err := db.ExecContext(ctx, `INSERT INTO session_outside_touches (session_id, repo_root, quiet) VALUES (?, ?, 1)
		ON CONFLICT (session_id, repo_root) DO UPDATE SET quiet = 1`, sessionID, repoRoot); err != nil {
		return fmt.Errorf("quieting session %d about %s: %w", sessionID, repoRoot, err)
	}
	return nil
}
