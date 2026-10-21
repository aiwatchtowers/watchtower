package db

import "fmt"

// Account access facts (board #601, migration 00147): access_ok_at is the
// last confirmed authenticated call, revoked_at the moment status turned
// revoked. Both feed the purge scheduler (internal/purge).

// accountTables maps a purge source to its account table. The table name is
// only ever taken from this fixed map, never built from input.
var accountTables = map[string]string{
	"slack":  "slack_accounts",
	"google": "google_accounts",
	"jira":   "jira_accounts",
	"linear": "linear_accounts",
}

// accountTable returns the account table of source, or an error for an
// unknown source.
func accountTable(source string) (string, error) {
	t, ok := accountTables[source]
	if !ok {
		return "", fmt.Errorf("unknown account source %q", source)
	}
	return t, nil
}

// nowSQL is the RFC 3339 UTC "now" every account clock is written with.
const nowSQL = `strftime('%Y-%m-%dT%H:%M:%SZ', 'now')`

// authStateSetSQL is the SET list every Set*AccountAuthState writer shares
// (?1 = status, ?2 = error text): revoked stamps revoked_at once and keeps it
// on a repeat — unless access was confirmed after it (a clean Jira/Linear
// pass stamps access_ok_at only), which makes this a new revocation —, ok
// clears it and stamps access_ok_at, error keeps both. Both columns are
// fixed-width RFC 3339 UTC, so text order is time order.
const authStateSetSQL = `status = ?1, error = ?2,
	revoked_at = CASE WHEN ?1 = 'revoked' THEN CASE WHEN revoked_at = '' OR access_ok_at > revoked_at THEN ` + nowSQL + ` ELSE revoked_at END
	                  WHEN ?1 = 'ok' THEN '' ELSE revoked_at END,
	access_ok_at = CASE WHEN ?1 = 'ok' THEN ` + nowSQL + ` ELSE access_ok_at END`

// authStateWhereSQL (?3 = id) refuses every write over a purged row except
// ok: a purged account stays purged until a later login proves access again
// (PURGE-01).
const authStateWhereSQL = ` WHERE id = ?3 AND (status != 'purged' OR ?1 = 'ok')`

// reenableOnLoginSQL re-enables a purged row on the ok that revives it. In a
// SET list, status still reads the pre-update value.
const reenableOnLoginSQL = `, enabled = CASE WHEN status = 'purged' THEN 1 ELSE enabled END`

// setAccountAuthState runs one auth-state UPDATE on table. extraSet is a
// constant SQL fragment appended to the SET list. A write refused because the
// row is purged returns nil; a missing row is an error.
func (db *DB) setAccountAuthState(table, extraSet string, id int64, status, errMsg string) error {
	res, err := db.Exec(`UPDATE `+table+` SET `+authStateSetSQL+extraSet+authStateWhereSQL, status, errMsg, id)
	if err != nil {
		return fmt.Errorf("setting auth state for %s row %d: %w", table, id, err)
	}
	if n, _ := res.RowsAffected(); n > 0 {
		return nil
	}
	var exists bool
	if err := db.QueryRow(`SELECT EXISTS(SELECT 1 FROM `+table+` WHERE id = ?)`, id).Scan(&exists); err != nil {
		return fmt.Errorf("setting auth state: checking %s row %d: %w", table, id, err)
	}
	if !exists {
		return fmt.Errorf("setting auth state: no %s row %d", table, id)
	}
	return nil // purged: the write is refused by design
}

// MarkAccountAccessOK stamps access_ok_at for one account without touching
// status — for sync passes that never write "ok" (Jira, Linear: a nil error
// is not proof of health, LINEAR-03) but did reach the source. A purged row
// is left alone; a missing row is not an error (the pass raced a delete).
func (db *DB) MarkAccountAccessOK(source string, id int64) error {
	table, err := accountTable(source)
	if err != nil {
		return err
	}
	if _, err := db.Exec(`UPDATE `+table+` SET access_ok_at = `+nowSQL+` WHERE id = ? AND status != 'purged'`, id); err != nil {
		return fmt.Errorf("marking %s account %d access ok: %w", source, id, err)
	}
	return nil
}
