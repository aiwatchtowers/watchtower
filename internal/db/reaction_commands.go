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

// FilterUnseenReactionCommands returns the candidates for one account that are
// NOT already in the ledger. Recording is deferred to InsertReactionCommand on
// a TERMINAL outcome, so a candidate whose dispatch fails transiently (the AI
// provider was briefly down) is never recorded and the next poll retries it —
// while a dispatched or terminally-failed one stays recorded and is filtered
// out here forever (REACT-03: a succeeded command never re-dispatches).
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

// InsertReactionCommand records one command's TERMINAL outcome in the ledger
// (status dispatched|skipped|failed). The UNIQUE key still guards a double
// insert (a re-poll that raced a prior insert is a no-op via INSERT OR IGNORE),
// so this stays idempotent even though FilterUnseenReactionCommands already
// filtered the candidate once.
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
