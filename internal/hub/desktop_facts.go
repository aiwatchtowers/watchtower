package hub

import (
	"context"
	"errors"
	"log"
	"time"

	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/cloudkit"
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
//
// The log names a run of failed reads once, and again only when their class
// changes; the next answer after a logged run says so once (#2192). Before
// this run's first answer, a read that finds no bridge listening
// (cloudkit.ErrBridgeNotListening) is not logged until the bridge's launch
// was seen by two houseEvery ticks in a row (bridgeStarting): the bridge
// starts after the hub, and its supervisor reports it running as soon as the
// process starts, before it serves its socket, so a start's first reads (the
// pass, the housekeeping and the link upkeep's pass, all kicked at once)
// find none yet. A bridge that runs and never serves it is logged at the
// second tick after its launch; one that does not start or keeps exiting is
// logged by its supervisor. Any other failure (a connection that dropped
// included) is logged at once. The silent failure's class is still
// recorded.
func (h *hubRuntime) refreshCloudKitAccount(ctx context.Context) {
	s, ok := h.shares()
	if !ok || h.sup.o.Desktop == nil {
		return
	}
	cctx, cancel := context.WithTimeout(ctx, opTimeout)
	a, err := s.AccountStatus(cctx)
	cancel()
	if err != nil {
		class := errClass(err)
		starting := errors.Is(err, cloudkit.ErrBridgeNotListening) && h.ckAccountUnread() && h.bridgeStarting()
		h.ckReadFail = class
		if starting || class == h.ckReadLogged {
			return
		}
		h.ckReadLogged = class
		log.Printf("hub: reading the iCloud account failed (%s): retried next cycle", class)
		return
	}
	if h.ckReadLogged != "" {
		log.Printf("hub: the iCloud account read again (%s)", a)
	}
	h.ckReadFail, h.ckReadLogged = "", ""
	h.mu.Lock()
	h.ckAccount = a
	h.mu.Unlock()
	h.applyICloudHold()
}

// bridgeLaunches is the bridge's launch generation (0 = none, or no bridge).
func (h *hubRuntime) bridgeLaunches() uint64 {
	if h.bridge == nil {
		return 0
	}
	return h.bridge.Launches()
}

// noteBridgeLaunch is a houseEvery tick's look at the bridge's launch
// generation (before its housekeeping reads the account): settled when the
// previous tick saw the same launch already. The start's and the daemon
// cycles' housekeepings do not count: they can run back to back.
func (h *hubRuntime) noteBridgeLaunch() {
	g := h.bridgeLaunches()
	h.ckLaunchSettled = g != 0 && g == h.ckLaunchSeen
	h.ckLaunchSeen = g
}

// bridgeStarting: the current bridge launch (if any) has not yet been seen
// by two houseEvery ticks in a row — a whole houseEvery interval may not
// have passed since it, so a missing socket may only mean it is not served
// yet. A relaunch starts it over.
func (h *hubRuntime) bridgeStarting() bool {
	return !h.ckLaunchSettled || h.bridgeLaunches() != h.ckLaunchSeen
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
