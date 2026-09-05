package db

import "fmt"

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
// poll has already seen. Rows are never deleted (there is no undo, REACT-05).
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

// RecordNewReactionCommands inserts each candidate into the ledger and returns
// ONLY the ones that were newly recorded (status 'pending'). The UNIQUE key
// makes this the idempotency guard (REACT-03): a candidate already in the
// ledger inserts nothing and is not returned, so re-polling reactions.list
// never re-dispatches a command already seen.
func (db *DB) RecordNewReactionCommands(candidates []OwnerReaction) ([]ReactionCommand, error) {
	if len(candidates) == 0 {
		return nil, nil
	}
	tx, err := db.Begin()
	if err != nil {
		return nil, fmt.Errorf("begin reaction command insert: %w", err)
	}
	defer tx.Rollback()

	var fresh []ReactionCommand
	for _, c := range candidates {
		res, err := tx.Exec(`INSERT OR IGNORE INTO reaction_commands
			(account_id, channel_id, message_ts, emoji) VALUES (?, ?, ?, ?)`,
			c.AccountID, c.ChannelID, c.MessageTS, c.Emoji)
		if err != nil {
			return nil, fmt.Errorf("inserting reaction command: %w", err)
		}
		n, err := res.RowsAffected()
		if err != nil {
			return nil, fmt.Errorf("reaction command rows affected: %w", err)
		}
		if n == 0 {
			continue // already in the ledger — idempotent skip
		}
		id, err := res.LastInsertId()
		if err != nil {
			return nil, fmt.Errorf("reaction command last insert id: %w", err)
		}
		fresh = append(fresh, ReactionCommand{
			ID: id, AccountID: c.AccountID, ChannelID: c.ChannelID,
			MessageTS: c.MessageTS, Emoji: c.Emoji, Status: "pending",
		})
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("commit reaction command insert: %w", err)
	}
	return fresh, nil
}

// MarkReactionCommandDispatched records that the command produced an
// agent-action (the proposal row, or an applied row under execute trust).
func (db *DB) MarkReactionCommandDispatched(id, actionID int64) error {
	_, err := db.Exec(`UPDATE reaction_commands SET status = 'dispatched', action_id = ?
		WHERE id = ?`, actionID, id)
	if err != nil {
		return fmt.Errorf("marking reaction command dispatched: %w", err)
	}
	return nil
}

// MarkReactionCommandFailed records that dispatch failed. The row stays in the
// ledger (never retried automatically — there is no undo/redo channel), so a
// transient failure is not re-attempted every poll; the owner re-reacts to try
// again only after the row is cleared, which v1 does not expose.
func (db *DB) MarkReactionCommandFailed(id int64, reason string) error {
	_, err := db.Exec(`UPDATE reaction_commands SET status = 'failed', error = ?
		WHERE id = ?`, reason, id)
	if err != nil {
		return fmt.Errorf("marking reaction command failed: %w", err)
	}
	return nil
}

// MarkReactionCommandSkipped records a command that matched no enabled mapping
// or could not be built (missing context). It stays skipped, not retried.
func (db *DB) MarkReactionCommandSkipped(id int64, reason string) error {
	_, err := db.Exec(`UPDATE reaction_commands SET status = 'skipped', error = ?
		WHERE id = ?`, reason, id)
	if err != nil {
		return fmt.Errorf("marking reaction command skipped: %w", err)
	}
	return nil
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
