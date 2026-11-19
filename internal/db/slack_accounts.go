package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// SlackAccount is one row of slack_accounts — a connected Slack workspace.
// Replaces the workspace singleton's current_user_id/search_last_date
// scalars, which used to live as workspace columns (see migration 00048).
type SlackAccount struct {
	ID             int64
	TeamID         string
	TeamName       string
	TeamDomain     string
	Label          string
	CurrentUserID  string // namespaced, e.g. "2:U0123"
	Status         string // ok | error | revoked | removed
	Error          string
	Enabled        bool
	SearchLastDate string
	CreatedAt      string
	// CompanySlug ties the account to a company bundle's Slack app; '' = our
	// shared app (migration 00198).
	CompanySlug string
	// ClientID is the Slack app the token was issued through; "" = connected
	// before migration 00196 and not yet backfilled (BackfillSlackClientIDs).
	ClientID string
	// AppID is the Slack App ID from oauth.v2.access; "" = unknown.
	AppID string
	// RefreshTokenExpiresAt is the RFC 3339 UTC expiry of a rotated token's
	// refresh token; "" = no rotation.
	RefreshTokenExpiresAt string
}

// FormatConnectedWorkspaces renders "<label1> (<domain1>), <label2> (<domain2>)"
// for AI system-prompt / status-line display. An account's label is preferred,
// falling back to its team name; a missing domain drops the parenthetical.
// Empty slice -> "".
func FormatConnectedWorkspaces(accounts []SlackAccount) string {
	parts := make([]string, 0, len(accounts))
	for _, a := range accounts {
		name := a.Label
		if name == "" {
			name = a.TeamName
		}
		if a.TeamDomain != "" {
			parts = append(parts, fmt.Sprintf("%s (%s)", name, a.TeamDomain))
		} else {
			parts = append(parts, name)
		}
	}
	return strings.Join(parts, ", ")
}

// slackAccountColumns is the shared column list for ListSlackAccounts,
// ListEnabledSlackAccounts, and GetSlackAccount — one place to keep the
// SELECT list and scanSlackAccount's Scan targets in lockstep.
const slackAccountColumns = `id, team_id, team_name, team_domain, label, current_user_id,
        status, error, enabled, search_last_date, created_at, client_id, app_id,
        refresh_token_expires_at, company_slug`

// scanSlackAccount scans one slackAccountColumns row from either *sql.Row or
// *sql.Rows (the jira.scanJiraIssue precedent).
func scanSlackAccount(scanner interface{ Scan(dest ...any) error }) (SlackAccount, error) {
	var a SlackAccount
	err := scanner.Scan(&a.ID, &a.TeamID, &a.TeamName, &a.TeamDomain, &a.Label, &a.CurrentUserID,
		&a.Status, &a.Error, &a.Enabled, &a.SearchLastDate, &a.CreatedAt, &a.ClientID, &a.AppID,
		&a.RefreshTokenExpiresAt, &a.CompanySlug)
	return a, err
}

