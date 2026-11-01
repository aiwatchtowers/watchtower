// Package switcher is the hub's dual transport and the transport switch
// (relay sim rules 8–13, relay client spec §9, Go hub spec §9; phase 3
// plan Task 18). A desktop host runs one action processor per transport over
// one sidecar: the active transport's applies the phones' actions, the
// other's is polled every OtherPoll for the phones' controls (a switch back,
// an epoch_ack) and answers a phone that wrote there without following
// (sim rule 12a, actions/standby.go).
//
// Only a person switches (rule 8): a phone's transport_switch, or the relay
// entitlement lapsing (by = "entitlement_expired"); a transport failure
// never does. Toward the relay a switch is accepted at least AntiFlap after
// the previous accepted one; toward CloudKit always and at once (rules
// 9–10). The last accepted request wins.
//
// An accepted switch (rule 11; Step) runs in this order, each step durable
// in hub_meta so a restart finishes the same switch and never rotates twice:
//  1. every phone's mailbox on the old transport is finished in the old
//     epoch if it answers within OldSideTimeout (never waiting on an
//     unreachable one);
//  2. the epoch rotates once (identity.ReasonTransportSwitch);
//  3. transport_switched{target, epoch, by, at, keybox} is queued for every
//     phone on both transports (one control id, two copies), the copy on the
//     old transport sealed in the old epoch; toward the relay, hub_on_relay
//     to the CloudKit mailbox of every ordered phone that does not pay;
//     hub_meta.transport moves in the same transaction;
//  4. the old transport's queue is flushed and its data zone gets the
//     transport marker sealed in the old epoch (phone contract point 6a),
//     both before the hub stops publishing there; the relay's data zone
//     always gets the marker (point 4), in the new epoch when the relay is
//     the new transport;
//  5. the new transport becomes the one actions are applied from (its
//     mailboxes are read from the start, so what waited there on standby is
//     read now) and the publisher's next cycle is one full diff there.
//
// A notice or a marker that could not be written stays owed: the queue rows
// are retried by every pass of their processor, the markers by Run.
package switcher

