package hub

import (
	"context"
	"errors"
	"log"
	"time"

	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/relay/relayv1"
)

// NeedsRelayPoll is how often a hub with no paying phone re-reads its
// account state (spec §7.3).
const NeedsRelayPoll = 5 * time.Minute

// ReadRetryFirst is the first wait after a failed account-state read; it
// doubles up to NeedsRelayPoll.
const ReadRetryFirst = 30 * time.Second

// AccountState reads the hub's account state from the relay
// (get_account_state: the phones holding the hub in a slot).
type AccountState func(ctx context.Context) (*relayv1.AccountState, error)

// accountStater is the hosted relay's get_account_state, asserted on the
// transport like admission (*relay.Transport and memfake have it).
type accountStater interface {
	AccountState(ctx context.Context) (*relayv1.AccountState, error)
}

// PayingWatch follows whether a phone holding the hub in a slot pays (spec
// §7.3, relay-only rules): a headless hub without one pauses. It reads the
// account state when Run starts, every NeedsRelayPoll (paying or not), after
// a failed read on a shorter backoff, and at once after an
// ENTITLEMENT_EXPIRED or SLOT_REMOVED control, an ENTITLEMENT_INACTIVE error
// (Observe: events, mailbox passes, publisher saves) or a link change
// (Recheck).
//
// What a pause leaves running, by decision: pairing; the POLICY-03 wipe when
// the policy turns the hub off (deleting published data is the safe
// direction and policy-ordered); held phone lines delivered into local
// sessions (local work — their late echoes are queued, not written).
type PayingWatch struct {
	state AccountState
	timer func(d time.Duration) (<-chan time.Time, func()) // a test's fake clock

	kick chan struct{}
}

// NewPayingWatch watches state.
func NewPayingWatch(state AccountState) *PayingWatch {
	return &PayingWatch{state: state, timer: realTimer, kick: make(chan struct{}, 1)}
}

func realTimer(d time.Duration) (<-chan time.Time, func()) {
	t := time.NewTimer(d)
	return t.C, func() { t.Stop() }
}

// Observe re-reads the account state at once after an ENTITLEMENT_EXPIRED
// or SLOT_REMOVED control, or an ENTITLEMENT_INACTIVE error in ev or saveErr.
func (a *PayingWatch) Observe(ev transport.Event, saveErr error) {
	expired := ev.Control != nil && (ev.Control.Kind == transport.EntitlementExpired || ev.Control.Kind == transport.SlotRemoved)
	if expired || errors.Is(ev.Err, transport.ErrEntitlementInactive) || errors.Is(saveErr, transport.ErrEntitlementInactive) {
		a.Recheck()
	}
}

// Recheck re-reads the account state at once (a phone linked, or the relay
// started taking the hub's subscriptions).
func (a *PayingWatch) Recheck() {
	select {
	case a.kick <- struct{}{}:
	default:
	}
}

// Run reads the account state until ctx ends (it returns ctx.Err()) and
// calls onChange with the first answer and with every change. A failed read
// keeps the last answer and is retried after ReadRetryFirst, doubling up to
// NeedsRelayPoll (or at the next kick).
func (a *PayingWatch) Run(ctx context.Context, onChange func(paying bool)) error {
	known, last := false, false
	var retry time.Duration
	for {
		rctx, cancel := context.WithTimeout(ctx, opTimeout)
		st, err := a.state(rctx)
		cancel()
		if ctx.Err() != nil {
			return ctx.Err()
		}
		wait := NeedsRelayPoll
		if err != nil {
			retry = min(max(2*retry, ReadRetryFirst), NeedsRelayPoll)
			wait = retry
			log.Printf("hub: reading the account state failed (%s), retried in %s", errClass(err), wait)
		} else {
			retry = 0
			if p := paying(st); !known || p != last {
				known, last = true, p
				onChange(p)
			}
		}
		fired, stop := a.timer(wait)
		select {
		case <-ctx.Done():
			stop()
			return ctx.Err()
		case <-a.kick:
		case <-fired:
		}
		stop()
	}
}

// paying: at least one phone holding the hub in a slot is active or in grace.
func paying(st *relayv1.AccountState) bool {
	for _, p := range st.GetPhones() {
		if p.GetPaying() {
			return true
		}
	}
	return false
}
