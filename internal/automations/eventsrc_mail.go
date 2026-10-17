package automations

import (
	"fmt"

	"watchtower/internal/db"
)

// MailNewMessages is the event type of a mail account's sync, Gmail or IMAP
// alike (phaseGmailSync, phaseImapSync).
const MailNewMessages = "gmail.new_messages"

// MailEvent builds the gmail.new_messages event for one mail account's sync:
// provider is "gmail" or "imap", account its label (else its address), count
// the messages the sync stored. A count of 0 is no event. The caller
// publishes only when db.MailWatermarkSet held before the syncer ran — an
// account's initial backfill is not news.
func MailEvent(d *db.DB, provider string, accountID int64, count int) (Event, bool, error) {
	if count <= 0 {
		return Event{}, false, nil
	}
	label, err := d.MailEventLabel(provider, accountID)
	if err != nil {
		return Event{}, false, fmt.Errorf("building mail event: %w", err)
	}
	return Event{Type: MailNewMessages, Fields: map[string]any{
		"account": label, "provider": provider, "count": count,
	}}, true, nil
}
