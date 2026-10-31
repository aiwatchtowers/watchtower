package relay

import (
	"context"
	"fmt"

	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/relay/relayv1"
)

// PairZoneFor is the zone of a pairing slot (pair/<slot>), named by a
// Control{PairingOpened} detail. It carries only the hello and the keybox: no
// attachments (Save refuses them there).
func (t *Transport) PairZoneFor(slot string) string { return transport.PairZone(slot) }

// SetHubReaders names the phones that may read the hub's data zone (their
// relay_device_ids); the relay replaces the whole set.
func (t *Transport) SetHubReaders(ctx context.Context, phones []string) error {
	if _, err := t.do(ctx, &relayv1.Request{Op: &relayv1.Request_SetHubReaders{SetHubReaders: &relayv1.SetHubReaders{
		PhoneDeviceIds: phones,
	}}}); err != nil {
		return fmt.Errorf("relay: set_hub_readers: %w", err)
	}
	return nil
}
