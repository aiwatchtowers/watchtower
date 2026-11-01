package hub

// The running hub on CloudKit (Go hub phase 3 Task 15, spec §9, ask #735):
// the mailbox pass cadence by transport, the bridge's pull-now and
// account-changed events, and the CloudKit half of the link center's life —
// the close of a link an earlier run left open, the per-pass share sweep,
// the close after a confirm that linked, the RelayZone hellos and the
// owner's Remove. Every share call goes through the transport's
// transport.Shares (the CloudKit bridge); on a transport without it these
// are no-ops and the hub behaves as on the hosted relay.

import (
	"context"
	"errors"
	"log"
	"time"

	"watchtower/internal/hub/link"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
)

// The CloudKit mailbox pass cadence (spec §9; the Swift
// defaultRelayActiveInterval / defaultRelayIdleInterval): CloudKitActivePass
// while a phone was in touch within cloudKitTouchWindow or a link is
// waiting (a code on screen, an answering close's grace), else
// CloudKitIdlePass. A bridge push (PullNow) runs a pass at once.
const CloudKitActivePass, CloudKitIdlePass = 3 * time.Second, 30 * time.Second

// cloudKitTouchWindow is how long after a phone's last write the CloudKit
// pass stays at its active cadence (spec §9: 10 minutes).
const cloudKitTouchWindow = 10 * time.Minute

// cloudKitPassEvery is the CloudKit pass cadence at now: active while the
// last phone write (lastTouch, zero = none) is within cloudKitTouchWindow or
// a link is urgent, else idle.
func cloudKitPassEvery(now, lastTouch time.Time, urgent bool) time.Duration {
	if urgent || (!lastTouch.IsZero() && now.Sub(lastTouch) < cloudKitTouchWindow) {
		return CloudKitActivePass
	}
	return CloudKitIdlePass
}

// shares is the transport's CloudKit linking surface; false on a transport
// that has none (the hosted relay).
func (h *hubRuntime) shares() (transport.Shares, bool) {
	if h.tr.Kind() != transport.KindCloudKit {
		return nil, false
	}
	s, ok := h.tr.(transport.Shares)
	return s, ok
}

// passTickEvery is the worker's pass ticker: Options.passEvery on the hosted
// relay (live events, a backstop only), CloudKitActivePass on CloudKit, where
// each tick asks passDue whether the cadence wants a pass now.
func (h *hubRuntime) passTickEvery() time.Duration {
	if h.tr.Kind() == transport.KindCloudKit {
		return CloudKitActivePass
	}
	return h.sup.o.passEvery
}

// passTick is one tick of the pass ticker (worker only): on CloudKit a pass
// runs once the cadence's interval passed since the last one, elsewhere
// every tick.
func (h *hubRuntime) passTick(ctx context.Context) {
	if h.tr.Kind() == transport.KindCloudKit {
		now := h.sup.o.Clock()
		if !h.lastPass.IsZero() && now.Sub(h.lastPass) < cloudKitPassEvery(now, h.touched(), h.center.LinkUrgent()) {
			return
		}
	}
	h.pass(ctx)
}

// cloudKitStart closes, once at start, a CloudKit link an earlier run left
// open (a crash with the QR on screen): CloseLink(CloseRestart), which
// sweeps only when the sweep is marked pending (worker only).
func (h *hubRuntime) cloudKitStart(ctx context.Context) {
	s, ok := h.shares()
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(ctx, opTimeout)
	defer cancel()
	if err := h.center.CloseLink(ctx, s, link.CloseRestart); err != nil {
		log.Printf("hub: closing the link an earlier run left open failed (%s): retried", errClass(err))
	}
}

// sweepShares is the CloudKit link's housekeeping on every pass
// (link.Center.SweepShares).
func (h *hubRuntime) sweepShares(ctx context.Context) {
	s, ok := h.shares()
	if !ok {
		return
	}
	if err := h.center.SweepShares(ctx, s); err != nil {
		log.Printf("hub: share sweep failed (%s): retried", errClass(err))
	}
}

// cloudKitEvent handles the CloudKit bridge's own events; false for any
// other event. PullNow (a silent push, or a reconnect that may have missed
// pushes) runs a pass at once; AccountChanged closes the link the old
// iCloud user opened.
func (h *hubRuntime) cloudKitEvent(ctx context.Context, ev transport.Event) bool {
	switch {
	case ev.AccountChanged:
		if s, ok := h.shares(); ok {
			cctx, cancel := context.WithTimeout(ctx, opTimeout)
			err := h.center.AccountChanged(cctx, s)
			cancel()
			if err != nil {
				log.Printf("hub: closing the link after an iCloud account change failed (%s): retried", errClass(err))
			}
		}
		return true
	case ev.PullNow:
		h.setUnreachable(false)
		h.pass(ctx)
		return true
	}
	return false
}

// cloudKitHello is the processor's hello lane (actions.Config.Hello): a
// hello read from CloudKit's shared RelayZone goes to the link center. A
// dropped hello is no error (nothing to read again); any other failure
// leaves the page for the next pass.
func (h *hubRuntime) cloudKitHello(ctx context.Context, rec transport.Stored) error {
	s, ok := h.shares()
	if !ok {
		return nil
	}
	if _, err := h.center.HandleCloudKitHello(ctx, s, rec); err != nil && !errors.Is(err, link.ErrHelloDropped) {
		return err
	}
	return nil
}

// removePhone is the owner's Remove: on CloudKit RemoveCloudKit (the
// phone's iCloud user leaves the shares at once), elsewhere Unlink. A
// participant removal that failed once the phone was unlinked answers OK:
// the sweep removes the participant later.
func (h *hubRuntime) removePhone(device string) error {
	s, ok := h.shares()
	if !ok {
		return h.center.Unlink(device)
	}
	ctx, cancel := context.WithTimeout(context.Background(), opTimeout)
	defer cancel()
	err := h.center.RemoveCloudKit(ctx, s, device)
	if err == nil || errors.Is(err, state.ErrNoDevice) {
		return err
	}
	if _, linked, rerr := h.st.Device(device); rerr == nil && !linked {
		log.Printf("hub: phone unlinked, its share participant left to the sweep (%s)", errClass(err))
		return nil
	}
	return err
}

// afterConfirm closes the CloudKit link once a confirm linked device
// (CloseUsed): the public link closes now, the participants after the
// answer grace.
func (h *hubRuntime) afterConfirm(device string) {
	s, ok := h.shares()
	if !ok {
		return
	}
	if _, linked, err := h.st.Device(device); err != nil || !linked {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), opTimeout)
	defer cancel()
	if err := h.center.CloseLink(ctx, s, link.CloseUsed); err != nil {
		log.Printf("hub: closing the link after a confirm failed (%s): retried", errClass(err))
	}
}
