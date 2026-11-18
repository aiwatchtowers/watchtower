package db

import (
	"errors"
	"fmt"
	"time"

	"watchtower/internal/sqlcipher"
)

// ErrSetupExists refuses a second setup record for a team: one setup per team.
var ErrSetupExists = errors.New("a Slack app setup already exists for this workspace")

// SlackAppSetup is one row of slack_app_setups — a team whose own Slack app
// this install set up (`slack app create|adopt`). "Connected" is derived from
// an ok slack_accounts row with the same client id, never stored (A5).
type SlackAppSetup struct {
	TeamID      string
	TeamName    string
	AppID       string
	ClientID    string
	LinkWritten bool // the connect link is on the app's About page
	// InstallRequestedAt is the RFC 3339 UTC time Slack reported an admin
	// approval request; "" = none.
	InstallRequestedAt string
	CreatedAt          string
	UpdatedAt          string
}

const slackAppSetupColumns = `team_id, team_name, app_id, client_id, link_written,
        install_requested_at, created_at, updated_at`

func scanSlackAppSetup(scanner interface{ Scan(dest ...any) error }) (SlackAppSetup, error) {
	var s SlackAppSetup
	err := scanner.Scan(&s.TeamID, &s.TeamName, &s.AppID, &s.ClientID, &s.LinkWritten,
		&s.InstallRequestedAt, &s.CreatedAt, &s.UpdatedAt)
	return s, err
}

// InsertSlackAppSetup records a new setup; a team that already has one is
// refused with ErrSetupExists and its row is left as it was.
func (db *DB) InsertSlackAppSetup(s SlackAppSetup) error {
	now := time.Now().UTC().Format(time.RFC3339)
	_, err := db.Exec(`INSERT INTO slack_app_setups (`+slackAppSetupColumns+`)
        VALUES (?,?,?,?,?,?,?,?)`,
		s.TeamID, s.TeamName, s.AppID, s.ClientID, s.LinkWritten, s.InstallRequestedAt, now, now)
	if err != nil {
		var se sqlcipher.Error
		if errors.As(err, &se) && se.ExtendedCode == sqlcipher.ErrConstraintPrimaryKey {
			return fmt.Errorf("slack app setup for %s: %w", s.TeamID, ErrSetupExists)
		}
		return fmt.Errorf("inserting slack app setup for %s: %w", s.TeamID, err)
	}
	return nil
}

// GetSlackAppSetup returns team's setup; a missing one wraps sql.ErrNoRows.
func (db *DB) GetSlackAppSetup(team string) (SlackAppSetup, error) {
	s, err := scanSlackAppSetup(db.QueryRow(`SELECT `+slackAppSetupColumns+` FROM slack_app_setups WHERE team_id = ?`, team))
	if err != nil {
		return SlackAppSetup{}, fmt.Errorf("getting slack app setup for %s: %w", team, err)
	}
	return s, nil
}

// ListSlackAppSetups returns every setup in insertion order (created_at has
// one-second precision, so rowid breaks ties).
func (db *DB) ListSlackAppSetups() ([]SlackAppSetup, error) {
	rows, err := db.Query(`SELECT ` + slackAppSetupColumns + ` FROM slack_app_setups ORDER BY created_at, rowid`)
	if err != nil {
		return nil, fmt.Errorf("listing slack app setups: %w", err)
	}
	defer rows.Close()
	var out []SlackAppSetup
	for rows.Next() {
		s, err := scanSlackAppSetup(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning slack app setup: %w", err)
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// SetSlackAppSetupLinkWritten marks team's connect link as written to the
// app's About page.
func (db *DB) SetSlackAppSetupLinkWritten(team string) error {
	return db.updateSlackAppSetup(team, `link_written = 1`)
}

// SetSlackAppSetupInstallRequested records when Slack reported an admin
// approval request for team's app; the zero time clears it.
func (db *DB) SetSlackAppSetupInstallRequested(team string, at time.Time) error {
	stamp := ""
	if !at.IsZero() {
		stamp = at.UTC().Format(time.RFC3339)
	}
	return db.updateSlackAppSetup(team, `install_requested_at = ?`, stamp)
}

// updateSlackAppSetup applies set (a fixed SET fragment) to team's row and
// stamps updated_at; a missing row is an error.
func (db *DB) updateSlackAppSetup(team, set string, args ...any) error {
	args = append(args, time.Now().UTC().Format(time.RFC3339), team)
	res, err := db.Exec(`UPDATE slack_app_setups SET `+set+`, updated_at = ? WHERE team_id = ?`, args...)
	if err != nil {
		return fmt.Errorf("updating slack app setup for %s: %w", team, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("updating slack app setup: no slack_app_setups row %s", team)
	}
	return nil
}
