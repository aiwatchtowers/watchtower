// Package alerts pushes the hub's work alerts to the paying phones over the
// hosted relay's send_alert (Go hub plan 4 Task 4, spec §12a "Alerts").
//
// Each push is sent at most once per (alert key, phone): its ledger row is
// written pending before the push is queued and settled with its outcome
// class after the request; a row still pending at hub start is settled
// expired and never resent. A push not accepted within Freshness of the
// alert's first save is dropped, and none is sent while the owner is back at
// the Mac. The alert's text lives only in memory, sealed in the queue item;
// the ledger and the logs carry ids and classes only (FILES-01).
package alerts

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"log"
	"slices"
	"sync"
	"time"

	"watchtower/internal/hub/platform"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/relay"
	"watchtower/internal/hub/transport/relay/relayv1"
)

const (
	// Freshness is how long after the alert's first save its push may still
	// be sent (owner, ask #864).
	Freshness = 5 * time.Minute
	// QueuePerPhone is how many pushes wait for one phone; one more is
	// settled expired (reason overflow).
	QueuePerPhone = 64

	// retryDefault and retryCap bound the wait after RATE_LIMITED (the
	// relay's retry_after_s when it sends one).
	retryDefault = time.Second
	retryCap     = 60 * time.Second
	// unavailableRetry is the wait after an unreachable relay when no new
	// connection (Reconnected) comes first.
	unavailableRetry = 30 * time.Second
)

// Target is a phone a push goes to: its sidecar device id and its relay
// device id.
type Target struct{ DeviceID, RelayID string }

// Config is what a Pusher works with.
type Config struct {
	Store  *state.Store
	Sealer *secure.Sealer
	Send   transport.Alerts
	// Targets is the phones to push to now: linked, with a relay device id,
	// a hub reader and paying (Eligible).
	Targets func(ctx context.Context) ([]Target, error)
	// RefreshAccount re-reads the relay account state; called once per
	// not_paying or forbidden answer.
	RefreshAccount func(ctx context.Context)
	// Away is the work-alert policy's owner-away input, checked before every
	// send, retries included. Nil reads as always away; an error as away.
	Away  platform.Away
	Clock func() time.Time
	// Timer waits d between retries (nil = a real timer): a channel that
	// fires once and a stop func.
	Timer func(d time.Duration) (<-chan time.Time, func())
}

// Eligible is the push targets among the linked devices: a relay device id
// that the account state lists in a slot with paying set (a paying phone
// holding the hub is one of its readers, SetReadersFrom). Sorted by device
// id.
func Eligible(devices []state.Device, acct *relayv1.AccountState) []Target {
	paying := map[string]bool{}
	for _, h := range acct.GetPhones() {
		if h.GetPaying() {
			paying[h.GetPhoneDeviceId()] = true
		}
	}
	var out []Target
	for _, d := range devices {
		if d.RelayDeviceID != "" && paying[d.RelayDeviceID] {
			out = append(out, Target{DeviceID: d.ID, RelayID: d.RelayDeviceID})
		}
	}
	slices.SortFunc(out, func(a, b Target) int { return cmp.Compare(a.DeviceID, b.DeviceID) })
	return out
}

// Pusher sends work alerts to the target phones, one sender goroutine per
// phone.
type Pusher struct {
	c Config

	mu       sync.Mutex
	ctx      context.Context
	cancel   context.CancelCauseFunc
	running  bool
	stopped  bool
	senders  map[string]*sender
	tooLarge map[string]bool // alert keys logged as too large

	wg sync.WaitGroup
	// onSettle, when set (tests), sees every settled push.
	onSettle func(key, device, outcome, reason string)
}

// item is one queued push: ids, the sealed envelope and its deadline.
type item struct {
	key, device, relay string
	push               secure.Push
	deadline           time.Time
}

// sender is one phone's queue and its push in progress.
type sender struct {
	queue     []item
	cur       *flight
	wake      chan struct{}
	reconnect chan struct{}
}

// flight is the push a sender works on (sending or waiting to retry).
type flight struct {
	key     string
	cancel  context.CancelCauseFunc
	done    chan struct{}
	outcome string // set before done closes
	reason  string
}

