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
	if h.sw != nil {
		// A desktop host links over CloudKit (and unlinks there) whichever
		// transport is active.
		s, ok := h.ck.(transport.Shares)
		return s, ok
	}
	if h.tr.Kind() != transport.KindCloudKit {
		return nil, false
	}
	s, ok := h.tr.(transport.Shares)
	return s, ok
}

// cloudKitCodes reports whether a link code is a CloudKit one — the hub's
// active transport is CloudKit (a desktop host's switch on CloudKit, or a
// CloudKit hub) — and the shares it is issued over; ok is false when such a
// hub has no shares (no code then: a relay code would link the phone where
// the hub does not publish). The active transport can change before the
// code is stored; that code is then the one the phone is answered on
// (accepted: a switch takes a person and minutes).
func (h *hubRuntime) cloudKitCodes() (s transport.Shares, cloudKit, ok bool) {
	if h.tr.Kind() != transport.KindCloudKit {
		return nil, false, false
	}
	s, ok = h.shares()
	return s, true, ok
}

// pairCloudKit issues a CloudKit code (link.Center.IssueCloudKit, which
// emits the qr and waiting events as Issue does) and runs a pass at once
// for the phone's hello. A refusal is answered with its class (LinkErrClass:
// no_icloud, icloud_unreachable, icloud_changed, else failed); a hub stopping
// meanwhile answers hub_off. The refusal's error is returned with it
// (supervisor.pair may answer a relay code instead: relayCodeFallback).
// Called off hubMu with the hub held by its wait group.
func (h *hubRuntime) pairCloudKit(s transport.Shares) (ControlAnswer, string, error) {
	ctx, cancel := context.WithTimeout(h.ctx, opTimeout)
	defer cancel()
	p, _, err := h.center.IssueCloudKit(ctx, s)
	if err != nil {
		class := LinkErrClass(err)
		if h.ctx.Err() != nil {
			class = ErrClassHubOff
		}
		log.Printf("hub: CloudKit code not issued (%s, %s)", class, errClass(err))
		return ControlAnswer{Error: class}, "", err
	}
	h.kick(h.passKick)
	return ControlAnswer{OK: true}, p.Nonce, nil
}

// relayCodeFallback: a CloudKit code refused with err gives way to a relay
// code (iCloud is not needed for linking) — only when the hub has a relay
// that is connected, and only when iCloud is really unusable: the bridge
// answered with an account that refuses linking, or the account could not
// be read although the bridge is past its start. The Mac's user not read
// (ErrOwnerUnknown), an unreadable account while the bridge starts, an
// account change and any other failure keep their refusal, so the Mac still
// says what is wrong with iCloud, or to try again.
func (h *hubRuntime) relayCodeFallback(err error) bool {
	if h.rel == nil || h.relDown.Load() {
		return false
	}
	var ae *link.AccountError
	if !errors.As(err, &ae) {
		return false
	}
	return ae.Account != link.AccountUnreadable || !h.bridgeStarting()
}

// abandonCode closes, in the background, the link of the CloudKit code
// nonce a pairing stream issued, once that stream ended (the sheet closed,
// the CLI stopped) — only while that code is still the one on screen
// (link.Center.CloseCode): waiting phones read not_confirmed and the
// shares' public URLs close now, not at the code's expiry. Called with the
// supervisor's hubMu read-held.
func (h *hubRuntime) abandonCode(nonce string) {
	s, ok := h.shares()
	if !ok {
		return
	}
	h.inBackground(func(ctx context.Context) {
		if err := h.center.CloseCode(ctx, s, nonce, link.CloseSheetClosed); err != nil {
			log.Printf("hub: closing an abandoned code's link failed (%s): retried", errClass(err))
		}
	})
}

// passTickEvery is the worker's pass ticker: Options.passEvery on the hosted
// relay (live events, a backstop only), CloudKitActivePass on CloudKit, where
// each tick asks the cadence whether a pass is due.
func (h *hubRuntime) passTickEvery() time.Duration {
	if h.sw != nil || h.tr.Kind() == transport.KindCloudKit {
		return CloudKitActivePass
	}
	return h.sup.o.passEvery
}

// passTick is one tick of the pass ticker (worker only): on CloudKit a pass
// runs when the cadence has one due, elsewhere every tick.
func (h *hubRuntime) passTick(ctx context.Context) {
	now := h.sup.o.Clock()
	h.laneMu.Lock()
	last := h.lastPass
	h.laneMu.Unlock()
	switch {
	case h.tr.Kind() == transport.KindCloudKit:
		if !cloudKitPassDue(now, last, h.touched(), h.center.LinkUrgent()) {
			return
		}
	case h.sw != nil:
		// A desktop host on the relay: the relay's backstop cadence on
		// the CloudKit ticker.
		if !last.IsZero() && now.Sub(last) < h.sup.o.passEvery-CloudKitActivePass/2 {
			return
		}
	}
	h.pass(ctx)
}

// cloudKitStart closes, once at start, a CloudKit link an earlier run left
// open (a crash with the QR on screen): link.Center.CloseOnStart, which
// sweeps only when the sweep is marked pending, refuses only the earlier
// run's waiting requests (no pair event) and leaves alone a code this run already issued
// (a pair can come before the worker gets here); a failure schedules a
// deferred sweep (worker only).
func (h *hubRuntime) cloudKitStart(ctx context.Context) {
	s, ok := h.shares()
	if !ok {
		h.center.SkipStartClose() // no CloudKit link to close: keep no own codes
		return
	}
	ctx, cancel := context.WithTimeout(ctx, opTimeout)
	defer cancel()
	if err := h.center.CloseOnStart(ctx, s); err != nil {
		log.Printf("hub: closing the link an earlier run left open failed (%s): retried", errClass(err))
	}
}

// stopCloseTimeout bounds the stop's close of a CloudKit code's link.
const stopCloseTimeout = 10 * time.Second

// cloudKitStop closes, at stop while the bridge still runs, the link of a
// CloudKit code still on screen (link.Center.CloseOnStop), so the shares'
// public URLs do not outlive the hub. Best effort and bounded: a failure,
// and the participants' sweep, are left to the next start's close. No share
// call when no code is open.
func (h *hubRuntime) cloudKitStop() {
	s, ok := h.shares()
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), stopCloseTimeout)
	defer cancel()
	if err := h.center.CloseOnStop(ctx, s); err != nil {
		log.Printf("hub: closing the link at stop failed (%s): closed at the next start", errClass(err))
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
// AccountChanged wipes what was published into the old account's zones
// (resetCloudKit), rereads the account and closes the link the old iCloud user
// opened; ZonesRecreated (a zone deleted on the server) wipes what was
// published there.
func (h *hubRuntime) cloudKitEvent(ctx context.Context, ev transport.Event) bool {
	switch {
	case ev.ZonesRecreated:
		h.resetCloudKit(ctx, false)
		return true
	case ev.AccountChanged:
		// The wipe first: a hold the new account lifts resumes onto it.
		h.resetCloudKit(ctx, true)
		h.refreshCloudKitAccount(ctx)
		if s, ok := h.shares(); ok {
			cctx, cancel := context.WithTimeout(ctx, opTimeout)
			err := h.center.AccountChanged(cctx, s)
			cancel()
			if err != nil {
				log.Printf("hub: closing the link after an iCloud account change failed (%s): retried", errClass(err))
			}
		}
		return true
	case ev.PullNow: // reachable again: noted by the event lane (noteReach)
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
