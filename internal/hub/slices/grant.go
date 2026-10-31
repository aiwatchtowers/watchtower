package slices

import (
	"context"
	"fmt"

	"watchtower/internal/hub/link"
	"watchtower/internal/hub/wire"
)

// GrantSource is the device_grant slice over the link center (the Swift
// DeviceGrantSlice): one keybox per phone the hub answers, record
// device_grant-<device id>, sealed to that phone under keybox-<id>. Each
// grant carries the transports as the center's HostInfo says (the runtime
// pins them). Items calls Center.Keyboxes, which takes the center's lock:
// never call it from inside a center method (the center's Publish callback
// runs after its lock is released, and PublishSoon only marks kinds dirty).
func GrantSource(c *link.Center) Source { return grantSource{c: c} }

type grantSource struct{ c *link.Center }

func (grantSource) Kind() Kind { return KindDeviceGrant }

func (g grantSource) Items(context.Context) ([]Item, error) {
	boxes, err := g.c.Keyboxes()
	if err != nil {
		return nil, err
	}
	out := make([]Item, 0, len(boxes))
	for _, kb := range boxes {
		payload, err := wire.Marshal(kb)
		if err != nil {
			for _, it := range out {
				clear(it.Payload)
			}
			return nil, fmt.Errorf("slices: encoding a keybox: %w", err)
		}
		out = append(out, Item{ID: kb.Grant.DeviceID, Payload: payload})
	}
	return out, nil
}
