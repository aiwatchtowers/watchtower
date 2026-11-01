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

// zone is a runtime zone name resolved: its CloudKit zone (ck) and the one
// runtime name its feed has (name) — what Stored.Zone and Event.Zone carry.
type zone struct {
	ck, name string
	mailbox  bool
}

// zone resolves a runtime zone name. The hub's data zone data/<relay id> is
// DataZone-<hub_id>; the shared mailbox relay/<relay id>/* and every phone's
// mailbox relay/<relay id>/<phone> are the one RelayZone-<hub_id>, whose feed
// is named the shared mailbox (records read through a phone's name come back
// stamped with the shared name). Another hub's zone, a pairing zone, a
// CloudKit zone name and anything else are transport.ErrUnsupportedZone:
// linking on CloudKit runs over shares.
func (c *Client) zone(name string) (zone, error) {
	rid, hub := c.c.RelayID, c.c.HubID
	if rid != "" && hub != "" {
		mbox := transport.SharedMailboxZone(rid)
		switch {
		case name == transport.DataZone(rid):
			return zone{ck: DataZoneName(hub), name: name}, nil
		case name == mbox || isPhoneMailbox(name, rid):
			return zone{ck: RelayZoneName(hub), name: mbox, mailbox: true}, nil
		}
	}
	return zone{}, fmt.Errorf("cloudkit: zone %q: %w", zoneClass(name), transport.ErrUnsupportedZone)
}

// runtimeName is the runtime name of one of the hub's CloudKit zones.
func (c *Client) runtimeName(ck string) (string, bool) {
	switch ck {
	case DataZoneName(c.c.HubID):
		return transport.DataZone(c.c.RelayID), true
	case RelayZoneName(c.c.HubID):
		return transport.SharedMailboxZone(c.c.RelayID), true
	}
	return "", false
}

// isPhoneMailbox: name is relay/<rid>/<phone> with one non-empty phone part.
func isPhoneMailbox(name, rid string) bool {
	phone, ok := strings.CutPrefix(name, transport.MailboxZone(rid, ""))
	return ok && phone != "" && phone != "*" && !strings.Contains(phone, "/")
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
