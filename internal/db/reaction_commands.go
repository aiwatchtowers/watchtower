package db

import (
	"database/sql"
	"fmt"
	"time"
)

// ReactionCommandProvisional is the ledger status of a command whose dispatch
// is in flight: ClaimReactionCommand writes it BEFORE the compose/Propose side
// effect and FinalizeReactionCommand replaces it with the terminal outcome
// after. It reuses the `pending` value the 00063 CHECK already permits.
const ReactionCommandProvisional = "pending"

// ReactionCommandMapping is one row of the emoji -> action dictionary
// (reaction_command_map). `Kind` is "builtin_tool" (dispatch the registered
// tool named by `Tool`) or "agent" (a custom handler, HandlerID — wired in a
// later wave). See the reaction-commands design spec.
type ReactionCommandMapping struct {
	Emoji     string
	Kind      string
	Tool      string
	HandlerID int64
	Enabled   bool
}

// OwnerReaction is one reaction the owner placed on a message, as read from
// Slack's reactions.list. It is the candidate a poll compares against the
// ledger; the channel id is namespaced (accountID:rawID) like everywhere else.
type OwnerReaction struct {
	AccountID int64
	ChannelID string
	MessageTS string
	Emoji     string
}

// ReactionCommand is one ledger row (reaction_commands) — an owner reaction the
// poll has already seen. A row with a terminal status is never deleted (there
// is no undo, REACT-05); only a provisional row whose dispatch provably
// produced nothing is released (ReleaseReactionCommand) so the next poll
// retries it.
type ReactionCommand struct {
	ID        int64
	AccountID int64
	ChannelID string
	MessageTS string
	Emoji     string
	Status    string
	ActionID  int64
	Error     string
}

// ListReactionCommandMap returns the enabled emoji -> action dictionary, keyed
// by emoji. Disabled rows are omitted so a poll never dispatches them.
func (db *DB) ListReactionCommandMap() (map[string]ReactionCommandMapping, error) {
	rows, err := db.Query(`SELECT emoji, kind, tool, handler_id, enabled
		FROM reaction_command_map WHERE enabled = 1`)
	if err != nil {
		return nil, fmt.Errorf("listing reaction command map: %w", err)
	}
	defer rows.Close()

	out := map[string]ReactionCommandMapping{}
	for rows.Next() {
		var m ReactionCommandMapping
		if err := rows.Scan(&m.Emoji, &m.Kind, &m.Tool, &m.HandlerID, &m.Enabled); err != nil {
			return nil, fmt.Errorf("scanning reaction command mapping: %w", err)
		}
		out[m.Emoji] = m
	}
	return out, rows.Err()
}

// FilterUnseenReactionCommands returns the candidates for one account that are
// NOT already in the ledger, whatever the row's status — a provisional
// (`pending`) row counts as seen too. A candidate whose dispatch fails
// transiently (the AI provider was briefly down) has its provisional row
// released, so the next poll retries it — while a dispatched, terminally
// failed, or still-provisional one is filtered out here forever (REACT-03: a
// command never re-dispatches once its side effect may have happened).
func (db *DB) FilterUnseenReactionCommands(accountID int64, candidates []OwnerReaction) ([]OwnerReaction, error) {
	if len(candidates) == 0 {
		return nil, nil
	}
	rows, err := db.Query(`SELECT channel_id, message_ts, emoji FROM reaction_commands
		WHERE account_id = ?`, accountID)
	if err != nil {
		return nil, fmt.Errorf("loading reaction command ledger: %w", err)
	}
	defer rows.Close()

	seen := map[string]bool{}
	for rows.Next() {
		var ch, ts, emoji string
		if err := rows.Scan(&ch, &ts, &emoji); err != nil {
			return nil, fmt.Errorf("scanning reaction command key: %w", err)
		}
		seen[ch+"\x00"+ts+"\x00"+emoji] = true
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterating reaction command ledger: %w", err)
	}

	var out []OwnerReaction
	for _, c := range candidates {
		if !seen[c.ChannelID+"\x00"+c.MessageTS+"\x00"+c.Emoji] {
			out = append(out, c)
		}
	}
	return out, nil
}

