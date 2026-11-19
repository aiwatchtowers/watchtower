package automations

import (
	"fmt"

	"watchtower/internal/db"
)

// RequireInboxReply refuses a press when a's confirmed recipe does not hold
// inbox:reply: a press runs the confirmed text, and the executor would fail
// a reply run of a snapshot without it. `automations reply` and inbox.act
// (the daemon) both check it before the press.
func RequireInboxReply(database *db.DB, a *db.Automation) error {
	noReply := fmt.Errorf("automation %d no longer reacts to its Inbox buttons (inbox:reply)", a.ID)
	r, err := ConfirmedRecipe(database, a)
	if err != nil {
		return err
	}
	if r == nil {
		return noReply
	}
	m, err := ParseManifest(r.Permissions, r.Outputs, r.Scope)
	if err != nil {
		return fmt.Errorf("automation %d: the confirmed permission manifest does not parse: %w", a.ID, err)
	}
	if _, err := m.AllowInboxReply(); err != nil {
		return noReply
	}
	return nil
}
