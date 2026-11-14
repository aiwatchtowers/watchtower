package hub

import (
	"context"
	"database/sql"
	"errors"
	"log"
	"strconv"
	"sync"
	"time"

	"google.golang.org/protobuf/proto"

	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/switcher"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/relay/relayv1"
)

// unvouchedPoll is the relay's floor between two account-state reads of a
// hub in no phone's slot that waits for one (relay proto README, "Vouched
// hubs": "poll get_account_state at most every 30 s while it expects a
// slot"). Every account-state read of the running hub — the short link
// retry's 2 s ticks, the link backstop, the readers sync, the PayingWatch —
// goes through accountReader, which answers a read inside the window from
// the last one. A SLOT_ADDED control is no poll: the relay transport reads
// at once on it.
const unvouchedPoll = 30 * time.Second

// The hosted relay's account side, asserted on the transport.
type (
	// accountStater is get_account_state (*relay.Transport and memfake).
	accountStater interface {
		AccountState(ctx context.Context) (*relayv1.AccountState, error)
	}
	// relayAdmission is the relay's view of the hub from the last account
	// state (*relay.Transport only): Vouched = in some phone's slot (the
	// relay opens the data zone and the mailboxes), Admitted = in a paying
	// phone's slot. A transport without it (memfake) is always open.
	relayAdmission interface {
		Vouched() bool
		Admitted() bool
		LastAccountState() *relayv1.AccountState
	}
)

// accountReader is the running hub's one door to get_account_state: while
// the transport says the hub is unvouched, a read less than unvouchedPoll
// after the last one answers the last answer instead.
type accountReader struct {
	read    AccountState
	vouched func() bool
	clock   func() time.Time

	mu      sync.Mutex
	at      time.Time // the last real read's start (zero = none yet)
	last    *relayv1.AccountState
	lastErr error
}

// seed records a read the transport made by itself (Connect's, SLOT_ADDED's).
// An empty state is no read (the transport may never have read one, or
// forgot its slots on HUB_NOT_VOUCHED): it arms no window.
func (r *accountReader) seed(st *relayv1.AccountState) {
	if len(st.GetPhones()) == 0 {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.at, r.last, r.lastErr = r.clock(), st, nil
}

// invalidate forgets the last answer after HUB_NOT_VOUCHED: the next read
// goes to the relay (the window's limit holds again from that read), so a
// pre-revoke state is never answered from the cache.
func (r *accountReader) invalidate() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.at, r.last, r.lastErr = time.Time{}, nil, nil
}

// State is one read of the account state. The window starts when a read
// starts (the lock is not held over it): a read during a slow one answers
// the answer before it.
func (r *accountReader) State(ctx context.Context) (*relayv1.AccountState, error) {
	return r.get(ctx, false)
}

