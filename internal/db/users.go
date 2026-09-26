package db

import (
	"database/sql"
	"fmt"
	"strings"

	watchtowerslack "watchtower/internal/slack"
)

// UserFilter provides options for filtering user queries.
type UserFilter struct {
	ExcludeBots    bool
	ExcludeDeleted bool
}

// UpsertUser inserts or updates a user with full profile data (is_stub = 0).
func (db *DB) UpsertUser(u User) error {
	_, err := db.Exec(`
		INSERT INTO users (id, name, display_name, real_name, email, is_bot, is_deleted, is_stub, profile_json, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
		ON CONFLICT(id) DO UPDATE SET
			name = excluded.name,
			display_name = excluded.display_name,
			real_name = excluded.real_name,
			email = excluded.email,
			is_bot = excluded.is_bot,
			is_deleted = excluded.is_deleted,
			is_stub = 0,
			profile_json = excluded.profile_json,
			updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')`,
		u.ID, u.Name, u.DisplayName, u.RealName, u.Email,
		u.IsBot, u.IsDeleted, u.ProfileJSON,
	)
	if err != nil {
		return fmt.Errorf("upserting user %s: %w", u.ID, err)
	}
	return nil
}

// GetUsers returns users matching the given filter.
func (db *DB) GetUsers(filter UserFilter) ([]User, error) {
	query := `SELECT id, name, display_name, real_name, email, is_bot, is_deleted, is_stub, profile_json, updated_at FROM users`
	var conditions []string

	if filter.ExcludeBots {
		conditions = append(conditions, "COALESCE(is_bot_override, is_bot) = 0")
	}
	if filter.ExcludeDeleted {
		conditions = append(conditions, "is_deleted = 0")
	}

	if len(conditions) > 0 {
		query += " WHERE " + conditions[0]
		for _, c := range conditions[1:] {
			query += " AND " + c
		}
	}
	query += " ORDER BY name"

	rows, err := db.Query(query)
	if err != nil {
		return nil, fmt.Errorf("querying users: %w", err)
	}
	defer rows.Close()

	return scanUsers(rows)
}

// GetUserByName returns a user by their Slack username.
func (db *DB) GetUserByName(name string) (*User, error) {
	row := db.QueryRow(`
		SELECT id, name, display_name, real_name, email, is_bot, is_deleted, is_stub, profile_json, updated_at
		FROM users WHERE name = ?`, name)
	return scanUser(row)
}

// SearchUsersByName returns non-bot, non-deleted users whose username, display
// name, or real name contains the query (case-insensitive).
func (db *DB) SearchUsersByName(query string, limit int) ([]User, error) {
	pattern := "%" + query + "%"
	rows, err := db.Query(`
		SELECT id, name, display_name, real_name, email, is_bot, is_deleted, is_stub, profile_json, updated_at
		FROM users
		WHERE is_bot = 0 AND is_deleted = 0
		  AND (name LIKE ? OR display_name LIKE ? OR real_name LIKE ?)
		ORDER BY name LIMIT ?`, pattern, pattern, pattern, limit)
	if err != nil {
		return nil, fmt.Errorf("searching users: %w", err)
	}
	defer rows.Close()

	return scanUsers(rows)
}

// GetUserByID returns a user by their Slack ID.
func (db *DB) GetUserByID(id string) (*User, error) {
	row := db.QueryRow(`
		SELECT id, name, display_name, real_name, email, is_bot, is_deleted, is_stub, profile_json, updated_at
		FROM users WHERE id = ?`, id)
	return scanUser(row)
}

// GetUserByEmail returns a user by their email address.
func (db *DB) GetUserByEmail(email string) (*User, error) {
	row := db.QueryRow(`
		SELECT id, name, display_name, real_name, email, is_bot, is_deleted, is_stub, profile_json, updated_at
		FROM users WHERE email = ? AND email != ''`, email)
	return scanUser(row)
}

