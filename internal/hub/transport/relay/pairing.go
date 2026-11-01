package relay

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"

	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/relay/client"
	"watchtower/internal/hub/transport/relay/relayv1"
)

// PairZoneFor is the zone of a pairing slot (pair/<slot>), named by a
// Control{PairingOpened} detail. It carries only the hello and the keybox: no
// attachments (Save refuses them there).
func (t *Transport) PairZoneFor(slot string) string { return transport.PairZone(slot) }

// WatchPairZone subscribes the pairing slot's zone, so the phone's hello —
// which may be written after PAIRING_OPENED arrives — comes as a zone event.
// The relay client has no unsubscribe: the zone stays subscribed for the
// connection, and after the slot expires a resubscribe refuses it and the
// client drops it (a zone error event). While disconnected the zone is
// subscribed on the next connect; nil then. An error before Connect.
func (t *Transport) WatchPairZone(ctx context.Context, slot string) error {
	if slot == "" || strings.Contains(slot, "/") {
		return errors.New("relay: not a pairing slot id")
	}
	t.mu.Lock()
	conn := t.conn
	t.mu.Unlock()
	if conn == nil {
		return errors.New("relay: watching a pair zone before Connect")
	}
	if err := conn.Subscribe(ctx, transport.PairZone(slot)); err != nil && !errors.Is(err, client.ErrDisconnected) {
		return fmt.Errorf("relay: subscribe pair zone: %w", MapError(err))
	}
	return nil
}

// WatchZone subscribes a mailbox zone of a phone linked after Connect
// (Connect subscribes the zones it was given), so its records come as zone
// events; the subscription is renewed after every reconnect. While
// disconnected it is subscribed on the next connect; nil then. An error
// before Connect.
func (t *Transport) WatchZone(ctx context.Context, zone string) error {
	if zone == "" || isPairZone(zone) {
		return errors.New("relay: not a mailbox or data zone")
	}
	t.mu.Lock()
	conn := t.conn
	t.mu.Unlock()
	if conn == nil {
		return errors.New("relay: watching a zone before Connect")
	}
	if err := conn.Subscribe(ctx, zone); err != nil && !errors.Is(err, client.ErrDisconnected) {
		return fmt.Errorf("relay: subscribe zone: %w", MapError(err))
	}
	return nil
}

// SetHubReaders names the phones that may read the hub's data zone (their
// relay_device_ids); the relay replaces the whole set, and refuses all of it
// (FORBIDDEN) when one phone does not hold the hub in a slot.
func (t *Transport) SetHubReaders(ctx context.Context, phones []string) error {
	if _, err := t.do(ctx, &relayv1.Request{Op: &relayv1.Request_SetHubReaders{SetHubReaders: &relayv1.SetHubReaders{
		PhoneDeviceIds: phones,
	}}}); err != nil {
		return fmt.Errorf("relay: set_hub_readers: %w", err)
	}
	return nil
}

// SetLinkedReaders is link.Center.SyncReaders' setter on the hosted relay:
// it reads a fresh account state and sends the linked phones that hold the
// hub in a slot, sorted. A linked phone not slotted yet (confirmed on the
// hub, promote_pairing still to come) or no longer (its slot removed) is left
// out, so it never makes the relay refuse the whole set; the next sync after
// its promotion adds it. Nothing is sent when the account state cannot be
// read.
func (t *Transport) SetLinkedReaders(ctx context.Context, linked []string) error {
	st, err := t.AccountState(ctx)
	if err != nil {
		return fmt.Errorf("relay: readers: account state: %w", err)
	}
	return t.SetReadersFrom(ctx, st, linked)
}

// SetReadersFrom is SetLinkedReaders over an account state the caller read
// (the hub runtime reads it through its one account-state door).
func (t *Transport) SetReadersFrom(ctx context.Context, st *relayv1.AccountState, linked []string) error {
	slotted := map[string]bool{}
	for _, p := range st.GetPhones() {
		slotted[p.GetPhoneDeviceId()] = true
	}
	readers := make([]string, 0, len(linked))
	for _, id := range linked {
		if slotted[id] && !slices.Contains(readers, id) {
			readers = append(readers, id)
		}
	}
	slices.Sort(readers)
	return t.SetHubReaders(ctx, readers)
}
