// Package switcher is the hub's dual transport and the transport switch
// (relay sim rules 8–13, relay client spec §9, Go hub spec §9; phase 3
// plan Task 18). A desktop host runs one action processor per transport over
// one sidecar: the active transport's applies the phones' actions, the
// other's is polled every OtherPoll for the phones' controls (a switch back,
// an epoch_ack) and answers a phone that wrote there without following
// (sim rule 12a, actions/standby.go).
//
// Only a person switches (rule 8): a phone's transport_switch, or the relay
// entitlement lapsing (by = "entitlement_expired"), which is also what the
// relay's answer that no phone pays for the hub moves it by (nopayer.go, G2,
// by ruling, two fresh answers and every phone with an iCloud route); a
// transport failure never does. Toward the relay a switch is accepted at
// least AntiFlap after the previous one; toward CloudKit always (rules 9–10),
// a lapse's only once a fresh account read says nobody else pays (rule 16). The
// last accepted request wins. A pass reads nothing from the relay: what needs
// the account is recorded there and decided by the Step (asks.go,
// entitlement.go).
//
// An accepted switch (rule 11; Step) runs in this order, each step durable
// in hub_meta so a restart finishes the same switch and never rotates twice:
//  1. the publisher is held (its own pause reason) from acceptance until the
//     new transport is active;
//  2. every phone's mailbox on the old transport is finished in the old
//     epoch if it answers within the old-side timeout (never waiting on an
//     unreachable one), then the old transport's processor is paused, so
//     nothing is sealed there in the new epoch;
//  3. the epoch rotates once (identity.ReasonTransportSwitch; switched_at and
//     switched_by are written with it);
//  4. one transaction queues transport_switched{target, epoch, by, at, keybox}
//     for every phone on both transports (one control id per phone, the old
//     copy sealed in an epoch that phone holds), toward the relay
//     hub_on_relay to the CloudKit mailbox of every ordered phone that does
//     not pay, sets hub_meta.transport, rewinds the new transport's
//     mailboxes and owes the markers; the in-memory active transport moves
//     with the commit. A phone whose copy cannot be sealed is logged and
//     skipped, never stopping the switch;
//  5. the new transport's queue is written and the publisher resumes there
//     (a full diff);
//  6. off the switch's path (PollOther): the old transport's queue (the
//     notices) and its data-zone marker sealed in the old epoch (phone
//     contract point 6a); the relay's data zone always gets the marker
//     (point 4). The publisher has stopped publishing there since step 1.
//
// A notice or a marker that could not be written stays owed: the queue rows
// are retried by every pass of their processor, the markers by PollOther. A
// Step that fails is retried with backoff (1 s doubling to 60 s).
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
	// AntiFlap is the least time between a switch and the next one toward
	// the relay (rule 9).
	AntiFlap = 5 * time.Minute
	// OtherPoll is how often Run polls the inactive transport's mailboxes
	// (rule 11) and retries the owed markers.
	OtherPoll = 30 * time.Second
	// OldSideTimeout bounds every call into the transport the hub leaves or
	// does not run on, so an unreachable (or hanging) one never holds a
	// switch up.
	OldSideTimeout = 10 * time.Second
	// The backoff of a failed Step.
	backoffFirst = time.Second
	backoffMax   = time.Minute
	// pauseReason is the switch's own hold on the publisher.
	pauseReason = "transport_switch"
)

// hub_meta keys: the active transport ("cloudkit"|"relay"), the last switch's
// time (seconds since 1970 as a decimal string, like enabled_at) and who
// asked (a device id or wire.SwitchedByEntitlement), and the switch record
// (switchRecord, JSON). metaAdoptedAt is the adoption's (internal/hub/adopt).
const (
	MetaTransport  = "transport"
	MetaSwitchedAt = "switched_at"
	MetaSwitchedBy = "switched_by"
	metaSwitch     = "transport_switch"
	metaAdoptedAt  = "adopted_at"
)