// GetUserByEmailFold matches an email case-insensitively. GetUserByEmail's
// exact match is right for synced Slack data (which is consistently cased),
// but wrong for anything a human typed or a tool authored, such as git commit
// author emails, where case varies freely.
//
// Since the Slack multi-account migration, one email legitimately maps to
// several rows — the same human has one users row per connected workspace
// (namespaced ids), so a duplicate email is the EXPECTED shape, not an edge
// case. Deleted rows are excluded (a deactivated account is never the right
// attribution target), and among the remaining candidates the lowest id wins
// — an arbitrary but STABLE tiebreak, so the same email always resolves to
// the same row rather than whatever order SQLite happens to return.
func (db *DB) GetUserByEmailFold(email string) (*User, error) {
	row := db.QueryRow(`
		SELECT id, name, display_name, real_name, email, is_bot, is_deleted, is_stub, profile_json, updated_at
		FROM users WHERE LOWER(email) = LOWER(?) AND email != '' AND is_deleted = 0
		ORDER BY id ASC LIMIT 1`, email)
	return scanUser(row)
}

// ResolveSlackUserID maps a hand-typed Slack user id onto the users.id that
// names it, so a value an operator read off the Slack UI ("U0123ABCD") lands in
// the namespaced form ("1:U0123ABCD") every reader compares against. Since
// migration 00048 a bare id matches no column in this database, and a writer
// that stores one produces a row nothing can ever join — silently, because
// every consumer reads a miss as "no signal".
//
// It resolves rather than guesses: an input that already names a users row is
// returned unchanged, and a bare id is accepted only when exactly one account's
// users row carries it. Nothing matched, or several accounts matched, is an
// error the caller must surface — never a stored value.
func (db *DB) ResolveSlackUserID(input string) (string, error) {
	id := strings.TrimSpace(input)
	if id == "" {
		return "", fmt.Errorf("empty slack user id")
	}

	// An exact hit needs no interpretation, whichever form it is in.
	var exact string
	err := db.QueryRow(`SELECT id FROM users WHERE id = ?`, id).Scan(&exact)
	if err == nil {
		return exact, nil
	}
	if err != sql.ErrNoRows {
		return "", fmt.Errorf("looking up slack user %s: %w", id, err)
	}

	// A namespaced input that missed names a specific account's row that does
	// not exist. Re-pointing it at another account's row with the same raw id
	// would silently attribute one workspace's person to another.
	if _, _, namespaced := watchtowerslack.SplitAccountID(id); namespaced {
		return "", fmt.Errorf("no synced Slack user %s", id)
	}

	matches, err := db.slackUserIDsWithRawID(id)
	if err != nil {
		return "", err
	}
	switch len(matches) {
	case 1:
		return matches[0], nil
	case 0:
		return "", fmt.Errorf("no synced Slack user matches %q (sync Slack first, or pass the full id such as 1:%s)", id, id)
	default:
		return "", fmt.Errorf("%q matches several Slack accounts (%s) — pass the full id", id, strings.Join(matches, ", "))
	}
}

// slackUserIDsWithRawID returns every users.id whose raw Slack id (the part
// after the "<account>:" prefix) equals rawID. The prefix is split in Go rather
// than matched with SQL LIKE so a wildcard in the input cannot widen the match.
func (db *DB) slackUserIDsWithRawID(rawID string) ([]string, error) {
	rows, err := db.Query(`SELECT id FROM users ORDER BY id`)
	if err != nil {
		return nil, fmt.Errorf("querying users: %w", err)
	}
	defer rows.Close()

	var matches []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scanning user ID: %w", err)
		}
		if _, raw, _ := watchtowerslack.SplitAccountID(id); raw == rawID {
			matches = append(matches, id)
		}
	}
	return matches, rows.Err()
}

// EnsureUser inserts a minimal stub user record if not already present.
// Stubs are marked with is_stub=1 so syncUserProfiles can backfill them.
// Does NOT update existing records (INSERT ON CONFLICT DO NOTHING).
func (db *DB) EnsureUser(id, name string) error {
	_, err := db.Exec(`
		INSERT INTO users (id, name, is_stub) VALUES (?, ?, 1)
		ON CONFLICT(id) DO NOTHING`,
		id, name,
	)
	if err != nil {
		return fmt.Errorf("ensuring user %s: %w", id, err)
	}
	return nil
}

