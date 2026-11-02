package hub

import (
	"log"
	"time"

	"watchtower/internal/hub/slices"
)

// The owner's off (go hub plan 3 Task 23 review): turning Mobile off deletes
// what the hub published, as the Swift hub's deleteZonesForHubOff did and as
// POLICY-03's wipe does — through the running transports before the hub
// stops (the bridge still up), and while the hub stays off, retried from the
// stopped wipe until nothing published is left. Linked phones and keys stay:
// turning on again republishes.

// OffDelete* are `hub status --json`'s off_delete.state values while the
// owner's switch is off ("" while it is on).
const (
	OffDeleteOK      = "ok"      // nothing the hub published is left
	OffDeletePending = "pending" // published records left, not tried yet
	OffDeleteFailed  = "failed"  // the last try left published records; retried
)

// OffDeleteStatus is `hub status --json`'s "off_delete" block (pinned keys):
// State (OffDelete*, "" while on) and At, the last try (RFC 3339, "" = none
// in this run).
type OffDeleteStatus struct {
	State string `json:"state"`
	At    string `json:"at"`
}

// offWipeRetry spaces the stopped retries of the owner's off wipe (a test seam).
var offWipeRetry = wipeRetry

// keepNothing is the wipe's filter: every published kind goes.
func keepNothing(slices.Kind) bool { return false }

// publishedLeft counts the records the hub has published and not deleted.
func (s *supervisor) publishedLeft() (int, error) {
	recs, err := publishedRecords(s.st, keepNothing)
	return len(recs), err
}

// noteOffDelete records a try of the off wipe at now: whether it left
// anything published.
func (s *supervisor) noteOffDelete(now time.Time) {
	s.offDeleteAt = now
	n, err := s.publishedLeft()
	s.offDeleteFailed = err != nil || n > 0
	if s.offDeleteFailed {
		log.Printf("hub: off: %d published records left: retried while off", n)
	}
}

// offDeleteStatus is the off_delete block for the owner's off.
func (s *supervisor) offDeleteStatus() OffDeleteStatus {
	var st OffDeleteStatus
	if !s.offDeleteAt.IsZero() {
		st.At = s.offDeleteAt.UTC().Format(time.RFC3339)
	}
	n, err := s.publishedLeft()
	switch {
	case err == nil && n == 0:
		st.State = OffDeleteOK
	case s.offDeleteFailed:
		st.State = OffDeleteFailed
	default:
		st.State = OffDeletePending
	}
	return st
}
