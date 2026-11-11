package hub

import (
	"log"
	goslices "slices"
)

// keysInZone is the link center's KeysInZone (relay client Phase 5): whether
// device's keybox in the data zone carries the epoch keys. Yes off the relay
// (by the keyring's relay rule: the current epoch's on_relay, the transport
// of a headless hub). On the relay, only for a phone that is not lapsed and
// that reads the data zone: a reader the relay last accepted, or any phone
// while that list is still unknown (before the first set_hub_readers after a
// start, so a restart never takes keys away from a phone that reads them). A
// free or lapsed phone (or one whose lapse waits for the switcher) reads nothing there, so its keybox carries the grant
// alone; a transport_switched still brings it the keys (KeyboxesAll).
//
// A failed read keeps the keys, as before Phase 5. It runs under the link
// center's lock: it reads the sidecar and the transport, never the center.
func (h *hubRuntime) keysInZone(device string) bool {
	on, err := h.kr.OnRelay()
	if err != nil {
		log.Printf("hub: keyboxes: the transport is unknown (%s): keys kept in the zone", errClass(err))
		return true
	}
	if !on {
		return true
	}
	dev, linked, err := h.st.Device(device)
	if err != nil {
		log.Printf("hub: keyboxes: a phone is unreadable (%s): keys kept in the zone", errClass(err))
		return true
	}
	if !linked || dev.RelayLapsedAt != nil {
		return false
	}
	// A lapse waiting for the switcher (its account read failed) already
	// cleared the phone's relay keys: no keys in the zone from queueLapse on.
	pending, err := h.st.LapsePending(dev.ID)
	if err != nil {
		log.Printf("hub: keyboxes: the waiting lapses are unreadable (%s): keys kept in the zone", errClass(err))
		return true
	}
	if pending {
		return false
	}
	r, ok := h.relayT().(readerLister)
	if !ok {
		return true
	}
	readers := r.Readers()
	if readers == nil {
		return true
	}
	return dev.RelayDeviceID != "" && goslices.Contains(readers, dev.RelayDeviceID)
}