// expiry is the cancel cause that settles a push expired with its reason.
type expiry struct{ reason string }

func (e expiry) Error() string { return "alert push expired: " + e.reason }

// New returns a Pusher; Start runs it.
func New(c Config) *Pusher {
	if c.Clock == nil {
		c.Clock = time.Now
	}
	if c.Timer == nil {
		c.Timer = func(d time.Duration) (<-chan time.Time, func()) {
			t := time.NewTimer(d)
			return t.C, func() { t.Stop() }
		}
	}
	return &Pusher{c: c, senders: map[string]*sender{}, tooLarge: map[string]bool{}}
}

// Start settles every push left pending by the previous run expired (reason
// restart, never resent), then accepts pushes until Stop or ctx ends.
func (p *Pusher) Start(ctx context.Context) error {
	n, err := p.c.Store.ExpirePendingAlertPushes(p.c.Clock())
	if err != nil {
		return fmt.Errorf("hub alerts: %w", err)
	}
	if n > 0 {
		log.Printf("hub alerts: %d pushes pending at start settled expired (restart), never resent", n)
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.running || p.stopped {
		return errors.New("hub alerts: pusher already started")
	}
	p.ctx, p.cancel = context.WithCancelCause(ctx)
	p.running = true
	return nil
}

// Enqueue queues key's push to every target phone that was never pushed
// this key. The pending rows are written first, in one short transaction,
// then the items enter the queues; it never waits on a send. savedAt is the
// alert's first save (the start of its freshness window).
func (p *Pusher) Enqueue(key string, fields secure.WorkAlertFields, savedAt time.Time) {
	p.mu.Lock()
	ctx, running := p.ctx, p.running
	p.mu.Unlock()
	if !running {
		log.Printf("hub alerts: push of %s not queued: the pusher is not running", key)
		return
	}
	targets, err := p.c.Targets(ctx)
	if err != nil {
		log.Printf("hub alerts: push of %s not queued: targets unreadable (%s)", key, errClass(err))
		return
	}
	relayOf := map[string]string{}
	devices := make([]string, 0, len(targets))
	for _, t := range targets {
		if _, dup := relayOf[t.DeviceID]; !dup && t.RelayID != "" {
			relayOf[t.DeviceID] = t.RelayID
			devices = append(devices, t.DeviceID)
		}
	}
	if len(devices) == 0 {
		return
	}
	begun, err := p.c.Store.BeginAlertPushes(key, devices, p.c.Clock())
	if err != nil {
		log.Printf("hub alerts: push of %s not queued: %s", key, errClass(err))
		return
	}
	if len(begun) == 0 {
		return
	}
	push, err := p.c.Sealer.AlertPush(key, fields)
	if err != nil {
		outcome := state.AlertFailed
		if errors.Is(err, secure.ErrAlertTooLarge) {
			outcome = state.AlertTooLarge
		}
		log.Printf("hub alerts: push of %s not sealed (%s): settled %s", key, errClass(err), outcome)
		for _, d := range begun {
			p.settle(key, d, outcome, "", 0)
		}
		return
	}
	deadline := savedAt.Add(Freshness)
	var refused []struct{ device, reason string }
	p.mu.Lock()
	for _, d := range begun {
		if !p.running {
			refused = append(refused, struct{ device, reason string }{d, state.ReasonStopped})
			continue
		}
		s := p.senderLocked(d)
		if len(s.queue) >= QueuePerPhone {
			refused = append(refused, struct{ device, reason string }{d, state.ReasonOverflow})
			continue
		}
		s.queue = append(s.queue, item{key: key, device: d, relay: relayOf[d], push: push, deadline: deadline})
		select {
		case s.wake <- struct{}{}:
		default:
		}
	}
	p.mu.Unlock()
	for _, r := range refused {
		if r.reason == state.ReasonOverflow {
			log.Printf("hub alerts: push of %s to %s dropped: its queue is full", key, r.device)
		}
		p.settle(key, r.device, state.AlertExpired, r.reason, 0)
	}
}

// Reconnected wakes the pushes waiting after an unreachable relay: the
// relay has a connection again.
func (p *Pusher) Reconnected() {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, s := range p.senders {
		select {
		case s.reconnect <- struct{}{}:
		default:
		}
	}
}

// Abandon settles every queued push, and the one each phone works on unless
// its answer comes first, expired with reason, and returns their alert keys
// (sorted, once each). The pusher keeps running: a later Enqueue is pushed
// as usual. The runtime calls it on a switch to CloudKit.
func (p *Pusher) Abandon(reason string) []string {
	queued, flights := p.takeAll()
	for _, f := range flights {
		f.cancel(expiry{reason})
	}
	keys := map[string]bool{}
	for _, it := range queued {
		p.settle(it.key, it.device, state.AlertExpired, reason, 0)
		keys[it.key] = true
	}
	for _, f := range flights {
		<-f.done
		if f.outcome == state.AlertExpired && f.reason == reason {
			keys[f.key] = true
		}
	}
	out := make([]string, 0, len(keys))
	for k := range keys {
		out = append(out, k)
	}
	slices.Sort(out)
	return out
}

// Stop settles every queued push and the ones in progress expired (reason
// stopped) and waits for the senders to end. It is safe to call twice.
func (p *Pusher) Stop() {
	p.mu.Lock()
	wasRunning := p.running
	p.running, p.stopped = false, true
	p.mu.Unlock()
	if !wasRunning {
		return
	}
	queued, _ := p.takeAll()
	p.cancel(expiry{state.ReasonStopped})
	for _, it := range queued {
		p.settle(it.key, it.device, state.AlertExpired, state.ReasonStopped, 0)
	}
	p.wg.Wait()
}

// takeAll empties every queue and returns the items with the flights in
// progress.
func (p *Pusher) takeAll() ([]item, []*flight) {
	p.mu.Lock()
	defer p.mu.Unlock()
	var (
		queued  []item
		flights []*flight
	)
	for _, s := range p.senders {
		queued = append(queued, s.queue...)
		s.queue = nil
		if s.cur != nil {
			flights = append(flights, s.cur)
		}
	}
	return queued, flights
}

// senderLocked is device's sender, started on first use (p.mu held, running).
func (p *Pusher) senderLocked(device string) *sender {
	s := p.senders[device]
	if s == nil {
		s = &sender{wake: make(chan struct{}, 1), reconnect: make(chan struct{}, 1)}
		p.senders[device] = s
		p.wg.Add(1)
		go p.run(s)
	}
	return s
}

// run is one phone's sender: one push at a time, in queue order.
func (p *Pusher) run(s *sender) {
	defer p.wg.Done()
	for {
		p.mu.Lock()
		if len(s.queue) == 0 {
			p.mu.Unlock()
			select {
			case <-s.wake:
				continue
			case <-p.ctx.Done():
				return
			}
		}
		it := s.queue[0]
		s.queue = s.queue[1:]
		ctx, cancel := context.WithCancelCause(p.ctx)
		f := &flight{key: it.key, cancel: cancel, done: make(chan struct{})}
		s.cur = f
		p.mu.Unlock()

		f.outcome, f.reason = p.deliver(ctx, s, it)
		cancel(nil)
		p.mu.Lock()
		s.cur = nil
		p.mu.Unlock()
		close(f.done)
	}
}

// deliver sends one push, retrying inside its freshness window, and settles
// it. It returns the outcome and reason it settled.
func (p *Pusher) deliver(ctx context.Context, s *sender, it item) (string, string) {
	attempts := 0
	expire := func(reason string) (string, string) {
		p.settle(it.key, it.device, state.AlertExpired, reason, attempts)
		return state.AlertExpired, reason
	}
	for {
		if err := context.Cause(ctx); err != nil {
			return expire(reasonOf(err))
		}
		if !p.c.Clock().Before(it.deadline) {
			return expire(state.ReasonFreshness)
		}
		if !p.away() {
			return expire(state.ReasonOwnerBack)
		}
		attempts++
		err := p.c.Send.SendAlert(ctx, it.relay, it.push)
		if err != nil && ctx.Err() != nil && (errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded)) {
			return expire(reasonOf(context.Cause(ctx)))
		}
		outcome, wait, onConnect := classify(err)
		if wait == 0 {
			p.settle(it.key, it.device, outcome, "", attempts)
			p.after(it, outcome)
			return outcome, ""
		}
		remaining := it.deadline.Sub(p.c.Clock())
		if remaining <= 0 {
			return expire(state.ReasonFreshness)
		}
		var reconnect <-chan struct{}
		if onConnect {
			reconnect = s.reconnect
		}
		fire, stop := p.c.Timer(min(wait, remaining))
		select {
		case <-fire:
		case <-reconnect:
		case <-ctx.Done():
		}
		stop()
	}
}