// InsertReactionCommand records a TERMINAL outcome reached without any side
// effect (status skipped — an unmapped emoji, the seed) directly. A dispatch
// that runs compose/Propose goes through ClaimReactionCommand +
// FinalizeReactionCommand instead, so its row exists before the side effect.
// The UNIQUE key still guards a double insert (a re-poll that raced a prior
// insert is a no-op via INSERT OR IGNORE), so this stays idempotent even
// though FilterUnseenReactionCommands already filtered the candidate once.
func (db *DB) InsertReactionCommand(c OwnerReaction, status string, actionID int64, errMsg string) error {
	_, err := db.Exec(`INSERT OR IGNORE INTO reaction_commands
		(account_id, channel_id, message_ts, emoji, status, action_id, error)
		VALUES (?, ?, ?, ?, ?, ?, ?)`,
		c.AccountID, c.ChannelID, c.MessageTS, c.Emoji, status, actionID, errMsg)
	if err != nil {
		return fmt.Errorf("inserting reaction command: %w", err)
	}
	return nil
}

// ClaimReactionCommand writes the provisional ledger row for one command BEFORE
// its dispatch runs any side effect, returning the row id. claimed=false means
// the key is already in the ledger (a concurrent poll — the daemon and a manual
// `reaction-commands poll` — got there first) and the caller must not dispatch.
// Because the row exists before the side effect, a failure anywhere after it
// can at worst strand a provisional row, never re-dispatch the command.
func (db *DB) ClaimReactionCommand(c OwnerReaction) (id int64, claimed bool, err error) {
	res, err := db.Exec(`INSERT OR IGNORE INTO reaction_commands
		(account_id, channel_id, message_ts, emoji, status)
		VALUES (?, ?, ?, ?, ?)`,
		c.AccountID, c.ChannelID, c.MessageTS, c.Emoji, ReactionCommandProvisional)
	if err != nil {
		return 0, false, fmt.Errorf("claiming reaction command: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, false, fmt.Errorf("claiming reaction command: %w", err)
	}
	if n == 0 {
		return 0, false, nil
	}
	id, err = res.LastInsertId()
	if err != nil {
		return 0, false, fmt.Errorf("claiming reaction command: %w", err)
	}
	return id, true, nil
}

// FinalizeReactionCommand replaces a provisional row with the command's
// terminal outcome (dispatched|skipped|failed). It only ever touches a row
// still provisional, so it can never rewrite an outcome already recorded;
// applied=false reports that the row was no longer provisional (a poll failed
// it as stranded while this dispatch was still in flight).
func (db *DB) FinalizeReactionCommand(id int64, status string, actionID int64, errMsg string) (applied bool, err error) {
	res, err := db.Exec(`UPDATE reaction_commands SET status = ?, action_id = ?, error = ?
		WHERE id = ? AND status = ?`, status, actionID, errMsg, id, ReactionCommandProvisional)
	if err != nil {
		return false, fmt.Errorf("finalizing reaction command: %w", err)
	}
	return rowsChanged(res, "finalizing reaction command")
}

// ReleaseReactionCommand deletes a provisional row whose dispatch failed
// TRANSIENTLY before any side effect (compose or Propose never produced an
// action), so the reaction is unseen again and the next poll retries it — the
// only row this ledger ever deletes. A terminal row is never matched, and
// applied=false reports that the row was no longer provisional.
func (db *DB) ReleaseReactionCommand(id int64) (applied bool, err error) {
	res, err := db.Exec(`DELETE FROM reaction_commands WHERE id = ? AND status = ?`,
		id, ReactionCommandProvisional)
	if err != nil {
		return false, fmt.Errorf("releasing reaction command: %w", err)
	}
	return rowsChanged(res, "releasing reaction command")
}

func rowsChanged(res sql.Result, op string) (bool, error) {
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("%s: %w", op, err)
	}
	return n > 0, nil
}

