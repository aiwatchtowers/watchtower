package cloudkit

import (
	"fmt"
	"strings"

	"watchtower/internal/hub/transport"
)

// DataZoneName is the hub's CloudKit data zone (the Kit's HubZones).
func DataZoneName(hubID string) string { return "DataZone-" + hubID }

// RelayZoneName is the hub's CloudKit relay zone: every phone's mailbox.
func RelayZoneName(hubID string) string { return "RelayZone-" + hubID }

// zoneName maps a hub zone name onto the hub's CloudKit zone: data/<x> and
// DataZoneName(hubID) are the data zone, relay/<x>/<y> and
// RelayZoneName(hubID) the one relay zone every phone shares. A pairing
// zone, another hub's zone and anything else are
// transport.ErrUnsupportedZone: linking on CloudKit runs over shares.
func zoneName(hubID, zone string) (string, error) {
	data, relay := DataZoneName(hubID), RelayZoneName(hubID)
	switch {
	case hubID == "":
	case zone == data, zone == relay:
		return zone, nil
	case segments(zone, "data/", 1): // transport.DataZone
		return data, nil
	case segments(zone, "relay/", 2): // transport.MailboxZone
		return relay, nil
	}
	return "", fmt.Errorf("cloudkit: zone %q: %w", zoneClass(zone), transport.ErrUnsupportedZone)
}

// segments: zone is prefix followed by n non-empty segments split by '/'.
func segments(zone, prefix string, n int) bool {
	rest, ok := strings.CutPrefix(zone, prefix)
	if !ok {
		return false
	}
	parts := strings.Split(rest, "/")
	if len(parts) != n {
		return false
	}
	for _, p := range parts {
		if p == "" {
			return false
		}
	}
	return true
}

// zoneClass is a zone's first segment, safe to put in an error (FILES-01:
// ids and classes only).
func zoneClass(zone string) string {
	head, _, _ := strings.Cut(zone, "/")
	head, _, _ = strings.Cut(head, "-")
	if len(head) > 16 {
		head = head[:16]
	}
	return head
}
