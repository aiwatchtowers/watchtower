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
// account state when Run starts, every NeedsRelayPoll while no phone pays,
// and at once after an ENTITLEMENT_EXPIRED or SLOT_REMOVED control, an
// ENTITLEMENT_INACTIVE error (Observe) or a link change (Recheck).
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
// keeps the last answer and is retried on the next poll or kick.
func (a *PayingWatch) Run(ctx context.Context, onChange func(paying bool)) error {
	known, last := false, false
	for {
		rctx, cancel := context.WithTimeout(ctx, opTimeout)
		st, err := a.state(rctx)
		cancel()
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if err != nil {
			log.Printf("hub: reading the account state failed (%s)", errClass(err))
		} else if p := paying(st); !known || p != last {
			known, last = true, p
			onChange(p)
		}
		var (
			fired <-chan time.Time
			stop  = func() {}
		)
		if !last {
			fired, stop = a.timer(NeedsRelayPoll)
		}
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
