package db

import (
	"database/sql"
	"fmt"
	"strconv"
	"time"
)

// SlackHomeTeam is the Slack team whose data a slack_accounts row holds: the
// only team a sign-in or a sync of that account may use, since every id it
// stores is namespaced by the account, not the team ("<accountID>:<rawID>").
// ID "" means the account has no team yet (a new or offline-seeded row) and
// accepts any team.
type SlackHomeTeam struct {
	ID   string
	Name string
}

// Conflicts reports whether a sign-in or a token for teamID would put another
// team's data under this account. An empty home or an unknown teamID never
// conflicts.
func (h SlackHomeTeam) Conflicts(teamID string) bool {
	return h.ID != "" && teamID != "" && h.ID != teamID
}

// DisplayName is the team's name, or its id when the name is unknown.
func (h SlackHomeTeam) DisplayName() string {
	if h.Name != "" {
		return h.Name
	}
	return h.ID
}

// SlackAccountHomeTeam returns the team acct's stored data belongs to.
//
// No per-message or per-channel column records a team, and the row's own
// team_id is rewritten by every sign-in (a Re-login into the wrong team
// overwrote it before #915), so the row alone cannot prove where the data
// came from. Account #1 of an install that predates multi-account Slack has a
// better witness: the legacy workspace singleton, seeded by the old single-team
// sync, copied into account #1 by migration 00048 and frozen since (no code
// writes workspace.id any more). It wins when present. Every other account —
// and account #1 of a newer install, which has no workspace row — falls back
// to the row's team_id, which sign-ins can no longer move to another team.
func (db *DB) SlackAccountHomeTeam(acct SlackAccount) (SlackHomeTeam, error) {
	if acct.ID == 1 {
		ws, err := db.GetWorkspace()
		if err != nil {
			return SlackHomeTeam{}, fmt.Errorf("reading the legacy workspace of slack account 1: %w", err)
		}
		if ws != nil && ws.ID != "" {
			return SlackHomeTeam{ID: ws.ID, Name: ws.Name}, nil
		}
	}
	return SlackHomeTeam{ID: acct.TeamID, Name: acct.TeamName}, nil
}

// LatestSlackMessageTime returns the post time of accountID's newest stored
// message; ok is false when the account holds none.
func (db *DB) LatestSlackMessageTime(accountID int64) (time.Time, bool, error) {
	prefix := strconv.FormatInt(accountID, 10)
	var ts sql.NullFloat64
	err := db.QueryRow(`SELECT MAX(ts_unix) FROM messages WHERE channel_id >= ? AND channel_id < ?`,
		prefix+":", prefix+";").Scan(&ts)
	if err != nil {
		return time.Time{}, false, fmt.Errorf("reading the newest message of slack account %d: %w", accountID, err)
	}
	if !ts.Valid {
		return time.Time{}, false, nil
	}
	return time.Unix(int64(ts.Float64), 0), true, nil
}