// ReactionAgentActionSince returns the id of the newest agent_actions row a
// reaction dispatch recorded for (contextID, tool) with an id above afterID,
// or 0 when there is none. The reaction pipeline reads it after a failed
// Propose to learn whether that Propose had already recorded its action.
func (db *DB) ReactionAgentActionSince(contextID, tool string, afterID int64) (int64, error) {
	var id int64
	err := db.QueryRow(`SELECT COALESCE(MAX(id), 0) FROM agent_actions
		WHERE surface = 'reaction' AND context_id = ? AND tool = ? AND id > ?`,
		contextID, tool, afterID).Scan(&id)
	if err != nil {
		return 0, fmt.Errorf("looking up reaction agent action: %w", err)
	}
	return id, nil
}

// FailStrandedReactionCommands turns one account's provisional rows created
// before `before` into terminal `failed` rows carrying errMsg, returning the
// rows it changed (with their new status) so the caller can log each. A row is
// stranded when the process died, or a ledger write failed, between the claim
// and the finalize/release — its outcome is unknown (a proposal may exist), so
// it is surfaced rather than retried: re-dispatching could double the effect.
func (db *DB) FailStrandedReactionCommands(accountID int64, before time.Time, errMsg string) ([]ReactionCommand, error) {
	rows, err := db.Query(`UPDATE reaction_commands SET status = 'failed', error = ?
		WHERE account_id = ? AND status = ? AND created_at < ?
		RETURNING id, account_id, channel_id, message_ts, emoji, status, action_id, error`,
		errMsg, accountID, ReactionCommandProvisional, before.UTC().Format("2006-01-02T15:04:05Z"))
	if err != nil {
		return nil, fmt.Errorf("failing stranded reaction commands: %w", err)
	}
	defer rows.Close()

	var out []ReactionCommand
	for rows.Next() {
		var c ReactionCommand
		if err := rows.Scan(&c.ID, &c.AccountID, &c.ChannelID, &c.MessageTS, &c.Emoji, &c.Status, &c.ActionID, &c.Error); err != nil {
			return nil, fmt.Errorf("scanning stranded reaction command: %w", err)
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// ListSyncedJiraProjectKeys returns the distinct Jira project keys across all
// connected sites, sorted. Used as a grounding hint when a reaction command
// composes a create_jira_issue proposal (the model must pick a real project).
func (db *DB) ListSyncedJiraProjectKeys() ([]string, error) {
	rows, err := db.Query(`SELECT DISTINCT project_key FROM jira_sync_state
		WHERE project_key != '' ORDER BY project_key`)
	if err != nil {
		return nil, fmt.Errorf("listing jira project keys: %w", err)
	}
	defer rows.Close()

	var out []string
	for rows.Next() {
		var k string
		if err := rows.Scan(&k); err != nil {
			return nil, fmt.Errorf("scanning jira project key: %w", err)
		}
		out = append(out, k)
	}
	return out, rows.Err()
}

// ListRecentReactionCommands returns the most recent ledger rows, newest first,
// for the CLI to show what the poll has done.
func (db *DB) ListRecentReactionCommands(limit int) ([]ReactionCommand, error) {
	if limit <= 0 {
		limit = 50
	}
	rows, err := db.Query(`SELECT id, account_id, channel_id, message_ts, emoji, status, action_id, error
		FROM reaction_commands ORDER BY id DESC LIMIT ?`, limit)
	if err != nil {
		return nil, fmt.Errorf("listing recent reaction commands: %w", err)
	}
	defer rows.Close()

	var out []ReactionCommand
	for rows.Next() {
		var c ReactionCommand
		if err := rows.Scan(&c.ID, &c.AccountID, &c.ChannelID, &c.MessageTS, &c.Emoji, &c.Status, &c.ActionID, &c.Error); err != nil {
			return nil, fmt.Errorf("scanning reaction command: %w", err)
		}
		out = append(out, c)
	}
	return out, rows.Err()
}
