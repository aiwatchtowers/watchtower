package relayv1

import (
	"errors"
	"fmt"
	"strings"
)

// ZoneKind identifies the kind of a zone name.
type ZoneKind int

const (
	ZoneData    ZoneKind = iota + 1 // data/<hub_id>
	ZoneMailbox                     // relay/<hub_id>/<phone_device_id>
	ZonePair                        // pair/<slot_id>
)

// ErrInvalidZone is returned by ParseZone for malformed zone names.
var ErrInvalidZone = errors.New("invalid zone name")

// DataZone builds the data zone name. hubID is the Mac's relay_device_id.
func DataZone(hubID string) string { return "data/" + hubID }

// MailboxZone builds the phone mailbox zone name.
func MailboxZone(hubID, phoneID string) string { return "relay/" + hubID + "/" + phoneID }

// PairZone builds the pairing zone name.
func PairZone(slotID string) string { return "pair/" + slotID }

// ParseZone returns the zone kind and its ids: [hubID] for ZoneData,
// [hubID, phoneID] for ZoneMailbox, [slotID] for ZonePair.
func ParseZone(zone string) (ZoneKind, []string, error) {
	parts := strings.Split(zone, "/")
	var kind ZoneKind
	var want int
	switch parts[0] {
	case "data":
		kind, want = ZoneData, 1
	case "relay":
		kind, want = ZoneMailbox, 2
	case "pair":
		kind, want = ZonePair, 1
	default:
		return 0, nil, fmt.Errorf("%w: %q", ErrInvalidZone, zone)
	}
	ids := parts[1:]
	if len(ids) != want {
		return 0, nil, fmt.Errorf("%w: %q", ErrInvalidZone, zone)
	}
	for _, id := range ids {
		if id == "" {
			return 0, nil, fmt.Errorf("%w: %q", ErrInvalidZone, zone)
		}
	}
	return kind, ids, nil
}
