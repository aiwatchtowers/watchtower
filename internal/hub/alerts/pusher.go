// Package alerts pushes the hub's work alerts to the paying phones over the
// hosted relay's send_alert (Go hub plan 4 Task 4, spec §12a "Alerts").
//
// Each push is sent at most once per (alert key, phone): its ledger row is
// written pending before the push is queued and settled with its outcome
// class after the request; a row still pending at hub start is settled
// expired and never resent, and a request that may have reached the relay
// without an answer (interrupted, or a connection failure) settles expired
// in_flight and is never resent either. A push not accepted within Freshness
// of the alert's first save is dropped, and none is sent while the owner is
// back at the Mac. The alert's text lives only in memory, sealed in the
// queue item; the ledger and the logs carry ids and classes only (FILES-01).
package alerts

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"log"
	"maps"
	"slices"
	"sync"
	"time"

	"watchtower/internal/hub/platform"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/relay"
	"watchtower/internal/hub/transport/relay/client"
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
	// unavailableRetry is the wait after the relay answered UNAVAILABLE when
	// no new connection (Reconnected) comes first.
	unavailableRetry = 30 * time.Second
	// refreshTimeout bounds one account refresh.
	refreshTimeout = 15 * time.Second
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
	// RefreshAccount re-reads the relay account state after a not_paying or
	// forbidden answer: run off the senders, one at a time (answers that come
	// while one runs share it), bounded by its own timeout.
	RefreshAccount func(ctx context.Context)
	// Away is the work-alert policy's owner-away input, checked before every
	// send, retries included. Nil reads as always away; an error as away.
	Away platform.Away
	// EpochFor is the epoch a phone's push is sealed in: one whose K_alert
	// the phone holds while locked (its acked epoch while the hub retains
	// it), 0 for the current one. Nil reads as 0 for every phone.
	EpochFor func(device string) uint32
	Clock    func() time.Time
	// Timer waits d between retries (nil = a real timer): a channel that
	// fires once and a stop func.
	Timer func(d time.Duration) (<-chan time.Time, func())
}