// Config wires a Switcher. Relay may be nil (a desktop host without a relay
// origin: CloudKit only, every switch toward the relay rejected). Actions is
// the processors' template: the switcher sets Transport and Switch per
// transport. Publisher (optional) publishes on Front(); the switch holds it
// under its own reason. Keyboxes is the link center's (each linked phone's
// keybox payload, the bytes the data zone's keybox carries). Paying
// (optional) is which linked phones pay for the relay, by device id.
// OldSideTimeout (0 = OldSideTimeout) bounds each old-side step. Clock
// defaults to Actions.Clock, then time.Now.
type Config struct {
	Store           *state.Store
	Keys            *identity.Keyring
	Relay, CloudKit transport.Transport
	Actions         actions.Config
	Publisher       *slices.Publisher
	Keyboxes        func() ([]wire.Keybox, error)
	Paying          func(ctx context.Context) (map[string]bool, error)
	// AnyPaying (optional) is whether any phone in the relay account pays,
	// matched to a linked phone or not; an error is unknown (nopayer.go).
	AnyPaying func(ctx context.Context) (bool, error)
	// AccountPhones (optional) is a fresh read of the relay account's phones
	// that hold this Mac in a slot, linked here or not; an error is
	// undecided (rule 16, asks #1075, #1079; othersPay decides over it).
	AccountPhones  func(ctx context.Context) ([]AccountPhone, error)
	OldSideTimeout time.Duration
	Clock          func() time.Time
	// OnSwitched (nil = none) sees each switch once its commit moved the
	// active transport to target, while the publisher is still held (the
	// runtime drops the queued alert pushes on a switch to CloudKit and
	// signals those alerts there, before the publisher resumes).
	OnSwitched func(target transport.Kind)
}

// AccountPhone is one phone of the relay account's list: its relay device id
// and whether it pays.
type AccountPhone struct {
	RelayDeviceID string
	Paying        bool
}

// Switcher is the hub's dual transport. Request and Stale are called from
// inside a processor's pass: they never call into a processor and never read
// the relay (asks.go); Step, Run and the processors' passes may run concurrently.
type Switcher struct {
	c      Config
	sealer *secure.Sealer
	data   string
	procs  map[transport.Kind]*actions.Processor
	kick   chan struct{}

	stepMu sync.Mutex // one Step at a time
	// answersQueued: this Step queued answers its end writes out (asks.go).
	answersQueued bool

	mu     sync.Mutex // guards active, pending, paying and every read-modify-write of the switch record
	active transport.Kind
	// pending is the lapses waiting for a Step, paying the last account
	// read that answered (entitlement.go). Device ids in uuidString form.
	pending map[string]*lapseRequest
	paying  map[string]bool

	lapseMu sync.Mutex // one lapse decision at a time (entitlement.go)
	npMu    sync.Mutex // the no-payer check (nopayer.go)
	np      noPayer

	boMu    sync.Mutex // the failed-Step backoff
	boDelay time.Duration
	boUntil time.Time
}

var _ actions.Switch = (*Switcher)(nil)

