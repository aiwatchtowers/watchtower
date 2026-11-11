package db

import (
	"context"
	"database/sql"
	"fmt"
	"slices"
	"strings"
	"time"
)

// BulkResolveReason is the resolved_reason of an item the owner marked done
// in bulk (`watchtower inbox resolve --ids …`).
const BulkResolveReason = "Marked done in bulk"

// bulkResolveChunk is how many ids one bulk-resolve transaction takes.
const bulkResolveChunk = 200

// OpenMailItemIDsFrom returns the open email_received items whose sender's
// MailSenderKey is address's, muted or not, newest first by
// MAX(created_at, mentioned_at), then id.
func (db *DB) OpenMailItemIDsFrom(ctx context.Context, now time.Time, address string) ([]int64, error) {
	return db.openInboxIDs(ctx, `SELECT id FROM inbox_items
		WHERE `+openInboxClause+` AND trigger_type = 'email_received' AND lower(trim(sender_user_id)) = ?
		ORDER BY MAX(created_at, mentioned_at) DESC, id DESC`, sqlStamp(now), MailSenderKey(address))
}

// OpenPeopleItemIDsOlderThan returns the open people items whose
// MAX(created_at, mentioned_at) is at or before now − age (with age =
// WaitingOlderAfter: the Older section), newest first, then id.
func (db *DB) OpenPeopleItemIDsOlderThan(ctx context.Context, now time.Time, age time.Duration) ([]int64, error) {
	clause, _ := waitingKindClause(WaitingPeople)
	return db.openInboxIDs(ctx, `SELECT id FROM inbox_items
		WHERE `+openInboxClause+clause+` AND MAX(created_at, mentioned_at) <= ?
		ORDER BY MAX(created_at, mentioned_at) DESC, id DESC`, sqlStamp(now), sqlStamp(now.Add(-age)))
}

func (db *DB) openInboxIDs(ctx context.Context, query string, args ...any) ([]int64, error) {
	rows, err := db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("reading open inbox ids: %w", err)
	}
	defer rows.Close()
	ids := []int64{}
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scanning an open inbox id: %w", err)
		}
		ids = append(ids, id)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading open inbox ids: %w", err)
	}
	return ids, nil
}

// ResolveOpenInboxItems resolves, with reason, the given items that are
// still open at now (openInboxClause, the dry run's rule); resolved,
// dismissed, snoozed, archived, deleted-Jira and unknown ids are skipped.
// Duplicates are dropped; the distinct ids go in chunks of bulkResolveChunk,
// each one transaction. It returns the ids it resolved, in the order asked;
// on a failed chunk, the ids resolved by the chunks before it and the error.
func (db *DB) ResolveOpenInboxItems(ctx context.Context, now time.Time, ids []int64, reason string) ([]int64, error) {
	distinct := make([]int64, 0, len(ids))
	seen := make(map[int64]bool, len(ids))
	for _, id := range ids {
		if !seen[id] {
			seen[id] = true
			distinct = append(distinct, id)
		}
	}
	resolved := []int64{}
	for chunk := range slices.Chunk(distinct, bulkResolveChunk) {
		done, err := db.resolveOpenChunk(ctx, now, chunk, reason)
		if err != nil {
			return resolved, err
		}
		for _, id := range chunk {
			if done[id] {
				resolved = append(resolved, id)
			}
		}
	}
	return resolved, nil
}

// resolveOpenChunk resolves the items among ids open at now in one write
// transaction and returns the ids it changed.
func (db *DB) resolveOpenChunk(ctx context.Context, now time.Time, ids []int64, reason string) (map[int64]bool, error) {
	args := make([]any, 0, len(ids)+2)
	args = append(args, reason, sqlStamp(now))
	for _, id := range ids {
		args = append(args, id)
	}
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("resolving inbox items: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	done, err := scanResolvedIDs(tx.QueryContext(ctx, `UPDATE inbox_items SET status = 'resolved', resolved_reason = ?,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
		WHERE `+openInboxClause+` AND id IN (?`+strings.Repeat(", ?", len(ids)-1)+`)
		RETURNING id`, args...))
	if err != nil {
		return nil, fmt.Errorf("resolving inbox items: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("resolving inbox items: %w", err)
	}
	return done, nil
}

func scanResolvedIDs(rows *sql.Rows, err error) (map[int64]bool, error) {
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	done := map[int64]bool{}
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		done[id] = true
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return done, rows.Close()
}
