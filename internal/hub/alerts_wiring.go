package hub

import (
	"context"
	"errors"
	"log"
	"time"

	"watchtower/internal/hub/alerts"
	"watchtower/internal/hub/platform"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/slices"
	"watchtower/internal/hub/slices/sources"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
)

// The work-alert pushes over the hosted relay (Go hub plan 4 Task 5, spec
// §12a "Alerts"): the publisher hands each alert's first save on the relay
// to the pusher, a switch to CloudKit drops the queued pushes and signals
// those alerts there, and a relay connection that comes back wakes the
// pushes waiting after an UNAVAILABLE answer.

// awayInput is the owner-away input of the work-alert policy and of the
// pusher (one source for both).
func (o Options) awayInput() platform.Away {
	if o.away != nil {
		return o.away
	}
	return platform.NewAway()
}

// newPusher builds the alert pusher over the relay transport when it sends
// alerts (none otherwise: a CloudKit-only desktop host, memfake).
func (h *hubRuntime) newPusher(sealer *secure.Sealer) {
	send, ok := h.relayT().(transport.Alerts)
	if !ok {
		return
	}
	h.push = alerts.New(alerts.Config{
		Store: h.st, Sealer: sealer, Send: send, Targets: h.pushTargets, RefreshAccount: h.refreshForPush,
		Away: h.sup.o.awayInput(), Clock: h.sup.o.Clock,
	})
}

// startPusher settles the pushes a previous run left pending and starts the
// senders; a failure is logged and leaves the hub without pushes this run
// (Enqueue refuses while the pusher is not running).
func (h *hubRuntime) startPusher(ctx context.Context) {
	if h.push == nil {
		return
	}
	if err := h.push.Start(ctx); err != nil {
		log.Printf("hub: alert pushes off this run (%s)", errClass(err))
	}
}

// stopPusher settles what is queued or in flight and waits for the senders.
func (h *hubRuntime) stopPusher() {
	if h.push != nil {
		h.push.Stop()
	}
}

// alertSaved is the publisher's OnAlertSaved: a new alert saved on the relay
// is pushed to the paying phones.
func (h *hubRuntime) alertSaved(key string, fields secure.WorkAlertFields, savedAt time.Time) {
	if h.push != nil {
		h.push.Enqueue(key, fields, savedAt)
	}
}

// errNoAccountState: the relay transport keeps no account state to push by.
var errNoAccountState = errors.New("hub: the transport keeps no account state")

// pushTargets is the pusher's Targets: the linked phones with a relay device
// id that the last account state holds in a paying slot (a paying phone in
// the hub's slot is one of its readers). It reads what the transport last
// read, never the relay: Enqueue runs on the publisher's cycle.
func (h *hubRuntime) pushTargets(context.Context) ([]alerts.Target, error) {
	a, ok := h.relayT().(relayAdmission)
	if !ok {
		return nil, errNoAccountState
	}
	devices, err := h.st.Devices()
	if err != nil {
		return nil, err
	}
	return alerts.Eligible(devices, a.LastAccountState()), nil
}

// refreshForPush is the pusher's RefreshAccount after a not_paying or
// forbidden answer: one read of the account state through the hub's door,
// which the next push's targets see.
func (h *hubRuntime) refreshForPush(ctx context.Context) {
	if h.acct == nil {
		return
	}
	if _, err := h.readAccount(ctx); err != nil {
		log.Printf("hub: account state after a refused push unreadable (%s)", errClass(err))
	}
}

// switchedTo is the switcher's OnSwitched.
func (h *hubRuntime) switchedTo(target transport.Kind) {
	switchPushes(h.push, h.pub, target)
}

// switchPushes follows a committed switch: toward CloudKit every queued or
// pending push settles expired (switched) and the alerts they were for are
// signalled on CloudKit (Publisher.Resignal); toward the relay nothing
// changes (the alerts already published are not pushed).
func switchPushes(push *alerts.Pusher, pub *slices.Publisher, target transport.Kind) {
	if target != transport.KindCloudKit || push == nil {
		return
	}
	keys := push.Abandon(state.ReasonSwitched)
	if pub != nil {
		pub.Resignal(keys)
	}
}

// pushReconnected tells the pusher the relay connection is back.
func (h *hubRuntime) pushReconnected() {
	if h.push != nil {
		h.push.Reconnected()
	}
}

// pruneAlertPushes drops the push ledger rows older than the alert lifetime
// (7 days), on the latency samples' prune cadence.
func (h *hubRuntime) pruneAlertPushes() {
	if h.sup == nil {
		return
	}
	if err := h.st.PruneAlertPushes(h.sup.o.Clock().Add(-sources.WorkAlertLifetime)); err != nil {
		log.Printf("hub: pruning the alert push ledger failed (%s)", errClass(err))
	}
}
