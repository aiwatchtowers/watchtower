package db

import (
	"fmt"
	"strings"
)

// FindLinearUsers returns the linear_user_map rows whose email (when who
// contains "@") or display name equals who, case-insensitively.
func (db *DB) FindLinearUsers(who string) ([]LinearUser, error) {
	column := "display_name"
	if strings.Contains(who, "@") {
		column = "email"
	}
	rows, err := db.Query(`SELECT linear_user_id, email, display_name FROM linear_user_map
		WHERE `+column+` != '' AND LOWER(`+column+`) = LOWER(?) ORDER BY linear_user_id`, who)
	if err != nil {
		return nil, fmt.Errorf("finding linear users: %w", err)
	}
	defer rows.Close()
	var out []LinearUser
	for rows.Next() {
		var u LinearUser
		if err := rows.Scan(&u.ID, &u.Email, &u.DisplayName); err != nil {
			return nil, fmt.Errorf("scanning linear user: %w", err)
		}
		out = append(out, u)
	}
	return out, rows.Err()
}

// ResolveLinearUsersByEmail maps every unmapped linear_user_map row whose
// email equals (case-insensitively) a non-deleted, non-bot Slack user's email,
// preferring Slack account 1 ("1:" prefix), then the lowest id. Rows mapped by
// hand (match_method = 'manual') are never touched. Returns rows mapped.
func (db *DB) ResolveLinearUsersByEmail(now string) (int64, error) {
	res, err := db.Exec(`UPDATE linear_user_map SET
  slack_user_id = (SELECT u.id FROM users u
                   WHERE LOWER(u.email) = LOWER(linear_user_map.email) AND u.email != ''
                     AND u.is_deleted = 0 AND COALESCE(u.is_bot_override, u.is_bot) = 0
                   ORDER BY (u.id LIKE '1:%') DESC, u.id LIMIT 1),
  match_method = 'email', match_confidence = 1.0, resolved_at = ?
WHERE slack_user_id = '' AND match_method != 'manual' AND email != ''
  AND EXISTS (SELECT 1 FROM users u WHERE LOWER(u.email) = LOWER(linear_user_map.email) AND u.email != ''
              AND u.is_deleted = 0 AND COALESCE(u.is_bot_override, u.is_bot) = 0)`, now)
	if err != nil {
		return 0, fmt.Errorf("resolving linear users by email: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("resolving linear users by email: %w", err)
	}
	return n, nil
}