// Eligible is the push targets among the linked devices: a relay device id
// that the account state lists in a slot with paying set (a paying phone
// holding the hub is one of its readers, SetReadersFrom) and whose "When work
// stops" switch is on (Device.WorkAlertsOff). Sorted by device id.
func Eligible(devices []state.Device, acct *relayv1.AccountState) []Target {
	paying := map[string]bool{}
	for _, h := range acct.GetPhones() {
		if h.GetPaying() {
			paying[h.GetPhoneDeviceId()] = true
		}
	}
	var out []Target
	for _, d := range devices {
		if d.RelayDeviceID != "" && !d.WorkAlertsOff && paying[d.RelayDeviceID] {
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

	mu         sync.Mutex
	ctx        context.Context
	cancel     context.CancelCauseFunc
	starting   bool
	running    bool
	stopped    bool
	gen        uint64 // bumped by every Abandon
	abandoned  string // the last Abandon's reason
	refreshing bool
	stopCalled bool
	stopDone   chan struct{} // closed when the first Stop has finished
	senders    map[string]*sender
	tooLarge   map[string]bool // alert keys logged as too large

	wg sync.WaitGroup
	// Test hooks: onSettle sees every push whose row a settle changed;
	// beforeQueue runs in Enqueue between the pending rows and the queues.
	onSettle    func(key, device, outcome, reason string)
	beforeQueue func()
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
	key    string
	cancel context.CancelCauseFunc
	done   chan struct{}
	// Set before done closes: how it settled and whether its row changed.
	outcome, reason string
	changed         bool
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
	return &Pusher{c: c, senders: map[string]*sender{}, tooLarge: map[string]bool{}, stopDone: make(chan struct{})}
}

// Start settles every push left pending by the previous run expired (reason
// restart, never resent), then accepts pushes until Stop or ctx ends. A
// Pusher starts once.
func (p *Pusher) Start(ctx context.Context) error {
	p.mu.Lock()
	if p.starting || p.running || p.stopped {
		p.mu.Unlock()
		return errors.New("hub alerts: pusher already started")
	}
	p.starting = true
	p.mu.Unlock()

	n, err := p.c.Store.ExpirePendingAlertPushes(p.c.Clock())

	p.mu.Lock()
	defer p.mu.Unlock()
	p.starting = false
	if err != nil {
		return fmt.Errorf("hub alerts: %w", err)
	}
	if n > 0 {
		log.Printf("hub alerts: %d pushes pending at start settled expired (restart), never resent", n)
	}
	if p.stopped {
		return errors.New("hub alerts: pusher stopped while starting")
	}
	p.ctx, p.cancel = context.WithCancelCause(ctx)
	p.running = true
	return nil
}

// Enqueue queues key's push to every target phone that was never pushed
// this key. The pending rows are written first, in one short transaction,
// then the items enter the queues; it never waits on a send. savedAt is the
// alert's first save (the start of its freshness window). An Enqueue that
// overlaps an Abandon queues nothing: its rows settle expired with the
// abandon's reason (the runtime calls Enqueue only while on the relay).
func (p *Pusher) Enqueue(key string, fields secure.WorkAlertFields, savedAt time.Time) {
	p.mu.Lock()
	ctx, running, gen := p.ctx, p.running, p.gen
	p.mu.Unlock()
	if !running || ctx.Err() != nil {
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
	pushOf, failed := p.seal(key, fields, begun)
	p.settleAll(failed)
	if len(pushOf) == 0 {
		return
	}
	if p.beforeQueue != nil {
		p.beforeQueue()
	}
	deadline := savedAt.Add(Freshness)
	var refused []state.AlertPushSettle
	p.mu.Lock()
	for _, d := range begun {
		push, ok := pushOf[d]
		if !ok {
			continue // settled by seal
		}
		reason := ""
		switch {
		case !p.running || p.ctx.Err() != nil: // stopped, or Start's ctx ended: the senders are gone
			reason = state.ReasonStopped
		case p.gen != gen:
			reason = p.abandoned
		default:
			s := p.senderLocked(d)
			if len(s.queue) >= QueuePerPhone {
				reason = state.ReasonOverflow
				break
			}
			s.queue = append(s.queue, item{key: key, device: d, relay: relayOf[d], push: push, deadline: deadline})
			select {
			case s.wake <- struct{}{}:
			default:
			}
		}
		if reason != "" {
			refused = append(refused, state.AlertPushSettle{Key: key, Device: d, Outcome: state.AlertExpired, Reason: reason})
		}
	}
	p.mu.Unlock()
	p.settleAll(refused)
}

// seal seals key's push once per distinct epoch among devices (EpochFor) and
// returns each device's push; the devices of an epoch whose seal failed come
// back as settles (too_large, else failed), and the others keep theirs. An
// older epoch that no longer seals (its keys left retention between EpochFor
// and the seal) falls back to the current one, the rule's own answer past
// retention.
func (p *Pusher) seal(key string, fields secure.WorkAlertFields, devices []string) (map[string]secure.Push, []state.AlertPushSettle) {
	byEpoch := map[uint32][]string{}
	for _, d := range devices {
		var e uint32
		if p.c.EpochFor != nil {
			e = p.c.EpochFor(d)
		}
		byEpoch[e] = append(byEpoch[e], d)
	}
	pushOf := make(map[string]secure.Push, len(devices))
	var failed []state.AlertPushSettle
	for _, e := range slices.Sorted(maps.Keys(byEpoch)) {
		push, err := p.sealIn(e, key, fields)
		if err != nil && e != 0 && !errors.Is(err, secure.ErrAlertTooLarge) {
			log.Printf("hub alerts: push of %s not sealed in epoch %d (%s), sealed in the current epoch", key, e, errClass(err))
			push, err = p.sealIn(0, key, fields)
		}
		if err != nil {
			outcome := state.AlertFailed
			if errors.Is(err, secure.ErrAlertTooLarge) {
				outcome = state.AlertTooLarge
			}
			log.Printf("hub alerts: push of %s not sealed (%s)", key, errClass(err))
			for _, d := range byEpoch[e] {
				failed = append(failed, state.AlertPushSettle{Key: key, Device: d, Outcome: outcome})
			}
			continue
		}
		for _, d := range byEpoch[e] {
			pushOf[d] = push
		}
	}
	return pushOf, failed
}

// sealIn seals key's push in epoch (0 = the current one).
func (p *Pusher) sealIn(epoch uint32, key string, fields secure.WorkAlertFields) (secure.Push, error) {
	s := p.c.Sealer
	if epoch != 0 {
		s = s.InEpoch(epoch)
	}
	return s.AlertPush(key, fields)
}

// Reconnected wakes the pushes waiting after the relay answered UNAVAILABLE:
// the relay has a connection again. Only a sender waiting then reacts.
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

// Abandon settles every queued push expired with reason, and the one each
// phone works on: expired with reason while it waits to retry, expired
// in_flight when its request is in progress, or its own answer when that
// comes first. It returns the alert keys it settled expired (sorted, once
// each). The pusher keeps running; an Enqueue overlapping the Abandon queues
// nothing. The runtime calls it on a switch to CloudKit.
func (p *Pusher) Abandon(reason string) []string {
	p.mu.Lock()
	p.gen++
	p.abandoned = reason
	queued, flights := p.takeAllLocked()
	for _, f := range flights {
		f.cancel(expiry{reason})
	}
	p.mu.Unlock()

	keys := map[string]bool{}
	xs := expireAll(queued, reason)
	for i, ok := range p.settleAll(xs) {
		if ok {
			keys[xs[i].Key] = true
		}
	}
	for _, f := range flights {
		<-f.done
		if f.changed && f.outcome == state.AlertExpired {
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

// Stop settles every queued push expired (reason stopped), and the ones in
// progress (stopped, or in_flight mid-request), and waits for the senders
// and any account refresh to end. No send starts after Stop. Safe to call
// twice.
func (p *Pusher) Stop() {
	p.mu.Lock()
	if p.stopCalled {
		p.mu.Unlock()
		<-p.stopDone // a concurrent or later Stop returns when the first is done
		return
	}
	p.stopCalled = true
	wasRunning := p.running
	p.running, p.stopped = false, true
	var queued []item
	if wasRunning {
		queued, _ = p.takeAllLocked()
		p.cancel(expiry{state.ReasonStopped})
	}
	p.mu.Unlock()
	defer close(p.stopDone)
	if !wasRunning {
		return
	}
	p.settleAll(expireAll(queued, state.ReasonStopped))
	p.wg.Wait()
}

// takeAllLocked empties every queue and returns the items with the flights
// in progress (p.mu held).
func (p *Pusher) takeAllLocked() ([]item, []*flight) {
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

func expireAll(items []item, reason string) []state.AlertPushSettle {
	xs := make([]state.AlertPushSettle, 0, len(items))
	for _, it := range items {
		xs = append(xs, state.AlertPushSettle{Key: it.key, Device: it.device, Outcome: state.AlertExpired, Reason: reason})
	}
	return xs
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

		f.outcome, f.reason, f.changed = p.deliver(ctx, s, it)
		cancel(nil)
		p.mu.Lock()
		s.cur = nil
		p.mu.Unlock()
		close(f.done)
	}
}

// deliver sends one push, retrying inside its freshness window, and settles
// it. It returns the outcome and reason it settled and whether the row
// changed.
func (p *Pusher) deliver(ctx context.Context, s *sender, it item) (string, string, bool) {
	attempts := 0
	finish := func(outcome, reason string) (string, string, bool) {
		changed := p.settleAll([]state.AlertPushSettle{{
			Key: it.key, Device: it.device, Outcome: outcome, Reason: reason, Attempts: attempts,
		}})[0]
		return outcome, reason, changed
	}
	for {
		if err := context.Cause(ctx); err != nil {
			return finish(state.AlertExpired, reasonOf(err))
		}
		remaining := it.deadline.Sub(p.c.Clock())
		if remaining <= 0 {
			return finish(state.AlertExpired, state.ReasonFreshness)
		}
		if !p.away() {
			return finish(state.AlertExpired, state.ReasonOwnerBack)
		}
		// The attempt ends at the window's end; a cancel (Abandon, Stop)
		// issued before this point is seen here, under the lock it is
		// issued under, so no request starts after one.
		actx, acancel := context.WithTimeoutCause(ctx, remaining, expiry{state.ReasonFreshness})
		p.mu.Lock()
		cancelled := ctx.Err() != nil
		p.mu.Unlock()
		if cancelled {
			acancel()
			continue
		}
		attempts++
		err := p.c.Send.SendAlert(actx, it.relay, it.push)
		interrupted := actx.Err() != nil
		acancel()
		if err != nil && !relayAnswered(err) {
			// No relay answer: the request may have reached it.
			// That holds for a freshness timeout mid-request too.
			if interrupted || errors.Is(err, transport.ErrUnavailable) {
				return finish(state.AlertExpired, state.ReasonInFlight)
			}
		}
		outcome, wait, onConnect := classify(err)
		if wait == 0 {
			o, r, changed := finish(outcome, "")
			if changed {
				p.after(it, outcome)
			}
			return o, r, changed
		}
		left := it.deadline.Sub(p.c.Clock())
		if left <= 0 {
			continue // the window ended during the request
		}
		var reconnect <-chan struct{}
		if onConnect {
			select { // a connection that came before this wait is stale
			case <-s.reconnect:
			default:
			}
			reconnect = s.reconnect
		}
		fire, stop := p.c.Timer(min(wait, left))
		select {
		case <-fire:
		case <-reconnect:
		case <-ctx.Done():
		}
		stop()
	}
}

// relayAnswered reports whether err is the relay's own coded answer, as
// opposed to a failure to reach it or to hear back.
func relayAnswered(err error) bool {
	var pe *client.Error
	return errors.As(err, &pe) ||
		errors.Is(err, transport.ErrNoPushToken) || errors.Is(err, transport.ErrPushOff)
}

// after acts on a settled answer: an account refresh after not_paying or
// forbidden, one log line per alert key for a push too large.
func (p *Pusher) after(it item, outcome string) {
	switch outcome {
	case state.AlertNotPaying, state.AlertForbidden:
		p.refresh()
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

// refresh runs RefreshAccount in its own goroutine unless one runs already;
// Stop waits for it, nothing else does.
func (p *Pusher) refresh() {
	if p.c.RefreshAccount == nil {
		return
	}
	p.mu.Lock()
	if p.refreshing || !p.running {
		p.mu.Unlock()
		return
	}
	p.refreshing = true
	ctx := p.ctx
	p.wg.Add(1)
	p.mu.Unlock()
	go func() {
		defer p.wg.Done()
		rctx, cancel := context.WithTimeout(ctx, refreshTimeout)
		defer cancel()
		p.c.RefreshAccount(rctx)
		p.mu.Lock()
		p.refreshing = false
		p.mu.Unlock()
	}()
}

// classify maps a relay answer to its outcome class, or to a retry: the
// wait, and whether a new connection ends it early. Only RATE_LIMITED,
// TRAFFIC_LIMIT_EXCEEDED and the relay's own UNAVAILABLE are retried.
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
	case errors.Is(err, transport.ErrUnavailable) && relayAnswered(err):
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

// settleAll settles xs in one write transaction and logs each row it
// changed (ids and classes only); a row already settled is left as is
// without a line. changed[i] is false for every row when the write fails.
func (p *Pusher) settleAll(xs []state.AlertPushSettle) []bool {
	if len(xs) == 0 {
		return nil
	}
	changed, err := p.c.Store.SettleAlertPushes(xs, p.c.Clock())
	if err != nil {
		log.Printf("hub alerts: %d pushes not settled (%s)", len(xs), errClass(err))
		return make([]bool, len(xs))
	}
	for i, x := range xs {
		if !changed[i] {
			continue
		}
		if x.Reason != "" {
			log.Printf("hub alerts: push of %s to %s: %s (%s) after %d attempts", x.Key, x.Device, x.Outcome, x.Reason, x.Attempts)
		} else {
			log.Printf("hub alerts: push of %s to %s: %s after %d attempts", x.Key, x.Device, x.Outcome, x.Attempts)
		}
		if p.onSettle != nil {
			p.onSettle(x.Key, x.Device, x.Outcome, x.Reason)
		}
	}
	return changed
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
