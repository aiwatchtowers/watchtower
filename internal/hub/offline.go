package hub

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"time"

	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/link"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
)

// The link changes a CLI makes while no hub runs (`hub unlink`, `hub allow`
// with the hub lock in hand): the same link.Center decisions the running
// hub makes, over the caller's store. Their device_grant records are
// published by the next hub start, which publishes from the sidecar.

// ErrIdentityMissing is returned when the dir has a linked phone but no hub
// identity, so its epoch cannot rotate offline; the hub has to run first.
var ErrIdentityMissing = errors.New("hub: no hub identity in this dir: start the hub to unlink the phone")

// UnlinkOffline removes a linked phone (rotating the epoch) or refuses one
// that waits for the owner, as the running hub's unlink does. The caller
// holds the hub lock. state.ErrNoDevice when there is no such phone.
func UnlinkOffline(dir string, st *state.Store, device string, clock func() time.Time) error {
	if clock == nil {
		clock = time.Now
	}
	fs := identity.FileStore{Path: filepath.Join(dir, identity.FileName)}
	id, err := fs.Load()
	if errors.Is(err, identity.ErrNoIdentity) {
		if _, ok, derr := st.Device(device); derr != nil {
			return derr
		} else if ok {
			return ErrIdentityMissing
		}
		return state.ErrNoDevice
	}
	if err != nil {
		return fmt.Errorf("hub: reading the identity: %w", err)
	}
	defer id.Zero()
	kr, err := identity.NewKeyring(id, st, clock)
	if err != nil {
		return fmt.Errorf("hub: opening the keyring: %w", err)
	}
	defer kr.Wipe()
	return link.NewCenter(link.Config{Store: st, Keys: kr, Clock: clock}).Unlink(device)
}

// AllowOffline sets one grant of a linked phone, as the running hub's allow
// does. The caller holds the hub lock.
func AllowOffline(st *state.Store, device string, g link.Grant, on bool, clock func() time.Time) error {
	return link.NewCenter(link.Config{Store: st, Clock: clock}).Allow(device, g, on)
}

// WithTransport returns o with fn building the hub's transport in place of
// the hosted relay: the seam other packages' tests (cmd's CLI tests over
// memfake) run a real Run through. Production never calls it.
func (o Options) WithTransport(fn func(ctx context.Context, id identity.Identity, st *state.Store, zones []string) (transport.Transport, error)) Options {
	o.newTransport = fn
	return o
}
