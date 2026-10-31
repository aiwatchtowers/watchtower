package hub

import (
	"context"
	"errors"
	"log"
	"sync"
	"time"

	"google.golang.org/protobuf/proto"

	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/relay/relayv1"
)

// UnvouchedPoll is the relay's floor between two account-state reads of a
// hub in no phone's slot that waits for one (relay proto README, "Vouched
// hubs": "poll get_account_state at most every 30 s while it expects a
// slot"). Every poll of the running hub — the short link retry's 2 s ticks,
// the link backstop, the PayingWatch — goes through accountReader, which
// answers a read inside the window from the last one. A SLOT_ADDED control
// is no poll: the relay transport reads at once on it.
const UnvouchedPoll = 30 * time.Second

// vouchState is the hosted relay's view of whether the hub is in any
// phone's slot (relay.Transport.Vouched); a transport without it (memfake)
// is always open to the hub.
type vouchState interface{ Vouched() bool }

// accountReader is the running hub's one door to get_account_state for its
// polls: while the transport says the hub is unvouched, a read less than
// UnvouchedPoll after the last one answers the last answer instead.
type accountReader struct {
	read    AccountState
	vouched func() bool
	clock   func() time.Time

	mu      sync.Mutex
	at      time.Time // the last real read (zero = none yet)
	last    *relayv1.AccountState
	lastErr error
}

// State is one poll of the account state. The window starts when a read
// starts (the lock is not held over it): a poll during a slow read answers
// the answer before it.
func (r *accountReader) State(ctx context.Context) (*relayv1.AccountState, error) {
	r.mu.Lock()
	now := r.clock()
	if !r.vouched() && !r.at.IsZero() && now.Sub(r.at) < UnvouchedPoll {
		last, lastErr := r.last, r.lastErr
		r.mu.Unlock()
		if last == nil {
			if lastErr == nil {
				lastErr = errors.New("hub: the account state is being read")
			}
			return nil, lastErr
		}
		return proto.Clone(last).(*relayv1.AccountState), nil
	}
	r.at = now
	r.mu.Unlock()
	st, err := r.read(ctx)
	r.mu.Lock()
	if err != nil {
		r.lastErr = err
	} else {
		r.last, r.lastErr = st, nil
	}
	r.mu.Unlock()
	if err != nil {
		return nil, err
	}
	return proto.Clone(st).(*relayv1.AccountState), nil
}

// readAccount is the hub's account-state poll: through the reader, then
// the admission stamps and the gate follow the answer.
func (h *hubRuntime) readAccount(ctx context.Context) (*relayv1.AccountState, error) {
	st, err := h.acct.State(ctx)
	if err != nil {
		return nil, err
	}
	ids := make([]string, 0, len(st.GetPhones()))
	for _, p := range st.GetPhones() {
		ids = append(ids, p.GetPhoneDeviceId())
	}
	h.markAdmitted(ids)
	h.refreshGate()
	return st, nil
}

// markAdmitted stamps relay_admitted_at on the linked phones the relay
// lists as holding the hub in a slot.
func (h *hubRuntime) markAdmitted(relayIDs []string) {
	if len(relayIDs) == 0 {
		return
	}
	n, err := h.st.MarkRelayAdmitted(relayIDs, h.sup.o.Clock())
	if err != nil {
		log.Printf("hub: stamping the relay admission failed (%s)", errClass(err))
		return
	}
	if n > 0 {
		log.Printf("hub: the relay admitted the hub for %d linked phone(s)", n)
		h.sup.poke()
	}
}

// vouched: the relay opens the hub's data zone and mailboxes to it (a
// transport without the notion always does).
func (h *hubRuntime) vouched() bool {
	if v, ok := h.tr.(vouchState); ok {
		return v.Vouched()
	}
	return true
}

// refreshGate follows the transport's vouch state: an unvouched hub writes
// nothing but its pairing zones, so its publisher and processor hold.
func (h *hubRuntime) refreshGate() {
	v := h.vouched()
	h.mu.Lock()
	changed := h.unvouched == v
	h.unvouched = !v
	h.mu.Unlock()
	if !changed {
		return
	}
	if v {
		log.Printf("hub: vouched on the relay (in a phone's slot)")
		h.kick(h.linkKick)
		h.recheckPaying()
	} else {
		log.Printf("hub: not vouched on the relay (in no phone's slot): only pairing goes on")
	}
	h.applyGate()
}

// applyGate holds or releases the publisher and the processor: held while
// the relay-only rules pause the hub or the relay has not vouched for it.
// Releasing it runs one full diff and one mailbox pass, which write what
// was queued meanwhile.
func (h *hubRuntime) applyGate() {
	h.gateMu.Lock()
	defer h.gateMu.Unlock()
	h.mu.Lock()
	want := h.paused || h.unvouched
	changed := want != h.held
	h.held = want
	h.mu.Unlock()
	if !changed {
		return
	}
	if want {
		h.pub.Pause()
		h.proc.SetPaused(true)
	} else {
		h.proc.SetPaused(false)
		h.pub.Resume()
		h.kick(h.passKick)
	}
	h.sup.poke()
}

// isHeld: the publisher and the processor hold (paused or unvouched).
func (h *hubRuntime) isHeld() bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.held
}

// isUnvouched: the relay has not vouched for the hub (in no phone's slot).
func (h *hubRuntime) isUnvouched() bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.unvouched
}

// vouchReason is the status reason of an unvouched hub: vouch_revoked when
// a linked phone had been admitted (the hub left every slot), else
// not_vouched.
func (h *hubRuntime) vouchReason() string {
	devices, err := h.st.Devices()
	if err != nil {
		return ReasonNotVouched
	}
	for _, d := range devices {
		if !d.RelayAdmittedAt.IsZero() {
			return ReasonVouchRevoked
		}
	}
	return ReasonNotVouched
}

// onSlotAdded follows Control{SLOT_ADDED}: the relay transport read the
// account state before the event went out, so the gate opens at once and
// the phone named in the control is stamped. A repeat changes nothing.
func (h *hubRuntime) onSlotAdded(phone string) {
	if h.vouched() {
		h.markAdmitted([]string{phone})
	}
	h.refreshGate()
	h.kick(h.linkKick)
	h.recheckPaying()
}

// noteNotVouched follows a HUB_NOT_VOUCHED answer (the transport forgot its
// slots): the gate closes. No retry follows it; the polls and SLOT_ADDED
// open the gate again.
func (h *hubRuntime) noteNotVouched(err error) {
	if errors.Is(err, transport.ErrNotVouched) {
		h.refreshGate()
	}
}