// CreateSlackAccount inserts a new connected Slack account and returns its ID.
func (db *DB) CreateSlackAccount(a SlackAccount) (int64, error) {
	res, err := db.Exec(`INSERT INTO slack_accounts
        (team_id, team_name, team_domain, label, current_user_id, company_slug)
        VALUES (?,?,?,?,?,?)`,
		a.TeamID, a.TeamName, a.TeamDomain, a.Label, a.CurrentUserID, a.CompanySlug)
	if err != nil {
		return 0, fmt.Errorf("creating slack account: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, fmt.Errorf("reading new slack account id: %w", err)
	}
	return id, nil
}

// ListSlackAccounts returns every connected Slack account, oldest first.
func (db *DB) ListSlackAccounts() ([]SlackAccount, error) {
	rows, err := db.Query(`SELECT ` + slackAccountColumns + ` FROM slack_accounts ORDER BY id ASC`)
	if err != nil {
		return nil, fmt.Errorf("listing slack accounts: %w", err)
	}
	defer rows.Close()
	var out []SlackAccount
	for rows.Next() {
		a, err := scanSlackAccount(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning slack account: %w", err)
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// ListEnabledSlackAccounts returns every enabled, non-removed connected
// Slack account, oldest first.
func (db *DB) ListEnabledSlackAccounts() ([]SlackAccount, error) {
	rows, err := db.Query(`SELECT ` + slackAccountColumns + ` FROM slack_accounts WHERE enabled = 1 AND status != 'removed' ORDER BY id ASC`)
	if err != nil {
		return nil, fmt.Errorf("listing enabled slack accounts: %w", err)
	}
	defer rows.Close()
	var out []SlackAccount
	for rows.Next() {
		a, err := scanSlackAccount(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning slack account: %w", err)
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// GetSlackAccount returns a single connected Slack account by ID.
func (db *DB) GetSlackAccount(id int64) (SlackAccount, error) {
	a, err := scanSlackAccount(db.QueryRow(`SELECT `+slackAccountColumns+` FROM slack_accounts WHERE id = ?`, id))
	if err != nil {
		return SlackAccount{}, fmt.Errorf("getting slack account %d: %w", id, err)
	}
	return a, nil
}

// UpdateSlackAccountConnection updates the resolved team info and current
// user id for accountID — called once auth.test/team.info resolve — and gives
// a still-unlabeled account its automatic label (best effort, after the
// identity is saved) (SlackAccountLabel).
func (db *DB) UpdateSlackAccountConnection(id int64, teamID, teamName, teamDomain, currentUserID string) error {
	res, err := db.Exec(`UPDATE slack_accounts SET team_id = ?, team_name = ?, team_domain = ?,
        current_user_id = ? WHERE id = ?`,
		teamID, teamName, teamDomain, currentUserID, id)
	if err != nil {
		return fmt.Errorf("updating slack account %d connection: %w", id, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("updating slack account connection: no slack_accounts row %d", id)
	}
	db.fillAccountLabelBestEffort("slack_accounts", id, SlackAccountLabel(teamName, teamDomain))
	return nil
}

// SetSlackAccountApp records the Slack app (client id and App ID) accountID's
// token was issued through — written by every connect.
func (db *DB) SetSlackAccountApp(id int64, clientID, appID string) error {
	res, err := db.Exec(`UPDATE slack_accounts SET client_id = ?, app_id = ? WHERE id = ?`, clientID, appID, id)
	if err != nil {
		return fmt.Errorf("setting app for slack account %d: %w", id, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("setting app: no slack_accounts row %d", id)
	}
	return nil
}

// SetSlackAccountClientID records the client id a sign-in went through when
// the App ID is not known: the row's App ID is kept while the client id stays
// the same and cleared when it changes — one statement, so a concurrent
// SetSlackAccountApp cannot interleave.
func (db *DB) SetSlackAccountClientID(id int64, clientID string) error {
	res, err := db.Exec(`UPDATE slack_accounts
        SET app_id = CASE WHEN client_id = ? THEN app_id ELSE '' END, client_id = ?
        WHERE id = ?`, clientID, clientID, id)
	if err != nil {
		return fmt.Errorf("setting client id for slack account %d: %w", id, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("setting client id: no slack_accounts row %d", id)
	}
	return nil
}

// SetSlackRefreshExpiry records when accountID's refresh token expires; the
// zero time clears it (a token without rotation).
func (db *DB) SetSlackRefreshExpiry(id int64, at time.Time) error {
	stamp := ""
	if !at.IsZero() {
		stamp = at.UTC().Format(time.RFC3339)
	}
	res, err := db.Exec(`UPDATE slack_accounts SET refresh_token_expires_at = ? WHERE id = ?`, stamp, id)
	if err != nil {
		return fmt.Errorf("setting refresh expiry for slack account %d: %w", id, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("setting refresh expiry: no slack_accounts row %d", id)
	}
	return nil
}

// BackfillSlackClientIDs gives every account without a client id (connected
// before migration 00196) clientID and returns how many rows it filled. A set
// id is never overwritten, so it is idempotent and needs no lock (A17). A row
// tied to a company (#1887) is never filled: it signed in through the
// company's Slack app, not the shared one clientID names; its token file
// carries its client and the next token read repairs the column.
func (db *DB) BackfillSlackClientIDs(clientID string) (int64, error) {
	res, err := db.Exec(`UPDATE slack_accounts SET client_id = ? WHERE client_id = '' AND company_slug = ''`, clientID)
	if err != nil {
		return 0, fmt.Errorf("backfilling slack client ids: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("backfilling slack client ids: %w", err)
	}
	return n, nil
}

// SetSlackAccountEnabled toggles whether accountID is synced.
func (db *DB) SetSlackAccountEnabled(id int64, enabled bool) error {
	res, err := db.Exec(`UPDATE slack_accounts SET enabled = ? WHERE id = ?`, enabled, id)
	if err != nil {
		return fmt.Errorf("setting enabled for slack account %d: %w", id, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("setting enabled: no slack_accounts row %d", id)
	}
	return nil
}

// SetSlackAccountAuthState updates status/error telemetry for accountID.
// status is one of "ok", "error", "revoked", "removed".
// It also keeps the access facts (revoked_at, access_ok_at) and never writes
// over a purged row except with "ok", which re-enables it (account_access.go).
func (db *DB) SetSlackAccountAuthState(id int64, status, errMsg string) error {
	return db.setAccountAuthState("slack_accounts", reenableOnLoginSQL, id, status, errMsg)
}

// SetSlackAccountError records errMsg on accountID's error column without
// touching status — for a data gap (e.g. a search-sync catch-up window that
// had to be clamped) rather than an auth failure, which is what
// SetSlackAccountAuthState's status transitions are for.
func (db *DB) SetSlackAccountError(id int64, errMsg string) error {
	res, err := db.Exec(`UPDATE slack_accounts SET error = ? WHERE id = ?`, errMsg, id)
	if err != nil {
		return fmt.Errorf("setting error for slack account %d: %w", id, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("setting error: no slack_accounts row %d", id)
	}
	return nil
}

// SetSlackAccountRemoved marks accountID as removed and disables it — a
// non-destructive soft delete, so the row (and any data it left behind)
// stays reachable by ID.
func (db *DB) SetSlackAccountRemoved(id int64) error {
	res, err := db.Exec(`UPDATE slack_accounts SET status = 'removed', enabled = 0 WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("removing slack account %d: %w", id, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("removing slack account: no slack_accounts row %d", id)
	}
	return nil
}

// GetSlackAccountSearchWatermark returns the search.messages sync watermark
// (empty if unset or the account is missing) for accountID — the
// per-account replacement for the old workspace.search_last_date scalar.
func (db *DB) GetSlackAccountSearchWatermark(id int64) (string, error) {
	var date string
	err := db.QueryRow(`SELECT search_last_date FROM slack_accounts WHERE id = ?`, id).Scan(&date)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", nil
		}
		return "", fmt.Errorf("getting search watermark for slack account %d: %w", id, err)
	}
	return date, nil
}

// SetSlackAccountSearchWatermark advances the search.messages sync
// watermark for accountID.
func (db *DB) SetSlackAccountSearchWatermark(id int64, date string) error {
	res, err := db.Exec(`UPDATE slack_accounts SET search_last_date = ? WHERE id = ?`, date, id)
	if err != nil {
		return fmt.Errorf("setting search watermark for slack account %d: %w", id, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("setting search watermark: no slack_accounts row %d", id)
	}
	return nil
}

// SetSlackFirstCycleAtOnce records at as accountID's first sync attempt
// (slack_accounts.first_cycle_at) unless one is already recorded: first write
// wins, so a retried first run keeps the original instant.
func (db *DB) SetSlackFirstCycleAtOnce(id int64, at time.Time) error {
	if _, err := db.Exec(`UPDATE slack_accounts SET first_cycle_at = ? WHERE id = ? AND first_cycle_at = ''`,
		at.UTC().Format(time.RFC3339), id); err != nil {
		return fmt.Errorf("setting first_cycle_at for slack account %d: %w", id, err)
	}
	return nil
}

// SlackFirstCycleAt returns accountID's first sync attempt; zero when none is
// recorded or the row is missing.
func (db *DB) SlackFirstCycleAt(id int64) (time.Time, error) {
	var stamp string
	err := db.QueryRow(`SELECT first_cycle_at FROM slack_accounts WHERE id = ?`, id).Scan(&stamp)
	if errors.Is(err, sql.ErrNoRows) || (err == nil && stamp == "") {
		return time.Time{}, nil
	}
	if err != nil {
		return time.Time{}, fmt.Errorf("getting first_cycle_at for slack account %d: %w", id, err)
	}
	t, err := time.Parse(time.RFC3339, stamp)
	if err != nil {
		return time.Time{}, fmt.Errorf("parsing first_cycle_at %q for slack account %d: %w", stamp, id, err)
	}
	return t, nil
}

// ReactionCommandsSeeded reports whether accountID's pre-existing reaction
// history has been recorded into the reaction_commands ledger (migration
// 00073). A missing row reads as NOT seeded, never as an error: the caller's
// safe move when in doubt is to seed, not to replay.
func (db *DB) ReactionCommandsSeeded(id int64) (bool, error) {
	var stamp string
	err := db.QueryRow(`SELECT reaction_commands_seeded_at FROM slack_accounts WHERE id = ?`, id).Scan(&stamp)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return false, nil
		}
		return false, fmt.Errorf("reading reaction seed stamp for slack account %d: %w", id, err)
	}
	return stamp != "", nil
}

// MarkReactionCommandsSeeded stamps accountID's reaction history as seeded.
func (db *DB) MarkReactionCommandsSeeded(id int64) error {
	res, err := db.Exec(`UPDATE slack_accounts SET reaction_commands_seeded_at = ? WHERE id = ?`,
		time.Now().UTC().Format(time.RFC3339), id)
	if err != nil {
		return fmt.Errorf("stamping reaction seed for slack account %d: %w", id, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("stamping reaction seed: no slack_accounts row %d", id)
	}
	return nil
}

// SlackRosterSyncedAt returns when accountID's full workspace roster was last
// fetched (migration 00099); the zero time means never, or a missing row.
func (db *DB) SlackRosterSyncedAt(id int64) (time.Time, error) {
	var stamp string
	err := db.QueryRow(`SELECT roster_synced_at FROM slack_accounts WHERE id = ?`, id).Scan(&stamp)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return time.Time{}, nil
		}
		return time.Time{}, fmt.Errorf("reading roster stamp for slack account %d: %w", id, err)
	}
	if stamp == "" {
		return time.Time{}, nil
	}
	t, err := time.Parse(time.RFC3339, stamp)
	if err != nil {
		return time.Time{}, fmt.Errorf("parsing roster stamp for slack account %d: %w", id, err)
	}
	return t, nil
}

// SlackEmojiScopeMissing reports whether accountID's legacy token (no
// recorded grant) answered emoji.list with missing_scope (migration 00195);
// false for a missing row.
func (db *DB) SlackEmojiScopeMissing(id int64) (bool, error) {
	var missing bool
	err := db.QueryRow(`SELECT emoji_scope_missing FROM slack_accounts WHERE id = ?`, id).Scan(&missing)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("reading emoji scope flag for slack account %d: %w", id, err)
	}
	return missing, nil
}

// SetSlackEmojiScopeMissing marks accountID's legacy token as lacking
// emoji:read, so the emoji sync skips it. Its only writer is the sync's
// syncEmoji; nothing clears it — a re-login records the grant, which then
// decides alone.
func (db *DB) SetSlackEmojiScopeMissing(id int64) error {
	if _, err := db.Exec(`UPDATE slack_accounts SET emoji_scope_missing = 1 WHERE id = ?`, id); err != nil {
		return fmt.Errorf("marking emoji scope missing for slack account %d: %w", id, err)
	}
	return nil
}

// SetSlackRosterSyncedAt stamps accountID's roster as fetched at at.
func (db *DB) SetSlackRosterSyncedAt(id int64, at time.Time) error {
	res, err := db.Exec(`UPDATE slack_accounts SET roster_synced_at = ? WHERE id = ?`,
		at.UTC().Format(time.RFC3339), id)
	if err != nil {
		return fmt.Errorf("stamping roster for slack account %d: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("stamping roster for slack account %d: %w", id, err)
	}
	if n == 0 {
		return fmt.Errorf("stamping roster: no slack_accounts row %d", id)
	}
	return nil
}
