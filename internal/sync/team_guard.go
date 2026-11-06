package sync

import (
	"errors"
	"fmt"

	"watchtower/internal/db"
)

// ErrSlackTeamMismatch is matched (errors.Is) by every TeamMismatchError.
var ErrSlackTeamMismatch = errors.New("slack token is for another team than the account's data")

// TeamMismatchError is a sync refused because the account's token (or the
// team.info it answers) belongs to another Slack team than the data the
// account already holds (#915): syncing it would mix two teams under one
// "<accountID>:" namespace, and an empty search on the wrong team would still
// move the search watermark past days that were never fetched. Error() names
// ids only (FILES-01); OwnerMessage is what the account row shows.
type TeamMismatchError struct {
	AccountID int64
	Home      db.SlackHomeTeam
	TeamID    string
	TeamName  string
}

func (e *TeamMismatchError) Error() string {
	return fmt.Sprintf("slack account %d: signed in to team %s, but its data belongs to team %s; Re-login required",
		e.AccountID, e.TeamID, e.Home.ID)
}

// Is makes errors.Is(err, ErrSlackTeamMismatch) hold.
func (e *TeamMismatchError) Is(target error) bool { return target == ErrSlackTeamMismatch }

// OwnerMessage is the account row's error text, read in the Desktop's
// Connections banner.
func (e *TeamMismatchError) OwnerMessage() string {
	got := e.TeamName
	if got == "" {
		got = e.TeamID
	}
	return fmt.Sprintf("Signed in to a different Slack workspace (%s) — Re-login to %s", got, e.Home.DisplayName())
}

// checkHomeTeam refuses teamID, and the token file's team (SetTokenTeam),
// when acct's stored data belongs to another team (db.SlackAccountHomeTeam).
// Every sync path calls it before its first write: ensureWorkspace (cached or
// first-run team), syncMetadata (the full sync's team.info) and
// BackfillSearch. For an account whose home team is its own row (every
// account but a legacy #1) the row check alone cannot fail; the token team
// and the full sync's team.info are what can.
func (o *Orchestrator) checkHomeTeam(acct db.SlackAccount, teamID, teamName string) error {
	home, err := o.db.SlackAccountHomeTeam(acct)
	if err != nil {
		return err
	}
	if home.Conflicts(teamID) {
		return &TeamMismatchError{AccountID: o.accountID, Home: home, TeamID: teamID, TeamName: teamName}
	}
	if home.Conflicts(o.tokenTeamID) {
		return &TeamMismatchError{AccountID: o.accountID, Home: home, TeamID: o.tokenTeamID}
	}
	return nil
}

// ownerErrorText is err's text for the account row: a team mismatch's owner
// message, anything else as it is.
func ownerErrorText(err error) string {
	var mismatch *TeamMismatchError
	if errors.As(err, &mismatch) {
		return mismatch.OwnerMessage()
	}
	return err.Error()
}
