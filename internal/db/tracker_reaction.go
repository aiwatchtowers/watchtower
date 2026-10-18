package db

import (
	"fmt"
	"strings"
)

// Reads the reaction-commands issue router needs (internal/reactioncmd): which
// tracker a key prefix belongs to, a channel's recent text, and the Linear
// teams a reaction may file into. They read the trackers' own tables, never the
// Slack link table, so the router does not depend on how links are stored.

// TrackerPrefixes is the set of issue-key prefixes each connected tracker owns.
// A prefix may be in both (a Jira project key equal to a Linear team key).
type TrackerPrefixes struct {
	Jira   map[string]bool
	Linear map[string]bool
}

// ReactionTrackerPrefixes returns the Jira project keys (synced projects plus
// the projects of mirrored issues) and the team keys of enabled Linear
// accounts.
func (db *DB) ReactionTrackerPrefixes() (TrackerPrefixes, error) {
	out := TrackerPrefixes{Jira: map[string]bool{}, Linear: map[string]bool{}}
	if err := db.collectKeys(out.Jira, "jira project keys", `
		SELECT project_key FROM jira_sync_state WHERE project_key != ''
		UNION SELECT DISTINCT project_key FROM jira_issues WHERE project_key != ''`); err != nil {
		return TrackerPrefixes{}, err
	}
	if err := db.collectKeys(out.Linear, "linear team keys", `
		SELECT DISTINCT t.key FROM linear_teams t
		JOIN linear_accounts a ON a.id = t.account_id
		WHERE t.key != '' AND a.enabled = 1 AND a.status != 'removed'`); err != nil {
		return TrackerPrefixes{}, err
	}
	return out, nil
}

func (db *DB) collectKeys(into map[string]bool, what, query string) error {
	rows, err := db.Query(query)
	if err != nil {
		return fmt.Errorf("listing %s: %w", what, err)
	}
	defer rows.Close()
	for rows.Next() {
		var k string
		if err := rows.Scan(&k); err != nil {
			return fmt.Errorf("scanning %s: %w", what, err)
		}
		into[strings.ToUpper(k)] = true
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("listing %s: %w", what, err)
	}
	return nil
}

// RecentChannelTexts returns the text of a channel's newest non-deleted
// messages, newest first, at most limit.
func (db *DB) RecentChannelTexts(channelID string, limit int) ([]string, error) {
	rows, err := db.Query(`SELECT text FROM messages
		WHERE channel_id = ? AND is_deleted = 0 AND text != ''
		ORDER BY ts_unix DESC LIMIT ?`, channelID, limit)
	if err != nil {
		return nil, fmt.Errorf("listing recent channel messages: %w", err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var t string
		if err := rows.Scan(&t); err != nil {
			return nil, fmt.Errorf("scanning channel message: %w", err)
		}
		out = append(out, t)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing recent channel messages: %w", err)
	}
	return out, nil
}

// ReactionLinearTeam is one Linear team a reaction may file an issue into.
type ReactionLinearTeam struct {
	AccountID int64
	Key       string
}

// ListReactionLinearTeams returns the selected teams of enabled Linear
// accounts, ordered by key then account — the Linear twin of
// ListSyncedJiraProjectKeys.
func (db *DB) ListReactionLinearTeams() ([]ReactionLinearTeam, error) {
	rows, err := db.Query(`SELECT t.account_id, t.key FROM linear_teams t
		JOIN linear_accounts a ON a.id = t.account_id
		WHERE t.is_selected = 1 AND t.key != '' AND a.enabled = 1 AND a.status != 'removed'
		ORDER BY t.key, t.account_id`)
	if err != nil {
		return nil, fmt.Errorf("listing linear teams: %w", err)
	}
	defer rows.Close()
	var out []ReactionLinearTeam
	for rows.Next() {
		var t ReactionLinearTeam
		if err := rows.Scan(&t.AccountID, &t.Key); err != nil {
			return nil, fmt.Errorf("scanning linear team: %w", err)
		}
		out = append(out, t)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing linear teams: %w", err)
	}
	return out, nil
}