// GetIncompleteUserIDs returns user IDs that either:
// - appear in messages but not in the users table, or
// - exist as stub records (is_stub=1) needing full profile backfill.
func (db *DB) GetIncompleteUserIDs() ([]string, error) {
	rows, err := db.Query(`
		SELECT DISTINCT id FROM (
			SELECT m.user_id AS id
			FROM messages m
			LEFT JOIN users u ON u.id = m.user_id
			WHERE m.user_id != '' AND u.id IS NULL
			UNION
			SELECT u.id
			FROM users u
			WHERE u.is_stub = 1
		)`)
	if err != nil {
		return nil, fmt.Errorf("querying incomplete user IDs: %w", err)
	}
	defer rows.Close()

	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scanning user ID: %w", err)
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

// UserNameByID returns a display name for a user by their Slack ID.
// Returns display_name if set, otherwise name.
func (db *DB) UserNameByID(userID string) (string, error) {
	var name, displayName string
	err := db.QueryRow(`SELECT name, display_name FROM users WHERE id = ?`, userID).Scan(&name, &displayName)
	if err != nil {
		return userID, err // fallback to ID
	}
	if displayName != "" {
		return displayName, nil
	}
	return name, nil
}

// UserNameByRawID returns a display name for a user by a raw (non-namespaced)
// Slack id — one parsed directly out of "<@U123>" markup in message text,
// which keeps the bare id forever regardless of how users.id is stored.
// Since migration 00048, users.id may be namespaced ("<accountID>:U123"), so
// this matches either form. A raw id parsed from text carries no account, so
// if the same raw id exists under two connected workspaces this resolves to
// an arbitrary one of them — acceptable for a display name.
func (db *DB) UserNameByRawID(rawID string) (string, error) {
	var name, displayName string
	err := db.QueryRow(`SELECT name, display_name FROM users WHERE id = ? OR id LIKE '%:' || ?`, rawID, rawID).Scan(&name, &displayName)
	if err != nil {
		return rawID, err // fallback to ID
	}
	if displayName != "" {
		return displayName, nil
	}
	return name, nil
}

// SetBotOverride sets or clears the manual bot override for a user.
// Pass nil to clear (revert to Slack-provided value), or a bool pointer to force.
func (db *DB) SetBotOverride(userID string, isBot *bool) error {
	var val any
	if isBot != nil {
		if *isBot {
			val = 1
		} else {
			val = 0
		}
	}
	_, err := db.Exec(`UPDATE users SET is_bot_override = ? WHERE id = ?`, val, userID)
	if err != nil {
		return fmt.Errorf("setting bot override for %s: %w", userID, err)
	}
	return nil
}

// SetUserMutedForLLM sets or clears the is_muted_for_llm flag for a user.
func (db *DB) SetUserMutedForLLM(userID string, muted bool) error {
	val := 0
	if muted {
		val = 1
	}
	_, err := db.Exec(`UPDATE users SET is_muted_for_llm = ? WHERE id = ?`, val, userID)
	if err != nil {
		return fmt.Errorf("setting user muted for llm %s: %w", userID, err)
	}
	return nil
}

// GetMutedUserIDs returns the list of user IDs that are muted for LLM processing.
func (db *DB) GetMutedUserIDs() ([]string, error) {
	rows, err := db.Query(`SELECT id FROM users WHERE is_muted_for_llm = 1`)
	if err != nil {
		return nil, fmt.Errorf("querying muted users: %w", err)
	}
	defer rows.Close()

	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scanning muted user id: %w", err)
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

func scanUser(row *sql.Row) (*User, error) {
	var u User
	err := row.Scan(
		&u.ID, &u.Name, &u.DisplayName, &u.RealName, &u.Email,
		&u.IsBot, &u.IsDeleted, &u.IsStub, &u.ProfileJSON, &u.UpdatedAt,
	)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("scanning user: %w", err)
	}
	return &u, nil
}

func scanUsers(rows *sql.Rows) ([]User, error) {
	var users []User
	for rows.Next() {
		var u User
		err := rows.Scan(
			&u.ID, &u.Name, &u.DisplayName, &u.RealName, &u.Email,
			&u.IsBot, &u.IsDeleted, &u.IsStub, &u.ProfileJSON, &u.UpdatedAt,
		)
		if err != nil {
			return nil, fmt.Errorf("scanning user row: %w", err)
		}
		users = append(users, u)
	}
	return users, rows.Err()
}
