package hub

// The running hub on CloudKit (Go hub phase 3 Task 15, spec §9, ask #735):
// the mailbox pass cadence by transport, the bridge's pull-now and
// account-changed events, and the CloudKit half of the link center's life —
// the close of a link an earlier run left open, the per-pass share sweep,
// the close after a confirm that linked, the RelayZone hellos and the
// owner's Remove. Every share call goes through the transport's
// transport.Shares (the CloudKit bridge); on a transport without it these
// are no-ops and the hub behaves as on the hosted relay. No share call runs
// on a control request's goroutine or under the supervisor's hubMu: the
// owner's Remove and confirm are answered once their database change is
// made, and their share calls follow on a goroutine of the hub's own, which
// stop cancels and waits for.

import (
	"context"
	"errors"
	"log"
	"time"

	"watchtower/internal/hub/link"
	"watchtower/internal/hub/slices"
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

// cloudKitPassDue: a pass is due at a tick at now when the cadence's
// interval has run since the last pass, within half a tick — the ticks and
// the pass stamps drift by milliseconds, and without the tolerance a 3 s
// cadence on a 3 s ticker would pass every other tick.
func cloudKitPassDue(now, lastPass, lastTouch time.Time, urgent bool) bool {
	if lastPass.IsZero() {
		return true
	}
	return now.Sub(lastPass) >= cloudKitPassEvery(now, lastTouch, urgent)-CloudKitActivePass/2
}

// realTicker is a real ticker as a channel and its stop.
func realTicker(d time.Duration) (<-chan time.Time, func()) {
	t := time.NewTicker(d)
	return t.C, t.Stop
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
// each tick asks the cadence whether a pass is due.
func (h *hubRuntime) passTickEvery() time.Duration {
	if h.tr.Kind() == transport.KindCloudKit {
		return CloudKitActivePass
	}
	return h.sup.o.passEvery
}

// passTick is one tick of the pass ticker (worker only): on CloudKit a pass
// runs when the cadence has one due, elsewhere every tick.
func (h *hubRuntime) passTick(ctx context.Context) {
	if h.tr.Kind() == transport.KindCloudKit &&
		!cloudKitPassDue(h.sup.o.Clock(), h.lastPass, h.touched(), h.center.LinkUrgent()) {
		return
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
// other event. PullNow (a silent push, or the bridge's reconnect, after
// which pushes may have been missed) is the relay's resync: what the phones
// wait for goes out again, the link check runs, and a pass runs at once.
// AccountChanged closes the link the old iCloud user opened.
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
		h.publishSoon(slices.UrgentKinds...)
		h.kick(h.linkKick)
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

// removePhone is the owner's Remove (link.Center.BeginRemove): the phone is
// unlinked before the answer; on CloudKit its iCloud user then leaves the
// shares in the background (a failure there is left to the sweep).
func (h *hubRuntime) removePhone(device string) error {
	finish, err := h.center.BeginRemove(context.Background(), device)
	if err != nil {
		return err
	}
	if s, ok := h.shares(); ok {
		h.inBackground(func(ctx context.Context) { finish(ctx, s) })
	}
	return nil
}

// afterConfirm closes the CloudKit link in the background once a confirm
// linked device (CloseUsed): the public link closes now, the participants
// after the answer grace. A failure keeps the sweep pending (retried by
// SweepShares, and by the next start's restart close).
func (h *hubRuntime) afterConfirm(device string) {
	s, ok := h.shares()
	if !ok {
		return
	}
	if _, linked, err := h.st.Device(device); err != nil || !linked {
		return
	}
	h.inBackground(func(ctx context.Context) {
		if err := h.center.CloseLink(ctx, s, link.CloseUsed); err != nil {
			log.Printf("hub: closing the link after a confirm failed (%s): retried", errClass(err))
		}
	})
}

// inBackground runs fn on a goroutine of the hub's own, under its context
// bounded by opTimeout: stop cancels it and waits for it. Called with the
// supervisor's hubMu read-held (a control request), so stop has not begun.
func (h *hubRuntime) inBackground(fn func(ctx context.Context)) {
	h.wg.Add(1)
	go func() {
		defer h.wg.Done()
		ctx, cancel := context.WithTimeout(h.ctx, opTimeout)
		defer cancel()
		fn(ctx)
	}()
}