// get is State and Fresh over one locked decision: inside the window a plain
// read answers the last answer, a fresh one never does.
func (r *accountReader) get(ctx context.Context, fresh bool) (*relayv1.AccountState, error) {
	r.mu.Lock()
	now := r.clock()
	if !r.vouched() && !r.at.IsZero() && now.Sub(r.at) < unvouchedPoll {
		last, lastErr := r.last, r.lastErr
		r.mu.Unlock()
		if fresh {
			if lastErr != nil {
				return nil, lastErr
			}
			return nil, switcher.ErrNotFresh
		}
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

// Fresh is State for a caller that must not take an earlier answer for a
// new one (the G2 check): inside the window it answers the last read's error
// if that read failed, else switcher.ErrNotFresh, never the cached state.
func (r *accountReader) Fresh(ctx context.Context) (*relayv1.AccountState, error) {
	return r.get(ctx, true)
}

// readAccount is the hub's account-state read: through the reader, then the
// admission stamps and the gate follow the answer.
func (h *hubRuntime) readAccount(ctx context.Context) (*relayv1.AccountState, error) {
	return h.followed(h.acct.State(ctx))
}

// followed is readAccount's tail: the stamps and the gate follow an answer,
// and so does relay_serving_nobody_since (every answered read, the switcher's
// Step and G2 poll included; a failed read changes nothing).
func (h *hubRuntime) followed(st *relayv1.AccountState, err error) (*relayv1.AccountState, error) {
	if err != nil {
		return nil, err
	}
	if err := noteServingNobody(h.kr, h.st, st, h.sup.o.Clock()); err != nil {
		log.Printf("hub: relay_serving_nobody_since not written (%s)", errClass(err))
	}
	h.followAccount(st)
	return st, nil
}

// noteServingNobody keeps relay_serving_nobody_since from an answered account
// read while the hub is on the relay: set (keeping an earlier since) when the
// read holds no linked phone in a slot or no phone pays, removed when a phone
// pays and a linked phone holds the hub in a slot (asks #1077, #1081). Off the
// relay it writes nothing (a rotation toward iCloud removed it). The keyring's
// rotation check reads it: no age rotation while it is set, and one rotation
// that clears every relay key ServingNobodyHold after it.
func noteServingNobody(kr *identity.Keyring, st *state.Store, acct *relayv1.AccountState, now time.Time) error {
	on, err := kr.OnRelay()
	if err != nil || !on {
		return err
	}
	devices, err := st.Devices()
	if err != nil {
		return err
	}
	linked := map[string]bool{}
	for _, d := range devices {
		if d.RelayDeviceID != "" {
			linked[d.RelayDeviceID] = true
		}
	}
	reader, payer := false, false
	for _, p := range acct.GetPhones() {
		reader = reader || linked[p.GetPhoneDeviceId()]
		payer = payer || p.GetPaying()
	}
	serves := reader && payer
	// Most reads change nothing: decided on a plain read, written (and
	// decided again) under the write lock only when it would change.
	if v, ok, err := st.Meta(state.MetaServingNobodySince); err != nil {
		return err
	} else if serves == !ok || (!serves && validSince(v)) {
		return nil
	}
	if servingNobodyBeforeWrite != nil {
		servingNobodyBeforeWrite()
	}
	return st.WithTx(context.Background(), func(tx *sql.Tx) error {
		// "On the relay" decided again under the write lock: a switch to
		// iCloud that committed since the plain read removed the mark, and
		// the mark never outlives the relay.
		if on, err := kr.OnRelayTx(tx); err != nil || !on {
			return err
		}
		if serves {
			return state.DeleteMetaTx(tx, state.MetaServingNobodySince)
		}
		v, ok, err := state.MetaTx(tx, state.MetaServingNobodySince)
		if err != nil || (ok && validSince(v)) {
			return err // the earlier since stands
		}
		return state.SetMetaTx(tx, state.MetaServingNobodySince, strconv.FormatInt(now.Unix(), 10))
	})
}

// servingNobodyBeforeWrite, when set, runs between noteServingNobody's plain
// read and its write transaction: the tests' seam for a commit in between.
var servingNobodyBeforeWrite func()

// validSince: a stored relay_serving_nobody_since is a number (one that is
// not is written afresh).
func validSince(v string) bool {
	_, err := strconv.ParseInt(v, 10, 64)
	return err == nil
}

// rotationAlso is housekeeping's check in the rotation's transaction: no age
// rotation while a switch is in progress (switcher.RotationBlocked).
func rotationAlso(tx *sql.Tx) error {
	blocked, err := switcher.RotationBlocked(tx)
	if err != nil {
		return err
	}
	if blocked {
		return identity.ErrSkipRotation
	}
	return nil
}

// phoneEpoch is the processors' EpochFor: the epoch a phone's echoes and
// controls are sealed in (identity.Keyring.PhoneEpoch), 0 for the current.
func (h *hubRuntime) phoneEpoch(device string) (uint32, error) {
	d, ok, err := h.st.Device(device)
	if err != nil || !ok {
		return 0, err
	}
	return h.kr.PhoneEpoch(d)
}

// followAccount stamps the phones st lists and follows the vouch state.
func (h *hubRuntime) followAccount(st *relayv1.AccountState) {
	h.markAdmitted(phoneIDs(st))
	h.refreshGate()
}

// phoneIDs lists the relay device ids of the phones st holds the hub for.
func phoneIDs(st *relayv1.AccountState) []string {
	ids := make([]string, 0, len(st.GetPhones()))
	for _, p := range st.GetPhones() {
		ids = append(ids, p.GetPhoneDeviceId())
	}
	return ids
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
		h.retryZonesNow()
		h.sup.poke()
	}
}

// retryZonesNow follows the relay admitting the hub for a phone: the zones
// it refused (that phone's mailbox above all) are subscribed by a link
// upkeep now, not at their backoff (watchZones). Safe from any goroutine.
func (h *hubRuntime) retryZonesNow() {
	h.zonesDue.Store(true)
	h.kick(h.linkKick)
}

// vouched: the relay opens the hub's data zone and mailboxes to it (a
// transport without the notion always does).
func (h *hubRuntime) vouched() bool {
	if a, ok := h.tr.(relayAdmission); ok {
		return a.Vouched()
	}
	return true
}

// vouchState is vouched and the account state it was read from (nil for a
// transport without the notion), from one copy of the state: the relay
// transport's Vouched is "the last account state lists a phone", so the
// phones the gate opens on are the phones it stamps.
func (h *hubRuntime) vouchState() (bool, *relayv1.AccountState) {
	if a, ok := h.tr.(relayAdmission); ok {
		st := a.LastAccountState()
		return len(st.GetPhones()) > 0, st
	}
	return true, nil
}

// refreshGate follows the transport's vouch state: an unvouched hub writes
// nothing but its pairing zones, so its publisher and processor hold.
func (h *hubRuntime) refreshGate() {
	h.mu.Lock()
	v, st := h.vouchState() // under mu: concurrent callers set unvouched in read order
	was := h.unvouched
	h.unvouched = !v
	changed := was != h.unvouched
	h.mu.Unlock()
	if !changed {
		return
	}
	if v {
		// The gate opens on the transport's state, which may be newer than
		// the answer its caller followed (a SLOT_ADDED read landing while a
		// cached answer was followed): the phones it lists are stamped too,
		// so a revoke after this opening reads vouch_revoked.
		h.markAdmitted(phoneIDs(st))
		log.Printf("hub: vouched on the relay (in a phone's slot)")
		h.kick(h.linkKick)
		h.recheckPaying()
	} else {
		log.Printf("hub: not vouched on the relay (in no phone's slot): only pairing goes on")
	}
	h.applyGate()
}

// applyGate holds or releases the publisher and the processor: held while
// the relay-only rules pause the hub or the relay has not vouched for it
// (isHeld). Releasing them runs one full diff and one mailbox pass, which
// write what was queued meanwhile.
func (h *hubRuntime) applyGate() {
	h.gateMu.Lock()
	defer h.gateMu.Unlock()
	want := h.isHeld()
	if want == h.gateHeld {
		return
	}
	h.gateHeld = want
	if want {
		h.pub.Pause()
		for _, p := range h.processors() {
			p.SetPaused(true)
		}
	} else {
		for _, p := range h.processors() {
			p.SetPaused(false)
		}
		h.pub.Resume()
		h.kick(h.passKick)
	}
	h.sup.poke()
}

// isHeld: the publisher and the processor hold (paused or unvouched).
func (h *hubRuntime) isHeld() bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.paused || h.unvouched
}

// isUnvouched: the relay has not vouched for the hub (in no phone's slot).
func (h *hubRuntime) isUnvouched() bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.unvouched
}

// vouchReason is the status reason of an unvouched hub: vouch_revoked when a
// linked phone had been admitted (the hub left every slot), else
// not_vouched. It runs on the status path only (rare); an unreadable
// sidecar reads as not_vouched on purpose: both mean "link a phone again".
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
// account state before the event went out, so the gate opens at once and the
// phones it lists are stamped. A repeat changes nothing.
func (h *hubRuntime) onSlotAdded() {
	if a, ok := h.relayT().(relayAdmission); ok {
		st := a.LastAccountState()
		if h.acct != nil {
			h.acct.seed(st)
		}
		h.followAccount(st)
	}
	h.retryZonesNow()
	h.recheckPaying()
}

// noteNotVouched follows a HUB_NOT_VOUCHED answer (the transport forgot its
// slots): the gate closes at once. No retry follows it; the reads and
// SLOT_ADDED open the gate again.
func (h *hubRuntime) noteNotVouched(err error) {
	if errors.Is(err, transport.ErrNotVouched) {
		if h.acct != nil {
			h.acct.invalidate()
		}
		h.refreshGate()
	}
}