// New builds the switcher and its processors. The active transport is
// hub_meta.transport; unset (decided once, then stored): CloudKit on a hub
// that adopted the Swift hub's state, the relay on a hub whose phones are
// all relay links (an existing relay hub becoming a desktop host), else
// CloudKit when the hub has it. A switch in flight holds the publisher and,
// once rotated, pauses the old transport's processor until Step finishes it.
func New(c Config) (*Switcher, error) {
	if c.CloudKit == nil && c.Relay == nil {
		return nil, errors.New("switcher: no transport")
	}
	if c.Keyboxes == nil {
		return nil, errors.New("switcher: no keyboxes")
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
	r, ok, err := s.record()
	if err != nil {
		return nil, err
	}
	if ok && !r.Done {
		s.holdPublisher()
		if r.Epoch != 0 {
			s.pauseOld(r)
		}
	}
	s.loadPending()
	return s, nil
}

func (s *Switcher) storedActive() (transport.Kind, error) {
	v, ok, err := s.c.Store.Meta(MetaTransport)
	if err != nil {
		return "", err
	}
	if k := transport.Kind(v); ok && s.transport(k) != nil {
		return k, nil
	}
	k, err := s.defaultActive()
	if err != nil {
		return "", err
	}
	if err := s.c.Store.SetMeta(MetaTransport, string(k)); err != nil {
		return "", err
	}
	return k, nil
}

func (s *Switcher) defaultActive() (transport.Kind, error) {
	if s.c.CloudKit == nil {
		return transport.KindRelay, nil
	}
	if s.c.Relay == nil {
		return transport.KindCloudKit, nil
	}
	if _, adopted, err := s.c.Store.Meta(metaAdoptedAt); err != nil || adopted {
		return transport.KindCloudKit, err
	}
	devices, err := s.c.Store.Devices()
	if err != nil {
		return "", err
	}
	ck, err := s.c.Store.CloudKitLinks()
	if err != nil {
		return "", err
	}
	relayLinked := false
	for _, d := range devices {
		if d.RelayDeviceID != "" {
			relayLinked = true
		}
	}
	if relayLinked && ck == 0 {
		return transport.KindRelay, nil
	}
	return transport.KindCloudKit, nil
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

func (s *Switcher) oldSide() time.Duration {
	if s.c.OldSideTimeout > 0 {
		return s.c.OldSideTimeout
	}
	return OldSideTimeout
}

// holdPublisher / releasePublisher hold the publisher under the switch's own
// reason (another pauser's hold is never lifted here).
func (s *Switcher) holdPublisher() {
	if s.c.Publisher != nil {
		s.c.Publisher.PauseFor(pauseReason)
	}
}

func (s *Switcher) releasePublisher() {
	if s.c.Publisher != nil {
		s.c.Publisher.ResumeFor(pauseReason)
	}
}

// SetPublisher wires the publisher built on Front() (it needs the switcher
// first); a switch in flight holds it at once.
func (s *Switcher) SetPublisher(p *slices.Publisher) {
	s.stepMu.Lock()
	defer s.stepMu.Unlock()
	s.c.Publisher = p
	if s.Pending() {
		s.holdPublisher()
	}
}

// pauseOld pauses the processor of the transport r leaves (between its
// rotation and its announce nothing may be sealed there in the new epoch).
func (s *Switcher) pauseOld(r switchRecord) {
	if p := s.procs[r.From]; p != nil {
		p.PauseFor(pauseReason)
	}
}

// Kick asks Run to Step now (a request was accepted).
func (s *Switcher) Kick() {
	select {
	case s.kick <- struct{}{}:
	default:
	}
}

// stepDue reports whether a failed Step's backoff has run out.
func (s *Switcher) stepDue() bool {
	s.boMu.Lock()
	defer s.boMu.Unlock()
	return !time.Now().Before(s.boUntil)
}

// noteStep moves the backoff: reset on success, else 1 s doubling to 60 s.
// One log line per streak of failures, one when it ends.
func (s *Switcher) noteStep(err error) {
	s.boMu.Lock()
	defer s.boMu.Unlock()
	if err == nil {
		if s.boDelay > 0 {
			log.Printf("hub: transport switch: carried out after retries")
		}
		s.boDelay, s.boUntil = 0, time.Time{}
		return
	}
	if s.boDelay == 0 {
		log.Printf("hub: transport switch: %s; retrying with backoff", errClass(err))
		s.boDelay = backoffFirst
	} else {
		s.boDelay = min(2*s.boDelay, backoffMax)
	}
	s.boUntil = time.Now().Add(s.boDelay)
}

func (s *Switcher) resetBackoff() {
	s.boMu.Lock()
	s.boDelay, s.boUntil = 0, time.Time{}
	s.boMu.Unlock()
}

// backoffWait is how long until a failed Step may run again (0 = now).
func (s *Switcher) backoffWait() time.Duration {
	s.boMu.Lock()
	defer s.boMu.Unlock()
	return max(time.Until(s.boUntil), 0)
}

// Run carries accepted switches out (a failed Step backs off) and polls
// the inactive transport's mailboxes every OtherPoll (rule 11), writing the
// owed notices and markers, until ctx ends.
func (s *Switcher) Run(ctx context.Context) error {
	for {
		if s.stepDue() {
			s.noteStep(s.Step(ctx))
		}
		s.PollOther(ctx)
		wait := OtherPoll
		if w := s.backoffWait(); w > 0 && w < wait {
			wait = w
		}
		t := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			t.Stop()
			return ctx.Err()
		case <-s.kick:
		case <-t.C:
		}
		t.Stop()
	}
}

// PollOther is one pass over the inactive transport's mailboxes (bounded by
// the old-side timeout): the phones' controls there are read, a phone that
// wrote there gets its answer, and that transport's queue is written (the
// switch notices among it); then the owed markers. An unreachable side is
// logged and left for the next poll. A pending switch kicks Run unless a
// failed Step is backing off.
func (s *Switcher) PollOther(ctx context.Context) {
	if k := s.other(); k != "" {
		octx, cancel := context.WithTimeout(ctx, s.oldSide())
		if _, err := s.procs[k].Pass(octx); err != nil && ctx.Err() == nil {
			log.Printf("hub: polling the %s mailboxes: %s", k, errClass(err))
		}
		cancel()
	}
	s.writeOwedMarkers(ctx, "")
	// G2 reads first on its tick: on an unvouched hub the reader answers a
	// read inside its window from the last one, and G2 alone refuses that
	// (a lapse recheck first would make every G2 read land in the window).
	s.checkNoPayer(ctx)  // G2: nobody pays any more
	s.recheckLapsed(ctx) // sim rule 16: a lapsed phone that pays again
	if (s.Pending() || s.asksWaiting()) && s.stepDue() {
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
