package hub

import (
	"context"
	"log"
	"time"

	"watchtower/internal/hub/transport"
)

// What Settings → Mobile and the Desktop's keep-awake read of a running hub
// on a desktop host (go hub plan 3 Task 23): the CloudKit facts the Swift
// hub's tab showed (the iCloud account, CloudKit's rate limit, whether this
// build can use CloudKit at all) and when a phone was last in touch.

// CloudKitStatus is `hub status --json`'s "cloudkit" block (pinned keys).
// Account is the bridge's account state (transport.Account*: available,
// no_account, restricted, temporarily_unavailable, no_entitlement; "" =
// not read: no running hub, no bridge, or the bridge did not answer).
// ThrottledSince (RFC 3339, "" = not now) is when CloudKit started
// rate-limiting the hub. Signed is false on a desktop host whose build has
// no CloudKit bridge or whose bridge lacks the iCloud entitlement (the old
// "Needs a signed build"); false off a desktop host.
type CloudKitStatus struct {
	Account        string `json:"account"`
	ThrottledSince string `json:"throttled_since"`
	Signed         bool   `json:"signed"`
}

// metaPhoneContactAt is hub_meta's last phone contact (RFC 3339), kept
// across restarts: the keep-awake's 24-hour window outlives a hub restart
// (the Swift hub's sidecar kept it the same way).
const metaPhoneContactAt = "phone_contact_at"

// throttleReporter is the CloudKit client's rate-limit view.
type throttleReporter interface{ ThrottledSince() time.Time }

// refreshCloudKitAccount reads the iCloud account from the bridge (at start,
// each pass until a first answer, every daemon cycle and on an account
// change) and holds or releases the
// CloudKit side by it (applyICloudHold); a failed read keeps the last
// answer.
func (h *hubRuntime) refreshCloudKitAccount(ctx context.Context) {
	s, ok := h.shares()
	if !ok || h.sup.o.Desktop == nil {
		return
	}
	cctx, cancel := context.WithTimeout(ctx, opTimeout)
	a, err := s.AccountStatus(cctx)
	cancel()
	if err != nil {
		log.Printf("hub: reading the iCloud account failed (%s): retried next cycle", errClass(err))
		return
	}
	h.mu.Lock()
	h.ckAccount = a
	h.mu.Unlock()
	h.applyICloudHold()
}

// cloudKitStatus is the running hub's "cloudkit" block (Signed is set by
// setStatus, which also sees a hub that is off).
func (h *hubRuntime) cloudKitStatus() CloudKitStatus {
	var st CloudKitStatus
	h.mu.Lock()
	st.Account = string(h.ckAccount)
	h.mu.Unlock()
	if t, ok := h.ck.(throttleReporter); ok {
		if since := t.ThrottledSince(); !since.IsZero() {
			st.ThrottledSince = since.UTC().Format(time.RFC3339)
		}
	}
	return st
}

// signedBuild: a desktop host's build can use CloudKit — it has the bridge
// and the bridge did not report the entitlement missing.
func signedBuild(st Status) bool {
	return st.Bridge != BridgeUnavailable && st.CloudKit.Account != string(transport.AccountNoEntitlement)
}

// phoneContact is when a phone was last in touch: this run's last admitted
// contact (noteContact), or the one stored by an earlier run (zero = never).
func (h *hubRuntime) phoneContact() time.Time {
	h.mu.Lock()
	t, stored := h.lastContact, h.storedContact
	h.mu.Unlock()
	if stored.After(t) {
		return stored
	}
	return t
}

// loadPhoneContact reads the stored last contact (at start).
func (h *hubRuntime) loadPhoneContact() {
	v, ok, err := h.st.Meta(metaPhoneContactAt)
	if err != nil || !ok {
		return
	}
	if t, err := time.Parse(time.RFC3339, v); err == nil {
		h.mu.Lock()
		h.storedContact = t
		h.mu.Unlock()
	}
}

// savePhoneContact stores this run's last contact when it is newer than the
// stored one (each daemon cycle: one small write at most per cycle).
func (h *hubRuntime) savePhoneContact() {
	h.mu.Lock()
	t := h.lastContact
	newer := t.After(h.storedContact)
	h.mu.Unlock()
	if !newer {
		return
	}
	if err := h.st.SetMeta(metaPhoneContactAt, t.UTC().Format(time.RFC3339)); err != nil {
		log.Printf("hub: storing the last phone contact failed (%s)", errClass(err))
		return
	}
	h.mu.Lock()
	h.storedContact = t
	h.mu.Unlock()
}

// phoneContactAt is the heartbeat answer's last phone contact: nil while no
// hub runs or no phone was ever in touch.
func (s *supervisor) phoneContactAt() *time.Time {
	s.hubMu.RLock()
	defer s.hubMu.RUnlock()
	if s.hub == nil {
		return nil
	}
	t := s.hub.phoneContact()
	if t.IsZero() {
		return nil
	}
	return &t
}