// after acts on a settled answer: one account refresh after not_paying or
// forbidden, one log line per alert key for a push too large.
func (p *Pusher) after(it item, outcome string) {
	switch outcome {
	case state.AlertNotPaying, state.AlertForbidden:
		if p.c.RefreshAccount != nil {
			p.c.RefreshAccount(p.ctx)
		}
	case state.AlertTooLarge:
		p.mu.Lock()
		first := !p.tooLarge[it.key]
		if len(p.tooLarge) >= 256 {
			clear(p.tooLarge)
		}
		p.tooLarge[it.key] = true
		p.mu.Unlock()
		if first {
			log.Printf("hub alerts: the relay refused the push of %s as too large (a bug: the envelope is sized to fit)", it.key)
		}
	}
}

// classify maps a send_alert answer to its outcome class, or to a retry: the
// wait, and whether a new connection ends it early.
func classify(err error) (outcome string, wait time.Duration, onConnect bool) {
	switch {
	case err == nil:
		return state.AlertAccepted, 0, false
	case errors.Is(err, transport.ErrNoPushToken):
		return state.AlertNoToken, 0, false
	case errors.Is(err, transport.ErrPushOff):
		return state.AlertPushOff, 0, false
	case errors.Is(err, transport.ErrEntitlementInactive):
		return state.AlertNotPaying, 0, false
	case errors.Is(err, transport.ErrForbidden), errors.Is(err, transport.ErrNotVouched):
		return state.AlertForbidden, 0, false
	case errors.Is(err, transport.ErrRecordTooLarge):
		return state.AlertTooLarge, 0, false
	case errors.Is(err, transport.ErrRateLimited):
		d := relay.RetryAfter(err)
		if d <= 0 {
			d = retryDefault
		}
		return "", min(d, retryCap), false
	case errors.Is(err, transport.ErrUnavailable):
		return "", unavailableRetry, true
	default:
		return state.AlertFailed, 0, false
	}
}