import (
	"context"
	"errors"
	"fmt"
	"log"
	"sync"
	"time"

	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/slices"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

const (
	// AntiFlap is the least time between an accepted switch and the next
	// one toward the relay (rule 9).
	AntiFlap = 5 * time.Minute
	// OtherPoll is how often Run polls the inactive transport's mailboxes
	// (rule 11) and retries the owed markers.
	OtherPoll = 30 * time.Second
	// OldSideTimeout bounds every call into the transport the hub leaves or
	// does not run on, so an unreachable one never holds a switch up.
	OldSideTimeout = 10 * time.Second
)

// hub_meta keys: the active transport ("cloudkit"|"relay"), the last accepted
// switch's time (seconds since 1970 as a decimal string, like enabled_at)
// and who asked (a device id or wire.SwitchedByEntitlement), and the switch
// record (switchRecord, JSON).
const (
	MetaTransport  = "transport"
	MetaSwitchedAt = "switched_at"
	MetaSwitchedBy = "switched_by"
	metaSwitch     = "transport_switch"
)

// Config wires a Switcher. Relay may be nil (a desktop host without a relay
// origin: CloudKit only, every switch toward the relay rejected). Actions is
// the processors' template: the switcher sets Transport and Switch per
// transport. Publisher (optional) is paused across a switch and resumed on
// the new transport (a full diff); it publishes on Front(). Keyboxes is the
// link center's (the payload of each linked phone's keybox, the bytes the
// data zone's keybox carries). Paying (optional) is which linked phones pay
// for the relay, by device id. Clock defaults to Actions.Clock, then
// time.Now.
type Config struct {
	Store           *state.Store
	Keys            *identity.Keyring
	Relay, CloudKit transport.Transport
	Actions         actions.Config
	Publisher       *slices.Publisher
	Keyboxes        func() ([]wire.Keybox, error)
	Paying          func(ctx context.Context) (map[string]bool, error)
	Clock           func() time.Time
}

// Switcher is the hub's dual transport. Request and Stale are called from
// inside a processor's pass and never call into a processor; Step, Run and
// the processors' passes may run concurrently.
type Switcher struct {
	c      Config
	sealer *secure.Sealer
	data   string
	procs  map[transport.Kind]*actions.Processor
	kick   chan struct{}

	stepMu sync.Mutex // one Step at a time

	mu     sync.Mutex // guards active and every read-modify-write of the switch record
	active transport.Kind
}

var _ actions.Switch = (*Switcher)(nil)

// New builds the switcher and its processors; the active transport is
// hub_meta.transport (CloudKit when unset, the relay on a hub with no
// CloudKit side).
func New(c Config) (*Switcher, error) {
	if c.CloudKit == nil && c.Relay == nil {
		return nil, errors.New("switcher: no transport")
	}
	if c.Clock == nil {
		c.Clock = c.Actions.Clock
	}
	if c.Clock == nil {
		c.Clock = time.Now
	}
	s := &Switcher{
		c: c, sealer: c.Actions.Sealer, data: transport.DataZone(c.Actions.HubRelayID),
		procs: map[transport.Kind]*actions.Processor{}, kick: make(chan struct{}, 1),
	}
	for _, t := range []transport.Transport{c.CloudKit, c.Relay} {
		if t == nil {
			continue
		}
		ac := c.Actions
		ac.Transport, ac.Switch, ac.Clock = t, s, c.Clock
		s.procs[t.Kind()] = actions.NewProcessor(ac)
	}
	active, err := s.storedActive()
	if err != nil {
		return nil, err
	}
	s.active = active
	return s, nil
}

func (s *Switcher) storedActive() (transport.Kind, error) {
	v, ok, err := s.c.Store.Meta(MetaTransport)
	if err != nil {
		return "", err
	}
	k := transport.Kind(v)
	if ok && s.transport(k) != nil {
		return k, nil
	}
	if s.c.CloudKit != nil {
		return transport.KindCloudKit, nil
	}
	return transport.KindRelay, nil
}

// transport is k's transport, nil when the hub has none of that kind.
func (s *Switcher) transport(k transport.Kind) transport.Transport {
	switch k {
	case transport.KindCloudKit:
		return s.c.CloudKit
	case transport.KindRelay:
		return s.c.Relay
	}
	return nil
}

func (s *Switcher) activeKind() transport.Kind {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.active
}

// Active is the transport the hub applies actions from and publishes on.
func (s *Switcher) Active() transport.Transport { return s.transport(s.activeKind()) }

// IsActive implements actions.Switch.
func (s *Switcher) IsActive(k transport.Kind) bool { return k == s.activeKind() }

// Front is the active transport behind one handle, for the publisher: each
// call goes to the transport active at that moment. Its Events is a nil
// channel (the runtime reads each transport's own events).
func (s *Switcher) Front() transport.Transport { return front{s} }

type front struct{ s *Switcher }

func (f front) Kind() transport.Kind { return f.s.activeKind() }

func (f front) Save(ctx context.Context, items []transport.SaveItem) ([]transport.Outcome, error) {
	return f.s.Active().Save(ctx, items)
}

func (f front) Delete(ctx context.Context, zone string, items []transport.DeleteItem) ([]transport.Outcome, error) {
	return f.s.Active().Delete(ctx, zone, items)
}

func (f front) Changes(ctx context.Context, zone string, since uint64) (transport.Batch, error) {
	return f.s.Active().Changes(ctx, zone, since)
}

func (front) Events() <-chan transport.Event { return nil }

func (f front) Download(ctx context.Context, zone, attachmentID, dst string) error {
	return f.s.Active().Download(ctx, zone, attachmentID, dst)
}

// Processor is k's processor (nil when the hub has no such transport).
func (s *Switcher) Processor(k transport.Kind) *actions.Processor { return s.procs[k] }

// ActiveProcessor is the active transport's processor: the runtime's passes,
// flushes, hygiene and late echoes go to it.
func (s *Switcher) ActiveProcessor() *actions.Processor { return s.procs[s.activeKind()] }

// other is the inactive transport's kind, "" on a hub with one transport.
func (s *Switcher) other() transport.Kind {
	k := transport.KindRelay
	if s.activeKind() == transport.KindRelay {
		k = transport.KindCloudKit
	}
	if s.transport(k) == nil {
		return ""
	}
	return k
}

// Kick asks Run to Step now (a request was accepted).
func (s *Switcher) Kick() {
	select {
	case s.kick <- struct{}{}:
	default:
	}
}

// Run carries accepted switches out and polls the inactive transport's
// mailboxes every OtherPoll (rule 11), retrying the owed markers, until ctx
// ends.
func (s *Switcher) Run(ctx context.Context) error {
	t := time.NewTicker(OtherPoll)
	defer t.Stop()
	for {
		if err := s.Step(ctx); err != nil && ctx.Err() == nil {
			log.Printf("hub: transport switch: %s", errClass(err))
		}
		s.PollOther(ctx)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-s.kick:
		case <-t.C:
		}
	}
}

// PollOther is one pass over the inactive transport's mailboxes (bounded by
// OldSideTimeout): the phones' controls there are read, a phone that wrote
// there gets its answer, and that transport's queue is written; then the
// owed markers. An unreachable side is logged and left for the next poll.
func (s *Switcher) PollOther(ctx context.Context) {
	if k := s.other(); k != "" {
		octx, cancel := context.WithTimeout(ctx, OldSideTimeout)
		if _, err := s.procs[k].Pass(octx); err != nil && ctx.Err() == nil {
			log.Printf("hub: polling the %s mailboxes: %s", k, errClass(err))
		}
		cancel()
	}
	s.writeOwedMarkers(ctx)
	if s.Pending() {
		s.Kick()
	}
}

func (s *Switcher) now() time.Time { return s.c.Clock() }

// errClass is a log-safe class of err (no ids, no text from a peer).
func errClass(err error) string {
	switch {
	case err == nil:
		return "none"
	case errors.Is(err, context.DeadlineExceeded):
		return "timeout"
	case errors.Is(err, context.Canceled):
		return "canceled"
	case errors.Is(err, transport.ErrUnavailable):
		return "unavailable"
	}
	return fmt.Sprintf("%T", err)
}
