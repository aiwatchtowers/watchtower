package hub

// The iCloud account's effects on the CloudKit side, as the Swift hub had
// them (ask #969 Q3, "do it as Swift"): with no usable account the CloudKit
// side stops and starts again by itself when the account comes back; an
// account change, or a hub zone deleted on the server, wipes what the hub
// believes is published (and, for an account change, CloudKit's mailbox
// cursor) and republishes everything.

import (
	"context"
	"log"

	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/slices/sources"
	"watchtower/internal/hub/transport"
)

// The publisher and processor holds of this file (reason sets: they never
// lift the admission gate's or the transport switch's).
const (
	pauseNoICloud      = "no_icloud"
	pauseCloudKitReset = "cloudkit_reset"
)

// cloudKitProcessor is the processor reading CloudKit's mailbox (nil on a
// hub without CloudKit).
func (h *hubRuntime) cloudKitProcessor() *actions.Processor {
	if h.sw != nil {
		return h.sw.Processor(transport.KindCloudKit)
	}
	if h.tr != nil && h.tr.Kind() == transport.KindCloudKit {
		return h.proc
	}
	return nil
}

// applyICloudHold holds the CloudKit side while the bridge reports an
// account that cannot be used (no account, restricted, temporarily
// unavailable, no entitlement) and releases it once the account is
// available again — the Swift hub's unavailable state and its re-probe; here
// the account is read at start, each daemon cycle, every houseEvery and on
// the bridge's account change. Held, CloudKit's processor reads nothing
// and, while CloudKit is the active transport, the publisher publishes
// nothing and no mailbox pass (nor its share sweep) runs; a desktop host's
// relay side goes on. An account not read yet holds nothing. The release
// runs one full diff (the publisher's resume) and one pass.
func (h *hubRuntime) applyICloudHold() {
	h.ckHoldMu.Lock()
	defer h.ckHoldMu.Unlock()
	// Read under ckHoldMu, so a caller holding an older answer never
	// applies it after a newer one.
	h.mu.Lock()
	acct := h.ckAccount
	h.mu.Unlock()
	off := acct != "" && acct != transport.AccountAvailable
	if off != h.ckHeld {
		if p := h.cloudKitProcessor(); p != nil {
			if off {
				p.PauseFor(pauseNoICloud)
			} else {
				p.ResumeFor(pauseNoICloud)
			}
		}
		if off {
			log.Printf("hub: the iCloud account is %s: CloudKit paused until it is available", acct)
		} else {
			log.Printf("hub: the iCloud account is available: CloudKit resumed")
		}
	}
	pub := off && h.tr.Kind() == transport.KindCloudKit
	paused := pub != h.ckPubHeld.Load()
	if paused && h.pub != nil {
		if pub {
			h.pub.PauseFor(pauseNoICloud)
		} else {
			h.pub.ResumeFor(pauseNoICloud)
		}
	}
	released := h.ckHeld && !off
	h.ckHeld = off
	h.ckPubHeld.Store(pub)
	if released {
		h.kick(h.passKick)
	}
	if paused {
		h.sup.poke() // the status reads paused (no_icloud), or running again
	}
}

// iCloudPaused: the iCloud hold stops the whole hub because CloudKit is the
// active transport, so the status reads paused (ReasonNoICloud), as the
// Swift hub showed itself unavailable, and no pass runs. On the relay
// nothing is paused.
func (h *hubRuntime) iCloudPaused() bool { return h.ckPubHeld.Load() }

// ckAccountUnread: the bridge has not answered an account read yet (it
// starts after the hub; the first read at start can find it down).
func (h *hubRuntime) ckAccountUnread() bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.ckAccount == ""
}

// resetCloudKit is the Swift hub's account and data-zone resets: with
// CloudKit's processor and the publisher held, what the hub believes is
// published goes (state.WipeSyncState) and so do the staged assets, so the
// resumed full diff republishes and restages everything into the new zone.
// account is an iCloud account change, which also rewinds CloudKit's
// mailbox (the new account's RelayZone is another zone; the exactly-once
// ledger keeps a re-read record from applying twice); a zone deleted on the
// server keeps it (the relay buffer survived). On a desktop host whose
// active transport is the relay, the published state is the relay's and
// stays (and so do the staged assets it references, unless the account
// changed): a switch to CloudKit republishes under a new epoch anyway.
//
// A wipe that fails keeps both held (ckResetPending) and is retried by
// retryCloudKitReset each housekeeping run: released unwiped, the full diff
// would match the old hashes and publish nothing into the new zone. The
// worker goroutine alone runs both, so the two fields need no lock.
func (h *hubRuntime) resetCloudKit(ctx context.Context, account bool) {
	if !h.ckResetPending {
		if p := h.cloudKitProcessor(); p != nil {
			p.PauseFor(pauseCloudKitReset)
		}
		if h.pub != nil {
			h.pub.PauseFor(pauseCloudKitReset)
		}
	}
	h.ckResetPending = true
	h.ckResetAccount = h.ckResetAccount || account
	account = h.ckResetAccount
	onCloudKit := h.tr.Kind() == transport.KindCloudKit
	mailbox := transport.SharedMailboxZone(h.relayID)
	var err error
	switch {
	case onCloudKit && account:
		err = h.st.WipeSyncState(ctx, h.sup.o.Clock().Add(-sources.WorkAlertLifetime), mailbox)
	case onCloudKit:
		err = h.st.WipeSyncState(ctx, h.sup.o.Clock().Add(-sources.WorkAlertLifetime))
	case account:
		err = h.st.SetZoneToken(mailbox, 0)
	}
	if err != nil {
		log.Printf("hub: wiping the published state after a CloudKit reset failed (%s): CloudKit held, retried", errClass(err))
		return
	}
	if onCloudKit || account {
		h.forgetStagedAssets()
	}
	h.ckResetPending, h.ckResetAccount = false, false
	if p := h.cloudKitProcessor(); p != nil {
		p.ResumeFor(pauseCloudKitReset)
	}
	if h.pub != nil {
		h.pub.ResumeFor(pauseCloudKitReset)
	}
	h.kick(h.passKick) // a rewound mailbox is read again at once
}

// retryCloudKitReset runs a reset whose wipe failed again (housekeeping).
func (h *hubRuntime) retryCloudKitReset(ctx context.Context) {
	if h.ckResetPending {
		h.resetCloudKit(ctx, false)
	}
}