// reasonOf is the expiry reason of a cancel cause; a context ended any other
// way reads as stopped.
func reasonOf(cause error) string {
	var e expiry
	if errors.As(cause, &e) {
		return e.reason
	}
	return state.ReasonStopped
}

// away is the owner-away input: nil reads as away, an error too.
func (p *Pusher) away() bool {
	if p.c.Away == nil {
		return true
	}
	away, err := p.c.Away.Away()
	return away || err != nil
}

// settle writes a push's outcome and logs it: ids and classes only.
func (p *Pusher) settle(key, device, outcome, reason string, attempts int) {
	if err := p.c.Store.SettleAlertPush(key, device, outcome, reason, attempts, p.c.Clock()); err != nil {
		log.Printf("hub alerts: push of %s to %s not settled (%s)", key, device, errClass(err))
	}
	if reason != "" {
		log.Printf("hub alerts: push of %s to %s: %s (%s) after %d attempts", key, device, outcome, reason, attempts)
	} else {
		log.Printf("hub alerts: push of %s to %s: %s after %d attempts", key, device, outcome, attempts)
	}
	if p.onSettle != nil {
		p.onSettle(key, device, outcome, reason)
	}
}

// errClass names an error by its class, never its text (FILES-01).
func errClass(err error) string {
	classes := []struct {
		err  error
		name string
	}{
		{secure.ErrAlertTooLarge, "too_large"},
		{secure.ErrNameMismatch, "key_mismatch"},
		{transport.ErrUnavailable, "unavailable"},
		{transport.ErrForbidden, "forbidden"},
		{transport.ErrEntitlementInactive, "entitlement_inactive"},
		{context.Canceled, "canceled"},
		{context.DeadlineExceeded, "deadline"},
	}
	for _, c := range classes {
		if errors.Is(err, c.err) {
			return c.name
		}
	}
	return "error"
}
