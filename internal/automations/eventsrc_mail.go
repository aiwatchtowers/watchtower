package automations

import (
	"context"
	"fmt"

	"watchtower/internal/db"
)

// MailNewMessages is the event type of a mail account's sync, Gmail or IMAP
// alike (phaseGmailSync, phaseImapSync).
const MailNewMessages = "gmail.new_messages"

// MailSource is the event source of one mail account's syncer: provider is
// "gmail" or "imap". After the syncer it counts the account's stored
// messages dated after the news floor read before it — the later of the
// account's connect time and its newest stored message — so a capped first
// sync's backlog drained over later cycles, and known mail re-synced after an
// IMAP UIDVALIDITY change, are never news. The account's first sync (its
// watermark unset before the syncer) publishes nothing.
func MailSource(d *db.DB, provider string, accountID int64) EventSource {
	return mailSource{d: d, provider: provider, accountID: accountID}
}

type mailSource struct {
	d         *db.DB
	provider  string
	accountID int64
}

func (mailSource) Type() string { return MailNewMessages }

func (s mailSource) Before(ctx context.Context) (EventDiff, error) {
	if err := ctx.Err(); err != nil {
		return nil, fmt.Errorf("snapshotting %s mail: %w", s.provider, err)
	}
	synced, err := s.d.MailWatermarkSet(s.provider, s.accountID)
	if err != nil {
		return nil, fmt.Errorf("snapshotting %s mail: %w", s.provider, err)
	}
	if !synced {
		return noEvents{}, nil
	}
	floor, err := s.d.MailNewsFloor(s.provider, s.accountID)
	if err != nil {
		return nil, fmt.Errorf("snapshotting %s mail: %w", s.provider, err)
	}
	return mailDiff{mailSource: s, floor: floor}, nil
}

// noEvents is a diff that publishes nothing.
type noEvents struct{}

func (noEvents) After(context.Context) ([]Event, error) { return nil, nil }

type mailDiff struct {
	mailSource
	floor string
}

func (m mailDiff) After(context.Context) ([]Event, error) {
	n, err := m.d.CountMailAfter(m.provider, m.accountID, m.floor)
	if err != nil {
		return nil, fmt.Errorf("diffing %s mail: %w", m.provider, err)
	}
	e, ok, err := mailEvent(m.d, m.provider, m.accountID, n)
	if err != nil || !ok {
		return nil, err
	}
	return []Event{e}, nil
}

// mailEvent builds the gmail.new_messages event for one mail account's sync:
// provider is "gmail" or "imap", account its label (else its address), count
// the new messages. A count of 0 is no event.
func mailEvent(d *db.DB, provider string, accountID int64, count int) (Event, bool, error) {
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
