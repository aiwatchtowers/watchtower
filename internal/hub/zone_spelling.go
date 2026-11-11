package hub

import (
	"context"
	"log"
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
