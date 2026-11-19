package hub

import (
	"context"
	"log"
	"time"

	"watchtower/internal/hub/transport"
)

// metaCloudKitZonesHubID is the hub_id spelling of the CloudKit zones
// (DataZone-/RelayZone-<hub_id>) that the published state and CloudKit's
// mailbox token belong to.
const metaCloudKitZonesHubID = "cloudkit_zones_hub_id"

// respellCloudKitZones moves CloudKit to the zones named with hub_id as
// stored (identity.Keyring.HubIDText, #1746). CloudKit zone names are
// case-sensitive, and every build before this one named them with the
// uppercase form: on a hub adopted from the Swift hub (a lowercase hub_id)
// those were two new zones no phone reads or writes, while the phones kept
// the Swift hub's lowercase ones. When the spelling changed, what the hub
// believes is published goes and CloudKit's mailbox is read again from the
// start (resetCloudKit's account reset: the new RelayZone is another zone,
// and the exactly-once ledger keeps a record read again from applying
// twice), so the next full diff publishes into the phones' zones. Run once
// at start, before the workers; a wipe that fails is retried by the
// housekeeping, and the mark waits for the next start.
func (h *hubRuntime) respellCloudKitZones(ctx context.Context) {
	if h.ck == nil {
		return
	}
	want := h.kr.HubIDText()
	prev, ok, err := h.st.Meta(metaCloudKitZonesHubID)
	if err != nil {
		log.Printf("hub: reading the CloudKit zones' hub id failed (%s): checked at the next start", errClass(err))
		return
	}
	if ok && prev == want {
		return
	}
	if !ok {
		prev = h.kr.HubID().String() // what every build before #1746 named them with
	}
	if prev != want {
		log.Printf("hub: the CloudKit zones are named with the stored hub id now: republishing, the mailbox read again")
		h.resetCloudKit(ctx, true)
		if h.ckResetPending {
			return
		}
	}
	if err := h.st.SetMeta(metaCloudKitZonesHubID, want); err != nil {
		log.Printf("hub: recording the CloudKit zones' hub id failed (%s): checked at the next start", errClass(err))
	}
}

// metaCloudKitRetiredHubID is the hub_id spelling whose CloudKit zones and
// bridge database subscription retireOldCloudKitZones deleted (#1750).
const metaCloudKitRetiredHubID = "cloudkit_retired_zones_hub_id"

// The retirement's backoff after a failure: doubled from retireFirstDelay
// on each failure up to retireMaxDelay (housekeeping runs each daemon cycle
// and every houseEvery, so a retry waits for the first one after the delay).
const (
	retireFirstDelay = houseEvery
	retireMaxDelay   = 12 * time.Hour
)

// zoneRetirer is the CloudKit bridge client's RetireZones
// (cloudkit.Client): the zones and database subscription of another
// spelling of the hub's id.
type zoneRetirer interface {
	RetireZones(ctx context.Context, hubID string) error
}

// zoneRetirement is retireOldCloudKitZones' state in this run.
type zoneRetirement struct {
	done   bool
	next   time.Time       // no try before it (zero: try now)
	delay  time.Duration   // the wait after the next failure
	logged map[string]bool // failure classes already logged
}

// retireOldCloudKitZones deletes, once, the CloudKit zones
// DataZone-/RelayZone-<UPPERCASE hub_id> and the bridge's
// watchtower-bridge-db-<UPPERCASE hub_id> database subscription that builds
// up to v0.28.0 made on a hub adopted from the Swift hub (lowercase hub_id;
// respellCloudKitZones moved it to the lowercase zones). Nothing reads
// those zones any more; the subscription costs one more silent push per
// private-database change. A hub whose stored hub_id is the uppercase form
// (made by the Go hub) has nothing to retire: the two spellings are equal
// and it never asks — its own zones are never named (the client and the
// bridge both refuse anything but another spelling of the hub's id).
//
// It runs from housekeeping, the worker's, once respellCloudKitZones has
// recorded the stored spelling and while the iCloud account is available;
// hub_meta records it only after the bridge answered done (zones or a
// subscription already gone count). A failure — iCloud unavailable, an old
// bridge that does not know the op, the bridge down — never holds the hub:
// it is retried after a backoff, at the next start at the latest, and each
// failure class is logged once per run.
func (h *hubRuntime) retireOldCloudKitZones(ctx context.Context) {
	r := &h.ckRetire
	if r.done || h.ck == nil || h.sup.o.Clock().Before(r.next) {
		return
	}
	old, cur := h.kr.HubID().String(), h.kr.HubIDText()
	if old == cur {
		r.done = true // a Go-made hub: its zones always had the uppercase name
		return
	}
	retired, ok, err := h.st.Meta(metaCloudKitRetiredHubID)
	if err != nil {
		h.retireFailed("meta", err)
		return
	}
	if ok && retired == old {
		r.done = true
		return
	}
	retirer, ok := h.ck.(zoneRetirer)
	if !ok {
		r.done = true
		return
	}
	zones, ok, err := h.st.Meta(metaCloudKitZonesHubID)
	if err != nil {
		h.retireFailed("meta", err)
		return
	}
	if !ok || zones != cur {
		return // the respelling is not recorded yet (its reset still pending)
	}
	h.mu.Lock()
	acct := h.ckAccount
	h.mu.Unlock()
	if acct != transport.AccountAvailable {
		return // read again each cycle; the account's own hold logs it
	}
	cctx, cancel := context.WithTimeout(ctx, opTimeout)
	err = retirer.RetireZones(cctx, old)
	cancel()
	if err != nil {
		h.retireFailed("bridge", err)
		return
	}
	if err := h.st.SetMeta(metaCloudKitRetiredHubID, old); err != nil {
		h.retireFailed("meta", err) // deleted again (already gone: done) next time
		return
	}
	r.done = true
	log.Printf("hub: the CloudKit zones and push subscription named with the uppercase hub id are deleted")
}

// retireFailed backs the retirement off and logs a failure class once.
func (h *hubRuntime) retireFailed(step string, err error) {
	r := &h.ckRetire
	if r.delay == 0 {
		r.delay = retireFirstDelay
	}
	r.next = h.sup.o.Clock().Add(r.delay)
	r.delay = min(2*r.delay, retireMaxDelay)
	class := step + ":" + errClass(err)
	if r.logged == nil {
		r.logged = map[string]bool{}
	}
	if !r.logged[class] {
		r.logged[class] = true
		log.Printf("hub: deleting the CloudKit zones named with the uppercase hub id failed (%s, %s): retried later", step, errClass(err))
	}
}
